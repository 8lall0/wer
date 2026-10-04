module apu;

// The APU, modelled after SameBoy's (Core/apu.c) at the level SameSuite and
// Blargg's sound tests check: every channel counts on the APU's 2 MHz clock,
// the frame sequencer is DIV-driven (a primary event on the falling edge of
// DIV bit 12, a secondary one on the rising edge for the envelopes), and the
// start/restart, sweep, envelope and NR43 quirks follow the hardware. The
// DMG paths are SameBoy's DMG ones, the CGB paths its CGB-E ones.

const int  SAMPLE_RATE = 48000;
const ulong CPU_HZ     = 4194304;

const int SQ1 = 0;
const int SQ2 = 1;
const int WAV = 2;
const int NOI = 3;

// Register offsets in `io` ($FF10 + n).
const int NR10 = 0x00;
const int NR11 = 0x01;
const int NR12 = 0x02;
const int NR13 = 0x03;
const int NR14 = 0x04;
const int NR21 = 0x06;
const int NR22 = 0x07;
const int NR30 = 0x0A;
const int NR32 = 0x0C;
const int NR42 = 0x11;
const int NR43 = 0x12;
const int NR44 = 0x13;
const int NR50 = 0x14;
const int NR51 = 0x15;
const int WAVE_RAM = 0x20;

// skip_div_event
const int SKIP_INACTIVE = 0;
const int SKIP_SKIPPED  = 1;
const int SKIP_SKIP     = 2;

struct Apu {
	bool power;
	char[0x30] io;       // $FF10-$FF3F as written; wave RAM at WAVE_RAM

	bool[4] active;
	char[4] samples;     // each channel's digital output (0-15)

	int div_divider;     // frame sequencer step counter (8 bits)
	// CGB-C and older: PCM12/PCM34 read in the M-cycle a channel's output
	// changes give a glitched value (SameBoy pcm_mask); reset every M-cycle.
	char[2] pcm_mask;
	int lf_div;          // 1 MHz phase of the 2 MHz clock

	// channel 1 sweep
	int  sweep_countdown;         // in 128 Hz ticks
	int  sweep_calc_countdown;    // in 1 MHz ticks
	int  sweep_calc_reload_timer; // in 1 MHz ticks
	int  sweep_addend;
	int  shadow_sweep_length;
	bool unshifted_sweep;
	bool sweep_instant_done;
	int  ch1_restart_hold;
	int  ch1_completed_addend;

	Square[2] sq;
	Wave  wave;
	Noise noise;

	int  skip_div_event;
	bool pending_envelope_tick;
	bool noise_counter_active;
	bool noise_background_counter_active;
	bool lfsr_stepped_in_narrow;
	bool lfsr_bit_7_before_step;
	bool noise_started_with_dac_disabled;
	bool during_div_write;

	// Set by the MMU.
	bool   cgb;          // CGB hardware (either mode)
	// M-cycles from a channel's start in which a frame sequencer step still
	// counts as before it (envelope: SQ1, SQ2, NOI; sweep; Gambatte nr4Init).
	int[3] env_grace;
	int    sweep_grace;
	// The 2 MHz clock as Gambatte derives it from the CPU's (PSG::
	// generateSamples): CPU cycles, the last cycle counted, and the count,
	// which DIV writes and power-on realign (PSG::divReset, PSG::reset).
	ulong  gcc;
	ulong  glu;
	ulong  gspu;
	int    clock_hold;
	uint   defer_steps;   // frame sequencer events held back an M-cycle (Apu.tick)
	uint   defer_rises;
	bool   defer_write;
	bool   clock_ds;      // the 2 MHz clock's view of double speed (it switches at its own time)
	char   rev;          // CGB revision (REV_*, mmu::CgbRevision's ordinal)
	bool   mgb;          // Game Boy Pocket / Light
	bool   double_speed;
	ushort div_counter;  // the timer's 16-bit counter, for power-on

	// Output.
	ulong sample_acc;
	float hp_l;          // one-pole DC-blocking high-pass
	float hp_r;
	short[] ring;        // caller-provided ring of interleaved s16 L,R samples
	usz     cap;
	usz     w;
	usz     r;
	usz     count;
	uint out_rate;
	uint clock_hz;       // T-cycles per real second (the model's clock); 0 = CPU_HZ
}

fn void Apu.init(&self) {
	self.cap = (usz)self.ring.len;
	self.out_rate = SAMPLE_RATE;
	self.reset_channels();
}

fn ulong Apu.hz(&self) => self.clock_hz ? self.clock_hz : CPU_HZ;

fn void Apu.set_ring(&self, short[] buf) {
	self.ring = buf;
	self.cap = (usz)buf.len;
}

fn bool Apu.dmg(&self) => !self.cgb;
// SameBoy's model <= CGB_C: a DMG, or a CGB-C.
// CGB revisions (mmu::CgbRevision's ordinals).
const char REV_0 = 0;
const char REV_A = 1;
const char REV_B = 2;
const char REV_C = 3;
const char REV_D = 4;
const char REV_E = 5;

// SameBoy's `model <= GB_MODEL_CGB_C` (a DMG counts) and `> CGB_C` (D, E).
fn bool Apu.le_c(&self) => !self.cgb || self.rev <= REV_C;
fn bool Apu.after_c(&self) => self.cgb && self.rev > REV_C;

// Clears the channel state like a power cycle does (not the registers).
fn void Apu.clear_state(&self) {
	Apu keep = *self;
	*self = {};
	self.power = keep.power;
	self.io = keep.io;
	self.cgb = keep.cgb;
	self.rev = keep.rev;
	self.mgb = keep.mgb;
	self.gcc = keep.gcc;
	self.glu = keep.glu;
	self.gspu = keep.gspu;
	self.clock_ds = keep.clock_ds;
	self.double_speed = keep.double_speed;
	self.div_counter = keep.div_counter;
	self.sample_acc = keep.sample_acc;
	self.hp_l = keep.hp_l;
	self.hp_r = keep.hp_r;
	self.ring = keep.ring;
	self.cap = keep.cap;
	self.w = keep.w;
	self.r = keep.r;
	self.count = keep.count;
	self.out_rate = keep.out_rate;
	self.clock_hz = keep.clock_hz;
}

// The state after power-on (GB_apu_init).
fn void Apu.reset_channels(&self) {
	self.clear_state();
	self.lf_div = 1;
	self.wave.shift = 4;
	// Turning the APU on while DIV's APU bit is set skips the first event.
	if (self.div_counter & (self.double_speed ? 0x2000 : 0x1000)) {
		self.skip_div_event = SKIP_SKIP;
		self.div_divider = 1;
	}
	self.sq[0].sample_countdown = 0xFFFF;
	self.sq[1].sample_countdown = 0xFFFF;
}

fn bool Apu.dac_on(&self, int ch) {
	switch (ch) {
		case SQ1: return (self.io[NR12] & 0xF8) != 0;
		case SQ2: return (self.io[NR22] & 0xF8) != 0;
		case WAV: return self.wave.enable;
		default:  return (self.io[NR42] & 0xF8) != 0;
	}
}

fn void Apu.stop(&self, int ch) {
	self.active[ch] = false;
	self.samples[ch] = 0;
}

// The duty step moved: latch its output with the current duty (Gambatte
// DutyUnit: a duty change alone doesn't change the output; sound/
// ch1_duty0_to_duty3_pos3*).
fn void Apu.latch_duty(&self, int i) {
	Square* s = &self.sq[i];
	int duty = self.io[i * 5 + 1] >> 6;
	s.duty_high = DUTY_TABLE[s.current_sample_index + duty * 8] != 0;
}

fn void Apu.update_square_sample(&self, int i) {
	Square* s = &self.sq[i];
	if (s.sample_surpressed) return;
	self.samples[i] = s.duty_high ? (char)s.current_volume : 0;
}

fn void Apu.update_wave_sample(&self) {
	char b = self.wave.current_sample_byte;
	char nibble = (self.wave.current_sample_index & 1) ? b & 0xF : b >> 4;
	self.samples[WAV] = self.wave.shift == 4 ? 0 : nibble >> self.wave.shift;
}

// --- frame sequencer -----------------------------------------------------

fn void Apu.tick_square_envelope(&self, int i) {
	Square* s = &self.sq[i];
	s.env.set(false, false, 0);
	if (s.env.locked) return;
	char nrx2 = self.io[i * 5 + 2];
	if ((nrx2 & 7) == 0) return;
	if (self.double_speed) {
		if (i == SQ1) {
			self.pcm_mask[0] &= (char)(s.current_volume | 0xF1);
		} else {
			// A CGB-0's channel 2 masks less going down from 1 (SameBoy).
			char low = self.rev == REV_0 && s.current_volume == 1 && (nrx2 & 8) ? 0x1F : 0x3F;
			self.pcm_mask[0] &= (char)((s.current_volume << 4) | low);
		}
	}
	s.current_volume = (nrx2 & 8) ? (s.current_volume + 1) & 0xFF : (s.current_volume - 1) & 0xFF;
	if (self.active[i]) self.update_square_sample(i);
}

fn void Apu.tick_noise_envelope(&self) {
	self.noise.env.set(false, false, 0);
	if (self.noise.env.locked) return;
	char nr42 = self.io[NR42];
	if ((nr42 & 7) == 0) return;
	if (self.double_speed) self.pcm_mask[1] &= (char)((self.noise.current_volume << 4) | 0x1F);
	self.noise.current_volume = (nr42 & 8) ? (self.noise.current_volume + 1) & 0xFF : (self.noise.current_volume - 1) & 0xFF;
	if (self.active[NOI]) self.samples[NOI] = (self.noise.lfsr & 1) ? (char)self.noise.current_volume : 0;
}

fn void Apu.sweep_calculation_done(&self) {
	// Sweep bug: the frequency is checked after adding the delta twice.
	if (self.ch1_restart_hold == 0) self.shadow_sweep_length = self.sq[0].sample_length;
	if (self.io[NR10] & 8) self.sweep_addend ^= 0x7FF;
	if (self.shadow_sweep_length + self.sweep_addend > 0x7FF && (self.io[NR10] & 8) == 0) {
		self.stop(SQ1);
	}
	self.ch1_completed_addend = self.sweep_addend;
}

fn void Apu.trigger_sweep_calculation(&self) {
	char nr10 = self.io[NR10];
	if ((nr10 & 0x70) == 0 || self.sweep_countdown != 7) return;
	if (nr10 & 0x07) {
		self.sq[0].sample_length = (self.sweep_addend + self.shadow_sweep_length + ((nr10 & 8) ? 1 : 0)) & 0x7FF;
	}
	if (self.ch1_restart_hold == 0) {
		self.sweep_addend = self.sq[0].sample_length >> (nr10 & 7);
	}
	// Recalculation and the overflow check only happen after a delay.
	self.sweep_calc_countdown = nr10 & 7;
	self.sweep_calc_reload_timer = 1 + self.lf_div;
	if (!self.double_speed && self.during_div_write) self.sweep_calc_reload_timer = 1;
	self.unshifted_sweep = (nr10 & 7) == 0;
	self.sweep_countdown = ((nr10 >> 4) & 7) ^ 7;
	if (self.sweep_calc_countdown == 0) self.sweep_instant_done = true;
}

// Envelope ticks postponed by one M-cycle (CGB double speed).
fn void Apu.delayed_envelope_tick(&self) {
	self.pending_envelope_tick = false;
	self.pcm_mask = { 0xFF, 0xFF };
	if (!self.power) return;
	for (int i = 0; i < 2; i++) {
		if (self.sq[i].env.clock) self.tick_square_envelope(i);
	}
	if (self.noise.env.clock) self.tick_noise_envelope();
}

fn void Apu.clock_length(&self, int* length, bool enabled, int ch) {
	if (enabled && *length) {
		(*length)--;
		if (*length == 0) self.stop(ch);
	}
}

// Falling edge of the DIV bit: the 512 Hz frame sequencer step.
fn void Apu.div_event(&self) {
	self.pcm_mask = { 0xFF, 0xFF };
	if (!self.power) return;
	if (self.skip_div_event == SKIP_SKIP) {
		self.skip_div_event = SKIP_SKIPPED;
		return;
	}
	if (self.skip_div_event == SKIP_SKIPPED) {
		self.skip_div_event = SKIP_INACTIVE;
	} else {
		self.div_divider = (self.div_divider + 1) & 0xFF;
	}

	if ((self.div_divider & 7) == 7) {
		// A channel started just before counts from after this step (Gambatte
		// EnvelopeUnit::nr4Init: cc + 2; sound/ch2_init_reset_env_counter_timing_*).
		for (int i = 0; i < 2; i++) {
			if (!self.sq[i].env.clock && !self.env_grace[i]) self.sq[i].volume_countdown = (self.sq[i].volume_countdown - 1) & 7;
		}
		if (!self.noise.env.clock && !self.env_grace[2]) self.noise.volume_countdown = (self.noise.volume_countdown - 1) & 7;
	}

	if (self.double_speed && self.after_c()) {
		self.pending_envelope_tick = true;
	} else {
		for (int i = 0; i < 2; i++) {
			if (self.sq[i].env.clock) self.tick_square_envelope(i);
		}
		if (self.noise.env.clock) self.tick_noise_envelope();
	}

	if (self.div_divider & 1) {
		for (int i = 0; i < 2; i++) self.clock_length(&self.sq[i].pulse_length, self.sq[i].length_enabled, i);
		self.clock_length(&self.wave.pulse_length, self.wave.length_enabled, WAV);
		self.clock_length(&self.noise.pulse_length, self.noise.length_enabled, NOI);
	}

	if ((self.div_divider & 3) == 3 && !self.sweep_grace) {
		self.sweep_countdown = (self.sweep_countdown + 1) & 7;
		self.trigger_sweep_calculation();
	}
}

// Rising edge of the DIV bit: envelope periods that ran out raise the clock.
fn void Apu.div_secondary_event(&self) {
	self.pcm_mask = { 0xFF, 0xFF };
	if (!self.power) return;
	for (int i = 0; i < 2; i++) {
		Square* s = &self.sq[i];
		char nrx2 = self.io[i * 5 + 2];
		if (self.active[i] && s.volume_countdown == 0) {
			s.volume_countdown = nrx2 & 7;
			s.env.set(s.volume_countdown != 0, (nrx2 & 8) != 0, s.current_volume);
		}
	}
	if (self.active[NOI] && self.noise.volume_countdown == 0) {
		char nr42 = self.io[NR42];
		self.noise.volume_countdown = nr42 & 7;
		self.noise.env.set(self.noise.volume_countdown != 0, (nr42 & 8) != 0, self.noise.current_volume);
	}
}

// --- the 2 MHz clock -----------------------------------------------------

fn void Apu.update_lfsr(&self) {
	self.noise.current_lfsr_sample = (self.noise.lfsr & 1) != 0;
	if (self.active[NOI]) {
		self.samples[NOI] = self.noise.current_lfsr_sample ? (char)self.noise.current_volume : 0;
	}
}

fn void Apu.step_lfsr(&self) {
	Noise* n = &self.noise;
	self.lfsr_bit_7_before_step = (n.lfsr & 0x80) != 0;
	int high_bit_mask = n.narrow ? 0x4040 : 0x4000;
	bool new_high_bit = ((n.lfsr ^ (n.lfsr >> 1) ^ 1) & 1) != 0;
	n.lfsr >>= 1;
	if (new_high_bit) {
		n.lfsr |= high_bit_mask;
	} else {
		n.lfsr &= ~high_bit_mask; // matters when switching widths
	}
	self.update_lfsr();
	self.lfsr_stepped_in_narrow = n.narrow;
}

// Runs the channels for `cycles` 2 MHz ticks.
fn void Apu.run(&self, int cycles) {
	if (cycles <= 0) return;

	bool start_ch4 = false;
	if (self.noise.dmg_delayed_start) {
		if (self.noise.dmg_delayed_start == cycles) {
			self.noise.dmg_delayed_start = 0;
			start_ch4 = true;
		} else if (self.noise.dmg_delayed_start > cycles) {
			self.noise.dmg_delayed_start -= cycles;
		} else {
			int first = self.noise.dmg_delayed_start;
			cycles -= first;
			self.run(first);
		}
	}

	// Channels 1, 2 and 4 run at 1 MHz: keep track of the phase.
	self.lf_div ^= cycles & 1;
	self.noise.alignment = (self.noise.alignment + cycles) & 0xFF;

	int sweep_cycles = cycles / 2;
	if ((cycles & 1) && !self.lf_div) sweep_cycles++;

	if (self.sweep_calc_reload_timer > sweep_cycles) {
		self.sweep_calc_reload_timer -= sweep_cycles;
		sweep_cycles = 0;
	} else {
		if (self.sweep_calc_reload_timer && !self.sweep_calc_countdown && self.sweep_instant_done) {
			self.sweep_calculation_done();
		}
		self.sweep_instant_done = false;
		sweep_cycles -= self.sweep_calc_reload_timer;
		self.sweep_calc_reload_timer = 0;
	}

	// The calculation pauses while the shift is 0.
	if (self.sweep_calc_countdown && ((self.io[NR10] & 7) || self.unshifted_sweep)) {
		if (self.sweep_calc_countdown > sweep_cycles) {
			self.sweep_calc_countdown -= sweep_cycles;
		} else {
			self.sweep_calc_countdown = 0;
			self.sweep_calculation_done();
		}
	}

	if (self.ch1_restart_hold) {
		self.ch1_restart_hold = self.ch1_restart_hold > cycles ? self.ch1_restart_hold - cycles : 0;
	}

	for (int i = 0; i < 2; i++) {
		if (!self.active[i]) continue;
		Square* s = &self.sq[i];
		int left = cycles;
		if (s.delay) s.delay = s.delay < left ? 0 : s.delay - left;
		while (left > s.sample_countdown) {
			left -= s.sample_countdown + 1;
			s.sample_countdown = s.reload();
			s.current_sample_index = (s.current_sample_index + 1) & 7;
			s.sample_surpressed = false;
			if (left == 0 && self.samples[i] == 0) self.pcm_mask[0] &= i == SQ1 ? 0xF0 : 0x0F;
			s.did_tick = true;
			self.latch_duty(i);
			self.update_square_sample(i);
		}
		s.just_reloaded = left == 0;
		if (left) s.sample_countdown -= left;
	}

	self.wave.just_read = false;
	if (self.active[WAV]) {
		Wave* w = &self.wave;
		int left = cycles;
		while (left > w.sample_countdown) {
			left -= w.sample_countdown + 1;
			w.sample_countdown = w.sample_length ^ 0x7FF;
			w.current_sample_index = (w.current_sample_index + 1) & 0x1F;
			w.current_sample_byte = self.io[WAVE_RAM + (w.current_sample_index >> 1)];
			self.update_wave_sample();
			w.just_read = true;
		}
		if (left) {
			w.sample_countdown -= left;
			w.just_read = false;
		}
	}

	if (self.noise_counter_active || self.noise_background_counter_active) {
		Noise* n = &self.noise;
		int left = cycles;
		int divisor = (self.io[NR43] & 0x07) << 2;
		if (!divisor) divisor = 2;
		if (n.counter_countdown == 0) n.counter_countdown = divisor;
		while (left >= n.counter_countdown) {
			left -= n.counter_countdown;
			n.counter_countdown = divisor;
			int mask = 1 << (self.io[NR43] >> 4);
			bool old_bit = (n.counter & mask) != 0;
			n.counter = (n.counter + 1) & 0x3FFF;
			n.did_step_counter = true;
			bool new_bit = (n.counter & mask) != 0;
			if (new_bit && !old_bit && self.active[NOI]) {
				if (left == 0 && self.samples[NOI] == 0 && !self.double_speed) self.pcm_mask[1] &= 0x0F;
				self.step_lfsr();
			}
		}
		if (left) {
			n.counter_countdown -= left;
			n.countdown_reloaded = false;
		} else {
			n.countdown_reloaded = true;
		}
	}

	if (start_ch4) self.write(0xFF23, self.io[NR44] | 0x80);
}

// M-cycles pass: the 2 MHz ticks they give.
fn int Apu.clock(&self, int mcycles) {
	if (self.clock_hold > 0) {
		// Like the timer, the 2 MHz clock doesn't see the M-cycle before a
		// switch back to normal speed (Gambatte counts the halt from the STOP).
		self.clock_hold--;
		return 0;
	}
	self.gcc += (ulong)mcycles * 4;
	int shift = self.clock_ds ? 2 : 1;
	ulong n = (self.gcc - self.glu) >> shift;
	self.glu += n << shift;
	self.gspu += n;
	return (int)n;
}

// A DIV write realigns the count with the frame sequencer (PSG::divReset).
fn void Apu.clock_div_reset(&self) {
	ulong off = self.double_speed ? (self.glu & 1) : 0;
	ulong cc = self.gspu + off;
	self.gspu = (cc & ~(ulong)0xFFF) + 2 * (cc & 0x800) - off;
}

// Power-on (PSG::reset).
fn void Apu.clock_power_on(&self) {
	bool ds = self.double_speed;
	ulong off = ds ? (self.glu & 1) : 0;
	ulong cc = self.gspu + off;
	ulong nds = ds ? 0 : 1;
	self.gspu = (cc & 0xFFF) + 2 * (~(cc + 1 + nds) & 0x800);
	self.glu = ((self.glu + 3) & ~(ulong)3) - nds;
}

// The clock changes speed (PSG::speedChange; at the STOP going back to normal
// speed, 2 M-cycles on going to double): leaving double speed the last count
// shifts a cycle, entering it the count is corrected.
fn void Apu.clock_switch(&self, bool to_double) {
	if (!to_double) {
		self.glu--;
	} else {
		// Going to double speed the count drops half the ticks since the
		// last DIV reset (the channels keep their timing).
		ulong div_ticks = self.gspu & 0xFFF;
		self.gspu -= div_ticks / 2 + self.glu % 2;
	}
	self.clock_ds = to_double;
}

// Gambatte's ticks from now to a square channel's first step after a start
// (DutyUnit::nr4Change: cc - (cc - ref) % 2 + period + 4 - 2 * master).
fn int Apu.duty_start_ticks(&self, int i, bool was_active) {
	ulong ref = self.double_speed && (self.glu & 1) ? 0 : 1;
	int par = (int)((self.gspu - ref) & 1);
	return (2048 - self.sq[i].sample_length) * 2 + 4 - (was_active ? 2 : 0) - par;
}

// One M-cycle's worth (or more) of time: `t` T-cycles at the real-time rate,
// with the DIV events that happened in it (see timer::TickResult).
// `frozen`: the APU stands still for this time (the halt after a CGB speed
// switch), only the output keeps going. `ticks`: the 2 MHz ticks (Apu.clock),
// else half of `t`.
fn void Apu.tick(&self, uint t, uint div_events, uint div_secondary = 0, bool div_write = false, bool frozen = false, int ticks = -1) {
	self.pcm_mask = { 0xFF, 0xFF };
	if (frozen) {
		self.output(t);
		return;
	}
	if (self.pending_envelope_tick) self.delayed_envelope_tick();
	// A CGB in double speed with Gambatte's clock a cycle off (odd last
	// count: its speed switch and DIV reset corrections) steps the frame
	// sequencer a tick, i.e. an M-cycle, after the DIV edge (on a CGB-E too:
	// AGE spsw-ch2-lc-delay).
	uint d_steps = self.defer_steps;
	uint d_rises = self.defer_rises;
	bool d_write = self.defer_write;
	self.defer_steps = self.defer_rises = 0;
	self.defer_write = false;
	if (self.cgb && self.clock_ds && (self.glu & 1)) {
		self.defer_steps = div_events;
		self.defer_rises = div_secondary;
		self.defer_write = div_write;
		div_events = div_secondary = 0;
		div_write = false;
	}
	div_events += d_steps;
	div_secondary += d_rises;
	div_write |= d_write;
	if (div_write) {
		self.during_div_write = true;
		self.div_event();
		self.during_div_write = false;
	}
	for (uint i = 0; i < div_events; i++) self.div_event();
	for (uint i = 0; i < div_secondary; i++) self.div_secondary_event();

	if (self.power) self.run(ticks >= 0 ? ticks : (int)t / 2);
	self.output(t);
	for (int i = 0; i < 3; i++) if (self.env_grace[i]) self.env_grace[i]--;
	if (self.sweep_grace) self.sweep_grace--;
}

// Gambatte's nr4Init windows (2 APU cycles, a sweep on a CGB 4): in M-cycles,
// counting the start's own.
fn int Apu.start_grace(&self, int apu_cycles) => self.double_speed ? apu_cycles : apu_cycles / 2;

// Output samples for `t` T-cycles of the current state.
fn void Apu.output(&self, uint t) {
	self.sample_acc += (ulong)t * self.out_rate;
	while (self.sample_acc >= self.hz()) {
		self.sample_acc -= self.hz();
		if (self.power) {
			self.emit_sample();
		} else {
			self.write_sample(0, 0);
		}
	}
}

// --- output --------------------------------------------------------------

const float HP_CHARGE = 0.996336f;
const int   DAC_SCALE = 380; // per-unit; 15 units * 4 channels ~= 22800

fn void Apu.emit_sample(&self) {
	int left;
	int right;
	for (int c = 0; c < 4; c++) {
		if (!self.active[c]) continue;
		int out = ((int)self.samples[c] * 2 - 15) * DAC_SCALE;
		if (self.io[NR51] & (1 << (c + 4))) left  += out;
		if (self.io[NR51] & (1 << c))       right += out;
	}

	int lvol = ((self.io[NR50] >> 4) & 0x07) + 1;
	int rvol = (self.io[NR50] & 0x07) + 1;

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

// CGB PCM12/PCM34 ($FF76/$FF77): the current digital output (0-15) of
// channels 1+2 and 3+4, the second channel of each pair in the high nibble.
fn char Apu.pcm12(&self) => (self.pcm(SQ1) | self.pcm(SQ2) << 4) & (self.le_c() ? self.pcm_mask[0] : 0xFF);
fn char Apu.pcm34(&self) => (self.pcm(WAV) | self.pcm(NOI) << 4) & (self.le_c() ? self.pcm_mask[1] : 0xFF);
fn char Apu.pcm(&self, int ch) => self.active[ch] ? self.samples[ch] : 0;
