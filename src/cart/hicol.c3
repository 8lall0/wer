module cart;

// The "GB HiCol" multicart menu (Shuma Bao Long Zhuanji 10 in 1): worked out
// from what its menu writes, with nothing to go by (MAME lists the cart as
// not supported, hhugboy doesn't know it).
//   $7000  the game's base, in 32 KiB units
//   $7001  which of those bits the base sets (the rest come from the game's
//          own bank number): $FF a 32 KiB game, $E0 1 MiB
//   $7002  bits 0-3 the game's 32 KiB of RAM; bits 5-6 both set: MBC1-style
//          bank writes ($2000-$3FFF, 0 means 1, but all 8 bits kept), else
//          MBC5's; bit 7 (always set) resets the console into the game
// The reset is what lets a colour game see a CGB: the menu jumps to $0100
// with A = 1 (Digimon D-3 then picks DMG palettes), the boot ROM leaves $11.
// Once the game runs, $7000-$7002 are its own (an MBC1 game's mode register).
// Digimon D-3 (game 4) comes from a SKOB LEE8 cart and shuffles its bank
// numbers itself; its $5001 write (LEE8's mode) does nothing here.

struct HiCol {
	bool locked;
	char base;
	char mask;
	char mode;
	char ram_page;  // $4000-$5FFF, within the game's RAM
}

fn bool is_hicol(char[] rom) => rom.len >= 0x8000 && (String)rom[0x134 : 8] == "GB HiCol";

fn bool Cartridge.hicol_mbc1(&self) => !self.hicol.locked || (self.hicol.mode & 0x60) == 0x60;

fn void Cartridge.hicol_ram(&self) {
	self.ram_bank = (uint)(self.hicol.mode & 0x0F) << 2 | (self.hicol.ram_page & 3);
}

fn usz Cartridge.hicol_rom_offset(&self, ushort addr) {
	HiCol* h = &self.hicol;
	char mask = h.locked ? h.mask : 0; // the menu's own banks until $7002
	uint fixed = (uint)(h.base & mask) << 1;
	uint free = ~((uint)mask << 1) & 0x1FF;
	uint bank = addr < 0x4000 ? fixed : fixed | (self.rom_bank & free);
	return (usz)wrap_bank(bank, self.rom.len, 0x4000) * 0x4000 + (usz)(addr & 0x3FFF);
}

fn void Cartridge.hicol_control(&self, ushort addr, char value) {
	HiCol* h = &self.hicol;
	if (!h.locked && addr >= 0x7000 && addr < 0x8000) {
		switch (addr & 3) {
			case 0: h.base = value;
			case 1: h.mask = value;
			case 2:
				h.mode = value;
				h.locked = true;
				self.hicol_ram();
				if (value & 0x80) self.reset_request = true;
			default: break;
		}
		return;
	}
	if (self.hicol_mbc1() && addr >= 0x2000 && addr < 0x4000) {
		self.rom_bank = value ? value : 1;
		return;
	}
	if ((addr & 0xF003) == 0x5001) return;
	if (addr >= 0x4000 && addr < 0x6000) {
		h.ram_page = value & 3;
		self.hicol_ram();
		return;
	}
	if (addr >= 0x6000) return;
	self.mbc5_control(addr, value);
}
