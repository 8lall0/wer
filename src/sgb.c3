module sgb;

import std::io;

// Super Game Boy: the SNES side of the adapter.
//
// The Game Boy program talks to it by pulsing P1 ($FF00) bits 4-5 (see
// write_p1): a start pulse, 128 data bits (16 bytes, LSB first) and a 0 stop
// bit make one packet. The first byte is command * 8 + number of packets
// (1-7); longer commands continue in further packets of 16 data bytes.
//
// Multiplayer (MLT_REQ) is the one feedback path back to the Game Boy, and
// what games use to detect an SGB: with both P1 lines high, the low nibble
// reads $F - current player, and the player advances when P15 goes 0 -> 1.

const char CMD_PAL01    = 0x00;
const char CMD_PAL23    = 0x01;
const char CMD_PAL03    = 0x02;
const char CMD_PAL12    = 0x03;
const char CMD_ATTR_BLK = 0x04;
const char CMD_ATTR_LIN = 0x05;
const char CMD_ATTR_DIV = 0x06;
const char CMD_ATTR_CHR = 0x07;
const char CMD_SOUND    = 0x08;
const char CMD_SOU_TRN  = 0x09;
const char CMD_PAL_SET  = 0x0A;
const char CMD_PAL_TRN  = 0x0B;
const char CMD_ATRC_EN  = 0x0C;
const char CMD_TEST_EN  = 0x0D;
const char CMD_ICON_EN  = 0x0E;
const char CMD_DATA_SND = 0x0F;
const char CMD_DATA_TRN = 0x10;
const char CMD_MLT_REQ  = 0x11;
const char CMD_JUMP     = 0x12;
const char CMD_CHR_TRN  = 0x13;
const char CMD_PCT_TRN  = 0x14;
const char CMD_ATTR_TRN = 0x15;
const char CMD_ATTR_SET = 0x16;
const char CMD_MASK_EN  = 0x17;

const String[24] COMMAND_NAMES = {
	"PAL01", "PAL23", "PAL03", "PAL12", "ATTR_BLK", "ATTR_LIN", "ATTR_DIV", "ATTR_CHR",
	"SOUND", "SOU_TRN", "PAL_SET", "PAL_TRN", "ATRC_EN", "TEST_EN", "ICON_EN", "DATA_SND",
	"DATA_TRN", "MLT_REQ", "JUMP", "CHR_TRN", "PCT_TRN", "ATTR_TRN", "ATTR_SET", "MASK_EN",
};

const int PACKET_BITS = 128;
const int MAX_PACKETS = 7;

struct Sgb {
	// packet receiver
	char   p1;          // last P1 select bits written (bits 4-5)
	bool   receiving;   // a start pulse was seen
	int    bits;        // data bits of the current packet so far (128 = expect stop bit)
	char[16] packet;

	// a command being assembled from 1-7 packets
	char[16 * MAX_PACKETS] data;
	int    packets_expected;
	int    packets_received;

	// multiplayer
	int    players;     // 1, 2 or 4
	int    player;      // 0-based, selects the joypad id read back

	uint[32] seen;      // commands executed, by code (tests / debugging)
	bool   log;         // print each command to stderr
}

fn Sgb* new() {
	Sgb* s = mem::new(Sgb);
	s.p1 = 0x30;
	s.players = 1;
	return s;
}

fn void Sgb.free(&self) {
	mem::free(self);
}

// Every write to P1, before the normal joypad handling sees it.
fn void Sgb.write_p1(&self, char value) {
	char p1 = value & 0x30;
	char prev = self.p1;
	self.p1 = p1;

	// Multiplayer: P15 (bit 5) rising selects the next joypad.
	if ((prev & 0x20) == 0 && (p1 & 0x20) != 0 && self.players > 1) {
		self.player = (self.player + 1) & (self.players - 1);
	}

	if (p1 == 0x00) {                    // start pulse
		self.receiving = true;
		self.bits = 0;
		self.packet = {};
		return;
	}
	// A bit is the edge from "both high" to one line low.
	if (!self.receiving || prev != 0x30 || p1 == 0x30) return;

	bool one = p1 == 0x10;               // P15 low = 1, P14 low = 0
	if (self.bits < PACKET_BITS) {
		if (one) self.packet[self.bits / 8] |= (char)(1 << (self.bits % 8));
		self.bits++;
		return;
	}
	// The stop bit must be 0; anything else drops the packet.
	self.receiving = false;
	if (!one) self.packet_done();
}

fn void Sgb.packet_done(&self) {
	if (self.packets_received == 0) {
		int len = self.packet[0] & 7;
		self.packets_expected = len == 0 ? 1 : len;
	}
	usz at = (usz)self.packets_received * 16;
	for (usz i = 0; i < 16; i++) self.data[at + i] = self.packet[i];
	self.packets_received++;
	if (self.packets_received < self.packets_expected) return;

	self.packets_received = 0;
	self.execute(self.data[0] >> 3, self.data[:(usz)self.packets_expected * 16]);
}

fn void Sgb.execute(&self, char cmd, char[] data) {
	if (cmd < 32) self.seen[cmd]++;
	if (self.log) {
		String name = cmd < COMMAND_NAMES.len ? COMMAND_NAMES[cmd] : "?";
		io::eprintfn("sgb: %-8s ($%02x, %d packet%s)", name, cmd, data.len / 16, data.len > 16 ? "s" : "");
	}

	switch (cmd) {
		case CMD_MLT_REQ:
			switch (data[1] & 3) {
				case 1:  self.players = 2;
				case 3:  self.players = 4;
				default: self.players = 1;
			}
			self.player &= self.players - 1;
		default:
			break; // colours (step 3) and borders (step 4) follow
	}
}

// The low nibble P1 reads when neither button row is selected: normally $F,
// in multiplayer mode $F - player.
fn char Sgb.joypad_id(&self) {
	return self.players > 1 ? (char)(0xF - self.player) : 0xF;
}
