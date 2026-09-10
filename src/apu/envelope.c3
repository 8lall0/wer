module apu;

struct Envelope {
	char volume;
	char period;
	char timer;
	bool add;
}

fn void Envelope.trigger(&self, char nrx2) {
	self.volume = nrx2 >> 4;
	self.add = (nrx2 & 0x08) != 0;
	self.period = nrx2 & 0x07;
	self.timer = self.period;
}

fn void Envelope.clock(&self) {
	if (self.period == 0) return;
	if (self.timer > 0) self.timer--;
	if (self.timer == 0) {
		self.timer = self.period;
		if (self.add && self.volume < 15) self.volume++;
		if (!self.add && self.volume > 0) self.volume--;
	}
}