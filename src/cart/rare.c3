module cart;

// Rare mappers: MBC6 (Net de Get), M161 (Mani's 4 in 1), the Wisdom Tree
// games' mapper, and TPP1 (homebrew: a big ROM, RAM, a clock and rumble).

// A ROM that needs a cartridge mapper: the header names one, or it is one
// of those the header doesn't name (TPP1, M161, Wisdom Tree, Sachen).
fn bool needs_mapper(char[] rom) {
	if (rom.len > 0x147 && mbc_of(rom[0x147]) != NONE) return true;
	if (is_tpp1(rom) || is_wisdom_tree(rom) || is_sachen_mmc1(rom) || is_sachen_mmc2(rom)) return true;
	if (@ok(bootleg_mbc(rom)) || @ok(known_mbc(rom))) return true;
	return rom.len == 0x40000 && (String)rom[0x134 : 10] == "TETRIS SET";
}

// --- MBC6 ($20) -------------------------------------------------------------
// Pan Docs: $4000-$5FFF and $6000-$7FFF are two 8 KiB windows (A, B) on the
// ROM or on an 8 Mbit Macronix MX29F008 flash chip, $A000-$AFFF and
// $B000-$BFFF two 4 KiB windows on 32 KiB of RAM.
//   $0000-$03FF  RAM enable ($0A)           $0400 / $0800  RAM bank A / B (0-7)
//   $0C00-$0FFF  flash enable (bit 0)       $1000          flash write enable
//   $2000 / $3000  ROM/flash bank A / B (8 KiB banks)
//   $2800 / $3800  A / B on the ROM ($00) or the flash ($08)
// The flash takes JEDEC commands: $AA to $5555, $55 to $2AAA (flash
// addresses: bank * $2000 + offset), then $80 (erase: again $AA, $55, then
// $30 at a sector or $10 for all), $90 (ID), $A0 (program: 128 bytes, then
// the last address again commits), $F0 (back to reading). The flash sits in
// the battery save after the RAM (Cartridge.ram: 32 KiB RAM + 1 MiB flash).

const usz MBC6_RAM   = 0x8000;
const usz MBC6_FLASH = 0x100000;

struct Mbc6 {
	uint[2] bank;          // A, B: 8 KiB ROM or flash banks
	bool[2] flash_window;  // ... on the flash
	uint[2] ram_bank;      // 4 KiB RAM banks
	bool flash_on;
	bool flash_write;      // sector 0 and the hidden region may change
	int  cmd;              // the command sequence so far
	bool id_mode;
	bool program_mode;
	bool status;           // reads give the status byte (an operation ran)
}

fn char[] Cartridge.flash(&self) => self.ram[MBC6_RAM..];

fn void Cartridge.mbc6_control(&self, ushort addr, char value) {
	Mbc6* m = &self.mbc6;
	switch {
		case addr < 0x0400: self.ram_enabled = value == 0x0A;
		case addr < 0x0800: m.ram_bank[0] = value & 7;
		case addr < 0x0C00: m.ram_bank[1] = value & 7;
		case addr < 0x1000: m.flash_on = (value & 1) != 0;
		case addr == 0x1000: m.flash_write = (value & 1) != 0;
		case addr >= 0x2000 && addr < 0x2800: m.bank[0] = value & 0x7F;
		case addr >= 0x2800 && addr < 0x3000: m.flash_window[0] = value == 0x08;
		case addr >= 0x3000 && addr < 0x3800: m.bank[1] = value & 0x7F;
		case addr >= 0x3800 && addr < 0x4000: m.flash_window[1] = value == 0x08;
		case addr >= 0x4000:
			int w = addr < 0x6000 ? 0 : 1;
			if (m.flash_window[w] && m.flash_on) self.flash_write_byte(m.bank[w] * 0x2000 + (addr & 0x1FFF), value);
		default: break;
	}
}

fn char Cartridge.mbc6_read_rom(&self, ushort addr) {
	if (addr < 0x4000) return addr < self.rom.len ? self.rom[addr] : 0xFF;
	Mbc6* m = &self.mbc6;
	int w = addr < 0x6000 ? 0 : 1;
	uint at = m.bank[w] * 0x2000 + (addr & 0x1FFF);
	if (!m.flash_window[w]) {
		usz off = (usz)wrap_bank(m.bank[w], self.rom.len, 0x2000) * 0x2000 + (usz)(addr & 0x1FFF);
		return off < self.rom.len ? self.rom[off] : 0xFF;
	}
	if (!m.flash_on) return 0xFF;
	if (m.status) return 0x80;                    // done
	if (m.id_mode) return (at & 1) ? 0x81 : 0xC2; // MX29F008T: Macronix, device $81
	return self.flash()[at % MBC6_FLASH];
}

fn void Cartridge.flash_write_byte(&self, uint at, char v) {
	Mbc6* m = &self.mbc6;
	at %= (uint)MBC6_FLASH;
	if (v == 0xF0) { // back to reading
		m.cmd = 0;
		m.id_mode = false;
		m.program_mode = false;
		m.status = false;
		return;
	}
	if (m.program_mode) {
		// Programming only clears bits; sector 0 needs flash write enable.
		if (at < 0x20000 && !m.flash_write) return;
		self.flash()[at] &= v;
		m.status = true;
		return;
	}
	switch (m.cmd) {
		case 0: m.cmd = at == 0x5555 && v == 0xAA ? 1 : 0;
		case 1: m.cmd = at == 0x2AAA && v == 0x55 ? 2 : 0;
		case 2:
			m.cmd = 0;
			if (at != 0x5555) return;
			switch (v) {
				case 0x80: m.cmd = 3;
				case 0x90: m.id_mode = true;
				case 0xA0: m.program_mode = true;
				default: break;
			}
		case 3: m.cmd = at == 0x5555 && v == 0xAA ? 4 : 0;
		case 4: m.cmd = at == 0x2AAA && v == 0x55 ? 5 : 0;
		case 5:
			m.cmd = 0;
			if (v == 0x30) { // erase the 128 KiB sector holding `at`
				uint sector = at & ~0x1FFFFu;
				if (sector == 0 && !m.flash_write) return;
				self.flash()[sector : 0x20000] = 0xFF;
				m.status = true;
			} else if (v == 0x10 && at == 0x5555) { // erase everything
				if (!m.flash_write) {
					self.flash()[0x20000..] = 0xFF;
				} else {
					self.flash()[..] = 0xFF;
				}
				m.status = true;
			}
		default:
			m.cmd = 0;
	}
}

fn usz Cartridge.mbc6_ram_offset(&self, ushort addr) {
	int w = addr < 0xB000 ? 0 : 1;
	return (usz)self.mbc6.ram_bank[w] * 0x1000 + (usz)(addr & 0x0FFF);
}

// --- M161 and Wisdom Tree: one 32 KiB bank over $0000-$7FFF ----------------
// M161 (Mani's 4 in 1; Pan Docs): any write to $0000-$7FFF picks the bank
// (bits 0-2) once; the mapper then ignores writes until power off.
// Wisdom Tree (mGBA's gbdoc): a write to $0000-$3FFF picks the bank by the
// address written, not the value.

fn void Cartridge.big_bank_control(&self, ushort addr, char value) {
	if (self.mbc == M161) {
		if (self.m161_locked) return;
		self.rom_bank = value & 7;
		self.m161_locked = true;
	} else if (addr < 0x4000) {
		self.rom_bank = addr & 0xFF;
	}
}

fn usz Cartridge.big_bank_offset(&self, ushort addr) {
	return (usz)wrap_bank(self.rom_bank, self.rom.len, 0x8000) * 0x8000 + addr;
}

// The Wisdom Tree games say "no mapper" in their header; their text names
// the publisher.
fn bool is_wisdom_tree(char[] rom) {
	if (rom.len <= 0x8000 || rom[0x147] != 0) return false;
	String text = (String)rom[:0x8000];
	return text.contains("WISDOM TREE") || text.contains("WISDOM\0TREE");
}

// --- TPP1 (header $BC, $C1, $65) ----------------------------------------------
// The TPP1 spec, as SameBoy implements it (MIT: see LICENSE-sameboy): writes
// to $0000-$7FFF set MR0/MR1 (16-bit ROM bank), MR2 (RAM bank) and MR3 (a
// command) by address bits 0-1; MR3 $00/$02/$03/$05 picks what $A000-$BFFF
// shows (the MR registers / RAM read-only / RAM / the latched clock), $10
// latches the clock, $11 sets it from the latch, $14 clears the overflow,
// $18/$19 stop/start it, $20-$23 the rumble strength. Header byte $153:
// bit 0 rumble, bit 2 clock, bit 3 battery; $152: RAM size ($2000 << n-1).
// The clock: seconds, minutes, hours (bits 0-4) with the weekday (5-7),
// weeks. Battery saves: the RAM, then 'TPP1', version $0100, MR4, 0, the
// Unix time (u64) and the clock as read (weeks first).

struct Tpp1 {
	char mode;
	char mr4;             // bit 2 clock running, bit 3 weeks overflowed
	char rumble;          // 0-3
	char[4] real;         // seconds, minutes, hours | weekday << 5, weeks
	char[4] latched;
	uint second;          // emulated cycles towards the next second
}

const usz TPP1_SAVE_LEN = 20;

fn bool is_tpp1(char[] rom) => rom.len > 0x153 && rom[0x147] == 0xBC && rom[0x149] == 0xC1 && rom[0x14A] == 0x65;

fn void Cartridge.tpp1_control(&self, ushort addr, char value) {
	Tpp1* t = &self.tpp1;
	switch (addr & 3) {
		case 0: self.rom_bank = (self.rom_bank & 0xFF00) | value;
		case 1: self.rom_bank = (self.rom_bank & 0x00FF) | (uint)value << 8;
		case 2: self.ram_bank = value;
		default:
			switch (value) {
				case 0x00: case 0x02: case 0x03: case 0x05: t.mode = value;
				case 0x10: t.latched = t.real;
				case 0x11: t.real = t.latched;
				case 0x14: t.mr4 &= (char)~0x08;
				case 0x18: t.mr4 &= (char)~0x04;
				case 0x19: t.mr4 |= 0x04;
				case 0x20: case 0x21: case 0x22: case 0x23:
					t.rumble = value & 3;
					self.rumble = t.rumble != 0;
				default: break;
			}
	}
}

fn char Cartridge.tpp1_read(&self, ushort addr) {
	Tpp1* t = &self.tpp1;
	switch (t.mode) {
		case 0x00:
			switch (addr & 3) {
				case 0:  return (char)self.rom_bank;
				case 1:  return (char)(self.rom_bank >> 8);
				case 2:  return (char)self.ram_bank;
				default: return t.rumble | t.mr4;
			}
		case 0x02:
		case 0x03: return self.ram_byte(addr);
		case 0x05: return t.latched[(addr & 3) ^ 3];
		default:   return 0xFF;
	}
}

fn void Cartridge.tpp1_write(&self, ushort addr, char value) {
	Tpp1* t = &self.tpp1;
	switch (t.mode) {
		case 0x03: self.set_ram_byte(addr, value);
		case 0x05: t.latched[(addr & 3) ^ 3] = value;
		default:   break;
	}
}

fn void Tpp1.tick_second(&self) {
	if (!(self.mr4 & 0x04)) return;
	if (++self.real[0] < 60) return;
	self.real[0] = 0;
	if (++self.real[1] < 60) return;
	self.real[1] = 0;
	char hours = self.real[2] & 0x1F;
	char weekday = self.real[2] >> 5;
	if (++hours == 24) {
		hours = 0;
		if (++weekday == 7) {
			weekday = 0;
			if (++self.real[3] == 0) self.mr4 |= 0x08;
		}
	}
	self.real[2] = hours | (char)(weekday << 5);
}

fn void Tpp1.serialize(&self, char[] out, long unix_now) {
	out[:4] = (char[]){ 'T', 'P', 'P', '1' }[..];
	out[4] = 0x01; // version $0100, big-endian
	out[5] = 0x00;
	out[6] = self.mr4;
	out[7] = 0;
	put_u32(out, 8, (uint)unix_now);
	put_u32(out, 12, (uint)(unix_now >> 32));
	for (int i = 0; i < 4; i++) out[16 + i] = self.real[i ^ 3];
}

fn void Tpp1.deserialize(&self, char[] data, long unix_now) {
	if (data[:4] != (char[]){ 'T', 'P', 'P', '1' }[..]) return;
	self.mr4 = data[6];
	long at = (long)get_u32(data, 8) | ((long)get_u32(data, 12) << 32);
	for (int i = 0; i < 4; i++) self.real[i ^ 3] = data[16 + i];
	if (unix_now > at) self.advance(unix_now - at);
}

// The clock moved on by `seconds` (while wer was closed): whole days at once.
fn void Tpp1.advance(&self, long seconds) {
	if (!(self.mr4 & 0x04)) return;
	long days = seconds / 86400;
	for (long s = 0; s < seconds % 86400; s++) self.tick_second();
	long weekday = (long)(self.real[2] >> 5) + days;
	long weeks = (long)self.real[3] + weekday / 7;
	if (weeks > 0xFF) self.mr4 |= 0x08;
	self.real[2] = (self.real[2] & 0x1F) | (char)((weekday % 7) << 5);
	self.real[3] = (char)weeks;
}
