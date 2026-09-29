module apu;

// Channel 3 (wave). Timing follows the hardware in 2 T-cycle units (the APU's
// 2 MHz clock), as needed for the DMG's wave RAM behaviour while playing
// (Blargg dmg_sound 09, 10, 12; model after SameBoy):
//
// - `countdown` runs down once per unit; when it underflows, the position
//   advances and the channel fetches that byte of wave RAM (`sample_byte`).
// - A CPU access to wave RAM while the channel plays reaches the byte being
//   played only if that fetch happened in the very last unit (`just_read`);
//   otherwise reads give $FF and writes are lost (see Apu.read / Apu.write).
// - Triggering loads the countdown with 3 extra units and restarts at
//   position 0, but keeps the current sample until the next fetch.
struct Wave {
	bool enabled;
	bool dac;
	char nr0, nr1, nr2, nr3, nr4;
	char[16] ram;
	int  countdown;    // 2 T-cycle units until the next fetch
	char pos;          // sample index 0..31 (two per byte, high nibble first)
	char sample_byte;  // the wave RAM byte last fetched
	bool just_read;    // the fetch happened in the last unit
	int  length;
}

// Extra units before the first fetch after a trigger.
const int WAVE_TRIGGER_DELAY = 3;

fn ushort Wave.freq(&self) {
	return (ushort)(self.nr3 | ((self.nr4 & 0x07) << 8));
}

fn void Wave.step(&self, uint t) {
	self.just_read = false;
	if (!self.enabled) return;
	int units = (int)t / 2;
	while (units > self.countdown) {
		units -= self.countdown + 1;
		self.countdown = self.freq() ^ 0x7FF;
		self.pos = (self.pos + 1) & 31;
		self.sample_byte = self.ram[self.pos >> 1];
		self.just_read = true;
	}
	if (units > 0) {
		self.countdown -= units;
		self.just_read = false;
	}
}

fn void Wave.clock_length(&self) {
	if ((self.nr4 & 0x40) != 0 && self.length > 0) {
		self.length--;
		if (self.length == 0) self.enabled = false;
	}
}

fn void Wave.trigger(&self) {
	// DMG bug: retriggering in the unit the channel is about to fetch
	// corrupts the start of wave RAM with the bytes it was about to read.
	if (self.enabled && self.countdown == 0) {
		int offset = ((self.pos + 1) >> 1) & 0xF;
		if (offset < 4) {
			self.ram[0] = self.ram[offset];
		} else {
			int block = offset & ~3;
			for (int i = 0; i < 4; i++) self.ram[i] = self.ram[block + i];
		}
	}
	bool fetching = self.enabled && self.countdown == 0;
	self.pos = 0;
	if (fetching) self.sample_byte = self.ram[0];
	self.enabled = self.dac;
	if (self.length == 0) self.length = 256;
	self.countdown = (self.freq() ^ 0x7FF) + WAVE_TRIGGER_DELAY;
}

// The wave RAM byte a CPU access reaches while the channel plays, or -1 when
// it misses (read $FF / write lost).
fn int Wave.cpu_access_index(&self) {
	return self.just_read ? self.pos >> 1 : -1;
}

fn char Wave.output(&self) {
	if (!self.enabled || !self.dac) return 0;
	char sample = (self.pos & 1) != 0 ? (self.sample_byte & 0x0F) : (self.sample_byte >> 4);
	switch ((self.nr2 >> 5) & 0x03) {
		case 0: return 0;
		case 1: return sample;
		case 2: return sample >> 1;
		default: return sample >> 2;
	}
}
