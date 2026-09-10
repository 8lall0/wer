module cart;

import std::io, std::io::file;

enum Mbc : char {
	NONE,
	MBC1,
	MBC2,
	MBC3, // TODO: RTC not modelled — the clock registers read/write as plain RAM
	MBC5,
}

struct Cartridge {
	Mbc    mbc;
	char[] rom;   // full image, heap
	char[] ram;   // battery-backed / work RAM, heap (empty if none)
	bool   has_battery;
	String save_path;

	// banking state
	uint rom_bank;   // selected $4000-$7FFF bank (never 0 for the low register)
	uint ram_bank;
	bool ram_enabled;
	bool mode1;      // MBC1 advanced banking mode
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

	uint ram_len;
	if (c.mbc == MBC2) {
		ram_len = 0x200; // built-in 512 x 4 bits
	} else {
		char code = image.len > 0x149 ? image[0x149] : 0;
		ram_len = code < 6 ? RAM_SIZE[code] : 0;
	}
	if (ram_len > 0) c.ram = mem::new_array(char, ram_len);

	c.rom_bank = 1;

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

fn usz Cartridge.rom_offset(&self, ushort addr) {
	if (addr < 0x4000) {
		// MBC1 mode 1 maps banks 0x20/0x40/0x60 into the low area on big ROMs.
		if (self.mbc == MBC1 && self.mode1) {
			uint hi = (self.rom_bank >> 5) & 3;
			return ((usz)hi * 0x20) * 0x4000 + addr;
		}
		return addr;
	}
	uint bank = self.rom_bank;
	if (self.mbc == MBC1 && !self.mode1) {
		bank = (bank & 0x1F) | (self.rom_bank & 0x60);
	}
	if (bank == 0 && (self.mbc == MBC1 || self.mbc == MBC2 || self.mbc == MBC3)) bank = 1;
	usz banks = self.rom.len / 0x4000;
	if (banks > 0) bank %= (uint)banks;
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
	return (usz)bank * 0x2000 + local;
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
					uint lo = value & 0x1F;
					if (lo == 0) lo = 1;
					self.rom_bank = (self.rom_bank & 0x60) | lo;
				case addr < 0x6000:
					self.rom_bank = (self.rom_bank & 0x1F) | ((value & 3) << 5);
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
				case addr < 0x6000: self.ram_bank = value; // 0-3 = RAM, 8-C = RTC (as RAM)
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
