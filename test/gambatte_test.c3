module gambatte_test;

import gameboy, mmu, apu;
import std::io, std::io::file, std::os::env, std::collections::map, std::collections::list, std::sort;
import parallel;
import std::core::test;

// Gambatte's hardware tests (sinamas), checked the way Gambatte's own
// testrunner does: run a ROM without boot ROM for 15 frames and more, then
//   hex:   the top-left 8x8 tiles show the expected hex digits (GLYPHS),
//   audio: the last frame is silent (0) or not (1),
//   png:   the whole screen equals a screenshot (colours masked to 0xF8F8F8;
//          DMG shades 0xFFFFFF/AAAAAA/555555/000000, CGB colours through
//          Gambatte's formula).
// The expected results are in the ROM names; scripts/fetch-gambatte.sh
// fetches the ROMs into test/gambatte/ and indexes them (index.txt).
//
// With several thousand checks there is no list of them here: the checks
// that pass are kept in test/gambatte_pass.txt, and one of those failing is
// a regression. WER_GAMBATTE_UPDATE=1 rewrites that file with today's passes.
//
// They take minutes (over ten unoptimized), so they only run when asked:
//   WER_GAMBATTE=1 c3c test -O2 --test-filter gambatte --test-nocapture
// WER_GAMBATTE_ONLY=<part of a path> runs just those, showing what failing
// ones display.

const String DIR = "test/gambatte/";
const String PASS_FILE = "test/gambatte_pass.txt";

// Real time a test runs: Gambatte's runner stops after 15 frames plus the
// part of a frame its last call runs past; 16 frames covers every test.
const ulong RUN_T = 70224UL * 16;
const ulong LAST_FRAME_T = RUN_T - 70224UL;

// testrunner.cpp's digits 0-F, 8x8, '#' = black, '.' = white.
const String[16 * 8] GLYPHS = {
	// 0
	"........",
	".#######",
	".#.....#",
	".#.....#",
	".#.....#",
	".#.....#",
	".#.....#",
	".#######",
	// 1
	"........",
	"....#...",
	"....#...",
	"....#...",
	"....#...",
	"....#...",
	"....#...",
	"....#...",
	// 2
	"........",
	".#######",
	".......#",
	".......#",
	".#######",
	".#......",
	".#......",
	".#######",
	// 3
	"........",
	".#######",
	".......#",
	".......#",
	"..######",
	".......#",
	".......#",
	".#######",
	// 4
	"........",
	".#.....#",
	".#.....#",
	".#.....#",
	".#######",
	".......#",
	".......#",
	".......#",
	// 5
	"........",
	".#######",
	".#......",
	".#......",
	".######.",
	".......#",
	".......#",
	".######.",
	// 6
	"........",
	".#######",
	".#......",
	".#......",
	".#######",
	".#.....#",
	".#.....#",
	".#######",
	// 7
	"........",
	".#######",
	".......#",
	"......#.",
	".....#..",
	"....#...",
	"...#....",
	"...#....",
	// 8
	"........",
	"..#####.",
	".#.....#",
	".#.....#",
	"..#####.",
	".#.....#",
	".#.....#",
	"..#####.",
	// 9
	"........",
	".#######",
	".#.....#",
	".#.....#",
	".#######",
	".......#",
	".......#",
	".#######",
	// A
	"........",
	"....#...",
	"..#...#.",
	".#.....#",
	".#######",
	".#.....#",
	".#.....#",
	".#.....#",
	// B
	"........",
	".######.",
	".#.....#",
	".#.....#",
	".######.",
	".#.....#",
	".#.....#",
	".######.",
	// C
	"........",
	"..#####.",
	".#.....#",
	".#......",
	".#......",
	".#......",
	".#.....#",
	"..#####.",
	// D
	"........",
	".######.",
	".#.....#",
	".#.....#",
	".#.....#",
	".#.....#",
	".#.....#",
	".######.",
	// E
	"........",
	".#######",
	".#......",
	".#......",
	".#######",
	".#......",
	".#......",
	".#######",
	// F
	"........",
	".#######",
	".#......",
	".#......",
	".#######",
	".#......",
	".#......",
	".#......",
};

struct Check {
	bool   cgb;
	String kind;   // hex, audio, png
	String rom;
	String expect; // hex digits, 0/1, or the .rgb screenshot
}

// The screen in Gambatte's colours, 0xRRGGBB.
fn void screen_rgb(gameboy::GameBoy* gb, uint[] out) {
	if (gb.mmu.model == CGB) {
		foreach (i, c : gb.mmu.ppu.cfb) {
			uint r = c & 0x1F;
			uint g = (c >> 5) & 0x1F;
			uint b = (c >> 10) & 0x1F;
			out[i] = ((r * 13 + g * 2 + b) >> 1) << 16 | ((g * 3 + b) << 1) << 8 | ((r * 3 + g * 2 + b * 11) >> 1);
		}
	} else {
		foreach (i, s : gb.mmu.ppu.fb) out[i] = (3 - (uint)(s & 3)) * 85 * 0x010101;
	}
}

// The mixed output the speakers would get: silence means it never changes.
fn uint mix(apu::Apu* a) {
	a.sync();
	if (!a.power) return 0;
	uint l;
	uint r;
	for (int c = 0; c < 4; c++) {
		uint s = a.active[c] ? a.samples[c] : 0;
		if (a.io[apu::NR51] & (1 << (c + 4))) l += s;
		if (a.io[apu::NR51] & (1 << c)) r += s;
	}
	return (l * (((a.io[apu::NR50] >> 4) & 7) + 1)) << 16 | r * ((a.io[apu::NR50] & 7) + 1);
}

// What a check ended with: passed, and for a failing hex check the digits shown.
struct Result {
	bool    pass;
	char[8] shown;
	usz     shown_len;
}

fn bool run_check(Check* c, Result* res) {
	uint[] px = alloc::alloc_array(tmem, uint, 160 * 144);
	char[]? data = file::load_temp(string::tformat("%s%s", DIR, c.rom));
	if (catch data) return false;
	gameboy::GameBoy gb = gameboy::new(false, c.cgb ? mmu::Model.CGB : mmu::Model.DMG);
	defer gb.destroy();
	gb.load_rom(data);
	if (gb.mmu.cart) gb.mmu.cart.has_battery = false;

	short[4096] drop;
	ulong t;
	uint first_mix;
	bool sound_changed;
	bool in_last = false;
	while (t < RUN_T) {
		uint m = gb.step();
		t += gb.mmu.double_speed ? (ulong)m * 2 : (ulong)m * 4;
		if (gb.mmu.apu.count > 2048) gb.audio(&drop);
		if (t >= LAST_FRAME_T) {
			uint x = mix(&gb.mmu.apu);
			if (!in_last) {
				first_mix = x;
				in_last = true;
			} else if (x != first_mix) {
				sound_changed = true;
			}
		}
	}

	switch (c.kind) {
		case "audio":
			return sound_changed == (c.expect == "1");
		case "hex":
			screen_rgb(&gb, px);
			String shown = shown_hex(px, (int)c.expect.len);
			res.shown_len = shown.len < 8 ? shown.len : 8;
			res.shown[:res.shown_len] = shown[:res.shown_len];
			foreach (i, ch : c.expect) {
				// Like testrunner.cpp: upper-cased, up to the first non-digit.
				int d = -1;
				if (ch >= '0' && ch <= '9') d = ch - '0';
				if ((ch | 0x20) >= 'a' && (ch | 0x20) <= 'f') d = (ch | 0x20) - 'a' + 10;
				if (d < 0) break;
				for (int y = 0; y < 8; y++) {
					for (int x = 0; x < 8; x++) {
						uint want = GLYPHS[d * 8 + y][x] == '#' ? 0 : 0xF8F8F8;
						usz at = (usz)(y * 160 + x) + (usz)i * 8;
						if ((px[at] & 0xF8F8F8) != want) return false;
					}
				}
			}
			return true;
		case "png":
			char[]? ref = file::load_temp(string::tformat("%s%s", DIR, c.expect));
			if (catch ref) return false;
			if (ref.len != 160 * 144 * 3) return false;
			screen_rgb(&gb, px);
			foreach (i, p : px) {
				uint want = (uint)ref[i * 3] << 16 | (uint)ref[i * 3 + 1] << 8 | ref[i * 3 + 2];
				if ((p ^ want) & 0xF8F8F8) {
					dump_screen(c, px);
					return false;
				}
			}
			return true;
		default:
			return false;
	}
}

// WER_GAMBATTE_DUMP=<dir>: a failing screenshot check saves what we show
// there, as raw RGB like the references (<rom path with / as _>.rgb).
fn void dump_screen(Check* c, uint[] px) {
	String? dir = env::tget_var("WER_GAMBATTE_DUMP");
	if (catch dir) return;
	char[] rgb = alloc::alloc_array(tmem, char, 160 * 144 * 3);
	foreach (i, p : px) {
		rgb[i * 3] = (char)(p >> 16);
		rgb[i * 3 + 1] = (char)(p >> 8);
		rgb[i * 3 + 2] = (char)p;
	}
	String name = string::tformat("%s/%s.rgb", dir, c.rom.treplace("/", "_"));
	(void)file::save(name, rgb);
}

// The hex digits shown in the top-left corner (`?` for a tile that is none),
// to report what a failing check displays.
fn String shown_hex(uint[] px, int n) {
	DString out;
	out.tinit();
	for (int i = 0; i < n; i++) {
		char got = '?';
		for (int d = 0; d < 16 && got == '?'; d++) {
			bool same = true;
			for (int y = 0; y < 8 && same; y++) {
				for (int x = 0; x < 8; x++) {
					uint want = GLYPHS[d * 8 + y][x] == '#' ? 0 : 0xF8F8F8;
					if ((px[(usz)(y * 160 + i * 8 + x)] & 0xF8F8F8) != want) {
						same = false;
						break;
					}
				}
			}
			if (same) got = d < 10 ? (char)('0' + d) : (char)('A' + d - 10);
		}
		out.append_char(got);
	}
	return out.str_view();
}

fn String Check.id(&self) => string::tformat("%s %s %s", self.cgb ? "cgb" : "dmg", self.kind, self.rom);

struct Batch {
	Check[]  checks;
	Result[] results;
}

fn void run_one(void* ctx, usz i) {
	Batch* b = ctx;
	b.results[i].pass = run_check(&b.checks[i], &b.results[i]);
}

fn void run_all() @test {
	if (!@ok(env::tget_var("WER_GAMBATTE")) && !@ok(env::tget_var("WER_GAMBATTE_ONLY"))) {
		io::printn("  (Gambatte tests skipped: set WER_GAMBATTE=1)");
		return;
	}
	char[]? index = file::load_temp(DIR +++ "index.txt");
	if (catch index) {
		io::printn("  (no Gambatte tests: scripts/fetch-gambatte.sh)");
		return;
	}
	HashMap{String, bool} baseline;
	baseline.init(mem);
	defer baseline.free();
	if (try saved = file::load_temp(PASS_FILE)) {
		foreach (line : ((String)saved).tsplit("\n")) if (line.len) baseline[line] = true;
	}
	bool update = @ok(env::tget_var("WER_GAMBATTE_UPDATE"));
	String only = env::tget_var("WER_GAMBATTE_ONLY") ?? "";

	// Every check first, run on all CPUs, then the report in order.
	List{Check} checks;
	checks.init(mem);
	defer checks.free();
	foreach (line : ((String)index).tsplit("\n")) {
		String[] f = line.tsplit(" ");
		if (f.len != 4) continue;
		Check c = { f[0] == "cgb", f[1], f[2], f[3] };
		if (only.len && !c.rom.contains(only)) continue;
		checks.push(c);
	}
	Result[] results = mem::new_array(Result, checks.len());
	defer free(results.ptr);
	Batch batch = { checks.array_view(), results };
	parallel::run((usz)checks.len(), &run_one, &batch);

	DString passed;
	passed.init(mem);
	defer passed.free();
	// Per directory and model: checks run, passed.
	HashMap{String, int[2]} dirs;
	dirs.init(mem);
	defer dirs.free();
	int total;
	int ok;
	int regressed;
	int fresh;
	foreach (i, &c : checks) {
		String id = c.id();
		bool pass = results[i].pass;
		String shown = (String)results[i].shown[:results[i].shown_len];
		total++;
		String dir = string::tformat("%s %s", c.rom[:c.rom.index_of_char('/') ?? 0], c.cgb ? "cgb" : "dmg");
		int[2] n = dirs[dir] ?? {};
		n[0]++;
		if (pass) {
			ok++;
			n[1]++;
			passed.appendf("%s\n", id);
			if (!baseline.has_key(id)) fresh++;
		} else if (baseline.has_key(id)) {
			regressed++;
			String got = only.len && c.kind == "hex" ? string::tformat(", got %s", shown) : "";
			io::eprintfn("  REGRESSED %s (%s%s)", id, c.expect, got);
		} else if (only.len) {
			io::eprintfn("  fail %s: want %s, got %s", id, c.expect, shown);
		}
		dirs[dir] = n;
	}
	String[] keys = dirs.tkeys();
	sort::quicksort(keys);
	foreach (k : keys) {
		int[2] n = dirs[k]!!;
		io::eprintfn("  %-22s %4d/%-4d", k, n[1], n[0]);
	}
	io::eprintfn("  gambatte: %d/%d pass, %d newly passing, %d regressed", ok, total, fresh, regressed);
	if (update && !only.len) {
		file::save(PASS_FILE, passed.str_view())!!;
		io::eprintfn("  wrote %s", PASS_FILE);
	}
	// WER_GAMBATTE_OUT=file: today's passes, for comparing two builds.
	if (try out = env::tget_var("WER_GAMBATTE_OUT")) file::save(out, passed.str_view())!!;
	test::eq(0, regressed);
}
