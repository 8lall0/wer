module ppu;
import std::io;

const int WIDTH  = 160;
const int HEIGHT = 144;

const int DOTS_PER_LINE = 456;
const int TOTAL_LINES   = 154;
const int VBLANK_LINE   = 144;
const int MODE2_DOTS    = 80;   // OAM scan
const int MODE3_DOTS    = 172;  // drawing, minimum (a plain line; see Ppu.predict_mode3)
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

// CGB revisions (mmu::CgbRevision's ordinals).
const char REV_0 = 0;
const char REV_A = 1;
const char REV_B = 2;
const char REV_C = 3;
const char REV_D = 4;
const char REV_E = 5;

struct Ppu {
	int  irq_dot;        // tick(): the dot of the call that raised the first IRQ, or -1
	char[0x2000] vram;
	char*        vram1;  // CGB: VRAM bank 1 (heap), null otherwise
	char[0xA0]   oam;
	// An OAM DMA owns OAM from oam_dma_from until oam_dma_until (Ppu.cc):
	// meanwhile the object scan reads $FF (Gambatte startOamDma).
	ulong        oam_dma_from;
	ulong        oam_dma_until;
	char         scx_before;  // SCX before a write that landed this dot (the fine scroll check still sees it)
	bool         scx_landed;
	char[0xA0]   oam_pre_dma; // OAM as the DMA found it (for entries the scan read before)
	char[] fb;
	// CGB mode: the picture as RGB555 colours (heap), and the switch between
	// the DMG and CGB renderers (Mmu.cgb_mode's copy).
	ushort[] cfb;
	bool     cgb;
	bool     compat;  // CGB running a DMG game: DMG renderer, colours from palette RAM
	bool     cgb_hw;  // CGB hardware, in either mode (timing differences)
	char     rev;     // ... its revision (REV_*, mmu::CgbRevision's ordinal)
	bool     mgb;     // Game Boy Pocket / Light
	char     pal_written; // DMG: BGP/OBP0/OBP1 (bits 0-2) written during this line

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
	char wy2;   // WY for the late check at the WX match (Ppu.window_check)
	char we_lcdc; // LCDC for the window line checks (Ppu.window_line_checks)
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
	bool frame_ready;  // set when VBlank begins; cleared by the consumer
	bool first_line;
	int  line;         // line being processed (LY runs LY_EARLY_DOTS ahead of it)
	bool predicting;   // a dry-run copy (Ppu.predict_mode3): no pixels, no prediction of its own
	bool repredict;    // a renderer write landed during mode 3: predict again
	int  pipe_end_dot; // the dot the pipeline outputs its last pixel this line (predicted)
	int  m0_irq_pred;  // ... and the mode 0 interrupt's dot (Ppu.m0_irq_dot)
	bool double_speed; // CGB double speed (set by the Mmu)
	bool hblank_start; // HBlank DMA time on a visible line (CGB HDMA); cleared by the Mmu

	// Mode 3 drawing (ppu_fifo.c3), and what it sees of the registers: SCY,
	// SCX, WY, WX and the palettes change a few dots after the CPU writes
	// them (Ppu.write_render_reg), LCDC through r_lcdc since its enable bit
	// must act at once.
	Renderer r;
	Renderer win_save;     // the renderer as the window started (CGB abort, see render_dot)
	bool     win_abortable;
	bool     win_late_off;  // DMG: a window started as WIN_EN went off (see render_dot)
	bool     win_armed;     // DMG: WX 166 matched with WIN_EN off, the window not started
	char     r_lcdc;
	bool     wx_just_changed;
	bool     sgb_hw;       // Super Game Boy: slightly different write timing
	RegWrite[8] writes;
	int      n_writes;
	ulong    lcd_on_cc;     // when the LCD was last switched on
	bool     hide_frame;    // the frame since the LCD went on isn't shown
	char     scan_y_bus;    // the OAM scan's last Y and X read (kept while a DMA has OAM)
	char     scan_x_bus;
	ulong    cc;            // Gambatte's cycle count: +1 per dot, +2 in double speed (ppu_irq.c3)
	StatIrq  si;
}

// Dot of a visible line at which mode 3 drawing starts fetching (a variable
// so the calibration can be swept from a test).
int render_start_dot = 89;

// A register write the renderer sees `delay` dots after the CPU made it.
struct RegWrite {
	char reg;    // low byte of the register address; WX_SETTLED ends wx_just_changed
	char value;
	char old;    // LCDC_DMG, LCDC_PART: the value before the write
	char keep;   // LCDC_PART: bits that still show the old value
	int  delay;
}

const char WX_SETTLED = 0x00;
const char TILE_SEL_GLITCH_ON  = 0x02; // CGB: TILE_SEL cleared on a bitplane read (see ppu_fifo)
const char TILE_SEL_GLITCH_OFF = 0x03;
const char TILE_SEL_CLEARED    = 0x05; // CGB: latch the last bitplane read (see ppu_fifo)
const char LCDC_DMG   = 0x01; // DMG LCDC write: mixed old/new value for a dot (see apply)
const char LCDC_PART  = 0x04; // LCDC write where the bits in `keep` land later
const int[3] WYD = { 2, 3, 2 };
const int[3] WE_DELAY = { 0, 3, 2 }; // DMG, CGB, CGB double speed (window/late_enable_afterVblank*)
const int[3] WY2D = { 10, 13, 9 };
const char WY2        = 0x08;
const char WE_LINE    = 0x09; // LCDC as the window line checks see it (Gambatte p.lcdc) // WY as the WX-time window check sees it (Gambatte wy2)

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

// A CGB-D or E (SameBoy: model > CGB_C), where many timings changed.
fn bool Ppu.after_c(&self) => self.cgb_hw && self.rev > REV_C;

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

fn char Ppu.write_lcdc(&self, char value) {
	bool was_on = (self.lcdc & LCDC_ENABLE) != 0;
	char irq = 0;
	if (was_on && (value & LCDC_ENABLE) == 0) {
		// The LY=LYC flag freezes as it was (Gambatte).
		self.stat = (self.stat & 0xF8) | (self.lyc_flag() ? STAT_LYC_FLAG : 0);
	}
	self.lcdc = value;
	if (!was_on && (value & LCDC_ENABLE) != 0) {
		bool flag_was = (self.stat & STAT_LYC_FLAG) != 0;
		self.dot = LCDON_START_DOT;
		self.ly = 0;
		self.line = 0;
		self.mode = 0;
		self.stat = self.stat & 0xF8;
		self.frame_ready = false;
		self.r_lcdc = value;
		self.we_lcdc = value;
		self.render_frame_start();
		self.first_line = true;
		// Until line 0 is predicted, its mode 0 interrupt is a plain line's
		// (not whatever line drew last, if any did).
		self.m0_irq_pred = MODE2_DOTS + MODE3_DOTS + (self.scx & 7) + PLAIN_PIPE_EXTRA - M0_IRQ_BEFORE_END;
		self.lcd_on_cc = self.cc;
		self.hide_frame = true;
		self.irq_reschedule(true);
		// LY=LYC turns true at once with LYC 0.
		if ((self.si.stat & STAT_LYC_IE) && self.lyc == 0 && !flag_was) irq = INT_STAT;
	}
	if (was_on && (value & LCDC_ENABLE) == 0) {
		self.irq_lcd_off();
		self.blank();
	}
	return irq;
}

// With the LCD off the screen shows no picture: white (the lightest shade).
fn void Ppu.blank(&self) {
	foreach (&px : self.fb) *px = 0;
	foreach (&px : self.cfb) *px = 0x7FFF;
}



fn char Ppu.tick(&self, uint tcycles) {
	if ((self.lcdc & LCDC_ENABLE) == 0) {
		self.flush_writes();
		self.dot = 0;
		self.ly = 0;
		self.line = 0;
		self.mode = 0;
		self.stat &= 0xFC;
		self.r.active = false;
		return 0;
	}

	char irq = 0;
	self.irq_dot = -1;
	for (uint i = 0; i < tcycles; i++) {
		if (self.repredict && self.r.active && !self.predicting) self.predict_mode3();
		self.scx_landed = false;
		self.apply_writes();
		self.window_line_checks();
		// Mode 3 drawing for this dot (before the counters move on).
		if (self.line < VBLANK_LINE) {
			int scan = self.oam_scan_index();
			if (scan >= 0) {
				self.oam_scan(scan);
			} else if (self.cgb_hw && self.r.scan_tall_only > 0) {
				self.oam_scan_second();
			}
			// The first line after the LCD is switched on has no OAM scan and
			// starts drawing earlier.
			int start = self.first_line ? render_start_dot - (self.cgb_hw ? 6 : 5) : render_start_dot;
			if (self.dot == start) {
				self.render_start();
				// The OAM scan is done: predict where this line's mode 3 ends
				// (from the start of the next dot, with this one complete).
				if (!self.predicting) self.repredict = true;
			}
			if (self.r.active) self.render_dot();
		}
		self.dot++;
		self.cc += self.spd();
		if (self.dot == DOTS_PER_LINE - LY_EARLY_DOTS) {
			self.ly = (char)((self.line + 1) % TOTAL_LINES);
		}
		if (self.dot >= DOTS_PER_LINE) {
			self.first_line = false;
			self.dot = 0;
			if (self.r.active) self.render_end(); // never happens with sane timing
			self.line = (self.line + 1) % TOTAL_LINES;
			self.pal_written = 0;
			if (self.line == 0) self.render_frame_start(true);
			// Line 153 reads LY 0 almost all along (2 dots later in double speed).
			if (self.line == TOTAL_LINES - 1 && !self.double_speed) self.ly = 0;
		} else if (self.line == TOTAL_LINES - 1 && self.dot == 2) {
			self.ly = 0;
		}
		// HBlank DMA: at Gambatte's mode 0 time, 2 cycles after STAT reads 0
		// (the block is copied at the next instruction boundary, Cpu.step).
		if (self.line < VBLANK_LINE && !self.predicting && self.dot > MODE3_START_DOT
			&& self.dot == self.m0_stat_dot() + (self.double_speed ? 1 : 2)) self.hblank_start = true;
		char now = self.update_mode() | self.irq_events();
		if (now && self.irq_dot < 0) self.irq_dot = (int)i;
		irq |= now;
	}
	return irq;
}






// A plain line's pipeline outputs its last pixel this many dots after the
// Pan Docs' 80 + 172 + SCX % 8.
const int PLAIN_PIPE_EXTRA = 5;
// STAT reads mode 0 this many dots before the pipeline outputs its last pixel
// (Gambatte: from dot 249 on a plain line). Objects and the window need
// nothing more: the pipeline already matches Gambatte's mode 0 times.
const int MODE3_TAIL = 8;
// The mode 0 interrupt comes when Gambatte's pixel counter reaches 166:
// this many dots before the pipeline's end if nothing stalls it after pixel
// 158 (a window or objects at the right edge only delay STAT's mode 0).
const int M0_IRQ_BEFORE_END = 7;

// How many dots before the pipeline's last pixel STAT leaves mode 3.
fn int Ppu.mode3_tail(&self) {
	int t = MODE3_TAIL;
	// Gambatte: STAT reads mode 3 until 2 cycles before mode 0 - a dot in
	// double speed.
	if (self.double_speed) t -= 1;
	// The first line after LCD on starts drawing 5 dots early (6 on a CGB)
	// while its mode 3 starts on time; it ends at dot 251 + SCX & 7
	// (Gambatte enable_display/ly0_late_scx7*).
	if (self.first_line) t -= self.cgb_hw ? 8 : 7;
	return t;
}

// When this line's mode 3 ends: run a copy of the PPU ahead, without
// drawing, to the dot its pipeline outputs the last pixel, with every
// register write already on its way included. Done once the OAM scan is
// over, and again whenever a register the renderer sees is written during
// mode 3 (Ppu.repredict). Objects, the window, mid-line SCX/WX/WY/LCDC
// changes all count as they really happen.
fn void Ppu.predict_mode3(&self) {
	self.repredict = false;
	// A plain line (no objects, no window that could start, no write on its
	// way): the pipeline's end only depends on SCX; no need to run it.
	bool window_possible = self.r.wx_triggered
		|| ((self.r_lcdc & LCDC_WIN_ENABLE) && (self.r.wy_triggered || self.wy2 == u8(self.line) || self.wy == u8(self.line + 1)) && self.wx <= 166);
	if (!self.first_line && self.r.n_obj == 0 && !window_possible && self.n_writes == 0) {
		self.pipe_end_dot = MODE2_DOTS + MODE3_DOTS + (self.scx & 7) + PLAIN_PIPE_EXTRA;
		self.m0_irq_pred = self.pipe_end_dot - M0_IRQ_BEFORE_END;
		return;
	}
	Ppu sim = *self;
	sim.fb = {};
	sim.cfb = {};
	sim.predicting = true;
	// Only what the pipeline needs, dot by dot: the register writes landing,
	// then a pixel step (as in Ppu.tick).
	self.pipe_end_dot = DOTS_PER_LINE;
	while (sim.dot < DOTS_PER_LINE) {
		sim.scx_landed = false;
		sim.apply_writes();
		if (sim.r.active) sim.render_dot();
		sim.dot++;
		if (!sim.r.active) {
			self.pipe_end_dot = sim.dot;
			break;
		}
	}
	self.m0_irq_pred = sim.r.x158_dot >= 0 ? sim.r.x158_dot + 2 - M0_IRQ_BEFORE_END : self.pipe_end_dot - M0_IRQ_BEFORE_END;
}

// STAT's mode, as Gambatte's LCD::getStat has it (in dots of the line, LY
// counting from its change at dot 0): VBlank from dot 454 of line 143 to dot
// 451 of line 153; mode 2 from dot 453 of the line before to dot 76; mode 3
// from dot 77 until the pipeline's end (Ppu.mode3_tail).
// Debugging: print the dot each line's mode 0 starts (cpu::io_trace format).
bool trace_m0;

const int MODE3_START_DOT = 77;
const int MODE2_START_DOT = 453;
const int VBLANK_START_DOT = 454;      // of line 143
const int VBLANK_END_DOT = 452;        // of line 153
fn char Ppu.update_mode(&self) {
	// Until the prediction (Ppu.predict_mode3) is in, mode 3 lasts.
	if (self.dot == MODE3_START_DOT && self.line < VBLANK_LINE) {
		self.pipe_end_dot = DOTS_PER_LINE;
		self.m0_irq_pred = DOTS_PER_LINE;
	}

	char want;
	int vblank_end = VBLANK_END_DOT + (self.double_speed ? 1 : 0);
	// A CGB-D/E has no mode-0 M-cycle between VBlank and line 0's mode 2
	// (AGE stat-mode-cgbE; SameBoy: model > CGB_C).
	if (self.after_c()) vblank_end = MODE2_START_DOT;
	if ((self.line >= VBLANK_LINE && self.line < TOTAL_LINES - 1)
		|| (self.line == VBLANK_LINE - 1 && self.dot >= VBLANK_START_DOT)
		|| (self.line == TOTAL_LINES - 1 && self.dot < vblank_end)) {
		want = 1;
	} else if ((self.line == VBLANK_LINE - 1 && self.dot >= VBLANK_START_DOT - 1)
		|| (self.line == TOTAL_LINES - 1 && self.dot < MODE2_START_DOT)) {
		want = 0;
	} else if (self.dot < MODE3_START_DOT || self.dot >= MODE2_START_DOT) {
		want = 2;
	} else if (self.dot < self.pipe_end_dot - self.mode3_tail()) {
		want = 3;
	} else {
		want = 0;
	}

	// Right after LCD on STAT reads mode 0 for a while (Gambatte getStat:
	// inactivePeriodAfterDisplayEnable; mode 3 too in double speed).
	if (self.first_line && (want == 2 || want == 3) && self.inactive_after_enable(1)) {
		want = 0;
	}
	if (want == self.mode) return 0;
	if (trace_m0 && !self.predicting && want == 0 && self.mode == 3) io::eprintfn("M0 ly %d lc %d", self.line, self.dot);
	self.mode = want;
	self.stat = (self.stat & 0xFC) | want;

	char irq = 0;
	if (want == 1) {
		// The LCD shows nothing for the first frame after it is switched on
		// (little-things-gb firstwhite; SameBoy).
		if (self.hide_frame) {
			self.hide_frame = false;
			self.blank();
		}
		self.frame_ready = true;
		irq |= INT_VBLANK;
	}
	return irq;
}


// A CPU write to SCY, SCX, WY, WX, BGP, OBP0/1 or LCDC as the renderer sees
// it, with each register's delay: SameBoy's write-conflict tables, except
// that on a DMG LCDC and SCY land a dot earlier here (calibrated on the
// Mealybug tests: our dots and SameBoy's T-cycles line up differently for
// those two). The
// register itself (what the CPU reads, and the timing code) was already set;
// LCDC reaches the renderer through r_lcdc.
// CGB write delays (LCDC, SCY, SCX, WX, TILE_SEL glitch dot): SameBoy's,
// swept on the Mealybug tests.
int[5] cgb_delay = { 8, 8, 8, 9, 8 };
// In double speed the CPU's writes reach the renderer earlier in dots: one
// dot for all of these (swept on Gambatte *_ds, scx_during_m3).
const int DS_DELAY_SHIFT = 1;
// A WY write reaches the renderer on the next dot (line starts compare with
// it from then on), and is compared with LY by itself this many dots after the
// write (swept on Gambatte window/*late_wy*; SameBoy schedules that check on
// an 8-cycle boundary after the write).

// CGB write delay `i` (cgb_delay), shorter in double speed.
fn int Ppu.cgb_delay(&self, int i) {
	int d = cgb_delay[i] - (self.double_speed ? DS_DELAY_SHIFT : 0);
	return d < 0 ? 0 : d;
}

fn void Ppu.write_render_reg(&self, char reg, char value) {
	self.repredict = true;
	char old;
	switch (reg) {
		case 0x40: old = self.r_lcdc;
		case 0x42: old = self.scy;
		case 0x43: old = self.scx;
		case 0x4A: old = self.wy;
		case 0x4B: old = self.wx;
		case 0x47: old = self.bgp;
		case 0x48: old = self.obp0;
		case 0x49: old = self.obp1;
	}
	old = self.cpu_view(reg, old);
	bool dmg = !self.cgb_hw;
	if (reg == 0x40) self.schedule(WE_LINE, value, dmg ? WE_DELAY[0] : (self.double_speed ? WE_DELAY[2] : WE_DELAY[1]));
	switch (reg) {
		case 0x42: self.schedule(reg, value, dmg ? 6 : self.cgb_delay(1));
		case 0x43:
			int d = dmg ? 6 : self.cgb_delay(2);
			// The first line after LCD on draws early: its fine-scroll discard
			// sees SCX the dot it is written (Gambatte enable_display/ly0_late_scx7*).
			if (self.first_line) d = 0;
			self.schedule(reg, value, d);
		case 0x4A:
			// Gambatte: the line checks see the new WY 1 cycle later (2 on a
			// CGB), the check at the WX match 2 (CGB: 6, 5 in double speed).
			self.schedule(reg, value, dmg ? WYD[0] : (self.double_speed ? WYD[2] : WYD[1]));
			self.schedule(WY2, value, dmg ? WY2D[0] : (self.double_speed ? WY2D[2] : WY2D[1]));
		case 0x4B:
			self.schedule(reg, value, dmg ? 8 : self.cgb_delay(3));
			if (dmg) self.schedule(WX_SETTLED, 0, 9);
		case 0x47:
		case 0x48:
		case 0x49:
			// DMG: the renderer sees the new value 6 dots on; for that first
			// dot it reads as old | new when the palette was already written
			// earlier in the line (Mealybug m3_bgp_change, AGE
			// m3-bg-bgp: 12-60 dots before), not after a line or more
			// (Gambatte dmgpalette_during_m3: 300+ dots).
			char bit = (char)(1 << (reg - 0x47));
			bool glitch = (self.pal_written & bit) != 0;
			self.pal_written |= bit;
			if (dmg && !self.sgb_hw) {
				if (glitch) {
					self.queue({ .reg = reg, .value = old | value, .old = value, .keep = 0xFF, .delay = 6 });
				} else {
					self.queue({ .reg = reg, .value = value, .delay = 6 });
				}
			}
			// A CGB-D/E's renderer sees them a dot sooner (AGE m3-bg-bgp-ncmE;
			// SameBoy GB_CONFLICT_PALETTE_CGB, model >= CGB_D).
			self.schedule(reg, value, self.after_c() ? 6 : 7);
		case 0x40:
			if (dmg && !self.sgb_hw) {
				self.queue({ .reg = LCDC_DMG, .value = value, .old = old, .delay = 6 });
				self.schedule(reg, value, 7);
			} else if (!dmg && ((old ^ value) & LCDC_TILE_DATA)) {
				// CGB: changing TILE_SEL disturbs a bitplane read in that dot.
				self.schedule(reg, value, self.cgb_delay(0));
				self.schedule(TILE_SEL_GLITCH_ON, 0, self.cgb_delay(4));
				if ((value & LCDC_TILE_DATA) == 0) self.schedule(TILE_SEL_CLEARED, 0, self.cgb_delay(4));
				self.schedule(TILE_SEL_GLITCH_OFF, 0, self.cgb_delay(4) + 1);
			} else if (!dmg) {
				// CGB: the object size bit lands a dot later than the rest
				// (Mealybug m3_lcdc_obj_size_change_scx).
				self.queue({ .reg = LCDC_PART, .value = value, .old = old, .keep = LCDC_OBJ_SIZE, .delay = self.cgb_delay(0) });
				self.schedule(reg, value, self.cgb_delay(0) + 1);
			} else {
				self.schedule(reg, value, 2);
			}
	}
}

// What the CPU reads back: the last value written, even if the renderer
// hasn't seen it yet.
fn char Ppu.cpu_view(&self, char reg, char current) {
	for (int i = self.n_writes - 1; i >= 0; i--) {
		if (self.writes[i].reg == reg) return self.writes[i].value;
	}
	return current;
}

fn void Ppu.schedule(&self, char reg, char value, int delay) {
	self.queue({ .reg = reg, .value = value, .delay = delay });
}

fn void Ppu.queue(&self, RegWrite w) {
	if (self.n_writes == self.writes.len) self.flush_writes();
	self.writes[self.n_writes++] = w;
}

// Apply every pending write now (the queue is full).
fn void Ppu.flush_writes(&self) {
	for (int i = 0; i < self.n_writes; i++) self.apply(self.writes[i]);
	self.n_writes = 0;
}

// Once per dot: writes that are due land, the others come a dot closer.
fn void Ppu.apply_writes(&self) {
	int kept = 0;
	for (int i = 0; i < self.n_writes; i++) {
		RegWrite w = self.writes[i];
		if (w.delay <= 0) {
			self.apply(w);
		} else {
			w.delay--;
			self.writes[kept++] = w;
		}
	}
	self.n_writes = kept;
}

// DMG window state on a WIN_EN change (Gambatte PPU::setLcdc), for a window
// carried over from a WX 166 match: going off between lines leaves it armed
// but not started; going on while armed starts it, a window line
// (window/on_screen/wxA6_weoff_at_xposA6, wxA6_late_we_reenable).
fn void Ppu.dmg_we_change(&self, char lcdc) {
	if (self.cgb_hw) return;
	bool was = (self.r_lcdc & LCDC_WIN_ENABLE) != 0;
	bool now = (lcdc & LCDC_WIN_ENABLE) != 0;
	if (was && !now && self.r.wx_triggered && !self.r.active) self.win_armed = true;
	if (!was && now && self.win_armed) {
		self.r.window_y++;
		self.win_armed = false;
	}
}

// The palette in a DMG write's glitch dot (RegWrite.keep $FF marks it,
// .old holds the new value): old | new, except for a line's first pixel,
// which has the new value already (AGE m3-bg-bgp-dmgC).
fn char Ppu.pal_glitch_value(&self, RegWrite w) {
	if (w.keep != 0xFF) return w.value;
	if (self.r.active && self.r.lcd_x == 0) return w.old;
	return w.value;
}

fn void Ppu.apply(&self, RegWrite w) {
	switch (w.reg) {
		case WX_SETTLED: self.wx_just_changed = false;
		case TILE_SEL_GLITCH_ON: self.r.tile_sel_glitch = true;
		case TILE_SEL_GLITCH_OFF: self.r.tile_sel_glitch = false;
		case TILE_SEL_CLEARED: self.r.glitch_data = self.r.last_read;
		case 0x42: self.scy = w.value;
		case 0x43:
			self.scx_before = self.scx;
			self.scx_landed = true;
			self.scx = w.value;
		case 0x4A: self.wy = w.value;
		case WY2: self.wy2 = w.value;
		case WE_LINE: self.we_lcdc = w.value;
		case 0x4B:
			self.wx = w.value;
			if (!self.cgb_hw) self.wx_just_changed = true;
		case 0x47: self.bgp = self.pal_glitch_value(w);
		case 0x48: self.obp0 = self.pal_glitch_value(w);
		case 0x49: self.obp1 = self.pal_glitch_value(w);
		case 0x40:
			// DMG: WIN_EN going on with the window armed but not started (a WX
			// 166 match while it was off) starts it: a window line (Gambatte
			// PPU::setLcdc; window/on_screen/wxA6_weoff_at_xposA6).
			self.dmg_we_change(w.value);
			self.r_lcdc = (self.r_lcdc & LCDC_ENABLE) | (w.value & 0x7F);
		case LCDC_PART:
			self.r_lcdc = (self.r_lcdc & LCDC_ENABLE) | (((w.value & ~w.keep) | (w.old & w.keep)) & 0x7F);
		case LCDC_DMG:
			// The new LCDC, except that the BG and object enable bits and a
			// window enable (not a disable) take a dot longer. Disabling objects
			// during an object fetch or at the first pixel, and disabling the BG
			// at the first pixel (not on a Pocket), are immediate. (SameBoy's
			// DMG LCDC conflict, reworked against the Mealybug DMG screenshots.)
			char keep = LCDC_OBJ_ENABLE | LCDC_BG_ENABLE;
			if ((w.value & LCDC_BG_ENABLE) == 0 && self.r.pos == 0) keep &= (char)~LCDC_BG_ENABLE;
			if ((w.old & LCDC_WIN_ENABLE) == 0) keep |= LCDC_WIN_ENABLE;
			if ((w.value & LCDC_OBJ_ENABLE) == 0 && ((self.r.pos == 0 && !self.mgb) || self.during_object_fetch())) keep &= (char)~LCDC_OBJ_ENABLE;
			if ((w.old & LCDC_OBJ_ENABLE) && (w.value & LCDC_OBJ_ENABLE) == 0 && self.during_object_fetch()) self.r.obj_abort = true;
			self.dmg_we_change(((w.value & ~keep) | (w.old & keep)));
			self.r_lcdc = (self.r_lcdc & LCDC_ENABLE) | (((w.value & ~keep) | (w.old & keep)) & 0x7F);
			if ((w.old & LCDC_WIN_ENABLE) && (w.value & LCDC_WIN_ENABLE) == 0 && self.r.window_fetching) {
				self.r.no_insert_glitch = true;
			}
	}
}

// The trademark symbol the DMG boot ROM draws next to the logo.
const char[8] REGISTERED = { 0x3C, 0x42, 0xB9, 0xA5, 0xB9, 0xA5, 0x42, 0x3C };

// VRAM as Nintendo's DMG boot ROM leaves it: the cartridge's header logo
// (48 bytes, a nibble per 4-pixel row, doubled to 8x8 tiles 1-24), the
// (R) symbol as tile 25, and both in the tile map at $9904 / $9924. Some
// test ROMs draw with these tiles (Mealybug Tearoom's (R) sprites).
fn void Ppu.load_boot_logo(&self, char[] logo) {
	usz at = 0x10;
	foreach (b : logo) {
		foreach (nibble : (char[2]){ b >> 4, b & 0x0F }) {
			char row;
			for (int bit = 3; bit >= 0; bit--) {
				row = (char)(row << 2) | (((nibble >> bit) & 1) != 0 ? 3 : 0);
			}
			for (int twice = 0; twice < 2; twice++) {
				self.vram[at] = row;       // bitplane 0 only: colour 1 (BGP maps it to black)
				self.vram[at + 1] = 0;
				at += 2;
			}
		}
	}
	foreach (i, b : REGISTERED) {
		self.vram[0x190 + i * 2] = b;
		self.vram[0x190 + i * 2 + 1] = 0;
	}
	for (int i = 0; i < 12; i++) {
		self.vram[0x1904 + i] = (char)(i + 1);
		self.vram[0x1924 + i] = (char)(i + 13);
	}
	self.vram[0x1910] = 0x19;
}
