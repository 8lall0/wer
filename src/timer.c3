module timer;

// Which `div` bit gates TIMA, indexed by (TAC & 3).
const uint[4] TIMA_BIT = { 9, 3, 5, 7 };

// Bit 12 of `div` clocks the 512 Hz APU frame sequencer.
const uint APU_BIT = 12;

struct Timer {
	ushort div;
	char   tima;
	char   tma;
	char   tac;

	int  reload_delay;
	uint pending_tima;
	uint pending_apu;

	bool reloaded;
	ushort last_div; // DIV at the start of the previous tick (see write_tac)
}

struct TickResult {
	bool timer_irq;
	uint apu_steps;
}

fn char Timer.div_reg(&self) {
	return (char)(self.div >> 8);
}

fn bool Timer.tima_input(&self) {
	return (self.tac & 0x04) != 0 && ((self.div >> TIMA_BIT[self.tac & 3]) & 1) != 0;
}

fn void Timer.write_div(&self) {
	if (self.tima_input()) self.pending_tima++;
	if (((self.div >> APU_BIT) & 1) != 0) self.pending_apu++;
	self.div = 0;
	self.last_div = 0;
}

fn void Timer.write_tac(&self, char value) {
	bool before = self.tima_input();
	bool was_on = (self.tac & 0x04) != 0;
	self.tac = value & 0x07;
	if (before && !self.tima_input()) self.pending_tima++;

	// Enabling the timer in the M-cycle right after the selected DIV bit fell
	// still counts that fall: the TAC write takes effect earlier in the M-cycle
	// than our access-then-tick order applies it (Mooneye timer/rapid_toggle).
	uint bit = TIMA_BIT[self.tac & 3];
	bool fell = ((self.last_div >> bit) & 1) != 0 && ((self.div >> bit) & 1) == 0;
	if (!was_on && (self.tac & 0x04) != 0 && fell) self.pending_tima++;
}

fn void Timer.write_tima(&self, char value) {
	if (self.reload_delay > 0) self.reload_delay = 0;
	if (self.reloaded) {
		return;
	}
	self.tima = value;
}

fn bool Timer.step_tima(&self) {
	if (self.tima == 0xFF) {
		self.tima = 0;
		return true;
	}
	self.tima++;
	return false;
}

fn TickResult Timer.tick(&self, uint tcycles) {
	TickResult res;

	self.reloaded = false;

	if (self.reload_delay > 0) {
		self.reload_delay -= (int)tcycles;
		if (self.reload_delay <= 0) {
			self.reload_delay = 0;
			self.tima = self.tma;
			self.reloaded = true;
			res.timer_irq = true;
		}
	}

	bool overflowed;
	for (uint i = 0; i < self.pending_tima; i++) {
		if (self.step_tima()) overflowed = true;
	}
	res.apu_steps += self.pending_apu;
	self.pending_tima = 0;
	self.pending_apu = 0;

	uint before = self.div;
	self.last_div = self.div;
	uint after = before + tcycles;
	self.div = (ushort)after;

	uint apu_shift = APU_BIT + 1;
	res.apu_steps += (after >> apu_shift) - (before >> apu_shift);

	if ((self.tac & 0x04) != 0) {
		uint shift = TIMA_BIT[self.tac & 3] + 1;
		uint edges = (after >> shift) - (before >> shift);
		for (uint i = 0; i < edges; i++) {
			if (self.step_tima()) overflowed = true;
		}
		if (overflowed) {
			uint since = after & ((1u << shift) - 1);
			if ((int)since >= 4) {
				self.tima = self.tma;
				self.reloaded = true;
				res.timer_irq = true;
			} else {
				self.reload_delay = 4 - (int)since;
			}
		}
	} else if (overflowed) {
		self.reload_delay = 4;
	}

	return res;
}

fn void Timer.write_tma(&self, char value) {
	self.tma = value;
	if (self.reloaded) {
		self.tima = value;
	}
}
