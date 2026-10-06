module wer;
import gameboy, display;

// A cartridge's piezo buzzer (Tamagotchi 3's call, mmu tama5.c3) in the
// sound: three short high beeps, square, over whatever the game plays.
// What the real one sounds like isn't documented; this is a generic piezo.
const int BUZZ_HZ    = 4000;
const int BUZZ_ON_MS = 70;
const int BUZZ_OFF_MS = 50;
const int BUZZ_BEEPS = 3;
const short BUZZ_LEVEL = 5000;

int buzz_pos = -1;   // sample frames into the chirp, -1: silent
bool was_calling;

// After a frame: new calls start a chirp (and say so the first time).
fn void buzzer_update(gameboy::GameBoy* g) {
	if (g.buzzes()) buzz_pos = 0;
	bool now = g.calling();
	if (now && !was_calling) notice.show("Your Tamagotchi is calling");
	was_calling = now;
}

// Mixed into `n` interleaved stereo samples at `rate`.
fn void buzzer_mix(short[] samples, uint n, uint rate) {
	if (buzz_pos < 0) return;
	int on = (int)rate * BUZZ_ON_MS / 1000;
	int period = on + (int)rate * BUZZ_OFF_MS / 1000;
	int half_wave = (int)rate / (BUZZ_HZ * 2);
	for (uint i = 0; i + 1 < n; i += 2) {
		if (buzz_pos >= period * BUZZ_BEEPS) {
			buzz_pos = -1;
			return;
		}
		if (buzz_pos % period < on) {
			short v = (buzz_pos / half_wave) & 1 ? BUZZ_LEVEL : -BUZZ_LEVEL;
			samples[i] = clamp_add(samples[i], v);
			samples[i + 1] = clamp_add(samples[i + 1], v);
		}
		buzz_pos++;
	}
}

fn short clamp_add(short a, short b) {
	int s = (int)a + b;
	return (short)(s > 32767 ? 32767 : s < -32768 ? -32768 : s);
}
