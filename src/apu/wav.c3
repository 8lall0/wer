module apu;

// Channel 3 (wave). Timing follows the hardware in 2 MHz ticks, as needed
// for the DMG's wave RAM behaviour while playing (Blargg dmg_sound 09, 10,
// 12; modelled after SameBoy):
//
// - `sample_countdown` runs down once per tick; when it underflows, the
//   position advances and the channel fetches that byte of wave RAM.
// - A CPU access to wave RAM while the channel plays reaches the byte being
//   played only if that fetch happened in the very last tick (`just_read`);
//   otherwise reads give $FF and writes are lost (DMG; a CGB always reaches it).
// - Triggering loads the countdown with 3 extra ticks and restarts at
//   position 0, but keeps the current sample until the next fetch.
struct Wave {
	bool enable;               // NR30 bit 7 (the DAC)
	int  pulse_length;
	int  shift;                // NR32: 4 = mute, else right shift
	int  sample_length;
	bool length_enabled;
	int  sample_countdown;
	int  current_sample_index; // 0..31, two per byte, high nibble first
	char current_sample_byte;
	bool just_read;
}

const int[4] WAVE_SHIFT = { 4, 0, 1, 2 };
