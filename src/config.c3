module config;

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

struct Config {
	String    mode;     // "dmg", "sgb", "sgb2", "cgb" (= "cgb-c"), "cgb-0" ... "cgb-e"
	String    palette;  // SGB palette "1-A" .. "4-H"
	int       scale;    // 1-4
	String[8] keys;
	String[8] pads;
}

// Every String in a Config is a heap copy owned by it (see set / free).
fn Config defaults() {
	Config c;
	c.mode = "dmg".copy(mem);
	c.palette = "1-A".copy(mem);
	c.scale = 3;
	foreach (i, k : DEFAULT_KEYS) c.keys[i] = k.copy(mem);
	foreach (i, p : DEFAULT_PADS) c.pads[i] = p.copy(mem);
	return c;
}

fn void Config.free(&self) {
	free(self.mode.ptr);
	free(self.palette.ptr);
	foreach (k : self.keys) free(k.ptr);
	foreach (p : self.pads) free(p.ptr);
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
				case "dmg": case "sgb": case "sgb2": case "cgb":
				case "cgb-0": case "cgb-a": case "cgb-b": case "cgb-c": case "cgb-d": case "cgb-e":
					break;
				default:
					return false;
			}
			replace(&self.mode, value);
		case name == "palette":
			replace(&self.palette, value);
		case name == "scale":
			int? n = value.to_int();
			if (catch n) return false;
			if (n < 1 || n > 4) return false;
			self.scale = n;
		case name.starts_with("key."):
			int b = button_index(name[4..]);
			if (b < 0 || value.len == 0) return false;
			replace(&self.keys[b], value);
		case name.starts_with("pad."):
			int b = button_index(name[4..]);
			if (b < 0 || value.len == 0) return false;
			replace(&self.pads[b], value);
		default:
			return false;
	}
	return true;
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
	out.appendf("scale = %d\n", self.scale);
	foreach (i, n : BUTTON_NAMES) out.appendf("key.%s = %s\n", n, self.keys[i]);
	foreach (i, n : BUTTON_NAMES) out.appendf("pad.%s = %s\n", n, self.pads[i]);
	return out.str_view();
}

// ~/.wer/wer.conf, or "" when there is no home directory.
fn String tpath() {
	String? home = env::tget_var("HOME");
	if (catch home) return "";
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
