module mmu;

import std::math;

// The Jaguar JN-100 / JN-2000 and Singer IZEK-1500 sewing machines (2000):
// Raku x Raku Mishin (and Sewing Machine Operation Software, its Singer
// twin) sends them the stitches to sew through the link cable. From Dan
// Docs (shonumi.github.io/dandocs.html#sewingmachines) and the game:
//
// The game clocks each byte itself ($83), then waits with $82 for the
// machine's status byte, which the machine clocks back: $00 here (bit 1 an
// embroidery arm attached, bits 6-7 its safety stop: the game then stops).
// A pattern is $80 $80 $80 $86, then 128-byte packets: $B9, on the first a
// header (checksum seed, -, start X, -, start Y, -), a path's start code
// ($C1-$C4), X/Y pairs, $BC and zeros once the pairs end, at byte 125 $BB
// (more packets follow) or $BA/$BF (the last), then the 16-bit sum of
// bytes 0-125, little-endian. $C7/$E7/$F7 end the path two pairs later: it
// is sewn once; without one it repeats as long as the machine runs. Then
// the game sends $80 to read the status until the next pattern.
//
// X (0-$1F) is where the needle comes down across the presser foot, in 0.25
// mm; Y (0-$20) feeds the fabric by (Y - $14) / 4 mm after each stitch: the
// same unit, so letters come out square, and the game's 1.5 mm stitch is Y
// = $0E. (Dan Docs' table has a quarter of that: at most 1.25 mm a stitch,
// shorter than a sewing machine's shortest usual stitch.) The
// game says to press the machine's start switch: the machine sews by itself
// then, so here a pattern is sewn as soon as it has all come, into a picture
// (SewingMachine.picture).

const uint SEW_DELAY_US = 100;   // from the game's wait to the machine's clock
const usz SEW_PAIRS = 2048;

enum SewState : char {
	IDLE,      // waiting for $80 $80 $80 $86
	PACKETS,   // a pattern's packets
}

struct SewingMachine {
	uint     hz;
	bool     waiting;
	ulong    wait_from;
	char     status;
	SewState state;
	int      starts;       // $80s in a row
	char[128] packet;
	int      at;
	int      packets;      // in this pattern
	bool     path_ended;
	int      after_end;    // pair bytes still to come after $C7/$E7/$F7
	// The pattern: where the needle starts, then its X/Y pairs.
	char     start_x;
	char     start_y;
	char[SEW_PAIRS * 2] pairs;
	usz      len;          // bytes in `pairs`
	bool     once;         // sewn once (a path end), else repeated
	bool     ready;        // a whole pattern, to sew
	bool     bad;          // a packet whose sum was wrong
}

fn void SewingMachine.init(&self, uint hz) {
	*self = { .hz = hz };
}

fn void Mmu.connect_sewing(&self, Link* l, SewingMachine* s) {
	*l = { .sewing = s };
	self.link = l;
}

// A byte the game clocks: the machine takes it, and answers $FF.
fn char SewingMachine.exchange(&self, char b) {
	self.receive(b);
	return 0xFF;
}

// Between slices of a frame: the game waiting for the status, clocked.
fn void SewingMachine.tick(&self, Mmu* m) {
	if ((m.io[0x02] & 0x81) != 0x80) {
		self.waiting = false;
		return;
	}
	if (!self.waiting) {
		self.waiting = true;
		self.wait_from = m.rt_clock;
		return;
	}
	if (m.rt_clock - self.wait_from < (ulong)SEW_DELAY_US * self.hz / 1_000_000) return;
	self.waiting = false;
	(void)m.link_take(self.status);
}

fn void SewingMachine.receive(&self, char b) {
	switch (self.state) {
		case IDLE:
			if (b == 0x80) {
				self.starts++;
				return;
			}
			if (b == 0x86 && self.starts >= 2) {
				self.state = PACKETS;
				self.at = 0;
				self.packets = 0;
				self.len = 0;
				self.once = false;
				self.path_ended = false;
				self.after_end = 0;
			}
			self.starts = 0;
		case PACKETS:
			self.packet[self.at++] = b;
			if (self.at < 128) return;
			self.at = 0;
			self.take_packet();
	}
}

fn void SewingMachine.take_packet(&self) {
	char[] p = &self.packet;
	ushort sum;
	foreach (c : p[:126]) sum += c;
	if (p[0] != 0xB9 || sum != (ushort)(p[126] | (ushort)p[127] << 8)) {
		self.bad = true;
		self.state = IDLE;
		return;
	}
	int from = 1;
	if (self.packets++ == 0) {
		self.start_x = p[4];
		self.start_y = p[6];
		from = 8;
	}
	for (int i = from; i < 125; i++) {
		char c = p[i];
		if (c == 0xBC) break;          // the pairs end: zeros to byte 125
		if (c >= 0xC1 && c <= 0xC4) continue;
		if (c == 0xC7 || c == 0xE7 || c == 0xF7) {
			self.once = true;
			self.after_end = 4;
			continue;
		}
		if (self.path_ended || self.len == self.pairs.len) continue;
		self.pairs[self.len++] = c;
		if (self.after_end && --self.after_end == 0) self.path_ended = true;
	}
	if (p[125] == 0xBB) return;     // more to come
	self.len &= ~(usz)1;
	self.state = IDLE;
	self.ready = self.len >= 2;
}

// --- The fabric ------------------------------------------------------------

const int SEW_PX_MM = 16;           // the picture's pixels per millimetre
const double SEW_LENGTH = 60.0;     // mm of fabric a repeating pattern is sewn on
const int SEW_MAX_STITCHES = 4000;
const double SEW_MARGIN = 6.0;      // mm of fabric around the seam
const double SEW_WIDTH = 7.75;      // mm the needle can swing ($1F)

fn double sew_feed(char y) => ((double)y - 20.0) / 4.0;

// Where the needle comes down on the fabric, in mm (x across, y along the
// seam, growing as it is sewn): at most xs.len drops.
fn int SewingMachine.drops(&self, double[] xs, double[] ys) {
	usz pairs = self.len / 2;
	if (!pairs) return 0;
	int n;
	// From the start the header gives to the first pair.
	char y1 = self.pairs[1];
	double fabric = sew_feed(y1 >= 0x1A ? y1 : self.start_y);
	usz i;
	while (n < xs.len) {
		xs[n] = (double)self.pairs[i * 2] * 0.25;
		ys[n] = -fabric;
		n++;
		fabric += sew_feed(self.pairs[i * 2 + 1]);
		if (++i < pairs) continue;
		if (self.once || math::abs(fabric) >= SEW_LENGTH) break;
		i = 0;
	}
	return n;
}

// The pattern sewn: thread on fabric, RGB, `*w` x `*h`, the seam running
// from left to right (lettering sewn across, 横ぬい, reads along it).
fn char[] SewingMachine.picture(&self, int* w, int* h, Allocator alloc) {
	double[] xs = mem::temp_array(double, SEW_MAX_STITCHES);
	double[] ys = mem::temp_array(double, SEW_MAX_STITCHES);
	int n = self.drops(xs, ys);
	double first = 0;
	double last = 0;
	for (int i = 0; i < n; i++) {
		first = math::min(first, ys[i]);
		last = math::max(last, ys[i]);
	}
	*w = (int)((last - first + 2 * SEW_MARGIN) * SEW_PX_MM);
	*h = (int)((SEW_WIDTH + 2 * SEW_MARGIN) * SEW_PX_MM);
	char[] rgb = alloc::alloc_array(alloc, char, (sz)*w * *h * 3);
	for (usz i = 0; i < rgb.len; i += 3) {
		rgb[i] = 0xF2;
		rgb[i + 1] = 0xEC;
		rgb[i + 2] = 0xDA;
	}
	for (int i = 1; i < n; i++) {
		draw_thread(rgb, *w, *h, sew_px(ys[i - 1] - first), sew_px(SEW_WIDTH - xs[i - 1]),
			sew_px(ys[i] - first), sew_px(SEW_WIDTH - xs[i]));
	}
	return rgb;
}

fn int sew_px(double mm) => (int)((mm + SEW_MARGIN) * SEW_PX_MM);

// Thread: a line two pixels wide.
fn void draw_thread(char[] rgb, int w, int h, int x0, int y0, int x1, int y1) {
	int steps = math::max(math::abs(x1 - x0), math::abs(y1 - y0));
	if (!steps) steps = 1;
	for (int s = 0; s <= steps; s++) {
		int x = x0 + (x1 - x0) * s / steps;
		int y = y0 + (y1 - y0) * s / steps;
		for (int dy = 0; dy < 2; dy++) {
			for (int dx = 0; dx < 2; dx++) {
				int px = x + dx;
				int py = y + dy;
				if (px < 0 || py < 0 || px >= w || py >= h) continue;
				usz o = ((usz)py * (usz)w + (usz)px) * 3;
				rgb[o] = 0x2A;
				rgb[o + 1] = 0x3C;
				rgb[o + 2] = 0x8C;
			}
		}
	}
}
