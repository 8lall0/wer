module mmu;

import timer, ppu, joypad, apu, cart, bootrom;
import std::io;

const ushort IF_REG   = 0xFF0F;
const ushort DIV_REG  = 0xFF04;
const ushort TIMA_REG = 0xFF05;
const ushort TMA_REG  = 0xFF06;
const ushort TAC_REG  = 0xFF07;
const ushort DMA_REG  = 0xFF46;

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

	bool   serial_pending;
	bool   serial_echo;   // when true, print each transferred byte to stderr

	bool boot_active;
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
		default:       return self.io[addr - 0xFF00];
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
			if ((value & 0x81) == 0x81) self.serial_pending = true;
		case DIV_REG:  self.timer.write_div();
		case TIMA_REG: self.timer.write_tima(value);
		case TMA_REG:  self.timer.tma = value;
		case TAC_REG:  self.timer.write_tac(value);
		case 0xFF40:   self.ppu.write_lcdc(value);
		case 0xFF41:   self.ppu.stat = (self.ppu.stat & 0x87) | (value & 0x78);
		case 0xFF42:   self.ppu.scy = value;
		case 0xFF43:   self.ppu.scx = value;
		case 0xFF44:   break; // LY is read-only
		case 0xFF45:   self.ppu.lyc = value;
		case DMA_REG:  self.io[DMA_REG - 0xFF00] = value; self.oam_dma(value);
		case 0xFF47:   self.ppu.bgp = value;
		case 0xFF48:   self.ppu.obp0 = value;
		case 0xFF49:   self.ppu.obp1 = value;
		case 0xFF4A:   self.ppu.wy = value;
		case 0xFF4B:   self.ppu.wx = value;
		case 0xFF50:   if (value != 0) self.boot_active = false; // unmap boot ROM
		default:       self.io[addr - 0xFF00] = value;
	}
}

fn void Mmu.oam_dma(&self, char page) {
	ushort src = (ushort)page << 8;
	for (int i = 0; i < 0xA0; i++) {
		self.ppu.oam[i] = self.get(src + (ushort)i);
	}
}

fn void Mmu.set_input(&self, char buttons, char dpad) {
	if (self.joypad.set_state(buttons, dpad)) {
		self.io[IF_REG - 0xFF00] |= 0x10;
	}
}

fn void Mmu.tick(&self, char mcycles) {
	uint t = (uint)mcycles * 4;

	if (self.serial_pending) {
		self.serial_pending = false;
		if (self.serial_echo) io::eprintf("%c", self.io[0x01]);
		self.io[0x01] = 0xFF;                 // received byte (no cable)
		self.io[0x02] &= 0x7F;                // clear transfer-start
		self.io[IF_REG - 0xFF00] |= 0x08;     // Serial interrupt
	}

	timer::TickResult tr = self.timer.tick(t);
	if (tr.timer_irq) self.io[IF_REG - 0xFF00] |= 0x04; // Timer interrupt

	char pirq = self.ppu.tick(t);
	if (pirq & ppu::INT_VBLANK) self.io[IF_REG - 0xFF00] |= 0x01;
	if (pirq & ppu::INT_STAT)   self.io[IF_REG - 0xFF00] |= 0x02;

	self.apu.tick(t, tr.apu_steps);
}
