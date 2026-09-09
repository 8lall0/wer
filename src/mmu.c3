module mmu;

import timer;

const ushort IF_REG   = 0xFF0F;
const ushort DIV_REG  = 0xFF04;
const ushort TIMA_REG = 0xFF05;
const ushort TMA_REG  = 0xFF06;
const ushort TAC_REG  = 0xFF07;

struct Mmu {
	char[0x8000] rom;    // 0000-7FFF  TODO: cartridge + MBC
	char[0x2000] vram;   // 8000-9FFF
	char[0x2000] extram; // A000-BFFF  TODO: cartridge RAM
	char[0x2000] wram;   // C000-DFFF  (+ E000-FDFF echo)
	char[0xA0]   oam;    // FE00-FE9F
	char[0x80]   io;     // FF00-FF7F
	char[0x7F]   hram;   // FF80-FFFE
	char         ie;     // FFFF
	timer::Timer timer;
	char*        flat;   // non-null => linear (test) mode
}

fn char Mmu.get(&self, ushort addr) {
	if (self.flat) return self.flat[addr];

	if (addr < 0x8000) return self.rom[addr];
	if (addr < 0xA000) return self.vram[addr - 0x8000];
	if (addr < 0xC000) return self.extram[addr - 0xA000];
	if (addr < 0xE000) return self.wram[addr - 0xC000];
	if (addr < 0xFE00) return self.wram[addr - 0xE000]; // echo RAM
	if (addr < 0xFEA0) return self.oam[addr - 0xFE00];
	if (addr < 0xFF00) return 0xFF;                     // unusable
	if (addr < 0xFF80) return self.io_get(addr);
	if (addr < 0xFFFF) return self.hram[addr - 0xFF80];
	return self.ie;
}

fn void Mmu.set(&self, ushort addr, char value) {
	if (self.flat) { self.flat[addr] = value; return; }

	if (addr < 0x8000) { self.rom[addr] = value; return; }            // TODO: MBC
	if (addr < 0xA000) { self.vram[addr - 0x8000] = value; return; }
	if (addr < 0xC000) { self.extram[addr - 0xA000] = value; return; }
	if (addr < 0xE000) { self.wram[addr - 0xC000] = value; return; }
	if (addr < 0xFE00) { self.wram[addr - 0xE000] = value; return; }  // echo RAM
	if (addr < 0xFEA0) { self.oam[addr - 0xFE00] = value; return; }
	if (addr < 0xFF00) { return; }                                    // unusable
	if (addr < 0xFF80) { self.io_set(addr, value); return; }
	if (addr < 0xFFFF) { self.hram[addr - 0xFF80] = value; return; }
	self.ie = value;
}

fn char Mmu.io_get(&self, ushort addr) {
	switch (addr) {
		case DIV_REG:  return self.timer.div();
		case TIMA_REG: return self.timer.tima;
		case TMA_REG:  return self.timer.tma;
		case TAC_REG:  return (char)(self.timer.tac | 0xF8);
		default:       return self.io[addr - 0xFF00];
	}
}

fn void Mmu.io_set(&self, ushort addr, char value) {
	switch (addr) {
		case DIV_REG:  self.timer.write_div();
		case TIMA_REG: self.timer.tima = value;
		case TMA_REG:  self.timer.tma = value;
		case TAC_REG:  self.timer.write_tac(value);
		default:       self.io[addr - 0xFF00] = value;
	}
}

// Advance peripherals by `mcycles` machine cycles (called after each CPU step).
fn void Mmu.tick(&self, char mcycles) {
	if (self.timer.tick((uint)mcycles * 4)) {
		self.io[IF_REG - 0xFF00] |= 0x04; // request Timer interrupt
	}
}
