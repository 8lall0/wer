module cart;

// MBC3 real-time clock (cartridge types $0F and $10).
//
// Five registers sit behind RAM "banks" $08-$0C: seconds, minutes, hours, the
// low 8 bits of the day counter, and DH (bit 0 = day bit 8, bit 6 = halt,
// bit 7 = day carry). Reads return the *latched* copy, taken when $00 then $01
// is written to $6000-$7FFF; writes go to the running clock.
//
// While the emulator runs, the clock advances with emulated time (one second
// per CPU_HZ T-cycles). Across sessions it catches up with the wall clock via
// the timestamp stored in the save file (see serialize / deserialize).

const uint RTC_CPU_HZ = 4194304;

// Save format appended after cartridge RAM, shared by VBA-M, BGB, mGBA and
// SameBoy: 5 live + 5 latched registers as little-endian u32, then a u64 Unix
// timestamp.
const usz RTC_SAVE_LEN = 48;

struct Rtc {
	char s;
	char m;
	char h;
	uint day;          // 0..511
	bool halt;
	bool carry;        // day counter overflowed past 511; sticky until written

	char[5] latched;   // S, M, H, DL, DH as of the last latch
	char    latch_last; // last value written to $6000-$7FFF
	uint    subsec;    // T-cycles into the current second
}

// Live register value for RAM bank $08 + idx.
fn char Rtc.reg(&self, int idx) {
	switch (idx) {
		case 0: return self.s;
		case 1: return self.m;
		case 2: return self.h;
		case 3: return (char)(self.day & 0xFF);
		default:
			return (char)(((self.day >> 8) & 1) | (self.halt ? 0x40 : 0) | (self.carry ? 0x80 : 0));
	}
}

fn void Rtc.latch(&self) {
	for (int i = 0; i < 5; i++) self.latched[i] = self.reg(i);
}

// A write to $6000-$7FFF: $00 followed by $01 latches the clock.
fn void Rtc.write_latch(&self, char value) {
	if (self.latch_last == 0 && value == 1) self.latch();
	self.latch_last = value;
}

fn char Rtc.read(&self, uint bank) {
	return self.latched[bank - 8];
}

fn void Rtc.write(&self, uint bank, char value) {
	switch (bank) {
		case 0x08:
			self.s = value & 0x3F;
			self.subsec = 0;        // setting seconds restarts the current second
		case 0x09: self.m = value & 0x3F;
		case 0x0A: self.h = value & 0x1F;
		case 0x0B: self.day = (self.day & 0x100) | value;
		case 0x0C:
			self.day   = (self.day & 0xFF) | ((uint)(value & 1) << 8);
			self.halt  = (value & 0x40) != 0;
			self.carry = (value & 0x80) != 0;
	}
}

// One second. Registers only roll over when they hit their real limit, so an
// out-of-range value a game wrote (e.g. 61 seconds) wraps at its bit width
// without carrying, like the hardware counters.
fn void Rtc.advance_second(&self) {
	self.s = (self.s + 1) & 0x3F;
	if (self.s != 60) return;
	self.s = 0;
	self.m = (self.m + 1) & 0x3F;
	if (self.m != 60) return;
	self.m = 0;
	self.h = (self.h + 1) & 0x1F;
	if (self.h != 24) return;
	self.h = 0;
	if (++self.day < 512) return;
	self.day = 0;
	self.carry = true;
}

fn void Rtc.tick(&self, uint tcycles) {
	if (self.halt) return;
	self.subsec += tcycles;
	while (self.subsec >= RTC_CPU_HZ) {
		self.subsec -= RTC_CPU_HZ;
		self.advance_second();
	}
}

// Catch up after the emulator was closed for `seconds`.
fn void Rtc.advance(&self, long seconds) {
	if (self.halt || seconds <= 0) return;
	const long CYCLE = 512L * 86400; // the day counter wraps after 512 days
	if (seconds >= CYCLE) {
		self.carry = true;
		seconds %= CYCLE;
	}
	for (long i = 0; i < seconds; i++) self.advance_second();
}

fn void put_u32(char[] out, usz at, uint v) {
	for (usz i = 0; i < 4; i++) out[at + i] = (char)(v >> (8 * i));
}

fn uint get_u32(char[] data, usz at) {
	uint v;
	for (usz i = 0; i < 4; i++) v |= (uint)data[at + i] << (8 * i);
	return v;
}

fn void Rtc.serialize(&self, char[] out, long unix_now) {
	for (int i = 0; i < 5; i++) {
		put_u32(out, (usz)i * 4, self.reg(i));
		put_u32(out, 20 + (usz)i * 4, self.latched[i]);
	}
	put_u32(out, 40, (uint)unix_now);
	put_u32(out, 44, (uint)(unix_now >> 32));
}

// Restore from a save block and advance by the time since it was written.
fn void Rtc.deserialize(&self, char[] data, long unix_now) {
	for (int i = 0; i < 5; i++) {
		self.write(0x08 + (uint)i, (char)get_u32(data, (usz)i * 4));
		self.latched[i] = (char)get_u32(data, 20 + (usz)i * 4);
	}
	long saved_at = (long)get_u32(data, 40) | ((long)get_u32(data, 44) << 32);
	self.advance(unix_now - saved_at);
}
