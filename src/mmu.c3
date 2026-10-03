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
	// A conflicting CPU write changes the byte copied this M-cycle into
	// `alter_value`, or ANDs it with that (Mmu.dma_conflict_write).
	bool   alter;
	bool   alter_and;
	char   alter_value;
}

struct Mmu {
	char[0x8000] rom;      // 0000-7FFF fallback when there is no MBC cartridge
	char[0x2000] extram;   // A000-BFFF fallback
	bool         has_extram; // a cartridge without MBC but with RAM (types $08/$09); else $A000-$BFFF is open bus
	cart::Cartridge* cart; // non-null once an MBC ROM is loaded; owns ROM+RAM
	char[0x2000] wram;   // C000-DFFF  (+ E000-FDFF echo)
	char[0x80]   io;     // FF00-FF7F
	char[0x7F]   hram;   // FF80-FFFE
	char[0x60]   extra_oam; // FEA0-FEFF on a CGB (revision C: RAM, address bits 3-4 ignored)
	char         ie;     // FFFF
	timer::Timer   timer;
	ppu::Ppu       ppu;    // owns VRAM (8000-9FFF) and OAM (FE00-FE9F)
	joypad::Joypad joypad;
	apu::Apu       apu;    // owns the sound registers + wave RAM (FF10-FF3F)
	char*          flat;   // non-null => linear (test) mode

	bool   serial_active; // internal-clock transfer in progress
	int    serial_bits;   // bits shifted so far (0..8)
	int    serial_left;   // T-cycles (DIV counts) until the transfer ends, 0: none
	bool   serial_fast;   // CGB fast clock (SC bit 1)
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
	ushort vdma_dst;    // next destination ($FF53 high byte unmasked; VRAM at & $1FFF)
	char   vdma_left;   // blocks left - 1 (what $FF55 bits 0-6 read)
	bool   vdma_hblank; // an HBlank DMA is running
	char   vdma_ff55;   // $FF55 read value when no HBlank DMA runs
	bool   cpu_halted;  // the CPU is in HALT (Cpu.step)
	bool   hdma_hold;   // ... or about to be (a speed switch): no HBlank DMA requests
	bool   hdma_refund; // the next HBlank DMA block stalls the CPU an M-cycle less
	int    timer_hold;  // M-cycles the timer stands still (CGB speed switch, Cpu.stop)
	bool   hdma_due;    // an HBlank DMA block goes at the next instruction boundary (Cpu.step)
	char   halt_hdma;   // HDMA state as HALT began: 0 low, 1 in HBlank, 2 a block was due, 3 the same at a speed switch (Gambatte)
	int    vdma_stall;  // M-cycles the CPU is held off the bus (Cpu.step)
	char   ack_bit;     // the interrupt just acknowledged: dropped if raised again within a cycle or two
	bool   if_written;  // the CPU wrote IF: it overrides what the PPU raises in the next dot (Gambatte)
	bool   irq_early;   // the PPU raised an interrupt early enough in the last tick
	int    ppu_freeze;  // dots the PPU stands still (right after a CGB speed switch)
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
	if (addr < 0xC000) return self.cart ? self.cart.read(addr) : (self.has_extram ? self.extram[addr - 0xA000] : 0xFF);
	if (addr < 0xE000) return *self.wram_at(addr - 0xC000);
	if (addr < 0xFE00) return *self.wram_at(addr - 0xE000); // echo RAM
	if (addr < 0xFEA0) return self.ppu.oam[addr - 0xFE00];
	if (addr < 0xFF00) {
		// Unused: $00 on a DMG; a CGB (C) has RAM here (Gambatte oamdma_*_busypushFF01).
		return self.model == CGB ? self.extra_oam[(addr & ~0x18) - 0xFEA0] : 0;
	}
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
		if (self.cart) {
			self.cart.write(addr, value);
		} else if (self.has_extram) {
			self.extram[addr - 0xA000] = value;
		}
		return;
	}
	if (addr < 0xE000) { *self.wram_at(addr - 0xC000) = value; return; }
	if (addr < 0xFE00) { *self.wram_at(addr - 0xE000) = value; return; }  // echo RAM
	if (addr < 0xFEA0) { self.ppu.oam[addr - 0xFE00] = value; return; }
	if (addr < 0xFF00) {                                              // unused
		if (self.model == CGB) self.extra_oam[(addr & ~0x18) - 0xFEA0] = value;
		return;
	}
	if (addr >= 0xFF10 && addr <= 0xFF3F) {
		self.apu.div_counter = self.timer.div;
		self.apu.write(addr, value);
		return;
	}
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
// Each VRAM DMA run (a whole general purpose one, or one HBlank block) holds
// the CPU this much longer than its blocks (Gambatte Memory::dma: + 4 cycles).
const int VDMA_OVERHEAD = 1;
fn int Mmu.vdma_block_mcycles(&self) => self.double_speed ? 16 : 8;

// Copy one 16-byte block, advancing source and destination.
fn void Mmu.vdma_block(&self) {
	for (int i = 0; i < 16; i++) {
		// From VRAM or $E000 on the DMA reads the cartridge bus, pulled up
		// to $FF by then (Gambatte Memory::dma, cartBus).
		ushort src = self.vdma_src;
		char b = (src >= 0x8000 && src < 0xA000) || src >= 0xE000 ? 0xFF : self.get(src);
		*self.vram_at(self.vdma_dst & 0x1FFF) = b;
		self.vdma_src++;
		self.vdma_dst++;
	}
	self.vdma_stall += self.vdma_block_mcycles();
}

// A write to $FF55: bits 0-6 = blocks - 1, bit 7 = HBlank DMA.
fn void Mmu.vdma_start(&self, char value) {
	if (self.vdma_hblank && (value & 0x80) == 0) {
		// Stopping an HBlank DMA. The write still sets the length, so $FF55
		// reads bit 7 set and the length just written (SameSuite
		// hdma_lcd_off: stopping with 0 reads $80).
		self.vdma_hblank = false;
		self.vdma_ff55 = 0x80 | (value & 0x7F);
		return;
	}
	self.vdma_left = value & 0x7F;
	if ((value & 0x80) == 0) {
		// General purpose: everything now, the CPU waits for all of it.
		// The destination running past $FFFF ends it (Gambatte Memory::dma).
		self.vdma_ff55 = 0xFF;
		for (int n = self.vdma_left; n >= 0; n--) {
			self.vdma_block();
			if (self.vdma_dst == 0) {
				self.vdma_ff55 = 0x80 | (char)((n - 1) & 0x7F);
				break;
			}
		}
		self.vdma_stall += VDMA_OVERHEAD;
		return;
	}
	self.vdma_hblank = true;
	// With the LCD off there are no HBlanks to wait for, and started during
	// HBlank it doesn't wait for the next one: one block goes now.
	if ((self.ppu.lcdc & ppu::LCDC_ENABLE) == 0 || self.in_hblank()) self.hdma_due = true;
}

// Gambatte isHdmaPeriod(now): a visible line from its mode 0 time to 3 cycles
// before LY changes.
fn bool Mmu.hdma_period(&self) {
	ppu::Ppu* p = &self.ppu;
	if ((p.lcdc & ppu::LCDC_ENABLE) == 0 || p.line >= ppu::VBLANK_LINE || p.first_line) return false;
	bool ds = p.double_speed;
	return p.dot > ppu::MODE3_START_DOT && p.dot >= p.m0_stat_dot() + (ds ? 1 : 2) && p.dot < 453;
}

// HALT begins: a due HBlank DMA block waits for the wake-up (Gambatte Memory::halt).
fn void Mmu.hdma_halt(&self) {
	if (!self.cgb_mode) return;
	self.halt_hdma = (self.vdma_hblank && self.hdma_period()) ? 1 : 0;
	if (self.hdma_due) self.halt_hdma = 2;
	self.hdma_due = false;
}

// A speed switch halts the CPU (Gambatte Memory::stop): going to double
// speed a block already requested is not dropped (it runs while halted, which
// ends the HBlank DMA); going back to normal speed it waits for the wake-up.
fn void Mmu.hdma_stop(&self, bool to_double) {
	if (!self.cgb_mode) return;
	bool requested = self.hdma_due;
	self.halt_hdma = (self.vdma_hblank && self.hdma_period()) ? 1 : 0;
	if (requested && !to_double) self.halt_hdma = 3;
	if (!(requested && to_double)) self.hdma_due = false;
}

// The CPU wakes: the block it held back, or one for an HBlank HALT slept into.
fn void Mmu.hdma_unhalt(&self) {
	if (!self.cgb_mode) return;
	if ((self.vdma_hblank && self.hdma_period() && self.halt_hdma == 0) || self.halt_hdma >= 2) self.hdma_due = true;
	// A block held back by a speed switch gives the CPU an M-cycle back
	// (Gambatte Memory::event, intevent_dma: cc -= 4; after a plain HALT our
	// wake-up cycle already accounts for it).
	if (self.halt_hdma == 3) self.hdma_refund = true;
	self.halt_hdma = 0;
}

// One HBlank DMA block (at the start of an HBlank on a visible line).
// True in a visible line's HBlank as an HDMA enable sees it.
fn bool Mmu.in_hblank(&self) {
	// Gambatte isHdmaPeriod(cc + 4): from 2 cycles before STAT reads mode 0
	// until 7 cycles before LY changes.
	ppu::Ppu* p = &self.ppu;
	if (p.line >= ppu::VBLANK_LINE || p.first_line) return false;
	bool ds = p.double_speed;
	return p.dot > ppu::MODE3_START_DOT && p.dot >= p.m0_stat_dot() - (ds ? 1 : 2) && p.dot < (ds ? 451 : 449);
}

fn void Mmu.vdma_hblank_step(&self, bool halted) {
	if (!self.vdma_hblank) {
		// Stopped after this block was requested: it still goes, and counts
		// down the length written with the stop (Gambatte Memory::dma).
		self.vdma_block();
		self.vdma_stall += VDMA_OVERHEAD;
		self.vdma_ff55 = 0x80 | ((self.vdma_ff55 - 1) & 0x7F);
		return;
	}
	self.vdma_block();
	self.vdma_stall += VDMA_OVERHEAD;
	if (self.hdma_refund) {
		self.hdma_refund = false;
		self.vdma_stall--;
	}
	// A block copied while the CPU is halted ends the HBlank DMA, the length
	// left as it was (Gambatte Memory::dma).
	if (halted) {
		self.vdma_hblank = false;
		self.vdma_ff55 = 0x80 | self.vdma_left;
		return;
	}
	if (self.vdma_left == 0 || self.vdma_dst == 0) {
		// Done, or the destination ran past $FFFF.
		self.vdma_hblank = false;
		self.vdma_ff55 = 0x80 | ((self.vdma_left - 1) & 0x7F);
		return;
	}
	self.vdma_left--;
}

// DMG OAM corruption bug (Pan Docs "OAM Corruption Bug"): during mode 2 the
// PPU reads OAM a row (8 bytes, 4 words) per M-cycle; a CPU access to
// $FE00-$FEFF, or the 16-bit incrementer pointing there, in that M-cycle
// corrupts the row being read. Not on a CGB.
int oam_bug_row_offset = 4; // dot offset of the PPU's row (calibrated on Blargg oam_bug)

fn void Mmu.oam_bug(&self, bool read, bool write) {
	if (self.model == CGB) return;
	if ((self.ppu.lcdc & ppu::LCDC_ENABLE) == 0 || self.ppu.mode != 2) return;
	if (self.ppu.line >= ppu::VBLANK_LINE) return;
	int row = (self.ppu.dot + oam_bug_row_offset) / 4;
	if (row < 1 || row > 19) return;   // the first row is never affected
	if (read && write) {
		self.oam_bug_read_idu(row);
	} else if (read) {
		self.oam_bug_read(row);
	} else {
		self.oam_bug_write(row);
	}
}

fn ushort Mmu.oam_word(&self, int row, int word) {
	int at = row * 8 + word * 2;
	return (ushort)(self.ppu.oam[at] | (ushort)self.ppu.oam[at + 1] << 8);
}

fn void Mmu.set_oam_word(&self, int row, int word, ushort v) {
	int at = row * 8 + word * 2;
	self.ppu.oam[at] = (char)v;
	self.ppu.oam[at + 1] = (char)(v >> 8);
}

// Words 1-3 of the row become those of the row before.
fn void Mmu.oam_copy_tail(&self, int row) {
	for (int w = 1; w < 4; w++) self.set_oam_word(row, w, self.oam_word(row - 1, w));
}

fn void Mmu.oam_bug_write(&self, int row) {
	ushort a = self.oam_word(row, 0);
	ushort b = self.oam_word(row - 1, 0);
	ushort c = self.oam_word(row - 1, 2);
	self.set_oam_word(row, 0, ((a ^ c) & (b ^ c)) ^ c);
	self.oam_copy_tail(row);
}

fn void Mmu.oam_bug_read(&self, int row) {
	ushort a = self.oam_word(row, 0);
	ushort b = self.oam_word(row - 1, 0);
	ushort c = self.oam_word(row - 1, 2);
	self.set_oam_word(row, 0, b | (a & c));
	self.oam_copy_tail(row);
}

// A read and an increment in the same M-cycle.
fn void Mmu.oam_bug_read_idu(&self, int row) {
	if (row >= 4 && row < 19) {
		ushort a = self.oam_word(row - 2, 0);
		ushort b = self.oam_word(row - 1, 0);
		ushort c = self.oam_word(row, 0);
		ushort d = self.oam_word(row - 1, 2);
		self.set_oam_word(row - 1, 0, (b & (a | c | d)) | (a & c & d));
		for (int w = 0; w < 4; w++) {
			ushort v = self.oam_word(row - 1, w);
			self.set_oam_word(row, w, v);
			self.set_oam_word(row - 2, w, v);
		}
	}
	self.oam_bug_read(row);
}

fn bool Mmu.palette_locked(&self) => self.ppu.palette_locked();

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
		case TIMA_REG: return self.timer.read_tima();
		case TMA_REG:  return self.timer.tma;
		case TAC_REG:  return (char)(self.timer.tac | 0xF8);
		case 0xFF40:   return self.ppu.lcdc;
		case 0xFF41:   return (char)((self.ppu.stat & ~ppu::STAT_LYC_FLAG) | (self.ppu.lyc_flag() ? ppu::STAT_LYC_FLAG : 0) | 0x80);
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
		case 0xFF02:   return self.io[0x02] | (self.cgb_mode ? 0x7C : 0x7E); // SC: bits 7, 0 (and 1 in CGB mode)
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
			case 0xFF53: if (c) self.vdma_dst = (self.vdma_dst & 0x00FF) | ((ushort)value << 8); return;
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
		case 0xFF02:   // SC: bit 7 = start, bit 0 = internal clock, CGB bit 1 = fast clock
			self.io[0x02] = self.cgb_mode ? value & 0x83 : value & 0x81;
			// Anything but start + internal clock stops a transfer (with an
			// external clock and no cable, nothing ever shifts it).
			if ((value & 0x81) == 0x81) {
				self.serial_start();
			} else {
				self.serial_active = false;
				self.serial_left = 0;
			}
		case DIV_REG:
			// A DIV reset moves a transfer's end to DIV's new phase (Gambatte).
			if (self.serial_left > 0) {
				int r = self.serial_left;
				int a = (int)self.serial_align();
				r += (-r & (a - 1)) - 2 * (-r & (a / 2));
				self.serial_left = r > 0 ? r : 1;
			}
			self.timer.write_div();
		case TIMA_REG: self.timer.write_tima(value);
		case TMA_REG:  self.timer.write_tma(value);
		case TAC_REG:  self.timer.write_tac(value);
		case 0xFF40:
			self.ppu.write_render_reg(0x40, value);
			self.request_irq(self.ppu.write_lcdc(value));
		case 0xFF41:   self.request_irq(self.ppu.write_stat(value));
		case 0xFF42:   self.ppu.write_render_reg(0x42, value);
		case 0xFF43:   self.ppu.write_render_reg(0x43, value);
		case 0xFF44:   break; // LY is read-only
		case IF_REG:
			self.io[IF_REG - 0xFF00] = value;
			self.if_written = true;
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
	// A DMG's DMA sees $E000-$FFFF as WRAM; a CGB's copies $FF from there.
	if (src >= 0xE000 && self.model != CGB) src -= 0x2000;
	self.dma.pending_source = src;
	self.dma.pending = DMA_STARTUP;
}

fn void Mmu.dma_step(&self) {
	// Gambatte: a halted CPU's OAM DMA stands still (Memory::updateOamDma).
	if (self.cpu_halted) return;
	if (self.dma.pending > 0 && --self.dma.pending == 0) {
		self.dma.active = true;
		self.ppu.oam_dma_from = self.ppu.cc;
		self.ppu.oam_dma_until = ppu::NEVER;
		self.dma.source = self.dma.pending_source;
		self.dma.index = 0;
		return;
	}
	if (!self.dma.active) return;
	char b = self.dma_byte();
	if (self.dma.alter) {
		b = self.dma.alter_and ? b & self.dma.alter_value : self.dma.alter_value;
		self.dma.alter = false;
	}
	self.ppu.oam[self.dma.index] = b;
	if (++self.dma.index == DMA_LEN) {
		self.dma.active = false;
		self.ppu.oam_dma_until = self.ppu.cc;
	}
}

// The address the DMA copies from in this M-cycle, and the byte.
fn ushort Mmu.dma_addr(&self) => self.dma.source + (ushort)self.dma.index;
fn char Mmu.dma_byte(&self) => self.dma_addr() >= 0xE000 ? 0xFF : self.get(self.dma_addr());

// True when the CPU cannot access `addr` normally: OAM, or the bus the DMA
// is reading from. The other bus, IO, HRAM and IE stay usable. On a CGB,
// WRAM is a bus of its own, which clashes with any DMA but one from VRAM,
// and a DMA from $E000 up clashes with everything but VRAM (SameBoy;
// Gambatte oamdma_src*_busy*).
fn bool Mmu.dma_blocks(&self, ushort addr) {
	if (!self.dma.active) return false;
	Bus bus = bus_of(addr);
	if (bus == OAM) return true;
	if (self.model != CGB) return bus == bus_of(self.dma.source);
	if (addr >= 0xFE00) return false;
	ushort src = self.dma_addr();
	if (addr == src) return false;
	if (addr >= 0xC000) return bus_of(src) != VIDEO;
	if (src >= 0xE000) return bus != VIDEO;
	return bus == bus_of(src) && src < 0xC000;
}

// A CPU access to WRAM that clashes with a CGB DMA reaches the WRAM byte
// mixing the DMA's address with its own.
fn ushort Mmu.dma_wram_alias(&self, ushort addr) => (self.dma_addr() & 0x1000) | (addr & 0x0FFF) | 0xC000;

// The DMA on the main bus of a CGB from $E000 up: those accesses go nowhere.
fn bool Mmu.dma_cgb_open(&self, ushort addr) {
	return self.model == CGB && self.dma_addr() >= 0xE000 && addr < 0xC000 && bus_of(addr) == EXTERNAL;
}

// CPU reads and writes to OAM/VRAM are locked at slightly different moments
// (see Ppu.oam_locked, vram_locked, oam_write_locked; Mooneye lcdon_*_timing).
fn bool Mmu.ppu_blocks(&self, ushort addr, bool write) {
	if ((self.ppu.lcdc & ppu::LCDC_ENABLE) == 0) return false;
	if (addr >= 0xFE00 && addr < 0xFF00) {
		return write ? self.ppu.oam_write_locked() : self.ppu.oam_read_locked();
	}
	if (addr >= 0x8000 && addr < 0xA000) {
		return write ? self.ppu.vram_write_locked() : self.ppu.vram_read_locked();
	}
	return false;
}

// What a blocked CPU read sees: $FF for OAM, otherwise the byte the DMA is
// reading on that bus right now (bus conflict); on a CGB, WRAM through the
// DMA's address, or nothing ($FF) from the main bus during a DMA from $E000 up.
fn char Mmu.dma_conflict_read(&self, ushort addr) {
	if (bus_of(addr) == OAM) return 0xFF;
	if (self.model == CGB) {
		if (self.dma_cgb_open(addr)) return 0xFF;
		ushort src = self.dma_addr();
		if (addr >= 0xC000 && (src < 0xC000 || src >= 0xE000)) return self.get(self.dma_wram_alias(addr));
		// Reading VRAM while the DMA does clears the byte it copies
		// (Gambatte oamdma_src8000_busypop9FFF).
		if (bus_of(addr) == VIDEO) {
			self.dma.alter = true;
			self.dma.alter_and = false;
			self.dma.alter_value = 0;
		}
	}
	return self.dma_byte();
}

// A CPU write that clashes with the DMA is lost, but the byte the DMA copies
// in that M-cycle takes the CPU's value (on a CGB also from $E000 up), is
// ANDed with it from a DMG's WRAM, is cleared from a CGB's VRAM. On a CGB,
// WRAM clashes take the write through the DMA's address instead (Gambatte
// oamdma_src*_busypush*).
fn void Mmu.dma_conflict_write(&self, ushort addr, char value) {
	if (bus_of(addr) == OAM) return;
	ushort src = self.dma_addr();
	self.dma.alter = true;
	self.dma.alter_and = false;
	self.dma.alter_value = value;
	if (self.model == CGB) {
		if (self.dma_cgb_open(addr)) return; // lost, but its byte is what the DMA copies
		if (addr >= 0xC000 && (src < 0xC000 || src >= 0xE000)) {
			self.dma.alter = false;
			self.set(self.dma_wram_alias(addr), value);
			return;
		}
		if (src >= 0xC000) {
			self.dma.alter = false;   // WRAM against WRAM: just lost
		} else if (src >= 0x8000 && src < 0xA000) {
			self.dma.alter_value = 0;
		}
		return;
	}
	if (src >= 0xC000) self.dma.alter_and = true;
}

// SC written with start + internal clock. Nothing moves yet: the bits shift
// in as the serial clock runs (Mmu.serial_tick).
fn void Mmu.serial_start(&self) {
	if (self.serial_echo) io::eprintf("%c", self.io[0x01]); // the byte being sent
	if (self.serial_log_len < self.serial_log.len) self.serial_log[self.serial_log_len++] = self.io[0x01];
	self.serial_active = true;
	self.serial_bits = 0;
	// A bit every 512 T-cycles of the DIV count (every 16 with the CGB's fast
	// clock, SC bit 1), the last one 8 periods after the count's last
	// multiple of 256 (8) (Gambatte).
	self.serial_fast = (self.io[0x02] & 0x02) != 0;
	self.serial_left = self.serial_period() * 8 - (int)(self.timer.div & (self.serial_align() - 1));
}

fn int Mmu.serial_period(&self) => self.serial_fast ? 16 : 512;
fn uint Mmu.serial_align(&self) => self.serial_fast ? 8 : 256;

// The serial clock moving on by `t` T-cycles: the bits due by now.
fn void Mmu.serial_tick(&self, uint t) {
	self.serial_left -= (int)t;
	int p = self.serial_period();
	int due = self.serial_left <= 0 ? 8 : 8 - (self.serial_left + p - 1) / p;
	while (self.serial_active && self.serial_bits < due) self.serial_shift();
	if (!self.serial_active) self.serial_left = 0;
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

// WRAM comes up in stripes of $00 and $FF (with a few stray bits, not
// modelled): on a DMG runs of 256 bytes, swapping at $C800; on a CGB runs of
// 8 bytes (bank 2 clear). Some tests read it before writing it (Gambatte
// oamdma_srcFE00_*).
fn void Mmu.power_on_wram(&self) {
	char[0x1000] bank;
	for (int i = 0; i < 0x1000; i++) {
		bool high = i >= 0x800;
		if (self.model == CGB) {
			bank[i] = ((i & 8) != 0) == high ? 0xFF : 0x00;
			if (i >= 0xE00 && (i & 0xF) == 2) bank[i] = 0xFF;
			if (i >= 0xE00 && (i & 0xF) == 0xA) bank[i] = 0x00;
		} else {
			bank[i] = ((i & 0x100) != 0) == high ? 0x00 : 0xFF;
		}
	}
	self.wram[0:0x1000] = bank[..];
	self.wram[0x1000:0x1000] = bank[..];
	if (self.wram_ext) {
		for (int b = 0; b < 6; b++) {
			char* p = self.wram_ext + b * 0x1000;
			if (b == 0) {
				mem::set(p, 0, 0x1000);
			} else {
				mem::copy(p, &bank, 0x1000);
			}
		}
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
	self.apu.double_speed = on;
	self.ppu.double_speed = on;
	if (self.ppu.lcdc & ppu::LCDC_ENABLE) self.ppu.irq_reschedule(false);
	self.key1 = 0;
}

// Dots the PPU stands still right after a CGB speed switch: none going to
// double speed, 6 going back (Gambatte speedchange*, swept; SameBoy has a
// similar short freeze).
const int[2] SWITCH_PPU_FREEZE = { 0, 1 }; // to double, to normal
fn void Mmu.tick(&self, char mcycles) {
	uint t = (uint)mcycles * 4;
	// In double speed an M-cycle is half as long: the timer, serial port and
	// OAM DMA follow the CPU clock, the PPU, APU and cartridge clock keep
	// real time and see half the T-cycles.
	uint rt = self.double_speed ? t / 2 : t;

	for (char i = 0; i < mcycles; i++) self.dma_step();

	timer::TickResult tr;
	if (self.timer_hold > 0) {
		self.timer_hold--;
	} else {
		tr = self.timer.tick(t);
		if (self.serial_left > 0) self.serial_tick(t);
	}
	// An IF write also overrides a timer interrupt in the next 1-2 cycles.
	if (tr.timer_irq && (self.ack_bit & 0x04) && tr.irq_before_end + 2 + (self.model == CGB ? 1 : 0) >= t) tr.timer_irq = false;
	if (tr.timer_irq && self.if_written && tr.irq_before_end + 1 + (self.double_speed ? 1 : 0) >= t) tr.timer_irq = false;
	if (tr.timer_irq) self.io[IF_REG - 0xFF00] |= 0x04; // Timer interrupt

	uint dots = rt;
	if (self.ppu_freeze > 0) {
		uint skip = self.ppu_freeze < (int)dots ? (uint)self.ppu_freeze : dots;
		self.ppu_freeze -= (int)skip;
		dots -= skip;
	}
	char pirq = dots ? self.ppu.tick(dots) : 0;
	// An IF write lands a cycle after the CPU's access (Gambatte: interrupts
	// up to then are overwritten).
	if (self.if_written && self.ppu.irq_dot == 0) pirq = 0;
	if ((pirq & self.ack_bit) && (self.ppu.irq_dot + 1) * (self.double_speed ? 2 : 1) <= 2) pirq &= ~self.ack_bit;
	self.if_written = false;
	self.ack_bit = 0;
	// A halted CPU wakes at the first M-cycle boundary after an interrupt,
	// plus one more M-cycle (Cpu.service_interrupt) - except on a DMG when
	// the interrupt came at least 2 T-cycles before that boundary (Gambatte
	// Memory::event, intevent_interrupts).
	self.irq_early = self.model != CGB && ((pirq != 0 && self.ppu.irq_dot < 2) || (tr.timer_irq && tr.irq_before_end >= 2));
	if (self.ppu.hblank_start) {
		self.ppu.hblank_start = false;
		// Not while the CPU is halted (Gambatte LCD flagHdmaReq): waking up
		// in the HBlank DMA period requests the block (Mmu.hdma_unhalt).
		if (self.cgb_mode && self.vdma_hblank && !self.cpu_halted && !self.hdma_hold) self.hdma_due = true;
	}
	// An SGB reads *_TRN data out of the frame that has just been shown.
	if (self.sgb && (pirq & ppu::INT_VBLANK)) self.sgb.capture_transfer(&self.ppu);
	self.request_irq(pirq);

	self.apu.tick(rt, tr.apu_steps, tr.apu_rises, tr.apu_div_write, false);

	if (self.cart && self.cart.has_rtc) self.cart.rtc.tick(rt);
}

// PPU interrupt bits (ppu::INT_VBLANK / INT_STAT) -> IF.
fn void Mmu.request_irq(&self, char pirq) {
	if (pirq & ppu::INT_VBLANK) self.io[IF_REG - 0xFF00] |= 0x01;
	if (pirq & ppu::INT_STAT)   self.io[IF_REG - 0xFF00] |= 0x02;
}
