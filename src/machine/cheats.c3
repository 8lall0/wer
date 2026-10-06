module mmu;

// Cheat codes.
//
// Game Genie, "ABC-DEF-GHI" (or "ABC-DEF"): the game reads AB from address
// (F^F)CDE of the ROM instead of what is there, and with GHI only where the
// ROM holds that byte (GI rotated right by two, XOR $BA; H is a check),
// which picks one bank out of the many mapped at the same address.
//
// GameShark, "TTVVAAAA": every frame, VV is written to address AAAA (low
// byte first); TT $01 (or $00) the bank in place, $9n (CGB) WRAM bank n.

struct Cheat {
	bool   genie;
	bool   on;
	ushort addr;
	char   value;
	bool   compare;   // Game Genie: only where the ROM holds `old`
	char   old;
	char   type;      // GameShark
}

const int MAX_CHEATS = 64;

struct Cheats {
	Cheat[MAX_CHEATS] list;
	int  count;
	int  genie_on;    // Game Genie codes switched on (the ROM read hook's quick check)
}

fn int hex_digit(char c) {
	switch {
		case c >= '0' && c <= '9': return c - '0';
		case c >= 'a' && c <= 'f': return c - 'a' + 10;
		case c >= 'A' && c <= 'F': return c - 'A' + 10;
		default: return -1;
	}
}

faultdef NOT_A_CODE;

// A code as typed: dashes and spaces are ignored.
fn Cheat? parse_cheat(String text) {
	char[9] d;
	int n;
	foreach (c : text) {
		if (c == '-' || c == ' ') continue;
		int v = hex_digit(c);
		if (v < 0 || n == 9) return NOT_A_CODE~;
		d[n++] = (char)v;
	}
	Cheat ch = { .on = true };
	switch (n) {
		case 6:
		case 9:
			ch.genie = true;
			ch.value = d[0] << 4 | d[1];
			ch.addr = (ushort)((d[5] ^ 0xF) << 12 | d[2] << 8 | d[3] << 4 | d[4]);
			if (n == 9) {
				char gi = d[6] << 4 | d[8];
				ch.compare = true;
				ch.old = (char)((gi >> 2 | gi << 6) ^ 0xBA);
			}
			if (ch.addr >= 0x8000) return NOT_A_CODE~;
		case 8:
			ch.type = d[0] << 4 | d[1];
			ch.value = d[2] << 4 | d[3];
			ch.addr = (ushort)(d[6] << 12 | d[7] << 8 | d[4] << 4 | d[5]);
		default:
			return NOT_A_CODE~;
	}
	return ch;
}

fn void? Cheats.add(&self, String text) {
	if (self.count == MAX_CHEATS) return NOT_A_CODE~;
	self.list[self.count++] = parse_cheat(text)!;
	self.recount();
}

fn void Cheats.recount(&self) {
	self.genie_on = 0;
	foreach (c : self.list[:self.count]) {
		if (c.on && c.genie) self.genie_on++;
	}
}

// A ROM read through the Game Genie.
fn char Cheats.patch(&self, ushort addr, char v) {
	foreach (c : self.list[:self.count]) {
		if (c.on && c.genie && c.addr == addr && (!c.compare || c.old == v)) return c.value;
	}
	return v;
}

// Once a frame: the GameShark's writes.
fn void Mmu.apply_gameshark(&self) {
	if (!self.cheats) return;
	foreach (c : self.cheats.list[:self.cheats.count]) {
		if (!c.on || c.genie) continue;
		if ((c.type & 0xF0) == 0x90 && c.addr >= 0xD000 && c.addr < 0xE000 && self.wram_ext) {
			int bank = c.type & 7;
			if (bank == 0) bank = 1;
			if (bank == 1) {
				self.wram[c.addr - 0xC000] = c.value;
			} else {
				self.wram_ext[(bank - 2) * 0x1000 + (c.addr - 0xD000)] = c.value;
			}
		} else {
			self.set(c.addr, c.value);
		}
	}
}
