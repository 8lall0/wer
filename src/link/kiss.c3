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

const int KISS_STEPS = 600;
const ulong KISS_AGAIN = 30000; // a command the game didn't answer: tried again after this

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

// What the game answers a command with.
enum KissAnswer : char {
	NONE,
	ECHO,      // one byte (a write's checksum)
	BYTES,     // its handshake, then bytes and their checksum (reads)
	REGS,      // its handshake, then its registers after the command (8 and a checksum)
	REGS_256,  // ... and 256 bytes and their checksum
}

enum KissState : char {
	KISS_ID,  // what is listening: the GB KISS menu ($CE00)
	MAP_ID,   // ... or Nectaris GB's map mode ($D000)
	WRITE_1,  // a map's first half to the game
	WRITE_2,
	READ_1,   // ... or from it
	READ_2,
	// A file to the GB KISS menu, as a Game Boy sends one (Dan Docs).
	G_FLAG1,  // $CE00 = $01: a transfer starts
	G_START,  // the menu gets ready
	G_TITLE,  // the title and icon (the menu says whether it has the file)
	G_DUP,    // ... it has: it makes way for this one
	G_FLAG5,  // $CE00 = $05
	G_SEARCH, // where the file goes
	G_READ2,
	G_PREP,
	G_HIST,   // the history
	G_DATA,   // the file, 256 bytes at a time
	G_FINISH,
	G_CART,   // the cartridge code
	G_FLAG2,  // $CE00 = $02: done
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
	char[300] rx;
	int    nrx;
	ulong  last;         // the last time anything was looked at
	ulong  failed_at;    // a command went wrong: start it over after KISS_RETRY
	bool   failed;
	bool   again;        // ... unanswered: try it again after KISS_AGAIN
	ulong  done_at;      // the session ended (another can start once the game is back)
	// The session.
	KissState state;
	char[512] map;       // the map to send, or the one received
	bool   has_map;      // there is one to send
	char   offset;       // "TRANCE": where the game's map is
	bool   received;     // a map came in (the frontend saves it)
	bool   sent;         // the map went out
	// A GB KISS file (.gbf) to send to the menu.
	char[16384] gbf;
	int    gbf_len;
	bool   has_gbf;
	bool   gbf_sent;     // it went out
	char   slot;         // the menu's slot for it
	char[256] search;    // the menu's answer to its title, given back to it
	int    gbf_at;       // how much of its data has gone
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

faultdef NOT_A_GBF;

// A GB KISS file (.gbf) to give the GB KISS menu when it receives (Start
// in the menu, or its Receive command).
fn void? KissLink.set_gbf(&self, char[] gbf) {
	if (gbf.len < 7 || gbf.len > self.gbf.len) return NOT_A_GBF~;
	int size = gbf[0] | (int)gbf[1] << 8;
	int meta = 6 + gbf[4] + (gbf[2] & 1 ? 46 : 0);
	if (size != gbf.len || meta > size) return NOT_A_GBF~;
	self.gbf[:gbf.len] = gbf[..];
	self.gbf_len = (int)gbf.len;
	self.has_gbf = true;
}

fn int KissLink.gbf_meta(&self) => 6 + self.gbf[4] + (self.gbf[2] & 1 ? 46 : 0);

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
	self.state = KISS_ID;
	self.send(0x08, 0xCE00, 0xCE00, 0x10, 0, {}, BYTES);
}

// The next part of a file to the menu: 256 bytes, or what is left.
fn void KissLink.gbf_chunk(&self) {
	int raw = self.gbf_len - self.gbf_meta();
	int n = raw - self.gbf_at < 256 ? raw - self.gbf_at : 256;
	int start = self.gbf_meta() + self.gbf_at;
	self.gbf_at += n;
	self.send(0x0A, 0xC500, 0xC600, (char)n, self.gbf_at < raw ? 1 : 0, self.gbf[start:n], REGS);
}

// The command just finished: what comes next.
fn void KissLink.command_done(&self) {
	switch (self.state) {
		case KISS_ID:
			if (self.nrx >= 16 && (String)self.rx[2:13] == "GB KISS MENU ") {
				if (!self.has_gbf) {
					self.status = "the menu wants a file: none to send";
					self.bye();
					return;
				}
				self.slot = self.rx[15];
				self.gbf_at = 0;
				self.state = G_FLAG1;
				self.send(0x0B, 0xCE00, 0xCE00, 1, 0, (char[1]){ 0x01 }[..], ECHO);
				return;
			}
			self.state = MAP_ID;
			self.send(0x08, 0xD000, 0xD000, 8, 0, {}, BYTES);
		case MAP_ID:
			if (self.nrx >= 7 && (String)self.rx[:7] == "RECEIVE") {
				if (!self.has_map) {
					self.status = "the game wants a map: none to send";
					self.bye();
					return;
				}
				self.state = WRITE_1;
				self.send(0x0B, 0xD000, 0xD000, 0, 0, self.map[:256], ECHO);
			} else if (self.nrx >= 7 && (String)self.rx[:6] == "TRANCE") {
				self.offset = self.rx[6];
				ushort a = (ushort)(0x4000 + (int)self.offset * 0x200);
				self.state = READ_1;
				self.send(0x09, a, a, 0, 0, {}, BYTES);
			} else {
				self.status = "not a game the GB KISS LINK knows";
				self.bye();
			}
		case WRITE_1:
			self.state = WRITE_2;
			self.send(0x0B, 0xD100, 0xD100, 0, 0, self.map[256:256], ECHO);
		case WRITE_2:
			self.sent = true;
			self.status = "map sent";
			self.bye();
		case READ_1:
			self.map[:256] = self.rx[:256];
			ushort a = (ushort)(0x4000 + (int)self.offset * 0x200 + 0x100);
			self.state = READ_2;
			self.send(0x09, a, a, 0, 0, {}, BYTES);
		case READ_2:
			self.map[256:256] = self.rx[:256];
			self.received = true;
			self.status = "map received";
			self.bye();
		case G_FLAG1:
			self.state = G_START;
			self.send(0x00, 0xCE00, 0xCE00, 1, 0, {}, NONE);
		case G_START:
		case G_DUP:
			self.state = G_TITLE;
			self.send(0x02, 0xC700, 0xC50C, self.gbf[4], 0, self.gbf[6:self.gbf[4]], REGS_256);
		case G_TITLE:
			self.search[..] = self.rx[9:256];
			if (self.rx[0] == 0x80) {  // the menu has it already: replace it
				self.state = G_DUP;
				self.send(0x06, 0xC700, 0x0910, 0x08, 0x23, self.search[..], REGS);
				return;
			}
			self.state = G_FLAG5;
			self.send(0x0B, 0xCE00, 0xCE00, 1, self.slot, (char[1]){ 0x05 }[..], ECHO);
		case G_FLAG5:
			int raw = self.gbf_len - self.gbf_meta();
			self.state = G_SEARCH;
			self.send(0x03, 0xC700, (ushort)raw, self.slot, self.gbf[2], self.search[..], REGS_256);
		case G_SEARCH:
			self.state = G_READ2;
			self.send(0x08, 0xCE00, 0xDFFC, 2, self.rx[7], {}, BYTES);
		case G_READ2:
			self.state = G_PREP;
			self.send(0x04, 0xC500, 0xFFD2, 0x2E, 0, {}, REGS);
		case G_PREP:
			int hist = self.gbf[2] & 1 ? 46 : 0;
			self.state = G_HIST;
			self.send(0x0A, 0xC500, 0xC600, (char)hist, 0, self.gbf[6 + self.gbf[4]:hist], REGS);
		case G_HIST:
		case G_DATA:
			if (self.gbf_at < self.gbf_len - self.gbf_meta()) {
				self.state = G_DATA;
				self.gbf_chunk();
				return;
			}
			self.state = G_FINISH;
			self.send(0x04, 0xC50B, (ushort)(0x03 - self.gbf_meta()), 0, 0, {}, REGS);
		case G_FINISH:
			self.state = G_CART;
			self.send(0x0A, 0xC500, 0xC50A, 1, 0, self.gbf[3:1], REGS);
		case G_CART:
			self.state = G_FLAG2;
			self.send(0x0B, 0xCE00, 0xCE00, 1, 0, (char[1]){ 0x02 }[..], ECHO);
		case G_FLAG2:
			self.gbf_sent = true;
			self.status = "file sent";
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
	self.send(0x00, 0xCE00, 0xCE00, 1, 0, {}, NONE);
}

// --- commands ----------------------------------------------------------------

fn void KissLink.push(&self, KissStep kind, char value = 0) {
	self.steps[self.nsteps++] = { kind, value };
}

fn void KissLink.push_bytes(&self, char[] data) {
	char sum;
	foreach (b : data) {
		self.push(SEND_CB, b);
		sum += b;
	}
	self.push(SEND_CB, -sum);
}

// The game's handshake, then `n` bytes and their checksum from it.
fn void KissLink.push_answer(&self, int n) {
	self.push(RECV_HS, 0xAA);
	self.push(SEND_HS, 0x55);
	self.push(RECV_HS, 0xC3);
	self.push(SEND_HS, 0x3C);
	for (int i = 0; i <= n; i++) self.push(RECV_CB);
}

// A command: the registers it carries (the game's handlers take local and
// remote addresses, a length (0 = 256) and a parameter from them), the data
// after it, and what the game answers.
fn void KissLink.send(&self, char cmd, ushort local, ushort remote, char len, char param, char[] data, KissAnswer answer) {
	self.nsteps = 0;
	self.at = 0;
	self.nrx = 0;
	self.push(SEND_HS, 0xAA);
	self.push(RECV_HS, 0x55);
	self.push(SEND_HS, 0xC3);
	self.push(RECV_HS, 0x3C);
	self.push(SEND_CB, 0x48);
	self.push(SEND_CB, 0x75);
	self.push_bytes((char[8]){ 0x30, cmd, (char)local, (char)(local >> 8), (char)remote, (char)(remote >> 8), len, param }[..]);
	// $03 and $06 always take 256 bytes; the others what the length says.
	if (data.len || cmd == 0x0A || cmd == 0x0B) {
		int n = cmd == 0x03 || cmd == 0x06 ? 256 : len ? len : 256;
		char[256] buf;
		buf[:data.len < n ? data.len : n] = data[:data.len < n ? data.len : n];
		self.push_bytes(buf[:n]);
	}
	switch (answer) {
		case NONE:     break;
		case ECHO:     self.push(RECV_CB);
		case BYTES:    self.push_answer(len ? len : 256);
		case REGS:     self.push_answer(8);
		case REGS_256:
			self.push_answer(8);
			for (int i = 0; i <= 256; i++) self.push(RECV_CB);
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
	if (kiss_trace) io::eprintfn("kiss %d: %s at step %d/%d %s phase %d (byte $%02X, rises %d)", now, self.at <= 3 ? "unanswered" : "FAILED", self.at, self.nsteps, self.steps[self.at].kind, self.phase, self.byte, self.rises);
	self.light = false;
	self.failed_at = now;
	// No answer to the handshake (the game not listening yet, or busy
	// between two parts of the session): the same command again soon.
	if (self.at <= 3) {
		self.again = true;
		return;
	}
	self.failed = true;
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
	if (now > self.last + KISS_RETRY && !self.failed && !self.again) {
		self.at = 0;
		self.nrx = 0;
		self.last = now;
		self.begin_step(now);
	}
	self.last = now;
	if (self.again) {
		if (now < self.failed_at + KISS_AGAIN) return;
		self.again = false;
		self.at = 0;
		self.nrx = 0;
		self.begin_step(now);
	}
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
