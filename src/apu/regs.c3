module apu;

// APU register access ($FF10-$FF3F), after SameBoy's GB_apu_read/write.

// Bits that read as 1 (OR mask) for each register $FF10-$FF26.
const char[23] READ_MASK = {
	0x80, 0x3F, 0x00, 0xFF, 0xBF,       // NR10-NR14
	0xFF, 0x3F, 0x00, 0xFF, 0xBF,       // NR20-NR24 (NR20 unused -> 0xFF)
	0x7F, 0xFF, 0x9F, 0xFF, 0xBF,       // NR30-NR34
	0xFF, 0xFF, 0x00, 0x00, 0xBF,       // NR40-NR44
	0x00, 0x00, 0x70,                   // NR50-NR52
};

// The wave RAM byte a CPU access reaches while channel 3 plays, or -1 when it
// misses (read $FF, write lost): on a DMG only in the tick of a fetch.
fn int Apu.wave_access(&self, int i) {
	if (!self.active[WAV]) return i;
	if (!self.cgb && !self.wave.just_read) return -1;
	return self.wave.current_sample_index / 2;
}

fn char Apu.read(&self, ushort addr) {
	int reg = addr - 0xFF10;
	if (reg >= WAVE_RAM) {
		int i = self.wave_access(reg - WAVE_RAM);
		return i < 0 ? 0xFF : self.io[WAVE_RAM + i];
	}
	if (addr == 0xFF26) {
		char v = 0x70;
		if (self.power) v |= 0x80;
		for (int c = 0; c < 4; c++) {
			if (self.active[c]) v |= (char)(1 << c);
		}
		return v;
	}
	if (reg >= READ_MASK.len) return 0xFF;
	return self.io[reg] | READ_MASK[reg];
}

fn void Apu.write(&self, ushort addr, char value) {
	int reg = addr - 0xFF10;
	if (reg >= WAVE_RAM) {
		int i = self.wave_access(reg - WAVE_RAM);
		if (i >= 0) self.io[WAVE_RAM + i] = value;
		return;
	}
	// Powered off, only NR52 is writable, and on a DMG the length counters
	// (NRx1; the duty bits are not stored).
	if (!self.power && addr != 0xFF26) {
		if (self.cgb) return;
		if (addr != 0xFF11 && addr != 0xFF16 && addr != 0xFF1B && addr != 0xFF20) return;
	}

	switch (addr) {
		case 0xFF24:
		case 0xFF25:
			break;

		case 0xFF26:
			int[4] lengths = { self.sq[0].pulse_length, self.sq[1].pulse_length,
			                   self.wave.pulse_length, self.noise.pulse_length };
			if ((value & 0x80) && !self.power) {
				self.clock_power_on();
				self.reset_channels();
				self.power = true;
			} else if ((value & 0x80) == 0 && self.power) {
				self.clear_state();
				for (int i = 0; i < WAVE_RAM; i++) self.io[i] = 0;
				self.power = false;
			}
			// The DMG keeps the length counters through a power cycle.
			if (!self.cgb && (value & 0x80)) {
				self.sq[0].pulse_length = lengths[0];
				self.sq[1].pulse_length = lengths[1];
				self.wave.pulse_length = lengths[2];
				self.noise.pulse_length = lengths[3];
			}
			return;

		case 0xFF10:
			if (self.sweep_calc_countdown || self.sweep_calc_reload_timer) self.nr10_write_glitch(value);
			bool old_negate = (self.io[NR10] & 8) != 0 || self.le_c();
			self.io[NR10] = value;
			// Leaving negate mode after a calculation made in it stops the channel.
			if (self.shadow_sweep_length + self.ch1_completed_addend + (old_negate ? 1 : 0) > 0x7FF && (value & 8) == 0) {
				self.stop(SQ1);
			}
			self.trigger_sweep_calculation();

		case 0xFF11:
		case 0xFF16:
			int i = addr == 0xFF16 ? SQ2 : SQ1;
			self.sq[i].pulse_length = 0x40 - (value & 0x3F);
			if (!self.power) value &= 0x3F;

		case 0xFF12:
		case 0xFF17:
			int i = addr == 0xFF17 ? SQ2 : SQ1;
			if ((value & 0xF8) == 0) {
				self.io[reg] = value; // DAC off
				self.stop(i);
			} else if (self.active[i]) {
				nrx2_glitch(self.le_c(), &self.sq[i].current_volume, value, self.io[reg],
				            &self.sq[i].volume_countdown, &self.sq[i].env);
				self.update_square_sample(i);
			}

		case 0xFF13:
		case 0xFF18:
			Square* s = &self.sq[addr == 0xFF18 ? SQ2 : SQ1];
			s.sample_length = (s.sample_length & ~0xFF) | value;
			if (s.just_reloaded) s.sample_countdown = s.reload();

		case 0xFF14:
		case 0xFF19:
			self.write_nrx4(addr == 0xFF19 ? SQ2 : SQ1, reg, value);

		case 0xFF1A:
			self.wave.enable = (value & 0x80) != 0;
			if (!self.wave.enable) self.stop(WAV);

		case 0xFF1B:
			self.wave.pulse_length = 0x100 - value;

		case 0xFF1C:
			self.wave.shift = WAVE_SHIFT[(value >> 5) & 3];
			if (self.active[WAV]) self.update_wave_sample();

		case 0xFF1D:
			self.wave.sample_length = (self.wave.sample_length & ~0xFF) | value;

		case 0xFF1E:
			self.write_nr34(value);

		case 0xFF20:
			self.noise.pulse_length = 0x40 - (value & 0x3F);

		case 0xFF21:
			if ((value & 0xF8) == 0) {
				// DAC off
				if (self.active[NOI] && (self.io[NR43] & 7)) {
					if (self.noise.counter_countdown <= 2) self.noise.counter++;
					self.noise_background_counter_active = false;
				}
				self.io[reg] = value;
				self.stop(NOI);
				self.noise_counter_active = false;
			} else if (self.active[NOI]) {
				nrx2_glitch(self.le_c(), &self.noise.current_volume, value, self.io[reg],
				            &self.noise.volume_countdown, &self.noise.env);
				self.samples[NOI] = self.noise.current_lfsr_sample ? (char)self.noise.current_volume : 0;
			}

		case 0xFF22:
			self.write_nr43_reg(value);

		case 0xFF23:
			self.write_nr44(value);

		default:
			if (reg >= READ_MASK.len) return;
	}
	self.io[reg] = value;
}

// If length is enabled while the frame sequencer's next step won't clock it,
// it is clocked once now; a trigger that finds it at 0 reloads max - 1. On a
// CGB-B and older this happens whatever the new enable bit (SameSuite
// *_extra_length_clocking-cgb0B; noise too, unlike SameBoy).
fn void Apu.length_enable_glitch(&self, int* length, bool* enabled, int ch, char value, int max) {
	bool always = self.cgb && self.rev <= REV_B;
	bool clock = ((value & 0x40) || always) && !*enabled && (self.div_divider & 1) && *length;
	// A CGB-B's wave channel clocks it at the next NR34 write instead, a
	// trigger starting afresh (SameSuite channel_3_extra_length_clocking-cgbB;
	// a CGB-0's clocks at once).
	if (always && self.rev == REV_B && ch == WAV) {
		bool now = self.wave.extra_clock_due && *length;
		self.wave.extra_clock_due = clock && (value & 0x80) == 0;
		clock = now;
	}
	if (clock) {
		(*length)--;
		if (*length == 0) {
			if (value & 0x80) {
				*length = max - 1;
			} else {
				self.stop(ch);
			}
		}
	}
	*enabled = (value & 0x40) != 0;
}

fn void Apu.write_nrx4(&self, int i, int reg, char value) {
	Square* s = &self.sq[i];
	bool was_active = self.active[i];
	char old_nrx4 = self.io[reg];

	// A frequency change from >= $700 to < $700 right before a step: the
	// countdown should use the old length but the sample must not change.
	if ((value & 0x80) == 0 && self.active[i] && (old_nrx4 & 7) == 7 && (value & 7) != 7) {
		if (self.after_c() || (s.sample_countdown & 1)) {
			if (s.did_tick && s.sample_countdown >> 1 == (s.sample_length ^ 0x7FF)) {
				s.current_sample_index = (s.current_sample_index - 1) & 7;
				s.sample_surpressed = false;
			}
		}
	}

	int old_sample_length = s.sample_length;
	s.sample_length = (s.sample_length & 0xFF) | ((value & 7) << 8);
	if (s.just_reloaded) s.sample_countdown = s.reload();

	if (value & 0x80) {
		// The duty position is not reset by a restart, only by power off.
		s.env.locked = false;
		s.env.clock = false;
		s.did_tick = false;
		bool force_unsurpressed = false;
		if (!self.active[i]) {
			if (self.after_c()) {
				if ((value & 4) == 0 && (((s.sample_countdown - s.delay) / 2) & 0x400) == 0) {
					s.current_sample_index = (s.current_sample_index + 1) & 7;
					self.latch_duty(i);
					force_unsurpressed = true;
				}
			}
			// SameBoy: before a CGB-D, double speed adds the 1 MHz phase instead.
			s.delay = 6 + self.lf_div * (self.cgb && self.rev < REV_D && self.double_speed ? 1 : -1);
			s.sample_countdown = (s.sample_length ^ 0x7FF) * 2 + s.delay;
			if (self.cgb && self.rev == REV_C) s.sample_countdown = self.duty_start_ticks(i, false) - 1;
		} else {
			int extra_delay = 0;
			if (self.after_c()) {
				// SameBoy (CGB-E): the duty steps on a restart almost always.
				if (!s.just_reloaded && (value & 4) == 0 && (((s.sample_countdown - 1 - s.delay) / 2) & 0x400) == 0) {
					s.current_sample_index = (s.current_sample_index + 1) & 7;
					self.latch_duty(i);
					s.sample_surpressed = false;
				} else if (s.sample_length == 0x7FF && old_sample_length != 0x7FF && s.sample_surpressed) {
					extra_delay += 2;
				}
			}
			// Restarting a playing channel starts 2 ticks earlier.
			s.delay = 4 - self.lf_div + extra_delay;
			s.sample_countdown = (s.sample_length ^ 0x7FF) * 2 + s.delay;
			// CGB-C: Gambatte's timing on its own 2 MHz clock (Apu.clock).
			// Older revisions keep SameBoy's (SameSuite
			// channel_1_freq_change_timing-cgb0BC; Gambatte's tests disagree
			// on a C).
			if (self.cgb && self.rev == REV_C) s.sample_countdown = self.duty_start_ticks(i, true) - 1;
		}
		char nrx2 = self.io[i * 5 + 2];
		s.current_volume = nrx2 >> 4;
		// The new volume applies at once to the sample already playing.
		if (self.active[i]) self.update_square_sample(i);
		s.volume_countdown = nrx2 & 7;
		self.env_grace[i] = self.start_grace(2);

		if ((nrx2 & 0xF8) != 0 && !self.active[i]) {
			self.active[i] = true;
			self.samples[i] = 0;
			s.sample_surpressed = !force_unsurpressed;
		}
		if (s.pulse_length == 0) {
			s.pulse_length = 0x40;
			s.length_enabled = false;
		}

		if (i == SQ1) {
			self.sweep_instant_done = false;
			self.shadow_sweep_length = 0;
			self.ch1_completed_addend = 0;
			char nr10 = self.io[NR10];
			if (nr10 & 7) {
				// Sweep bug: with a shift, the overflow check also runs on trigger.
				self.sweep_calc_countdown = nr10 & 7;
				bool odd = (self.lf_div ^ (self.double_speed ? 0 : 1)) != 0;
				self.sweep_calc_reload_timer = odd && self.le_c() ? 3 : 2;
				self.unshifted_sweep = false;
				if (!was_active) self.sweep_calc_reload_timer++;
				self.sweep_addend = s.sample_length >> (nr10 & 7);
			} else {
				self.sweep_addend = 0;
			}
			self.ch1_restart_hold = 2 - self.lf_div + (self.cgb && self.rev != REV_D ? 2 : 0);
			self.sweep_countdown = ((nr10 >> 4) & 7) ^ 7;
			// The sweep's step just after the start counts as before it (Gambatte
			// SweepUnit::nr4Init: cc + 2, + 4 on a CGB; ch1_init_reset_sweep_counter_timing_*).
			self.sweep_grace = self.start_grace(self.cgb ? 4 : 2);
		}
	}

	self.length_enable_glitch(&s.pulse_length, &s.length_enabled, i, value, 0x40);
}

fn void Apu.write_nr34(&self, char value) {
	Wave* w = &self.wave;
	w.sample_length = (w.sample_length & 0xFF) | ((value & 7) << 8);
	if (value & 0x80) {
		// DMG bug: retriggering in the tick the channel fetches corrupts the
		// start of wave RAM with the bytes it was about to read: one byte from
		// the first four, else their block of four; always the block on a
		// Pocket (SameBoy's Game Boy Light).
		if (!self.cgb && self.active[WAV] && w.sample_countdown == 0) {
			int offset = ((w.current_sample_index + 1) >> 1) & 0xF;
			if (offset < 4 && !self.mgb) {
				self.io[WAVE_RAM] = self.io[WAVE_RAM + offset];
			} else {
				int block = offset & ~3;
				for (int i = 0; i < 4; i++) self.io[WAVE_RAM + i] = self.io[WAVE_RAM + block + i];
			}
		}
		w.current_sample_index = 0;
		if (self.active[WAV] && w.sample_countdown == 0) {
			w.current_sample_byte = self.io[WAVE_RAM];
		}
		if (w.enable) {
			self.active[WAV] = true;
			self.samples[WAV] = w.shift == 4 ? 0 : (w.current_sample_byte >> 4) >> w.shift;
		}
		w.sample_countdown = (w.sample_length ^ 0x7FF) + 3;
		if (w.pulse_length == 0) {
			w.pulse_length = 0x100;
			w.length_enabled = false;
		}
		// The sample itself changes only at the next fetch.
	}
	self.length_enable_glitch(&w.pulse_length, &w.length_enabled, WAV, value, 0x100);
}

fn void Apu.write_nr44(&self, char value) {
	Noise* n = &self.noise;
	if (value & 0x80) {
		n.env.locked = false;
		n.env.clock = false;
		if (!self.cgb && (n.alignment & 3) != 0) {
			n.dmg_delayed_start = 6;
		} else {
			n.lfsr = 0;
			self.prepare_noise_start();
			char nr42 = self.io[NR42];
			n.current_volume = nr42 >> 4;
			n.current_lfsr_sample = false;
			n.volume_countdown = nr42 & 7;
			self.env_grace[2] = self.start_grace(2);
			n.did_step_counter = (n.alignment & 3) == 2;
			if (nr42 & 0xF8) {
				self.active[NOI] = true;
				self.samples[NOI] = 0;
			}
			if (n.pulse_length == 0) {
				n.pulse_length = 0x40;
				n.length_enabled = false;
			}
		}
	}
	self.length_enable_glitch(&n.pulse_length, &n.length_enabled, NOI, value, 0x40);
}

fn void Apu.prepare_noise_start(&self) {
	Noise* n = &self.noise;
	char nr43 = self.io[NR43];
	self.noise_counter_active = (self.io[NR42] & 0xF8) != 0; // reset by APU off and DAC off
	bool was_started_with_dac_disabled = self.noise_started_with_dac_disabled;
	self.noise_started_with_dac_disabled = !self.noise_counter_active;
	int divisor = nr43 & 7;
	bool was_background_counting = self.noise_background_counter_active;
	self.noise_background_counter_active = true;
	bool active = self.active[NOI];
	bool instant_step = false;
	bool div_1_glitch = false;
	// SameBoy's quirks of a CGB-C in double speed.
	bool c_ds = self.cgb && self.rev <= REV_C && self.double_speed;

	if (divisor > 1 && n.counter_countdown == 1) {
		n.counter = (n.counter + 1) & 0x3FFF;
	} else if (divisor > 1 && n.counter_countdown == 2 && active && c_ds) {
		n.counter = (n.counter + 1) & 0x3FFF;
	} else if (n.counter_countdown == 2 && (n.alignment & 3) == 0 && active) {
		if (divisor == 0) {
			divisor = 8;
		} else if (divisor == 1) {
			if (!n.did_step_counter) div_1_glitch = true;
			int mask = 1 << (nr43 >> 4);
			bool old_bit = (n.counter & mask) != 0;
			n.counter = (n.counter + 1) & 0x3FFF;
			bool new_bit = (n.counter & mask) != 0;
			if (new_bit && !old_bit) instant_step = true;
		}
	}

	int cd = divisor == 0 ? 6 : divisor * 4 + 6;
	if (n.alignment & 1) {
		if (!divisor) {
			if (self.le_c()) {
				cd++;
			} else if (was_background_counting) {
				cd--;
			} else {
				cd++;
			}
		} else if (n.alignment & 2) {
			if (divisor == 1 && !active) {
				cd++;
			} else {
				cd -= 3;
			}
		} else {
			cd--;
			if (divisor == 1 && active) cd -= 4;
		}
	} else if (divisor) {
		if (n.alignment & 2) {
			cd += c_ds && divisor == 1 ? 2 : -2;
		} else if (divisor > 1 && !c_ds) {
			cd -= 4;
		} else if (divisor == 1 && active && (nr43 & 0xF0) == 0) {
			cd -= 4;
		}
	} else if (c_ds) {
		cd += 2;
	}

	// Background counting glitches
	if (divisor > 1) {
		if (!self.noise_counter_active && (n.alignment & 3) == 0) cd += 4;
	} else if (was_background_counting && !active && (n.alignment & 3) == 0) {
		if (divisor == 0) {
			if (was_started_with_dac_disabled) cd += 28;
		} else {
			cd -= 4;
		}
	}
	if (!divisor && c_ds && was_background_counting && !active) cd--;
	if (div_1_glitch) cd -= 4;
	n.counter_countdown = cd & 0xFF;

	n.lfsr = !divisor && active && (n.alignment & 3) == 3 ? 0x0055 : 0;
	if (instant_step) self.step_lfsr();
}

fn void Apu.write_nr43_reg(&self, char value) {
	Noise* n = &self.noise;
	if (n.countdown_reloaded) {
		int divisor = (value & 0x07) << 2;
		if (!divisor) divisor = 2;
		int[4] adj = self.after_c() ? { 2, 1, 0, 3 } : { 2, 1, 4, 3 };
		n.counter_countdown = divisor + (divisor == 2 ? 0 : adj[n.alignment & 3]);
	}
	if (self.le_c()) {
		if (n.countdown_reloaded) {
			char nr43 = self.io[NR43];
			bool old_bit = ((n.counter >> (nr43 >> 4)) & 1) != 0;
			bool glitch_bit = ((n.counter >> 7) & 1) != 0;
			bool new_bit = ((n.counter >> (value >> 4)) & 1) != 0;
			if (!old_bit && new_bit && glitch_bit) {
				int prev = (n.counter - 1) & 0x3FFF;
				bool p_old = ((prev >> (nr43 >> 4)) & 1) != 0;
				bool p_glitch = ((prev >> 7) & 1) != 0;
				bool p_new = ((prev >> (value >> 4)) & 1) != 0;
				if (p_old && !p_new && p_glitch) self.step_lfsr();
			}
		}
		self.nr43_write(0xFF);
	}
	self.nr43_write(value);
}

// NR43 writes glitch the LFSR when the selected counter bit changes through
// an intermediate value (SameBoy's deterministic CGB-E variant; DMG simplified).
fn void Apu.nr43_write(&self, char new) {
	Noise* n = &self.noise;
	bool old_narrow = n.narrow;
	n.narrow = (new & 8) != 0;
	char old = self.io[NR43];
	self.io[NR43] = new;
	if ((old & 0xF0) == (new & 0xF0)) return;

	int effective = n.counter;
	if (self.le_c() && n.countdown_reloaded) effective |= (effective - 1) & 0x3FFF;
	bool old_bit = ((effective >> (old >> 4)) & 1) != 0;
	char glitch_value = (old & 0x7F) | (new & 0x80);
	bool glitch_bit = ((effective >> (glitch_value >> 4)) & 1) != 0;
	bool new_bit = ((effective >> (new >> 4)) & 1) != 0;

	if (old_bit == new_bit && new_bit != glitch_bit) {
		if (new_bit) {
			if (self.le_c()) return;
			// Category 1
			if ((new & 0x80) == 0) {
				self.step_lfsr();
				return;
			}
			int t1 = (old >> 4) & 7;
			int t2 = (new >> 4) & 7;
			if ((t1 ^ 7) + t2 > 7 || ((t1 ^ 7) & t2)) {
				// Copy bit 8 to bit 7
				n.lfsr = (n.lfsr & ~0x80) | ((n.lfsr >> 1) & 0x80);
				if ((t1 == 0 || t1 == 4) && t2 == 3) {
					n.lfsr &= (n.lfsr >> 1) | 0x545;
					self.update_lfsr();
				} else if (t1 == 2 && t2 == 3) {
					int mask = 0x555;
					if ((n.lfsr & 0xC) == 0xC) mask |= 8;
					if ((n.lfsr & 0xC00) == 0xC00) mask |= 0x800;
					n.lfsr &= (n.lfsr >> 1) | mask;
					self.update_lfsr();
				}
				if (!n.narrow && old_narrow && self.lfsr_stepped_in_narrow) {
					if (self.lfsr_bit_7_before_step) {
						n.lfsr |= 0x40;
					} else {
						n.lfsr &= ~0x40;
					}
				}
				n.lfsr |= n.narrow ? 0x4040 : 0x4000;
				self.lfsr_stepped_in_narrow = n.narrow;
			}
			return;
		}
		// Category 2
		if (self.le_c()) {
			self.step_lfsr();
			return;
		}
		int glitch = (new & 0x80) ? NR43_GLITCH[((old & 0x70) >> 1) | ((new & 0x70) >> 4)] : 0;
		switch (glitch) {
			case 1:
			case 6:
				// Step, then bit 1 &= bit 0 (6: plus more AND glitches)
				self.step_lfsr();
				if (glitch == 6) {
					if ((n.narrow && (n.lfsr & 0x71) == 0x20) || (n.lfsr & 0x71) == 0x61) n.lfsr &= ~0x20;
					if ((n.lfsr & 0x7001) == 0x2000 || (n.lfsr & 0x7001) == 0x6001) n.lfsr &= ~0x2000;
				}
				if ((n.lfsr & 3) == 2) n.lfsr &= ~2;
			case 2:
				// Step, AND with the previous value except bit 0
				int prev = n.lfsr;
				self.step_lfsr();
				n.lfsr &= prev | 1;
			case 5:
				if ((n.lfsr & 3) == 2) n.lfsr &= n.narrow ? ~0x4040 : ~0x4000;
				if ((n.lfsr & 0x19) == 8) n.lfsr &= ~8;
				nextcase 3;
			case 3:
				// No step: bit 0 = bit 1
				n.lfsr = (n.lfsr & ~1) | ((n.lfsr >> 1) & 1);
				self.update_lfsr();
				self.lfsr_stepped_in_narrow = n.narrow;
			case 4:
				// Step, bit 1 &= bit 0, LFSR bit - 1 &= LFSR bit
				int prev = n.lfsr;
				self.step_lfsr();
				n.lfsr &= prev | (n.narrow ? ~0x2022 : ~0x2002);
			default:
				self.step_lfsr();
		}
	} else if (!old_bit && new_bit) {
		if (self.le_c()) {
			bool previous_narrow = n.narrow;
			n.narrow = true;
			self.step_lfsr();
			n.narrow = previous_narrow;
			if ((new & 0xF0) <= 0x20 && glitch_bit && (effective & 8) == 0) {
				self.step_lfsr();
				n.lfsr &= ~(n.narrow ? 0x4040 : 0x4000);
				n.lfsr |= (n.lfsr & (n.narrow ? 0x2020 : 0x2000)) << 1;
			}
		} else {
			self.step_lfsr();
		}
	} else if (self.le_c()) {
		if ((new & 0xF0) <= 0x20 && !glitch_bit && !new_bit && !old_bit && (effective & 8)) {
			self.step_lfsr();
		}
	}
	n.lfsr &= 0x7FFF;
}

const char[8] SWEEP_CORRUPTION = { 7, 7, 5, 7, 3, 3, 5, 7 };

fn void Apu.nr10_write_glitch(&self, char value) {
	if (self.le_c()) {
		// DMG and CGB up to C (the double speed cases are a CGB-C's)
		bool ds = self.double_speed;
		if (self.sweep_calc_reload_timer == 1 && !self.lf_div) {
			// SameBoy: corruption as two of its CGB-Cs show it.
			if (ds) self.sweep_calc_countdown = SWEEP_CORRUPTION[self.sweep_calc_countdown & 7];
			return;
		}
		if (self.sweep_calc_reload_timer > 1) {
			if (ds) self.sweep_calc_countdown = value & 7;
			return;
		}
		if (self.sweep_calc_countdown) {
			bool zombie_step = (self.io[NR10] & 7) == 0
				? (self.lf_div != 0) != ds
				: ds && self.sweep_calc_countdown == 1;
			if (zombie_step) {
				self.sweep_calc_countdown--;
				if (self.sweep_calc_countdown <= 1) {
					self.sweep_calc_countdown = 0;
					self.sweep_calculation_done();
				}
			}
		}
		return;
	}
	if (self.sweep_calc_reload_timer == 2) {
		// The countdown just reloaded: reload it again.
		self.sweep_calc_countdown = value & 7;
		if (!self.sweep_calc_countdown) self.sweep_calc_reload_timer = 0;
	}
	if ((value & 7) && (self.io[NR10] & 7) == 0 && !self.lf_div && self.sweep_calc_countdown > 1) {
		self.sweep_calc_countdown--;
		if (!self.sweep_calc_countdown) self.sweep_calculation_done();
	}
}
