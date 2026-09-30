module apu;

// Channels 1 and 2. Counters run on the APU's 2 MHz clock; the duty step
// period is (2048 - frequency) * 2 of those ticks, as on hardware.
struct Square {
	int  pulse_length;         // length counter (NRx1), in 256 Hz ticks
	int  current_volume;
	int  volume_countdown;     // envelope period countdown (NRx2)
	int  current_sample_index; // duty step 0-7
	bool sample_surpressed;    // just started: output 0 until the first step
	int  sample_countdown;     // 2 MHz ticks to the next duty step (a 16-bit counter)
	int  sample_length;        // frequency (NRx3/NRx4)
	bool length_enabled;
	EnvClock env;
	int  delay;                // start delay after a trigger
	bool did_tick;
	bool just_reloaded;        // the countdown reloaded in the last tick
}

const char[32] DUTY_TABLE = {
	0, 0, 0, 0, 0, 0, 0, 1,
	1, 0, 0, 0, 0, 0, 0, 1,
	1, 0, 0, 0, 0, 1, 1, 1,
	0, 1, 1, 1, 1, 1, 1, 0,
};

fn int Square.reload(&self) => (self.sample_length ^ 0x7FF) * 2 + 1;
