module ppu;

const int WIDTH  = 160;
const int HEIGHT = 144;

const int DOTS_PER_LINE = 456;
const int TOTAL_LINES   = 154;
const int VBLANK_LINE   = 144;
const int MODE2_DOTS    = 80;   // OAM scan
const int MODE3_DOTS    = 172;  // drawing, minimum; see Ppu.mode3_length
// A line with objects ends mode 3 this many dots before the plain Pan Docs
// sum. Measured on Mooneye intr_2_mode0_timing_sprites (which only sees whole
// M-cycles): with it, every case of that test lines up.
const int OBJ_PENALTY_ADJUST = 3;
// LY (and the LY=LYC compare) move to the next line this many dots before
// the line itself ends: for one M-cycle LY is already new while the old
// line's HBlank is still running (Mooneye lcdon_timing).
const int LY_EARLY_DOTS = 4;

// LCDC ($FF40)
const char LCDC_ENABLE     = 0x80;
const char LCDC_WIN_MAP    = 0x40;
const char LCDC_WIN_ENABLE = 0x20;
const char LCDC_TILE_DATA  = 0x10;
const char LCDC_BG_MAP     = 0x08;
const char LCDC_OBJ_SIZE   = 0x04;
const char LCDC_OBJ_ENABLE = 0x02;
const char LCDC_BG_ENABLE  = 0x01;

// STAT ($FF41)
const char STAT_LYC_IE    = 0x40;
const char STAT_OAM_IE    = 0x20;
const char STAT_VBLANK_IE = 0x10;
const char STAT_HBLANK_IE = 0x08;
const char STAT_LYC_FLAG  = 0x04;
const int LCDON_START_DOT = 0;

// Interrupt request bits returned by tick().
const char INT_VBLANK = 0x01;
const char INT_STAT   = 0x02;

struct Ppu {
	char[0x2000] vram;
	char*        vram1;  // CGB: VRAM bank 1 (heap), null otherwise
	char[0xA0]   oam;
	char[] fb;
	// CGB mode: the picture as RGB555 colours (heap), and the switch between
	// the DMG and CGB renderers (Mmu.cgb_mode's copy).
	ushort[] cfb;
	bool     cgb;
	bool     compat;  // CGB running a DMG game: DMG renderer, colours from palette RAM

	char lcdc;
	char stat;
	char scy;
	char scx;
	char ly;
	char lyc;
	char bgp;
	char obp0;
	char obp1;
	char wy;
	char wx;

	// CGB colour palettes: 8 BG + 8 OBJ palettes of 4 colours, each colour
	// two bytes of little-endian RGB555. BCPS/OCPS ($FF68/$FF6A) select a
	// byte (bits 0-5) and auto-increment after a data write (bit 7).
	char[64] bg_pal;
	char[64] obj_pal;
	char     bcps;
	char     ocps;
	char     opri;   // $FF6C bit 0: 0 = CGB object priority (OAM order), 1 = DMG (X)

	int  dot;          // 0..455 within the current line
	char mode;         // 0 HBlank, 1 VBlank, 2 OAM, 3 drawing
	int  win_line;     // internal window line counter
	bool frame_ready;  // set when VBlank begins; cleared by the consumer
	bool stat_line;    // OR of the enabled STAT sources (see update_stat_line)
	bool first_line;
	int  line;         // line being processed (LY runs LY_EARLY_DOTS ahead of it)
	int  mode3_len;    // length of this line's mode 3, fixed when it starts
	bool hblank_start; // a visible line entered HBlank (CGB HDMA); cleared by the Mmu

	char[WIDTH] bg_color; // BG colour index per pixel of the current line (sprite priority)
	bool[WIDTH] bg_prio;  // CGB: the BG tile's attribute bit 7 (BG over objects)
}

// CGB tile attributes (VRAM bank 1, same address as the tile index).
const char ATTR_PALETTE  = 0x07;
const char ATTR_BANK     = 0x08;
const char ATTR_XFLIP    = 0x20;
const char ATTR_YFLIP    = 0x40;
const char ATTR_PRIORITY = 0x80;

// Colour `index` of CGB palette `palette` (0-7) in palette RAM, as RGB555.
fn ushort pal_color(char[] pal, int palette, int index) {
	int i = palette * 8 + index * 2;
	return (ushort)(pal[i] | ((ushort)pal[i + 1] << 8));
}

// A data write through BCPD/OCPD: store at the selected byte, then advance
// the index if auto-increment is on.
fn void pal_write(char[] pal, char* spec, char value) {
	pal[*spec & 0x3F] = value;
	pal_advance(spec);
}

fn void pal_advance(char* spec) {
	if (*spec & 0x80) *spec = (char)(0x80 | ((*spec + 1) & 0x3F));
}

// White to black in RGB555: BG palette 0 and OBJ palettes 0 and 1 for a DMG
// game on a CGB started without the boot ROM.
const ushort[4] GREYS = { 0x7FFF, 0x56B5, 0x294A, 0x0000 };

fn void set_grey_palettes(Ppu* p) {
	for (int i = 0; i < 4; i++) {
		char lo = (char)GREYS[i];
		char hi = (char)(GREYS[i] >> 8);
		p.bg_pal[i * 2] = lo;
		p.bg_pal[i * 2 + 1] = hi;
		for (int obj = 0; obj < 2; obj++) {
			p.obj_pal[obj * 8 + i * 2] = lo;
			p.obj_pal[obj * 8 + i * 2 + 1] = hi;
		}
	}
}

fn char shade(char palette, char index) {
	return (palette >> (index * 2)) & 3;
}

fn void Ppu.write_lcdc(&self, char value) {
	bool was_on = (self.lcdc & LCDC_ENABLE) != 0;
	self.lcdc = value;
	if (!was_on && (value & LCDC_ENABLE) != 0) {
		self.dot = LCDON_START_DOT;
		self.ly = 0;
		self.line = 0;
		self.win_line = 0;
		self.mode = 0;
		self.stat = self.stat & 0xFC;
		self.frame_ready = false;
		self.first_line = true;
		self.check_lyc();
	}
}

// Writable STAT bits are the four interrupt enables (3-6). Turning one on
// while its condition already holds is a rising edge of the STAT line.
fn char Ppu.write_stat(&self, char value) {
	self.stat = (self.stat & 0x87) | (value & 0x78);
	if ((self.lcdc & LCDC_ENABLE) == 0) return 0;
	return self.update_stat_line();
}

// The LY=LYC flag follows a LYC write immediately, not at the next line.
// With the LCD off the comparison clock is stopped: the flag keeps its last
// value until the LCD is turned on again (Mooneye stat_lyc_onoff).
fn char Ppu.write_lyc(&self, char value) {
	self.lyc = value;
	if ((self.lcdc & LCDC_ENABLE) == 0) return 0;
	self.check_lyc();
	return self.update_stat_line();
}

fn char Ppu.tick(&self, uint tcycles) {
	if ((self.lcdc & LCDC_ENABLE) == 0) {
		self.dot = 0;
		self.ly = 0;
		self.line = 0;
		self.win_line = 0;
		self.mode = 0;
		self.stat &= 0xFC;
		// stat_line and the LY=LYC flag stay frozen while the LCD is off, so
		// turning it back on only raises an IRQ if the line really goes 0 -> 1.
		return 0;
	}

	char irq = 0;
	for (uint i = 0; i < tcycles; i++) {
		self.dot++;
		if (self.dot == DOTS_PER_LINE - LY_EARLY_DOTS) {
			self.ly = (char)((self.line + 1) % TOTAL_LINES);
			self.check_lyc();
		}
		if (self.dot >= DOTS_PER_LINE) {
			self.first_line = false;
			self.dot = 0;
			self.line = (self.line + 1) % TOTAL_LINES;
			if (self.line == 0) self.win_line = 0;
			self.check_lyc();
		}
		irq |= self.update_mode();
		irq |= self.update_stat_line();
	}
	return irq;
}

// True while the CPU can't use OAM: modes 2 and 3, and already during the
// LY_EARLY_DOTS before a visible line starts (its OAM scan begins with the
// LY change, while STAT still reads mode 0).
fn bool Ppu.oam_locked(&self) {
	if (self.mode >= 2) return true;
	int next = (self.line + 1) % TOTAL_LINES;
	return self.dot >= DOTS_PER_LINE - LY_EARLY_DOTS && next < VBLANK_LINE;
}

// True while the CPU can't use VRAM: mode 3, and already the last
// LY_EARLY_DOTS of mode 2 (drawing grabs VRAM before STAT reads mode 3).
fn bool Ppu.vram_locked(&self) {
	if (self.mode == 3) return true;
	return self.mode == 2 && self.dot >= MODE2_DOTS - LY_EARLY_DOTS;
}

// CPU writes to OAM are blocked in modes 2 and 3, except during the last
// LY_EARLY_DOTS of mode 2 (the hand-over to drawing), when they get through.
fn bool Ppu.oam_write_locked(&self) {
	if (self.mode == 3) return true;
	return self.mode == 2 && self.dot < MODE2_DOTS - LY_EARLY_DOTS;
}

// Keep the LY=LYC flag (STAT bit 2) in sync. Interrupts come from update_stat_line.
// While LY has already moved on but the line hasn't (the last LY_EARLY_DOTS
// dots), the comparator sees no line at all: the flag reads 0.
fn void Ppu.check_lyc(&self) {
	bool ly_settling = self.dot >= DOTS_PER_LINE - LY_EARLY_DOTS;
	if (self.ly == self.lyc && !ly_settling) {
		self.stat |= STAT_LYC_FLAG;
	} else {
		self.stat &= (char)~STAT_LYC_FLAG;
	}
}

// How long mode 3 lasts on the current line (Pan Docs "Mode 3 length"):
//   172 dots, + SCX % 8 (pixels discarded from the first tile),
//   + 6 if the window starts on this line,
//   + per object on the line: 6, plus max(0, 5 - (X + SCX) % 8) for the first
//     object whose left edge falls in a given BG tile (X = 0 always pays 11).
fn int Ppu.mode3_length(&self) {
	int len = MODE3_DOTS + (self.scx & 7);

	bool win = (self.lcdc & LCDC_WIN_ENABLE) != 0 && self.line >= (int)self.wy && self.wx <= 166;
	if (win) len += 6;

	if ((self.lcdc & LCDC_OBJ_ENABLE) == 0) return len;
	int without_objects = len;
	int height = (self.lcdc & LCDC_OBJ_SIZE) ? 16 : 8;
	bool[32] tile_paid;
	int n = 0;
	for (int i = 0; i < 40 && n < 10; i++) {
		int oy = (int)self.oam[i * 4] - 16;
		if (self.line < oy || self.line >= oy + height) continue;
		n++;                                   // counts towards the 10-object limit
		int x = self.oam[i * 4 + 1];
		if (x >= 168) continue;                // off the right edge: never fetched
		len += 6;
		int tile = (x + (self.scx & 7)) >> 3;
		if (tile_paid[tile]) continue;
		tile_paid[tile] = true;
		int extra = x == 0 ? 5 : 5 - ((x + self.scx) & 7);
		if (extra > 0) len += extra;
	}
	if (len > without_objects) len -= OBJ_PENALTY_ADJUST;
	return len;
}

fn char Ppu.update_mode(&self) {
	if (self.dot == MODE2_DOTS && self.line < VBLANK_LINE) self.mode3_len = self.mode3_length();

	char want;
	if (self.line >= VBLANK_LINE) {
		want = 1;
	} else if (self.dot < MODE2_DOTS) {
		want = 2;
	} else if (self.dot < MODE2_DOTS + self.mode3_len) {
		want = 3;
	} else {
		want = 0;
	}

	if (self.first_line && want == 2) {
		want = 0;
	}
	if (want == self.mode) return 0;
	self.mode = want;
	self.stat = (self.stat & 0xFC) | want;

	char irq = 0;
	switch (want) {
		case 0:
			self.render_line();
			self.hblank_start = true;
		case 1:
			self.frame_ready = true;
			irq |= INT_VBLANK;
	}
	return irq;
}

fn char Ppu.tile_pixel(&self, ushort map_base, bool signed_tiles, int px, int py) {
	int col = (px >> 3) & 31;
	int row = (py >> 3) & 31;
	char tile = self.vram[map_base + row * 32 + col];

	ushort base;
	if (signed_tiles) {
		base = (ushort)(0x1000 + (int)(ichar)tile * 16);
	} else {
		base = (ushort)((uint)tile * 16);
	}
	int fine = py & 7;
	char lo = self.vram[base + fine * 2];
	char hi = self.vram[base + fine * 2 + 1];
	int bit = 7 - (px & 7);
	return (char)((((hi >> bit) & 1) << 1) | ((lo >> bit) & 1));
}

fn void Ppu.render_line(&self) {
	if (self.cgb) {
		self.render_line_cgb();
		return;
	}
	if (self.fb.len == 0) return;

	int y = self.line;
	int row = y * WIDTH;

	bool bg_on   = (self.lcdc & LCDC_BG_ENABLE) != 0;
	bool win_row = (self.lcdc & LCDC_WIN_ENABLE) != 0 && y >= (int)self.wy;
	bool signed_tiles = (self.lcdc & LCDC_TILE_DATA) == 0;
	ushort bg_map  = (self.lcdc & LCDC_BG_MAP)  ? (ushort)0x1C00 : (ushort)0x1800;
	ushort win_map = (self.lcdc & LCDC_WIN_MAP) ? (ushort)0x1C00 : (ushort)0x1800;
	int win_x0 = (int)self.wx - 7;

	for (int x = 0; x < WIDTH; x++) {
		char idx = 0;
		if (bg_on) {
			if (win_row && x >= win_x0) {
				idx = self.tile_pixel(win_map, signed_tiles, x - win_x0, self.win_line);
			} else {
				idx = self.tile_pixel(bg_map, signed_tiles, (x + self.scx) & 0xFF, (y + self.scy) & 0xFF);
			}
		}
		self.bg_color[x] = idx;
		self.fb[row + x] = shade(self.bgp, idx);
		if (self.compat) self.cfb[row + x] = pal_color(&self.bg_pal, 0, shade(self.bgp, idx));
	}

	if (win_row && win_x0 < WIDTH) self.win_line++;

	if (self.lcdc & LCDC_OBJ_ENABLE) self.render_sprites(y);
}

// CGB mode: every BG/window tile has an attribute byte in VRAM bank 1 (its
// palette, tile bank, flips and priority). LCDC bit 0 no longer hides the BG
// and window; it takes away their priority over objects instead.
fn void Ppu.render_line_cgb(&self) {
	if (self.cfb.len == 0) return;

	int y = self.line;
	int row = y * WIDTH;

	bool win_row = (self.lcdc & LCDC_WIN_ENABLE) != 0 && y >= (int)self.wy;
	bool signed_tiles = (self.lcdc & LCDC_TILE_DATA) == 0;
	ushort bg_map  = (self.lcdc & LCDC_BG_MAP)  ? (ushort)0x1C00 : (ushort)0x1800;
	ushort win_map = (self.lcdc & LCDC_WIN_MAP) ? (ushort)0x1C00 : (ushort)0x1800;
	int win_x0 = (int)self.wx - 7;

	for (int x = 0; x < WIDTH; x++) {
		ushort map;
		int px;
		int py;
		if (win_row && x >= win_x0) {
			map = win_map;
			px = x - win_x0;
			py = self.win_line;
		} else {
			map = bg_map;
			px = (x + self.scx) & 0xFF;
			py = (y + self.scy) & 0xFF;
		}
		usz at = (usz)map + (usz)((py >> 3) & 31) * 32 + (usz)((px >> 3) & 31);
		char tile = self.vram[at];
		char attr = self.vram1[at];

		ushort base = signed_tiles ? (ushort)(0x1000 + (int)(ichar)tile * 16) : (ushort)((uint)tile * 16);
		int fine = (attr & ATTR_YFLIP) ? 7 - (py & 7) : py & 7;
		char* data = (attr & ATTR_BANK) ? self.vram1 : &self.vram[0];
		char lo = data[base + fine * 2];
		char hi = data[base + fine * 2 + 1];
		int bit = (attr & ATTR_XFLIP) ? px & 7 : 7 - (px & 7);
		char idx = (char)((((hi >> bit) & 1) << 1) | ((lo >> bit) & 1));

		self.bg_color[x] = idx;
		self.bg_prio[x] = (attr & ATTR_PRIORITY) != 0;
		self.cfb[row + x] = pal_color(&self.bg_pal, attr & ATTR_PALETTE, idx);
	}

	if (win_row && win_x0 < WIDTH) self.win_line++;

	if (self.lcdc & LCDC_OBJ_ENABLE) self.render_sprites(y);
}

fn void Ppu.render_sprites(&self, int y) {
	int height = (self.lcdc & LCDC_OBJ_SIZE) ? 16 : 8;
	int row = y * WIDTH;

	int[10] chosen;
	int n = 0;
	for (int i = 0; i < 40 && n < 10; i++) {
		int oy = (int)self.oam[i * 4] - 16;
		if (y >= oy && y < oy + height) chosen[n++] = i;
	}

	// DMG priority: smaller X wins; ties broken by OAM index. Sort ascending so
	// the first sprite to touch a pixel is the winner. In CGB mode (OPRI = 0)
	// OAM order alone decides: already the order they were picked in.
	bool by_x = !self.cgb || (self.opri & 1) != 0;
	for (int a = 1; a < n && by_x; a++) {
		int v = chosen[a];
		int vx = self.oam[v * 4 + 1];
		int b = a - 1;
		while (b >= 0 && (int)self.oam[chosen[b] * 4 + 1] > vx) {
			chosen[b + 1] = chosen[b];
			b--;
		}
		chosen[b + 1] = v;
	}

	bool[WIDTH] painted;
	for (int s = 0; s < n; s++) {
		int i = chosen[s];
		int oy = (int)self.oam[i * 4] - 16;
		int ox = (int)self.oam[i * 4 + 1] - 8;
		char tile = self.oam[i * 4 + 2];
		char flags = self.oam[i * 4 + 3];

		int line = y - oy;
		if (flags & 0x40) line = height - 1 - line; // y-flip
		if (height == 16) tile &= 0xFE;

		ushort addr = (ushort)((int)tile * 16 + line * 2);
		// CGB: tile bank in bit 3, palette in bits 0-2 (bit 4 is unused).
		char* data = (self.cgb && (flags & ATTR_BANK)) ? self.vram1 : &self.vram[0];
		char lo = data[addr];
		char hi = data[addr + 1];
		char pal = (flags & 0x10) ? self.obp1 : self.obp0;
		bool behind = (flags & 0x80) != 0;
		bool xflip = (flags & 0x20) != 0;

		for (int px = 0; px < 8; px++) {
			int sx = ox + px;
			if (sx < 0 || sx >= WIDTH || painted[sx]) continue;
			int bit = xflip ? px : 7 - px;
			char cidx = (char)((((hi >> bit) & 1) << 1) | ((lo >> bit) & 1));
			if (cidx == 0) continue;              // transparent
			painted[sx] = true;
			if (self.cgb) {
				// A non-zero BG pixel stays on top if either the object or the
				// BG tile asks for it, unless LCDC bit 0 takes BG priority away.
				bool bg_wins = (self.lcdc & LCDC_BG_ENABLE) != 0 && self.bg_color[sx] != 0
					&& (behind || self.bg_prio[sx]);
				if (!bg_wins) self.cfb[row + sx] = pal_color(&self.obj_pal, flags & ATTR_PALETTE, cidx);
				continue;
			}
			if (behind && self.bg_color[sx] != 0) continue;
			self.fb[row + sx] = shade(pal, cidx);
			if (self.compat) self.cfb[row + sx] = pal_color(&self.obj_pal, (flags & 0x10) ? 1 : 0, shade(pal, cidx));
		}
	}
}

// The four STAT sources are OR'ed into one line; the STAT interrupt fires only
// on its rising edge. A source turning on while the line is already high
// raises nothing ("STAT blocking").
// DMG quirk: when VBlank starts at line 144 the mode-2 (OAM) source is briefly
// active too, so with STAT bit 5 set a STAT IRQ fires together with VBlank
// (Mooneye vblank_stat_intr).
fn bool Ppu.vblank_oam_pulse(&self) {
	return self.line == VBLANK_LINE && self.dot < LY_EARLY_DOTS;
}

fn char Ppu.update_stat_line(&self) {
	bool high = ((self.stat & STAT_LYC_IE)    != 0 && (self.stat & STAT_LYC_FLAG) != 0)
	         || ((self.stat & STAT_OAM_IE)    != 0 && (self.mode == 2 || self.vblank_oam_pulse()))
	         || ((self.stat & STAT_VBLANK_IE) != 0 && self.mode == 1)
	         || ((self.stat & STAT_HBLANK_IE) != 0 && self.mode == 0);

	bool rising = high && !self.stat_line;   // was low, is high now
	self.stat_line = high;                   // remember for the next call
	return rising ? INT_STAT : 0;
}
