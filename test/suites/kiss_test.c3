module kiss_test;

import gameboy, mmu, joypad, zip;
import std::io, std::io::file;
import std::core::test;

// The GB KISS LINK (link/kiss.c3) with Nectaris GB: a map sent to the game
// ("receive from PC") lands in its battery RAM; the game sends it back
// ("send to PC") the same. Needs the game, which isn't in the repository:
// resources/Nectaris GB (Japan) (SGB Enhanced).zip (or .gb); without it the
// test passes with a note.

const String[2] ROMS = { "resources/Nectaris GB (Japan) (SGB Enhanced).zip", "resources/Nectaris GB (Japan) (SGB Enhanced).gb" };

// A construction map in the game's format: one unit, the rest empty.
fn char[512] test_map() {
	char[512] map;
	map[0:6] = ((String)"NECTAR")[..];
	map[6] = 0x20;   // map $20 (construction map 1)
	map[7] = 0x04;   // construction data
	map[8:6] = ((String)"EMAP01")[..];
	map[0x0E] = 0xFF;
	map[0x0F] = 0xFF;
	for (int i = 0x14; i < 0x17C; i++) map[i] = 0xFF;
	map[0x2C:6] = (char[6]){ 0x00, 2, 2, 0, 0xFF, 8 }[..]; // an M77 at (2, 2), 8 of them
	for (int i = 0x180; i < 0x1E4; i++) map[i] = 0xFF;
	char sum;
	for (int i = 0; i < 0x1FF; i++) sum += map[i];
	map[0x1FF] = sum;
	return map;
}

fn void play(gameboy::GameBoy* gb, String script, int frames) {
	joypad::Script s = joypad::parse_script(script)!!;
	for (int f = 0; f < frames; f++) {
		char b;
		char d;
		s.at((ulong)f, &b, &d);
		gb.mmu.set_input(b, d);
		gb.run_frame();
	}
}

fn void nectaris_map_round_trip() @test {
	char[] rom;
	foreach (path : ROMS) {
		if (try data = file::load_temp(path)) {
			rom = zip::is_zip(data) ? zip::extract_rom(data, tmem) ?? {} : data;
			break;
		}
	}
	if (!rom.len) {
		io::printn("  (Nectaris GB not in resources/: GB KISS LINK not tested)");
		return;
	}
	gameboy::GameBoy gb = gameboy::new(true, DMG);
	defer gb.destroy();
	gb.load_rom(rom);
	gb.mmu.cart.has_battery = false;
	mmu::KissLink kiss;
	kiss.init();
	char[512] map = test_map();
	kiss.set_map(&map);
	mmu::Link cable;
	gb.mmu.connect_kiss(&cable, &kiss);

	// GB KISS > receive from PC > slot 00 > A at the prompt.
	play(&gb, "320:start,520:down,560:down,600:down,640:a,760:down,800:down,840:down,880:a,960:a,1040:a,1300:a", 1700);
	test::@check(kiss.sent, "the map went to the game (%s)", kiss.status);
	bool found;
	for (usz i = 0; i + 512 <= gb.mmu.cart.ram.len; i++) {
		if (gb.mmu.cart.ram[i:512] == map[..]) found = true;
	}
	test::@check(found, "the game keeps it in its battery RAM");

	// Back in the GB KISS menu: send to PC > slot 00 > A at the prompt.
	kiss.map[..] = 0;
	play(&gb, "10:a,100:up,160:a,240:a,320:a,600:a", 1100);
	test::@check(kiss.received, "a map came back (%s)", kiss.status);
	test::@check(kiss.map[..] == map[..], "the same map");
}
