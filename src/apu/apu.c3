module apu;

// Models the DMG quirks Blargg's dmg_sound checks (length counter on trigger
// and power, sweep negate exit, wave RAM access and corruption while playing).
// Channels 1, 2 and 4 are stepped per M-cycle, not per T-cycle.

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

	uint out_rate;
	uint clock_hz; // T-cycles per real second (the model's clock); 0 = CPU_HZ
	bool cgb;      // CGB hardware (either mode): no DMG wave/length quirks
}

fn void Apu.init(&self) {
	self.ch1.has_sweep = true;
	self.cap = (usz)self.ring.len;
	self.out_rate = SAMPLE_RATE;
}

fn ulong Apu.hz(&self) => self.clock_hz ? self.clock_hz : CPU_HZ;

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

	self.sample_acc += (ulong)t * self.out_rate;
	while (self.sample_acc >= self.hz()) {
		self.sample_acc -= self.hz();
		self.emit_sample();
	}
}

fn void Apu.push_silence(&self, uint t) {
	self.sample_acc += (ulong)t * self.out_rate;
	while (self.sample_acc >= self.hz()) {
		self.sample_acc -= self.hz();
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
		if (!self.ch3.enabled) return self.ch3.ram[addr - 0xFF30];
		// While playing: the byte being played (CGB), or on a DMG only the
		// byte the channel is fetching right now.
		int i = self.cgb ? self.ch3.pos >> 1 : self.ch3.cpu_access_index();
		return i < 0 ? (char)0xFF : self.ch3.ram[i];
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

	return (char)(v | READ_MASK[addr - 0xFF10]);
}

fn void Apu.write(&self, ushort addr, char value) {
	if (addr >= 0xFF30 && addr <= 0xFF3F) {
		if (!self.ch3.enabled) {
			self.ch3.ram[addr - 0xFF30] = value;
			return;
		}
		int i = self.cgb ? self.ch3.pos >> 1 : self.ch3.cpu_access_index();
		if (i >= 0) self.ch3.ram[i] = value;
		return;
	}

	// While powered off only NR52 is writable (wave RAM handled above) — except
	// that on the DMG the length counters keep working: NRx1 writes still load
	// them (the duty bits are not stored). Blargg dmg_sound 08.
	if (!self.power && self.cgb && addr != 0xFF26) return;
	if (!self.power) {
		switch (addr) {
			case 0xFF11: self.ch1.length = 64 - (value & 0x3F);
			case 0xFF16: self.ch2.length = 64 - (value & 0x3F);
			case 0xFF1B: self.ch3.length = 256 - value;
			case 0xFF20: self.ch4.length = 64 - (value & 0x3F);
			case 0xFF26: break;
			default:     return;
		}
		if (addr != 0xFF26) return;
	}

	switch (addr) {
		case 0xFF10:
			// Leaving subtract mode after a sweep calculation was made in it
			// disables the channel (Blargg dmg_sound 05).
			if ((self.ch1.nr0 & 0x08) != 0 && (value & 0x08) == 0 && self.ch1.sweep_neg_used) {
				self.ch1.enabled = false;
			}
			self.ch1.nr0 = value;
		case 0xFF11:
			self.ch1.nr1 = value;
			self.ch1.length = 64 - (value & 0x3F);
		case 0xFF12:
			self.ch1.nr2 = value;
			self.ch1.dac = (value & 0xF8) != 0;
			if (!self.ch1.dac) self.ch1.enabled = false;
		case 0xFF13: self.ch1.nr3 = value;
		case 0xFF14:
			bool off = nrx4_length(&self.ch1.length, 64, self.ch1.nr4, value, self.length_first_half());
			self.ch1.nr4 = value;
			if ((value & 0x80) != 0) self.ch1.trigger();
			if (off) self.ch1.enabled = false;
		case 0xFF16:
			self.ch2.nr1 = value;
			self.ch2.length = 64 - (value & 0x3F);
		case 0xFF17:
			self.ch2.nr2 = value;
			self.ch2.dac = (value & 0xF8) != 0;
			if (!self.ch2.dac) self.ch2.enabled = false;
		case 0xFF18: self.ch2.nr3 = value;
		case 0xFF19:
			bool off = nrx4_length(&self.ch2.length, 64, self.ch2.nr4, value, self.length_first_half());
			self.ch2.nr4 = value;
			if ((value & 0x80) != 0) self.ch2.trigger();
			if (off) self.ch2.enabled = false;
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
			bool off = nrx4_length(&self.ch3.length, 256, self.ch3.nr4, value, self.length_first_half());
			self.ch3.nr4 = value;
			if ((value & 0x80) != 0) self.ch3.trigger(!self.cgb);
			if (off) self.ch3.enabled = false;
		case 0xFF20:
			self.ch4.nr1 = value;
			self.ch4.length = 64 - (value & 0x3F);
		case 0xFF21:
			self.ch4.nr2 = value;
			self.ch4.dac = (value & 0xF8) != 0;
			if (!self.ch4.dac) self.ch4.enabled = false;
		case 0xFF22: self.ch4.nr3 = value;
		case 0xFF23:
			bool off = nrx4_length(&self.ch4.length, 64, self.ch4.nr4, value, self.length_first_half());
			self.ch4.nr4 = value;
			if ((value & 0x80) != 0) self.ch4.trigger();
			if (off) self.ch4.enabled = false;
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

// CGB PCM12/PCM34 ($FF76/$FF77): the current digital output (0-15) of
// channels 1+2 and 3+4, the second channel of each pair in the high nibble.
fn char Apu.pcm12(&self) => (char)(self.ch1.output() | self.ch2.output() << 4);
fn char Apu.pcm34(&self) => (char)(self.ch3.output() | self.ch4.output() << 4);

// True while the frame sequencer's next step will not clock the length
// counters (they are clocked on steps 0, 2, 4, 6; fs_step is the next step).
fn bool Apu.length_first_half(&self) => (self.fs_step & 1) != 0;

// NRx4 length-counter quirks (Blargg dmg_sound 03). In the first half of a
// length period, enabling the counter clocks it once right away, and a
// trigger that reloads an empty counter loads max - 1 if length is enabled.
// Returns true when the extra clock emptied the counter without a trigger,
// which turns the channel off. The channel's own trigger() then sees a
// non-zero counter and leaves it alone.
fn bool nrx4_length(int* length, int max, char old, char value, bool first_half) {
	bool enable = (value & 0x40) != 0;
	bool trigger = (value & 0x80) != 0;
	bool off = false;
	if (first_half && enable && (old & 0x40) == 0 && *length > 0) {
		(*length)--;
		if (*length == 0 && !trigger) off = true;
	}
	if (trigger && *length == 0) {
		*length = max;
		if (first_half && enable) (*length)--;
	}
	return off;
}

// Powering off clears every register, but on the DMG not the length counters
// (Blargg dmg_sound 08, 11; a CGB clears them too) and never wave RAM.
fn void Apu.power_off(&self) {
	int[4] length = { self.ch1.length, self.ch2.length, self.ch3.length, self.ch4.length };
	Square s1;
	s1.has_sweep = true;
	self.ch1 = s1;
	self.ch2 = {};
	char[16] wave = self.ch3.ram;
	self.ch3 = {};
	self.ch3.ram = wave;
	self.ch4 = {};
	if (self.cgb) length = {};
	self.ch1.length = length[0];
	self.ch2.length = length[1];
	self.ch3.length = length[2];
	self.ch4.length = length[3];
	self.nr50 = 0;
	self.nr51 = 0;
	self.fs_step = 0;
}
