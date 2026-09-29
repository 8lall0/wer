module mealybug_test;

import gameboy, ppu, mmu;
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
	{ "m3_lcdc_bg_en_change", false },
	{ "m3_lcdc_bg_map_change", true  },
	{ "m3_lcdc_obj_en_change", false },
	{ "m3_lcdc_obj_en_change_variant", false },
	{ "m3_lcdc_obj_size_change", true  },
	{ "m3_lcdc_obj_size_change_scx", true  },
	{ "m3_lcdc_tile_sel_change", true  },
	{ "m3_lcdc_tile_sel_win_change", true  },
	{ "m3_lcdc_win_en_change_multiple", true  },
	{ "m3_lcdc_win_en_change_multiple_wx", false },
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

fn void run_all() @test
{
	uint present;
	uint passed;
	uint regressed;
	uint new_pass;
	foreach (rom : DMG_ROMS) {
		int wrong;
		Outcome o = run_dmg(rom.name, &wrong);
		if (o == MISSING) continue;
		present++;
		if (o == PASS) {
			passed++;
			if (!rom.must_pass) {
				new_pass++;
				io::eprintfn("  NEW PASS  %s  (mark it `true`)", rom.name);
			}
			continue;
		}
		if (rom.must_pass) regressed++;
		String what = o == TIMEOUT ? "timeout" : string::tformat("%d px", wrong);
		io::eprintfn("  %s%-9s %s", rom.must_pass ? "REGRESSED " : "", what, rom.name);
	}

	if (present == 0) {
		io::eprintn("  mealybug: no ROMs in test/mealybug — run scripts/fetch-mealybug.sh");
		return;
	}
	io::eprintfn("  mealybug: %d/%d pass, %d newly passing, %d regressed", passed, present, new_pass, regressed);
	test::@check(regressed == 0, "a must-pass Mealybug ROM regressed (see lines above)");
}
