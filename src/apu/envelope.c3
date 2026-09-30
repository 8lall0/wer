module apu;

// The envelope's clock line and its lock (the volume stops at 0 or 15). The
// clock is raised by the frame sequencer's secondary event when the period
// countdown expires and lowered by the next DIV event, which is when the
// volume steps. Modelled after SameBoy (apu.c).
struct EnvClock {
	bool locked;
	bool clock;
	bool should_lock;
}

fn void EnvClock.set(&self, bool value, bool up, int volume) {
	if (self.clock == value) return;
	if (value) {
		self.clock = true;
		self.should_lock = (volume == 0xF && up) || (volume == 0 && !up);
	} else {
		self.clock = false;
		self.locked |= self.should_lock;
	}
}

// Writing NRx2 while the channel plays ("zombie mode") steps or inverts the
// volume depending on the old and new values.
fn void nrx2_glitch_step(int* volume, char value, char old, int* countdown, EnvClock* env) {
	if (env.clock) *countdown = value & 7;
	bool should_tick = (value & 7) != 0 && (old & 7) == 0 && !env.locked;
	bool should_invert = ((value ^ old) & 8) != 0;

	if ((value & 0xF) == 8 && (old & 0xF) == 8 && !env.locked) should_tick = true;

	if (should_invert) {
		if (value & 8) {
			if ((old & 7) == 0 && !env.locked) {
				*volume ^= 0xF;
			} else {
				*volume = (0xE - *volume) & 0xF;
			}
			should_tick = false;
		} else {
			*volume = (0x10 - *volume) & 0xF;
		}
	}
	if (should_tick) {
		*volume = (value & 8) ? (*volume + 1) & 0xF : (*volume - 1) & 0xF;
	} else if ((value & 7) == 0 && env.clock) {
		env.set(false, false, 0);
	}
}

// A DMG (and CGB up to C) goes through $FF on the way to the new value.
fn void nrx2_glitch(bool dmg, int* volume, char value, char old, int* countdown, EnvClock* env) {
	if (dmg) {
		nrx2_glitch_step(volume, 0xFF, old, countdown, env);
		nrx2_glitch_step(volume, value, 0xFF, countdown, env);
	} else {
		nrx2_glitch_step(volume, value, old, countdown, env);
	}
}
