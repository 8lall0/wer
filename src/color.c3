module gameboy;
import std::math;

// How CGB (and SGB) colours become screen RGB. The Game Boy Color's LCD had
// no backlight: darker midtones, washed-out colours, green bleeding into
// blue; games chose their palettes for it. OFF shows the raw 15-bit colours
// ((X << 3) | (X >> 2), what the test references use); the others are
// SameBoy's colour correction (MIT, see LICENSE-sameboy): a measured curve
// per channel, green mixed with blue, and a contrast treatment.
enum ColorCorrection : char {
	OFF,
	BALANCED,  // SameBoy's default ("modern - balanced")
	ACCURATE,  // gamma-correct mixing
	BOOST,     // more contrast
	REDUCE,    // less contrast, closer to the real screen
	LOW,       // much less contrast
}

const String[6] COLOR_NAMES  = { "off", "balanced", "accurate", "boost", "reduce", "low" };
const String[6] COLOR_LABELS = { "Off", "Balanced", "Accurate", "Boost", "Reduce", "Low" };

// The front end's choice (tests leave it OFF).
ColorCorrection color_correction = OFF;

// A CGB LCD's response to a 5-bit channel (SameBoy; the SGB's is sgb::SGB_CURVE).
const char[32] CGB_CURVE = { 0, 6, 12, 20, 28, 36, 45, 56, 66, 76, 88, 100, 113, 125, 137, 149,
	161, 172, 182, 192, 202, 210, 218, 225, 232, 238, 243, 247, 250, 252, 254, 255 };
// A GBA's LCD (SameBoy): brighter darks, green mixed 5:1 with blue.
const char[32] AGB_CURVE = { 0, 3, 8, 14, 20, 26, 33, 40, 47, 54, 62, 70, 78, 86, 94, 103,
	112, 120, 129, 138, 147, 157, 166, 176, 185, 195, 205, 215, 225, 235, 245, 255 };
// One CGB colour through the correction (SameBoy GB_convert_rgb15), on a
// CGB's screen or a GBA's.
fn char[3] correct_cgb(ushort c, ColorCorrection mode, bool agb = false) {
	char[32]* curve = agb ? &AGB_CURVE : &CGB_CURVE;
	int r = (*curve)[c & 0x1F];
	int g = (*curve)[(c >> 5) & 0x1F];
	int b = (*curve)[(c >> 10) & 0x1F];
	int nr = r;
	int ng = g;
	int nb = b;
	if (g != b) {
		// The high-contrast modes mix less gamma-correctly, so blues don't wash out.
		double gamma = mode == BALANCED || mode == BOOST ? 1.6 : 2.2;
		double mixed = agb ? (math::pow(g / 255.0, gamma) * 5 + math::pow(b / 255.0, gamma)) / 6
			: (math::pow(g / 255.0, gamma) * 3 + math::pow(b / 255.0, gamma)) / 4;
		ng = (int)math::round(math::pow(mixed, 1 / gamma) * 255);
	}
	switch (mode) {
		case REDUCE:
		case LOW:
			r = nr;
			g = ng;
			b = nb;
			nr = nr * 15 / 16 + (g + b) / 32;
			ng = ng * 15 / 16 + (r + b) / 32;
			nb = nb * 15 / 16 + (r + g) / 32;
			if (mode == REDUCE) {
				nr = nr * (220 - 40) / 255 + 40;
				ng = ng * (224 - 36) / 255 + 36;
				nb = nb * (216 - 32) / 255 + 32;
			} else {
				nr = nr * (162 - 45) / 255 + 45;
				ng = ng * (167 - 41) / 255 + 41;
				nb = nb * (157 - 38) / 255 + 38;
			}
		case BOOST:
			int old_max = max(r, max(g, b));
			int new_max = max(nr, max(ng, nb));
			if (new_max != 0) {
				nr = nr * old_max / new_max;
				ng = ng * old_max / new_max;
				nb = nb * old_max / new_max;
			}
			int old_min = min(r, min(g, b));
			int new_min = min(nr, min(ng, nb));
			if (new_min != 0xFF) {
				nr = 0xFF - (0xFF - nr) * (0xFF - old_min) / (0xFF - new_min);
				ng = 0xFF - (0xFF - ng) * (0xFF - old_min) / (0xFF - new_min);
				nb = 0xFF - (0xFF - nb) * (0xFF - old_min) / (0xFF - new_min);
			}
		default:
			break;
	}
	return { (char)nr, (char)ng, (char)nb };
}

// Every 15-bit colour, for the current mode (built when it changes).
char[3][32768] cgb_lut;
ColorCorrection cgb_lut_mode = OFF;
bool cgb_lut_agb;

fn char[3]* cgb_colors(bool agb = false) {
	if (cgb_lut_mode != color_correction || cgb_lut_agb != agb) {
		for (int c = 0; c < 32768; c++) cgb_lut[c] = correct_cgb((ushort)c, color_correction, agb);
		cgb_lut_mode = color_correction;
		cgb_lut_agb = agb;
	}
	return &cgb_lut;
}
