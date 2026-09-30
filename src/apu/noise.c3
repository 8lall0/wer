module apu;

// Channel 4. A 14-bit counter runs at 2 MHz / divisor; a rising edge of the
// counter bit NR43 selects steps the LFSR.
struct Noise {
	int  pulse_length;
	int  current_volume;
	int  volume_countdown;
	int  lfsr;               // 15 bits
	bool narrow;             // 7-bit mode (NR43 bit 3)
	int  counter_countdown;  // 2 MHz ticks to the next counter step (8 bits)
	int  counter;            // 14 bits
	bool length_enabled;
	int  alignment;          // 2 MHz ticks run, for the start alignment quirks
	bool current_lfsr_sample;
	bool did_step_counter;
	bool countdown_reloaded; // the countdown reloaded in the last tick
	int  dmg_delayed_start;  // DMG: a trigger off the 1 MHz grid starts later
	EnvClock env;
}

// Category 2 NR43 glitches on a CGB-E, by old and new clock shift (octal
// index old*8 + new, both with bit 7 of the new value set).
const char[64] NR43_GLITCH = {
	0, 0, 4, 2, 2, 2, 0, 0,
	0, 0, 2, 4, 2, 2, 0, 0,
	1, 2, 0, 1, 5, 3, 0, 0,
	0, 0, 0, 0, 2, 2, 0, 0,
	0, 2, 2, 2, 0, 0, 0, 0,
	6, 0, 2, 2, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0,
};
