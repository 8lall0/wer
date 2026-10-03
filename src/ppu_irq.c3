module ppu;

// The STAT interrupt and the LY=LYC flag, as Gambatte has them (video.cpp,
// video/mstat_irq.h, video/lyc_irq.cpp): rather than one line ORing the
// enabled sources, four kinds of event at fixed times of the line or frame
// (mode 0, mode 1, mode 2, LY=LYC), each checking a latched copy of STAT and
// LYC, plus the interrupts a STAT or LYC write can raise by itself.
//
// Times are Gambatte's cycle counts (`cc`): one per dot, two in CGB double
// speed. A CPU access at dot d of a line happens at Gambatte line cycle d.

const ulong NEVER = ulong::max;
const char STAT_IRQ_BITS = STAT_LYC_IE | STAT_OAM_IE | STAT_VBLANK_IE | STAT_HBLANK_IE;
const long FRAME_DOTS = (long)TOTAL_LINES * DOTS_PER_LINE;
const int M2_IRQ_LINE_CYCLE = 452;     // the mode 2 interrupt, the line before
const int M2_IRQ_LINE_CYCLE_LY0 = 454; // ... before line 0
const long M1_IRQ_FRAME_CYCLE = (long)VBLANK_LINE * DOTS_PER_LINE - 2;

struct StatIrq {
	char  stat;        // STAT's interrupt enables as written (Gambatte LCD::statReg_)
	bool  m0_armed;    // a mode 0 event is scheduled (STAT had HBLANK_IE)
	ulong m1_time;
	ulong m2_time;
	ulong lyc_time;
	ulong oneshot_time;
	// MStatIrqEvent's latches
	char  m_stat;
	char  m_lyc;
	// LycIrq's: the written values and the latched ones the event checks
	char  lyc_stat_src;
	char  lyc_stat;
	char  lyc_lyc;
}

fn ulong Ppu.spd(&self) => self.double_speed ? 2 : 1;

// When LY next changes.
fn ulong Ppu.ly_time(&self) => self.cc + (ulong)(DOTS_PER_LINE - self.dot) * self.spd();

fn long Ppu.frame_cycles(&self) => (long)self.line * DOTS_PER_LINE + self.dot;

// The next time (strictly after now) the line reaches cycle `lc`.
fn ulong Ppu.next_line_cycle(&self, int lc) {
	ulong t = self.ly_time() + (ulong)lc * self.spd();
	if (t - self.cc > (ulong)DOTS_PER_LINE * self.spd()) t -= (ulong)DOTS_PER_LINE * self.spd();
	return t;
}

// The next time the frame reaches cycle `fc`.
fn ulong Ppu.next_frame_cycle(&self, long fc) {
	ulong t = self.ly_time() + (ulong)(((long)TOTAL_LINES - 1 - self.line) * DOTS_PER_LINE + fc) * self.spd();
	if (t - self.cc > (ulong)FRAME_DOTS * self.spd()) t -= (ulong)FRAME_DOTS * self.spd();
	return t;
}

fn ulong Ppu.m1_schedule(&self) => self.next_frame_cycle(M1_IRQ_FRAME_CYCLE);

fn ulong Ppu.m2_schedule(&self, char stat) {
	if ((stat & STAT_OAM_IE) == 0) return NEVER;
	long last = (long)(VBLANK_LINE - 1) * DOTS_PER_LINE + M2_IRQ_LINE_CYCLE;
	long ly0 = (long)(TOTAL_LINES - 1) * DOTS_PER_LINE + M2_IRQ_LINE_CYCLE_LY0;
	long fc = self.frame_cycles();
	if ((fc >= last && fc < ly0) || (stat & STAT_HBLANK_IE)) return self.next_frame_cycle(ly0);
	return self.next_line_cycle(M2_IRQ_LINE_CYCLE);
}

fn ulong Ppu.lyc_schedule(&self, char stat, char lyc) {
	if ((stat & STAT_LYC_IE) == 0 || lyc >= TOTAL_LINES) return NEVER;
	long fc = lyc ? (long)lyc * DOTS_PER_LINE - 2 : (long)(TOTAL_LINES - 1) * DOTS_PER_LINE + 6;
	return self.next_frame_cycle(fc);
}

// This line's mode 0 interrupt: a dot after STAT reads mode 0. On the first
// line after LCD on (drawn 5 dots early, 6 on a CGB) it comes 2 dots later
// still than that (Gambatte enable_display/ly0_m0irq_*, frame0_m0irq_count_*).
const int[2] FIRST_LINE_M0_IRQ = { 7, 8 };
fn int Ppu.m0_irq_dot(&self) => self.m0_irq_pred + (self.first_line ? FIRST_LINE_M0_IRQ[self.cgb_hw ? 1 : 0] : 0);

fn bool Ppu.m0_pending(&self) => self.line < VBLANK_LINE && self.dot < self.m0_irq_dot();

// The scheduled mode 0 event: this line's, or (later than ly_time) the next one's.
fn ulong Ppu.m0_time(&self) {
	if (!self.si.m0_armed) return NEVER;
	if (self.m0_pending()) return self.cc + (ulong)(self.m0_irq_dot() - self.dot) * self.spd();
	return self.ly_time() + 1;
}

// The LY the LY=LYC comparator sees, and how long before it moves on.
struct LyCmp {
	int ly;
	long time_to_next;
}

fn LyCmp Ppu.lyc_cmp_ly(&self) {
	int ly = self.line;
	long t = (long)(self.ly_time() - self.cc);
	long line_time = (long)DOTS_PER_LINE * (long)self.spd();
	if (ly == TOTAL_LINES - 1) {
		t -= line_time - (self.double_speed ? 12 : 6);
		if (t <= 0) {
			ly = 0;
			t += line_time;
		}
	} else {
		t -= self.double_speed ? 4 : 2;
		if (t <= 0) {
			ly++;
			t += line_time;
		}
	}
	return { ly, t };
}

fn bool Ppu.lyc_flag(&self) {
	if ((self.lcdc & LCDC_ENABLE) == 0) return (self.stat & STAT_LYC_FLAG) != 0;
	LyCmp c = self.lyc_cmp_ly();
	return c.ly == (int)self.lyc && c.time_to_next > 2;
}

// --- LycIrq ---

fn void Ppu.lycirq_change(&self, char stat, char lyc) {
	StatIrq* s = &self.si;
	ulong src_time = self.lyc_schedule(stat, lyc);
	s.lyc_stat_src = stat;
	ulong t = s.lyc_time < src_time ? s.lyc_time : src_time;
	s.lyc_time = t;
	ulong ahead = t - self.cc;
	if (self.cgb_hw) {
		if (ahead > (self.double_speed ? 10UL : 6UL) || (src_time != t && ahead > 2)) s.lyc_lyc = lyc;
		if (ahead > 2) s.lyc_stat = stat;
	} else {
		if (ahead > 4 || src_time != t) s.lyc_lyc = lyc;
		s.lyc_stat = stat;
	}
}

fn bool lyc_irq_blocked(char ly, char stat) {
	return ly <= VBLANK_LINE && ly > 0 ? (stat & STAT_OAM_IE) != 0 : (stat & STAT_VBLANK_IE) != 0;
}

fn bool Ppu.lycirq_event(&self) {
	StatIrq* s = &self.si;
	bool flag = false;
	if ((s.lyc_stat | s.lyc_stat_src) & STAT_LYC_IE) {
		int cmp = self.line == TOTAL_LINES - 1 ? 0 : self.line + 1;
		flag = (int)s.lyc_lyc == cmp && !lyc_irq_blocked(s.lyc_lyc, s.lyc_stat);
	}
	s.lyc_lyc = self.lyc;
	s.lyc_stat = s.lyc_stat_src;
	s.lyc_time = self.lyc_schedule(s.lyc_stat, s.lyc_lyc);
	return flag;
}

// --- the events, run after each dot (Gambatte's order for equal times) ---

fn char Ppu.irq_events(&self) {
	StatIrq* s = &self.si;
	// Nothing due (the common case): leave at once.
	if (!s.m0_armed && self.cc < s.m1_time && self.cc < s.m2_time && self.cc < s.lyc_time && self.cc < s.oneshot_time) return 0;
	char irq = 0;
	if (s.oneshot_time <= self.cc) {
		irq |= INT_STAT;
		s.oneshot_time = NEVER;
	}
	if (s.m1_time <= self.cc) {
		if ((s.stat & STAT_VBLANK_IE) && !(s.m_stat & (STAT_OAM_IE | STAT_HBLANK_IE))) irq |= INT_STAT;
		s.m_stat = s.stat;
		s.m1_time += (ulong)FRAME_DOTS * self.spd();
	}
	if (s.lyc_time <= self.cc) {
		if (self.lycirq_event()) irq |= INT_STAT;
	}
	if (s.m2_time <= self.cc) {
		int ly = self.line;
		if (self.ly_time() - s.m2_time < 16) ly = ly == TOTAL_LINES - 1 ? 0 : ly + 1;
		bool by_m1 = ly == 0 && (s.m_stat & STAT_VBLANK_IE);
		bool by_lyc = (s.m_stat & STAT_LYC_IE) && (ly == 0 ? 0 : ly - 1) == (int)s.m_lyc;
		if (!by_m1 && !by_lyc) irq |= INT_STAT;
		s.m_lyc = self.lyc;
		s.m_stat = s.stat;
		long next = FRAME_DOTS;
		if ((s.stat & STAT_HBLANK_IE) == 0) {
			next = DOTS_PER_LINE;
			if (ly == 0) {
				next -= M2_IRQ_LINE_CYCLE_LY0 - M2_IRQ_LINE_CYCLE;
			} else if (ly == VBLANK_LINE) {
				next += (long)DOTS_PER_LINE * (TOTAL_LINES - VBLANK_LINE - 1) + M2_IRQ_LINE_CYCLE_LY0 - M2_IRQ_LINE_CYCLE;
			}
		}
		s.m2_time += (ulong)next * self.spd();
	}
	if (s.m0_armed && self.line < VBLANK_LINE && self.dot > MODE3_START_DOT && self.dot == self.m0_irq_dot()) {
		bool flag = ((s.stat | s.m_stat) & STAT_HBLANK_IE) && (!(s.m_stat & STAT_LYC_IE) || self.line != (int)s.m_lyc);
		if (flag) irq |= INT_STAT;
		s.m_lyc = self.lyc;
		s.m_stat = s.stat;
		s.m0_armed = (s.stat & STAT_HBLANK_IE) != 0;
	}
	return irq;
}

// LCD switched on, or the speed changed: schedule everything afresh.
fn void Ppu.irq_reschedule(&self, bool lcd_on) {
	StatIrq* s = &self.si;
	if (lcd_on) {
		s.lyc_lyc = self.lyc;
		s.lyc_stat = s.lyc_stat_src;
		s.m_lyc = self.lyc;
		s.m0_armed = (s.stat & STAT_HBLANK_IE) != 0;
	}
	ulong a = self.lyc_schedule(s.lyc_stat, s.lyc_lyc);
	ulong b = self.lyc_schedule(s.lyc_stat_src, self.lyc);
	s.lyc_time = a < b ? a : b;
	s.m1_time = self.m1_schedule();
	s.m2_time = self.m2_schedule(s.stat);
	s.oneshot_time = NEVER;
}

fn void Ppu.irq_lcd_off(&self) {
	StatIrq* s = &self.si;
	s.m1_time = s.m2_time = s.lyc_time = s.oneshot_time = NEVER;
	s.m0_armed = false;
}

// --- STAT and LYC writes ---

fn bool Ppu.stat_write_irq_dmg(&self, char old) {
	LyCmp c = self.lyc_cmp_ly();
	bool lyc_match = c.ly == (int)self.lyc;
	if (self.line < VBLANK_LINE) {
		// Is this line's mode 0 interrupt still to come (or none at all)?
		bool m0_known = self.si.m0_armed || (self.ly_time() - self.cc) < (ulong)(DOTS_PER_LINE - 80 - 160);
		if (!m0_known || self.m0_pending()) return lyc_match && !(old & STAT_LYC_IE);
		return !(old & STAT_HBLANK_IE) && !(lyc_match && (old & STAT_LYC_IE));
	}
	return !(old & STAT_VBLANK_IE) && !(lyc_match && (old & STAT_LYC_IE));
}

fn bool Ppu.stat_write_irq_cgb(&self, char old, char data) {
	if (!(data & ~old & STAT_IRQ_BITS)) return false;
	int ly = self.line;
	long ttn = (long)(self.ly_time() - self.cc);
	bool ds = self.double_speed;
	LyCmp c = self.lyc_cmp_ly();
	bool lycperiod = c.ly == (int)self.lyc && c.time_to_next > 2;
	if (lycperiod && (old & STAT_LYC_IE)) return false;

	// statChangeTriggersM0LycOrM1StatIrqCgb
	bool m0lyc_m1;
	int m1_irq_lc_inv = DOTS_PER_LINE - (int)(M1_IRQ_FRAME_CYCLE % DOTS_PER_LINE);
	if (ly < VBLANK_LINE - 1 || (ly == VBLANK_LINE - 1 && ttn > (long)(m1_irq_lc_inv * (ds ? 2 : 1)))) {
		bool m0_this_line = self.si.m0_armed && self.m0_pending();
		if (m0_this_line == false && self.si.m0_armed == false) {
			// no event scheduled: Gambatte compares disabled_time, never earlier
		}
		if ((self.si.m0_armed && self.m0_pending()) || ttn <= (long)(ly < VBLANK_LINE - 1 ? 4 + (ds ? 4 : 0) : 4 + (ds ? 2 : 0))) {
			m0lyc_m1 = lycperiod && (data & STAT_LYC_IE);
		} else if (old & STAT_HBLANK_IE) {
			m0lyc_m1 = false;
		} else {
			m0lyc_m1 = (data & STAT_HBLANK_IE) || (lycperiod && (data & STAT_LYC_IE));
		}
	} else if ((old & STAT_VBLANK_IE) && (ly < TOTAL_LINES - 1 || ttn > (long)(ds ? 6 : 3))) {
		m0lyc_m1 = false;
	} else {
		m0lyc_m1 = ((data & STAT_VBLANK_IE) && (ly < TOTAL_LINES - 1 || ttn > (long)(ds ? 6 : 4)))
			|| (lycperiod && (data & STAT_LYC_IE));
	}
	if (m0lyc_m1) return true;

	// statChangeTriggersM2IrqCgb
	if ((old & STAT_OAM_IE) || (data & (STAT_OAM_IE | STAT_HBLANK_IE)) != STAT_OAM_IE) return false;
	long m2_window = (long)(DOTS_PER_LINE - M2_IRQ_LINE_CYCLE) * (ds ? 2 : 1);
	if (ly < VBLANK_LINE - 1) return ttn <= m2_window && ttn > 2;
	if (ly == VBLANK_LINE - 1) return ttn <= m2_window && ttn > (long)(4 + (ds ? 2 : 0));
	if (ly == TOTAL_LINES - 1) return ttn <= (long)(DOTS_PER_LINE - M2_IRQ_LINE_CYCLE_LY0) * (ds ? 2 : 1) && ttn > 2;
	return false;
}

fn char Ppu.write_stat(&self, char value) {
	StatIrq* s = &self.si;
	char data = value & STAT_IRQ_BITS;
	char old = s.stat;
	s.stat = data;
	self.stat = (self.stat & 0x87) | data;
	self.lycirq_change(data, self.lyc);
	char irq = 0;
	if ((self.lcdc & LCDC_ENABLE) == 0) {
		// LCD off: the frozen LY=LYC flag raises it when LYC's enable comes on
		// (on a DMG with any write).
		if ((self.stat & STAT_LYC_FLAG) && !(old & STAT_LYC_IE) && (!self.cgb_hw || (data & STAT_LYC_IE))) irq = INT_STAT;
	} else {
		if (data & STAT_HBLANK_IE) s.m0_armed = true;
		s.m2_time = self.m2_schedule(data);
		bool fire = self.cgb_hw ? self.stat_write_irq_cgb(old, data) : self.stat_write_irq_dmg(old);
		if (fire) irq = INT_STAT;
	}
	// MStatIrqEvent::statRegChange
	ulong m = self.m0_time();
	if (s.m1_time < m) m = s.m1_time;
	if (s.m2_time < m) m = s.m2_time;
	if (self.cc + (self.cgb_hw ? 2UL : 0UL) < m) s.m_stat = data;
	return irq;
}

fn bool Ppu.lyc_write_blocked(&self, char data) {
	StatIrq* s = &self.si;
	if (self.line < VBLANK_LINE) {
		// this line's mode 0 interrupt is already past and set for the next one
		return (s.stat & STAT_HBLANK_IE) && s.m0_armed && !self.m0_pending() && (int)data == self.line;
	}
	long ttn = (long)(self.ly_time() - self.cc);
	return (s.stat & STAT_VBLANK_IE)
		&& !(self.line == TOTAL_LINES - 1 && ttn <= (long)(2 + (self.double_speed ? 2 : 0) + (self.cgb_hw ? 2 : 0)));
}

fn bool Ppu.lyc_write_irq(&self, char old, char data) {
	if (!(self.si.stat & STAT_LYC_IE) || data >= TOTAL_LINES || self.lyc_write_blocked(data)) return false;
	LyCmp c = self.lyc_cmp_ly();
	if (c.time_to_next <= (long)(4 + (self.double_speed ? 4 : 0) + (self.cgb_hw ? 2 : 0))) {
		if ((int)old == c.ly && c.time_to_next > (self.cgb_hw ? 2 : 0)) return false;
		c.ly = c.ly == TOTAL_LINES - 1 ? 0 : c.ly + 1;
	}
	return (int)data == c.ly;
}

fn char Ppu.write_lyc(&self, char value) {
	StatIrq* s = &self.si;
	char old = self.lyc;
	if (value == old) return 0;
	self.lycirq_change(s.stat, value);
	// MStatIrqEvent::lycRegChange
	ulong m = self.m0_time();
	if (s.m2_time < m) m = s.m2_time;
	if (self.cc + (ulong)((self.cgb_hw ? 5 : 0) + 1 - (self.double_speed ? 1 : 0)) < m) s.m_lyc = value;
	self.lyc = value;
	if ((self.lcdc & LCDC_ENABLE) == 0) return 0;
	if (self.lyc_write_irq(old, value)) {
		if (self.cgb_hw && !self.double_speed) {
			s.oneshot_time = self.cc + 5;
		} else {
			return INT_STAT;
		}
	}
	return 0;
}

// LY as the CPU reads it (Gambatte LCD::getLyReg): the next line's number
// from 6 cycles before it starts (10 in double speed), at exactly that cycle
// the old and new ANDed (lcd_offset/*_ly_count_*).
fn char Ppu.ly_reg(&self) {
	if ((self.lcdc & LCDC_ENABLE) == 0) return self.ly;
	// Line 153 reads 0 at once (in double speed from its second cycle).
	// A CGB-E reads 153 for its first dot in normal speed too (AGE ly-cgbE).
	if (self.line == TOTAL_LINES - 1) {
		return (self.double_speed || self.cgb_e) && self.dot == 0 ? (char)(TOTAL_LINES - 1) : 0;
	}
	long ttn = (long)(DOTS_PER_LINE - self.dot) * (long)self.spd();
	long edge = self.double_speed ? 10 : 6;
	// A CGB-E's LY & (LY + 1) glitch comes a dot later in normal speed (AGE
	// lcd-align-ly-cgbE).
	if (self.cgb_e && !self.double_speed) edge = 5;
	char ly = (char)self.line;
	// A CGB-C in normal speed glitches for 2 dots, a dot longer than in
	// Gambatte (AGE lcd-align-ly-cgbBC).
	bool c_wide = self.cgb_hw && !self.cgb_e && !self.double_speed && ttn == 5;
	if (ttn == edge || c_wide) return ly & (ly + 1);
	if (ttn < edge) return ly + 1;
	return ly;
}

// --- CPU access to VRAM, OAM and CGB palettes (Gambatte LCD::vramReadable &c) ---

// The first 81 cycles after the LCD is switched on lock nothing.
fn bool Ppu.inactive_after_enable(&self, int off) => self.cc + (ulong)off < self.lcd_on_cc + 80 * self.spd() + 1;

// The dot STAT starts reading mode 0 on this line.
fn int Ppu.m0_stat_dot(&self) => self.pipe_end_dot - self.mode3_tail();

fn bool Ppu.vram_read_locked(&self) {
	if ((self.lcdc & LCDC_ENABLE) == 0 || self.line >= VBLANK_LINE) return false;
	int ds = self.double_speed ? 1 : 0;
	int cgb = self.cgb_hw ? 1 : 0;
	if (self.inactive_after_enable(1 - cgb + ds)) return false;
	return self.dot + ds >= 76 + 3 * cgb && self.dot < self.m0_stat_dot();
}

fn bool Ppu.vram_write_locked(&self) {
	if ((self.lcdc & LCDC_ENABLE) == 0 || self.line >= VBLANK_LINE) return false;
	int ds = self.double_speed ? 1 : 0;
	int cgb = self.cgb_hw ? 1 : 0;
	if (self.inactive_after_enable(1 - cgb + ds)) return false;
	return self.dot + ds >= 79 && self.dot < self.m0_stat_dot();
}

fn bool Ppu.palette_locked(&self) {
	if ((self.lcdc & LCDC_ENABLE) == 0 || self.line >= VBLANK_LINE) return false;
	int ds = self.double_speed ? 1 : 0;
	if (self.inactive_after_enable(0)) return false;
	return self.dot + ds >= 80 && self.dot < self.m0_stat_dot() + (self.double_speed ? 2 : 4);
}

fn bool Ppu.oam_read_locked(&self) {
	int ds = self.double_speed ? 1 : 0;
	if ((self.lcdc & LCDC_ENABLE) == 0 || self.inactive_after_enable(4)) return false;
	if (self.dot + 4 - ds >= DOTS_PER_LINE) return !(self.line >= VBLANK_LINE - 1 && self.line < TOTAL_LINES - 1);
	return !(self.line >= VBLANK_LINE || self.dot >= self.m0_stat_dot());
}

fn bool Ppu.oam_write_locked(&self) {
	int ds = self.double_speed ? 1 : 0;
	int cgb = self.cgb_hw ? 1 : 0;
	if ((self.lcdc & LCDC_ENABLE) == 0 || self.inactive_after_enable(4 + ds)) return false;
	if (self.dot + 3 + cgb >= DOTS_PER_LINE) return !(self.line >= VBLANK_LINE - 1 && self.line < TOTAL_LINES - 1);
	return !(self.line >= VBLANK_LINE || self.dot >= self.m0_stat_dot() || (self.dot == 76 && !self.cgb_hw));
}
