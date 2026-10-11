module cart;

import std::io::file;

// The Nintendo Power GB Memory cartridge (DMG-MMSA, 1997-2007): 1 MiB of
// flash with up to seven games and a menu, 128 KiB of RAM, and a MegaChips
// "G-MMC1" that maps one part of each to the console as an MBC1, 2, 3 or 5
// cartridge. From msinger's documentation (iceboy.a-singer.de/doc/
// np_gb_memory.html).
//
// The mappings are in a hidden 128-byte "map" region of the flash, three
// bytes each: entry 0 at power on (the menu), entries 1-7 the games. A dump
// keeps it in a .map file beside the .gb; without one, wer works it out from
// the menu's own list of games, as gbnp builds it.
//
//   byte 0: bits 7-5 MBC (0 none, 1 MBC1, 2 MBC2, 3 MBC3, 4 MBC5 without
//           bank 0 high, 5 MBC5, 6-7 an invalid entry), 4-2 ROM size (0 32
//           KiB ... 5-6 1 MiB, 7 16 KiB twice), 1-0 RAM size bits 2-1
//   byte 1: bit 7 RAM size bit 0 (0 none, 1 2 KiB, 2 8, 3 32, 4 64, 5 128),
//           bits 5-0 ROM offset in 32 KiB
//   byte 2: bits 5-0 RAM offset in 2 KiB
//
// The menu talks to the MMC at $0120-$013F: a command at $0120, arguments
// at $0121-$0127, $A5 at $013F to run it. $09 (with $AA, $55) enables the
// commands; $C0|n switches to entry n, $80|n does so resetting the console
// (the menu on a Game Boy Color: the game then gets the boot ROM's welcome).
// Programming the flash (the Kiosk's job) isn't emulated.

const usz NP_FLASH = 0x100000;
const usz NP_RAM = 0x20000;
const usz NP_MAP = 128;
const usz NP_DIRECTORY = 0x1C200;   // the menu's list of games, 512 bytes each

struct GbMemory {
	char[128] map;
	char[3]   entry;       // the mapping in use
	char      index;       // ... its number
	bool      commands;    // $0120-$013F are the MMC's
	bool      unmapped;    // command $04: all the flash and RAM, as an MBC5
	bool      mbc_locked;  // command $10: MBC writes ignored
	char[8]   args;        // $0120-$0127 as last written
	// The MBC's registers, kept by command $04 for $05.
	uint      saved_rom_bank;
	uint      saved_ram_bank;
	bool      saved_ram_enabled;
}

fn bool is_np_menu(char[] rom) => rom.len >= 0x8000 && (String)rom[0x134 : 9] == "NP M-MENU";

// Its map: the .map beside the ROM, else one from the menu's list of games.
fn bool? np_map(char[] rom, String path, char[128]* map) {
	if (path.len) {
		if (try data = file::load_temp(path.tconcat(".map"))) {
			if (data.len >= NP_MAP) {
				(*map)[..] = data[:NP_MAP];
				return true;
			}
		}
	}
	if (!is_np_menu(rom) || rom.len < NP_DIRECTORY + 7 * 512) return false;
	np_map_from_menu(rom, map);
	return true;
}

// The mapping of each game in the menu's list (its first block, its size
// in blocks of 128 KiB), with the MBC and RAM from the game's header and its
// RAM after the previous game's, at least 8 KiB each, as gbnp writes them.
fn void np_map_from_menu(char[] rom, char[128]* map) {
	(*map)[..] = 0xFF;
	(*map)[0x7F] = 0;
	(*map)[0] = 0xA8; // the menu: MBC5, 128 KiB, at the start
	(*map)[1] = 0x00;
	(*map)[2] = 0x00;
	usz ram_at;
	for (int i = 0; i < 7; i++) {
		char[] e = rom[NP_DIRECTORY + (usz)i * 512 : 7];
		if (e[0] != i + 1) break;
		usz at = (usz)e[1] * 0x20000;
		usz size = (usz)e[3] * 0x20000;
		if (!size || at + 0x150 > rom.len) break;
		char type = rom[at + 0x147];
		char ram_code = rom[at + 0x149];
		char mbc;
		switch (mbc_of(type)) {
			case MBC1: mbc = 1;
			case MBC2: mbc = 2;
			case MBC3: mbc = 3;
			case MBC5: mbc = 5;
			default:   mbc = 0;
		}
		char rom_size = size <= 0x20000 ? 2 : size <= 0x40000 ? 3 : size <= 0x80000 ? 4 : 5;
		usz ram = ram_code < 6 ? RAM_SIZE[ram_code] : 0;
		char ram_size;
		switch {
			case type == 0x06:  ram_size = 1;
			case ram == 0:      ram_size = 0;
			case ram == 0x8000: ram_size = 3;
			case ram == 0x10000: ram_size = 4;
			case ram == 0x20000: ram_size = 5;
			default:            ram_size = 2;
		}
		usz m = (usz)(i + 1) * 3;
		(*map)[m] = (mbc << 5) | (rom_size << 2) | (ram_size >> 1);
		(*map)[m + 1] = (char)(((usz)(ram_size & 1) << 7) | ((at / 0x8000) & 0x3F));
		(*map)[m + 2] = (char)((ram_at / 0x800) & 0x3F);
		ram_at += type == 0x06 || ram < 0x2000 ? (usz)0x2000 : ram;
	}
}

fn void Cartridge.np_init(&self, char[128]* map) {
	self.mbc = GBMEM;
	self.np.map = *map;
	self.has_battery = true;
	self.np_switch(0);
}

// Mapping entry n, as the MMC reads it from the map (00 00 00 if the map or
// the entry isn't valid), with the MBC's registers at their defaults.
fn void Cartridge.np_switch(&self, char n) {
	GbMemory* g = &self.np;
	g.index = n & 0x3F;
	g.entry = { 0, 0, 0 };
	usz m = (usz)g.index * 3;
	if (g.map[0x7F] == 0 && m + 2 < NP_MAP && (g.map[m] & 0xC0) != 0xC0) {
		g.entry = { g.map[m], g.map[m + 1] & 0xBF, g.map[m + 2] & 0x3F };
	}
	g.unmapped = false;
	g.commands = false;
	g.mbc_locked = false;
	self.np_mbc_defaults();
}

fn void Cartridge.np_mbc_defaults(&self) {
	self.rom_bank = 1;
	self.bank1 = 1;
	self.bank2 = 0;
	self.mode1 = false;
	self.ram_bank = 0;
	self.ram_enabled = false;
	self.rom_mapped = false;
}

// The console reset (from the MMC's command, or the player's): the mapping
// stays, the MMC's commands are off, the MBC's registers at their defaults.
fn void Cartridge.np_reset(&self) {
	self.np.commands = false;
	self.np.unmapped = false;
	self.np.mbc_locked = false;
	self.np_mbc_defaults();
}

// The mapping's fields; command $04's is 9A 80 00 (all of it, MBC5-ish).
fn char[3] GbMemory.mapping(&self) => self.unmapped ? (char[3]){ 0x9A, 0x80, 0x00 } : self.entry;
fn char GbMemory.mbc_type(&self) => self.mapping()[0] >> 5;

fn usz GbMemory.rom_size(&self) {
	char s = (self.mapping()[0] >> 2) & 7;
	if (s == 7) return 0x4000;
	return s >= 5 ? NP_FLASH : (usz)0x8000 << s;
}

fn usz GbMemory.ram_size(&self) {
	char[3] m = self.mapping();
	char s = ((m[0] & 3) << 1) | (m[1] >> 7);
	switch (s) {
		case 1: return self.mbc_type() == 2 ? 0x200 : 0x800;
		case 2: return 0x2000;
		case 3: return 0x8000;
		case 4: return 0x10000;
		case 5: return 0x20000;
		default: return 0;
	}
}

fn usz Cartridge.np_rom_offset(&self, ushort addr) {
	GbMemory* g = &self.np;
	usz size = g.rom_size();
	uint bank;
	if (addr >= 0x4000) {
		switch (g.mbc_type()) {
			case 1:
				bank = (self.bank2 << 5) | self.bank1;
			case 2:
				bank = self.rom_bank & 0x0F;
				if (!bank) bank = 1;
			case 3:
				bank = self.rom_bank & 0x7F;
				if (!bank) bank = 1;
			case 4:
				bank = self.rom_bank ? self.rom_bank : 1;
			case 5:
				bank = self.rom_bank;
			default:
				bank = 1;
		}
	}
	usz in_game = size <= 0x4000 ? 0 : (usz)wrap_bank(bank, size, 0x4000) * 0x4000;
	usz base = (usz)(g.mapping()[1] & 0x3F) * 0x8000;
	return (base + in_game + (usz)(addr & 0x3FFF)) % NP_FLASH;
}

// Where $A000-$BFFF is in the cartridge's RAM, or NP_RAM for nothing.
fn usz Cartridge.np_ram_offset(&self, ushort addr) {
	GbMemory* g = &self.np;
	usz size = g.ram_size();
	if (!size || (!self.ram_enabled && g.mbc_type() != 0)) return NP_RAM; // without an MBC, always on
	uint bank = self.ram_bank;
	switch (g.mbc_type()) {
		case 1: bank = self.mode1 ? self.bank2 : 0;
		case 2: bank = 0;
		case 3: if (bank >= 8) return NP_RAM; // the clock's registers: nothing there
		default: break;
	}
	usz local = (usz)bank * 0x2000 + (usz)(addr - 0xA000);
	usz base = (usz)(g.mapping()[2] & 0x3F) * 0x800;
	return (base + local % size) % NP_RAM;
}

fn char Cartridge.np_read_ram(&self, ushort addr) {
	usz off = self.np_ram_offset(addr);
	return off < self.ram.len ? self.ram[off] : 0xFF;
}

fn void Cartridge.np_write_ram(&self, ushort addr, char value) {
	usz off = self.np_ram_offset(addr);
	if (off < self.ram.len) self.ram[off] = value;
}

// $0120-$013F while the MMC's commands are on: its registers.
fn bool Cartridge.np_registers(&self, ushort addr) => self.mbc == GBMEM && self.np.commands && addr >= 0x0120 && addr < 0x0140;

fn char Cartridge.np_register(&self, ushort addr) {
	GbMemory* g = &self.np;
	switch (addr) {
		case 0x0120: return 0x21;
		case 0x0121: return g.index << 2;
		case 0x0122: return g.mapping()[0];
		case 0x0123: return g.mapping()[1];
		case 0x0124: return g.mapping()[2];
		case 0x0125: return 0x87;
		case 0x0126: return 0x78;
		case 0x0127: return 0x5A;
		case 0x013F: return 0xA5;
		default:     return 0x00;
	}
}

fn void Cartridge.np_control(&self, ushort addr, char value) {
	GbMemory* g = &self.np;
	if (addr >= 0x0120 && addr < 0x0140) {
		if (addr < 0x0128) g.args[addr - 0x0120] = value;
		if (addr == 0x013F && value == 0xA5) self.np_command(g.args[0]);
		// These are in the MBC's $0000-$1FFF too: RAM off (unless $0A).
		if (!g.mbc_locked) self.ram_enabled = (value & 0x0F) == 0x0A;
		return;
	}
	if (g.mbc_locked) return;
	switch (g.mbc_type()) {
		case 0:
			return;
		case 1:
			switch {
				case addr < 0x2000: self.ram_enabled = (value & 0x0F) == 0x0A;
				case addr < 0x4000:
					self.bank1 = value & 0x1F;
					if (!self.bank1) self.bank1 = 1;
				case addr < 0x6000: self.bank2 = value & 3;
				default:            self.mode1 = (value & 1) != 0;
			}
		case 2:
			if (addr >= 0x4000) return;
			if (addr & 0x100) {
				self.rom_bank = value & 0x0F;
			} else {
				self.ram_enabled = (value & 0x0F) == 0x0A;
			}
		case 3:
			switch {
				case addr < 0x2000: self.ram_enabled = (value & 0x0F) == 0x0A;
				case addr < 0x4000: self.rom_bank = value & 0x7F;
				case addr < 0x6000: self.ram_bank = value & 0x0F;
				default:            break; // the clock latch: no clock
			}
		case 4:
			if (addr < 0x2000) {
				self.ram_enabled = (value & 0x0F) == 0x0A;
				return;
			}
			self.mbc5_control(addr, value);
		default:
			self.mbc5_control(addr, value);
	}
}

fn void Cartridge.np_command(&self, char command) {
	GbMemory* g = &self.np;
	if (command == 0x09) {
		if (g.args[1] == 0xAA && g.args[2] == 0x55) g.commands = true;
		return;
	}
	if (!g.commands) return;
	switch {
		case command == 0x04:
			g.saved_rom_bank = self.rom_bank;
			g.saved_ram_bank = self.ram_bank;
			g.saved_ram_enabled = self.ram_enabled;
			g.unmapped = true;
			self.rom_bank = 1;
			self.ram_bank = 0;
			self.ram_enabled = false;
		case command == 0x05:
			g.unmapped = false;
			self.rom_bank = g.saved_rom_bank;
			self.ram_bank = g.saved_ram_bank;
			self.ram_enabled = g.saved_ram_enabled;
		case command == 0x08: g.commands = false;
		case command == 0x10: g.mbc_locked = true;
		case command == 0x11: g.mbc_locked = false;
		case command >= 0xC0:
			self.np_switch(command & 0x3F);
		case command >= 0x80:
			self.np_switch(command & 0x3F);
			self.reset_request = true;
		default:
			break; // the flash's write protection and programming
	}
}
