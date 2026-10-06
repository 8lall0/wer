module gameboy;

import cpu, mmu, ppu, apu, cart, sgb, timer, joypad;
import std::io, std::io::file;

// Save states: the whole machine as it is between two instructions.
//
// A state is a header (the game, the model) and then every field of the
// machine's structs by name, written from the structs themselves at compile
// time (write_struct / read_struct):
//
//   field  = name length (u8), name, tag (u8), length (u32), value
//   record = u16 field count, fields
//
// with a struct's value a record of its own, an integer's its bytes (read
// back into whatever width the field has now), an array's its element size
// (u32) and elements. Loading matches the fields by name, so a state still
// loads after the structs change: a field that is gone is skipped, a new
// field keeps the value it has, an array that grew or shrank takes what
// fits. Pointers and slices aren't state; the heap blocks they point to go
// in as blocks of their own (wram_ext, vram1, cfb, fb, cart_ram). A field
// whose meaning changes must change its name too.
//
// Version 1 states (wer 0.10 and before: the structs byte for byte) still
// load while this build's structs are laid out as theirs were.

const char[8] STATE_MAGIC = "WERSTATE";
const uint STATE_VERSION = 2;
const uint STATE_RAW = 1;

faultdef STATE_INVALID, STATE_OTHER_BUILD, STATE_OTHER_GAME, STATE_OTHER_MODEL;

struct StateHeader {
	char[8]  magic;
	uint     version;
	uint     layout;       // state_layout() of the writing build (version 1 checks it)
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

// A fingerprint of the layout of everything a version 1 state stores.
fn uint state_layout() {
	uint h = STATE_RAW;
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

// The model in a state's header, with the CGB and DMG revisions (0 for C and
// A/B/C, so states from before revisions still load).
fn uint GameBoy.state_model(&self) => (uint)self.mmu.model.ordinal | (uint)((self.mmu.cgb_rev.ordinal + 3) % 6) << 8
	| (uint)((self.mmu.dmg_rev.ordinal + 2) % 3) << 12;

fn StateHeader GameBoy.state_header(&self, uint version) {
	StateHeader h = {
		.magic = STATE_MAGIC,
		.version = version,
		.layout = state_layout(),
		.model = self.state_model(),
		.flags = self.state_flags(),
	};
	h.rom_header[..] = self.rom_header()[..];
	return h;
}

// --- Fields by name ---------------------------------------------------------

const char TAG_RAW      = 0; // bytes, loaded only into a field of the same size
const char TAG_STRUCT   = 1;
const char TAG_SIGNED   = 2;
const char TAG_UNSIGNED = 3;
const char TAG_ARRAY    = 4;

struct StateWriter {
	DString out;
}

fn void StateWriter.u8(&self, char v) => self.out.append_char(v);

fn void StateWriter.u16(&self, ushort v) {
	self.u8((char)v);
	self.u8((char)(v >> 8));
}

fn void StateWriter.u32(&self, uint v) {
	for (int i = 0; i < 4; i++) self.u8((char)(v >> (8 * i)));
}

fn void StateWriter.bytes(&self, void* p, usz n) {
	self.out.append_bytes(((char*)p)[:(sz)n]);
}

// A field's name and tag, and room for its length (end_field fills it in).
fn usz StateWriter.begin_field(&self, String name, char tag) {
	self.u8((char)name.len);
	self.out.append_string(name);
	self.u8(tag);
	usz at = (usz)self.out.len();
	self.u32(0);
	return at;
}

fn void StateWriter.end_field(&self, usz at) {
	uint n = (uint)((usz)self.out.len() - at - 4);
	for (int i = 0; i < 4; i++) self.out[(sz)at + i] = (char)(n >> (8 * i));
}

fn void StateWriter.blob(&self, String name, void* p, usz n) {
	usz at = self.begin_field(name, TAG_RAW);
	self.bytes(p, n);
	self.end_field(at);
}

// Anonymous members (a union) go by their position.
macro String @field_name($name, $i) => $name.len ? $name : string::tformat("~%d", $i);

// Whether a field of this type is state: not pointers, slices and the like,
// also behind a typedef (String is a slice).
macro bool @is_state($type) {
	$switch $type.kind:
		$case POINTER:
		$case SLICE:
		$case FUNC:
		$case ANY:
		$case INTERFACE:
		$case TYPEID:
		$case FAULT:
		$case OPTIONAL:
			return false;
		$case TYPEDEF:
			return @is_state($type.inner);
		$default:
			return true;
	$endswitch
}

macro void write_struct($Type, StateWriter* w, void* p) {
	ushort n;
	$foreach $m : $Type::members:
		$if @is_state($m.type):
			n++;
		$endif
	$endforeach
	w.u16(n);
	$foreach $i, $m : $Type::members:
		$if @is_state($m.type):
			write_member($m.type, @field_name($m.name, $i), w, (char*)p + $m.offset);
		$endif
	$endforeach
}

macro void write_member($type, String name, StateWriter* w, void* p) {
	$switch $type.kind:
		$case STRUCT:
			usz at = w.begin_field(name, TAG_STRUCT);
			write_struct($Typefrom($type), w, p);
			w.end_field(at);
		$case SIGNED_INT:
			usz at = w.begin_field(name, TAG_SIGNED);
			w.bytes(p, $type.size);
			w.end_field(at);
		$case UNSIGNED_INT:
		$case BOOL:
			usz at = w.begin_field(name, TAG_UNSIGNED);
			w.bytes(p, $type.size);
			w.end_field(at);
		$case ARRAY:
			usz at = w.begin_field(name, TAG_ARRAY);
			w.u32((uint)$type.inner.size);
			w.bytes(p, $type.size);
			w.end_field(at);
		$default:
			usz at = w.begin_field(name, TAG_RAW);
			w.bytes(p, $type.size);
			w.end_field(at);
	$endswitch
}

struct StateField {
	String name;
	char   tag;
	char[] value;
}

fn uint get32(char[] d, usz at) => (uint)d[at] | (uint)d[at + 1] << 8 | (uint)d[at + 2] << 16 | (uint)d[at + 3] << 24;

// A well-formed record, all the way down (so a damaged state is refused
// before anything is loaded).
fn bool valid_record(char[] rec, int depth = 0) {
	if (depth > 16 || rec.len < 2) return false;
	int left = rec[0] | (int)rec[1] << 8;
	usz pos = 2;
	for (int i = 0; i < left; i++) {
		if (pos + 1 > rec.len) return false;
		usz len = rec[pos];
		if (pos + 6 + len > rec.len) return false;
		char tag = rec[pos + 1 + len];
		usz n = get32(rec, pos + 2 + len);
		usz start = pos + 6 + len;
		if (n > rec.len - start) return false;
		char[] value = rec[start : n];
		switch (tag) {
			case TAG_STRUCT: if (!valid_record(value, depth + 1)) return false;
			case TAG_ARRAY:  if (n < 4) return false;
			case TAG_SIGNED:
			case TAG_UNSIGNED:
				if (n != 1 && n != 2 && n != 4 && n != 8) return false;
			default: break;
		}
		pos = start + n;
	}
	return pos == rec.len;
}

// A field of a (valid) record by name.
fn StateField? find_field(char[] rec, String name) {
	int left = rec[0] | (int)rec[1] << 8;
	usz pos = 2;
	for (int i = 0; i < left; i++) {
		usz len = rec[pos];
		usz n = get32(rec, pos + 2 + len);
		if ((String)rec[pos + 1 : len] == name) {
			return { .name = name, .tag = rec[pos + 1 + len], .value = rec[pos + 6 + len : n] };
		}
		pos += 6 + len + n;
	}
	return NOT_FOUND~;
}

fn long field_int(StateField* f) {
	ulong v;
	foreach (i, b : f.value) v |= (ulong)b << (8 * i);
	usz bits = f.value.len * 8;
	if (f.tag == TAG_SIGNED && bits < 64 && ((v >> (bits - 1)) & 1)) v |= ~0UL << bits;
	return (long)v;
}

macro void read_struct($Type, char[] rec, void* p) {
	$foreach $i, $m : $Type::members:
		$if @is_state($m.type):
			if (try f = find_field(rec, @field_name($m.name, $i))) read_member($m.type, &f, (char*)p + $m.offset);
		$endif
	$endforeach
}

macro void read_member($type, StateField* f, void* p) {
	$switch $type.kind:
		$case STRUCT:
			if (f.tag == TAG_STRUCT) read_struct($Typefrom($type), f.value, p);
		$case BOOL:
			if (f.tag == TAG_SIGNED || f.tag == TAG_UNSIGNED) *(bool*)p = field_int(f) != 0;
		$case SIGNED_INT:
		$case UNSIGNED_INT:
			if (f.tag == TAG_SIGNED || f.tag == TAG_UNSIGNED) {
				long v = field_int(f);
				$switch $type.size:
					$case 1: *(char*)p = (char)v;
					$case 2: *(ushort*)p = (ushort)v;
					$case 4: *(uint*)p = (uint)v;
					$default: *(ulong*)p = (ulong)v;
				$endswitch
			}
		$case ARRAY:
			if (f.tag == TAG_ARRAY && get32(f.value, 0) == $type.inner.size) {
				usz n = f.value.len - 4;
				if (n > $type.size) n = $type.size;
				mem::copy(p, &f.value[4], (sz)n);
			}
		$default:
			if (f.tag == TAG_RAW && f.value.len == $type.size) mem::copy(p, f.value.ptr, (sz)$type.size);
	$endswitch
}

// A heap block: what fits of it.
fn void load_blob(char[] rec, String name, void* p, usz n) {
	if (try f = find_field(rec, name)) {
		if (f.tag == TAG_RAW && n) mem::copy(p, f.value.ptr, (sz)(f.value.len < n ? f.value.len : n));
	}
}

// --- Saving and loading -----------------------------------------------------

fn char[] GameBoy.save_state(&self, Allocator alloc) {
	self.mmu.apu.sync();
	StateHeader h = self.state_header(STATE_VERSION);
	StateWriter w;
	w.out.init(tmem);
	w.bytes(&h, StateHeader::size);
	ushort fields = 3; // cpu, mmu, fb
	if (self.mmu.wram_ext) fields += 3;
	if (self.mmu.cart) fields += 2;
	if (self.mmu.sgb) fields += 1;
	w.u16(fields);
	usz at = w.begin_field("cpu", TAG_STRUCT);
	write_struct(cpu::Cpu, &w, &self.cpu);
	w.end_field(at);
	at = w.begin_field("mmu", TAG_STRUCT);
	write_struct(mmu::Mmu, &w, &self.mmu);
	w.end_field(at);
	if (self.mmu.wram_ext) {
		w.blob("wram_ext", self.mmu.wram_ext, mmu::WRAM_EXT_SIZE);
		w.blob("vram1", self.mmu.ppu.vram1, 0x2000);
		w.blob("cfb", self.mmu.ppu.cfb.ptr, self.mmu.ppu.cfb.len * 2);
	}
	w.blob("fb", self.mmu.ppu.fb.ptr, self.mmu.ppu.fb.len);
	if (self.mmu.cart) {
		at = w.begin_field("cart", TAG_STRUCT);
		write_struct(cart::Cartridge, &w, self.mmu.cart);
		w.end_field(at);
		w.blob("cart_ram", self.mmu.cart.ram.ptr, self.mmu.cart.ram.len);
	}
	if (self.mmu.sgb) {
		at = w.begin_field("sgb", TAG_STRUCT);
		write_struct(sgb::Sgb, &w, self.mmu.sgb);
		w.end_field(at);
	}
	return w.out.str_view().copy(alloc);
}

// Checks everything first: a state that doesn't fit leaves the machine as it was.
fn void? GameBoy.load_state(&self, char[] data) {
	if (data.len < StateHeader::size) return STATE_INVALID~;
	StateHeader h;
	mem::copy(&h, data.ptr, StateHeader::size);
	if (h.magic != STATE_MAGIC) return STATE_INVALID~;
	if (h.version == STATE_RAW) return self.load_state_raw(data, &h);
	if (h.version != STATE_VERSION) return STATE_OTHER_BUILD~;
	if (h.model != self.state_model()) return STATE_OTHER_MODEL~;
	if (h.rom_header[..] != self.rom_header()) return STATE_OTHER_GAME~;
	if (h.flags != self.state_flags()) return STATE_INVALID~;
	char[] rec = data[StateHeader::size..];
	if (!valid_record(rec)) return STATE_INVALID~;
	StateField? c = find_field(rec, "cpu");
	StateField? m = find_field(rec, "mmu");
	if (catch c, m) return STATE_INVALID~;
	if (c.tag != TAG_STRUCT || m.tag != TAG_STRUCT) return STATE_INVALID~;

	HostSide keep = self.host_side();
	read_struct(cpu::Cpu, c.value, &self.cpu);
	read_struct(mmu::Mmu, m.value, &self.mmu);
	if (self.mmu.wram_ext) {
		load_blob(rec, "wram_ext", self.mmu.wram_ext, mmu::WRAM_EXT_SIZE);
		load_blob(rec, "vram1", self.mmu.ppu.vram1, 0x2000);
		load_blob(rec, "cfb", self.mmu.ppu.cfb.ptr, self.mmu.ppu.cfb.len * 2);
	}
	load_blob(rec, "fb", self.mmu.ppu.fb.ptr, self.mmu.ppu.fb.len);
	if (self.mmu.cart) {
		if (try f = find_field(rec, "cart")) {
			if (f.tag == TAG_STRUCT) read_struct(cart::Cartridge, f.value, self.mmu.cart);
		}
		load_blob(rec, "cart_ram", self.mmu.cart.ram.ptr, self.mmu.cart.ram.len);
	}
	if (self.mmu.sgb) {
		if (try f = find_field(rec, "sgb")) {
			if (f.tag == TAG_STRUCT) read_struct(sgb::Sgb, f.value, self.mmu.sgb);
		}
	}
	self.restore_host_side(&keep);
}

// What belongs to this run rather than to the machine: kept across a load.
struct HostSide {
	mmu::Mmu mmu;
	bool     sgb_log;
	uint     rtc_hz;
}

fn HostSide GameBoy.host_side(&self) {
	HostSide k = { .mmu = self.mmu };
	if (self.mmu.sgb) k.sgb_log = self.mmu.sgb.log;
	if (self.mmu.cart) k.rtc_hz = self.mmu.cart.rtc.cpu_hz;
	return k;
}

fn void GameBoy.restore_host_side(&self, HostSide* k) {
	self.mmu.cart = k.mmu.cart;
	self.mmu.flat = k.mmu.flat;
	self.mmu.wram_ext = k.mmu.wram_ext;
	self.mmu.sgb = k.mmu.sgb;
	self.mmu.serial_echo = k.mmu.serial_echo;
	self.mmu.link = k.mmu.link;
	self.mmu.cheats = k.mmu.cheats;
	self.mmu.serial_waiting = false;
	self.mmu.ppu.vram1 = k.mmu.ppu.vram1;
	self.mmu.ppu.fb = k.mmu.ppu.fb;
	self.mmu.ppu.cfb = k.mmu.ppu.cfb;
	// Sound: this machine's buffer, emptied (what it held belongs to the
	// abandoned timeline), and the rate the host asks for.
	apu::Apu* a = &self.mmu.apu;
	a.ring = k.mmu.apu.ring;
	a.cap = k.mmu.apu.cap;
	a.w = 0;
	a.r = 0;
	a.count = 0;
	a.out_rate = k.mmu.apu.out_rate;
	if (self.mmu.sgb) self.mmu.sgb.log = k.sgb_log;
	if (self.mmu.cart) self.mmu.cart.rtc.cpu_hz = k.rtc_hz;
}

// --- Version 1: the structs byte for byte -----------------------------------

fn usz GameBoy.raw_state_size(&self) {
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

// A version 1 state (for the tests: wer writes version 2).
fn char[] GameBoy.save_state_raw(&self, Allocator alloc) {
	self.mmu.apu.sync();
	StateHeader h = self.state_header(STATE_RAW);
	StateCursor w = { .data = alloc::alloc_array(alloc, char, (sz)self.raw_state_size()) };
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

fn void? GameBoy.load_state_raw(&self, char[] data, StateHeader* h) {
	if (h.layout != state_layout()) return STATE_OTHER_BUILD~;
	if (h.model != self.state_model()) return STATE_OTHER_MODEL~;
	if (h.rom_header[..] != self.rom_header()) return STATE_OTHER_GAME~;
	if (h.flags != self.state_flags() || data.len != self.raw_state_size()) return STATE_INVALID~;

	HostSide keep = self.host_side();
	StateCursor r = { .data = data, .pos = StateHeader::size };
	r.get(&self.cpu, cpu::Cpu::size);
	r.get(&self.mmu, mmu::Mmu::size);
	self.restore_host_side(&keep);
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

// Slot `n` of the game whose saves start with `base`, next to its battery save.
fn String state_path(String base, int n) => string::tformat("%s.ss%d", base, n);
