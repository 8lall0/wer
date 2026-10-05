// This file is a port of mGBA's TAMA5 mapper (src/gb/mbc/tama5.c,
// Copyright (c) 2013-2016 Jeffrey Pfau), so unlike the rest of wer it is
// under the Mozilla Public License 2.0: https://mozilla.org/MPL/2.0/.
module cart;

// TAMA5 ($FD, Tamagotchi 3): everything goes through two addresses. $A001
// selects a 4-bit register, $A000 writes or reads it. Registers 0/1 are the
// ROM bank, 4-7 a byte to write, and the address and command that act on
// it: the 32-byte RAM, or the TAMA6 clock chip's pages of BCD digits.

const char TAMA5_BANK_LO  = 0x0;
const char TAMA5_BANK_HI  = 0x1;
const char TAMA5_WRITE_LO = 0x4;
const char TAMA5_WRITE_HI = 0x5;
const char TAMA5_ADDR_HI  = 0x6;
const char TAMA5_ADDR_LO  = 0x7;
const char TAMA5_MAX      = 0x8;
const char TAMA5_ACTIVE   = 0xA;
const char TAMA5_READ_LO  = 0xC;
const char TAMA5_READ_HI  = 0xD;

// The clock's page 0 (time) and page 1 (alarm) digits.
const int RTC_SECOND_1  = 0x0;
const int RTC_SECOND_10 = 0x1;
const int RTC_MINUTE_1  = 0x2;
const int RTC_MINUTE_10 = 0x3;
const int RTC_HOUR_1    = 0x4;
const int RTC_HOUR_10   = 0x5;
const int RTC_WEEK      = 0x6;
const int RTC_DAY_1     = 0x7;
const int RTC_DAY_10    = 0x8;
const int RTC_MONTH_1   = 0x9;
const int RTC_MONTH_10  = 0xA;
const int RTC_YEAR_1    = 0xB;
const int RTC_YEAR_10   = 0xC;
const int RTC_24_HOUR   = 0xA; // page 1
const int RTC_LEAP_YEAR = 0xB; // page 1
const int RTC_PAGE      = 0xD;
const int RTC_MAX       = 0x10;

// Commands (address $40-$5F).
const char TAMA6_DISABLE_TIMER = 0x0;
const char TAMA6_ENABLE_TIMER  = 0x1;
const char TAMA6_MINUTE_WRITE  = 0x4;
const char TAMA6_HOUR_WRITE    = 0x5;
const char TAMA6_MINUTE_READ   = 0x6;
const char TAMA6_HOUR_READ     = 0x7;
const char TAMA6_DISABLE_ALARM = 0x10;
const char TAMA6_ENABLE_ALARM  = 0x11;

const char[32] TAMA6_RTC_MASK = {
	0xF, 0x7, 0xF, 0x7, 0xF, 0x3, 0x7, 0xF, 0x3, 0xF, 0x1, 0xF, 0xF, 0x0, 0x0, 0x0,
	0x0, 0x0, 0xF, 0x7, 0xF, 0x3, 0x7, 0xF, 0x3, 0x0, 0x1, 0x3, 0x0, 0x0, 0x0, 0x0,
};

const int[13] DAYS_TO_MONTH = {
	0, 0, 31, 31 + 28, 31 + 28 + 31, 31 + 28 + 31 + 30, 31 + 28 + 31 + 30 + 31,
	31 + 28 + 31 + 30 + 31 + 30, 31 + 28 + 31 + 30 + 31 + 30 + 31,
	31 + 28 + 31 + 30 + 31 + 30 + 31 + 31, 31 + 28 + 31 + 30 + 31 + 30 + 31 + 31 + 30,
	31 + 28 + 31 + 30 + 31 + 30 + 31 + 31 + 30 + 31,
	31 + 28 + 31 + 30 + 31 + 30 + 31 + 31 + 30 + 31 + 30,
};

// The battery save's clock block after the 32 bytes of RAM (mGBA's layout):
// the four pages, two digits a byte, then the u64 Unix time of the last latch.
const usz TAMA5_SAVE_LEN = 40;

struct Tama5 {
	char reg;
	bool disabled;
	char[TAMA5_MAX] regs;
	char[RTC_MAX] timer;
	char[RTC_MAX] alarm;
	char[RTC_MAX] free0;
	char[RTC_MAX] free1;
	long pending;    // emulated seconds since the clock was last brought up to date
}

fn void Tama5.init(&self) {
	self.alarm[RTC_PAGE] = 1;
	self.free0[RTC_PAGE] = 2;
	self.free1[RTC_PAGE] = 3;
}

fn int tama6_day_of_year(int day, int month, int year) {
	if (month < 1 || month > 12) return -1;
	day += DAYS_TO_MONTH[month];
	if (month > 2 && (year & 3) == 0) day++;
	return day;
}

fn int tama6_month(int day, int year) {
	for (int month = 1; month < 12; month++) {
		if (day <= DAYS_TO_MONTH[month + 1]) return month;
		if (month == 2 && (year & 3) == 0) {
			if (day == 60) return 2;
			day--;
		}
	}
	return 12;
}

fn int tama6_day_of_month(int day, int year) {
	for (int month = 1; month < 12; month++) {
		if (day <= DAYS_TO_MONTH[month + 1]) return day - DAYS_TO_MONTH[month];
		if (month == 2 && (year & 3) == 0) {
			if (day == 60) return 29;
			day--;
		}
	}
	return day - DAYS_TO_MONTH[12];
}

// Bring the time page forward by the seconds since the last time.
fn void Tama5.latch(&self) {
	long t = self.pending;
	self.pending = 0;
	if (!t || self.disabled) return;

	char[] r = &self.timer;
	bool is24 = self.alarm[RTC_24_HOUR] != 0;
	long diff = (long)r[RTC_SECOND_1] + (long)r[RTC_SECOND_10] * 10 + t % 60;
	if (diff < 0) {
		diff += 60;
		t -= 60;
	}
	r[RTC_SECOND_1] = (char)(diff % 10);
	r[RTC_SECOND_10] = (char)((diff % 60) / 10);
	t /= 60;
	t += diff / 60;

	diff = (long)r[RTC_MINUTE_1] + (long)r[RTC_MINUTE_10] * 10 + t % 60;
	if (diff < 0) {
		diff += 60;
		t -= 60;
	}
	r[RTC_MINUTE_1] = (char)(diff % 10);
	r[RTC_MINUTE_10] = (char)((diff % 60) / 10);
	t /= 60;
	t += diff / 60;

	diff = r[RTC_HOUR_1];
	if (is24) {
		diff += (long)r[RTC_HOUR_10] * 10;
	} else {
		int hour10 = r[RTC_HOUR_10];
		diff += (long)(hour10 & 1) * 10;
		diff += (long)(hour10 & 2) * 12;
	}
	diff += t % 24;
	if (diff < 0) {
		diff += 24;
		t -= 24;
	}
	if (is24) {
		r[RTC_HOUR_1] = (char)((diff % 24) % 10);
		r[RTC_HOUR_10] = (char)((diff % 24) / 10);
	} else {
		r[RTC_HOUR_1] = (char)((diff % 12) % 10);
		r[RTC_HOUR_10] = (char)((diff % 12) / 10 + (diff / 12) * 2);
	}
	t /= 24;
	t += diff / 24;

	int day = r[RTC_DAY_1] + r[RTC_DAY_10] * 10;
	int month = r[RTC_MONTH_1] + r[RTC_MONTH_10] * 10;
	int year = r[RTC_YEAR_1] + r[RTC_YEAR_10] * 10;
	int leap = self.alarm[RTC_LEAP_YEAR];
	int week = r[RTC_WEEK];
	long d = tama6_day_of_year(day, month, leap) + t;
	while (d <= 0) {
		d += (leap & 3) ? 365 : 366; // the year before
		year--;
		leap--;
	}
	while (d > ((leap & 3) ? 365 : 366)) {
		d -= (year % 4) ? 365 : 366; // the year after
		year++;
		leap++;
	}
	week = (int)((week + d) % 7);
	year %= 100;
	leap &= 3;
	day = tama6_day_of_month((int)d, leap);
	month = tama6_month((int)d, leap);

	r[RTC_WEEK] = (char)week;
	self.alarm[RTC_LEAP_YEAR] = (char)leap;
	r[RTC_DAY_1] = (char)(day % 10);
	r[RTC_DAY_10] = (char)(day / 10);
	r[RTC_MONTH_1] = (char)(month % 10);
	r[RTC_MONTH_10] = (char)(month / 10);
	r[RTC_YEAR_1] = (char)(year % 10);
	r[RTC_YEAR_10] = (char)(year / 10);
}

fn void Tama5.set_page_bits(&self, char and_mask, char or_mask) {
	self.timer[RTC_PAGE] = (self.timer[RTC_PAGE] & and_mask) | or_mask;
	self.alarm[RTC_PAGE] = (self.alarm[RTC_PAGE] & and_mask) | or_mask;
	self.free0[RTC_PAGE] = (self.free0[RTC_PAGE] & and_mask) | or_mask;
	self.free1[RTC_PAGE] = (self.free1[RTC_PAGE] & and_mask) | or_mask;
}

fn void Cartridge.tama5_write(&self, ushort addr, char value) {
	Tama5* t = &self.tama5;
	if (addr & 1) {
		t.reg = value;
		return;
	}
	value &= 0x0F;
	if (t.reg >= TAMA5_MAX) return;
	t.regs[t.reg] = value;
	char address = ((t.regs[TAMA5_ADDR_HI] << 4) & 0x10) | t.regs[TAMA5_ADDR_LO];
	char out = (t.regs[TAMA5_WRITE_HI] << 4) | t.regs[TAMA5_WRITE_LO];
	switch (t.reg) {
		case TAMA5_BANK_LO:
		case TAMA5_BANK_HI:
			self.rom_bank = t.regs[TAMA5_BANK_LO] | (uint)t.regs[TAMA5_BANK_HI] << 4;
		case TAMA5_ADDR_LO:
			switch (t.regs[TAMA5_ADDR_HI] >> 1) {
				case 0x0: // RAM write
					if (address < self.ram.len) self.ram[address] = out;
				case 0x2: // commands
					switch (address) {
						case TAMA6_DISABLE_TIMER:
							t.disabled = true;
							t.set_page_bits(0x7, 0);
						case TAMA6_ENABLE_TIMER:
							t.disabled = false;
							t.timer[RTC_SECOND_1] = 0;
							t.timer[RTC_SECOND_10] = 0;
							t.set_page_bits(0xF, 0x8);
						case TAMA6_MINUTE_WRITE:
							t.timer[RTC_MINUTE_1] = out & 0x0F;
							t.timer[RTC_MINUTE_10] = out >> 4;
						case TAMA6_HOUR_WRITE:
							t.timer[RTC_HOUR_1] = out & 0x0F;
							t.timer[RTC_HOUR_10] = out >> 4;
						case TAMA6_DISABLE_ALARM:
							t.set_page_bits(0xB, 0);
						case TAMA6_ENABLE_ALARM:
							t.set_page_bits(0xF, 0x4);
					}
				case 0x4: // clock register write
					char a = t.regs[TAMA5_WRITE_LO];
					if (a >= RTC_PAGE) break;
					char v = t.regs[TAMA5_WRITE_HI];
					switch (t.regs[TAMA5_ADDR_LO]) {
						case 0: t.timer[a] = v & TAMA6_RTC_MASK[a];
						case 2: t.alarm[a] = v & TAMA6_RTC_MASK[a | 0x10];
						case 4: t.free0[a] = v;
						case 6: t.free1[a] = v;
					}
			}
		default:
			break;
	}
}

fn char Cartridge.tama5_read(&self, ushort addr) {
	Tama5* t = &self.tama5;
	if (addr & 1) return 0xFF;
	char address = ((t.regs[TAMA5_ADDR_HI] << 4) & 0x10) | t.regs[TAMA5_ADDR_LO];
	switch (t.reg) {
		case TAMA5_ACTIVE:
			return 0xF1;
		case TAMA5_READ_LO:
		case TAMA5_READ_HI:
			char value = 0xF0;
			switch (t.regs[TAMA5_ADDR_HI] >> 1) {
				case 0x1: // RAM read
					value = address < self.ram.len ? self.ram[address] : 0xFF;
				case 0x2:
					t.latch();
					switch (address) {
						case TAMA6_MINUTE_READ: value = (t.timer[RTC_MINUTE_10] << 4) | t.timer[RTC_MINUTE_1];
						case TAMA6_HOUR_READ:   value = (t.timer[RTC_HOUR_10] << 4) | t.timer[RTC_HOUR_1];
						default:                value = address;
					}
				case 0x4:
					if (t.reg == TAMA5_READ_HI) break;
					t.latch();
					char a = t.regs[TAMA5_WRITE_LO];
					value = a > RTC_PAGE ? 0 : t.timer[a];
				default:
					break;
			}
			if (t.reg == TAMA5_READ_HI) value >>= 4;
			return value | 0xF0;
		default:
			return 0xF1;
	}
}

fn void Tama5.serialize(&self, char[] out, long unix_now) {
	for (int i = 0; i < 8; i++) {
		out[i]      = (self.timer[i * 2] & 0x0F) | (char)(self.timer[i * 2 + 1] << 4);
		out[8 + i]  = (self.alarm[i * 2] & 0x0F) | (char)(self.alarm[i * 2 + 1] << 4);
		out[16 + i] = (self.free0[i * 2] & 0x0F) | (char)(self.free0[i * 2 + 1] << 4);
		out[24 + i] = (self.free1[i * 2] & 0x0F) | (char)(self.free1[i * 2 + 1] << 4);
	}
	long at = unix_now - self.pending;
	put_u32(out, 32, (uint)at);
	put_u32(out, 36, (uint)(at >> 32));
}

fn void Tama5.deserialize(&self, char[] data, long unix_now) {
	for (int i = 0; i < 8; i++) {
		self.timer[i * 2] = data[i] & 0x0F;
		self.timer[i * 2 + 1] = data[i] >> 4;
		self.alarm[i * 2] = data[8 + i] & 0x0F;
		self.alarm[i * 2 + 1] = data[8 + i] >> 4;
		self.free0[i * 2] = data[16 + i] & 0x0F;
		self.free0[i * 2 + 1] = data[16 + i] >> 4;
		self.free1[i * 2] = data[24 + i] & 0x0F;
		self.free1[i * 2 + 1] = data[24 + i] >> 4;
	}
	long at = (long)get_u32(data, 32) | ((long)get_u32(data, 36) << 32);
	self.pending = unix_now > at ? unix_now - at : 0;
	self.disabled = (self.timer[RTC_PAGE] & 0x8) == 0;
	self.timer[RTC_PAGE] &= 0xC;
	self.alarm[RTC_PAGE] = (self.alarm[RTC_PAGE] & 0xC) | 1;
	self.free0[RTC_PAGE] = (self.free0[RTC_PAGE] & 0xC) | 2;
	self.free1[RTC_PAGE] = (self.free1[RTC_PAGE] & 0xC) | 3;
}
