module cart;

import std::io, std::io::file, std::time;

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
	MBC3, // types $0F/$10 also carry the real-time clock (see rtc.c3)
	MBC5,
	MBC7, // $22: accelerometer and a serial EEPROM (Kirby Tilt 'n' Tumble, Command Master)
	MMM01, // $0B-$0D: multicarts (mappers.c3)
	HUC1, // $FF: infrared port (mappers.c3)
	HUC3, // $FE: clock and infrared (mappers.c3)
	TAMA5, // $FD: Tamagotchi 3's clock and RAM (tama5.c3)
	CAMERA, // $FC: the Game Boy Camera (camera.c3)
	MBC6,   // $20: two ROM/flash windows, two RAM windows (rare.c3)
	M161,   // Mani's 4 in 1: one 32 KiB bank, chosen once (rare.c3)
	WISDOM, // Wisdom Tree: one 32 KiB bank by address (rare.c3)
	TPP1,   // homebrew: 16-bit banks, RAM, clock, rumble (rare.c3)
	SACHEN, // Sachen MMC1/MMC2: base bank and mask, logo scrambling (sachen.c3)
}

// MBC7's own state (SameBoy's model, MIT: see LICENSE-sameboy). $A000-$AFFF
// holds registers, selected by address bits 4-7, once both $0000 = $0A and
// $4000 = $40 enable them:
//   $Ax0x  write $55: clear the latch       $Ax1x  write $AA: latch the tilt
//   $Ax2x/3x  X low/high                    $Ax4x/5x  Y low/high
//   $Ax8x  the 93LC56 EEPROM's pins: bit 7 CS, 6 CLK, 1 DI, 0 DO
// The latched values sit around $81D0, $70 per g; tilting right or toward
// the player lowers them.
struct Mbc7 {
	bool   ram_enabled2;  // $4000-$5FFF = $40
	ushort x_latch;
	ushort y_latch;
	bool   latch_ready;
	// The EEPROM: 128 16-bit words (Cartridge.ram, little-endian words).
	bool   cs;
	bool   clk;
	bool   di;
	bool   dout;
	ushort command;       // bits clocked in; complete with the start bit at bit 10
	int    argument_bits; // WRITE/WRAL: data bits still to come
	ushort read_bits;     // shifted out on DO, MSB first
	bool   write_enabled; // EWEN / EWDS
}

struct Cartridge {
	Mbc    mbc;
	char[] rom;   // full image, heap
	char[] ram;   // battery-backed / work RAM, heap (empty if none)
	bool   has_battery;
	bool   has_rtc;     // MBC3 with timer ($0F, $10)
	Rtc    rtc;
	String save_path;

	// banking state
	uint rom_bank;
	// Where $0000-$3FFF and $4000-$7FFF are in the ROM, worked out again
	// after a write to the cartridge (Cartridge.read_rom).
	bool rom_mapped;
	bool rom_linear;   // ... each a plain 16 KiB stretch (not Sachen's, not MBC6's)
	usz  rom_lo;
	usz  rom_hi;   // MBC2/3/5: selected $4000-$7FFF bank
	uint ram_bank;
	bool ram_enabled;
	uint bank1;      // MBC1 $2000 register: 5 bits, 0 reads as 1
	uint bank2;      // MBC1 $4000 register: 2 bits
	bool mode1;      // MBC1 advanced banking mode
	bool multicart;  // MBC1M wiring: bank1 has 4 bits, bank2 sits at bit 4

	Mbc7  mbc7;
	float tilt_x;    // MBC7: the player's tilt, -1..1 g each way (right, toward the player)
	float tilt_y;
	bool  has_rumble; // MBC5 $1C-$1E: a motor on bit 3 of the RAM bank register
	bool  rumble;     // ... running
	// Games set the motor's strength by switching it on and off quickly:
	// the writes to it since the frontend last looked, and how many ran it.
	uint  rumble_writes;
	uint  rumble_on;

	// A clock other than MBC3's (HuC3, TAMA5), counted in emulated seconds.
	bool  has_clock;
	uint  clock_subsec;
	// HuC1 / HuC3 infrared: $0000 = $0E (HuC1) or mode $E (HuC3).
	bool  ir_mode;
	bool  ir_out;    // the LED
	bool  ir_in;     // light seen
	Huc3  huc3;
	Mmm01 mmm01;
	Tama5 tama5;
	Camera camera;
	Mbc6  mbc6;
	Tpp1  tpp1;
	bool  m161_locked;
	Sachen sachen;
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
		case 0x22:
			return MBC7;
		case 0x0B: case 0x0C: case 0x0D:
			return MMM01;
		case 0x20:
			return MBC6;
		case 0xFC:
			return CAMERA;
		case 0xFD:
			return TAMA5;
		case 0xFE:
			return HUC3;
		case 0xFF:
			return HUC1;
		default:
			return NONE;
	}
}

fn bool has_battery(char type) {
	switch (type) {
		case 0x03: case 0x06: case 0x0D: case 0x0F: case 0x10: case 0x13: case 0x1B: case 0x1E: case 0x22:
		case 0xFC: case 0xFD: case 0xFE: case 0xFF:
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
	// MMM01: the menu, with the cartridge's own header, goes last.
	if (mbc_of(type) == MMM01) {
		mmm01_arrange(c.rom);
	} else if (mmm01_at_end(c.rom)) {
		type = 0x0B;
	}
	char ram_code = image.len > 0x149 ? image[0x149] : 0;
	if (mbc_of(type) == MMM01) {
		usz menu = c.rom.len - 0x8000;
		type = c.rom[menu + 0x147] == 0x11 ? 0x0B : c.rom[menu + 0x147];
		ram_code = c.rom[menu + 0x149];
	}
	c.mbc = mbc_of(type);
	c.has_battery = has_battery(type);
	// Mappers the header doesn't name.
	if (is_tpp1(c.rom)) {
		c.mbc = TPP1;
		c.has_battery = (c.rom[0x153] & 8) != 0;
	} else if (c.rom.len == 0x40000 && (String)c.rom[0x134 : 10] == "TETRIS SET") {
		c.mbc = M161;
	} else if (is_wisdom_tree(c.rom)) {
		c.mbc = WISDOM;
	} else if (is_sachen_mmc1(c.rom) || is_sachen_mmc2(c.rom)) {
		c.mbc = SACHEN;
		c.has_battery = false;
		c.sachen.locked = true; // until the boot ROM hands over (Mmu)
	} else if (c.mbc == MBC6) {
		c.has_battery = true; // the flash keeps what was written to it
	}
	c.has_rtc = type == 0x0F || type == 0x10;

	// MBC1M multicart: a 1 MB MBC1 whose bank $10 (the second game) has its own
	// Nintendo logo. Nothing in the header says so.
	c.multicart = c.mbc == MBC1 && c.rom.len == 0x100000 && logo_matches(c.rom[0x40000..]);

	uint ram_len;
	if (c.mbc == MBC2) {
		ram_len = 0x200; // built-in 512 x 4 bits
	} else if (c.mbc == MBC7) {
		ram_len = 0x100; // the 93LC56 EEPROM
	} else if (c.mbc == TAMA5) {
		ram_len = 0x20;
	} else if (c.mbc == MBC6) {
		ram_len = MBC6_RAM + MBC6_FLASH;
	} else if (c.mbc == TPP1) {
		char n = c.rom[0x152];
		ram_len = n >= 1 && n <= 9 ? 0x2000u << (n - 1) : 0;
	} else if (c.mbc == M161 || c.mbc == WISDOM || c.mbc == SACHEN) {
		ram_len = 0;
	} else {
		ram_len = ram_code < 6 ? RAM_SIZE[ram_code] : 0;
	}
	if (ram_len > 0) c.ram = mem::new_array(char, (sz)ram_len);
	c.has_rumble = (type >= 0x1C && type <= 0x1E) || (c.mbc == TPP1 && (c.rom[0x153] & 1));
	if (c.mbc == MBC6) c.flash()[..] = 0xFF; // an erased flash chip
	if (c.mbc == MBC7) {
		c.ram[..] = 0xFF; // a blank EEPROM
		c.mbc7.x_latch = c.mbc7.y_latch = 0x8000;
		c.mbc7.latch_ready = true;
		c.mbc7.read_bits = 0xFFFF;
		c.mbc7.dout = true;
	}

	c.rom_bank = 1;
	c.bank1 = 1;
	c.has_clock = c.mbc == HUC3 || c.mbc == TAMA5 || (c.mbc == TPP1 && (c.rom[0x153] & 4));
	if (c.mbc == M161 || c.mbc == WISDOM) c.rom_bank = 0;
	if (c.mbc == HUC3) c.huc3.unset();
	if (c.mbc == TAMA5) c.tama5.init();
	if (c.mbc == MMM01) c.mmm01.ram_mask = 3;

	if (c.has_battery && (c.ram.len > 0 || c.has_rtc || c.has_clock)) {
		c.save_path = string::format(mem, "%s.sav", path);
		if (try saved = file::load_temp(c.save_path)) {
			usz n = saved.len < c.ram.len ? saved.len : c.ram.len;
			for (usz i = 0; i < n; i++) c.ram[i] = saved[i];
			usz clock_len = c.clock_save_len();
			if (clock_len && saved.len >= c.ram.len + clock_len) {
				char[] block = saved[c.ram.len : (sz)clock_len];
				switch (c.mbc) {
					case HUC3:  c.huc3.deserialize(block, unix_now());
					case TAMA5: c.tama5.deserialize(block, unix_now());
					case TPP1:  c.tpp1.deserialize(block, unix_now());
					default:    c.rtc.deserialize(block, unix_now());
				}
			}
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

fn long unix_now() => (long)time::now() / (long)time::SEC;

// The clock's block after the RAM in a battery save (0 without a clock).
fn usz Cartridge.clock_save_len(&self) {
	switch {
		case self.has_rtc:      return RTC_SAVE_LEN;
		case self.mbc == HUC3:  return HUC3_SAVE_LEN;
		case self.mbc == TAMA5: return TAMA5_SAVE_LEN;
		case self.mbc == TPP1:  return self.has_clock ? TPP1_SAVE_LEN : 0;
		default:                return 0;
	}
}

// RAM, followed by the clock's block for clock cartridges (MBC3: 48 bytes,
// as other emulators write it; HuC3 as SameBoy, TAMA5 as mGBA does).
fn void Cartridge.save(&self) {
	if (!self.has_battery || self.save_path.len == 0) return;
	usz clock_len = self.clock_save_len();
	if (self.ram.len == 0 && clock_len == 0) return;
	char[] out = mem::new_array(char, (sz)(self.ram.len + clock_len));
	defer free(out.ptr);
	foreach (i, b : self.ram) out[i] = b;
	if (clock_len) {
		char[] block = out[self.ram.len : (sz)clock_len];
		switch (self.mbc) {
			case HUC3:  self.huc3.serialize(block, unix_now());
			case TAMA5: self.tama5.serialize(block, unix_now());
			case TPP1:  self.tpp1.serialize(block, unix_now());
			default:    self.rtc.serialize(block, unix_now());
		}
	}
	if (catch file::save(self.save_path, out)) {
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
	if (self.mbc == MMM01) return self.mmm01_rom_offset(addr);
	if (self.mbc == M161 || self.mbc == WISDOM) return self.big_bank_offset(addr);
	if (self.mbc == SACHEN) return self.sachen_rom_offset(addr);

	if (addr < 0x4000) return addr;
	uint bank = self.rom_bank;
	if (bank == 0 && (self.mbc == MBC2 || self.mbc == MBC3)) bank = 1;
	bank = wrap_bank(bank, self.rom.len, 0x4000);
	return (usz)bank * 0x4000 + (usz)(addr - 0x4000);
}

// $A000-$BFFF currently maps an RTC register instead of RAM.
fn bool Cartridge.rtc_selected(&self) {
	return self.has_rtc && self.ram_bank >= 0x08 && self.ram_bank <= 0x0C;
}

// A ROM read ($0000-$7FFF), through the mapping worked out last.
fn char Cartridge.read_rom(&self, ushort addr) @inline {
	if (!self.rom_mapped) self.map_rom();
	if (!self.rom_linear) return self.read(addr);
	usz off = (addr < 0x4000 ? self.rom_lo : self.rom_hi) + (usz)(addr & 0x3FFF);
	return off < self.rom.len ? self.rom[off] : 0xFF;
}

fn void Cartridge.map_rom(&self) {
	self.rom_mapped = true;
	self.rom_linear = self.mbc != MBC6 && self.mbc != SACHEN;
	if (!self.rom_linear) return;
	self.rom_lo = self.rom_offset(0x0000);
	self.rom_hi = self.rom_offset(0x4000);
}

fn char Cartridge.read(&self, ushort addr) {
	if (addr < 0x8000 && self.mbc == MBC6) return self.mbc6_read_rom(addr);
	if (addr < 0x8000) {
		usz off = self.rom_offset(addr);
		return off < self.rom.len ? self.rom[off] : 0xFF;
	}
	// $A000-$BFFF
	switch (self.mbc) {
		case MBC7:  return self.mbc7_read(addr);
		case TPP1:  return self.tpp1_read(addr);
		case HUC1:  return self.huc1_read(addr);
		case HUC3:  return self.huc3_read(addr);
		case TAMA5: return self.tama5_read(addr);
		case CAMERA: return self.camera_read(addr);
		default:    break;
	}
	if (!self.ram_enabled) return 0xFF;
	if (self.rtc_selected()) return self.rtc.read(self.ram_bank);
	if (self.ram.len == 0) return 0xFF;
	usz off = self.ram_offset(addr);
	char v = off < self.ram.len ? self.ram[off] : 0xFF;
	return self.mbc == MBC2 ? (char)(v | 0xF0) : v;
}

// RAM at $A000-$BFFF in the current bank, whatever enables it.
fn char Cartridge.ram_byte(&self, ushort addr) {
	if (self.ram.len == 0) return 0xFF;
	usz off = self.ram_offset(addr);
	return off < self.ram.len ? self.ram[off] : 0xFF;
}

fn void Cartridge.set_ram_byte(&self, ushort addr, char value) {
	if (self.ram.len == 0) return;
	usz off = self.ram_offset(addr);
	if (off < self.ram.len) self.ram[off] = value;
}

// Emulated time for the cartridge's clock, if it has one.
fn void Cartridge.tick(&self, uint tcycles) {
	if (self.has_rtc) {
		self.rtc.tick(tcycles);
		return;
	}
	uint hz = self.rtc.cpu_hz ? self.rtc.cpu_hz : RTC_CPU_HZ;
	self.clock_subsec += tcycles;
	while (self.clock_subsec >= hz) {
		self.clock_subsec -= hz;
		if (self.mbc == HUC3) {
			self.huc3.tick_second();
		} else if (self.mbc == TPP1) {
			self.tpp1.tick_second();
		} else {
			self.tama5.pending++;
		}
	}
}

fn usz Cartridge.ram_offset(&self, ushort addr) {
	usz local = (usz)(addr - 0xA000);
	if (self.mbc == MBC2) return local & 0x1FF;
	if (self.mbc == MBC6) return self.mbc6_ram_offset(addr);
	uint bank = (self.mbc == MBC1 && !self.mode1) ? 0 : self.ram_bank;
	// MBC3 banks $08-$0C are the RTC registers, not RAM: keep them out of range
	// (reads $FF, writes dropped) instead of wrapping onto real save RAM.
	if (self.mbc == MBC3 && bank >= 0x08) return self.ram.len;
	bank = wrap_bank(bank, self.ram.len, 0x2000);
	return (usz)bank * 0x2000 + local % (usz)self.ram.len; // 2 KiB RAM mirrors in its bank
}

fn void Cartridge.write(&self, ushort addr, char value) {
	self.rom_mapped = false;
	if (addr < 0x8000) {
		self.write_control(addr, value);
		return;
	}
	// $A000-$BFFF
	switch (self.mbc) {
		case MBC7:  self.mbc7_write(addr, value); return;
		case HUC1:  self.huc1_write(addr, value); return;
		case HUC3:  self.huc3_write(addr, value); return;
		case TAMA5: self.tama5_write(addr, value); return;
		case TPP1:  self.tpp1_write(addr, value); return;
		case CAMERA: self.camera_write(addr, value); return;
		default:    break;
	}
	if (!self.ram_enabled) return;
	if (self.rtc_selected()) {
		self.rtc.write(self.ram_bank, value);
		return;
	}
	if (self.ram.len == 0) return;
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
					// 7 bits (2 MiB); MBC30, on bigger cartridges, has all 8.
					uint b = value & (self.rom.len > 0x200000 ? 0xFF : 0x7F);
					self.rom_bank = b == 0 ? 1 : b;
				case addr < 0x6000: self.ram_bank = value; // 0-3 = RAM, 8-C = RTC
				default: if (self.has_rtc) self.rtc.write_latch(value);
			}
		case MBC5:
			switch {
				case addr < 0x2000: self.ram_enabled = (value & 0x0F) == 0x0A;
				case addr < 0x3000: self.rom_bank = (self.rom_bank & 0x100) | value;
				case addr < 0x4000: self.rom_bank = (self.rom_bank & 0xFF) | ((value & 1) << 8);
				case addr < 0x6000:
					if (self.has_rumble) {
						self.rumble = (value & 8) != 0; // the motor, not a RAM bank bit
						self.rumble_writes++;
						if (self.rumble) self.rumble_on++;
						self.ram_bank = value & 7;
					} else {
						self.ram_bank = value & 0x0F;
					}
				default: break;
			}
		case MMM01: self.mmm01_control(addr, value);
		case HUC1:  self.huc1_control(addr, value);
		case HUC3:  self.huc3_control(addr, value);
		case TAMA5: break; // everything goes through $A000/$A001
		case MBC6:  self.mbc6_control(addr, value);
		case M161:
		case WISDOM: self.big_bank_control(addr, value);
		case TPP1:  self.tpp1_control(addr, value);
		case SACHEN: self.sachen_control(addr, value);
		case CAMERA: self.camera_control(addr, value);
		case MBC7:
			switch {
				case addr < 0x2000: self.ram_enabled = value == 0x0A;
				case addr < 0x4000: self.rom_bank = value;
				case addr < 0x6000: self.mbc7.ram_enabled2 = value == 0x40;
				default: break;
			}
	}
}

// --- MBC7 -------------------------------------------------------------------

fn char Cartridge.mbc7_read(&self, ushort addr) {
	Mbc7* m = &self.mbc7;
	if (!self.ram_enabled || !m.ram_enabled2 || addr >= 0xB000) return 0xFF;
	switch ((addr >> 4) & 0xF) {
		case 2: return (char)m.x_latch;
		case 3: return (char)(m.x_latch >> 8);
		case 4: return (char)m.y_latch;
		case 5: return (char)(m.y_latch >> 8);
		case 6: return 0;
		case 8: return (char)((m.dout ? 1 : 0) | (m.di ? 2 : 0) | (m.clk ? 0x40 : 0) | (m.cs ? 0x80 : 0));
		default: return 0xFF;
	}
}

fn ushort Cartridge.eeprom_word(&self, int i) => (ushort)(self.ram[i * 2] | (ushort)self.ram[i * 2 + 1] << 8);
fn void Cartridge.set_eeprom_word(&self, int i, ushort v) {
	self.ram[i * 2] = (char)v;
	self.ram[i * 2 + 1] = (char)(v >> 8);
}

fn void Cartridge.mbc7_write(&self, ushort addr, char value) {
	Mbc7* m = &self.mbc7;
	if (!self.ram_enabled || !m.ram_enabled2 || addr >= 0xB000) return;
	switch ((addr >> 4) & 0xF) {
		case 0:
			if (value == 0x55) {
				m.latch_ready = true;
				m.x_latch = m.y_latch = 0x8000;
			}
		case 1:
			if (value == 0xAA) {
				m.latch_ready = false;
				m.x_latch = (ushort)(0x81D0 - (int)(0x70 * self.tilt_x));
				m.y_latch = (ushort)(0x81D0 - (int)(0x70 * self.tilt_y));
			}
		case 8:
			m.cs = (value & 0x80) != 0;
			m.di = (value & 2) != 0;
			bool clk = (value & 0x40) != 0;
			if (m.cs && !m.clk && clk) self.eeprom_clock();
			m.clk = clk;
		default:
			break;
	}
}

// A rising CLK with CS high: shift DO out, DI in (93LC56, 8-bit addresses of
// 16-bit words; commands start bit + 2 opcode bits + 8 address bits).
fn void Cartridge.eeprom_clock(&self) {
	Mbc7* m = &self.mbc7;
	m.dout = (m.read_bits >> 15) != 0;
	m.read_bits = (ushort)(m.read_bits << 1 | 1);
	if (m.argument_bits > 0) {
		// The data bits of a WRITE or WRAL, MSB first.
		m.argument_bits--;
		m.dout = true;
		if (m.di && m.write_enabled) {
			ushort bit = (ushort)(1 << m.argument_bits);
			if (m.command & 0x100) {
				int i = m.command & 0x7F;
				self.set_eeprom_word(i, self.eeprom_word(i) | bit);
			} else {
				for (int i = 0; i < 0x80; i++) self.set_eeprom_word(i, self.eeprom_word(i) | bit);
			}
		}
		if (m.argument_bits == 0) {
			m.command = 0;
			m.read_bits = 0x3FFF; // busy for a moment, then ready
		}
		return;
	}
	m.command = (ushort)(m.command << 1 | (m.di ? 1 : 0));
	if ((m.command & 0x400) == 0) return;
	int word = m.command & 0x7F;
	switch ((m.command >> 6) & 0xF) {
		case 0x8: case 0x9: case 0xA: case 0xB: // READ
			m.read_bits = self.eeprom_word(word);
			m.command = 0;
		case 0x3:                               // EWEN
			m.write_enabled = true;
			m.command = 0;
		case 0x0:                               // EWDS
			m.write_enabled = false;
			m.command = 0;
		case 0x4: case 0x5: case 0x6: case 0x7: // WRITE: clear the word, then 16 data bits
			if (m.write_enabled) self.set_eeprom_word(word, 0);
			m.argument_bits = 16;
		case 0xC: case 0xD: case 0xE: case 0xF: // ERASE
			if (m.write_enabled) {
				self.set_eeprom_word(word, 0xFFFF);
				m.read_bits = 0x3FFF;
			}
			m.command = 0;
		case 0x2:                               // ERAL
			if (m.write_enabled) {
				self.ram[..] = 0xFF;
				m.read_bits = 0xFF;
			}
			m.command = 0;
		case 0x1:                               // WRAL: clear all, then 16 data bits
			if (m.write_enabled) self.ram[..] = 0;
			m.argument_bits = 16;
	}
}
