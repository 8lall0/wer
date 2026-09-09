module timer;

// T-cycles between TIMA increments, indexed by (TAC & 3).
const ushort[4] TIMA_PERIOD = { 1024, 16, 64, 256 };

struct Timer {
	ushort div_counter;
	ushort tima_ticks;   // T-cycles accumulated toward the next TIMA step
	char tima;
	char tma;
	char tac;
	bool overflow_pending;
}

fn char Timer.div(&self) {
	return (char)(self.div_counter >> 8);
}

fn void Timer.write_div(&self) {
	self.div_counter = 0;
	self.tima_ticks = 0;
}

fn void Timer.write_tac(&self, char value) {
	self.tac = value & 0x07;
}

fn bool Timer.enabled(&self) {
	return (self.tac & 0x04) != 0;
}

// Advance the timer by `tcycles` T-cycles. Returns true if a Timer interrupt
// should be requested during this span.
fn bool Timer.tick(&self, uint tcycles) {
	bool irq = false;

	for (uint i = 0; i < tcycles; i++) {
		self.div_counter++;

		if (self.overflow_pending) {
			self.tima = self.tma;
			self.overflow_pending = false;
			irq = true;
		}

		if (!self.enabled()) continue;

		self.tima_ticks++;
		ushort period = TIMA_PERIOD[self.tac & 3];
		if (self.tima_ticks >= period) {
			self.tima_ticks -= period;
			if (self.tima == 0xFF) {
				self.tima = 0;
				self.overflow_pending = true;
			} else {
				self.tima++;
			}
		}
	}

	return irq;
}
