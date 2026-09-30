module mmu;

import timer, ppu, joypad, apu, cart, bootrom, sgb;
import std::io;

const ushort IF_REG   = 0xFF0F;
const ushort DIV_REG  = 0xFF04;
const ushort TIMA_REG = 0xFF05;
const ushort TMA_REG  = 0xFF06;
const ushort TAC_REG  = 0xFF07;
const ushort DMA_REG  = 0xFF46;

const int DMA_STARTUP = 2;
const int DMA_LEN     = 0xA0;

// CGB work RAM: 8 banks of 4 KiB. Banks 0 and 1 live in Mmu.wram (all a DMG
// has), banks 2-7 in Mmu.wram_ext.
const usz WRAM_BANK     = 0x1000;
const usz WRAM_EXT_SIZE = 6 * WRAM_BANK;

// Which Game Boy is emulated. SGB = a DMG inside a Super Game Boy: same
// hardware, plus the SNES side that colours the picture and draws a border.
// SGB2 is the later model: same SNES side, but its Game Boy runs off its own
// crystal at the DMG's speed, and its boot ROM leaves A = $FF.
// CGB = Game Boy Color. Colour features are active only for games that ask
// for them (header $0143 bit 7, see Mmu.cgb_mode); other games run in the
// CGB's DMG compatibility mode.
enum Model : char {
	DMG,
	SGB,
	SGB2,
	CGB,
}

// The DMG's clock, 4 194 304 Hz.
const uint DMG_HZ = 4194304;
// The original SGB derives its Game Boy clock from the SNES master clock
// (21 477 272 Hz / 5), so games run about 2.4% fast on it.
const uint SGB_HZ = 4295454;

fn bool Model.is_sgb(self) => self == SGB || self == SGB2;

// T-cycles per second of real time.
fn uint Model.clock_hz(self) => self == SGB ? SGB_HZ : DMG_HZ;

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
	// The first bytes sent over serial (test ROMs report results there).
	char[1024] serial_log;
	usz    serial_log_len;

	bool boot_active;
	Model model;
	// CGB features on: model CGB and a game that supports them. Every CGB
	// register reads $FF and ignores writes otherwise.
	bool  cgb_mode;
	char* wram_ext;     // CGB: WRAM banks 2-7 (heap, freed by GameBoy.destroy)
	char  svbk;         // $FF70: WRAM bank at $D000 (0 selects 1)
	char  vbk;          // $FF4F: VRAM bank the CPU sees
	char  key0;         // $FF4C: bit 2 = DMG compatibility mode (set by the boot ROM)
	char  key1;         // $FF4D: bit 0 = speed switch armed
	bool  double_speed; // CGB double speed: CPU, timer, serial, OAM DMA at 8 MHz
	char[4] undoc;      // $FF72-$FF75: undocumented CGB registers
	char  rp;           // $FF56: infrared port

	// CGB VRAM DMA ($FF51-$FF55): copies 16-byte blocks into VRAM, either
	// all at once (general purpose) or one block per HBlank (HBlank DMA).
	ushort vdma_src;    // next source address
	ushort vdma_dst;    // next destination, offset into VRAM
	char   vdma_left;   // blocks left - 1 (what $FF55 bits 0-6 read)
	bool   vdma_hblank; // an HBlank DMA is running
	char   vdma_ff55;   // $FF55 read value when no HBlank DMA runs
	int    vdma_stall;  // M-cycles the CPU is held off the bus (Cpu.step)
	sgb::Sgb* sgb;      // non-null in SGB mode (heap, freed by GameBoy.destroy)

	Dma dma;
}

fn char Mmu.get(&self, ushort addr) {
	if (self.flat) return self.flat[addr];

	if (self.boot_active) {
		if (self.model == CGB) {
			if (addr < 0x100 || (addr >= 0x200 && addr < 0x900)) return bootrom::CGB[addr];
		} else if (addr < 0x100) {
			return bootrom::DMG[addr];
		}
	}
	if (addr < 0x8000) return self.cart ? self.cart.read(addr) : self.rom[addr];
	if (addr < 0xA000) return *self.vram_at(addr - 0x8000);
	if (addr < 0xC000) return self.cart ? self.cart.read(addr) : self.extram[addr - 0xA000];
	if (addr < 0xE000) return *self.wram_at(addr - 0xC000);
	if (addr < 0xFE00) return *self.wram_at(addr - 0xE000); // echo RAM
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
	if (addr < 0xA000) { *self.vram_at(addr - 0x8000) = value; return; }
	if (addr < 0xC000) {
		if (self.cart) { self.cart.write(addr, value); } else { self.extram[addr - 0xA000] = value; }
		return;
	}
	if (addr < 0xE000) { *self.wram_at(addr - 0xC000) = value; return; }
	if (addr < 0xFE00) { *self.wram_at(addr - 0xE000) = value; return; }  // echo RAM
	if (addr < 0xFEA0) { self.ppu.oam[addr - 0xFE00] = value; return; }
	if (addr < 0xFF00) { return; }                                    // unusable
	if (addr >= 0xFF10 && addr <= 0xFF3F) { self.apu.write(addr, value); return; }
	if (addr < 0xFF80) { self.io_set(addr, value); return; }
	if (addr < 0xFFFF) { self.hram[addr - 0xFF80] = value; return; }
	self.ie = value;
}

// Work RAM byte at `off` from $C000: bank 0, then the bank SVBK selects.
fn char* Mmu.wram_at(&self, ushort off) {
	if (off < WRAM_BANK || !self.cgb_mode) return &self.wram[off];
	usz bank = (usz)(self.svbk & 7);
	if (bank <= 1) return &self.wram[off];
	return &self.wram_ext[(bank - 2) * WRAM_BANK + (usz)off - WRAM_BANK];
}

// M-cycles the CPU waits per 16-byte VRAM DMA block: the copy takes the same
// real time in both speeds.
fn int Mmu.vdma_block_mcycles(&self) => self.double_speed ? 16 : 8;

// Copy one 16-byte block, advancing source and destination.
fn void Mmu.vdma_block(&self) {
	for (int i = 0; i < 16; i++) {
		*self.vram_at(self.vdma_dst & 0x1FFF) = self.get(self.vdma_src);
		self.vdma_src++;
		self.vdma_dst = (self.vdma_dst + 1) & 0x1FFF;
	}
	self.vdma_stall += self.vdma_block_mcycles();
}

// A write to $FF55: bits 0-6 = blocks - 1, bit 7 = HBlank DMA.
fn void Mmu.vdma_start(&self, char value) {
	if (self.vdma_hblank && (value & 0x80) == 0) {
		// Stopping an HBlank DMA: $FF55 keeps the blocks left, bit 7 set.
		self.vdma_hblank = false;
		self.vdma_ff55 = 0x80 | self.vdma_left;
		return;
	}
	self.vdma_left = value & 0x7F;
	if ((value & 0x80) == 0) {
		// General purpose: everything now, the CPU waits for all of it.
		for (int n = self.vdma_left; n >= 0; n--) self.vdma_block();
		self.vdma_ff55 = 0xFF;
		return;
	}
	self.vdma_hblank = true;
	// With the LCD off there are no HBlanks to wait for: one block goes now.
	if ((self.ppu.lcdc & ppu::LCDC_ENABLE) == 0) self.vdma_hblank_step();
}

// One HBlank DMA block (at the start of an HBlank on a visible line).
fn void Mmu.vdma_hblank_step(&self) {
	if (!self.vdma_hblank) return;
	self.vdma_block();
	if (self.vdma_left == 0) {
		self.vdma_hblank = false;
		self.vdma_ff55 = 0xFF;
		return;
	}
	self.vdma_left--;
}

// CGB palette RAM is out of the CPU's reach while the PPU draws (mode 3).
fn bool Mmu.palette_locked(&self) {
	return (self.ppu.lcdc & ppu::LCDC_ENABLE) != 0 && self.ppu.mode == 3;
}

// Video RAM byte at `off` from $8000 in the bank the CPU sees (VBK).
fn char* Mmu.vram_at(&self, ushort off) {
	if (self.cgb_mode && (self.vbk & 1)) return &self.ppu.vram1[off];
	return &self.ppu.vram[off];
}

fn char Mmu.io_get(&self, ushort addr) {
	if (self.model == CGB) {
		// Some CGB registers exist even in DMG compatibility mode.
		bool c = self.cgb_mode;
		switch (addr) {
			case 0xFF4D: return c ? (char)(self.key1 | 0x7E | (self.double_speed ? 0x80 : 0)) : 0xFF;
			case 0xFF4F: return (char)(c ? self.vbk | 0xFE : 0xFE);
			case 0xFF68: return (char)(self.ppu.bcps | 0x40);
			case 0xFF69:
				if (!c || self.palette_locked()) return 0xFF;
				return self.ppu.bg_pal[self.ppu.bcps & 0x3F];
			case 0xFF6A: return (char)(self.ppu.ocps | 0x40);
			case 0xFF6B:
				if (!c || self.palette_locked()) return 0xFF;
				return self.ppu.obj_pal[self.ppu.ocps & 0x3F];
			case 0xFF6C: return c ? (char)(self.ppu.opri | 0xFE) : 0xFF;
			case 0xFF55:
				if (!c) return 0xFF;
				return self.vdma_hblank ? self.vdma_left : self.vdma_ff55;
			case 0xFF70: return c ? (char)(self.svbk | 0xF8) : 0xFF;
			case 0xFF72:
			case 0xFF73: return self.undoc[addr - 0xFF72];
			case 0xFF74: return c ? self.undoc[2] : 0xFF;
			case 0xFF75: return (char)(self.undoc[3] | 0x8F);
			case 0xFF76: return self.apu.pcm12();
			case 0xFF77: return self.apu.pcm34();
			// Infrared: bit 0 = LED on, bits 6-7 = receiver enable, bit 1 = 0
			// while light is received (never: no other device).
			case 0xFF56: return c ? (char)((self.rp & 0xC1) | 0x3E) : 0xFF;
		}
	}
	switch (addr) {
		case 0xFF00:   return self.p1_read();
		case DIV_REG:  return self.timer.div_reg();
		case TIMA_REG: return self.timer.tima;
		case TMA_REG:  return self.timer.tma;
		case TAC_REG:  return (char)(self.timer.tac | 0xF8);
		case 0xFF40:   return self.ppu.lcdc;
		case 0xFF41:   return (char)(self.ppu.stat | 0x80);
		case 0xFF42:   return self.ppu.cpu_view(0x42, self.ppu.scy);
		case 0xFF43:   return self.ppu.cpu_view(0x43, self.ppu.scx);
		case 0xFF44:   return self.ppu.ly;
		case 0xFF45:   return self.ppu.lyc;
		case 0xFF47:   return self.ppu.cpu_view(0x47, self.ppu.bgp);
		case 0xFF48:   return self.ppu.cpu_view(0x48, self.ppu.obp0);
		case 0xFF49:   return self.ppu.cpu_view(0x49, self.ppu.obp1);
		case 0xFF4A:   return self.ppu.cpu_view(0x4A, self.ppu.wy);
		case 0xFF4B:   return self.ppu.cpu_view(0x4B, self.ppu.wx);
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
	if (self.model == CGB) {
		bool c = self.cgb_mode;
		switch (addr) {
			case 0xFF4D: if (c) self.key1 = value & 0x01; return;
			case 0xFF4F: if (c) self.vbk = value & 0x01;  return;
			case 0xFF68: self.ppu.bcps = value & 0xBF; return;
			// Palette data writes during mode 3 are lost, but still advance
			// the index.
			case 0xFF69:
				if (!c) return;
				if (self.palette_locked()) { ppu::pal_advance(&self.ppu.bcps); return; }
				ppu::pal_write(&self.ppu.bg_pal, &self.ppu.bcps, value);
				return;
			case 0xFF6A: self.ppu.ocps = value & 0xBF; return;
			case 0xFF6B:
				if (!c) return;
				if (self.palette_locked()) { ppu::pal_advance(&self.ppu.ocps); return; }
				ppu::pal_write(&self.ppu.obj_pal, &self.ppu.ocps, value);
				return;
			case 0xFF6C: if (c) self.ppu.opri = value & 0x01; return;
			case 0xFF51: if (c) self.vdma_src = (self.vdma_src & 0x00FF) | ((ushort)value << 8); return;
			case 0xFF52: if (c) self.vdma_src = (self.vdma_src & 0xFF00) | (value & 0xF0); return;
			case 0xFF53: if (c) self.vdma_dst = (self.vdma_dst & 0x00FF) | ((ushort)(value & 0x1F) << 8); return;
			case 0xFF54: if (c) self.vdma_dst = (self.vdma_dst & 0x1F00) | (value & 0xF0); return;
			case 0xFF55: if (c) self.vdma_start(value); return;
			case 0xFF70: if (c) self.svbk = value & 0x07; return;
			case 0xFF72:
			case 0xFF73: self.undoc[addr - 0xFF72] = value; return;
			case 0xFF74: if (c) self.undoc[2] = value; return;
			case 0xFF75: self.undoc[3] = value & 0x70; return;
			case 0xFF56: if (c) self.rp = value & 0xC1; return;
		}
	}
	switch (addr) {
		case 0xFF00:
			if (self.sgb) self.sgb.write_p1(value); // SGB command packets / multiplayer
			self.joypad.write(value);
		case 0xFF01:   self.io[0x01] = value; // SB
		case 0xFF02:   // SC: bit 7 = start, bit 0 = internal clock
			self.io[0x02] = value;
			if ((value & 0x81) == 0x81) self.serial_start();
		case DIV_REG:  self.timer.write_div();
		case TIMA_REG: self.timer.write_tima(value);
		case TMA_REG:  self.timer.write_tma(value);
		case TAC_REG:  self.timer.write_tac(value);
		case 0xFF40:
			self.ppu.write_render_reg(0x40, value);
			self.ppu.write_lcdc(value);
		case 0xFF41:   self.request_irq(self.ppu.write_stat(value));
		case 0xFF42:   self.ppu.write_render_reg(0x42, value);
		case 0xFF43:   self.ppu.write_render_reg(0x43, value);
		case 0xFF44:   break; // LY is read-only
		case 0xFF45:   self.request_irq(self.ppu.write_lyc(value));
		case DMA_REG:  self.io[DMA_REG - 0xFF00] = value; self.dma_request(value);
		case 0xFF47:   self.ppu.write_render_reg(0x47, value);
		case 0xFF48:   self.ppu.write_render_reg(0x48, value);
		case 0xFF49:   self.ppu.write_render_reg(0x49, value);
		case 0xFF4A:   self.ppu.write_render_reg(0x4A, value);
		case 0xFF4B:   self.ppu.write_render_reg(0x4B, value);
		case 0xFF50:   // unmap the boot ROM
			if (value == 0 || !self.boot_active) break;
			self.boot_active = false;
			// The CGB boot ROM chose DMG compatibility mode through KEY0.
			if (self.model == CGB && (self.key0 & 0x04) != 0) self.enter_compat_mode();
		case 0xFF4C:   // KEY0: writable only while the CGB boot ROM runs
			if (self.model == CGB && self.boot_active) self.key0 = value;
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
	if (self.serial_log_len < self.serial_log.len) self.serial_log[self.serial_log_len++] = self.io[0x01];
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

// P1 as the game reads it. On an SGB in multiplayer mode the low nibble shows
// the current joypad id while no row is selected, and joypads 2-4 (nothing
// connected here) read as no buttons pressed.
fn char Mmu.p1_read(&self) {
	char v = self.joypad.read();
	if (!self.sgb) return v;
	if ((v & 0x30) == 0x30) return (v & 0xF0) | self.sgb.joypad_id();
	if (self.sgb.player != 0) return v | 0x0F;
	return v;
}

fn void Mmu.set_input(&self, char buttons, char dpad) {
	if (self.joypad.set_state(buttons, dpad)) {
		self.io[IF_REG - 0xFF00] |= 0x10;
	}
}

// A CGB running a DMG game: the CGB registers lock, and the PPU draws like a
// DMG's, coloured through palette RAM (BG palette 0, OBJ palettes 0 and 1).
fn void Mmu.enter_compat_mode(&self) {
	self.cgb_mode = false;
	self.ppu.cgb = false;
	self.ppu.compat = true;
	self.ppu.opri = 1; // DMG object priority (by X)
	self.vbk = 0;
	self.svbk = 0;
}

// Switch CGB double speed on or off (STOP with KEY1 bit 0 set).
fn void Mmu.set_double_speed(&self, bool on) {
	self.double_speed = on;
	self.timer.double_speed = on;
	self.key1 = 0;
}

fn void Mmu.tick(&self, char mcycles) {
	uint t = (uint)mcycles * 4;
	// In double speed an M-cycle is half as long: the timer, serial port and
	// OAM DMA follow the CPU clock, the PPU, APU and cartridge clock keep
	// real time and see half the T-cycles.
	uint rt = self.double_speed ? t / 2 : t;

	for (char i = 0; i < mcycles; i++) self.dma_step();

	timer::TickResult tr = self.timer.tick(t);
	for (uint i = 0; i < tr.serial_edges; i++) self.serial_shift();
	if (tr.timer_irq) self.io[IF_REG - 0xFF00] |= 0x04; // Timer interrupt

	char pirq = self.ppu.tick(rt);
	if (self.ppu.hblank_start) {
		self.ppu.hblank_start = false;
		if (self.cgb_mode) self.vdma_hblank_step();
	}
	// An SGB reads *_TRN data out of the frame that has just been shown.
	if (self.sgb && (pirq & ppu::INT_VBLANK)) self.sgb.capture_transfer(&self.ppu);
	self.request_irq(pirq);

	self.apu.tick(rt, tr.apu_steps);

	if (self.cart && self.cart.has_rtc) self.cart.rtc.tick(rt);
}

// PPU interrupt bits (ppu::INT_VBLANK / INT_STAT) -> IF.
fn void Mmu.request_irq(&self, char pirq) {
	if (pirq & ppu::INT_VBLANK) self.io[IF_REG - 0xFF00] |= 0x01;
	if (pirq & ppu::INT_STAT)   self.io[IF_REG - 0xFF00] |= 0x02;
}
