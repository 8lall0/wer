module gbmicrotest_test;

import gameboy, mmu, parallel;
import std::io, std::io::file, std::collections::list;
import std::core::test;

// gbmicrotest (https://github.com/aappleby/GBMicrotest): ~480 tiny DMG tests,
// each checking one register or address at one exact cycle after boot,
// checked on a DMG-CPU-08. A test writes its verdict to $FF82: $01 passed,
// $FF failed. ROMs that write nothing are not tests (testbenches, demos).
//
// Not vendored; fetch them with
//   scripts/fetch-gbmicrotest.sh
// into test/gbmicrotest/ . With none present the test prints one line and passes.
//   c3c test && ./build/testrun --test-nocapture --test-filter gbmicrotest

const String DIR = "test/gbmicrotest/";
const int FRAMES = 4;
const int LONG_FRAMES = 30; // is_if_set_during_ime0 needs ~380 ms

// Failing; both are inside `#if 0` in GateBoy's own runner (MetroBoyTests.cpp),
// and SameBoy gives the same results as wer:
//  - halt_op_dupe_delay: expects DIV = $55 a line after resetting it.
//  - stat_write_glitch_l154_d: expects no VBlank flag a frame after LCD on,
//    against stat_write_glitch_l143_d (same setup, flag set).
const String[*] KNOWN_FAIL = {
	"halt_op_dupe_delay.gb",
	"stat_write_glitch_l154_d.gb",
};

struct Check {
	String rom;
	char   verdict; // $FF82 at the end: 0 = no test
	bool   missing;
}

fn void Check.run(&self) {
	char[]? data = file::load_temp(DIR.tconcat(self.rom));
	if (catch data) {
		self.missing = true;
		return;
	}
	gameboy::GameBoy gb = gameboy::new(false, mmu::Model.DMG);
	defer gb.destroy();
	gb.load_rom(data);
	if (gb.mmu.cart) gb.mmu.cart.has_battery = false;
	int frames = self.rom.starts_with("is_if_set_during_ime0") ? LONG_FRAMES : FRAMES;
	for (int i = 0; i < frames; i++) gb.run_frame();
	self.verdict = gb.mmu.get(0xFF82);
}

fn void run_job(void* ctx, usz i) {
	((Check*)ctx)[i].run();
}

fn void run_all() @test
{
	char[]? index = file::load_temp(DIR.tconcat("index.txt"));
	if (catch index) {
		io::eprintn("  gbmicrotest: no ROMs in test/gbmicrotest — run scripts/fetch-gbmicrotest.sh");
		return;
	}
	List{Check} list;
	list.tinit();
	foreach (line : ((String)index).tsplit("\n")) {
		String rom = line.trim();
		if (rom.len) list.push({ .rom = rom });
	}
	Check[] checks = list.array_view();
	parallel::run(checks.len, &run_job, checks.ptr);

	uint tests;
	uint passed;
	uint regressed;
	foreach (&c : checks) {
		if (c.missing || (c.verdict != 0x01 && c.verdict != 0xFF)) continue;
		tests++;
		bool known = false;
		foreach (k : KNOWN_FAIL) if (k == c.rom) known = true;
		if (c.verdict == 0x01) {
			passed++;
			if (known) io::eprintfn("  NEW PASS  %s  (remove it from KNOWN_FAIL)", c.rom);
		} else if (!known) {
			regressed++;
			io::eprintfn("  REGRESSED %s", c.rom);
		}
	}
	io::eprintfn("  gbmicrotest: %d/%d pass, %d regressed", passed, tests, regressed);
	test::@check(regressed == 0, "a gbmicrotest test regressed (see lines above)");
}
