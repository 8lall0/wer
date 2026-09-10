module apu;

// Functional, not cycle-exact: no length-counter trigger quirks, no wave-RAM
// corruption bug, no DAC-disable pop. Good enough for music and SFX.

const int  SAMPLE_RATE = 48000;
const ulong CPU_HZ     = 4194304;

const char[4] DUTY = { 0b00000001, 0b00000011, 0b00001111, 0b11111100 };

const int[8] NOISE_DIVISOR = { 8, 16, 32, 48, 64, 80, 96, 112 };


struct Apu {
	bool power;

	Square ch1;
	Square ch2;
	Wave   ch3;
	Noise  ch4;

	char nr50; // master volume + VIN
	char nr51; // panning

	char  fs_step;
	ulong sample_acc;

	// one-pole DC-blocking high-pass, per channel of the stereo mix
	float hp_l;
	float hp_r;

	// caller-provided ring buffer of interleaved s16 L,R samples
	short[] ring;
	usz     cap;
	usz     w;
	usz     r;
	usz     count;
}

fn void Apu.init(&self) {
	self.ch1.has_sweep = true;
	self.cap = (usz)self.ring.len;
}

fn void Apu.set_ring(&self, short[] buf) {
	self.ring = buf;
	self.cap = (usz)buf.len;
}

fn void Apu.frame_step(&self) {
	switch (self.fs_step) {
		case 0:
		case 4:
			self.clock_length();
		case 2:
		case 6:
			self.clock_length();
			self.ch1.clock_sweep();
		case 7:
			self.ch1.env.clock();
			self.ch2.env.clock();
			self.ch4.env.clock();
	}
	self.fs_step = (self.fs_step + 1) & 7;
}

fn void Apu.clock_length(&self) {
	self.ch1.clock_length();
	self.ch2.clock_length();
	self.ch3.clock_length();
	self.ch4.clock_length();
}

fn void Apu.tick(&self, uint t, uint frame_steps) {
	if (!self.power) {
		// Still advance the sample clock so the stream doesn't starve.
		self.push_silence(t);
		return;
	}

	self.ch1.step(t);
	self.ch2.step(t);
	self.ch3.step(t);
	self.ch4.step(t);

	for (uint i = 0; i < frame_steps; i++) self.frame_step();

	self.sample_acc += (ulong)t * SAMPLE_RATE;
	while (self.sample_acc >= CPU_HZ) {
		self.sample_acc -= CPU_HZ;
		self.emit_sample();
	}
}

fn void Apu.push_silence(&self, uint t) {
	self.sample_acc += (ulong)t * SAMPLE_RATE;
	while (self.sample_acc >= CPU_HZ) {
		self.sample_acc -= CPU_HZ;
		self.write_sample(0, 0);
	}
}

const float HP_CHARGE = 0.996336f;
const int   DAC_SCALE = 380; // per-unit; 15 units * 4 channels ~= 22800

fn void Apu.emit_sample(&self) {
	int[4] out;
	out[0] = self.ch1.enabled ? ((int)self.ch1.output() * 2 - 15) * DAC_SCALE : 0;
	out[1] = self.ch2.enabled ? ((int)self.ch2.output() * 2 - 15) * DAC_SCALE : 0;
	out[2] = self.ch3.enabled ? ((int)self.ch3.output() * 2 - 15) * DAC_SCALE : 0;
	out[3] = self.ch4.enabled ? ((int)self.ch4.output() * 2 - 15) * DAC_SCALE : 0;

	int left;
	int right;
	for (int c = 0; c < 4; c++) {
		if ((self.nr51 & (1 << (c + 4))) != 0) left  += out[c];
		if ((self.nr51 & (1 << c)) != 0)       right += out[c];
	}

	int lvol = ((self.nr50 >> 4) & 0x07) + 1;
	int rvol = (self.nr50 & 0x07) + 1;

	float fl = (float)(left  * lvol / 8);
	float fr = (float)(right * rvol / 8);
	float ol = fl - self.hp_l;
	float or = fr - self.hp_r;
	self.hp_l = fl - ol * HP_CHARGE;
	self.hp_r = fr - or * HP_CHARGE;

	self.write_sample(clamp(ol), clamp(or));
}

fn short clamp(float v) {
	if (v > 32767.0f) return 32767;
	if (v < -32768.0f) return -32768;
	return (short)v;
}

fn void Apu.write_sample(&self, short l, short r) {
	if (self.cap == 0) return;
	if (self.count + 2 > self.cap) {
		self.r = (self.r + 2) % self.cap; // overflow: drop the oldest frame
		self.count -= 2;
	}
	self.ring[self.w] = l;
	self.ring[(self.w + 1) % self.cap] = r;
	self.w = (self.w + 2) % self.cap;
	self.count += 2;
}

fn uint Apu.drain(&self, short[] out) {
	usz limit = (usz)out.len;
	usz n = self.count < limit ? self.count : limit;
	for (usz i = 0; i < n; i++) {
		out[i] = self.ring[self.r];
		self.r = (self.r + 1) % self.cap;
	}
	self.count -= n;
	return (uint)n;
}

// --- register access ($FF10-$FF3F) --------------------------------------

// Bits that read as 1 (OR mask) for each register $FF10-$FF26.
const char[23] READ_MASK = {
	0x80, 0x3F, 0x00, 0xFF, 0xBF,       // NR10-NR14
	0xFF, 0x3F, 0x00, 0xFF, 0xBF,       // NR20-NR24 (NR20 unused -> 0xFF)
	0x7F, 0xFF, 0x9F, 0xFF, 0xBF,       // NR30-NR34
	0xFF, 0xFF, 0x00, 0x00, 0xBF,       // NR40-NR44
	0x00, 0x00, 0x70,                   // NR50-NR52
};

fn char Apu.read(&self, ushort addr) {
	if (addr >= 0xFF30 && addr <= 0xFF3F) {
		return self.ch3.ram[addr - 0xFF30];
	}

	char v;
	switch (addr) {
		case 0xFF10: v = self.ch1.nr0;
		case 0xFF11: v = self.ch1.nr1;
		case 0xFF12: v = self.ch1.nr2;
		case 0xFF13: v = self.ch1.nr3;
		case 0xFF14: v = self.ch1.nr4;
		case 0xFF16: v = self.ch2.nr1;
		case 0xFF17: v = self.ch2.nr2;
		case 0xFF18: v = self.ch2.nr3;
		case 0xFF19: v = self.ch2.nr4;
		case 0xFF1A: v = self.ch3.nr0;
		case 0xFF1B: v = self.ch3.nr1;
		case 0xFF1C: v = self.ch3.nr2;
		case 0xFF1D: v = self.ch3.nr3;
		case 0xFF1E: v = self.ch3.nr4;
		case 0xFF20: v = self.ch4.nr1;
		case 0xFF21: v = self.ch4.nr2;
		case 0xFF22: v = self.ch4.nr3;
		case 0xFF23: v = self.ch4.nr4;
		case 0xFF24: v = self.nr50;
		case 0xFF25: v = self.nr51;
		case 0xFF26:
			v = self.power ? (char)0x80 : (char)0x00;
			if (self.ch1.enabled) v |= 0x01;
			if (self.ch2.enabled) v |= 0x02;
			if (self.ch3.enabled) v |= 0x04;
			if (self.ch4.enabled) v |= 0x08;
		default:
			return 0xFF;
	}

	int idx = addr <= 0xFF14 ? addr - 0xFF10
		: addr <= 0xFF19 ? addr - 0xFF16 + 5
		: addr <= 0xFF1E ? addr - 0xFF1A + 10
		: addr <= 0xFF23 ? addr - 0xFF20 + 15
		: addr - 0xFF24 + 20;
	return (char)(v | READ_MASK[idx]);
}

fn void Apu.write(&self, ushort addr, char value) {
	if (addr >= 0xFF30 && addr <= 0xFF3F) {
		self.ch3.ram[addr - 0xFF30] = value;
		return;
	}

	// While powered off only NR52 is writable (wave RAM handled above).
	if (!self.power && addr != 0xFF26) return;

	switch (addr) {
		case 0xFF10: self.ch1.nr0 = value;
		case 0xFF11:
			self.ch1.nr1 = value;
			self.ch1.length = 64 - (value & 0x3F);
		case 0xFF12:
			self.ch1.nr2 = value;
			self.ch1.dac = (value & 0xF8) != 0;
			if (!self.ch1.dac) self.ch1.enabled = false;
		case 0xFF13: self.ch1.nr3 = value;
		case 0xFF14:
			self.ch1.nr4 = value;
			if ((value & 0x80) != 0) self.ch1.trigger();
		case 0xFF16:
			self.ch2.nr1 = value;
			self.ch2.length = 64 - (value & 0x3F);
		case 0xFF17:
			self.ch2.nr2 = value;
			self.ch2.dac = (value & 0xF8) != 0;
			if (!self.ch2.dac) self.ch2.enabled = false;
		case 0xFF18: self.ch2.nr3 = value;
		case 0xFF19:
			self.ch2.nr4 = value;
			if ((value & 0x80) != 0) self.ch2.trigger();
		case 0xFF1A:
			self.ch3.nr0 = value;
			self.ch3.dac = (value & 0x80) != 0;
			if (!self.ch3.dac) self.ch3.enabled = false;
		case 0xFF1B:
			self.ch3.nr1 = value;
			self.ch3.length = 256 - value;
		case 0xFF1C: self.ch3.nr2 = value;
		case 0xFF1D: self.ch3.nr3 = value;
		case 0xFF1E:
			self.ch3.nr4 = value;
			if ((value & 0x80) != 0) self.ch3.trigger();
		case 0xFF20:
			self.ch4.nr1 = value;
			self.ch4.length = 64 - (value & 0x3F);
		case 0xFF21:
			self.ch4.nr2 = value;
			self.ch4.dac = (value & 0xF8) != 0;
			if (!self.ch4.dac) self.ch4.enabled = false;
		case 0xFF22: self.ch4.nr3 = value;
		case 0xFF23:
			self.ch4.nr4 = value;
			if ((value & 0x80) != 0) self.ch4.trigger();
		case 0xFF24: self.nr50 = value;
		case 0xFF25: self.nr51 = value;
		case 0xFF26:
			bool on = (value & 0x80) != 0;
			if (self.power && !on) self.power_off();
			self.power = on;
		default:
			break;
	}
}

fn void Apu.power_off(&self) {
	Square s1;
	s1.has_sweep = true;
	self.ch1 = s1;
	self.ch2 = {};
	char[16] wave = self.ch3.ram;
	self.ch3 = {};
	self.ch3.ram = wave;
	self.ch4 = {};
	self.nr50 = 0;
	self.nr51 = 0;
	self.fs_step = 0;
}
