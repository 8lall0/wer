module apu;

struct Wave {
	bool enabled;
	bool dac;
	char nr0, nr1, nr2, nr3, nr4;
	char[16] ram;
	int  timer;
	char pos;
	int  length;
}

fn ushort Wave.freq(&self) {
	return (ushort)(self.nr3 | ((self.nr4 & 0x07) << 8));
}

fn void Wave.step(&self, uint t) {
	self.timer -= (int)t;
	int period = (2048 - (int)self.freq()) * 2;
	if (period <= 0) period = 2;
	while (self.timer <= 0) {
		self.timer += period;
		self.pos = (self.pos + 1) & 31;
	}
}

fn void Wave.clock_length(&self) {
	if ((self.nr4 & 0x40) != 0 && self.length > 0) {
		self.length--;
		if (self.length == 0) self.enabled = false;
	}
}

fn void Wave.trigger(&self) {
	self.enabled = self.dac;
	if (self.length == 0) self.length = 256;
	self.timer = (2048 - (int)self.freq()) * 2;
	self.pos = 0;
}

fn char Wave.output(&self) {
	if (!self.enabled || !self.dac) return 0;
	char byte = self.ram[self.pos >> 1];
	char sample = (self.pos & 1) != 0 ? (byte & 0x0F) : (byte >> 4);
	switch ((self.nr2 >> 5) & 0x03) {
		case 0: return 0;
		case 1: return sample;
		case 2: return sample >> 1;
		default: return sample >> 2;
	}
}