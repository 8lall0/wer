// This file follows mGBA's Sachen mappers (src/gb/mbc/unlicensed.c,
// Copyright (c) 2013-2022 Jeffrey Pfau), so unlike the rest of wer it is
// under the Mozilla Public License 2.0: https://mozilla.org/MPL/2.0/.
module cart;

// Sachen's unlicensed cartridges (MMC1 and, for the later CGB-capable ones,
// MMC2). Banks: the cartridge can be cut into several games by a base bank
// and a mask, both writable only while the bank register's bits 4-5 are set:
//   $0000-$1FFF  base bank (also $0000-$3FFF's bank, base & mask)
//   $2000-$3FFF  bank for $4000-$7FFF (0 means 1), mixed with the base under the mask
//   $4000-$5FFF  mask
// The Nintendo logo check: reads of $0100-$01FF always go through scrambled
// address lines, and until the boot ROM has read there $31 times, also come
// from $0180-$01FF, where the real logo sits (the game's own is at $0104).
// wer's boot ROMs read the logo fewer times than Nintendo's: the cartridge
// unlocks when the boot ROM hands over (Mmu, $FF50), or at once without one.

struct Sachen {
	bool locked;
	int  reads;           // of $01xx while locked
	char mask;
	char unmasked_bank;
	char base_bank;
}

// The header's logo where these cartridges keep it: scrambled (MMC1), or
// also moved to $0184 (MMC2).
fn bool is_sachen_mmc1(char[] rom) => rom.len > 0x150 && rom[0x104] == 0xCE && rom[0x144] == 0xED && rom[0x114] == 0x66;
fn bool is_sachen_mmc2(char[] rom) => rom.len > 0x200 && rom[0x184] == 0xCE && rom[0x1C4] == 0xED && rom[0x194] == 0x66;

fn void Cartridge.sachen_control(&self, ushort addr, char value) {
	Sachen* s = &self.sachen;
	bool open = (s.unmasked_bank & 0x30) == 0x30;
	switch (addr >> 13) {
		case 0:
			if (open) s.base_bank = value;
		case 1:
			s.unmasked_bank = value ? value : 1;
		case 2:
			if (open) s.mask = value;
		default:
			return;
	}
	self.rom_bank = (s.unmasked_bank & ~s.mask) | (s.base_bank & s.mask);
}

fn usz Cartridge.sachen_rom_offset(&self, ushort addr) {
	Sachen* s = &self.sachen;
	if ((addr & 0xFF00) == 0x0100) {
		if (s.locked) {
			if (++s.reads == 0x31) {
				s.locked = false;
			} else {
				addr |= 0x80;
			}
		}
		addr = sachen_unscramble(addr);
	}
	uint bank = addr < 0x4000 ? (uint)(s.base_bank & s.mask) : self.rom_bank;
	return (usz)wrap_bank(bank, self.rom.len, 0x4000) * 0x4000 + (usz)(addr & 0x3FFF);
}

fn ushort sachen_unscramble(ushort addr) {
	ushort a = addr & 0xFFAC;
	a |= (addr & 0x40) >> 6;
	a |= (addr & 0x10) >> 3;
	a |= (addr & 0x02) << 3;
	a |= (addr & 0x01) << 6;
	return a;
}
