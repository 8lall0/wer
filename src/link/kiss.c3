module mmu;
import std::io;

// The GB KISS LINK (Hudson HC-749, 1998): a PC's infrared modem for the
// HuC-1 and HuC-3 cartridges' infrared port. Here wer is the PC with it:
// Nectaris GB sends a map to it ("send to PC") or gets one from it
// ("receive from PC"), 512 bytes (the game's own format: "NECTAR", the map,
// a checksum).
//
// The protocol, as Hudson's infrared library in the games does it (Nectaris
// GB, ROM bank $1A, $68B8-$6D2E; Shonumi's Dan Docs describe it too):
//
//   a pulse is the LED on, then off as long; its length is the time from
//   one rising edge to the next, which the game counts in loops of 9
//   M-cycles: 15 or more is a 1, less a 0; 26 or more ends a byte
//
//   handshake byte: 8 pulses (MSB first), a long stop pulse, a short one
//
//   command/data byte: the sender lights up and waits; the receiver
//   answers with a "ping" (lights up until the sender goes dark, then goes
//   dark); then 8 pulses and a short closing one
//
//   a command: the sender's handshake ($AA, answered $55; $C3, answered
//   $3C), $48 $75, 8 bytes (status $30, command, local and remote address,
//   length (0 = 256), parameter) and their checksum (the sum, negated);
//   then the command's data, or the other side's answer, which starts with
//   its own handshake
//
//   the map: the GB KISS LINK reads 8 bytes at $D000: "RECEIVE" (it gets a
//   map) or "TRANCE" and the map's offset in $200 units (it sends one).
//   It writes the map to $D000 and $D100 (command $0B; the game answers
//   with the data's checksum), or reads it from battery RAM at $4000 +
//   offset * $200 and $100 on (command $09); command $00 ends.

// Lengths in T-cycles (the game's loops run at the normal speed).
// The game measures a pulse from rising edge to rising edge, but its caller
// takes ~34 M-cycles between two measurements that it doesn't count: a
// pulse counts as (length - 136) / 36 loops. Hudson's own pulses are about
// 700 T-cycles for a 1, 440 for a 0, 1240 for a stop.
const ulong KISS_ONE    = 400;   // on, then off as long: a 1 (18 loops)
const ulong KISS_ZERO   = 200;   // a 0 (7 loops)
const ulong KISS_STOP   = 600;   // a handshake byte's stop pulse (29 loops)
const ulong KISS_CLOSE  = 176;   // the closing pulse
const ulong KISS_BIT    = 15 * 36; // a 1 from the game: this long or more
const ulong KISS_END    = 26 * 36; // ... and this long ends its byte
const ulong KISS_REACT  = 96;    // between seeing the game's LED and answering
const ulong KISS_GAP    = 600;   // before a byte the game has to get ready for
const ulong KISS_WAIT   = 60000; // the game silent this long: start the command over
const ulong KISS_RETRY  = 200000; // ... after this long

const int KISS_STEPS = 300;

bool kiss_trace; // print each step (WER_KISS_TRACE)

enum KissStep : char {
	SEND_HS,  // a handshake byte
	RECV_HS,  // ... from the game: `value` expected
	SEND_CB,  // a command or data byte
	RECV_CB,  // ... from the game (kept in rx)
}

struct KissStepData {
	KissStep kind;
	char value;
}

enum KissState : char {
	ID,       // reading what the game wants
	WRITE_1,  // the map's first half to the game
	WRITE_2,
	READ_1,   // ... or from it
	READ_2,
	BYE,      // ending the session
	DONE,
}

struct KissLink {
	// The command being run, a step at a time.
	KissStepData[KISS_STEPS] steps;
	int    nsteps;
	int    at;
	int    phase;
	ulong  t;            // when the step's current phase began
	char[11] pulse;      // its pulses: 0 one, 1 zero, 2 stop, 3 closing
	int    npulse;
	bool   light;
	// The game's LED, and its pulses while receiving from it.
	bool   gb_led;
	ulong  rise;         // its last rising edge
	int    rises;
	char   byte;
	char[260] rx;
	int    nrx;
	ulong  last;         // the last time anything was looked at
	ulong  failed_at;    // a command went wrong: start it over after KISS_RETRY
	bool   failed;
	ulong  done_at;      // the session ended (another can start once the game is back)
	// The session.
	KissState state;
	char[512] map;       // the map to send, or the one received
	bool   has_map;      // there is one to send
	char   offset;       // "TRANCE": where the game's map is
	bool   received;     // a map came in (the frontend saves it)
	bool   sent;         // the map went out
	String status;       // what happened last, for the frontend (static text)
}

fn void KissLink.init(&self) {
	*self = {};
	self.status = "waiting for the game";
	self.start_session();
}

// A map to give the game when it asks ("receive from PC").
fn void KissLink.set_map(&self, char[] map) {
	self.map[..] = 0;
	usz n = map.len < 512 ? map.len : 512;
	self.map[:n] = map[:n];
	self.has_map = true;
}

fn void Mmu.connect_kiss(&self, Link* l, KissLink* k) {
	*l = { .kiss = k };
	self.link = l;
}

// A Nectaris GB map's name (bytes 8-13), or "".
fn String kiss_map_name(char[] map) {
	if (map.len < 14 || (String)map[:6] != "NECTAR") return "";
	foreach (c : map[8:6]) if (c < 0x20 || c >= 0x7F) return "";
	return (String)map[8:6];
}

// --- the session -----------------------------------------------------------

fn void KissLink.start_session(&self) {
	self.state = ID;
	self.command(0x08, 0xD000, 8);
}

// The command just finished: what comes next.
fn void KissLink.command_done(&self) {
	switch (self.state) {
		case ID:
			if (self.nrx >= 7 && (String)self.rx[:7] == "RECEIVE") {
				if (!self.has_map) {
					self.status = "the game wants a map: none to send";
					self.bye();
					return;
				}
				self.state = WRITE_1;
				self.command(0x0B, 0xD000, 0, self.map[:256]);
			} else if (self.nrx >= 7 && (String)self.rx[:6] == "TRANCE") {
				self.offset = self.rx[6];
				self.state = READ_1;
				self.command(0x09, (ushort)(0x4000 + (int)self.offset * 0x200), 0);
			} else {
				self.status = "not a game the GB KISS LINK knows";
				self.bye();
			}
		case WRITE_1:
			self.state = WRITE_2;
			self.command(0x0B, 0xD100, 0, self.map[256:256]);
		case WRITE_2:
			self.sent = true;
			self.status = "map sent";
			self.bye();
		case READ_1:
			self.map[:256] = self.rx[:256];
			self.state = READ_2;
			self.command(0x09, (ushort)(0x4000 + (int)self.offset * 0x200 + 0x100), 0);
		case READ_2:
			self.map[256:256] = self.rx[:256];
			self.received = true;
			self.status = "map received";
			self.bye();
		case BYE:
			self.state = DONE;
			self.done_at = self.last;
		case DONE:
			break;
	}
}

fn void KissLink.bye(&self) {
	self.state = BYE;
	self.command(0x00, 0xCE00, 1);
}

// --- commands ----------------------------------------------------------------

fn void KissLink.push(&self, KissStep kind, char value = 0) {
	self.steps[self.nsteps++] = { kind, value };
}

// A command: `len` bytes (0 = 256) at `addr`, `data` written there, or read
// from there (commands $08 and $09).
fn void KissLink.command(&self, char cmd, ushort addr, char len, char[] data = {}) {
	self.nsteps = 0;
	self.at = 0;
	self.nrx = 0;
	self.push(SEND_HS, 0xAA);
	self.push(RECV_HS, 0x55);
	self.push(SEND_HS, 0xC3);
	self.push(RECV_HS, 0x3C);
	self.push(SEND_CB, 0x48);
	self.push(SEND_CB, 0x75);
	char[8] head = { 0x30, cmd, (char)addr, (char)(addr >> 8), (char)addr, (char)(addr >> 8), len, 0 };
	char sum;
	foreach (b : head) {
		self.push(SEND_CB, b);
		sum += b;
	}
	self.push(SEND_CB, -sum);
	int n = len ? len : 256;
	if (cmd == 0x0B) {
		sum = 0;
		foreach (b : data[:n]) {
			self.push(SEND_CB, b);
			sum += b;
		}
		self.push(SEND_CB, -sum);
		self.push(RECV_CB);      // the game's echo of the checksum
	} else if (cmd == 0x08 || cmd == 0x09) {
		// The answer: the game's handshake, the bytes, their checksum.
		self.push(RECV_HS, 0xAA);
		self.push(SEND_HS, 0x55);
		self.push(RECV_HS, 0xC3);
		self.push(SEND_HS, 0x3C);
		for (int i = 0; i <= n; i++) self.push(RECV_CB);
	}
	self.begin_step(self.last + KISS_GAP);
}

fn void KissLink.begin_step(&self, ulong t) {
	self.phase = 0;
	self.t = t;
	self.rises = 0;
	self.byte = 0;
	KissStepData s = self.steps[self.at];
	if (s.kind == SEND_HS || s.kind == SEND_CB) {
		self.npulse = 0;
		for (int b = 7; b >= 0; b--) self.pulse[self.npulse++] = (s.value >> b) & 1 ? 0 : 1;
		if (s.kind == SEND_HS) self.pulse[self.npulse++] = 2;
		self.pulse[self.npulse++] = 3;
	}
	// Dark until it starts. A handshake byte then goes out straight away; a
	// command byte starts with the light on, waiting for the ping.
	self.light = false;
	if (s.kind == SEND_HS) self.phase = 3;
}

fn ulong pulse_len(char kind) {
	switch (kind) {
		case 0: return KISS_ONE;
		case 1: return KISS_ZERO;
		case 2: return KISS_STOP;
		default: return KISS_CLOSE;
	}
}

// The pulse train from self.t: the light at `now`, and whether it is over.
fn bool KissLink.train(&self, ulong now) {
	ulong t = self.t;
	for (int i = 0; i < self.npulse; i++) {
		ulong len = pulse_len(self.pulse[i]);
		if (now < t + len) {
			self.light = true;
			return false;
		}
		if (now < t + len * 2) {
			self.light = false;
			return false;
		}
		t += len * 2;
	}
	self.light = false;
	return true;
}

fn ulong KissLink.train_end(&self) {
	ulong t = self.t;
	for (int i = 0; i < self.npulse; i++) t += pulse_len(self.pulse[i]) * 2;
	return t;
}

fn void KissLink.step_done(&self, ulong t) {
	if (kiss_trace) {
		KissStepData s = self.steps[self.at];
		io::eprintfn("kiss %d: step %d/%d %s $%02X done (rx %d)", t, self.at, self.nsteps, s.kind, s.kind == RECV_CB && self.nrx ? self.rx[self.nrx - 1] : s.value, self.nrx);
	}
	self.at++;
	if (self.at < self.nsteps) {
		self.begin_step(t + (self.steps[self.at].kind == SEND_CB || self.steps[self.at].kind == SEND_HS ? KISS_GAP : 0));
		return;
	}
	self.last = t;
	self.command_done();
}

fn void KissLink.fail(&self, ulong now) {
	// The game is done before the goodbye (Nectaris GB leaves its infrared
	// mode after the map): that's the end all the same.
	if (self.state == BYE) {
		self.light = false;
		self.state = DONE;
		self.done_at = now;
		return;
	}
	if (kiss_trace) io::eprintfn("kiss %d: FAILED at step %d/%d %s phase %d (byte $%02X, rises %d)", now, self.at, self.nsteps, self.steps[self.at].kind, self.phase, self.byte, self.rises);
	self.failed = true;
	self.failed_at = now;
	self.light = false;
}

// Time moves on to `now` (it only does when the game looks).
fn void KissLink.advance(&self, ulong now) {
	// A session over and the game gone a while (out of its infrared mode):
	// ready for the next one.
	if (self.state == DONE) {
		if (now < self.done_at + 8 * KISS_RETRY) return;
		self.last = now;
		self.start_session();
		self.t = now;
	}
	// Long unwatched (the game busy elsewhere): the command starts over now.
	if (now > self.last + KISS_RETRY && !self.failed) {
		self.at = 0;
		self.nrx = 0;
		self.last = now;
		self.begin_step(now);
	}
	self.last = now;
	if (self.failed) {
		if (now < self.failed_at + KISS_RETRY) return;
		self.failed = false;
		// Start the whole exchange over: a half-done command leaves the game
		// back at its handshake.
		self.start_session();
		self.t = now;
		return;
	}
	while (self.at < self.nsteps) {
		KissStepData s = self.steps[self.at];
		if (now < self.t) return;
		switch (s.kind) {
			case SEND_HS:
				if (!self.train(now)) return;
				self.step_done(self.train_end());
			case SEND_CB:
				switch (self.phase) {
					case 0:  // light on, waiting for the ping
						self.light = true;
						if (now > self.t + KISS_WAIT) { self.fail(now); return; }
						return;
					case 1:  // the ping seen: go dark
						self.light = false;
						self.phase = 2;
						self.t = now;
						return;
					case 2:  // waiting for the ping to end
						if (now > self.t + KISS_WAIT) { self.fail(now); return; }
						return;
					default: // the bits
						if (!self.train(now)) return;
						self.step_done(self.train_end());
				}
			case RECV_HS:
			case RECV_CB:
				if (s.kind == RECV_CB && self.phase == 1) {
					self.light = true;  // the ping
					self.phase = 2;
					return;
				}
				if (s.kind == RECV_CB && self.phase == 3) {
					self.light = false;
					self.phase = 4;
					return;
				}
				if (now > self.t + KISS_WAIT) { self.fail(now); return; }
				return;
		}
	}
}

// The game's LED changed at `now`.
fn void KissLink.led(&self, bool on, ulong now) {
	self.advance(now);
	bool rose = on && !self.gb_led;
	bool fell = !on && self.gb_led;
	self.gb_led = on;
	if (self.failed || self.at >= self.nsteps || now < self.t) return;
	KissStepData s = self.steps[self.at];
	switch (s.kind) {
		case SEND_CB:
			if (self.phase == 0 && rose) {
				self.phase = 1;
				self.t = now + KISS_REACT;
			} else if (self.phase == 2 && fell) {
				self.phase = 3;
				self.t = now + KISS_REACT;
			}
		case RECV_HS:
			if (!rose && !(fell && self.phase == 9)) return;
			if (fell) {   // the closing pulse is over: the byte is in
				char b = ~self.byte;
				if (b != s.value) { self.fail(now); return; }
				self.step_done(now);
				return;
			}
			if (self.rises++ > 0) {
				ulong len = now - self.rise;
				if (len >= KISS_END) {
					self.phase = 9;
				} else {
					self.byte = (char)(self.byte << 1) | (len < KISS_BIT ? 1 : 0);
				}
			}
			self.rise = now;
			self.t = now;
		case RECV_CB:
			switch (self.phase) {
				case 0:  // the game lights up for its ping: answer it
					if (rose) { self.phase = 1; self.t = now + KISS_REACT; }
				case 2:  // it has gone dark: so do we
					if (fell) { self.phase = 3; self.t = now + KISS_REACT; }
				case 4:  // the bits: 8 pulses, then the closing one
					if (rose) {
						if (self.rises++ > 0) {
							ulong len = now - self.rise;
							self.byte = (char)(self.byte << 1) | (len < KISS_BIT ? 1 : 0);
						}
						self.rise = now;
						self.t = now;
						if (self.rises == 9) self.phase = 5;
					}
				case 5:
					if (fell) {
						self.rx[self.nrx++] = ~self.byte;
						self.step_done(now);
					}
				default:
					break;
			}
		default:
			break;
	}
}

// What the game's sensor sees at `now`.
fn bool KissLink.seen(&self, ulong now) {
	self.advance(now);
	return self.light;
}
