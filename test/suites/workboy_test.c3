module workboy_suite;

import gameboy, mmu;
import std::io, std::io::file, std::os::env, std::hash::crc32;
import std::core::test;

// The WorkBoy (link/workboy.c3) with its program: the README's steps typed
// in, each screen checked (its pixels' CRC). The clock is fixed, so every
// run draws the same. Needs the program, which isn't in the repository:
// resources/WorkBoy (USA) (Proto).gb; without it the test passes with a
// note. WER_WORKBOY_SHOTS=DIR also writes each step's screen there (.ppm).

const String ROM = "resources/WorkBoy (USA) (Proto).gb";

// 2026-10-11 (a Sunday) 09:30:00, local time.
const long CLOCK = 20737 * 86400 + 9 * 3600 + 30 * 60;

struct Step {
	int    frame;   // typed at the start of this frame
	String keys;    // characters, or {F1}..{F9} {ESC} {ENTER} {DOWN} ...
	String shows;   // what the screen shows 90 frames later
	uint   crc;     // ... its pixels' CRC (0: print it, for a new step)
}

const Step[*] STEPS = {
	{ 600,  "n",       "first start, home city: the next one (London Inner)", 0x2dd1f9e3 },
	{ 700,  "p",       "the one before (Leeds)", 0xfe8917f4 },
	{ 800,  "s",       "the city picked: the main menu", 0x959aaf0b },
	{ 900,  "{F1}",    "the clock (SUN 11/10/26 09:30)", 0xc08f59e7 },
	{ 1000, "{ESC}",   "the main menu", 0xf0f80271 },
	{ 1100, "{F4}",    "the calculator", 0xecd4a1b7 },
	{ 1200, "12+30=",  "12 + 30 = 42", 0x1aafdc57 },
	{ 1300, "{ESC}{F6}", "conversion: To Metric / From Metric", 0xf40b6761 },
	{ 1400, "{DOWN}",  "From Metric picked", 0x14289e78 },
	{ 1500, "{ENTER}", "From Metric's list", 0xf2add9fc },
	{ 1600, "{ESC}",   "back to the main menu", 0xf7aceffd },
};

fn void type_keys(mmu::WorkBoy* w, String keys) {
	for (usz i = 0; i < keys.len; i++) {
		if (keys[i] != '{') {
			w.press(mmu::workboy_key(keys[i]));
			continue;
		}
		usz end = i;
		while (keys[end] != '}') end++;
		String name = keys[i + 1 .. end - 1];
		i = end;
		switch {
			case name.len == 2 && name[0] == 'F': w.press((char)(mmu::WORKBOY_CLOCK + name[1] - '1'));
			case name == "ESC":   w.press(mmu::WORKBOY_ESCAPE);
			case name == "ENTER": w.press(mmu::WORKBOY_ENTER);
			case name == "BS":    w.press(mmu::WORKBOY_BACKSPACE);
			case name == "UP":    w.press(mmu::WORKBOY_UP);
			case name == "DOWN":  w.press(mmu::WORKBOY_DOWN);
			case name == "LEFT":  w.press(mmu::WORKBOY_LEFT);
			case name == "RIGHT": w.press(mmu::WORKBOY_RIGHT);
			default: unreachable("no key {%s}", name);
		}
	}
}

fn void the_workboy_program() @test {
	char[]? rom = file::load_temp(ROM);
	if (catch rom) {
		io::printn("  (the WorkBoy program not in resources/: WorkBoy not tested with it)");
		return;
	}
	String shots = env::tget_var("WER_WORKBOY_SHOTS") ?? "";
	gameboy::GameBoy gb = gameboy::new(false, DMG);
	defer gb.destroy();
	gb.load_rom(rom);
	gb.mmu.cart.has_battery = false;
	mmu::WorkBoy* w = mem::new(mmu::WorkBoy);
	defer free(w);
	w.init(0);
	w.fixed_now = CLOCK;
	mmu::Link l;
	gb.mmu.connect_workboy(&l, w);

	char[] rgb = mem::temp_array(char, gameboy::MAX_FRAME_RGB);
	char[12] colors = { 0xFF, 0xFF, 0xFF, 0xAA, 0xAA, 0xAA, 0x55, 0x55, 0x55, 0, 0, 0 };
	uint last;
	int frame;
	foreach (s : STEPS) {
		while (frame < s.frame) { gb.run_frame(); frame++; }
		type_keys(w, s.keys);
		while (frame < s.frame + 90) { gb.run_frame(); frame++; }
		gameboy::FrameSize size = gb.frame_rgb(rgb, colors);
		char[] picture = rgb[:size.w * size.h * 3];
		uint crc = crc32::hash(picture);
		if (shots.len) {
			String path = string::tformat("%s/workboy-%d.ppm", shots, s.frame);
			String head = string::tformat("P6\n%d %d\n255\n", size.w, size.h);
			file::save(path, head.tconcat((String)picture))!!;
			io::printfn("  %s: %s", path, s.shows);
		}
		test::@check(w.active(), "the program talks to the keyboard");
		test::@check(crc != last, "%s: the screen changed", s.shows);
		if (s.crc) {
			test::@check(crc == s.crc, "%s: the screen (CRC %08x, not %08x)", s.shows, crc, s.crc);
		} else {
			io::printfn("  %s: %08x", s.shows, crc);
		}
		last = crc;
	}
}
