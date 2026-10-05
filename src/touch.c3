module display;
import sdl, joypad;

// On-screen controls for touch screens (Android): a D-pad, A, B, Select,
// Start and a menu button around the picture, multi-touch. They play like a
// gamepad: in the menu the D-pad moves, A and Start choose.

const int MAX_FINGERS = 10;

struct Finger {
	ulong id;
	float x;   // output pixels
	float y;
	bool  down;
}

// Control bits (Display.touch_held).
const ushort T_UP     = 0x001;
const ushort T_DOWN   = 0x002;
const ushort T_LEFT   = 0x004;
const ushort T_RIGHT  = 0x008;
const ushort T_A      = 0x010;
const ushort T_B      = 0x020;
const ushort T_SELECT = 0x040;
const ushort T_START  = 0x080;
const ushort T_MENU   = 0x100;

// Where things go on the output, in pixels.
struct Layout {
	sdl::FRect screen; // the picture
	sdl::FRect dpad;
	sdl::FRect a;
	sdl::FRect b;
	sdl::FRect select;
	sdl::FRect start;
	sdl::FRect menu;
}

fn sdl::FRect centered(float cx, float cy, float w, float h) => { cx - w / 2, cy - h / 2, w, h };

// Whole picture pixels when the room allows it, else the largest fit.
fn float fit_scale(float room_w, float room_h, float pw, float ph) {
	float s = room_w / pw < room_h / ph ? room_w / pw : room_h / ph;
	return s >= 1 ? (float)(int)s : s;
}

fn Layout Display.layout(&self) {
	int iw;
	int ih;
	sdl::get_render_output_size(self.renderer, &iw, &ih);
	float w = (float)iw;
	float h = (float)ih;
	float pw = (float)self.width;
	float ph = (float)self.height;
	Layout l;
	if (!self.touch_ui) {
		l.screen = { 0, 0, w, h };
		return l;
	}
	if (h >= w) {
		// Portrait: the picture across the top, the controls below it.
		float s = fit_scale(w, h * 0.55f, pw, ph);
		l.screen = { (w - pw * s) / 2, h * 0.04f, pw * s, ph * s };
		float top = l.screen.y + l.screen.h;
		float ch = h - top;
		float u = w / 7 < ch / 5 ? w / 7 : ch / 5;
		l.dpad   = centered(w * 0.25f, top + ch * 0.45f, 3 * u, 3 * u);
		l.a      = centered(w * 0.84f, top + ch * 0.38f, 1.3f * u, 1.3f * u);
		l.b      = centered(w * 0.64f, top + ch * 0.50f, 1.3f * u, 1.3f * u);
		l.select = centered(w * 0.36f, top + ch * 0.82f, 1.3f * u, 0.6f * u);
		l.start  = centered(w * 0.64f, top + ch * 0.82f, 1.3f * u, 0.6f * u);
		l.menu   = centered(w * 0.50f, top + 0.6f * u, 1.2f * u, 0.6f * u);
	} else {
		// Landscape: the picture in the middle, the controls at its sides
		// (over its edges if the sides are narrow).
		float s = fit_scale(w, h, pw, ph);
		l.screen = { (w - pw * s) / 2, (h - ph * s) / 2, pw * s, ph * s };
		float u = h / 6;
		float side = l.screen.x;
		float cx = side / 2 > 1.5f * u ? side / 2 : 1.5f * u;
		l.dpad   = centered(cx, h * 0.55f, 2.6f * u, 2.6f * u);
		l.a      = centered(w - cx + 0.6f * u, h * 0.48f, 1.2f * u, 1.2f * u);
		l.b      = centered(w - cx - 0.7f * u, h * 0.62f, 1.2f * u, 1.2f * u);
		l.select = centered(cx, h - 0.5f * u, 1.4f * u, 0.5f * u);
		l.start  = centered(w - cx, h - 0.5f * u, 1.4f * u, 0.5f * u);
		l.menu   = centered(w - 0.8f * u, 0.5f * u, 1.2f * u, 0.5f * u);
	}
	return l;
}

// A rectangle grown by `f` of its size on each side: fingers are blunt.
fn bool hits(sdl::FRect r, float x, float y, float f = 0.15f) {
	float gx = r.w * f;
	float gy = r.h * f;
	return x >= r.x - gx && x < r.x + r.w + gx && y >= r.y - gy && y < r.y + r.h + gy;
}

// The D-pad directions under a point (diagonals too), or 0.
fn ushort dpad_at(sdl::FRect r, float x, float y) {
	if (!hits(r, x, y, 0.25f)) return 0;
	float dx = x - (r.x + r.w / 2);
	float dy = y - (r.y + r.h / 2);
	float dead = r.w * 0.12f;
	float ax = dx < 0 ? -dx : dx;
	float ay = dy < 0 ? -dy : dy;
	ushort bits;
	if (ax > dead && ax >= ay * 0.5f) bits |= dx > 0 ? T_RIGHT : T_LEFT;
	if (ay > dead && ay >= ax * 0.5f) bits |= dy > 0 ? T_DOWN : T_UP;
	return bits;
}

// The controls under a point.
fn ushort controls_at(Layout* l, float x, float y) {
	ushort bits = dpad_at(l.dpad, x, y);
	if (hits(l.a, x, y)) bits |= T_A;
	if (hits(l.b, x, y)) bits |= T_B;
	if (hits(l.select, x, y)) bits |= T_SELECT;
	if (hits(l.start, x, y)) bits |= T_START;
	if (hits(l.menu, x, y)) bits |= T_MENU;
	return bits;
}

// What the fingers hold now.
fn ushort Display.touch_controls(&self, Layout* l) {
	ushort held;
	foreach (f : self.fingers) {
		if (f.down) held |= controls_at(l, f.x, f.y);
	}
	return held;
}

// A finger event: track where each finger is.
fn void Display.finger_event(&self, sdl::TouchFingerEvent* e) {
	int iw;
	int ih;
	sdl::get_render_output_size(self.renderer, &iw, &ih);
	int slot = -1;
	foreach (i, f : self.fingers) {
		if (f.down && f.id == e.finger_id) slot = (int)i;
	}
	if (e.type == sdl::EVENT_FINGER_UP || e.type == sdl::EVENT_FINGER_CANCELED) {
		if (slot >= 0) self.fingers[slot].down = false;
		return;
	}
	if (slot < 0) {
		foreach (i, f : self.fingers) {
			if (!f.down) { slot = (int)i; break; }
		}
		if (slot < 0) return;
	}
	self.fingers[slot] = { e.finger_id, e.x * (float)iw, e.y * (float)ih, true };
	if (e.type == sdl::EVENT_FINGER_DOWN) {
		Layout l = self.layout();
		self.touch_tap |= controls_at(&l, self.fingers[slot].x, self.fingers[slot].y);
	}
}

// Into a poll's Input: held Game Boy buttons, and presses as menu keys.
fn void Display.touch_input(&self, Input* in) {
	Layout l = self.layout();
	// A tap held for at least this poll, however short it was.
	ushort held = self.touch_controls(&l) | self.touch_tap;
	self.touch_tap = 0;
	ushort pressed = held & ~self.touch_held;
	self.touch_held = held;
	if (held & T_UP)     in.dpad |= joypad::PAD_UP;
	if (held & T_DOWN)   in.dpad |= joypad::PAD_DOWN;
	if (held & T_LEFT)   in.dpad |= joypad::PAD_LEFT;
	if (held & T_RIGHT)  in.dpad |= joypad::PAD_RIGHT;
	if (held & T_A)      in.buttons |= joypad::BTN_A;
	if (held & T_B)      in.buttons |= joypad::BTN_B;
	if (held & T_SELECT) in.buttons |= joypad::BTN_SELECT;
	if (held & T_START)  in.buttons |= joypad::BTN_START;
	if (pressed & T_UP)    in.pressed |= KEY_UP;
	if (pressed & T_DOWN)  in.pressed |= KEY_DOWN;
	if (pressed & T_LEFT)  in.pressed |= KEY_LEFT;
	if (pressed & T_RIGHT) in.pressed |= KEY_RIGHT;
	if (pressed & (T_A | T_START)) in.pressed |= KEY_ENTER;
	if (pressed & T_MENU)  in.pressed |= KEY_MENU;
}

// One control: a translucent panel, brighter while held, with its label.
fn void Display.draw_control(&self, sdl::FRect r, String label, bool held) {
	sdl::set_render_draw_color(self.renderer, 0xE0, 0xF8, 0xD0, held ? 0x90 : 0x38);
	sdl::render_fill_rect(self.renderer, &r);
	sdl::set_render_draw_color(self.renderer, 0xE0, 0xF8, 0xD0, 0xA0);
	sdl::render_rect(self.renderer, &r);
	if (!label.len) return;
	float font = r.h >= 48 ? (float)(int)(r.h / 24) : 1;
	sdl::set_render_scale(self.renderer, font, font);
	float tx = (r.x + r.w / 2) / font - (float)label.len * 4;
	float ty = (r.y + r.h / 2) / font - 4;
	sdl::render_debug_text(self.renderer, tx, ty, label.zstr_tcopy());
	sdl::set_render_scale(self.renderer, 1, 1);
}

fn void Display.draw_touch(&self, Layout* l) {
	sdl::set_render_draw_blend_mode(self.renderer, sdl::BLENDMODE_BLEND);
	ushort h = self.touch_held;
	// The D-pad as a cross.
	float t = l.dpad.w / 3;
	sdl::FRect d = l.dpad;
	self.draw_control({ d.x + t, d.y, t, t }, "", (h & T_UP) != 0);
	self.draw_control({ d.x + t, d.y + 2 * t, t, t }, "", (h & T_DOWN) != 0);
	self.draw_control({ d.x, d.y + t, t, t }, "", (h & T_LEFT) != 0);
	self.draw_control({ d.x + 2 * t, d.y + t, t, t }, "", (h & T_RIGHT) != 0);
	self.draw_control({ d.x + t, d.y + t, t, t }, "", false);
	self.draw_control(l.a, "A", (h & T_A) != 0);
	self.draw_control(l.b, "B", (h & T_B) != 0);
	self.draw_control(l.select, "SELECT", (h & T_SELECT) != 0);
	self.draw_control(l.start, "START", (h & T_START) != 0);
	self.draw_control(l.menu, "MENU", (h & T_MENU) != 0);
	sdl::set_render_draw_color(self.renderer, 0, 0, 0, 0xFF);
}
