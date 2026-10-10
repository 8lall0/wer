module sgb;

import std::io;
import ppu;

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
//
// Colours: the SNES sees the finished Game Boy picture as shades 0-3 (after
// BGP/OBP) and colours it by position: the screen is 20x18 cells of 8x8
// pixels, each cell uses one of 4 palettes (`attr`), and a shade picks the
// palette's colour. Colour 0 is shared by all four palettes.
//
// Border: CHR_TRN sends up to 256 SNES tiles, PCT_TRN a 32x28 map and three
// 16-colour palettes (4-6). The output is always the SNES screen, 256x224,
// with the Game Boy picture at (48, 40). Border colour 0 is transparent,
// anything else covers what is behind it. Until a game sends a border (and
// for games that never do) the frame is filled with the darkest colour of
// palette 0.
//
// *_TRN commands move 4 KiB through the picture itself: the game shows tiles
// $00-$FF on the BG and the SNES reads them out during the next frame
// (capture_transfer).

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

const int COLS = 20;              // 8x8 cells across the Game Boy screen
const int ROWS = 18;
const int ATF_COUNT = 45;         // attribute files in ATTR_TRN data
const int ATF_LEN = 90;           // 18 rows x 5 bytes (4 cells per byte)
const usz TRN_LEN = 4096;

// The SNES screen, and where the Game Boy picture sits in it.
const int BORDER_W = 256;
const int BORDER_H = 224;
const int GB_X = 48;
const int GB_Y = 40;

// MASK_EN modes
const char MASK_NONE   = 0;
const char MASK_FREEZE = 1;
const char MASK_BLACK  = 2;
const char MASK_COLOR0 = 3;

struct Sgb {
	// packet receiver
	char   p1;          // last P1 select bits written (bits 4-5)
	bool   receiving;   // a start pulse was seen
	bool   starting;    // ... and P1 hasn't gone back to $30 since
	char   low;         // the line last pulled low since $30 ($10 or $20; 0: none)
	int    bits;        // data bits of the current packet so far (128 = expect stop bit)
	char[16] packet;

	// a command being assembled from 1-7 packets
	char[16 * MAX_PACKETS] data;
	int    packets_expected;
	int    packets_received;

	// multiplayer
	int    players;     // 1, 2 or 4 (3: MLT_REQ's unofficial mode 2)
	int    player;      // 0-based, selects the joypad id read back

	uint[32] seen;      // commands executed, by code (tests / debugging)
	bool   log;         // print each command to stderr

	// colours
	ushort[4][4]  pal;              // visible palettes 0-3, BGR555; [p][0] is shared
	char[COLS * ROWS] attr;         // palette per 8x8 cell
	ushort[4][512] sys_pal;         // system palettes (PAL_TRN)
	char[ATF_COUNT * ATF_LEN] atf;  // attribute files (ATTR_TRN)
	char   mask;                    // MASK_EN mode
	char[ppu::WIDTH * ppu::HEIGHT] frozen; // shades shown while MASK_FREEZE

	// border
	char[256 * 32]   border_tiles;  // SNES 4bpp tiles (CHR_TRN)
	ushort[32 * 28]  border_map;    // PCT_TRN: tile, palette, flips
	ushort[16][3]    border_pal;    // palettes 4-6
	bool             has_border;    // a PCT_TRN arrived: draw the game's border
	char[ppu::WIDTH * ppu::HEIGHT * 3] screen_rgb; // coloured GB picture before compositing

	// a *_TRN command waiting for the next frame (0xFF = none)
	char   pending_trn;
	char   chr_half;              // CHR_TRN: 0 = tiles $00-$7F, 1 = $80-$FF
}

fn Sgb* new() {
	Sgb* s = mem::new(Sgb);
	s.p1 = 0x30;
	s.players = 1;
	s.pending_trn = 0xFF;
	return s;
}

// As the SNES side is when a game starts: no packet on the way, one player
// (what a boot ROM did over the link is forgotten; the colours stay).
fn void Sgb.reset_link(&self) {
	self.p1 = 0x30;
	self.receiving = false;
	self.starting = false;
	self.low = 0;
	self.bits = 0;
	self.packet = {};
	self.packets_expected = 0;
	self.packets_received = 0;
	self.players = 1;
	self.player = 0;
}

fn void Sgb.free(&self) {
	mem::free(self);
}

// Every write to P1, before the normal joypad handling sees it.
fn void Sgb.write_p1(&self, char value) {
	char p1 = value & 0x30;
	char prev = self.p1;
	self.p1 = p1;

	// Multiplayer: P15 (bit 5) rising selects the next joypad (2 or 4
	// players; the glitched 3-player mode doesn't advance).
	if ((prev & 0x20) == 0 && (p1 & 0x20) != 0 && (self.players == 2 || self.players == 4)) {
		self.player = (self.player + 1) & (self.players - 1);
	}

	// Both lines low, whenever: a start pulse (a packet being sent is
	// dropped). It only takes once P1 is back at $30.
	if (p1 == 0x00) {
		self.receiving = true;
		self.starting = true;
		self.bits = 0;
		self.packet = {};
		self.low = 0;
		return;
	}
	if (!self.receiving) return;
	if (p1 != 0x30) {                    // one line low: what the bit will be
		if (!self.starting) self.low = p1;
		return;
	}
	if (self.starting) {
		self.starting = false;
		return;
	}
	// Back to $30: a bit, by the line that was low last (P15 = 1, P14 = 0;
	// $20 then $10 is a 1). (CasualPokePlayer's sgb-ext-test.)
	if (!self.low) return;
	bool one = self.low == 0x10;
	self.low = 0;
	if (self.bits < PACKET_BITS) {
		if (one) self.packet[self.bits / 8] |= (char)(1 << (self.bits % 8));
		self.bits++;
		return;
	}
	// The stop bit: whatever its value, the packet is done.
	self.receiving = false;
	self.packet_done();
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
		case CMD_PAL01: self.set_pals(0, 1, data);
		case CMD_PAL23: self.set_pals(2, 3, data);
		case CMD_PAL03: self.set_pals(0, 3, data);
		case CMD_PAL12: self.set_pals(1, 2, data);
		case CMD_PAL_SET: self.pal_set(data);
		case CMD_ATTR_BLK: self.attr_blk(data);
		case CMD_ATTR_LIN: self.attr_lin(data);
		case CMD_ATTR_DIV: self.attr_div(data);
		case CMD_ATTR_CHR: self.attr_chr(data);
		case CMD_ATTR_SET:
			self.apply_atf(data[1] & 0x3F);
			if (data[1] & 0x40) self.mask = MASK_NONE;
		case CMD_MASK_EN: self.mask = data[1] & 3;
		case CMD_CHR_TRN:
			self.chr_half = data[1] & 1;
			self.pending_trn = cmd;
		case CMD_PAL_TRN:
		case CMD_PCT_TRN:
		case CMD_ATTR_TRN:
			self.pending_trn = cmd;
		case CMD_MLT_REQ:
			// 0-3 = 1, 2, (3), 4 players. Mode 2 is not a real mode: entering
			// it the player becomes (player + 1) & 2, so player 3 can show
			// up, and it never advances (worked out from SameSuite
			// command_mlt_req).
			switch (data[1] & 3) {
				case 0:  self.players = 1;
				case 1:  self.players = 2;
				case 2:  self.players = 3;
				default: self.players = 4;
			}
			if (self.players == 3) {
				self.player = (self.player + 1) & 2;
			} else {
				self.player &= self.players - 1;
			}
		default:
			break; // sound, SNES code/data and the border (next step)
	}
}

// The low nibble P1 reads when neither button row is selected: normally $F,
// in multiplayer mode $F - player.
fn char Sgb.joypad_id(&self) {
	return self.players > 1 ? (char)(0xF - self.player) : 0xF;
}

// ---------------------------------------------------------------------------
// Colours
// ---------------------------------------------------------------------------

fn ushort le16(char[] data, usz at) => (ushort)(data[at] | (data[at + 1] << 8));

// Show a 4-colour palette everywhere, as before a game sends its own (and when
// the player picks an SGB preset).
fn void Sgb.set_preset(&self, ushort[4] colors) {
	for (int p = 0; p < 4; p++) self.pal[p] = colors;
	self.attr = {};
}

// Colour 0 is the backdrop, shared by all four palettes.
fn void Sgb.set_color0(&self, ushort c) {
	for (int p = 0; p < 4; p++) self.pal[p][0] = c;
}

// PAL01/23/03/12: colour 0, then colours 1-3 of palette `a`, then of palette `b`.
fn void Sgb.set_pals(&self, int a, int b, char[] data) {
	self.set_color0(le16(data, 1));
	for (usz i = 0; i < 3; i++) {
		self.pal[a][i + 1] = le16(data, 3 + i * 2);
		self.pal[b][i + 1] = le16(data, 9 + i * 2);
	}
}

// PAL_SET: palettes 0-3 from the system palettes, optionally an attribute
// file, optionally cancelling MASK_EN.
fn void Sgb.pal_set(&self, char[] data) {
	for (usz p = 0; p < 4; p++) {
		self.pal[p] = self.sys_pal[le16(data, 1 + p * 2) & 0x1FF];
	}
	self.set_color0(self.pal[0][0]);
	char flags = data[9];
	if (flags & 0x80) self.apply_atf(flags & 0x3F);
	if (flags & 0x40) self.mask = MASK_NONE;
}

fn void Sgb.apply_atf(&self, char n) {
	if (n >= ATF_COUNT) return;
	usz base = (usz)n * ATF_LEN;
	for (int i = 0; i < COLS * ROWS; i++) {
		char b = self.atf[base + (usz)i / 4];
		self.attr[i] = (b >> (6 - (i % 4) * 2)) & 3;
	}
}

// ATTR_BLK: rectangles; each data set changes the inside, the border line
// and/or the outside of one rectangle (in cells).
fn void Sgb.attr_blk(&self, char[] data) {
	int sets = data[1];
	for (int s = 0; s < sets; s++) {
		usz at = 2 + (usz)s * 6;
		if (at + 6 > data.len) return;
		char ctrl = data[at] & 7;
		char pals = data[at + 1];
		int x1 = data[at + 2];
		int y1 = data[at + 3];
		int x2 = data[at + 4];
		int y2 = data[at + 5];
		char p_in = pals & 3;
		char p_line = (pals >> 2) & 3;
		char p_out = (pals >> 4) & 3;
		// Changing only the inside or only the outside also colours the line.
		if (ctrl == 1) { ctrl |= 2; p_line = p_in; }
		if (ctrl == 4) { ctrl |= 2; p_line = p_out; }

		for (int y = 0; y < ROWS; y++) {
			for (int x = 0; x < COLS; x++) {
				bool in_rect = x >= x1 && x <= x2 && y >= y1 && y <= y2;
				bool edge = in_rect && (x == x1 || x == x2 || y == y1 || y == y2);
				int i = y * COLS + x;
				if (edge) {
					if (ctrl & 2) self.attr[i] = p_line;
				} else if (in_rect) {
					if (ctrl & 1) self.attr[i] = p_in;
				} else {
					if (ctrl & 4) self.attr[i] = p_out;
				}
			}
		}
	}
}

// ATTR_LIN: whole rows (bit 7 set) or columns, one byte each.
fn void Sgb.attr_lin(&self, char[] data) {
	int sets = data[1];
	for (int s = 0; s < sets && (usz)(2 + s) < data.len; s++) {
		char b = data[2 + s];
		int line = b & 0x1F;
		char p = (b >> 5) & 3;
		if (b & 0x80) {
			if (line < ROWS) for (int x = 0; x < COLS; x++) self.attr[line * COLS + x] = p;
		} else {
			if (line < COLS) for (int y = 0; y < ROWS; y++) self.attr[y * COLS + line] = p;
		}
	}
}

// ATTR_DIV: split at a row or column: before / on / after the line.
fn void Sgb.attr_div(&self, char[] data) {
	char b = data[1];
	char p_after = b & 3;
	char p_before = (b >> 2) & 3;
	char p_line = (b >> 4) & 3;
	bool rows = (b & 0x40) != 0;
	int at = data[2];
	for (int y = 0; y < ROWS; y++) {
		for (int x = 0; x < COLS; x++) {
			int c = rows ? y : x;
			self.attr[y * COLS + x] = c < at ? p_before : c == at ? p_line : p_after;
		}
	}
}

// ATTR_CHR: cell by cell from (x, y), 2 bits each (MSB first), left to right
// or top to bottom, wrapping at the screen edge.
fn void Sgb.attr_chr(&self, char[] data) {
	int x = data[1];
	int y = data[2];
	int n = data[3] | (data[4] << 8);
	bool down = data[5] != 0;
	for (int k = 0; k < n && k < COLS * ROWS; k++) {
		usz byte = 6 + (usz)k / 4;
		if (byte >= data.len || x >= COLS || y >= ROWS) return;
		self.attr[y * COLS + x] = (data[byte] >> (6 - (k % 4) * 2)) & 3;
		if (down) {
			if (++y == ROWS) { y = 0; x++; }
		} else {
			if (++x == COLS) { x = 0; y++; }
		}
	}
}

// ---------------------------------------------------------------------------
// VRAM transfers
// ---------------------------------------------------------------------------

// The 4 KiB a *_TRN command transfers: the 256 tiles the BG shows in map order
// (20 per row), read from the tile data area LCDC selects.
fn void read_transfer(ppu::Ppu* p, char[TRN_LEN]* out) {
	usz map = (p.lcdc & ppu::LCDC_BG_MAP) ? 0x1C00 : 0x1800;
	bool signed_tiles = (p.lcdc & ppu::LCDC_TILE_DATA) == 0;
	for (usz t = 0; t < 256; t++) {
		char idx = p.vram[map + (t / 20) * 32 + t % 20];
		usz tile = signed_tiles ? (usz)(0x1000 + (int)(ichar)idx * 16) : (usz)idx * 16;
		for (usz b = 0; b < 16; b++) (*out)[t * 16 + b] = p.vram[tile + b];
	}
}

// Called at the start of VBlank: complete a pending *_TRN from this frame.
fn void Sgb.capture_transfer(&self, ppu::Ppu* p) {
	if (self.pending_trn == 0xFF) return;
	char cmd = self.pending_trn;
	self.pending_trn = 0xFF;
	char[TRN_LEN] buf;
	read_transfer(p, &buf);
	switch (cmd) {
		case CMD_PAL_TRN:
			for (usz i = 0; i < 512 * 4; i++) self.sys_pal[i / 4][i % 4] = le16(&buf, i * 2);
		case CMD_ATTR_TRN:
			for (usz i = 0; i < self.atf.len; i++) self.atf[i] = buf[i];
		case CMD_CHR_TRN:
			usz at = (usz)self.chr_half * TRN_LEN;
			for (usz i = 0; i < TRN_LEN; i++) self.border_tiles[at + i] = buf[i];
		case CMD_PCT_TRN:
			for (usz i = 0; i < self.border_map.len; i++) self.border_map[i] = le16(&buf, i * 2);
			for (usz i = 0; i < 3 * 16; i++) self.border_pal[i / 16][i % 16] = le16(&buf, 0x800 + i * 2);
			self.has_border = true;
		default:
			break;
	}
}

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

// SGB/CGB 15-bit BGR -> 8-bit R, G, B (each channel << 3, which is what the
// commonly quoted values like 1-A = F8E8C8 assume).
fn void bgr555_to_rgb(ushort c, char[] out) {
	out[0] = (char)((c & 0x1F) << 3);
	out[1] = (char)(((c >> 5) & 0x1F) << 3);
	out[2] = (char)(((c >> 10) & 0x1F) << 3);
}

// Through the SNES's output curve on a TV (SameBoy's SGB colour correction).
const char[32] SGB_CURVE = { 0, 2, 5, 9, 15, 20, 27, 34, 42, 50, 58, 67, 76, 85, 94, 104,
	114, 123, 133, 143, 153, 163, 173, 182, 192, 202, 211, 220, 229, 238, 247, 255 };

// Colours through SGB_CURVE (gameboy::color_correction on). Not in Sgb: a
// display setting, not saved state.
bool color_curve;

fn void Sgb.to_rgb(&self, ushort c, char[] out) {
	if (!color_curve) {
		bgr555_to_rgb(c, out);
		return;
	}
	out[0] = SGB_CURVE[c & 0x1F];
	out[1] = SGB_CURVE[(c >> 5) & 0x1F];
	out[2] = SGB_CURVE[(c >> 10) & 0x1F];
}

fn int Sgb.width(&self)  => BORDER_W;
fn int Sgb.height(&self) => BORDER_H;

// The picture as RGB (3 bytes per pixel), width() x height(): the coloured
// Game Boy screen inside the border. Freezing keeps showing the picture
// from when MASK_EN froze it.
fn void Sgb.render(&self, char[] shades, char[] out) {
	char[] rgb = &self.screen_rgb;
	if (self.mask == MASK_FREEZE) {
		shades = &self.frozen;
	} else {
		for (usz i = 0; i < self.frozen.len; i++) self.frozen[i] = shades[i];
	}
	for (int y = 0; y < ppu::HEIGHT; y++) {
		for (int x = 0; x < ppu::WIDTH; x++) {
			int i = y * ppu::WIDTH + x;
			char[] px = rgb[(usz)i * 3 : 3];
			switch (self.mask) {
				case MASK_BLACK:  px[0] = 0; px[1] = 0; px[2] = 0;
				case MASK_COLOR0: self.to_rgb(self.pal[0][0], px);
				default:
					char p = self.attr[(y / 8) * COLS + x / 8];
					self.to_rgb(self.pal[p][shades[i] & 3], px);
			}
		}
	}
	self.compose(out);
}

// Colour index 0-15 of border pixel (x, y), and its palette (0-2 for 4-6).
fn char Sgb.border_pixel(&self, int x, int y, int* pal) {
	ushort e = self.border_map[(y / 8) * 32 + x / 8];
	int px = (e & 0x4000) ? 7 - (x & 7) : x & 7;
	int py = (e & 0x8000) ? 7 - (y & 7) : y & 7;
	usz base = (usz)(e & 0xFF) * 32 + (usz)py * 2;
	int bit = 7 - px;
	char idx = ((self.border_tiles[base] >> bit) & 1)
	         | (((self.border_tiles[base + 1] >> bit) & 1) << 1)
	         | (((self.border_tiles[base + 16] >> bit) & 1) << 2)
	         | (((self.border_tiles[base + 17] >> bit) & 1) << 3);
	int p = ((e >> 10) & 7) - 4;
	*pal = p < 0 || p > 2 ? 0 : p;
	return idx;
}

// Border over the Game Boy picture over the backdrop (shared colour 0).
fn void Sgb.compose(&self, char[] out) {
	for (int y = 0; y < BORDER_H; y++) {
		for (int x = 0; x < BORDER_W; x++) {
			char[] px = out[(usz)(y * BORDER_W + x) * 3 : 3];
			int pal;
			char idx = self.has_border ? self.border_pixel(x, y, &pal) : 0;
			int gx = x - GB_X;
			int gy = y - GB_Y;
			if (idx != 0) {
				self.to_rgb(self.border_pal[pal][idx], px);
			} else if (gx >= 0 && gx < ppu::WIDTH && gy >= 0 && gy < ppu::HEIGHT) {
				usz s = (usz)(gy * ppu::WIDTH + gx) * 3;
				px[0] = self.screen_rgb[s];
				px[1] = self.screen_rgb[s + 1];
				px[2] = self.screen_rgb[s + 2];
			} else if (self.has_border) {
				self.to_rgb(self.pal[0][0], px);   // backdrop through the border
			} else {
				self.to_rgb(self.pal[0][3], px);   // no border (yet): a plain frame
			}
		}
	}
}
