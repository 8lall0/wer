module mmu;

// The card reader of Barcode Taisen Bardigun (TAM, 1998). From Dan Docs
// (shonumi.github.io/dandocs.html#btb): the game clocks $FFs; the reader
// answers $00 until a card is swiped, then the barcode as it passes under
// it, bit by bit: 1 while it sees white, 0 while it sees a bar, about 15
// bits for the thinnest bar. The cards' barcodes are EAN-13 (JAN).

const int BARDIGUN_BITS = 15;   // bits per module (the thinnest bar)
const int BARDIGUN_QUIET = 10;  // modules of white after the code

struct Bardigun {
	char[256] stream;   // a card on its way in
	int       len;
	int       at;
}

fn void Mmu.connect_bardigun(&self, Link* l, Bardigun* b) {
	*l = { .bardigun = b };
	self.link = l;
}

fn char Bardigun.exchange(&self, char b) {
	if (self.at >= self.len) return 0x00;
	return self.stream[self.at++];
}

faultdef NOT_AN_EAN;

// The 95 modules of an EAN-13 code (true: a bar), from its 13 digits.
fn void? ean13(String digits, bool[95]* modules) {
	const String[10] L = { "0001101", "0011001", "0010011", "0111101", "0100011", "0110001", "0101111", "0111011", "0110111", "0001011" };
	const String[10] G = { "0100111", "0110011", "0011011", "0100001", "0011101", "0111001", "0000101", "0010001", "0001001", "0010111" };
	const String[10] R = { "1110010", "1100110", "1101100", "1000010", "1011100", "1001110", "1010000", "1000100", "1001000", "1110100" };
	// Which of L and G the left half uses: set by the first digit.
	const String[10] PARITY = { "LLLLLL", "LLGLGG", "LLGGLG", "LLGGGL", "LGLLGG", "LGGLLG", "LGGGLL", "LGLGLG", "LGLGGL", "LGGLGL" };
	char[13] d;
	int n;
	foreach (c : digits) {
		if (c == ' ' || c == '-') continue;
		if (c < '0' || c > '9' || n == 13) return NOT_AN_EAN~;
		d[n++] = c - '0';
	}
	if (n != 13) return NOT_AN_EAN~;
	DString bits;
	bits.tinit();
	bits.append("101");
	for (int i = 1; i <= 6; i++) bits.append(PARITY[d[0]][i - 1] == 'L' ? L[d[i]] : G[d[i]]);
	bits.append("01010");
	for (int i = 7; i <= 12; i++) bits.append(R[d[i]]);
	bits.append("101");
	foreach (i, c : bits.str_view()) (*modules)[i] = c == '1';
}

// Swipe a card: its 13-digit number.
fn void? Bardigun.swipe(&self, String digits) {
	bool[95] modules;
	ean13(digits, &modules)!;
	self.stream[..] = 0;
	int bit;
	for (int m = 0; m < 95 + BARDIGUN_QUIET; m++) {
		bool white = m >= 95 || !modules[m];
		for (int i = 0; i < BARDIGUN_BITS; i++) {
			if (white) self.stream[bit >> 3] |= (char)(0x80 >> (bit & 7));
			bit++;
		}
	}
	self.len = (bit + 7) >> 3;
	self.at = 0;
}
