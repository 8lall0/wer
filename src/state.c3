module gameboy;

import cpu, mmu, ppu, apu, cart, sgb, timer, joypad;
import std::io, std::io::file;

// Save states: the whole machine as it is between two instructions.
//
// The machine is plain value structs apart from a few heap blocks, so a state
// is those structs byte for byte followed by the heap blocks they point to:
//
//   header | Cpu | Mmu | CGB: WRAM 2-7, VRAM 1, colour frame | shade frame
//          | cartridge: Cartridge + its RAM | SGB: Sgb
//
// Loading copies them back and puts the pointers (and the host-side audio
// and logging settings) of the running machine back in place. Struct bytes
// only mean something to the build that wrote them, so the header carries a
// fingerprint of every struct's layout: a state from a build with different
// structs is refused, not misread. It also names the game (its header) and
// the model, which must match.

const char[8] STATE_MAGIC = "WERSTATE";
const uint STATE_VERSION = 1;

faultdef STATE_INVALID, STATE_OTHER_BUILD, STATE_OTHER_GAME, STATE_OTHER_MODEL;

struct StateHeader {
	char[8]  magic;
	uint     version;
	uint     layout;       // state_layout() of the writing build
	uint     model;
	uint     flags;        // STATE_CGB / STATE_CART / STATE_SGB: which blocks follow
	char[28] rom_header;   // $0134-$014F: title, codes and checksums
}

const uint STATE_CGB  = 1;
const uint STATE_CART = 2;
const uint STATE_SGB  = 4;

macro uint layout_of($Type, uint h) {
	h = h * 31 + (uint)$Type::size;
	$foreach $m : $Type::members:
		h = h * 31 + (uint)$m.offset;
		foreach (c : $m.name) h = h * 31 + c;
	$endforeach
	return h;
}

// A fingerprint of the layout of everything a state stores.
fn uint state_layout() {
	uint h = STATE_VERSION;
	h = layout_of(cpu::Cpu, h);
	h = layout_of(cpu::BusEvent, h);
	h = layout_of(mmu::Mmu, h);
	h = layout_of(mmu::Dma, h);
	h = layout_of(timer::Timer, h);
	h = layout_of(joypad::Joypad, h);
	h = layout_of(ppu::Ppu, h);
	h = layout_of(ppu::RegWrite, h);
	h = layout_of(ppu::Renderer, h);
	h = layout_of(ppu::Fifo, h);
	h = layout_of(ppu::Pixel, h);
	h = layout_of(apu::Apu, h);
	h = layout_of(apu::Square, h);
	h = layout_of(apu::Wave, h);
	h = layout_of(apu::Noise, h);
	h = layout_of(apu::EnvClock, h);
	h = layout_of(cart::Cartridge, h);
	h = layout_of(cart::Rtc, h);
	h = layout_of(sgb::Sgb, h);
	return h;
}

fn char[] GameBoy.rom_header(&self) {
	char[] rom = self.mmu.cart ? self.mmu.cart.rom : self.mmu.rom[..];
	return rom[0x134 : 28];
}

fn uint GameBoy.state_flags(&self) {
	uint flags;
	if (self.mmu.wram_ext) flags |= STATE_CGB;
	if (self.mmu.cart) flags |= STATE_CART;
	if (self.mmu.sgb) flags |= STATE_SGB;
	return flags;
}

// The heap blocks after the Cpu and Mmu, in file order.
fn usz GameBoy.state_size(&self) {
	usz n = StateHeader::size + cpu::Cpu::size + mmu::Mmu::size;
	if (self.mmu.wram_ext) n += mmu::WRAM_EXT_SIZE + 0x2000 + self.mmu.ppu.cfb.len * 2;
	n += self.mmu.ppu.fb.len;
	if (self.mmu.cart) n += cart::Cartridge::size + self.mmu.cart.ram.len;
	if (self.mmu.sgb) n += sgb::Sgb::size;
	return n;
}

struct StateCursor {
	char[] data;
	usz pos;
}

fn void StateCursor.put(&self, void* p, usz n) {
	mem::copy(&self.data[self.pos], p, (sz)n);
	self.pos += n;
}

fn void StateCursor.get(&self, void* p, usz n) {
	mem::copy(p, &self.data[self.pos], (sz)n);
	self.pos += n;
}

fn char[] GameBoy.save_state(&self, Allocator alloc) {
	StateHeader h = {
		.magic = STATE_MAGIC,
		.version = STATE_VERSION,
		.layout = state_layout(),
		.model = (uint)self.mmu.model.ordinal,
		.flags = self.state_flags(),
	};
	h.rom_header[..] = self.rom_header()[..];

	StateCursor w = { .data = alloc::alloc_array(alloc, char, (sz)self.state_size()) };
	w.put(&h, StateHeader::size);
	w.put(&self.cpu, cpu::Cpu::size);
	w.put(&self.mmu, mmu::Mmu::size);
	if (self.mmu.wram_ext) {
		w.put(self.mmu.wram_ext, mmu::WRAM_EXT_SIZE);
		w.put(self.mmu.ppu.vram1, 0x2000);
		w.put(self.mmu.ppu.cfb.ptr, self.mmu.ppu.cfb.len * 2);
	}
	w.put(self.mmu.ppu.fb.ptr, self.mmu.ppu.fb.len);
	if (self.mmu.cart) {
		w.put(self.mmu.cart, cart::Cartridge::size);
		if (self.mmu.cart.ram.len) w.put(self.mmu.cart.ram.ptr, self.mmu.cart.ram.len);
	}
	if (self.mmu.sgb) w.put(self.mmu.sgb, sgb::Sgb::size);
	return w.data;
}

// Checks everything first: a state that doesn't fit leaves the machine as it was.
fn void? GameBoy.load_state(&self, char[] data) {
	if (data.len < StateHeader::size) return STATE_INVALID~;
	StateHeader h;
	mem::copy(&h, data.ptr, StateHeader::size);
	if (h.magic != STATE_MAGIC) return STATE_INVALID~;
	if (h.version != STATE_VERSION || h.layout != state_layout()) return STATE_OTHER_BUILD~;
	if (h.model != (uint)self.mmu.model.ordinal) return STATE_OTHER_MODEL~;
	if (h.rom_header[..] != self.rom_header()) return STATE_OTHER_GAME~;
	if (h.flags != self.state_flags() || data.len != self.state_size()) return STATE_INVALID~;

	StateCursor r = { .data = data, .pos = StateHeader::size };
	r.get(&self.cpu, cpu::Cpu::size);

	// The Mmu's pointers and host-side settings stay those of this machine.
	mmu::Mmu keep = self.mmu;
	r.get(&self.mmu, mmu::Mmu::size);
	self.mmu.cart = keep.cart;
	self.mmu.flat = keep.flat;
	self.mmu.wram_ext = keep.wram_ext;
	self.mmu.sgb = keep.sgb;
	self.mmu.serial_echo = keep.serial_echo;
	self.mmu.ppu.vram1 = keep.ppu.vram1;
	self.mmu.ppu.fb = keep.ppu.fb;
	self.mmu.ppu.cfb = keep.ppu.cfb;
	// Sound: this machine's buffer, emptied (what it held belongs to the
	// abandoned timeline), and the rate the host asks for.
	apu::Apu* a = &self.mmu.apu;
	a.ring = keep.apu.ring;
	a.cap = keep.apu.cap;
	a.w = 0;
	a.r = 0;
	a.count = 0;
	a.out_rate = keep.apu.out_rate;

	if (self.mmu.wram_ext) {
		r.get(self.mmu.wram_ext, mmu::WRAM_EXT_SIZE);
		r.get(self.mmu.ppu.vram1, 0x2000);
		r.get(self.mmu.ppu.cfb.ptr, self.mmu.ppu.cfb.len * 2);
	}
	r.get(self.mmu.ppu.fb.ptr, self.mmu.ppu.fb.len);
	if (self.mmu.cart) {
		cart::Cartridge* c = self.mmu.cart;
		cart::Cartridge ck = *c;
		r.get(c, cart::Cartridge::size);
		c.rom = ck.rom;
		c.ram = ck.ram;
		c.save_path = ck.save_path;
		c.rtc.cpu_hz = ck.rtc.cpu_hz;
		if (c.ram.len) r.get(c.ram.ptr, c.ram.len);
	}
	if (self.mmu.sgb) {
		bool log = self.mmu.sgb.log;
		r.get(self.mmu.sgb, sgb::Sgb::size);
		self.mmu.sgb.log = log;
	}
}

fn void? GameBoy.save_state_file(&self, String path) {
	char[] data = self.save_state(tmem);
	file::save(path, data)!;
}

fn void? GameBoy.load_state_file(&self, String path) {
	char[] data = file::load_temp(path)!;
	self.load_state(data)!;
}

// Slot `n` of the game at `rom_path`, next to its battery save.
fn String state_path(String rom_path, int n) => string::tformat("%s.ss%d", rom_path, n);
