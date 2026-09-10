module apu;

struct Noise {
	bool enabled;
	bool dac;
	char nr1, nr2, nr3, nr4;
	int  timer;
	ushort lfsr;
	Envelope env;
	int  length;
}

fn void Noise.step(&self, uint t) {
	int divisor = NOISE_DIVISOR[self.nr3 & 0x07];
	int period = divisor << ((self.nr3 >> 4) & 0x0F);
	if (period <= 0) period = 8;

	self.timer -= (int)t;
	while (self.timer <= 0) {
		self.timer += period;
		ushort x = (self.lfsr ^ (self.lfsr >> 1)) & 1;
		self.lfsr = (self.lfsr >> 1) | (x << 14);
		if ((self.nr3 & 0x08) != 0) {
			self.lfsr = (self.lfsr & (ushort)~0x40) | (x << 6);
		}
	}
}

fn void Noise.clock_length(&self) {
	if ((self.nr4 & 0x40) != 0 && self.length > 0) {
		self.length--;
		if (self.length == 0) self.enabled = false;
	}
}

fn void Noise.trigger(&self) {
	self.enabled = self.dac;
	if (self.length == 0) self.length = 64;
	self.env.trigger(self.nr2);
	self.lfsr = 0x7FFF;
	int divisor = NOISE_DIVISOR[self.nr3 & 0x07];
	self.timer = divisor << ((self.nr3 >> 4) & 0x0F);
}

fn char Noise.output(&self) {
	if (!self.enabled || !self.dac) return 0;
	return (self.lfsr & 1) == 0 ? self.env.volume : 0;
}