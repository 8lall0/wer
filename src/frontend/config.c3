module config;
import gameboy, display;

import std::io, std::io::file, std::io::path, std::os::env;

// Settings kept between runs, in ~/.wer/wer.conf:
//
//   # comment
//   mode = sgb
//   palette = 1-A
//   scale = 3
//   key.a = Z
//   pad.a = b
//
// Keys are SDL scancode names ("Z", "Right Shift", "Return"), gamepad
// buttons SDL gamepad button names ("a" = bottom face button, "b" = right
// face button, "back", "start", "dpup", ...). This module only stores the
// names; main.c3 turns them into SDL codes. The command line overrides the
// file for one run.

const String DIR  = ".wer";
const String FILE = "wer.conf";

// The Game Boy buttons, in the order of Config.keys / Config.pads.
enum Button : char {
	A,
	B,
	SELECT,
	START,
	UP,
	DOWN,
	LEFT,
	RIGHT,
}

const String[8] BUTTON_NAMES = { "a", "b", "select", "start", "up", "down", "left", "right" };

// Defaults: the keys wer always used; on a gamepad the Game Boy's A/B sit
// where they are on a Nintendo pad (A right, B bottom).
const String[8] DEFAULT_KEYS = { "Z", "X", "Right Shift", "Return", "Up", "Down", "Left", "Right" };
const String[8] DEFAULT_PADS = { "b", "a", "back", "start", "dpup", "dpdown", "dpleft", "dpright" };

// Hotkeys, also rebindable (key.fast, pad.rewind, ...); "none": no gamepad
// button.
enum Hotkey : char {
	FAST,       // held: fast forward
	REWIND,     // held: back in time
	PAUSE,
	ADVANCE,    // one frame while paused
	SCREENSHOT,
	DEBUG,      // the debugger's window (desktop)
}

const String[6] HOTKEY_NAMES     = { "fast", "rewind", "pause", "advance", "screenshot", "debug" };
const String[6] DEFAULT_HOT_KEYS = { "Tab", "R", "P", "N", "F12", "F10" };
const String[6] DEFAULT_HOT_PADS = { "rightshoulder", "leftshoulder", "none", "none", "none", "none" };

struct Config {
	String    mode;     // "dmg", "dmg-0", "mgb", "sgb", "sgb2", "cgb" (= "cgb-c"), "cgb-0" ... "cgb-e"
	String    palette;  // SGB palette "1-A" .. "4-H"
	String    color;    // CGB/SGB colour correction: gameboy::COLOR_NAMES
	String    blend;    // frame blending: "off", "simple", "accurate"
	String    filter;   // screen filter: display::FILTER_NAMES
	int       scale;    // 1-4
	String    link;     // the address the link cable last joined ("host" or "host:port")
	String[8] keys;
	String[8] pads;
	String[6] hot_keys;
	String[6] hot_pads;
}

// Every String in a Config is a heap copy owned by it (see set / free).
fn Config defaults() {
	Config c;
	c.mode = "dmg".copy(mem);
	c.palette = "1-A".copy(mem);
	c.color = "balanced".copy(mem);
	c.blend = "off".copy(mem);
	c.filter = "off".copy(mem);
	c.scale = 3;
	c.link = "".copy(mem);
	foreach (i, k : DEFAULT_KEYS) c.keys[i] = k.copy(mem);
	foreach (i, p : DEFAULT_PADS) c.pads[i] = p.copy(mem);
	foreach (i, k : DEFAULT_HOT_KEYS) c.hot_keys[i] = k.copy(mem);
	foreach (i, p : DEFAULT_HOT_PADS) c.hot_pads[i] = p.copy(mem);
	return c;
}

fn void Config.free(&self) {
	free(self.mode.ptr);
	free(self.palette.ptr);
	free(self.color.ptr);
	free(self.blend.ptr);
	free(self.filter.ptr);
	free(self.link.ptr);
	foreach (k : self.keys) free(k.ptr);
	foreach (p : self.pads) free(p.ptr);
	foreach (k : self.hot_keys) free(k.ptr);
	foreach (p : self.hot_pads) free(p.ptr);
	*self = {};
}

fn void replace(String* field, String value) {
	free(field.ptr);
	*field = value.copy(mem);
}

// Apply one `name = value` setting. False for an unknown name or bad value.
fn bool Config.set(&self, String name, String value) {
	switch {
		case name == "mode":
			switch (value) {
				case "dmg": case "dmg-0": case "mgb": case "sgb": case "sgb2": case "cgb":
				case "cgb-0": case "cgb-a": case "cgb-b": case "cgb-c": case "cgb-d": case "cgb-e": case "gba":
					break;
				default:
					return false;
			}
			replace(&self.mode, value);
		case name == "palette":
			replace(&self.palette, value);
		case name == "color":
			if (color_index(value) < 0) return false;
			replace(&self.color, value);
		case name == "blend":
			if (blend_index(value) < 0) return false;
			replace(&self.blend, value);
		case name == "filter":
			if (display::filter_index(value) < 0) return false;
			replace(&self.filter, value);
		case name == "link":
			replace(&self.link, value);
		case name == "scale":
			int? n = value.to_int();
			if (catch n) return false;
			if (n < 1 || n > 4) return false;
			self.scale = n;
		case name.starts_with("key."):
			if (value.len == 0) return false;
			int b = button_index(name[4..]);
			int h = hotkey_index(name[4..]);
			if (b >= 0) {
				replace(&self.keys[b], value);
			} else if (h >= 0) {
				replace(&self.hot_keys[h], value);
			} else {
				return false;
			}
		case name.starts_with("pad."):
			if (value.len == 0) return false;
			int b = button_index(name[4..]);
			int h = hotkey_index(name[4..]);
			if (b >= 0) {
				replace(&self.pads[b], value);
			} else if (h >= 0) {
				replace(&self.hot_pads[h], value);
			} else {
				return false;
			}
		default:
			return false;
	}
	return true;
}

fn int color_index(String name) {
	foreach (i, n : gameboy::COLOR_NAMES) {
		if (n == name) return (int)i;
	}
	return -1;
}

fn int blend_index(String name) {
	switch (name) {
		case "off":      return 0;
		case "simple":   return 1;
		case "accurate": return 2;
		default:         return -1;
	}
}

fn int hotkey_index(String name) {
	foreach (i, n : HOTKEY_NAMES) {
		if (n == name) return (int)i;
	}
	return -1;
}

fn int button_index(String name) {
	foreach (i, n : BUTTON_NAMES) {
		if (n == name) return (int)i;
	}
	return -1;
}

// Read settings from config file text; bad lines are reported and skipped.
fn void Config.parse(&self, String text, String origin = FILE) {
	foreach (lineno, raw : text.tsplit("\n")) {
		String line = raw.trim();
		if (line.len == 0 || line[0] == '#') continue;
		sz? eq = line.index_of_char('=');
		if (catch eq) {
			io::eprintfn("%s:%d: expected `name = value`", origin, lineno + 1);
			continue;
		}
		String name = line[:eq].trim();
		String value = line[eq + 1..].trim();
		if (!self.set(name, value)) io::eprintfn("%s:%d: ignoring `%s`", origin, lineno + 1, line);
	}
}

// The file contents for these settings (comments in the old file are not kept).
fn String Config.to_text(&self, Allocator allocator) {
	DString out;
	out.init(allocator);
	out.append("# wer settings; rewritten when you change them in the menu.\n");
	out.append("# key.* are SDL key names, pad.* SDL gamepad button names\n");
	out.append("# (a = bottom, b = right, x = left, y = top face button).\n");
	out.appendf("mode = %s\n", self.mode);
	out.appendf("palette = %s\n", self.palette);
	out.appendf("color = %s\n", self.color);
	out.appendf("blend = %s\n", self.blend);
	out.appendf("filter = %s\n", self.filter);
	out.appendf("scale = %d\n", self.scale);
	if (self.link.len) out.appendf("link = %s\n", self.link);
	foreach (i, n : BUTTON_NAMES) out.appendf("key.%s = %s\n", n, self.keys[i]);
	foreach (i, n : BUTTON_NAMES) out.appendf("pad.%s = %s\n", n, self.pads[i]);
	foreach (i, n : HOTKEY_NAMES) out.appendf("key.%s = %s\n", n, self.hot_keys[i]);
	foreach (i, n : HOTKEY_NAMES) out.appendf("pad.%s = %s\n", n, self.hot_pads[i]);
	return out.str_view();
}

// Where wer.conf goes without a home directory (Android: the app's folder,
// ending in '/').
String fallback_dir;

// ~/.wer/wer.conf (%USERPROFILE%\.wer on Windows), else in fallback_dir, or
// "" without either.
fn String tpath() {
	String? home = env::tget_var("HOME");
	if (catch home) home = env::tget_var("USERPROFILE");
	if (catch home) return fallback_dir.len ? fallback_dir.tconcat(FILE) : "";
	return string::tformat("%s/%s/%s", home, DIR, FILE);
}

// Defaults, overridden by ~/.wer/wer.conf if there is one.
fn Config load() => load_from(tpath());

fn Config load_from(String p) {
	Config c = defaults();
	if (p.len == 0) return c;
	char[]? text = file::load_temp(p);
	if (catch text) return c; // no file yet
	c.parse((String)text, p);
	return c;
}

// Write ~/.wer/wer.conf, creating ~/.wer if needed.
fn void? Config.save(&self) => self.save_to(tpath());

fn void? Config.save_to(&self, String p) {
	if (p.len == 0) return;
	sz? slash = p.rindex_of_char('/');
	if (try slash) {
		String dir = p[:slash];
		if (dir.len && !file::is_dir(dir)) path::mkdir(dir, true)!;
	}
	@pool() {
		file::save(p, self.to_text(tmem))!;
	};
}
