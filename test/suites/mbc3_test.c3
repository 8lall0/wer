module mbc3_test;

import gameboy, mmu, joypad, parallel;
import std::io, std::io::file;
import std::core::test;

// MBC3 cartridge tests, compared with their reference screenshots (DMG
// shades #FFFFFF/#AAAAAA/#555555/#000000):
//   rtc3test (ax6): the real-time clock, three sub-tests picked with buttons;
//   mbc3-tester (Eric Kirschenmann): ROM banking up to 4 MiB (MBC30).
// scripts/fetch-gambatte.sh fetches them into test/mbc3/.

const String DIR = "test/mbc3/";

fn bool? matches(String rom, String keys, int seconds, String reference) {
	char[] data = file::load_temp(string::tformat("%s%s", DIR, rom))!;
	char[] want = file::load_temp(string::tformat("%s%s", DIR, reference))!;
	gameboy::GameBoy gb = gameboy::new(false, mmu::Model.DMG);
	defer gb.destroy();
	gb.load_rom(data);
	if (gb.mmu.cart) gb.mmu.cart.has_battery = false;

	short[8192] drop;
	for (int f = 0; f < 30; f++) {
		gb.run_frame();
		gb.audio(&drop);
	}
	// Each key: held 6 frames, released 6.
	foreach (k : keys) {
		gb.mmu.set_input(k == 'a' ? joypad::BTN_A : 0, k == 'd' ? joypad::PAD_DOWN : 0);
		for (int f = 0; f < 12; f++) {
			if (f == 6) gb.mmu.set_input(0, 0);
			gb.run_frame();
			gb.audio(&drop);
		}
	}
	for (int f = 0; f < seconds * 60; f++) {
		gb.run_frame();
		gb.audio(&drop);
	}
	foreach (i, s : gb.mmu.ppu.fb) {
		if (want[i * 3] != (char)(255 - 85 * (s & 3))) return false;
	}
	return true;
}

struct Check {
	String rom;
	String keys;
	int    seconds;
	String reference;
	bool   present;
	bool   ok;
}

fn void run_job(void* ctx, usz i) {
	Check* c = &((Check*)ctx)[i];
	bool? ok = matches(c.rom, c.keys, c.seconds, c.reference);
	if (catch ok) return;
	c.present = true;
	c.ok = ok;
}

// All four at once (the rtc3test ones run for many emulated seconds).
fn void mbc3_tests() @test {
	Check[4] checks = {
		{ "rtc3test.gb", "a", 15, "rtc3test-basic-tests-dmg.rgb", false, false },
		{ "rtc3test.gb", "da", 10, "rtc3test-range-tests-dmg.rgb", false, false },
		{ "rtc3test.gb", "dda", 28, "rtc3test-sub-second-writes-dmg.rgb", false, false },
		{ "mbc3-tester.gb", "", 1, "mbc3-tester-dmg.rgb", false, false },
	};
	parallel::run(checks.len, &run_job, &checks);
	foreach (c : checks) {
		if (!c.present) {
			io::printfn("  (%s missing: scripts/fetch-gambatte.sh)", c.rom);
			continue;
		}
		test::@check(c.ok, "%s: screen differs from %s", c.rom, c.reference);
	}
}
