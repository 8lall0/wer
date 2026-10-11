module joypad;
import mmu;

// Scripted button presses (--input=...), to play a game the same way every
// time: comma-separated FRAME:KEYS, KEYS one or more of a, b, start, select,
// up, down, left, right joined by '+', held for 6 frames or *N:
//   --input=400:down,460:a,600:start*30,900:a+b
// FRAME counts the frames the game has run, from 0.
//
// An item can also work a device on the link port, as its menu line does:
//   card=DIGITS   swipe a 13-digit card (Barcode Boy, Bardigun reader)
//   wave=N        wave character N, 1-70 (Full Changer)
//   watts=N       send N watts, 0-999 (Pokémon Pikachu 2)
//   gift=N        send gift N, 0-53 (Pocket Sakura)
//   --input=600:start,11020:card=4900363432103

const uint SCRIPT_HOLD = 6;
const usz SCRIPT_MAX = 256;

struct Press {
	ulong from;
	ulong until;    // the first frame without it
	char buttons;
	char dpad;
}

enum ActionKind : char {
	CARD,
	WAVE,
	WATTS,
	GIFT,
}

struct Action {
	ulong      frame;
	ActionKind kind;
	int        number;    // wave, watts, gift
	char[13]   digits;    // card
}

const usz ACTIONS_MAX = 32;

struct Script {
	Press[SCRIPT_MAX] presses;
	usz len;
	Action[ACTIONS_MAX] actions;
	usz actions_len;
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
		ulong from = at[0].trim().to_ulong() ?? NOT_A_SCRIPT~!;
		String keys = at[1].trim();
		if (keys.contains("=")) {
			if (s.actions_len == ACTIONS_MAX) return NOT_A_SCRIPT~;
			s.actions[s.actions_len++] = parse_action(from, keys)!;
			continue;
		}
		Press p;
		p.from = from;
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

fn Action? parse_action(ulong frame, String text) {
	String[] kv = text.tsplit("=");
	if (kv.len != 2) return NOT_A_SCRIPT~;
	String name = kv[0].trim();
	String arg = kv[1].trim();
	Action a = { .frame = frame };
	if (name == "card") {
		if (arg.len != 13) return NOT_A_SCRIPT~;
		foreach (i, c : arg) {
			if (c < '0' || c > '9') return NOT_A_SCRIPT~;
			a.digits[i] = c;
		}
		a.kind = CARD;
		return a;
	}
	a.number = arg.to_int() ?? NOT_A_SCRIPT~!;
	switch (name) {
		case "wave":
			if (a.number < 1 || a.number > mmu::CHANGER_NAMES.len) return NOT_A_SCRIPT~;
			a.kind = WAVE;
		case "watts":
			if (a.number < 0 || a.number > 999) return NOT_A_SCRIPT~;
			a.kind = WATTS;
		case "gift":
			if (a.number < 0 || a.number >= mmu::SAKURA_EVENTS) return NOT_A_SCRIPT~;
			a.kind = GIFT;
		default:
			return NOT_A_SCRIPT~;
	}
	return a;
}

// What the script holds down at `frame`, added to `buttons` and `dpad`.
fn void Script.at(&self, ulong frame, char* buttons, char* dpad) {
	foreach (p : self.presses[:self.len]) {
		if (frame < p.from || frame >= p.until) continue;
		*buttons |= p.buttons;
		*dpad |= p.dpad;
	}
}
