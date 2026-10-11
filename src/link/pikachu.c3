module mmu;

// The Pokémon Pikachu 2 (Nintendo, 1999), a pedometer pet that sends its
// watts to Pokémon Gold and Silver as a Mystery Gift over infrared: the
// game takes it for another Game Boy whose version byte is 3, so the gift
// is the item the pet chose (by its watts, as Dan Docs lists them) and the
// game's five-a-day limit doesn't apply.
//
// The Mystery Gift protocol, from the pret disassembly of Pokémon Gold
// (engine/link/mystery_gift.asm), with the pet in the role of the other
// Game Boy that pressed A first. Times count the game's timer: "interrupts"
// every 3 ticks of 65536 Hz, data bits 12 ticks (0) or 24 (1) from one
// light-on to the next.
//
//   hello: light off 60, on 4, off 20, on 4, off 4; the other side answers
//     the same way once it has seen two pulses
//   message: off 4, on 4, off 20, then the bits (MSB first), then on 4,
//     off 16
//   block: off 60, a message $5A length, a message of the data, a message
//     of the 16-bit sum of all of them (little-endian); the receiver
//     answers off 60 and a message of its status ($6C: fine)
//
// The exchange: hello, block $96 (the region prefix), empty block; the
// game says hello, sends its region code, an empty block; hello, the pet's
// 20 bytes, empty; the game: hello, $96, empty; hello, the region code back,
// empty; the game: hello, its data, empty; hello, empty block.

const int PIKA_F = 192;       // an interrupt: 3 ticks of the 65536 Hz timer, in rt_clock
const int PIKA_TICK = 64;     // a tick
const int PIKA_VERSION = 3;   // POKEMON_PIKACHU_2_VERSION
const char PIKA_OKAY = 0x6C;  // MG_OKAY
const char PIKA_PREFIX = 0x96;
const char PIKA_MESSAGE = 0x5A;
const ulong PIKA_WAIT_LIMIT = 200_000; // a wait the game would have given up on (~50 ms)

// Watts (0-999) to the gift: indexes in the games' Mystery Gift item list.
const int[11] PIKA_ITEMS = { 13, 0, 9, 19, 21, 23, 16, 17, 22, 18, 34 };
const String[11] PIKA_ITEM_NAMES = { "Eon Mail", "Berry", "Bitter Berry", "Great Ball", "Max Repel", "Ether", "Miracle Berry", "Gold Berry", "Elixir", "Revive", "Rare Candy" };

fn int pika_gift(int watts) => watts >= 999 ? 10 : watts / 100;

enum PikaOp : char {
	OFF,        // light off for `n` interrupts
	ON,
	OFF_T,      // ... for `n` rt_clock
	ON_T,
	WAIT_ON,    // until the game's light comes on
	WAIT_OFF,
	SEND,       // a message: slot `n`
	RECV,       // a message into slot `n` (its length: `len`, or -1: the block's)
}

struct PikaStep {
	PikaOp op;
	int    n;
	int    len;
}

enum PikaState : char {
	IDLE,
	SENDING,    // the steps run
	DONE,
	FAILED,
}

struct Pikachu2 {
	PikaStep[200] steps;
	int        count;
	int        at;           // the step running
	ulong      step_at;      // rt_clock it started
	PikaStep[700] pulses;    // a message being sent, as ON_T / OFF_T
	int        pulse_count;
	int        pulse_at;
	char[24][8] slots;        // messages: 0-5 built, 6-7 received
	int[8]     slot_len;
	// a message coming in
	int        bits_left;
	int        got;
	ulong      last_on;
	bool       ref_seen;
	bool       game_led;
	bool       lit;
	PikaState  state;
	int        tries;
	char       region;       // the game's region code, as it sent it
	char[20]   game_data;    // what the game sent (its version, ID, name ...)
	int        watts;
}

fn void Mmu.connect_pikachu(&self, Link* l, Pikachu2* p) {
	*l = { .pikachu = p };
	self.link = l;
}

fn void Pikachu2.add(&self, PikaOp op, int n = 0, int len = 0) {
	self.steps[self.count++] = { op, n, len };
}

fn void Pikachu2.hello(&self) {
	self.add(OFF, 60);
	self.add(ON, 4);
	self.add(OFF, 20);
	self.add(ON, 4);
	self.add(OFF, 4);
	self.answer_wait();
	self.add(OFF, 60);
}

fn void Pikachu2.answer_wait(&self) {
	self.add(WAIT_ON);
	self.add(WAIT_OFF);
	self.add(WAIT_ON);
	self.add(WAIT_OFF);
}

// The game's hello, answered.
fn void Pikachu2.answer(&self) {
	self.answer_wait();
	self.add(OFF, 60);
	self.add(ON, 4);
	self.add(OFF, 20);
	self.add(ON, 4);
	self.add(OFF, 4);
}

// Slots: 0 the empty block, 1 the prefix, 2 the pet's data, 3 the region
// code (as the game sent it), 4 the status; what comes in: 5 a block's sum,
// 6 its header (or a status), 7 its data.
fn void Pikachu2.send_block(&self, int slot) {
	self.add(OFF, 60);
	self.add(SEND, slot, -2);  // header
	self.add(SEND, slot);
	self.add(SEND, slot, -3);  // sum
	self.add(RECV, 6, 1);      // the status
}

fn void Pikachu2.recv_block(&self, int slot) {
	self.add(RECV, 6, 2);      // $5A, length
	self.add(RECV, slot, -1);
	self.add(RECV, 5, 2);      // the sum
	self.add(OFF, 60);
	self.add(SEND, 4);
}

// Send watts as a Mystery Gift (the game must be on its Mystery Gift screen).
fn void Pikachu2.send(&self, int watts) {
	self.watts = watts;
	self.slot_len[0] = 0;
	self.slots[1][0] = PIKA_PREFIX;
	self.slot_len[1] = 1;
	// The pet as a partner: version, ID, name, Pokédex, sent a decoration,
	// which item, which decoration, its own gift still waiting, padding.
	char[] d = self.slots[2][:20];
	d[..] = 0;
	d[0] = PIKA_VERSION;
	// Its name: what the real one sends isn't known; "PIKACHU" in the
	// games' letters ($80 = A), then the end ($50).
	d[3:11] = 0x50;
	char[7] name = { 0x8F, 0x88, 0x8A, 0x80, 0x82, 0x87, 0x94 };
	d[3:7] = name[..];
	d[16] = (char)PIKA_ITEMS[pika_gift(watts)];
	self.slot_len[2] = 20;
	self.slot_len[3] = 1;
	self.slots[4][0] = PIKA_OKAY;
	self.slot_len[4] = 1;
	self.count = 0;
	self.hello();
	self.send_block(1);
	self.send_block(0);
	self.answer();
	self.recv_block(3);
	self.recv_block(7);
	self.hello();
	self.send_block(2);
	self.send_block(0);
	self.answer();
	self.recv_block(7);
	self.recv_block(7);
	self.hello();
	self.send_block(3);
	self.send_block(0);
	self.answer();
	self.recv_block(7);
	self.recv_block(7);
	self.hello();
	self.send_block(0);
	self.state = SENDING;
	self.tries = 0;
	self.at = -1;
}

fn bool Pikachu2.busy(&self) => self.state == SENDING;

// The step after the running one, starting at `t`.
fn void Pikachu2.next(&self, ulong t) {
	self.at++;
	self.step_at = t;
	self.lit = false;
	if (self.at >= self.count) {
		self.state = DONE;
		return;
	}
	PikaStep s = self.steps[self.at];
	switch (s.op) {
		case ON:
		case ON_T:
			self.lit = true;
		case SEND:
			self.build_message(s);
			self.pulse_at = 0;
			self.lit = self.pulses[0].op == ON_T;
		case RECV:
			int n = s.len;
			if (n == -1) n = self.slots[6][1]; // the length the header said
			if (n > (int)self.slots[s.n].len) n = (int)self.slots[s.n].len;
			self.slot_len[s.n] = n;
			self.bits_left = n * 8;
			self.got = 0;
			self.ref_seen = false;
		default:
			break;
	}
}

// A message as pulses: its preamble, the bits, the end.
fn void Pikachu2.build_message(&self, PikaStep s) {
	char[24] bytes;
	int n;
	if (s.len == -2) {
		bytes[0] = PIKA_MESSAGE;
		bytes[1] = (char)self.slot_len[s.n];
		n = 2;
	} else if (s.len == -3) {
		ushort sum = PIKA_MESSAGE + (ushort)self.slot_len[s.n];
		for (int i = 0; i < self.slot_len[s.n]; i++) sum += self.slots[s.n][i];
		bytes[0] = (char)sum;
		bytes[1] = (char)(sum >> 8);
		n = 2;
	} else {
		n = self.slot_len[s.n];
		bytes[:n] = self.slots[s.n][:n];
	}
	self.pulse_count = 0;
	self.pulse(OFF_T, 4 * PIKA_F);
	self.pulse(ON_T, 4 * PIKA_F);
	self.pulse(OFF_T, 20 * PIKA_F);
	for (int i = 0; i < n * 8; i++) {
		bool one = (bytes[i / 8] >> (7 - i % 8)) & 1 != 0;
		self.pulse(ON_T, 4 * PIKA_TICK);
		self.pulse(OFF_T, (one ? 24 : 12) * PIKA_TICK - 4 * PIKA_TICK);
	}
	self.pulse(ON_T, 4 * PIKA_F);
	self.pulse(OFF_T, 16 * PIKA_F);
}

fn void Pikachu2.pulse(&self, PikaOp op, int t) {
	self.pulses[self.pulse_count++] = { op, t, 0 };
}

// Time goes by to `now`: timed steps end, waits that took too long fail.
fn void Pikachu2.advance(&self, ulong now) {
	if (self.state != SENDING) return;
	if (self.at < 0) self.next(now);
	while (self.state == SENDING) {
		PikaStep s = self.steps[self.at];
		switch (s.op) {
			case ON:
			case OFF:
				ulong end = self.step_at + (ulong)s.n * PIKA_F;
				if (now < end) return;
				self.next(end);
			case SEND:
				ulong end = self.step_at + (ulong)self.pulses[self.pulse_at].n;
				if (now < end) return;
				self.step_at = end;
				if (++self.pulse_at == self.pulse_count) {
					self.next(end);
					break;
				}
				self.lit = self.pulses[self.pulse_at].op == ON_T;
			default:
				// Waiting for the game: not forever.
				if (now - self.step_at < PIKA_WAIT_LIMIT) return;
				self.fail();
				return;
		}
	}
}

fn void Pikachu2.fail(&self) {
	// No answer to the first hello: the game wasn't listening yet; try again
	// (for about ten seconds).
	if (self.at < 10 && ++self.tries < 150) {
		self.at = -1;
		self.lit = false;
		self.step_at = 0;
		return;
	}
	self.state = FAILED;
	self.lit = false;
}

// The game's light changed at `now`.
fn void Pikachu2.led(&self, bool on, ulong now) {
	self.game_led = on;
	self.advance(now);
	if (self.state != SENDING || self.at < 0) return;
	PikaStep s = self.steps[self.at];
	switch (s.op) {
		case WAIT_ON:
			if (on) self.next(now);
		case WAIT_OFF:
			if (!on) self.next(now);
		case RECV:
			self.receive(s, on, now);
		default:
			break;
	}
}

// A message coming in: after the preamble (on, off), each light-on starts
// a bit, measured to the next one; the last one is the end's pulse, then
// its light off ends the message.
fn void Pikachu2.receive(&self, PikaStep s, bool on, ulong now) {
	// Phases: 0 waiting for the preamble's light, 1 for its end, 2 the bits,
	// 3 the end's light going off.
	switch (self.got) {
		case 0:
			if (on) self.got = 1;
			return;
		case 1:
			if (!on) self.got = 2;
			return;
		case 2:
			if (!on) return;
			if (!self.ref_seen) {
				self.ref_seen = true;
				self.last_on = now;
				if (!self.bits_left) self.got = 3;
				return;
			}
			bool one = now - self.last_on >= 18 * PIKA_TICK;
			self.last_on = now;
			int i = self.slot_len[s.n] * 8 - self.bits_left;
			char* b = &self.slots[s.n][i / 8];
			if (i % 8 == 0) *b = 0;
			if (one) *b |= (char)(0x80 >> (i % 8));
			if (--self.bits_left == 0) self.got = 3;
		default:
			if (on) return;
			self.received(s);
			self.next(now);
	}
}

fn void Pikachu2.received(&self, PikaStep s) {
	// The game's region code: sent back to it later.
	if (s.n == 3) self.region = self.slots[3][0];
	// The game's own data (20 bytes): kept.
	if (s.n == 7 && self.slot_len[7] == 20) self.game_data[..] = self.slots[7][:20];
}

// Is the pet's light on, as the game looks at `now`?
fn bool Pikachu2.seen(&self, ulong now) {
	self.advance(now);
	return self.state == SENDING && self.lit;
}
