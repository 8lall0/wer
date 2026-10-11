module mmu;

// ASCII's Turbo File GB (ASC-1501T), an external save drive with a memory
// card slot, for RPG Tsukuru GB and Uchuu Nin Tanaka Tarou de RPG Tsukuru
// GB2. Written from Dan Docs (shonumi.github.io/dandocs.html#tbgb); GBE+
// consulted for the byte timing. The drive clocks the cable: the game puts
// a byte in SB, waits (external clock), and gets the drive's answer to that
// same byte.
//
//   $6C (until the drive says $C6), then $5A, command, parameters, checksum
//   (= -sum of $5A..parameters), then $F1 $7E (answered $E7 $A5); the game
//   then clocks $F2s and reads the reply: command, $00, status, data,
//   checksum (= $5B - sum).
//
//   $10 status: + card ($05 with a card, $01 without), bank (7 bits each)
//   $20 begin, $24 end; $22 / $23 write / read bank (bit 7, bits 0-6)
//   $30 write 64 bytes at a 13-bit offset; $40 read 64 bytes
//
// 1 MiB inside (banks $00-$7F of 8 KiB) and 1 MiB on the card ($80-$FF):
// `data` is both, 2 MiB.

const usz TURBO_SIZE = 0x200000;
const ulong TURBO_BYTE_US = 100; // between the bytes the drive clocks

enum TurboState : char {
	SYNC,       // waiting for $6C
	BODY,
	END_SYNC,   // $F1 $7E
	REPLY,
}

struct TurboFile {
	char[]     data;          // TURBO_SIZE bytes (the frontend's)
	bool       changed;       // written to: save it
	TurboState state;
	char[80]   packet;        // the game's, from $5A
	int        len;
	char[80]   reply;
	int        reply_len;
	int        reply_at;
	bool       synced;        // $F1 seen
	int        bank;
	char       status;        // bit 0 ready, bit 3 a bank was set
	ulong      next_at;
	uint       hz;
}

fn void TurboFile.init(&self, char[] data, uint hz) {
	*self = { .data = data, .hz = hz, .status = 0x03 };
}

fn void Mmu.connect_turbo(&self, Link* l, TurboFile* t) {
	*l = { .turbo = t };
	self.link = l;
}

// A command's whole packet length, from $5A: magic, command, parameters,
// checksum (0: not known yet).
fn int turbo_packet_len(char command) {
	switch (command) {
		case 0x10:
		case 0x24: return 3;
		case 0x20: return 4;
		case 0x22:
		case 0x23:
		case 0x40: return 5;
		case 0x30: return 69;
		default:   return 3; // unknown: taken as having no parameters
	}
}

// Between slices of emulation: the next byte, once the game waits for it.
fn void TurboFile.tick(&self, Mmu* m) {
	if (m.rt_clock < self.next_at || (m.io[0x02] & 0x81) != 0x80) return;
	char answer = self.answer(m.io[0x01]);
	m.link_take(answer);
	self.next_at = m.rt_clock + TURBO_BYTE_US * self.hz / 1_000_000;
}

// The game's byte in, the drive's answer to it out (the same transfer).
fn char TurboFile.answer(&self, char b) {
	switch (self.state) {
		case SYNC:
			if (b != 0x6C) return 0x00;
			self.state = BODY;
			self.len = 0;
			return 0xC6;
		case BODY:
			if (self.len < self.packet.len) self.packet[self.len++] = b;
			if (self.len >= 2 && self.len == turbo_packet_len(self.packet[1])) {
				self.run();
				self.state = END_SYNC;
				self.synced = false;
			}
			return 0x00;
		case END_SYNC:
			if (b == 0xF1) {
				self.synced = true;
				return 0xE7;
			}
			if (b == 0x7E && self.synced) {
				self.state = REPLY;
				self.reply_at = 0;
				return 0xA5;
			}
			return 0x00;
		case REPLY:
			char out = self.reply[self.reply_at++];
			if (self.reply_at == self.reply_len) self.state = SYNC;
			return out;
	}
}

fn usz TurboFile.offset(&self) => (usz)self.bank * 0x2000 + ((usz)(self.packet[2] & 0x1F) << 8 | self.packet[3]);

// The packet in, the reply ready.
fn void TurboFile.run(&self) {
	char command = self.packet[1];
	self.reply[0] = command;
	self.reply[1] = 0;
	self.reply[2] = self.status;
	int n = 3;
	switch (command) {
		case 0x10:
			self.reply[3] = 0x05; // a card in
			self.reply[4] = (char)(self.bank >> 7);
			self.reply[5] = (char)(self.bank & 0x7F);
			self.reply[6] = 0;
			self.reply[7] = 0;
			n = 8;
		case 0x22:
		case 0x23:
			self.bank = (self.packet[2] & 1) << 7 | (self.packet[3] & 0x7F);
			self.status |= 0x08;
			self.reply[2] = self.status;
		case 0x30:
			usz at = self.offset();
			self.data[at : 64] = self.packet[4 : 64];
			self.changed = true;
		case 0x40:
			usz at = self.offset();
			self.reply[3 : 64] = self.data[at : 64];
			n = 67;
		default:
			break;
	}
	char sum = 0x5B;
	for (int i = 0; i < n; i++) sum -= self.reply[i];
	self.reply[n] = sum;
	self.reply_len = n + 1;
}
