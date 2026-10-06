module display;
import std::math;

// Frame blending: the Game Boy's LCD answers slowly, so each frame shows a
// little of the one before; games that flicker objects on alternate frames
// (for transparency, or more than 10 per line) count on it. Each shown frame
// is mixed with the last one in linear light, as SameBoy's shader does:
// SIMPLE half and half; ACCURATE a third and two thirds on alternate rows,
// swapping every frame (SameBoy's model of the LCD), SIMPLE on an SGB (a TV).
enum Blend : char {
	OFF,
	SIMPLE,
	ACCURATE,
}

const String[3] BLEND_NAMES  = { "off", "simple", "accurate" };
const String[3] BLEND_LABELS = { "Off", "Simple", "Accurate" };

const float BLEND_BIAS = 1.0f / 3.0f;

// 8-bit (gamma 2.2) <-> linear.
float[256] to_linear;
char[4096] from_linear;
bool blend_tables_ready;

fn void make_blend_tables() {
	for (int i = 0; i < 256; i++) to_linear[i] = (float)math::pow(i / 255.0, 2.2);
	for (int i = 0; i < 4096; i++) from_linear[i] = (char)math::round(math::pow(i / 4095.0, 1 / 2.2) * 255);
	blend_tables_ready = true;
}

// The frame to show for `rgb`: mixed with the previous one (kept raw).
fn char[] Display.blended(&self, char[] rgb, int w, int h) {
	usz n = (usz)(w * h * 3);
	char[] out = rgb;
	if (self.blend != OFF && self.prev_w == w && self.prev_h == h) {
		if (!blend_tables_ready) make_blend_tables();
		out = self.mixed[:n];
		for (int y = 0; y < h; y++) {
			float ratio = 0.5f; // of the previous frame
			if (self.blend == ACCURATE && !self.blend_simple) {
				ratio = ((y & 1) == 0) != self.odd_frame ? BLEND_BIAS : 1 - BLEND_BIAS;
			}
			usz row = (usz)(y * w * 3);
			for (usz i = row; i < row + (usz)(w * 3); i++) {
				float v = to_linear[rgb[i]] * (1 - ratio) + to_linear[self.prev[i]] * ratio;
				out[i] = from_linear[(int)(v * 4095 + 0.5f)];
			}
		}
	}
	self.prev[:n] = rgb[:n];
	self.prev_w = w;
	self.prev_h = h;
	return out;
}
