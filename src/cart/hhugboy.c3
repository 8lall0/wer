module cart;

// Boards and signatures that hhugboy (https://github.com/tzlion/hhugboy, by
// taizou and contributors) knows, written for wer from a description of their
// behaviour (docs/HHUGBOY-BOARDS.md). hhugboy's SKOB LEE8 and LB multicart
// mappers (taizou) are CC0; the logo sums and titles are facts its detection
// relies on.
//   SKOB LEE8   MBC5 whose bank number is shuffled by a mode ($5001, address
//               & $F003) and whose ROM data at $4000-$7FFF is XORed with one
//               of four values ($7000-$7003), picked by the shuffled bank
//               (Final Fantasy X / Space Fighter X, Digimon D-3)
//   2 in 1      Duz's Pokemon compilations: a menu at bank 0, then a write
//               to $A100 moves the whole ROM window to the chosen game
// And recognised here, but run by boards from elsewhere: the LB multicarts
// (SLMULTI), Rocket Games and Smartcom (ROCKET), and second logos that
// bootleg_mbc's CRCs miss.

struct Lee8 {
	char mode;      // bank shuffle: 5 and 7 shuffle, the others don't
	char bank;      // the bank written, before shuffling
	char[4] xors;
	char xor;       // the one applied now
}

struct TwoInOne {
	char base;      // the chosen game's first bank
	bool armed;     // $0000-$1FFF bits 6-7: the next $A100 write picks
	bool chosen;
}

// --- detection ---------------------------------------------------------------

// The sum of the 48 bytes at `at` (a logo).
fn uint logo_sum(char[] rom, usz at) {
	uint sum;
	foreach (b : rom[at : 0x30]) sum += b;
	return sum;
}

fn bool title_has(char[] rom, String what) {
	String title = (String)rom[0x134 : 16];
	return title.contains(what);
}

fn Mbc? hhugboy_mbc(char[] rom) {
	if (rom.len < 0x8000) return NOT_A_BOOTLEG~;
	// LB multicarts: SL 36 in 1 (with Pokemon Gold), Vast Fame 18 in 1 and
	// 12 in 1 Silver.
	if (title_has(rom, "POKEMON_GLDAAUJ") && rom.len == 0x400000) return SLMULTI;
	if (title_has(rom, "TIMER MONSTER") && (rom.len == 0x800000 || rom.len == 0x1000000)) return SLMULTI;
	if ((title_has(rom, "POKEMON RED") && rom[0x148] == 6) || title_has(rom, "SGBPACK")) return POKE2IN1;

	switch (logo_sum(rom, 0x104)) {
		case 2756: // Rocket Games
		case 4850: // Smartcom
			return ROCKET;
		default: break;
	}
	// A "fixed" (decrypted) dump keeps each bank's number in its last byte,
	// and runs as plain MBC5.
	bool fixed = rom[0x7FFF] == 1 && (rom.len < 0xC000 || rom[0xBFFF] == 2);
	switch (logo_sum(rom, 0x184)) {
		case 4048: return HITEK;    // "GK.RX" (Gaoke x Ruanxin)
		case 4639:                  // BBD
		case 3334:                  // "S-GBC" (SKOB's Pocket Monsters Crystal, by BBD)
		case 5092:                  // Fiver Firm
			if (!fixed) return BBD;
		case 4876: return LI_CHENG; // "Niutoude"
		case 4125:                  // Sintax "Kwichvu"
		case 4138:                  // ... a variant (Harry Potter)
			if (rom[0x7FFF] > 1) return SINTAX;
		case 4932:                  // "Yiutoudz"
			if (!fixed) return SKOB;
		case 4844:                  // V.Fame
		case 6127:                  // SOUL (Falchion)
		case 4406:                  // DIGI (italic)
			return VF001;
		case 2692: return GGB81;    // "DIGI."
		default: break;
	}
	return NOT_A_BOOTLEG~;
}

// --- power-on ----------------------------------------------------------------

fn void Cartridge.hhugboy_init(&self) {
	switch (self.mbc) {
		case SKOB:
			self.lee8 = { .mode = 7, .bank = 1, .xors = { 0x55, 0xAA, 0xF0, 0x0F } };
		case POKE2IN1:
			self.two_in_one = {};
			self.ram_enabled = self.ram.len > 0; // the RAM ignores the enable
		default:
			break;
	}
}

// --- SKOB LEE8 ---------------------------------------------------------------

// Destination bit i takes bit LEE8_ORDER[i] of the bank written.
const char[8] LEE8_ORDER = { 1, 0, 3, 2, 7, 5, 4, 6 };

fn char Cartridge.lee8_data(&self, char v) => v ^ self.lee8.xor;

fn void Cartridge.lee8_control(&self, ushort addr, char value) {
	Lee8* l = &self.lee8;
	if (addr >= 0x2000 && addr < 0x3000) {
		l.bank = value;
		if (l.mode == 5 || l.mode == 7) value = reorder_bits(value, &LEE8_ORDER);
		l.xor = l.xors[value & 3];
		self.mbc5_control(addr, value);
		return;
	}
	if ((addr & 0xF003) == 0x5001) {
		l.mode = value & 7;
		self.lee8_control(0x2000, l.bank);
		return;
	}
	if (addr >= 0x7000 && addr < 0x8000) {
		l.xors[addr & 3] = value;
		l.xor = l.xors[self.rom_bank & 3];
		return;
	}
	self.mbc5_control(addr, value);
}

// --- Pokemon 2 in 1 ----------------------------------------------------------

fn usz Cartridge.two_in_one_offset(&self, ushort addr) {
	uint bank = addr < 0x4000 ? self.two_in_one.base : self.rom_bank;
	return (usz)wrap_bank(bank, self.rom.len, 0x4000) * 0x4000 + (usz)(addr & 0x3FFF);
}

fn void Cartridge.two_in_one_control(&self, ushort addr, char value) {
	switch {
		case addr < 0x2000:
			self.two_in_one.armed = (value & 0xC0) == 0xC0;
		case addr < 0x4000:
			uint bank = value & 0x7F;
			self.rom_bank = (bank ? bank : 1) + self.two_in_one.base;
		case addr < 0x6000:
			if (self.ram.len > 0x2000) self.ram_bank = value & 3;
		default:
			break;
	}
}

// A RAM write; false if it picked the game instead.
fn bool Cartridge.two_in_one_write(&self, ushort addr, char value) {
	TwoInOne* t = &self.two_in_one;
	if (addr != 0xA100 || !t.armed || t.chosen) return true;
	switch (value) {
		case 0x01: t.base = 2;
		case 0xC0: t.chosen = true; // the menu's choice stands
		default:   t.base = 66;
	}
	self.rom_bank = t.base + 1;
	return false;
}
