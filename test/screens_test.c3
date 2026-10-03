module screens_test;

import gameboy, mmu, parallel;
import std::io, std::io::file, std::collections::list;
import std::core::test;

// Small screenshot-checked test ROMs from c-sp/game-boy-test-roms:
// cgb-acid-hell, bully, strikethrough, turtle-tests, scribbltests and
// little-things-gb's firstwhite. Each runs a number of frames (or until
// LD B,B) and the picture must match the reference exactly, with the
// collection's colours: DMG shades $FF/$AA/$55/$00, CGB channels (X << 3) |
// (X >> 2), and fixed palettes for a DMG game on a CGB.
//
// Not vendored; fetch them with
//   scripts/fetch-screens.sh
// into test/screens/ . With none present the test prints one line and passes.
//   c3c test && ./build/testrun --test-nocapture --test-filter screens

const String DIR = "test/screens/";
const ulong TIMEOUT = 4194304UL / 4 * 30;
const int PIXELS = 160 * 144;
const char[4] DMG_SHADE = { 0xFF, 0xAA, 0x55, 0x00 };
// The collection's colours for a DMG game on a CGB (RGB555): BG and objects.
const ushort[4] NCM_BG = { 0x7FFF, 0x1BEF, 0x6180, 0x0000 };
const ushort[4] NCM_OBJ = { 0x7FFF, 0x421F, 0x1CF2, 0x0000 };

// Failing: strikethrough draws a sprite from what the OAM scan reads while
// an OAM DMA writes OAM (neither Gambatte's nor SameBoy's model gives it).
const String[*] KNOWN_FAIL = {
	"dmg strikethrough/strikethrough.gb",
	"cgb strikethrough/strikethrough.gb",
};

struct Check {
	bool   cgb;
	char   rev;
	int    frames;
	String rom;
	String ref;
	int    wrong;
	bool   done;
	bool   missing;
}

fn mmu::CgbRevision revision(char c) {
	switch (c) {
		case 'b': return B;
		case 'd': return D;
		case 'e': return E;
		default:  return C;
	}
}

fn void Check.run(&self) {
	char[]? data = file::load_temp(DIR.tconcat(self.rom));
	char[]? ref = file::load_temp(DIR.tconcat(self.ref));
	if (catch data, ref) {
		self.missing = true;
		return;
	}
	gameboy::GameBoy gb = gameboy::new(false, self.cgb ? mmu::Model.CGB : mmu::Model.DMG);
	defer gb.destroy();
	gb.set_cgb_revision(revision(self.rev));
	gb.load_rom(data);
	if (gb.mmu.cart) gb.mmu.cart.has_battery = false;
	if (self.cgb && !gb.mmu.cgb_mode) {
		for (int i = 0; i < 4; i++) {
			gb.mmu.ppu.bg_pal[i * 2] = (char)NCM_BG[i];
			gb.mmu.ppu.bg_pal[i * 2 + 1] = (char)(NCM_BG[i] >> 8);
			for (int o = 0; o < 2; o++) {
				gb.mmu.ppu.obj_pal[o * 8 + i * 2] = (char)NCM_OBJ[i];
				gb.mmu.ppu.obj_pal[o * 8 + i * 2 + 1] = (char)(NCM_OBJ[i] >> 8);
			}
		}
	}
	if (self.frames > 0) {
		for (int i = 0; i < self.frames; i++) gb.run_frame();
	} else {
		ulong limit = gb.cpu.clk + TIMEOUT;
		while (gb.mmu.get(gb.cpu.pc) != 0x40) { // LD B,B
			if (gb.cpu.clk >= limit) return;
			gb.step();
		}
	}
	if (ref.len < PIXELS * 3) return;
	char[] rgb = mem::new_array(char, gameboy::MAX_FRAME_RGB);
	defer free(rgb.ptr);
	if (self.cgb) {
		gb.frame_rgb(rgb, {});
	} else {
		char[] fb = gb.framebuffer();
		for (int i = 0; i < PIXELS; i++) rgb[i * 3] = rgb[i * 3 + 1] = rgb[i * 3 + 2] = DMG_SHADE[fb[i] & 3];
	}
	for (int i = 0; i < PIXELS; i++) {
		if (rgb[i * 3:3] != ref[i * 3:3]) self.wrong++;
	}
	self.done = true;
}

fn String Check.id(&self) => string::tformat("%s %s", self.cgb ? "cgb" : "dmg", self.rom);

fn void run_job(void* ctx, usz i) {
	((Check*)ctx)[i].run();
}

fn void run_all() @test
{
	char[]? index = file::load_temp(DIR.tconcat("index.txt"));
	if (catch index) {
		io::eprintn("  screens: no ROMs in test/screens — run scripts/fetch-screens.sh");
		return;
	}
	List{Check} list;
	list.tinit();
	foreach (line : ((String)index).tsplit("\n")) {
		String[] f = line.trim().tsplit(" ");
		if (f.len < 5) continue;
		list.push({ .cgb = f[0] == "cgb", .rev = f[1][0], .frames = f[2].to_int() ?? 30, .rom = f[3], .ref = f[4] });
	}
	Check[] checks = list.array_view();
	parallel::run(checks.len, &run_job, checks.ptr);

	uint present;
	uint passed;
	uint regressed;
	foreach (&c : checks) {
		if (c.missing) continue;
		present++;
		String id = c.id();
		bool known = false;
		foreach (k : KNOWN_FAIL) if (k == id) known = true;
		if (c.done && c.wrong == 0) {
			passed++;
			if (known) io::eprintfn("  NEW PASS  %s  (remove it from KNOWN_FAIL)", id);
		} else if (!known) {
			regressed++;
			io::eprintfn("  REGRESSED %s (%d px)", id, c.wrong);
		}
	}
	io::eprintfn("  screens: %d/%d pass, %d regressed", passed, present, regressed);
	test::@check(regressed == 0, "a screenshot test regressed (see lines above)");
}
