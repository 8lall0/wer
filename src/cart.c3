module cart;

import std::io, std::io::file;

const char[48] NINTENDO_LOGO = {
	0xCE, 0xED, 0x66, 0x66, 0xCC, 0x0D, 0x00, 0x0B, 0x03, 0x73, 0x00, 0x83, 0x00, 0x0C, 0x00, 0x0D,
	0x00, 0x08, 0x11, 0x1F, 0x88, 0x89, 0x00, 0x0E, 0xDC, 0xCC, 0x6E, 0xE6, 0xDD, 0xDD, 0xD9, 0x99,
	0xBB, 0xBB, 0x67, 0x63, 0x6E, 0x0E, 0xEC, 0xCC, 0xDD, 0xDC, 0x99, 0x9F, 0xBB, 0xB9, 0x33, 0x3E,
};

fn bool logo_matches(char[] rom) {
	if (rom.len < 0x134) return false;
	for (int i = 0; i < 48; i++) {
		if (rom[0x104 + i] != NINTENDO_LOGO[i]) return false;
	}
	return true;
}

enum Mbc : char {
	NONE,
	MBC1,
	MBC2,
	MBC3, // TODO: RTC not modelled — the clock registers read $FF and ignore writes
	MBC5,
}

struct Cartridge {
	Mbc    mbc;
	char[] rom;   // full image, heap
	char[] ram;   // battery-backed / work RAM, heap (empty if none)
	bool   has_battery;
	String save_path;

	// banking state
	uint rom_bank;   // MBC2/3/5: selected $4000-$7FFF bank
	uint ram_bank;
	bool ram_enabled;
	uint bank1;      // MBC1 $2000 register: 5 bits, 0 reads as 1
	uint bank2;      // MBC1 $4000 register: 2 bits
	bool mode1;      // MBC1 advanced banking mode
	bool multicart;  // MBC1M wiring: bank1 has 4 bits, bank2 sits at bit 4
}

fn Mbc mbc_of(char type) {
	switch (type) {
		case 0x01: case 0x02: case 0x03:
			return MBC1;
		case 0x05: case 0x06:
			return MBC2;
		case 0x0F: case 0x10: case 0x11: case 0x12: case 0x13:
			return MBC3;
		case 0x19: case 0x1A: case 0x1B: case 0x1C: case 0x1D: case 0x1E:
			return MBC5;
		default:
			return NONE;
	}
}

fn bool has_battery(char type) {
	switch (type) {
		case 0x03: case 0x06: case 0x0F: case 0x10: case 0x13: case 0x1B: case 0x1E:
			return true;
		default:
			return false;
	}
}

const uint[6] RAM_SIZE = { 0, 0x800, 0x2000, 0x8000, 0x20000, 0x10000 };

// Build from a full ROM image. `path` is used to derive the .sav filename.
fn Cartridge* new(char[] image, String path) {
	Cartridge* c = mem::new(Cartridge);
	c.rom = mem::new_array(char, image.len < 0x8000 ? (usz)0x8000 : image.len);
	foreach (i, b : image) c.rom[i] = b;

	char type = image.len > 0x147 ? image[0x147] : 0;
	c.mbc = mbc_of(type);
	c.has_battery = has_battery(type);

	// MBC1M multicart: a 1 MB MBC1 whose bank $10 (the second game) has its own
	// Nintendo logo. Nothing in the header says so.
	c.multicart = c.mbc == MBC1 && c.rom.len == 0x100000 && logo_matches(c.rom[0x40000..]);

	uint ram_len;
	if (c.mbc == MBC2) {
		ram_len = 0x200; // built-in 512 x 4 bits
	} else {
		char code = image.len > 0x149 ? image[0x149] : 0;
		ram_len = code < 6 ? RAM_SIZE[code] : 0;
	}
	if (ram_len > 0) c.ram = mem::new_array(char, ram_len);

	c.rom_bank = 1;
	c.bank1 = 1;

	if (c.has_battery && c.ram.len > 0) {
		c.save_path = string::format(mem, "%s.sav", path);
		if (try saved = file::load_temp(c.save_path)) {
			usz n = saved.len < c.ram.len ? saved.len : c.ram.len;
			for (usz i = 0; i < n; i++) c.ram[i] = saved[i];
		}
	}
	return c;
}

fn void Cartridge.free(&self) {
	if (self.rom.len) mem::free(self.rom.ptr);
	if (self.ram.len) mem::free(self.ram.ptr);
	if (self.save_path.len) mem::free(self.save_path.ptr);
	mem::free(self);
}

fn void Cartridge.save(&self) {
	if (!self.has_battery || self.ram.len == 0 || self.save_path.len == 0) return;
	if (catch file::save(self.save_path, self.ram)) {
		io::eprintfn("could not write %s", self.save_path);
	}
}

// A bank number beyond the chip's size wraps: a smaller ROM/RAM simply has
// fewer address lines connected, so the high bits of the number are lost.
fn uint wrap_bank(uint bank, usz size, usz bank_size) {
	usz banks = size / bank_size;
	return banks > 1 ? bank % (uint)banks : 0;
}

// MBC1: bank = bank2 << shift | bank1 & mask. The low area shows bank2 << shift
// in mode 1 ($00/$20/$40/$60, or $00/$10/$20/$30 on a multicart), else bank 0.
fn usz Cartridge.mbc1_rom_offset(&self, ushort addr) {
	uint shift = self.multicart ? 4 : 5;
	uint mask  = self.multicart ? 0x0F : 0x1F;
	if (addr < 0x4000) {
		if (!self.mode1) return addr;
		return (usz)wrap_bank(self.bank2 << shift, self.rom.len, 0x4000) * 0x4000 + addr;
	}
	uint bank = (self.bank2 << shift) | (self.bank1 & mask);
	return (usz)wrap_bank(bank, self.rom.len, 0x4000) * 0x4000 + (usz)(addr - 0x4000);
}

fn usz Cartridge.rom_offset(&self, ushort addr) {
	if (self.mbc == MBC1) return self.mbc1_rom_offset(addr);

	if (addr < 0x4000) return addr;
	uint bank = self.rom_bank;
	if (bank == 0 && (self.mbc == MBC2 || self.mbc == MBC3)) bank = 1;
	bank = wrap_bank(bank, self.rom.len, 0x4000);
	return (usz)bank * 0x4000 + (usz)(addr - 0x4000);
}

fn char Cartridge.read(&self, ushort addr) {
	if (addr < 0x8000) {
		usz off = self.rom_offset(addr);
		return off < self.rom.len ? self.rom[off] : 0xFF;
	}
	// $A000-$BFFF
	if (!self.ram_enabled || self.ram.len == 0) return 0xFF;
	usz off = self.ram_offset(addr);
	char v = off < self.ram.len ? self.ram[off] : 0xFF;
	return self.mbc == MBC2 ? (char)(v | 0xF0) : v;
}

fn usz Cartridge.ram_offset(&self, ushort addr) {
	usz local = (usz)(addr - 0xA000);
	if (self.mbc == MBC2) return local & 0x1FF;
	uint bank = (self.mbc == MBC1 && !self.mode1) ? 0 : self.ram_bank;
	// MBC3 banks $08-$0C are the RTC registers, not RAM: keep them out of range
	// (reads $FF, writes dropped) instead of wrapping onto real save RAM.
	if (self.mbc == MBC3 && bank >= 0x08) return self.ram.len;
	bank = wrap_bank(bank, self.ram.len, 0x2000);
	return (usz)bank * 0x2000 + local % (usz)self.ram.len; // 2 KiB RAM mirrors in its bank
}

fn void Cartridge.write(&self, ushort addr, char value) {
	if (addr < 0x8000) {
		self.write_control(addr, value);
		return;
	}
	// $A000-$BFFF
	if (!self.ram_enabled || self.ram.len == 0) return;
	usz off = self.ram_offset(addr);
	if (off < self.ram.len) {
		self.ram[off] = self.mbc == MBC2 ? (char)(value & 0x0F) : value;
	}
}

fn void Cartridge.write_control(&self, ushort addr, char value) {
	switch (self.mbc) {
		case NONE:
			return;
		case MBC1:
			switch {
				case addr < 0x2000: self.ram_enabled = (value & 0x0F) == 0x0A;
				case addr < 0x4000:
					// 0 -> 1 looks at the register value, before wrapping and even on
					// a multicart where only 4 bits reach the ROM: BANK1 = 4 on a 4-bank
					// ROM, or $10 on a multicart, really does map bank 0 at $4000.
					self.bank1 = value & 0x1F;
					if (self.bank1 == 0) self.bank1 = 1;
				case addr < 0x6000:
					self.bank2 = value & 3;
					self.ram_bank = value & 3;
				default:
					self.mode1 = (value & 1) != 0;
			}
		case MBC2:
			// $0000-$3FFF: bit 8 of address selects RAM-enable vs ROM-bank.
			if (addr < 0x4000) {
				if ((addr & 0x100) == 0) {
					self.ram_enabled = (value & 0x0F) == 0x0A;
				} else {
					uint b = value & 0x0F;
					self.rom_bank = b == 0 ? 1 : b;
				}
			}
		case MBC3:
			switch {
				case addr < 0x2000: self.ram_enabled = (value & 0x0F) == 0x0A;
				case addr < 0x4000:
					uint b = value & 0x7F;
					self.rom_bank = b == 0 ? 1 : b;
				case addr < 0x6000: self.ram_bank = value; // 0-3 = RAM, 8-C = RTC (unmodelled)
				default: break; // RTC latch — ignored
			}
		case MBC5:
			switch {
				case addr < 0x2000: self.ram_enabled = (value & 0x0F) == 0x0A;
				case addr < 0x3000: self.rom_bank = (self.rom_bank & 0x100) | value;
				case addr < 0x4000: self.rom_bank = (self.rom_bank & 0xFF) | ((value & 1) << 8);
				case addr < 0x6000: self.ram_bank = value & 0x0F;
				default: break;
			}
	}
}
