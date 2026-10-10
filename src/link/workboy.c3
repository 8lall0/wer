module mmu;
import std::time, std::time::datetime;

// The WorkBoy, Fabtek's keyboard for the Game Boy (never released): its
// program on the cartridge talks to it over the link cable, clocking every
// byte. Ported from SameBoy's Core/workboy.c (MIT, LICENSE-sameboy), itself
// worked out from the program without the hardware:
//
//   'R': the keyboard's clock, as hex digits ('0'-'F'), one per byte after
//        an answer 'D': $04, $00, seconds, minutes, hours (BCD), day (BCD),
//        month (BCD) | weekday << 5, ..., years since 1900 at $0F
//   'W': the program sets the clock: 2 bytes, then 21 the same way
//        (seconds at 7 ... month at $0B, the day's top 2 bits adding to the
//        year at $14)
//   'O': from then on each byte asks for a key: its code, or $FF for none.
//        Digits and some signs are letters with the keyboard's Shift down,
//        which the program is told by codes of their own.
//
// Each answer comes a byte late: the keyboard shifts out its answer to a
// byte while the next one comes in.

const char WORKBOY_NONE = 0xFF;
const char WORKBOY_SHIFT = 0x40;       // in a key: typed with Shift down
const char WORKBOY_SHIFT_DOWN = 39;
const char WORKBOY_SHIFT_UP = 50;

// The keyboard's own keys (codes of their own, without Shift).
const char WORKBOY_CLOCK = 1;          // F1 ... F9: the program's 9 tools
const char WORKBOY_ESCAPE = 10;
const char WORKBOY_BACKSPACE = 11;
const char WORKBOY_LEFT = 13;
const char WORKBOY_ENTER = 38;
const char WORKBOY_UP = 54;
const char WORKBOY_DOWN = 55;
const char WORKBOY_RIGHT = 56;

struct WorkBoy {
	char     answer;      // the answer the next byte gets
	char     mode;        // 0 until the program talks to it, then 'R', 'W' or 'O'
	char[21] buffer;      // the clock as it was read or is being written
	int      index;       // 'R': in hex digits; 'W': in bytes
	bool     shift;       // the keyboard's Shift, as the program was told
	char[32] keys;        // typed keys on their way (codes | WORKBOY_SHIFT)
	int      key_at;
	int      key_n;
	long     offset;      // seconds the clock runs ahead of the host's local time
	bool     clock_set;   // the program set the clock: offset changed
	long     fixed_now;   // tests: the local time (seconds since 1970), not the host's
}

fn void WorkBoy.init(&self, long offset) {
	*self = { .offset = offset };
}

fn void Mmu.connect_workboy(&self, Link* l, WorkBoy* w) {
	*l = { .workboy = w };
	self.link = l;
}

// The program has talked to the keyboard: it takes the typing.
fn bool WorkBoy.active(&self) => self.mode != 0;

// A key typed (a code above, or one from workboy_key).
fn void WorkBoy.press(&self, char key) {
	if (key == WORKBOY_NONE || self.key_n == self.keys.len) return;
	self.keys[(self.key_at + self.key_n++) % (int)self.keys.len] = key;
}

// A character typed: its key, or WORKBOY_NONE for none. Letters either case.
fn char workboy_key(char c) {
	const String LETTERS = "qwertyuiopasdfghjklzxcvbnm";
	const char[26] CODES = { 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 28, 29, 30, 31, 32, 33, 34, 35, 36, 40, 41, 42, 43, 44, 45, 46 };
	if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
	foreach (i, l : LETTERS) {
		if (l == c) return CODES[i];
	}
	switch (c) {
		case '1':  return 17 | WORKBOY_SHIFT;
		case '2':  return 18 | WORKBOY_SHIFT;
		case '3':  return 19 | WORKBOY_SHIFT;
		case '!':  return 24 | WORKBOY_SHIFT;
		case '~':  return 25 | WORKBOY_SHIFT;
		case '*':  return 26 | WORKBOY_SHIFT;
		case '$':  return 27;
		case '#':  return 27 | WORKBOY_SHIFT;
		case '4':  return 28 | WORKBOY_SHIFT;
		case '5':  return 29 | WORKBOY_SHIFT;
		case '6':  return 30 | WORKBOY_SHIFT;
		case '+':  return 31 | WORKBOY_SHIFT;
		case '-':  return 32 | WORKBOY_SHIFT;
		case '(':  return 35 | WORKBOY_SHIFT;
		case ')':  return 36 | WORKBOY_SHIFT;
		case ';':  return 37;
		case ':':  return 37; // SameBoy's: the same key either way
		case '7':  return 40 | WORKBOY_SHIFT;
		case '8':  return 41 | WORKBOY_SHIFT;
		case '9':  return 42 | WORKBOY_SHIFT;
		case '.':  return 48;
		case '%':  return 44 | WORKBOY_SHIFT;
		case '=':  return 45 | WORKBOY_SHIFT;
		case ',':  return 47;
		case '<':  return 47 | WORKBOY_SHIFT;
		case '>':  return 48 | WORKBOY_SHIFT;
		case '/':  return 49;
		case '?':  return 49 | WORKBOY_SHIFT;
		case '0':  return 51 | WORKBOY_SHIFT;
		case '`':  return 51;  // the umlaut
		case ' ':  return 52;
		case '\'': return 53;
		case '@':  return 53 | WORKBOY_SHIFT;
		default:   return WORKBOY_NONE;
	}
}

// A byte the program clocks out: the answer to the one before.
fn char WorkBoy.exchange(&self, char b) {
	char out = self.answer;
	self.answer = self.reply(b);
	return out;
}

fn char WorkBoy.reply(&self, char b) {
	if (self.mode != 'W' && b == 'R') {
		self.mode = 'R';
		self.index = 1;
		self.read_clock();
		return 'D';
	}
	if (self.mode != 'W' && b == 'W') {
		self.mode = 'W';
		self.index = 0;
		return 'D'; // not known
	}
	if (self.mode != 'W' && (b == 'O' || self.mode == 'O')) {
		self.mode = 'O';
		return self.next_key();
	}
	if (self.mode == 'R') {
		if (self.index / 2 >= (int)self.buffer.len) return 0;
		char v = self.buffer[self.index / 2];
		v = self.index & 1 ? v & 0x0F : v >> 4;
		self.index++;
		return "0123456789ABCDEF"[v];
	}
	if (self.mode == 'W') {
		if (self.index < 2) {
			self.index++;
		} else if (self.index - 2 < (int)self.buffer.len) {
			self.buffer[self.index - 2] = b;
			self.index++;
			if (self.index - 2 == (int)self.buffer.len) {
				self.write_clock();
				self.mode = 'O';
			}
		}
		return 'D';
	}
	return 0;
}

// The next key for the program: Shift first if the key needs it changed.
fn char WorkBoy.next_key(&self) {
	if (!self.key_n) return WORKBOY_NONE;
	char key = self.keys[self.key_at];
	bool shifted = (key & WORKBOY_SHIFT) != 0;
	if (shifted != self.shift) {
		self.shift = shifted;
		return shifted ? WORKBOY_SHIFT_DOWN : WORKBOY_SHIFT_UP;
	}
	self.key_at = (self.key_at + 1) % (int)self.keys.len;
	self.key_n--;
	return key & (char)~WORKBOY_SHIFT;
}

fn char bcd(int v) => (char)(v % 10 + (v / 10 << 4));
fn int from_bcd(char v) => (v & 0x0F) + (v >> 4) * 10;

// Days since 1970-01-01 of a date (proleptic Gregorian), and back.
fn long days_from_civil(long y, int m, int d) {
	y -= m <= 2 ? 1 : 0;
	long era = (y >= 0 ? y : y - 399) / 400;
	long yoe = y - era * 400;
	long doy = (long)((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1);
	long doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
	return era * 146097 + doe - 719468;
}

fn void civil_from_days(long z, long* y, int* m, int* d) {
	z += 719468;
	long era = (z >= 0 ? z : z - 146096) / 146097;
	long doe = z - era * 146097;
	long yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
	long doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
	long mp = (5 * doy + 2) / 153;
	*d = (int)(doy - (153 * mp + 2) / 5 + 1);
	*m = (int)(mp < 10 ? mp + 3 : mp - 9);
	*y = yoe + era * 400 + (*m <= 2 ? 1 : 0);
}

// The host's local time, as seconds since 1970 read as if it were UTC.
fn long WorkBoy.local_now(&self) {
	if (self.fixed_now) return self.fixed_now;
	TzDateTime t = datetime::now().to_local();
	return days_from_civil(t.year, t.month.ordinal + 1, t.day) * 86400 + (long)t.hour * 3600 + (long)t.min * 60 + t.sec;
}

fn void WorkBoy.read_clock(&self) {
	long now = self.local_now() + self.offset;
	long days = now >= 0 ? now / 86400 : (now - 86399) / 86400;
	long secs = now - days * 86400;
	long year;
	int month;
	int day;
	civil_from_days(days, &year, &month, &day);
	int weekday = (int)((days % 7 + 11) % 7); // 1970-01-01 was a Thursday (4)
	self.buffer[..] = 0;
	self.buffer[0] = 4; // not known, but expected
	self.buffer[2] = bcd((int)(secs % 60));
	self.buffer[3] = bcd((int)(secs / 60 % 60));
	self.buffer[4] = bcd((int)(secs / 3600));
	self.buffer[5] = bcd(day);
	self.buffer[6] = bcd(month) | (char)(weekday << 5);
	self.buffer[0x0F] = (char)(year - 1900);
}

fn void WorkBoy.write_clock(&self) {
	int sec = from_bcd(self.buffer[7]);
	int min = from_bcd(self.buffer[8]);
	int hour = from_bcd(self.buffer[9]);
	int day = from_bcd(self.buffer[0x0A] & 0x3F);
	int month = from_bcd(self.buffer[0x0B] & 0x3F);
	long year = 1900 + (long)(char)(self.buffer[0x14] + (self.buffer[0x0A] >> 6));
	if (sec > 59 || min > 59 || hour > 23 || day < 1 || day > 31 || month < 1 || month > 12) return;
	long t = days_from_civil(year, month, day) * 86400 + (long)(hour * 3600 + min * 60 + sec);
	self.offset = t - self.local_now();
	self.clock_set = true;
}
