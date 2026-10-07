// This file follows mGBA's unlicensed mappers (src/gb/mbc/unlicensed.c and
// the detection in src/gb/mbc.c, src/gb/overrides.c; Copyright (c) 2013-2022
// Jeffrey Pfau), so unlike the rest of wer it is under the Mozilla Public
// License 2.0: https://mozilla.org/MPL/2.0/.
module cart;

// Bootleg cartridges, mostly from China and Taiwan. Their headers name an
// ordinary mapper (or none), so they are known by a second logo at $0184
// (BBD, Hitek, GGB-81, Li Cheng, Sintax) or by their header's CRC (the NT
// boards, Pokemon Jade/Diamond):
//   BBD, Hitek   MBC5 whose ROM data bits ($4000-$7FFF) and bank number bits
//                are shuffled, by modes set at $2001 (data) and $2080 (bank)
//   GGB-81       MBC5, data bits shuffled ($2001)
//   Li Cheng     MBC5 that ignores writes to $2101-$2FFF
//   Sintax       MBC5, bank bits shuffled by a mode ($5x1x), and the ROM data
//                XORed with one of four values ($7x2x-$7x5x), by bank
//   NT old       MBC3 multicarts: a base bank, a bank count, swapped bank
//                bits ($5xxx); type 2 also drives a rumble motor
//   NT new       MBC5 that switches to two 8 KiB banks after a write to $14xx
//                ($2000-$23FF and $2400-$27FF then pick them)
//   PKJD         MBC3 whose RAM window can show two registers the game
//                counts with (a copy protection), modes $0D-$0F at $4000

struct Bootleg {
	// BBD, Hitek, GGB-81
	char data_swap;
	char bank_swap;
	// Sintax
	char sintax_mode;
	char sintax_bank;      // the bank written, before shuffling
	char[4] sintax_xor;
	char sintax_cur_xor;
	// NT old
	uint nt_base;          // in 16 KiB banks
	uint nt_count;         // banks the game sees (0: all)
	bool nt_swapped;
	bool nt_rumble;
	// NT new
	bool nt_split;
	uint[2] nt_half;       // 8 KiB banks at $4000 and $6000 while split
	// PKJD
	char pkjd_reg;         // 0: RAM, 5-6: a counter, 7: the operations port
	char[2] pkjd_counter;
}

// --- detection ---------------------------------------------------------------

faultdef NOT_A_BOOTLEG;

fn Mbc? bootleg_mbc(char[] rom) {
	if (rom.len < 0x8000) return NOT_A_BOOTLEG~;
	switch (crc32(rom[0x100 : 0x50])) {
		case 0x30F8F86C: return PKJD;     // Pokemon Jade Version (Telefang Speed bootleg)
		case 0xE1147E75:                  // Rockman 8
		case 0xEFF88FAA: return NT_OLD1;  // True Color 25 in 1 (NT-9920)
		case 0x811925D9:                  // 23 in 1 (CR2011)
		case 0x62A8016A:                  // 29 in 1 (CR2020), Caise Gedou 29 in 1 (CY2061)
		case 0x5758D6D9:                  // Caise Gedou 24 in 1 (CY2060)
		case 0x80265A64:                  // Rockman X4
		case 0x805459DE:                  // Sonic Adventure 8
		case 0x0B1B808A:                  // Super Donkey Kong 5
		case 0x4650EB9A: return NT_OLD2;  // Super Mario Special 3
		case 0xB289D95A:                  // Capcom vs SNK - Millennium Fight 2001
		case 0x688D6713:                  // Digimon 02 4
		case 0x8931A272:                  // Digimon 2
		case 0x79083C6B:                  // Digimon Pocket
		case 0x0C5047EE:                  // Harry Potter 3
		case 0x8AC634B7:                  // Pokemon Diamond (Special Pikachu Edition)
		case 0x8628A287:                  // Pokemon Jade (Special Pikachu Edition)
		case 0xBC75D7B8:                  // Pokemon - Mewtwo Strikes Back
		case 0xFF0B60CC:                  // Shuma Baolong 02 4
		case 0x14A992A6: return NT_NEW;   // Street Fighter Zero 4
		case 0x3EF5AFB2: return LI_CHENG; // Pokemon Jade Version (Telefang Speed bootleg)
		default: break;
	}
	// The second logo; some were re-released "fixed" (as plain MBC5).
	switch (crc32(rom[0x184 : 0x30])) {
		case 0x4FDAB691:
			return HITEK;
		case 0xC7D8C1DF:
		case 0x6D1EA662: // Garou
			if (rom[0x7FFF] != 0x01) return BBD;
		case 0x79F34594: // DATA.
		case 0x7E8C539B: // TD-SOFT
			return GGB81;
		case 0x20D092E2:
		case 0xD2B57657:
			if (rom[0x147] == 0x01) return LI_CHENG;
			if (rom[0x148] < 9 && (usz)0x8000 << rom[0x148] != rom.len) return LI_CHENG;
		case 0x6C1DCF2D:
		case 0x99E3449D:
			if (rom[0x7FFF] != 0x01) return SINTAX;
		default: break;
	}
	return NOT_A_BOOTLEG~;
}

// The bootlegs that sit on MBC5 (its RAM banks, its rumble types $1C-$1E).
fn bool Mbc.mbc5_like(self) {
	switch (self) {
		case MBC5: case BBD: case HITEK: case GGB81: case LI_CHENG: case SINTAX: case NT_NEW: case SKOB:
			return true;
		default:
			return false;
	}
}

uint[256] crc_table;

fn uint crc32(char[] data) {
	if (!crc_table[1]) {
		for (uint i = 0; i < 256; i++) {
			uint c = i;
			for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320 ^ (c >> 1) : c >> 1;
			crc_table[i] = c;
		}
	}
	uint crc = 0xFFFFFFFF;
	foreach (b : data) crc = crc_table[(crc ^ b) & 0xFF] ^ (crc >> 8);
	return ~crc;
}

// --- bit shuffles ------------------------------------------------------------

// Bit i of the result is bit order[i] of `v`.
fn char reorder_bits(char v, char[8]* order) {
	char out;
	for (int i = 0; i < 8; i++) out |= ((v >> (*order)[i]) & 1) << i;
	return out;
}

const char[8][8] BBD_DATA = {
	{ 0, 1, 2, 3, 4, 5, 6, 7 }, { 0, 1, 2, 3, 4, 5, 6, 7 }, { 0, 1, 2, 3, 4, 5, 6, 7 }, { 0, 1, 2, 3, 4, 5, 6, 7 },
	{ 0, 5, 1, 3, 4, 2, 6, 7 }, // Garou
	{ 0, 4, 2, 3, 1, 5, 6, 7 }, // Harry
	{ 0, 1, 2, 3, 4, 5, 6, 7 },
	{ 0, 1, 5, 3, 4, 2, 6, 7 }, // Digimon
};
const char[8][8] BBD_BANK = {
	{ 0, 1, 2, 3, 4, 5, 6, 7 }, { 0, 1, 2, 3, 4, 5, 6, 7 }, { 0, 1, 2, 3, 4, 5, 6, 7 },
	{ 3, 4, 2, 0, 1, 5, 6, 7 }, // Digimon, Garou
	{ 0, 1, 2, 3, 4, 5, 6, 7 },
	{ 1, 2, 3, 4, 0, 5, 6, 7 }, // Harry
	{ 0, 1, 2, 3, 4, 5, 6, 7 }, { 0, 1, 2, 3, 4, 5, 6, 7 },
};
const char[8][8] HITEK_DATA = {
	{ 0, 1, 2, 3, 4, 5, 6, 7 }, { 0, 6, 5, 3, 4, 1, 2, 7 }, { 0, 5, 6, 3, 4, 2, 1, 7 }, { 0, 6, 2, 3, 4, 5, 1, 7 },
	{ 0, 6, 1, 3, 4, 5, 2, 7 }, { 0, 1, 6, 3, 4, 5, 2, 7 }, { 0, 2, 6, 3, 4, 1, 5, 7 }, { 0, 6, 2, 3, 4, 1, 5, 7 },
};
const char[8][8] HITEK_BANK = {
	{ 0, 1, 2, 3, 4, 5, 6, 7 }, { 3, 2, 1, 0, 4, 5, 6, 7 }, { 2, 1, 0, 3, 4, 5, 6, 7 }, { 1, 0, 3, 2, 4, 5, 6, 7 },
	{ 0, 3, 2, 1, 4, 5, 6, 7 }, { 2, 3, 0, 1, 4, 5, 6, 7 }, { 3, 0, 1, 2, 4, 5, 6, 7 }, { 2, 0, 3, 1, 4, 5, 6, 7 },
};
const char[8][8] GGB81_DATA = {
	{ 0, 1, 2, 3, 4, 5, 6, 7 }, { 0, 2, 1, 3, 4, 6, 5, 7 }, { 0, 6, 5, 3, 4, 2, 1, 7 }, { 0, 5, 1, 3, 4, 2, 6, 7 },
	{ 0, 5, 2, 3, 4, 1, 6, 7 }, { 0, 2, 6, 3, 4, 5, 1, 7 }, { 0, 1, 6, 3, 4, 2, 5, 7 }, { 0, 2, 5, 3, 4, 6, 1, 7 },
};
const char[8][16] SINTAX_BANK = {
	{ 2, 1, 4, 3, 6, 5, 0, 7 }, { 3, 2, 5, 4, 7, 6, 1, 0 }, { 0, 1, 2, 3, 4, 5, 6, 7 }, { 0, 1, 2, 3, 4, 5, 6, 7 },
	{ 0, 1, 2, 3, 4, 5, 6, 7 }, { 4, 5, 2, 3, 0, 1, 6, 7 }, { 0, 1, 2, 3, 4, 5, 6, 7 }, { 6, 7, 4, 5, 1, 3, 0, 2 },
	{ 0, 1, 2, 3, 4, 5, 6, 7 }, { 7, 6, 1, 0, 3, 2, 5, 4 }, { 0, 1, 2, 3, 4, 5, 6, 7 }, { 5, 4, 7, 6, 1, 0, 3, 2 },
	{ 0, 1, 2, 3, 4, 5, 6, 7 }, { 2, 3, 4, 5, 6, 7, 0, 1 }, { 0, 1, 2, 3, 4, 5, 6, 7 }, { 0, 1, 2, 3, 4, 5, 6, 7 },
};
const char[8] NT_OLD1_ORDER = { 0, 2, 1, 4, 3, 5, 6, 7 };
const char[8] NT_OLD2_ORDER = { 1, 2, 0, 3, 4, 5, 6, 7 };

// --- reads -------------------------------------------------------------------

// Whether ROM reads go through Cartridge.read (bit shuffles, XOR, 8 KiB
// banks) rather than a plain 16 KiB mapping.
fn bool Cartridge.bootleg_reads(&self) {
	switch (self.mbc) {
		case BBD: case HITEK: case GGB81: case SINTAX: case NT_NEW: case SKOB: return true;
		default: return false;
	}
}

// A byte of $4000-$7FFF as the game sees it.
fn char Cartridge.bootleg_data(&self, char v) {
	Bootleg* b = &self.bootleg;
	switch (self.mbc) {
		case BBD:    return reorder_bits(v, &BBD_DATA[b.data_swap & 7]);
		case HITEK:  return reorder_bits(v, &HITEK_DATA[b.data_swap & 7]);
		case GGB81:  return reorder_bits(v, &GGB81_DATA[b.data_swap & 7]);
		case SINTAX: return v ^ b.sintax_cur_xor;
		case SKOB:   return self.lee8_data(v);
		default:     return v;
	}
}

// NT boards: the base bank at $0000 (old), 8 KiB banks while split (new).
fn usz Cartridge.nt_rom_offset(&self, ushort addr) {
	Bootleg* b = &self.bootleg;
	if (addr < 0x4000) {
		if (self.mbc == NT_NEW || !b.nt_base) return addr;
		return (usz)wrap_bank(b.nt_base, self.rom.len, 0x4000) * 0x4000 + addr;
	}
	if (self.mbc == NT_NEW && b.nt_split) {
		uint half = b.nt_half[(addr >> 13) & 1];
		return (usz)wrap_bank(half, self.rom.len, 0x2000) * 0x2000 + (usz)(addr & 0x1FFF);
	}
	uint bank = self.rom_bank;
	if (bank == 0 && self.mbc != NT_NEW) bank = 1;
	return (usz)wrap_bank(bank, self.rom.len, 0x4000) * 0x4000 + (usz)(addr - 0x4000);
}

fn char Cartridge.pkjd_read(&self, ushort addr) {
	if (!self.ram_enabled) return 0xFF;
	switch (self.bootleg.pkjd_reg) {
		case 0:    return self.ram_byte(addr);
		case 5:
		case 6:    return self.bootleg.pkjd_counter[self.bootleg.pkjd_reg - 5];
		default:   return 0;
	}
}

fn void Cartridge.pkjd_write(&self, ushort addr, char value) {
	if (!self.ram_enabled) return;
	char[2]* c = &self.bootleg.pkjd_counter;
	switch (self.bootleg.pkjd_reg) {
		case 0: self.set_ram_byte(addr, value);
		case 5:
		case 6: (*c)[self.bootleg.pkjd_reg - 5] = value;
		case 7:
			switch (value) {
				case 0x11: (*c)[0]--;
				case 0x12: (*c)[1]--;
				case 0x41: (*c)[0] += (*c)[1];
				case 0x42: (*c)[1] += (*c)[0];
				case 0x51: (*c)[0]++;
				case 0x52: (*c)[1]++; // (mGBA decrements: MAME's tfboot_device increments)
				default: break;
			}
		default: break;
	}
}

// --- writes ------------------------------------------------------------------

fn void Cartridge.bootleg_control(&self, ushort addr, char value) {
	Bootleg* b = &self.bootleg;
	switch (self.mbc) {
		case BBD:
		case HITEK:
			bool hitek = self.mbc == HITEK;
			switch (addr & 0xF0FF) {
				case 0x2000:
					value = reorder_bits(value, hitek ? &HITEK_BANK[b.bank_swap & 7] : &BBD_BANK[b.bank_swap & 7]);
				case 0x2001: b.data_swap = value & 7;
				case 0x2080: b.bank_swap = value & 7;
				case 0x0300: if (hitek) return; // (hhugboy: MbcUnlHitek.cpp)
				default: break;
			}
			self.mbc5_control(addr, value);
		case GGB81:
			if ((addr & 0xF0FF) == 0x2001) b.data_swap = value & 7;
			self.mbc5_control(addr, value);
		case LI_CHENG:
			if (addr > 0x2100 && addr < 0x3000) return;
			self.mbc5_control(addr, value);
		case SINTAX:
			self.sintax_control(addr, value);
		case NT_OLD1:
		case NT_OLD2:
			self.nt_old_control(addr, value);
		case NT_NEW:
			if (addr >> 8 == 0x14) {
				if (!b.nt_split) {
					// What is mapped now, as two halves.
					uint bank = wrap_bank(self.rom_bank, self.rom.len, 0x4000);
					b.nt_half = { bank * 2, bank * 2 + 1 };
				}
				b.nt_split = true;
				return;
			}
			if (b.nt_split && addr >> 10 >= 8 && addr >> 10 <= 9) {
				b.nt_half[(addr >> 10) - 8] = value < 2 ? 2 : value;
				return;
			}
			self.mbc5_control(addr, value);
		case PKJD:
			if (addr >> 13 == 2) {
				if (value < 8) {
					b.pkjd_reg = 0;
				} else if (value >= 0x0D && value <= 0x0F) {
					b.pkjd_reg = value - 8;
				}
			}
			self.mbc3_control(addr, value);
		default:
			break;
	}
}

fn void Cartridge.sintax_control(&self, ushort addr, char value) {
	Bootleg* b = &self.bootleg;
	if (addr >= 0x2000 && addr < 0x3000) {
		b.sintax_bank = value;
		value = reorder_bits(value, &SINTAX_BANK[b.sintax_mode & 0x0F]);
		b.sintax_cur_xor = b.sintax_xor[b.sintax_bank & 3];
	}
	if ((addr & 0xF0F0) == 0x5010) {
		// The mode can change again (Metal Max writes other $5xxx addresses
		// before battles, and only $5x1x counts).
		b.sintax_mode = value & 0x0F;
		self.sintax_control(0x2000, b.sintax_bank); // the bank again, shuffled anew
		return;
	}
	if (addr >= 0x7000 && addr < 0x8000) {
		int n = (addr >> 4 & 0x0F) - 2;
		if (n >= 0 && n < 4) b.sintax_xor[n] = value;
		b.sintax_cur_xor = b.sintax_xor[b.sintax_bank & 3];
	}
	self.mbc5_control(addr, value);
}

fn void Cartridge.nt_old_control(&self, ushort addr, char value) {
	Bootleg* b = &self.bootleg;
	char[8]* order = self.mbc == NT_OLD1 ? &NT_OLD1_ORDER : &NT_OLD2_ORDER;
	switch (addr >> 12) {
		case 0x0:
		case 0x1:
			self.mbc3_control(addr, value);
		case 0x2:
		case 0x3:
			uint bank = self.mbc == NT_OLD1 ? value & 0x1F : value;
			if (!bank) bank = 1;
			if (b.nt_swapped) bank = reorder_bits((char)bank, order);
			if (b.nt_count) bank &= b.nt_count - 1;
			self.rom_bank = bank + b.nt_base;
		case 0x4:
			if (self.mbc == NT_OLD2) self.nt_rumble_write(value);
		case 0x5:
			switch (addr & 3) {
				case 1:
					b.nt_base = (uint)(value & 0x3F) * 2;
					if (b.nt_base) self.rom_bank = b.nt_base + 1;
				case 2:
					switch (value & 0x0F) {
						case 0x8: b.nt_count = 16;
						case 0xC: b.nt_count = 8;
						case 0xE: b.nt_count = 4;
						case 0xF: b.nt_count = 2;
						default:  b.nt_count = 32;
					}
				case 3:
					b.nt_swapped = (value & 0x10) != 0;
					if (b.nt_swapped) self.rom_bank = reorder_bits((char)self.rom_bank, order);
				default: break;
			}
			if (self.mbc == NT_OLD2) {
				if (addr == 0x5001) b.nt_rumble = (value & 0x80) != 0;
				self.nt_rumble_write(value);
			}
		default:
			break;
	}
}

// NT old type 2: once $5001 bit 7 turns it on, the motor follows a bit of
// what is written to $4000-$5FFF (bit 3 with swapped bits, else bit 1).
fn void Cartridge.nt_rumble_write(&self, char value) {
	if (!self.bootleg.nt_rumble) return;
	self.rumble = (value & (self.bootleg.nt_swapped ? 0x08 : 0x02)) != 0;
	self.rumble_writes++;
	if (self.rumble) self.rumble_on++;
}
