module joypad;

// Scripted button presses (--input=...), to play a game the same way every
// time: comma-separated FRAME:KEYS, KEYS one or more of a, b, start, select,
// up, down, left, right joined by '+', held for 6 frames or *N:
//   --input=400:down,460:a,600:start*30,900:a+b
// FRAME counts the frames the game has run, from 0.

const uint SCRIPT_HOLD = 6;
const usz SCRIPT_MAX = 256;

struct Press {
	ulong from;
	ulong until;    // the first frame without it
	char buttons;
	char dpad;
}

struct Script {
	Press[SCRIPT_MAX] presses;
	usz len;
}

faultdef NOT_A_SCRIPT;

fn bool? key_bits(String name, char* buttons, char* dpad) {
	switch (name) {
		case "a":      *buttons |= BTN_A;
		case "b":      *buttons |= BTN_B;
		case "start":  *buttons |= BTN_START;
		case "select": *buttons |= BTN_SELECT;
		case "up":     *dpad |= PAD_UP;
		case "down":   *dpad |= PAD_DOWN;
		case "left":   *dpad |= PAD_LEFT;
		case "right":  *dpad |= PAD_RIGHT;
		default:       return NOT_A_SCRIPT~;
	}
	return true;
}

fn Script? parse_script(String text) {
	Script s;
	foreach (item : text.tsplit(",")) {
		item = item.trim();
		if (!item.len) continue;
		if (s.len == SCRIPT_MAX) return NOT_A_SCRIPT~;
		String[] at = item.tsplit(":");
		if (at.len != 2) return NOT_A_SCRIPT~;
		Press p;
		p.from = at[0].trim().to_ulong() ?? NOT_A_SCRIPT~!;
		String keys = at[1].trim();
		ulong hold = SCRIPT_HOLD;
		String[] held = keys.tsplit("*");
		if (held.len > 2) return NOT_A_SCRIPT~;
		if (held.len == 2) {
			keys = held[0];
			hold = held[1].trim().to_ulong() ?? NOT_A_SCRIPT~!;
			if (!hold) return NOT_A_SCRIPT~;
		}
		foreach (k : keys.tsplit("+")) key_bits(k.trim(), &p.buttons, &p.dpad)!;
		p.until = p.from + hold;
		s.presses[s.len++] = p;
	}
	return s;
}

// What the script holds down at `frame`, added to `buttons` and `dpad`.
fn void Script.at(&self, ulong frame, char* buttons, char* dpad) {
	foreach (p : self.presses[:self.len]) {
		if (frame < p.from || frame >= p.until) continue;
		*buttons |= p.buttons;
		*dpad |= p.dpad;
	}
}
