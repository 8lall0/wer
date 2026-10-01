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
	int  irq_dot;        // tick(): the dot of the call that raised the first IRQ, or -1
	bool irq_m2;         // ... and it was the mode 2 STAT interrupt
	bool stat_m2;        // update_stat_line(): the rise came from mode 2 alone
	char[0x2000] vram;
	char*        vram1;  // CGB: VRAM bank 1 (heap), null otherwise
	char[0xA0]   oam;
	char[] fb;
	// CGB mode: the picture as RGB555 colours (heap), and the switch between
	// the DMG and CGB renderers (Mmu.cgb_mode's copy).
	ushort[] cfb;
	bool     cgb;
	bool     compat;  // CGB running a DMG game: DMG renderer, colours from palette RAM
	bool     cgb_hw;  // CGB hardware, in either mode (timing differences)

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
	bool frame_ready;  // set when VBlank begins; cleared by the consumer
	bool stat_line;    // OR of the enabled STAT sources (see update_stat_line)
	bool first_line;
	int  line;         // line being processed (LY runs LY_EARLY_DOTS ahead of it)
	int  mode3_len;    // length of this line's mode 3, fixed when it starts
	bool hblank_start; // a visible line's last pixel is out (CGB HDMA); cleared by the Mmu

	// Mode 3 drawing (ppu_fifo.c3), and what it sees of the registers: SCY,
	// SCX, WY, WX and the palettes change a few dots after the CPU writes
	// them (Ppu.write_render_reg), LCDC through r_lcdc since its enable bit
	// must act at once.
	Renderer r;
	char     r_lcdc;
	bool     wx_just_changed;
	bool     sgb_hw;       // Super Game Boy: slightly different write timing
	bool     lcd_on_by_cpu; // the LCD was last switched on by a CPU write (see late_oam_irq)
	RegWrite[8] writes;
	int      n_writes;
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
		self.mode = 0;
		self.stat = self.stat & 0xFC;
		self.frame_ready = false;
		self.r_lcdc = value;
		self.render_frame_start();
		self.lcd_on_by_cpu = true;
		self.first_line = true;
		self.check_lyc();
	}
	if (was_on && (value & LCDC_ENABLE) == 0) self.blank();
}

// With the LCD off the screen shows no picture: white (the lightest shade).
fn void Ppu.blank(&self) {
	foreach (&px : self.fb) *px = 0;
	foreach (&px : self.cfb) *px = 0x7FFF;
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
		self.flush_writes();
		self.dot = 0;
		self.ly = 0;
		self.line = 0;
		self.mode = 0;
		self.stat &= 0xFC;
		self.r.active = false;
		// stat_line and the LY=LYC flag stay frozen while the LCD is off, so
		// turning it back on only raises an IRQ if the line really goes 0 -> 1.
		return 0;
	}

	char irq = 0;
	self.irq_dot = -1;
	for (uint i = 0; i < tcycles; i++) {
		self.apply_writes();
		// Mode 3 drawing for this dot (before the counters move on).
		if (self.line < VBLANK_LINE) {
			int scan = self.oam_scan_index();
			if (scan >= 0) self.oam_scan(scan);
			// The first line after the LCD is switched on has no OAM scan and
			// starts drawing earlier.
			int start = self.first_line ? render_start_dot - (self.cgb_hw ? 6 : 5) : render_start_dot;
			if (self.dot == start) self.render_start();
			if (self.r.active) self.render_dot();
		}
		self.dot++;
		if (self.dot == DOTS_PER_LINE - LY_EARLY_DOTS) {
			self.ly = (char)((self.line + 1) % TOTAL_LINES);
			self.check_lyc();
		}
		if (self.dot >= DOTS_PER_LINE) {
			self.first_line = false;
			self.dot = 0;
			if (self.r.active) self.render_end(); // never happens with sane timing
			self.line = (self.line + 1) % TOTAL_LINES;
			if (self.line == 0) self.render_frame_start();
			if (self.line < VBLANK_LINE) self.wy_check();
			self.check_lyc();
		}
		char now = self.update_mode() | self.update_stat_line();
		if (now && self.irq_dot < 0) {
			self.irq_dot = (int)i;
			self.irq_m2 = self.stat_m2;
		}
		irq |= now;
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
	if (want == 1) {
		self.frame_ready = true;
		irq |= INT_VBLANK;
	}
	return irq;
}

// The four STAT sources are OR'ed into one line; the STAT interrupt fires only
// on its rising edge. A source turning on while the line is already high
// raises nothing ("STAT blocking").
// DMG quirk: when VBlank starts at line 144 the mode-2 (OAM) source is briefly
// active too, so with STAT bit 5 set a STAT IRQ fires together with VBlank
// (Mooneye vblank_stat_intr). On a CGB the pulse comes one M-cycle earlier,
// as soon as LY reads 144 (vblank_stat_intr-C).
fn bool Ppu.vblank_oam_pulse(&self) {
	if (self.cgb_hw) return self.line == VBLANK_LINE - 1 && self.dot >= DOTS_PER_LINE - LY_EARLY_DOTS;
	return self.line == VBLANK_LINE && self.dot < LY_EARLY_DOTS;
}

// The mode 2 STAT interrupt of line 0 comes a T-cycle later than on the
// other lines (SameBoy: "except on line 0"). Whether the CPU sees that as an
// M-cycle later depends on where in the CPU's M-cycle the PPU's dots fall,
// which we don't model: it does after the LCD was switched on by the CPU
// (Mealybug tests compensate for it), not with the phase the boot ROM leaves
// (Mooneye intr_1_2_timing).
fn bool Ppu.late_oam_irq(&self) => self.lcd_on_by_cpu && self.line == 0 && !self.first_line && self.dot < 4;

fn char Ppu.update_stat_line(&self) {
	bool high = ((self.stat & STAT_LYC_IE)    != 0 && (self.stat & STAT_LYC_FLAG) != 0)
	         || ((self.stat & STAT_OAM_IE)    != 0 && ((self.mode == 2 && !self.late_oam_irq()) || self.vblank_oam_pulse()))
	         || ((self.stat & STAT_VBLANK_IE) != 0 && self.mode == 1)
	         || ((self.stat & STAT_HBLANK_IE) != 0 && self.mode == 0);

	bool rising = high && !self.stat_line;   // was low, is high now
	self.stat_line = high;                   // remember for the next call
	// Raised by the mode 2 (OAM) condition alone (see Mmu.tick).
	self.stat_m2 = rising && (self.stat & STAT_OAM_IE) != 0 && self.mode == 2
	               && !((self.stat & STAT_LYC_IE) != 0 && (self.stat & STAT_LYC_FLAG) != 0);
	return rising ? INT_STAT : 0;
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
int[5] cgb_delay = { 4, 4, 4, 5, 4 };

fn void Ppu.write_render_reg(&self, char reg, char value) {
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
	switch (reg) {
		case 0x42: self.schedule(reg, value, dmg ? 2 : cgb_delay[1]);
		case 0x43: self.schedule(reg, value, dmg ? 2 : cgb_delay[2]);
		case 0x4A: self.schedule(reg, value, 4);
		case 0x4B:
			self.schedule(reg, value, dmg ? 4 : cgb_delay[3]);
			if (dmg) self.schedule(WX_SETTLED, 0, 5);
		case 0x47:
		case 0x48:
		case 0x49:
			// DMG: for one dot the palette reads as old | new.
			if (dmg && !self.sgb_hw) self.schedule(reg, old | value, 2);
			self.schedule(reg, value, 3);
		case 0x40:
			if (dmg && !self.sgb_hw) {
				self.queue({ .reg = LCDC_DMG, .value = value, .old = old, .delay = 2 });
				self.schedule(reg, value, 3);
			} else if (!dmg && ((old ^ value) & LCDC_TILE_DATA)) {
				// CGB: changing TILE_SEL disturbs a bitplane read in that dot.
				self.schedule(reg, value, cgb_delay[0]);
				self.schedule(TILE_SEL_GLITCH_ON, 0, cgb_delay[4]);
				if ((value & LCDC_TILE_DATA) == 0) self.schedule(TILE_SEL_CLEARED, 0, cgb_delay[4]);
				self.schedule(TILE_SEL_GLITCH_OFF, 0, cgb_delay[4] + 1);
			} else if (!dmg) {
				// CGB: the object size bit lands a dot later than the rest
				// (Mealybug m3_lcdc_obj_size_change_scx).
				self.queue({ .reg = LCDC_PART, .value = value, .old = old, .keep = LCDC_OBJ_SIZE, .delay = cgb_delay[0] });
				self.schedule(reg, value, cgb_delay[0] + 1);
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

fn void Ppu.apply(&self, RegWrite w) {
	switch (w.reg) {
		case WX_SETTLED: self.wx_just_changed = false;
		case TILE_SEL_GLITCH_ON: self.r.tile_sel_glitch = true;
		case TILE_SEL_GLITCH_OFF: self.r.tile_sel_glitch = false;
		case TILE_SEL_CLEARED: self.r.glitch_data = self.r.last_read;
		case 0x42: self.scy = w.value;
		case 0x43: self.scx = w.value;
		case 0x4A:
			self.wy = w.value;
			if (self.line < VBLANK_LINE) self.wy_check();
		case 0x4B:
			self.wx = w.value;
			if (!self.cgb_hw) self.wx_just_changed = true;
		case 0x47: self.bgp = w.value;
		case 0x48: self.obp0 = w.value;
		case 0x49: self.obp1 = w.value;
		case 0x40:
			self.r_lcdc = (self.r_lcdc & LCDC_ENABLE) | (w.value & 0x7F);
			// Enabling the window re-checks WY (SameBoy: after an LCDC write).
			if (self.line < VBLANK_LINE) self.wy_check();
		case LCDC_PART:
			self.r_lcdc = (self.r_lcdc & LCDC_ENABLE) | (((w.value & ~w.keep) | (w.old & w.keep)) & 0x7F);
		case LCDC_DMG:
			// The new LCDC, except that the BG and object enable bits and a
			// window enable (not a disable) take a dot longer. Disabling objects
			// during an object fetch or at the first pixel, and disabling the BG
			// at the first pixel, are immediate. (SameBoy's DMG LCDC conflict,
			// reworked against the Mealybug DMG screenshots.)
			char keep = LCDC_OBJ_ENABLE | LCDC_BG_ENABLE;
			if ((w.value & LCDC_BG_ENABLE) == 0 && self.r.pos == 0) keep &= (char)~LCDC_BG_ENABLE;
			if ((w.old & LCDC_WIN_ENABLE) == 0) keep |= LCDC_WIN_ENABLE;
			if ((w.value & LCDC_OBJ_ENABLE) == 0 && (self.r.pos == 0 || self.during_object_fetch())) keep &= (char)~LCDC_OBJ_ENABLE;
			if ((w.old & LCDC_OBJ_ENABLE) && (w.value & LCDC_OBJ_ENABLE) == 0 && self.during_object_fetch()) self.r.obj_abort = true;
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
