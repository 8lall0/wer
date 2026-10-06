module mmu;

// The Barcode Boy (Shonumi's "Edge of Emulation: Barcode Boy"), the card
// reader for Battle Space and Monster Maker: Barcode Saga. On the link port:
//
//   the game says hello, clocking $10 $07 $10 $07; the reader answers
//   $FF $FF $10 $07 (games only check the last two)
//
//   a card swiped: the reader clocks it into the game (which waits with an
//   external clock): $02, the card's 13-digit JAN number as ASCII, $03,
//   and the same again.

const ulong BARCODE_BYTE_US = 2000; // between the bytes of a swipe

struct BarcodeBoy {
	int      hello;        // bytes of the game's hello so far
	char[30] swipe;        // a card on its way in
	int      swipe_len;
	int      swipe_at;
	ulong    next_at;      // rt_clock of the next byte in
	uint     hz;
}

fn void BarcodeBoy.init(&self, uint hz) {
	*self = { .hz = hz };
}

// A byte the game clocks out: the reader's answer.
fn char BarcodeBoy.exchange(&self, char b) {
	const char[4] ANSWER = { 0xFF, 0xFF, 0x10, 0x07 };
	// The hello is always four bytes: answer them in turn.
	char answer = ANSWER[self.hello];
	self.hello = (self.hello + 1) & 3;
	return answer;
}

faultdef NOT_A_BARCODE;

// Swipe a card: its 13-digit number.
fn void? BarcodeBoy.swipe_card(&self, String digits, ulong now) {
	char[13] d;
	int n;
	foreach (c : digits) {
		if (c == ' ' || c == '-') continue;
		if (c < '0' || c > '9' || n == 13) return NOT_A_BARCODE~;
		d[n++] = c;
	}
	if (n != 13) return NOT_A_BARCODE~;
	for (int copy = 0; copy < 2; copy++) {
		self.swipe[copy * 15] = 0x02;
		self.swipe[copy * 15 + 1 : 13] = d[..];
		self.swipe[copy * 15 + 14] = 0x03;
	}
	self.swipe_len = 30;
	self.swipe_at = 0;
	self.next_at = now;
}

// Between slices of emulation: the next byte of a swipe, once the game waits
// for it.
fn void BarcodeBoy.tick(&self, Mmu* m) {
	if (self.swipe_at >= self.swipe_len || m.rt_clock < self.next_at) return;
	if (m.link_take(self.swipe[self.swipe_at]) < 0) return; // not waiting yet
	self.swipe_at++;
	self.next_at = m.rt_clock + BARCODE_BYTE_US * self.hz / 1_000_000;
}

fn void Mmu.connect_barcode(&self, Link* l, BarcodeBoy* b) {
	*l = { .barcode = b };
	self.link = l;
}
