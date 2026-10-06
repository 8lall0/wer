module cart;

// HuC1, HuC3 and MMM01, after SameBoy (MIT: see LICENSE-sameboy).

// --- HuC1 ($FF) -------------------------------------------------------------
// MBC1-like banking without the RAM enable; $0000 = $0E turns $A000-$BFFF
// into the infrared port (bit 0 out, bit 0 in: 1 = light seen).

fn void Cartridge.huc1_control(&self, ushort addr, char value) {
	switch {
		case addr < 0x2000: self.ir_mode = (value & 0x0F) == 0x0E;
		case addr < 0x4000: self.rom_bank = value & 0x3F;
		case addr < 0x6000: self.ram_bank = value & 0x07;
		default: break;
	}
}

fn char Cartridge.huc1_read(&self, ushort addr) {
	if (self.ir_mode) return 0xC0 | (self.ir_in ? 1 : 0);
	return self.ram_byte(addr);
}

fn void Cartridge.huc1_write(&self, ushort addr, char value) {
	if (self.ir_mode) {
		self.ir_out = (value & 1) != 0;
		return;
	}
	self.set_ram_byte(addr, value);
}

// --- HuC3 ($FE) -------------------------------------------------------------
// $0000-$1FFF picks what $A000-$BFFF is: $0/$A RAM (writable with $A), $B
// clock commands, $C a clock command's result, $D clock status, $E the
// infrared port. The clock counts minutes of the day and days, with an alarm.

struct Huc3 {
	char   mode;
	ushort minutes;       // of the day, 0..1439
	ushort days;
	ushort alarm_minutes;
	ushort alarm_days;
	bool   alarm_enabled;
	char   index;         // the clock register commands address
	char   read;          // the nibble the last read command fetched
	char   flags;
	uint   second;        // emulated seconds into the current minute
}

// A new cartridge, or a save without the clock: values that tell the game
// to have the player set the clock.
const ushort HUC3_UNSET_DAYS    = 0xFFFF;
const ushort HUC3_UNSET_MINUTES = 0xFFF;

// The battery save's clock block after the RAM (SameBoy's layout): u64 Unix
// time of the last whole minute, u16 minutes, days, alarm minutes, alarm
// days, u8 alarm enabled.
const usz HUC3_SAVE_LEN = 17;

fn void Cartridge.huc3_control(&self, ushort addr, char value) {
	switch {
		case addr < 0x2000:
			self.huc3.mode = value & 0x0F;
			self.ram_enabled = self.huc3.mode == 0x0A;
		case addr < 0x4000: self.rom_bank = value & 0x7F;
		case addr < 0x6000: self.ram_bank = value & 0x0F;
		default: break;
	}
}

fn char Cartridge.huc3_read(&self, ushort addr) {
	switch (self.huc3.mode) {
		case 0x0: case 0xA: return self.ram_byte(addr);
		case 0xC: return self.huc3.flags == 0x2 ? 1 : self.huc3.read;
		case 0xE: return self.ir_in ? 1 : 0;
		default:  return 1; // $D: the clock is ready
	}
}

fn void Cartridge.huc3_write(&self, ushort addr, char value) {
	Huc3* h = &self.huc3;
	switch (h.mode) {
		case 0xA:
			self.set_ram_byte(addr, value);
		case 0xB:
			self.huc3_command(value);
		case 0xE:
			self.ir_out = (value & 1) != 0;
		default:
			break; // $0 (RAM read-only), $C, $D: ignored
	}
}

// A clock command: high nibble the command, low nibble its argument.
fn void Cartridge.huc3_command(&self, char value) {
	Huc3* h = &self.huc3;
	char arg = value & 0x0F;
	switch (value >> 4) {
		case 1: // read the register at index, then step
			if (h.index < 3) {
				h.read = (char)((h.minutes >> (h.index * 4)) & 0x0F);
			} else if (h.index < 7) {
				h.read = (char)((h.days >> ((h.index - 3) * 4)) & 0x0F);
			}
			h.index++;
		case 2: case 3: // write the register at index (3: then step)
			int i = h.index;
			switch {
				case i < 3:
					h.minutes = (ushort)((h.minutes & ~(0x0F << (i * 4))) | (arg << (i * 4)));
				case i < 7:
					h.days = (ushort)((h.days & ~(0x0F << ((i - 3) * 4))) | (arg << ((i - 3) * 4)));
				case i >= 0x58 && i <= 0x5A:
					h.alarm_minutes = (ushort)((h.alarm_minutes & ~(0x0F << ((i - 0x58) * 4))) | (arg << ((i - 0x58) * 4)));
				case i >= 0x5B && i <= 0x5E:
					h.alarm_days = (ushort)((h.alarm_days & ~(0x0F << ((i - 0x5B) * 4))) | (arg << ((i - 0x5B) * 4)));
				case i == 0x5F:
					h.alarm_enabled = (arg & 1) != 0;
			}
			if (value >> 4 == 3) h.index++;
		case 4: h.index = (h.index & 0xF0) | arg;
		case 5: h.index = (h.index & 0x0F) | (char)(arg << 4);
		case 6: h.flags = arg;
		default: break;
	}
}

fn void Huc3.advance_minutes(&self, long minutes) {
	for (long i = 0; i < minutes; i++) {
		if (++self.minutes == 60 * 24) {
			self.minutes = 0;
			self.days++;
		}
	}
}

fn void Huc3.tick_second(&self) {
	if (++self.second < 60) return;
	self.second = 0;
	self.advance_minutes(1);
}

fn void Huc3.serialize(&self, char[] out, long unix_now) {
	long at = unix_now - self.second;
	put_u32(out, 0, (uint)at);
	put_u32(out, 4, (uint)(at >> 32));
	put_u16(out, 8, self.minutes);
	put_u16(out, 10, self.days);
	put_u16(out, 12, self.alarm_minutes);
	put_u16(out, 14, self.alarm_days);
	out[16] = self.alarm_enabled ? 1 : 0;
}

fn void Huc3.deserialize(&self, char[] data, long unix_now) {
	long at = (long)get_u32(data, 0) | ((long)get_u32(data, 4) << 32);
	self.minutes = get_u16(data, 8);
	self.days = get_u16(data, 10);
	self.alarm_minutes = get_u16(data, 12);
	self.alarm_days = get_u16(data, 14);
	self.alarm_enabled = data[16] != 0;
	long elapsed = unix_now - at;
	if (elapsed < 0) {
		self.unset();
		return;
	}
	self.advance_minutes(elapsed / 60);
	self.second = (uint)(elapsed % 60);
}

fn void Huc3.unset(&self) {
	self.days = HUC3_UNSET_DAYS;
	self.minutes = HUC3_UNSET_MINUTES;
	self.alarm_enabled = false;
}

fn void put_u16(char[] out, usz at, ushort v) {
	out[at] = (char)v;
	out[at + 1] = (char)(v >> 8);
}

fn ushort get_u16(char[] data, usz at) => (ushort)(data[at] | (ushort)data[at + 1] << 8);

// --- MMM01 ($0B-$0D) --------------------------------------------------------
// A multicart mapper: it starts on the menu in the ROM's last 32 KiB, and the
// menu's writes, until it sets the lock bit, pick the game's place and size
// in the ROM; after that the game sees an MBC1-like mapper of its own.

struct Mmm01 {
	char rom_low;    // 5 bits
	char rom_mid;    // 2 bits
	char rom_high;   // 2 bits
	char rom_mask;   // 4 bits: rom_low bits 1-4 the game can't change
	char ram_low;    // 2 bits
	char ram_high;   // 2 bits
	char ram_mask;   // 2 bits
	bool mbc1_mode;
	bool mbc1_mode_disable;
	bool multiplex;
	bool locked;
	uint rom0_bank;  // the 16 KiB banks at $0000 and $4000 (when locked)
}

// Dumps of MMM01 carts come two ways round: with the menu (and the MMM01
// header) at the end, as the cartridge has it, or moved to the start. The
// latter is turned back so the menu is the last 32 KiB.
fn void mmm01_arrange(char[] rom) {
	if (rom.len <= 0x8000) return;
	char[] menu = mem::temp_array(char, 0x8000);
	menu[..] = rom[:0x8000];
	usz rest = rom.len - 0x8000;
	for (usz i = 0; i < rest; i++) rom[i] = rom[i + 0x8000];
	rom[rest..] = menu[..];
}

// The menu's header, at the start of the ROM's last 32 KiB, says MMM01 (or
// MBC3, as some dumps have it) while the first header says something else.
fn bool mmm01_at_end(char[] rom) {
	if (rom.len <= 0x8000) return false;
	usz end = rom.len - 0x8000;
	for (usz i = 0x104; i < 0x134; i++) {
		if (rom[i] != rom[end + i]) return false;
	}
	char t = rom[end + 0x147];
	return (t >= 0x0B && t <= 0x0D) || t == 0x11;
}

fn void Cartridge.mmm01_control(&self, ushort addr, char value) {
	Mmm01* m = &self.mmm01;
	switch {
		case addr < 0x2000:
			self.ram_enabled = (value & 0x0F) == 0x0A;
			if (!m.locked) {
				m.ram_mask = (value >> 4) & 3;
				m.locked = (value & 0x40) != 0;
			}
		case addr < 0x4000:
			if (!m.locked) m.rom_mid = (value >> 5) & 3;
			char fixed = (char)(m.rom_mask << 1);
			m.rom_low = ((m.rom_low & fixed) | (value & ~fixed)) & 0x1F;
		case addr < 0x6000:
			m.ram_low = (value | ~m.ram_mask) & 3;
			if (!m.locked) {
				m.ram_high = (value >> 2) & 3;
				m.rom_high = (value >> 4) & 3;
				m.mbc1_mode_disable = (value & 0x40) != 0;
			}
		default:
			if (!m.mbc1_mode_disable) m.mbc1_mode = (value & 1) != 0;
			if (!m.locked) {
				m.rom_mask = (value >> 2) & 0x0F;
				m.multiplex = (value & 0x40) != 0;
			}
	}
	self.mmm01_update();
}

fn void Cartridge.mmm01_update(&self) {
	Mmm01* m = &self.mmm01;
	uint low0 = m.rom_low & (uint)(m.rom_mask << 1);
	if (m.multiplex) {
		m.rom0_bank = low0 | (uint)(m.mbc1_mode ? 0 : m.ram_low) << 5 | (uint)m.rom_high << 7;
		self.rom_bank = m.rom_low | (uint)m.ram_low << 5 | (uint)m.rom_high << 7;
		self.ram_bank = m.rom_mid | (uint)m.ram_high << 2;
	} else {
		m.rom0_bank = low0 | (uint)m.rom_mid << 5 | (uint)m.rom_high << 7;
		self.rom_bank = m.rom_low | (uint)m.rom_mid << 5 | (uint)m.rom_high << 7;
		self.ram_bank = m.ram_low | (uint)m.ram_high << 2;
	}
	if (self.rom_bank == m.rom0_bank) self.rom_bank++;
}

fn usz Cartridge.mmm01_rom_offset(&self, ushort addr) {
	usz banks = self.rom.len / 0x4000;
	uint bank;
	if (!self.mmm01.locked) {
		bank = (uint)banks - (addr < 0x4000 ? 2 : 1); // the menu
	} else {
		bank = wrap_bank(addr < 0x4000 ? self.mmm01.rom0_bank : self.rom_bank, self.rom.len, 0x4000);
	}
	return (usz)bank * 0x4000 + (usz)(addr & 0x3FFF);
}
