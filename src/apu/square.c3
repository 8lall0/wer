module apu;

struct Square {
	bool has_sweep; // CH1 only
	bool enabled;
	bool dac;

	char nr0, nr1, nr2, nr3, nr4;

	int  timer;
	char duty_pos;
	Envelope env;
	int  length;

	// sweep
	bool sweep_on;
	int  sweep_shadow;
	char sweep_timer;
	bool sweep_neg_used;
}

fn ushort Square.freq(&self) {
	return (ushort)(self.nr3 | ((self.nr4 & 0x07) << 8));
}

fn void Square.step(&self, uint t) {
	self.timer -= (int)t;
	int period = (2048 - (int)self.freq()) * 4;
	if (period <= 0) period = 4;
	while (self.timer <= 0) {
		self.timer += period;
		self.duty_pos = (self.duty_pos + 1) & 7;
	}
}

fn void Square.clock_length(&self) {
	if ((self.nr4 & 0x40) != 0 && self.length > 0) {
		self.length--;
		if (self.length == 0) self.enabled = false;
	}
}

fn int Square.sweep_calc(&self) {
	int shift = self.nr0 & 0x07;
	int delta = self.sweep_shadow >> shift;
	if ((self.nr0 & 0x08) != 0) {
		self.sweep_neg_used = true;
		return self.sweep_shadow - delta;
	}
	return self.sweep_shadow + delta;
}

fn void Square.clock_sweep(&self) {
	if (!self.has_sweep) return;
	if (self.sweep_timer > 0) self.sweep_timer--;
	if (self.sweep_timer != 0) return;

	char pace = (self.nr0 >> 4) & 0x07;
	self.sweep_timer = pace != 0 ? pace : 8;
	if (!self.sweep_on || pace == 0) return;

	int next = self.sweep_calc();
	if (next > 2047) {
		self.enabled = false;
		return;
	}
	if ((self.nr0 & 0x07) != 0) {
		self.sweep_shadow = next;
		self.nr3 = (char)(next & 0xFF);
		self.nr4 = (char)((self.nr4 & ~0x07) | ((next >> 8) & 0x07));
		if (self.sweep_calc() > 2047) self.enabled = false;
	}
}

fn void Square.trigger(&self) {
	self.enabled = self.dac;
	if (self.length == 0) self.length = 64;
	self.timer = (2048 - (int)self.freq()) * 4;
	self.env.trigger(self.nr2);
	self.duty_pos = 0;

	if (self.has_sweep) {
		self.sweep_shadow = (int)self.freq();
		char pace = (self.nr0 >> 4) & 0x07;
		self.sweep_timer = pace != 0 ? pace : 8;
		self.sweep_on = pace != 0 || (self.nr0 & 0x07) != 0;
		self.sweep_neg_used = false;
		if ((self.nr0 & 0x07) != 0 && self.sweep_calc() > 2047) self.enabled = false;
	}
}

fn char Square.output(&self) {
	if (!self.enabled || !self.dac) return 0;
	char bit = (DUTY[self.nr1 >> 6] >> self.duty_pos) & 1;
	return bit != 0 ? self.env.volume : 0;
}