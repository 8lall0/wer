module ppu;
import std::io;

// The drawing part of mode 3, one dot at a time, as the hardware does it: a
// background fetcher reads the tile map and tile data a step per dot into an
// 8-pixel FIFO; objects on the line stall it while their data is fetched into
// a second FIFO; one pixel pops out per dot, mixed and coloured with the
// registers as they are at that dot. So register writes during mode 3 show up
// mid-line (Mealybug Tearoom tests).
//
// Modelled closely on SameBoy's display.c (MIT, Lior Halphon): the fetcher
// states, the fine-scroll discard at the start of a line, the window trigger
// and its DMG quirks, and when object fetches read OAM and VRAM.
//
// Positions follow SameBoy: `pos` starts at -16; pixels before 0 (8 junk
// pixels and the SCX fine-scroll discard) are dropped.

// Background fetcher steps; VRAM reads take 2 dots (address, then data).
enum Fetch : char {
	TILE_T1,
	TILE_T2,
	LOW_T1,
	LOW_T2,
	HIGH_T1,
	HIGH_T2,
	PUSH,
}

// Where an object fetch is (each step takes one dot).
enum ObjStep : char {
	NONE,
	WAIT,      // let the background fetcher finish its tile first
	WIN_STALL, // DMG, WX = 0 with fine scroll: the window start costs a dot
	OAM,       // read tile number and attributes (2 dots)
	OAM_IDLE,
	LOW,       // read the low bitplane (2 dots)
	LOW_IDLE,
	HIGH,      // read the high bitplane
	OVERLAY,   // mix into the object FIFO (start of the next dot)
}

struct Pixel {
	char color;    // 0-3
	char palette;  // DMG: 0/1 = OBP0/OBP1 (objects); CGB: palette 0-7
	bool bg_prio;  // BG: attribute bit 7; object: "behind BG" flag
	char prio;     // objects, CGB OAM-order priority: OAM index (lower wins)
}

struct Fifo {
	Pixel[8] px;
	int head;
	int size;
}

fn void Fifo.clear(&self) {
	self.head = 0;
	self.size = 0;
}

fn Pixel Fifo.pop(&self) {
	Pixel p = self.px[self.head];
	self.head = (self.head + 1) & 7;
	self.size--;
	return p;
}

fn Pixel* Fifo.at(&self, int i) => &self.px[(self.head + i) & 7];

struct Renderer {
	bool active;        // mode 3 drawing in progress on this line
	char fetch_y;       // CGB-D/E: the fetcher Y latched with the tile number
	int  pos;           // position in line, -16 .. 160 (see above)
	int  lcd_x;         // next screen column written
	Fifo bg;
	Fifo obj;

	// background fetcher
	Fetch  state;
	ushort addr;        // VRAM address being read (bit 13 = bank 1)
	char   tile;
	char   attr;        // CGB tile attributes (0 on DMG)
	char   lo;
	char   hi;
	bool   insert_bg_pixel;

	// window
	bool wy_triggered;  // WY matched LY on some line of this frame
	bool wx_triggered;  // the fetcher is fetching window tiles
	int  window_y;      // window line counter (-1 before the first window line)
	char window_tile_x;
	bool window_fetching; // the window has just started: its first pixel isn't out yet
	int  scan_tall_only; // CGB: 1 + the entry just scanned that only an 8x16 object would show, or 0
	bool fractional;      // this line discards pixels for SCX fine scroll
	bool no_insert_glitch; // WIN_EN was cleared while the window was being fetched

	// objects on this line, sorted so that the next to fetch is last
	char[10] obj_index;
	char[10] obj_x;
	char[10] obj_y;
	int      n_obj;
	ObjStep  obj_step;
	bool     prev_win_en;     // LCDC's window enable in the previous dot
	bool     obj_abort;   // DMG: OBJ_EN was cleared during an object fetch
	int      x158_dot;    // the dot pixel 158 went out (Gambatte's xpos 166: the mode 0 interrupt)

	// CGB TILE_SEL glitch (SameBoy, after Matt Currie's research)
	bool     tile_sel_glitch;  // TILE_SEL is being cleared in this dot
	bool     last_tileset;     // TILE_SEL as the bitplane address was formed
	// What a TILE_SEL set glitch reads: latched by the last object fetch (its
	// high bitplane) or TILE_SEL clear (the bitplane byte read last by then),
	// whichever came later. Ordinary tile reads leave it alone.
	char     glitch_data;
	char     last_read;        // the last bitplane byte read (tiles and objects)
	bool     cgb_wx_glitch;    // CGB: the window is starting here, the fetcher skips reads
	char     obj_tile;
	char     obj_flags;
	char     obj_lo;
	char     obj_hi;
}

fn char u8(int v) => (char)v;

fn bool Ppu.is_cgb_hw(&self) => self.cgb_hw;

// VRAM as the PPU sees it: bank 1 when bit 13 of the address is set.
fn char Ppu.vram_read(&self, ushort a) {
	if (a & 0x2000) return self.vram1 ? self.vram1[a & 0x1FFF] : 0xFF;
	return self.vram[a & 0x1FFF];
}

// Mode 2 checks one OAM entry every 2 dots (Ppu.oam_scan_dot); an object
// covering the line, with the object size at that moment, is kept (at most
// 10), sorted so the next one to fetch is last.
fn void Ppu.oam_scan(&self, int i) {
	Renderer* r = &self.r;
	if (i == 0) r.n_obj = 0;
	if (r.n_obj == 10) return;
	int height = (self.r_lcdc & LCDC_OBJ_SIZE) ? 16 : 8;
	bool dma = self.oam_dma_hides();
	// An entry read before the DMA started has the old contents.
	char* oam = self.oam_read_before_dma() ? &self.oam_pre_dma : &self.oam;
	// While the DMA has OAM the scan reads nothing new: it checks this entry
	// with the Y and X last on its bus (SameBoy add_object_from_index;
	// strikethrough, Gambatte oamdma/late_sp39y).
	if (!dma) {
		self.scan_y_bus = oam[i * 4];
		self.scan_x_bus = oam[i * 4 + 1];
	}
	char y = self.scan_y_bus;
	char x = self.scan_x_bus;
	int top = (int)y - 16;
	r.scan_tall_only = 0;
	if (self.line < top || self.line >= top + height) {
		if (height == 8 && self.line >= top + 8 && self.line < top + 16) r.scan_tall_only = i + 1;
		return;
	}
	self.scan_add(i, y, x);
}

// CGB: an entry counts as 8x16 if OBJ_SIZE is set in either of its 2 scan
// dots (Gambatte OamReader: lsbuf |= the size at the second).
fn void Ppu.oam_scan_second(&self) {
	Renderer* r = &self.r;
	int i = r.scan_tall_only - 1;
	r.scan_tall_only = 0;
	if (i < 0 || r.n_obj == 10 || (self.r_lcdc & LCDC_OBJ_SIZE) == 0) return;
	self.scan_add(i, self.oam[i * 4], self.oam[i * 4 + 1]);
}

fn void Ppu.scan_add(&self, int i, char y, char x) {
	Renderer* r = &self.r;
	// Descending X; for equal X the lower OAM index ends up later, so it is
	// fetched first.
	int j = 0;
	while (j < r.n_obj && r.obj_x[j] > x) j++;
	for (int k = r.n_obj; k > j; k--) {
		r.obj_index[k] = r.obj_index[k - 1];
		r.obj_x[k] = r.obj_x[k - 1];
		r.obj_y[k] = r.obj_y[k - 1];
	}
	r.obj_index[j] = (char)i;
	r.obj_x[j] = x;
	r.obj_y[j] = y;
	r.n_obj++;
}

// While an OAM DMA owns OAM the scan reads $FF (Gambatte startOamDma: the
// entries read from then on come from a $FF buffer). Gambatte reads entry k
// at line cycle 2k, ahead of the scan here: an entry is hidden if the DMA
// started before that and hadn't ended (OamReader::update; oamdma/late_sp*).
fn bool Ppu.oam_read_before_dma(&self) {
	int first = self.cgb_hw ? SCAN_FIRST[1] : SCAN_FIRST[0];
	ulong t = self.cc - (ulong)first * self.spd();
	return t <= self.oam_dma_from && self.oam_dma_from <= self.cc;
}

fn bool Ppu.oam_dma_hides(&self) {
	int first = self.cgb_hw ? SCAN_FIRST[1] : SCAN_FIRST[0];
	ulong t = self.cc - (ulong)first * self.spd();
	return self.oam_dma_from < t && t <= self.oam_dma_until;
}

// The OAM entry mode 2 checks at this dot, or -1.
// The dot mode 2 checks OAM entry 0 (then one entry every 2 dots); swept
// on Gambatte's sprite tests after the timing port.
const int[2] SCAN_FIRST = { 4, 6 }; // DMG, CGB
fn int Ppu.oam_scan_index(&self) {
	int first = self.cgb_hw ? SCAN_FIRST[1] : SCAN_FIRST[0];
	if (self.first_line || self.dot < first || self.dot > first + 78 || (self.dot - first) & 1) return -1;
	return (self.dot - first) / 2;
}

// Mode 3 starts: prime the FIFO with 8 junk pixels (the objects were picked
// during mode 2).
fn void Ppu.render_start(&self) {
	Renderer* r = &self.r;
	self.win_abortable = false;
	self.win_late_off = false;
	self.win_armed = false;
	r.x158_dot = -1;
	r.active = true;
	r.pos = -16;
	r.lcd_x = 0;
	r.fractional = false;
	r.no_insert_glitch = false;
	r.bg.clear();
	r.obj.clear();
	r.bg.size = 8;
	for (int i = 0; i < 8; i++) *r.bg.at(i) = {};
	r.state = TILE_T1;
	r.obj_step = NONE;
	r.insert_bg_pixel = false;
	r.prev_win_en = (self.r_lcdc & LCDC_WIN_ENABLE) != 0;
	// A window carried over from a WX 166 match starts only if WIN_EN is set
	// now (Gambatte M3Start: win_draw_start && lcdcWinEn).
	if (r.wx_triggered && !self.cgb_hw) {
		if (r.prev_win_en) {
			r.window_y++;
		} else {
			r.wx_triggered = false;
		}
	}

	if (self.first_line) r.n_obj = 0; // no OAM scan on the first line after LCD on
}

// The screen X at which an object's left edge is due (0 while the junk and
// fine-scroll pixels are still coming out).
fn char Ppu.x_for_object_match(&self) {
	char x = u8(self.r.pos + 8);
	return x > 240 ? 0 : x;
}

fn char Ppu.fetcher_y(&self) {
	return self.r.wx_triggered ? u8(self.r.window_y) : u8(self.line + self.scy);
}

fn bool Ppu.objects_fetched(&self) => (self.r_lcdc & LCDC_OBJ_ENABLE) != 0 || self.cgb_hw;

// One dot of mode 3.
fn void Ppu.render_dot(&self) {
	Renderer* r = &self.r;
	// DMG: a window started as WIN_EN went off takes its fetch's time, then
	// the background goes on as it was (Gambatte late_disable; Mealybug
	// m3_lcdc_win_en_change_multiple_wx shows no pixel of it).
	if (self.win_late_off && !r.window_fetching) {
		*r = self.win_save;
		r.prev_win_en = false;
		self.win_late_off = false;
	}
	if (self.win_abortable) {
		if (!r.window_fetching) {
			self.win_abortable = false;
		} else if ((self.r_lcdc & LCDC_WIN_ENABLE) == 0) {
			*r = self.win_save;
			r.prev_win_en = false;
			self.win_abortable = false;
		}
	}
	// DMG: OBJ_EN off (by the write's second step) while a fetch is under way
	// cuts it short as well (Gambatte sprites/sprite_late_disable_*).
	if (!self.cgb_hw && (self.r_lcdc & LCDC_OBJ_ENABLE) == 0 && self.during_object_fetch()) r.obj_abort = true;
	if (r.obj_abort) {
		// The object being fetched is dropped from this dot on (it stays in
		// the list, but with objects off nothing fetches it).
		r.obj_abort = false;
		if (r.obj_step != NONE && r.obj_step != WIN_STALL) {
			r.obj_step = NONE;
			self.pixel_and_fetch();
			return;
		}
	}
	switch (r.obj_step) {
		case NONE:
			if (self.window_check()) {
				r.obj_step = WIN_STALL;
				return;
			}
			if (self.start_object_fetch()) {
				self.object_wait();
				return;
			}
			self.pixel_and_fetch();
		case WIN_STALL:
			r.obj_step = NONE;
			if (self.start_object_fetch()) {
				self.object_wait();
				return;
			}
			self.pixel_and_fetch();
		case WAIT:
			self.object_wait();
		case OAM:
			self.advance_fetcher();
			char i = r.obj_index[r.n_obj - 1];
			r.obj_tile = self.oam[i * 4 + 2];
			r.obj_flags = self.oam[i * 4 + 3];
			// While an OAM DMA writes OAM the PPU reads the bytes at the DMA's
			// address instead (SameBoy oam_read; strikethrough).
			if (self.oam_dma_hides()) {
				long d = (long)((self.cc - self.oam_dma_from) / (4 * (ulong)self.spd())) + 1;
				if (d >= 0 && d < 160) {
					r.obj_tile = self.oam[d & ~1];
					r.obj_flags = self.oam[(d & ~1) | 1];
				}
			}
			// The tile number goes over the bus the OAM scan latches Y from.
			self.scan_y_bus = r.obj_tile;
			r.obj_step = OAM_IDLE;
		case OAM_IDLE:
			r.obj_step = LOW;
		case LOW:
			r.last_read = r.obj_lo = self.vram_read(self.object_line_address());
			r.obj_step = LOW_IDLE;
		case LOW_IDLE:
			r.obj_step = HIGH;
		case HIGH:
			r.obj_hi = self.vram_read(self.object_line_address() + 1);
			r.last_read = r.glitch_data = r.obj_hi;
			r.obj_step = OVERLAY;
		case OVERLAY:
			self.overlay_object();
			r.obj_step = NONE;
			// The next object at the same X starts right away.
			if (self.start_object_fetch()) {
				self.object_wait();
				return;
			}
			self.pixel_and_fetch();
	}
}

// Catching up (Mmu.ppu_catch_up), no write lands and no interrupt is due,
// and nobody reads STAT until it's over: the dots of the OAM scan and of the
// drawing go through the same steps as in Ppu.tick, without its checks for
// what can't happen meanwhile. At most `left` dots, up to the dot drawing
// starts or the end of drawing; returns how many it ran.
fn uint Ppu.catch_up_line(&self, uint left) {
	if (!fast_catch_up) return 0;
	Renderer* r = &self.r;
	ulong spd = self.spd();
	uint n = 0;
	if (!r.active) {
		// The OAM scan, up to the dot drawing starts (Ppu.tick).
		while (n < left && self.dot < render_start_dot) {
			if (self.line == 0 && self.dot <= 2) self.window_line_checks();
			int scan = self.dot < 88 ? self.oam_scan_index() : -1;
			if (scan >= 0) {
				self.oam_scan(scan);
			} else if (self.cgb_hw && r.scan_tall_only > 0) {
				self.oam_scan_second();
			}
			self.dot++;
			self.cc += spd;
			n++;
			// (Ppu.update_mode)
			if (self.dot == MODE3_START_DOT) {
				self.pipe_end_dot = DOTS_PER_LINE;
				self.m0_irq_pred = DOTS_PER_LINE;
			}
		}
	} else if (self.plain_line()) {
		// Only background: no object to fetch, no window that could start.
		// (Where drawing ends is predicted while it's on: Ppu.update_mode.)
		self.pipe_end();
		while (n < left && r.active) {
			self.render_pixel();
			self.advance_fetcher();
			if (r.pos == 160) self.render_end();
			self.dot++;
			self.cc += spd;
			n++;
		}
	} else {
		self.pipe_end();
		while (n < left && r.active) {
			if (self.cgb_hw && r.scan_tall_only > 0) self.oam_scan_second();
			self.render_dot();
			self.dot++;
			self.cc += spd;
			n++;
		}
	}
	if (n) self.update_mode();
	return n;
}

fn bool Ppu.plain_line(&self) {
	Renderer* r = &self.r;
	return r.n_obj == 0 && r.scan_tall_only == 0 && !r.wy_triggered && !r.wx_triggered && self.wy2 != u8(self.line)
		&& !r.tile_sel_glitch && !self.win_abortable && !self.win_late_off;
}

bool fast_catch_up = true;

// Debugging: run each catch-up the ordinary way too and compare (Mmu.ppu_catch_up).
bool check_catch_up;
int  catch_up_mismatches;
int  catch_up_checked;

// The rest of an ordinary dot: output a pixel, step the fetcher, finish the
// line after pixel 159.
fn void Ppu.pixel_and_fetch(&self) {
	self.render_pixel();
	self.advance_fetcher();
	if (self.r.pos == 160) self.render_end();
}

// Drop objects already passed; true when one starts at this X (and objects
// are being fetched).
fn bool Ppu.start_object_fetch(&self) {
	Renderer* r = &self.r;
	char x = self.x_for_object_match();
	while (r.n_obj > 0 && r.obj_x[r.n_obj - 1] < x) r.n_obj--;
	if (r.n_obj == 0 || !self.objects_fetched() || r.obj_x[r.n_obj - 1] != x) return false;
	r.obj_step = WAIT;
	return true;
}


// Object fetch, first part: the background fetcher runs on until it holds
// a whole tile and the FIFO isn't empty, then one more dot.
fn void Ppu.object_wait(&self) {
	Renderer* r = &self.r;
	if (r.state < HIGH_T2 || r.bg.size == 0) {
		self.advance_fetcher();
		return;
	}
	self.advance_fetcher();
	r.obj_step = OAM;
}

// An object fetch counts as in progress (for LCDC writes) until its high
// bitplane read starts: mixing the fetched row in can no longer be stopped.
fn bool Ppu.during_object_fetch(&self) {
	switch (self.r.obj_step) {
		case WAIT:
		case OAM:
		case OAM_IDLE:
		case LOW:
		case LOW_IDLE:
		case HIGH:
			return true;
		default:
			return false;
	}
}

fn ushort Ppu.object_line_address(&self) {
	Renderer* r = &self.r;
	bool tall = (self.r_lcdc & LCDC_OBJ_SIZE) != 0;
	char mask = tall ? 15 : 7;
	char tile_y = u8(self.line - r.obj_y[r.n_obj - 1]) & mask;
	if (r.obj_flags & 0x40) tile_y ^= mask;
	ushort a = (ushort)((tall ? r.obj_tile & 0xFE : r.obj_tile) * 16 + tile_y * 2);
	if (self.cgb && (r.obj_flags & ATTR_BANK)) a += 0x2000;
	return a;
}

// Mix the fetched object row into the object FIFO: a pixel lands where the
// FIFO is transparent, or (CGB) over an object with a higher OAM index.
fn void Ppu.overlay_object(&self) {
	Renderer* r = &self.r;
	char index = r.obj_index[r.n_obj - 1];
	char flags = r.obj_flags;
	char palette = self.cgb ? flags & ATTR_PALETTE : (flags & 0x10) ? 1 : 0;
	char prio = (self.cgb && (self.opri & 1) == 0) ? index : 0;
	bool xflip = (flags & ATTR_XFLIP) != 0;

	while (r.obj.size < 8) *r.obj.at(r.obj.size++) = {};
	char lo = r.obj_lo;
	char hi = r.obj_hi;
	for (int i = 0; i < 8; i++) {
		char color = (char)(((hi >> 7) << 1) | (lo >> 7));
		lo <<= 1;
		hi <<= 1;
		Pixel* t = r.obj.at(xflip ? 7 - i : i);
		if (color != 0 && (t.color == 0 || t.prio > prio)) {
			*t = { .color = color, .palette = palette, .bg_prio = (flags & 0x80) != 0, .prio = prio };
		}
	}
	r.n_obj--;
}

// The window starts when WY has matched this frame and WX is reached.
// True when starting it takes an extra dot.
fn bool Ppu.window_check(&self) {
	bool stall = false;
	Renderer* r = &self.r;
	bool win_en = (self.r_lcdc & LCDC_WIN_ENABLE) != 0;
	bool was_en = r.prev_win_en;
	r.prev_win_en = win_en;
	// CGB: a window enable starts the window from the next dot on (Gambatte
	// window/late_reenable*).
	if (self.cgb_hw && !was_en) win_en = false;
	// A DMG still matches WX exactly in the dot WIN_EN goes off (Gambatte
	// window/late_disable_scx5_1).
	bool exact_en = win_en || (!self.cgb_hw && was_en);
	bool wy_ok = r.wy_triggered || self.wy2 == u8(self.line);
	if (!r.wx_triggered && wy_ok && exact_en) {
		bool start = false;
		if (self.wx == 0) {
			start = win_en && (r.pos == -7 || (r.pos == -16 && (self.scx & 7) != 0) || (r.pos >= -15 && r.pos <= -8));
		} else if (self.wx < 166 + (self.cgb_hw ? 1 : 0)) {
			if (self.wx == u8(r.pos + 7)) {
				start = true;
			} else if (!self.cgb_hw && win_en && self.wx == u8(r.pos + 6) && !self.wx_just_changed) {
				// DMG: WX is also matched a pixel late (WIN_EN turned on right
				// after the exact match). SameBoy also shifts the LCD back a
				// pixel here, which only some DMGs do; the DMG-blob screenshots
				// (Mealybug m3_lcdc_win_en_change_multiple_wx) show no shift.
				start = true;
			}
		}
		if (start) {
			r.window_y++;
			// CGB: if WIN_EN goes off before the window's first pixel, the
			// background carries on from here (Gambatte StartWindowDraw).
			if (self.cgb_hw) {
				self.win_save = *r;
				self.win_abortable = true;
			} else if (!win_en) {
				self.win_save = *r;
				self.win_late_off = true;
			}
			r.window_tile_x = 0;
			r.bg.clear();
			r.wx_triggered = true;
			r.state = TILE_T1;
			r.window_fetching = true;
			stall = self.wx == 0 && (self.scx & 7) != 0 && !self.cgb_hw;
		} else if (!self.cgb_hw && self.wx == 166 && self.wx == u8(r.pos + 7)) {
			r.window_y++;
		}
	}
	// WX matching again while the window runs inserts a colour-0 pixel (a
	// sprite behind the BG shows through it; Mealybug m3_wx_4_change_sprites,
	// on the CGB too).
	if (self.wx == u8(r.pos + 7) && r.wx_triggered
		&& !r.window_fetching && r.state == TILE_T1 && r.bg.size == 8) {
		r.insert_bg_pixel = true;
	}
	return stall;
}

// CGB: while the window is being switched in, the fetcher's reads are
// skipped (SameBoy's cgb_wx_glitch). Re-evaluated at each address step.
fn void Ppu.update_wx_glitch(&self) {
	Renderer* r = &self.r;
	if (!self.cgb_hw) return;
	if ((self.r_lcdc & LCDC_WIN_ENABLE) == 0 || !(r.wy_triggered || self.wy2 == u8(self.line))) {
		r.cgb_wx_glitch = false;
		return;
	}
	if (self.wx == 0) {
		r.cgb_wx_glitch = u8(r.pos + 16) <= 8 || (r.pos == -7 && r.fractional);
		return;
	}
	r.cgb_wx_glitch = u8(r.pos + 7 + (r.window_fetching ? 1 : 0)) == self.wx;
}

fn void Ppu.advance_fetcher(&self) {
	Renderer* r = &self.r;
	switch (r.state) {
		case TILE_T1:
			self.update_wx_glitch();
			if ((self.r_lcdc & LCDC_WIN_ENABLE) == 0) r.wx_triggered = false;
			ushort map = 0x1800;
			if (r.wx_triggered ? (self.r_lcdc & LCDC_WIN_MAP) != 0 : (self.r_lcdc & LCDC_BG_MAP) != 0) map = 0x1C00;
			char y = self.fetcher_y();
			// A CGB-D/E keeps this Y for the tile's data too (SameBoy).
			r.fetch_y = y;
			char x;
			if (r.wx_triggered) {
				x = r.window_tile_x;
			} else if (u8(r.pos + 16) < 8) {
				x = self.scx >> 3;
			} else {
				int cgb_adj = (self.cgb_hw && r.obj_step == NONE) ? 1 : 0;
				x = (char)(((int)self.scx + r.pos + 8 - cgb_adj) / 8) & 0x1F;
			}
			r.addr = (ushort)(map + x + (y / 8) * 32);
			r.state = TILE_T2;
		case TILE_T2:
			if (r.cgb_wx_glitch) {
				r.state = LOW_T1;
				return;
			}
			r.tile = self.vram_read(r.addr);
			r.attr = self.cgb ? self.vram_read(r.addr | 0x2000) : 0;
			r.state = LOW_T1;
		case LOW_T1:
			self.update_wx_glitch();
			r.addr = self.tile_data_address();
			r.state = LOW_T2;
		case LOW_T2:
			if (r.cgb_wx_glitch) {
				r.lo = r.hi;
				r.state = HIGH_T1;
				return;
			}
			bool used;
			if (r.tile_sel_glitch) r.lo = self.tile_sel_glitch_data(&used);
			if (!used) r.last_read = r.lo = self.vram_read(r.addr);
			if (r.last_tileset && r.tile_sel_glitch) r.glitch_data = self.vram_read(r.addr);
			r.state = HIGH_T1;
		case HIGH_T1:
			self.update_wx_glitch();
			r.addr = self.tile_data_address() + 1;
			r.state = HIGH_T2;
		case HIGH_T2:
			if (r.cgb_wx_glitch) {
				// No push in this dot.
				r.hi = r.lo;
				r.state = PUSH;
				if (r.wx_triggered) r.window_tile_x = (r.window_tile_x + 1) & 0x1F;
				return;
			}
			bool used;
			if (r.tile_sel_glitch) r.hi = self.tile_sel_glitch_data(&used);
			if (!used) r.last_read = r.hi = self.vram_read(r.addr);
			if (r.last_tileset && r.tile_sel_glitch) r.glitch_data = self.vram_read(r.addr);
			if (r.wx_triggered) r.window_tile_x = (r.window_tile_x + 1) & 0x1F;
			r.state = PUSH;
			self.fetcher_push();
		case PUSH:
			self.fetcher_push();
	}
}

// CGB (up to CPU CGB C) TILE_SEL glitch, when the bit changes in the dot a
// bitplane is read (worked out from the Mealybug CGB screenshots):
// - clearing it reads the tile number instead (when the tile number is below
//   $80; the real read goes into the latch below);
// - setting it reads the latch: the high bitplane of the last object fetched,
//   or the bitplane byte read last when TILE_SEL was last cleared (in that
//   very dot, what the glitched read really fetched), whichever came later.
fn char Ppu.tile_sel_glitch_data(&self, bool* used) {
	Renderer* r = &self.r;
	if (r.last_tileset) {
		*used = (r.tile & 0x80) == 0;
		return r.tile;
	}
	*used = true;
	return r.glitch_data;
}

// Tile data address for the current tile and fetcher Y (TILE_SEL and SCY
// are read again for each bitplane; on a CGB-D/E only TILE_SEL).
fn ushort Ppu.tile_data_address(&self) {
	Renderer* r = &self.r;
	char y = self.after_c() ? r.fetch_y : self.fetcher_y();
	r.last_tileset = (self.r_lcdc & LCDC_TILE_DATA) != 0;
	int a = (self.r_lcdc & LCDC_TILE_DATA) ? (int)r.tile * 16 : (int)(ichar)r.tile * 16 + 0x1000;
	if (r.attr & ATTR_BANK) a += 0x2000;
	int fine = (r.attr & ATTR_YFLIP) ? 7 - (y & 7) : y & 7;
	return (ushort)(a + fine * 2);
}

// The fetched row goes into the background FIFO once that is empty.
fn void Ppu.fetcher_push(&self) {
	Renderer* r = &self.r;
	if (r.bg.size > 0) return;
	// DMG: with WIN_EN cleared after WY matched, WX matching still pushes a
	// single blank pixel.
	if (r.wy_triggered && (self.r_lcdc & LCDC_WIN_ENABLE) == 0 && !self.cgb_hw && !r.no_insert_glitch) {
		char logical = u8(r.pos + 7);
		if (logical > 167) logical = 0;
		if (self.wx == logical) {
			r.bg.clear();
			r.bg.size = 1;
			*r.bg.at(0) = {};
			return;
		}
	}
	bool xflip = (r.attr & ATTR_XFLIP) != 0;
	char lo = r.lo;
	char hi = r.hi;
	r.bg.clear();
	for (int i = 0; i < 8; i++) {
		char color = (char)(((hi >> 7) << 1) | (lo >> 7));
		lo <<= 1;
		hi <<= 1;
		r.bg.px[xflip ? 7 - i : i] = {
			.color = color,
			.palette = r.attr & ATTR_PALETTE,
			.bg_prio = (r.attr & ATTR_PRIORITY) != 0,
		};
	}
	r.bg.size = 8;
	r.state = TILE_T1;
}

// Pop a pixel (if the FIFO has one and no object at X = 0 is pending), drop
// it while in the junk/fine-scroll area, otherwise mix and draw it.
fn void Ppu.render_pixel(&self) {
	Renderer* r = &self.r;
	if (r.n_obj > 0 && self.objects_fetched() && r.obj_x[r.n_obj - 1] == 0) return;
	if (r.bg.size == 0) return;

	Pixel bg;
	if (r.insert_bg_pixel) {
		r.insert_bg_pixel = false;
	} else {
		bg = r.bg.pop();
	}
	bool bg_prio = bg.bg_prio;
	bool draw_obj = false;
	Pixel ob;
	if (r.obj.size > 0) {
		ob = r.obj.pop();
		if (ob.color != 0 && (self.r_lcdc & LCDC_OBJ_ENABLE)) {
			draw_obj = true;
			bg_prio |= ob.bg_prio;
		}
	}

	if (u8(r.pos + 16) < 8) {
		// The first 8 positions: the junk pixels, and dropping SCX & 7 pixels
		// of the first tile.
		// On a DMG an SCX write landing this dot comes after the check
		// (Gambatte scxChange: the PPU runs up to the write first;
		// scx_m3_extend). The first line after LCD on has its own timing.
		char scx = self.scx_landed && !self.cgb_hw && !self.first_line ? self.scx_before : self.scx;
		if ((r.pos & 7) == (scx & 7)) {
			r.pos = -8;
		} else if (r.window_fetching && (r.pos & 7) == 6 && (scx & 7) == 7) {
			r.pos = -8;
		} else if (r.pos == -9) {
			r.pos = -16;
			return;
		} else {
			r.fractional = true;
		}
	}
	r.window_fetching = false;

	if (r.pos < 0 || r.pos >= 160) {
		r.pos++;
		return;
	}

	bool bg_on = true;
	if ((self.r_lcdc & LCDC_BG_ENABLE) == 0) {
		if (self.cgb) {
			bg_prio = false;   // CGB: LCDC.0 only takes the BG's priority away
		} else {
			bg_on = false;
		}
	}
	char color = bg_on ? bg.color : 0;
	if (color != 0 && bg_prio) draw_obj = false;

	if (r.lcd_x < WIDTH) {
		int at = self.line * WIDTH + r.lcd_x;
		if (self.cgb) {
			if (self.cfb.len) {
				self.cfb[at] = draw_obj ? pal_color(&self.obj_pal, ob.palette, ob.color)
				                        : pal_color(&self.bg_pal, bg.palette, color);
			}
		} else {
			char s = draw_obj ? shade(ob.palette ? self.obp1 : self.obp0, ob.color) : shade(self.bgp, color);
			if (self.fb.len) self.fb[at] = s;
			if (self.compat && self.cfb.len) {
				self.cfb[at] = draw_obj ? pal_color(&self.obj_pal, ob.palette, s) : pal_color(&self.bg_pal, 0, s);
			}
		}
	}
	if (r.pos == WIDTH - 2) r.x158_dot = self.dot;
	r.pos++;
	r.lcd_x++;
}

// After pixel 159: the rest of the line keeps its last colour if the LCD fell
// behind, and the window state moves on.
fn void Ppu.render_end(&self) {
	Renderer* r = &self.r;
	r.active = false;
	while (r.lcd_x < WIDTH) {
		int at = self.line * WIDTH + r.lcd_x;
		if (r.lcd_x > 0) {
			if (self.fb.len) self.fb[at] = self.fb[at - 1];
			if (self.cfb.len) self.cfb[at] = self.cfb[at - 1];
		}
		r.lcd_x++;
	}
	if (self.line == VBLANK_LINE - 1) r.window_y = -1;
	// DMG: WX 166 matched (WIN_EN or not) leaves the window to start with
	// the next line, if WIN_EN is set then (Gambatte win_draw_start; see
	// render_start).
	if (!self.cgb_hw && r.wy_triggered && self.wx == 166) {
		r.wx_triggered = true;
		r.window_tile_x = 1;
		self.win_armed = (self.r_lcdc & LCDC_WIN_ENABLE) == 0;
	} else {
		r.wx_triggered = false;
	}
}

// Gambatte: the window turns on for the frame at cycle 450 of a line when WY
// is that line, at 454 when WY is the next one (lines 0-142), and on line 0 at
// cycle 1 (CGB 2) when WY is 0.
fn void Ppu.window_line_checks(&self) {
	if ((self.lcdc & LCDC_ENABLE) == 0) return;
	bool en = (self.we_lcdc & LCDC_WIN_ENABLE) != 0;
	if (self.line == 0 && self.dot == (self.cgb_hw ? 2 : 1)) {
		self.r.wy_triggered = en && self.wy == 0;
	} else if (self.line < VBLANK_LINE - 1) {
		if (self.dot == 450 && en && self.wy == u8(self.line)) self.r.wy_triggered = true;
		if (self.dot == 454 && en && self.wy == u8(self.line + 1)) self.r.wy_triggered = true;
	}
}

// WY is compared with LY when a line starts (and when WY is written).
fn void Ppu.wy_check(&self) {
	if ((self.lcdc & LCDC_ENABLE) == 0) return;
	if ((self.r_lcdc & LCDC_WIN_ENABLE) && self.wy == u8(self.line)) self.r.wy_triggered = true;
}

// A new frame: the window waits for WY again.
// A DMG window started at WX 166 on line 143 carries over the VBlank into
// line 0 (Gambatte: winDrawState survives), unless the LCD was switched off.
fn void Ppu.render_frame_start(&self, bool keep_carry = false) {
	bool carry = keep_carry && self.r.wx_triggered && !self.cgb_hw;
	self.r.wy_triggered = false;
	self.r.window_y = -1;
	self.r.wx_triggered = carry;
}
