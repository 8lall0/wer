module mealybug_test;

import gameboy, ppu, mmu, parallel;
import std::io, std::io::file, std::io::path;
import std::core::test;

// Mealybug Tearoom tests (https://github.com/mattcurrie/mealybug-tearoom-tests):
// PPU register writes during mode 3, which only a renderer that fetches and
// draws pixel by pixel gets right. Each ROM stops at LD B,B; the screen then
// must match the expected screenshot exactly.
//
// Not vendored; fetch with
//   scripts/fetch-mealybug.sh
// into test/mealybug/ . With no files present the test prints one line and
// passes. Entries marked `true` must keep passing; the others are reported,
// and our frame for each failure goes to test/mealybug/out/.
// To see the report:
//   c3c test && ./build/testrun --test-nocapture --test-filter mealybug

const String DIR = "test/mealybug/";
const ulong TIMEOUT = 4194304UL / 4 * 5; // 5 s of M-cycles
const int PIXELS = ppu::WIDTH * ppu::HEIGHT;

// Screen shade (0 = lightest) -> expected grey level.
const char[4] GRAY = { 0xFF, 0xAA, 0x55, 0x00 };

struct Rom {
	String name;
	bool   must_pass;
}

// Expected on a DMG (DMG-blob screenshots).
const Rom[*] DMG_ROMS = {
	{ "m2_win_en_toggle", true  },
	{ "m3_bgp_change", true  },
	{ "m3_bgp_change_sprites", true  },
	{ "m3_lcdc_bg_en_change", true  },
	{ "m3_lcdc_bg_map_change", true  },
	{ "m3_lcdc_obj_en_change", true  },
	{ "m3_lcdc_obj_en_change_variant", true  },
	{ "m3_lcdc_obj_size_change", true  },
	{ "m3_lcdc_obj_size_change_scx", true  },
	{ "m3_lcdc_tile_sel_change", true  },
	{ "m3_lcdc_tile_sel_win_change", true  },
	{ "m3_lcdc_win_en_change_multiple", true  },
	{ "m3_lcdc_win_en_change_multiple_wx", true  },
	{ "m3_lcdc_win_map_change", true  },
	{ "m3_obp0_change", true  },
	{ "m3_scx_high_5_bits", true  },
	{ "m3_scx_low_3_bits", true  },
	{ "m3_scy_change", true  },
	{ "m3_window_timing", true  },
	{ "m3_window_timing_wx_0", true  },
	{ "m3_wx_4_change", true  },
	{ "m3_wx_4_change_sprites", true  },
	{ "m3_wx_5_change", true  },
	{ "m3_wx_6_change", true  },
};

// Expected on a CGB (CPU CGB C screenshots). The ROMs are DMG games: the
// CGB runs them in compatibility mode, coloured by the boot ROM, so these
// run through the boot ROM. Left out: the four whose CGB screenshot is a
// "not currently available" placeholder (m3_lcdc_win_en_change_multiple_wx,
// m3_wx_4_change, m3_wx_5_change, m3_wx_6_change).
const Rom[*] CGB_ROMS = {
	{ "m2_win_en_toggle", true  },
	{ "m3_bgp_change", true  },
	{ "m3_bgp_change_sprites", true  },
	{ "m3_lcdc_bg_en_change", true  },
	{ "m3_lcdc_bg_en_change2", true  },
	{ "m3_lcdc_bg_map_change", true  },
	{ "m3_lcdc_bg_map_change2", true  },
	{ "m3_lcdc_obj_en_change", true  },
	{ "m3_lcdc_obj_en_change_variant", true  },
	{ "m3_lcdc_obj_size_change", true  },
	{ "m3_lcdc_obj_size_change_scx", true  },
	{ "m3_lcdc_tile_sel_change", true  },
	{ "m3_lcdc_tile_sel_change2", true  },
	{ "m3_lcdc_tile_sel_win_change", true  },
	{ "m3_lcdc_tile_sel_win_change2", true  },
	{ "m3_lcdc_win_en_change_multiple", true  },
	{ "m3_lcdc_win_map_change", true  },
	{ "m3_lcdc_win_map_change2", true  },
	{ "m3_obp0_change", true  },
	{ "m3_scx_high_5_bits", true  },
	{ "m3_scx_high_5_bits_change2", true  },
	{ "m3_scx_low_3_bits", true  },
	{ "m3_scy_change", true  },
	{ "m3_scy_change2", true  },
	{ "m3_window_timing", true  },
	{ "m3_window_timing_wx_0", true  },
	{ "m3_wx_4_change_sprites", true  },
};

enum Outcome : char {
	MISSING,
	PASS,
	FAIL,
	TIMEOUT,
}

// Runs one ROM on a DMG; `wrong` = pixels that differ from the screenshot.
fn Outcome run_dmg(String name, int* wrong) {
	char[]? rom = file::load_temp(string::tformat("%sroms/%s.gb", DIR, name));
	char[]? ref = file::load_temp(string::tformat("%sdmg/%s.pgm", DIR, name));
	if (catch rom, ref) return MISSING;
	if (ref.len < PIXELS) return MISSING;
	char[] want = ref[ref.len - PIXELS..];

	gameboy::GameBoy gb = gameboy::new(false);
	defer gb.destroy();
	gb.load_rom(rom);

	ulong limit = gb.cpu.clk + TIMEOUT;
	while (gb.cpu.clk < limit) {
		if (gb.mmu.get(gb.cpu.pc) == 0x40) { // LD B,B
			char[] fb = gb.framebuffer();
			for (int i = 0; i < PIXELS; i++) {
				if (GRAY[fb[i] & 3] != want[i]) (*wrong)++;
			}
			if (*wrong == 0) return PASS;
			(void)write_pgm(string::tformat("%sout/%s.pgm", DIR, name), fb);
			return FAIL;
		}
		gb.step();
	}
	return TIMEOUT;
}

// Runs one ROM on a CGB, through the boot ROM; compares the RGB frame.
fn Outcome run_cgb(String name, int* wrong) {
	char[]? rom = file::load_temp(string::tformat("%sroms/%s.gb", DIR, name));
	char[]? ref = file::load_temp(string::tformat("%scgb/%s.ppm", DIR, name));
	if (catch rom, ref) return MISSING;
	if (ref.len < PIXELS * 3) return MISSING;
	char[] want = ref[ref.len - PIXELS * 3..];

	gameboy::GameBoy gb = gameboy::new(true, CGB);
	defer gb.destroy();
	gb.load_rom(rom);

	ulong limit = gb.cpu.clk + TIMEOUT * 2;
	while (gb.cpu.clk < limit) {
		if (!gb.mmu.boot_active && gb.mmu.get(gb.cpu.pc) == 0x40) { // LD B,B
			char[] rgb = mem::new_array(char, gameboy::MAX_FRAME_RGB);
			defer free(rgb.ptr);
			gb.frame_rgb(rgb, {});
			for (int i = 0; i < PIXELS; i++) {
				if (rgb[i * 3:3] != want[i * 3:3]) (*wrong)++;
			}
			if (*wrong == 0) return PASS;
			(void)write_ppm(string::tformat("%sout/%s-cgb.ppm", DIR, name), rgb[:PIXELS * 3]);
			return FAIL;
		}
		gb.step();
	}
	return TIMEOUT;
}

fn void? write_ppm(String path, char[] rgb) {
	if (!file::is_dir(DIR +++ "out")) path::mkdir(DIR +++ "out")!;
	DString out;
	out.init(mem);
	defer out.free();
	out.appendf("P6\n%d %d\n255\n", ppu::WIDTH, ppu::HEIGHT);
	foreach (b : rgb) out.append_char(b);
	file::save(path, out.str_view())!;
}

// Our frame, for comparing by eye (test/mealybug/out/<name>.pgm).
fn void? write_pgm(String path, char[] fb) {
	if (!file::is_dir(DIR +++ "out")) path::mkdir(DIR +++ "out")!;
	DString out;
	out.init(mem);
	defer out.free();
	out.appendf("P5\n%d %d\n255\n", ppu::WIDTH, ppu::HEIGHT);
	for (int i = 0; i < PIXELS; i++) out.append_char(GRAY[fb[i] & 3]);
	file::save(path, out.str_view())!;
}

alias Runner = fn Outcome(String, int*);

struct Result {
	Outcome outcome;
	int     wrong;
}

struct Batch {
	Rom[]    roms;
	Runner   run;
	Result[] results;
}

fn void run_job(void* ctx, usz i) {
	Batch* b = ctx;
	b.results[i].outcome = b.run(b.roms[i].name, &b.results[i].wrong);
}

fn void run_suite(String label, Rom[] roms, Runner run)
{
	uint present;
	uint passed;
	uint regressed;
	uint new_pass;
	Result[] results = mem::new_array(Result, roms.len);
	defer free(results.ptr);
	Batch batch = { roms, run, results };
	parallel::run(roms.len, &run_job, &batch);
	foreach (i, rom : roms) {
		int wrong = results[i].wrong;
		Outcome o = results[i].outcome;
		if (o == MISSING) continue;
		present++;
		if (o == PASS) {
			passed++;
			if (!rom.must_pass) {
				new_pass++;
				io::eprintfn("  NEW PASS  %s %s  (mark it `true`)", label, rom.name);
			}
			continue;
		}
		if (rom.must_pass) regressed++;
		String what = o == TIMEOUT ? "timeout" : string::tformat("%d px", wrong);
		io::eprintfn("  %s%-9s %s %s", rom.must_pass ? "REGRESSED " : "", what, label, rom.name);
	}

	if (present == 0) {
		io::eprintfn("  %s: no ROMs in test/mealybug — run scripts/fetch-mealybug.sh", label);
		return;
	}
	io::eprintfn("  %s: %d/%d pass, %d newly passing, %d regressed", label, passed, present, new_pass, regressed);
	test::@check(regressed == 0, "a must-pass Mealybug ROM regressed (see lines above)");
}

fn void run_all() @test
{
	run_suite("mealybug dmg", &DMG_ROMS, &run_dmg);
	run_suite("mealybug cgb", &CGB_ROMS, &run_cgb);
}
