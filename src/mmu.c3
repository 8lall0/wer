module mmu;

import timer, ppu, joypad, apu, cart, bootrom;
import std::io;

const ushort IF_REG   = 0xFF0F;
const ushort DIV_REG  = 0xFF04;
const ushort TIMA_REG = 0xFF05;
const ushort TMA_REG  = 0xFF06;
const ushort TAC_REG  = 0xFF07;
const ushort DMA_REG  = 0xFF46;

const int DMA_STARTUP = 2;
const int DMA_LEN     = 0xA0;

// The DMG has two memory buses. OAM DMA occupies the one its source is on.
enum Bus : char {
	NONE,     // IO, HRAM, IE: internal, never blocked
	EXTERNAL, // cartridge ROM/RAM, WRAM and its echo
	VIDEO,    // VRAM
	OAM,      // $FE00-$FEFF: always the DMA's target
}

fn Bus bus_of(ushort addr) {
	if (addr < 0x8000) return EXTERNAL;
	if (addr < 0xA000) return VIDEO;
	if (addr < 0xFE00) return EXTERNAL;
	if (addr < 0xFF00) return OAM;
	return NONE;
}

struct Dma {
	bool   active;         // copying, CPU locked out
	ushort source;
	int    index;          // next byte, 0..DMA_LEN-1
	int    pending;        // M-cycles until a written start takes over (0 = none)
	ushort pending_source;
}

struct Mmu {
	char[0x8000] rom;      // 0000-7FFF fallback when there is no MBC cartridge
	char[0x2000] extram;   // A000-BFFF fallback
	cart::Cartridge* cart; // non-null once an MBC ROM is loaded; owns ROM+RAM
	char[0x2000] wram;   // C000-DFFF  (+ E000-FDFF echo)
	char[0x80]   io;     // FF00-FF7F
	char[0x7F]   hram;   // FF80-FFFE
	char         ie;     // FFFF
	timer::Timer   timer;
	ppu::Ppu       ppu;    // owns VRAM (8000-9FFF) and OAM (FE00-FE9F)
	joypad::Joypad joypad;
	apu::Apu       apu;    // owns the sound registers + wave RAM (FF10-FF3F)
	char*          flat;   // non-null => linear (test) mode

	bool   serial_active; // internal-clock transfer in progress
	int    serial_bits;   // bits shifted so far (0..8)
	bool   serial_echo;   // when true, print each transferred byte to stderr

	bool boot_active;

	Dma dma;
}

fn char Mmu.get(&self, ushort addr) {
	if (self.flat) return self.flat[addr];

	if (self.boot_active && addr < 0x100) return bootrom::DMG[addr];
	if (addr < 0x8000) return self.cart ? self.cart.read(addr) : self.rom[addr];
	if (addr < 0xA000) return self.ppu.vram[addr - 0x8000];
	if (addr < 0xC000) return self.cart ? self.cart.read(addr) : self.extram[addr - 0xA000];
	if (addr < 0xE000) return self.wram[addr - 0xC000];
	if (addr < 0xFE00) return self.wram[addr - 0xE000]; // echo RAM
	if (addr < 0xFEA0) return self.ppu.oam[addr - 0xFE00];
	if (addr < 0xFF00) return 0xFF;                     // unusable
	if (addr >= 0xFF10 && addr <= 0xFF3F) return self.apu.read(addr);
	if (addr < 0xFF80) return self.io_get(addr);
	if (addr < 0xFFFF) return self.hram[addr - 0xFF80];
	return self.ie;
}

fn void Mmu.set(&self, ushort addr, char value) {
	if (self.flat) { self.flat[addr] = value; return; }
	// $0000-$7FFF is cartridge ROM: read-only. With an MBC these writes are
	// bank-control registers; without one (plain 32 KiB ROM) they are ignored.
	if (addr < 0x8000) {
		if (self.cart) self.cart.write(addr, value);
		return;
	}
	if (addr < 0xA000) { self.ppu.vram[addr - 0x8000] = value; return; }
	if (addr < 0xC000) {
		if (self.cart) { self.cart.write(addr, value); } else { self.extram[addr - 0xA000] = value; }
		return;
	}
	if (addr < 0xE000) { self.wram[addr - 0xC000] = value; return; }
	if (addr < 0xFE00) { self.wram[addr - 0xE000] = value; return; }  // echo RAM
	if (addr < 0xFEA0) { self.ppu.oam[addr - 0xFE00] = value; return; }
	if (addr < 0xFF00) { return; }                                    // unusable
	if (addr >= 0xFF10 && addr <= 0xFF3F) { self.apu.write(addr, value); return; }
	if (addr < 0xFF80) { self.io_set(addr, value); return; }
	if (addr < 0xFFFF) { self.hram[addr - 0xFF80] = value; return; }
	self.ie = value;
}

fn char Mmu.io_get(&self, ushort addr) {
	switch (addr) {
		case 0xFF00:   return self.joypad.read();
		case DIV_REG:  return self.timer.div_reg();
		case TIMA_REG: return self.timer.tima;
		case TMA_REG:  return self.timer.tma;
		case TAC_REG:  return (char)(self.timer.tac | 0xF8);
		case 0xFF40:   return self.ppu.lcdc;
		case 0xFF41:   return (char)(self.ppu.stat | 0x80);
		case 0xFF42:   return self.ppu.scy;
		case 0xFF43:   return self.ppu.scx;
		case 0xFF44:   return self.ppu.ly;
		case 0xFF45:   return self.ppu.lyc;
		case 0xFF47:   return self.ppu.bgp;
		case 0xFF48:   return self.ppu.obp0;
		case 0xFF49:   return self.ppu.obp1;
		case 0xFF4A:   return self.ppu.wy;
		case 0xFF4B:   return self.ppu.wx;
		case 0xFF01:   // SB: all 8 bits
		case DMA_REG:  return self.io[addr - 0xFF00];
		case 0xFF02:   return self.io[0x02] | 0x7E;             // SC: only bits 7 and 0 exist
		case IF_REG:   return self.io[IF_REG - 0xFF00] | 0xE0;  // IF: bits 5-7 unused
		default:       return 0xFF;                             // unmapped
	}
}

fn void Mmu.load(&self, usz offset, char[] bytes) {
	foreach (i, b : bytes) {
		usz o = offset + (usz)i;
		if (o < 0x8000) self.rom[o] = b;
	}
}

fn void Mmu.io_set(&self, ushort addr, char value) {
	switch (addr) {
		case 0xFF00:   self.joypad.write(value);
		case 0xFF01:   self.io[0x01] = value; // SB
		case 0xFF02:   // SC: bit 7 = start, bit 0 = internal clock
			self.io[0x02] = value;
			if ((value & 0x81) == 0x81) self.serial_start();
		case DIV_REG:  self.timer.write_div();
		case TIMA_REG: self.timer.write_tima(value);
		case TMA_REG:  self.timer.write_tma(value);
		case TAC_REG:  self.timer.write_tac(value);
		case 0xFF40:   self.ppu.write_lcdc(value);
		case 0xFF41:   self.request_irq(self.ppu.write_stat(value));
		case 0xFF42:   self.ppu.scy = value;
		case 0xFF43:   self.ppu.scx = value;
		case 0xFF44:   break; // LY is read-only
		case 0xFF45:   self.request_irq(self.ppu.write_lyc(value));
		case DMA_REG:  self.io[DMA_REG - 0xFF00] = value; self.dma_request(value);
		case 0xFF47:   self.ppu.bgp = value;
		case 0xFF48:   self.ppu.obp0 = value;
		case 0xFF49:   self.ppu.obp1 = value;
		case 0xFF4A:   self.ppu.wy = value;
		case 0xFF4B:   self.ppu.wx = value;
		case 0xFF50:   if (value != 0) self.boot_active = false; // unmap boot ROM
		default:       self.io[addr - 0xFF00] = value;
	}
}

fn void Mmu.dma_request(&self, char page) {
	ushort src = (ushort)page << 8;
	if (src >= 0xE000) src -= 0x2000; // DMA sees $E000-$FFFF as WRAM
	self.dma.pending_source = src;
	self.dma.pending = DMA_STARTUP;
}

fn void Mmu.dma_step(&self) {
	if (self.dma.pending > 0 && --self.dma.pending == 0) {
		self.dma.active = true;
		self.dma.source = self.dma.pending_source;
		self.dma.index = 0;
		return;
	}
	if (!self.dma.active) return;
	self.ppu.oam[self.dma.index] = self.get(self.dma.source + (ushort)self.dma.index);
	if (++self.dma.index == DMA_LEN) self.dma.active = false;
}

// True when the CPU cannot access `addr` normally: OAM, or the bus the DMA
// is reading from. The other bus, IO, HRAM and IE stay usable.
fn bool Mmu.dma_blocks(&self, ushort addr) {
	if (!self.dma.active) return false;
	Bus bus = bus_of(addr);
	return bus == OAM || bus == bus_of(self.dma.source);
}

// CPU reads and writes to OAM/VRAM are locked at slightly different moments
// (see Ppu.oam_locked, vram_locked, oam_write_locked; Mooneye lcdon_*_timing).
fn bool Mmu.ppu_blocks(&self, ushort addr, bool write) {
	if ((self.ppu.lcdc & ppu::LCDC_ENABLE) == 0) return false;
	if (addr >= 0xFE00 && addr < 0xFEA0) {
		return write ? self.ppu.oam_write_locked() : self.ppu.oam_locked();
	}
	if (addr >= 0x8000 && addr < 0xA000) {
		return write ? self.ppu.mode == 3 : self.ppu.vram_locked();
	}
	return false;
}

// What a blocked CPU read sees: $FF for OAM, otherwise the byte the DMA is
// reading on that bus right now (DMG bus conflict).
fn char Mmu.dma_conflict_read(&self, ushort addr) {
	if (bus_of(addr) == OAM) return 0xFF;
	return self.get(self.dma.source + (ushort)self.dma.index);
}

// SC written with start + internal clock. Nothing moves yet: bits shift on
// the serial clock edges (Timer SERIAL_BIT), 8 of them per transfer.
fn void Mmu.serial_start(&self) {
	if (self.serial_echo) io::eprintf("%c", self.io[0x01]); // the byte being sent
	self.serial_active = true;
	self.serial_bits = 0;
}

// One serial clock edge: SB shifts left, taking in 1 (no cable connected).
// After 8 bits the transfer ends: SC bit 7 clears, serial IRQ.
fn void Mmu.serial_shift(&self) {
	if (!self.serial_active) return;
	self.io[0x01] = (char)((self.io[0x01] << 1) | 1);
	if (++self.serial_bits < 8) return;
	self.serial_active = false;
	self.io[0x02] &= 0x7F;
	self.io[IF_REG - 0xFF00] |= 0x08;
}

fn void Mmu.set_input(&self, char buttons, char dpad) {
	if (self.joypad.set_state(buttons, dpad)) {
		self.io[IF_REG - 0xFF00] |= 0x10;
	}
}

fn void Mmu.tick(&self, char mcycles) {
	uint t = (uint)mcycles * 4;

	for (char i = 0; i < mcycles; i++) self.dma_step();

	timer::TickResult tr = self.timer.tick(t);
	for (uint i = 0; i < tr.serial_edges; i++) self.serial_shift();
	if (tr.timer_irq) self.io[IF_REG - 0xFF00] |= 0x04; // Timer interrupt

	self.request_irq(self.ppu.tick(t));

	self.apu.tick(t, tr.apu_steps);

	if (self.cart && self.cart.has_rtc) self.cart.rtc.tick(t);
}

// PPU interrupt bits (ppu::INT_VBLANK / INT_STAT) -> IF.
fn void Mmu.request_irq(&self, char pirq) {
	if (pirq & ppu::INT_VBLANK) self.io[IF_REG - 0xFF00] |= 0x01;
	if (pirq & ppu::INT_STAT)   self.io[IF_REG - 0xFF00] |= 0x02;
}
