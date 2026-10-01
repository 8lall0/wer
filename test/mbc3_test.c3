module mbc3_test;

import gameboy, mmu, joypad;
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

fn void check(String rom, String keys, int seconds, String reference) {
	bool? ok = matches(rom, keys, seconds, reference);
	if (catch ok) {
		io::printfn("  (%s missing: scripts/fetch-gambatte.sh)", rom);
		return;
	}
	test::@check(ok, "%s: screen differs from %s", rom, reference);
}

fn void rtc3test_basic() @test => check("rtc3test.gb", "a", 15, "rtc3test-basic-tests-dmg.rgb");
fn void rtc3test_range() @test => check("rtc3test.gb", "da", 10, "rtc3test-range-tests-dmg.rgb");
fn void rtc3test_sub_second_writes() @test => check("rtc3test.gb", "dda", 28, "rtc3test-sub-second-writes-dmg.rgb");
fn void mbc3_tester() @test => check("mbc3-tester.gb", "", 1, "mbc3-tester-dmg.rgb");
