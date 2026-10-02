module timer;

// DIV, and TIMA/TMA/TAC as Gambatte has them (tima.cpp): TIMA counts in steps
// of its period from the last DIV-aligned update, overflowing loads TMA 3
// cycles later (reads 0 meanwhile) and raises the interrupt then; writes to
// TAC and DIV count the falling edge they may cause. Times are CPU cycles
// (`cc`, 4 per M-cycle in either speed).

// log2 of TIMA's period, indexed by (TAC & 3).
const uint[4] TIMA_CLOCK = { 10, 4, 6, 8 };

// Bit 12 of `div` clocks the 512 Hz APU frame sequencer; in CGB double
// speed DIV counts twice as fast, and bit 13 keeps it at 512 Hz.
const uint APU_BIT = 12;

const ulong NEVER = ulong::max;

struct Timer {
	ushort div;      // the DIV counter (DIV is its high byte)
	char   tima;     // as of last_update (Timer.read_tima brings it up to date)
	char   tma;
	char   tac;

	ulong cc;          // CPU cycles so far
	ulong last_update; // when TIMA last counted
	ulong tmatime;     // when an overflow loads TMA (NEVER: none pending)
	ulong next_irq;    // when TIMA next raises its interrupt (NEVER: off)
	bool  irq_now;     // a TIMA/TMA/TAC/DIV write raised it at once
	bool  init;        // tmatime/next_irq set up
	bool pending_apu_write;
	bool double_speed;
}

fn uint Timer.apu_bit(&self) => self.double_speed ? APU_BIT + 1 : APU_BIT;

struct TickResult {
	bool timer_irq;
	uint irq_before_end; // CPU cycles from the interrupt to the end of the tick
	uint apu_steps;      // falling edges of the APU bit (frame sequencer steps)
	uint apu_rises;      // rising edges (the APU's secondary event)
	bool apu_div_write;  // a DIV write made the APU bit fall
}

fn char Timer.div_reg(&self) {
	return (char)(self.div >> 8);
}

fn void Timer.setup(&self) {
	if (self.init) return;
	self.init = true;
	self.tmatime = NEVER;
	self.next_irq = NEVER;
}

fn uint Timer.clock(&self) => TIMA_CLOCK[self.tac & 3];
// Cycles since DIV was last reset (Gambatte cc - divLastUpdate).
fn ulong Timer.since_div(&self) => (ulong)self.div;

fn void Timer.update_tima(&self, ulong cc) {
	uint clk = self.clock();
	ulong ticks = (cc - self.last_update) >> clk;
	self.last_update += ticks << clk;
	if (self.tmatime != NEVER && cc >= self.tmatime) {
		if (cc >= self.tmatime + 4) self.tmatime = NEVER;
		self.tima = self.tma;
	}
	ulong tmp = (ulong)self.tima + ticks;
	if (tmp > 0x100) {
		ulong diff = 0x100 - (ulong)self.tma;
		tmp -= diff * (tmp / diff - 0x100 / diff);
		if (tmp > 0x100) tmp -= diff;
	}
	if (tmp == 0x100) {
		tmp = 0;
		self.tmatime = self.last_update + 3;
		if (cc >= self.tmatime) {
			if (cc >= self.tmatime + 4) self.tmatime = NEVER;
			tmp = self.tma;
		}
	}
	self.tima = (char)tmp;
}

// Interrupts due by `cc` (Gambatte Tima::updateIrq): true if any.
fn bool Timer.update_irq(&self, ulong cc) {
	bool fired = false;
	while (self.next_irq != NEVER && cc >= self.next_irq) {
		fired = true;
		self.next_irq += (ulong)(0x100 - (uint)self.tma) << self.clock();
	}
	return fired;
}

fn char Timer.read_tima(&self) {
	self.setup();
	if (self.tac & 0x04) self.update_tima(self.cc);
	return self.tima;
}

fn void Timer.write_tima(&self, char value) {
	self.setup();
	if (self.tac & 0x04) {
		if (self.update_irq(self.cc)) self.irq_now = true;
		self.update_tima(self.cc);
		if (self.tmatime != NEVER && self.tmatime - self.cc < 4) self.tmatime = NEVER;
		self.next_irq = self.last_update + ((ulong)(0x100 - (uint)value) << self.clock()) + 3;
	}
	self.tima = value;
}

fn void Timer.write_tma(&self, char value) {
	self.setup();
	if (self.tac & 0x04) {
		if (self.update_irq(self.cc)) self.irq_now = true;
		self.update_tima(self.cc);
	}
	self.tma = value;
}

fn void Timer.write_tac(&self, char value) {
	self.setup();
	char data = value & 0x07;
	if (self.tac != data) {
		ulong nirq = self.next_irq;
		if (self.tac & 0x04) {
			// Switching off (or to another clock) counts the falling edge it causes.
			ulong inc = ~((ulong)(data >> 2) & (self.since_div() >> (TIMA_CLOCK[data & 3] - 1))) & 1;
			ulong back = (inc << (self.clock() - 1)) + 3;
			self.last_update -= back;
			if (nirq != NEVER) nirq -= back;
			if (nirq != NEVER && self.cc >= nirq) self.irq_now = true;
			self.update_tima(self.cc);
			self.tmatime = NEVER;
			nirq = NEVER;
		}
		if (data & 0x04) {
			uint clk = TIMA_CLOCK[data & 3];
			self.last_update = self.cc - (self.since_div() & ((1UL << clk) - 1));
			nirq = self.last_update + ((ulong)(0x100 - (uint)self.tima) << clk) + 3;
		}
		self.next_irq = nirq;
	}
	self.tac = data;
}

fn void Timer.write_div(&self) {
	self.setup();
	if (self.tac & 0x04) {
		ulong nirq = self.next_irq;
		ulong back = (1UL << (self.clock() - 1)) + 3;
		self.last_update -= back;
		if (nirq != NEVER) nirq -= back;
		if (nirq != NEVER && self.cc >= nirq) self.irq_now = true;
		self.update_tima(self.cc);
		self.last_update = self.cc;
		self.next_irq = self.last_update + ((ulong)(0x100 - (uint)self.tima) << self.clock()) + 3;
	}
	if (((self.div >> self.apu_bit()) & 1) != 0) self.pending_apu_write = true;
	self.div = 0;
}

// A CGB speed switch: a fast-clocked timer gets 4 more cycles (Gambatte
// Tima::speedChange).
fn void Timer.speed_change(&self) {
	self.setup();
	if ((self.tac & 0x07) >= 0x05) {
		self.last_update -= 4;
		if (self.next_irq != NEVER) self.next_irq -= 4;
	}
}

fn TickResult Timer.tick(&self, uint tcycles) {
	self.setup();
	TickResult res;
	res.apu_div_write = self.pending_apu_write;
	self.pending_apu_write = false;
	if (self.irq_now) {
		self.irq_now = false;
		res.timer_irq = true;
		res.irq_before_end = tcycles;
	}

	uint before = self.div;
	uint after = before + tcycles;
	self.div = (ushort)after;
	ulong end = self.cc + tcycles;
	if (!res.timer_irq && self.next_irq != NEVER && self.next_irq <= end) {
		res.irq_before_end = (uint)(end - self.next_irq);
	}
	if (self.update_irq(end)) res.timer_irq = true;
	self.cc = end;

	uint apu_shift = self.apu_bit() + 1;
	res.apu_steps += (after >> apu_shift) - (before >> apu_shift);
	uint half = 1u << self.apu_bit();
	res.apu_rises += ((after + half) >> apu_shift) - ((before + half) >> apu_shift);
	return res;
}
