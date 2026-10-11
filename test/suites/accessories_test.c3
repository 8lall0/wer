module accessories_suite;

import gameboy, mmu, zip;
import std::io, std::io::file, std::os::env, std::hash::crc32;
import std::core::test;

// The link port devices with their games, from power on (the games aren't
// in the repository; without one its test passes with a note):
//
//   RPG Tsukuru GB saves a file to the Turbo File GB
//   Barcode Taisen Bardigun hatches its first egg from a swiped card
//
// WER_ACC_SHOTS=DIR writes each test's last screen there.

// The game in resources/ (a .zip of it is fine), or none.
fn char[]? game(String name) {
	char[] data = file::load_temp(string::tformat("resources/%s", name))!;
	if (zip::is_zip(data)) data = zip::extract_rom(data, tmem)!;
	return data;
}

// Buttons (each held 6 frames): A B s(elect) S(tart) U D L R.
struct Press {
	int  frame;
	char key;
}

fn void press(gameboy::GameBoy* gb, Press[] presses, int f) {
	char buttons;
	char dpad;
	foreach (p : presses) {
		if (f < p.frame || f >= p.frame + 6) continue;
		switch (p.key) {
			case 'A': buttons |= 1;
			case 'B': buttons |= 2;
			case 's': buttons |= 4;
			case 'S': buttons |= 8;
			case 'R': dpad |= 1;
			case 'L': dpad |= 2;
			case 'U': dpad |= 4;
			case 'D': dpad |= 8;
			default: unreachable();
		}
	}
	gb.mmu.set_input(buttons, dpad);
}

fn uint screen(gameboy::GameBoy* gb, String name) {
	char[] rgb = mem::temp_array(char, gameboy::MAX_FRAME_RGB);
	char[12] colors = { 0xFF, 0xFF, 0xFF, 0xAA, 0xAA, 0xAA, 0x55, 0x55, 0x55, 0, 0, 0 };
	gameboy::FrameSize size = gb.frame_rgb(rgb, colors);
	char[] picture = rgb[:size.w * size.h * 3];
	String shots = env::tget_var("WER_ACC_SHOTS") ?? "";
	if (shots.len) {
		String head = string::tformat("P6\n%d %d\n255\n", size.w, size.h);
		file::save(string::tformat("%s/%s.ppm", shots, name), head.tconcat((String)picture))!!;
	}
	return crc32::hash(picture);
}

mmu::Mmu* turbo_mmu;
mmu::TurboFile* turbo_drive;

// Main menu > Turbo File > Save > the Turbo File > the name offered > yes.
fn void rpg_tsukuru_saves_to_the_turbo_file() @test {
	char[]? rom = game("RPG Tsukuru GB (Japan).zip");
	if (catch rom) {
		io::printn("  (RPG Tsukuru GB not in resources/: the Turbo File not tested with it)");
		return;
	}
	gameboy::GameBoy gb = gameboy::new(false, CGB);
	defer gb.destroy();
	gb.load_rom(rom);
	gb.mmu.cart.has_battery = false;
	char[] data = mem::temp_array(char, mmu::TURBO_SIZE);
	data[..] = 0xFF;
	mmu::TurboFile* t = mem::new(mmu::TurboFile);
	defer free(t);
	t.init(data, (uint)gb.mmu.model.clock_hz());
	mmu::Link l;
	gb.mmu.connect_turbo(&l, t);
	turbo_mmu = &gb.mmu;
	turbo_drive = t;
	Press[*] presses = {
		{ 600, 'R' }, { 660, 'R' }, { 720, 'D' }, { 800, 'A' },
		{ 1520, 'A' }, { 1600, 'A' }, { 1800, 'S' }, { 2000, 'A' }, { 2200, 'A' }, { 2400, 'A' },
	};
	for (int f = 0; f < 3900; f++) {
		press(&gb, &presses, f);
		gb.run_frame_polled(fn (ctx) { turbo_drive.tick(turbo_mmu); }, null, 128);
	}
	screen(&gb, "rpg-tsukuru");
	// The file's four 8 KiB blocks, each with a header in bank $7F: $5A,
	// the game's ID, the name, which block of how many.
	test::@check(t.changed, "written to");
	usz headers = 0x7F * 0x2000;
	for (int b = 0; b < 4; b++) {
		char[] h = data[headers + (usz)b * 64 : 0x18];
		test::@check((String)h[:0x16] == "ZA2QJRPG TCOOL 00     ", "header %d: %s", b, (String)h[:0x16]);
		test::eq(h[0x16], b);
		test::eq(h[0x17], 4);
		test::@check(data[(usz)b * 0x2000 : 0x2000] != data[0x10 * 0x2000 : 0x2000], "block %d written", b);
	}
}

// Through the title, the clock, the hero, a name, to the first egg; then a
// card: Nyaari (Dan Docs' list of barcodes) hatches.
fn void bardigun_hatches_from_a_card() @test {
	char[]? rom = game("Barcode Taisen Bardigun (Japan) (SGB Enhanced).zip");
	if (catch rom) {
		io::printn("  (Barcode Taisen Bardigun not in resources/: its reader not tested with it)");
		return;
	}
	gameboy::GameBoy gb = gameboy::new(false, CGB);
	defer gb.destroy();
	gb.load_rom(rom);
	gb.mmu.cart.has_battery = false;
	mmu::Bardigun* reader = mem::new(mmu::Bardigun);
	defer free(reader);
	mmu::Link l;
	gb.mmu.connect_bardigun(&l, reader);
	Press[100] presses;
	int n;
	foreach (p : (Press[*]){ { 600, 'S' }, { 900, 'S' }, { 1200, 'S' }, { 1500, 'A' }, { 1800, 'A' },
	                         { 2100, 'A' }, { 2400, 'A' }, { 2700, 'A' }, { 3040, 'S' } }) presses[n++] = p;
	for (int f = 3200; f < 11000; f += 100) presses[n++] = { f, 'A' };
	for (int f = 0; f < 11400; f++) {
		if (f == 11020) reader.swipe("4900363432103")!!;
		press(&gb, presses[:n], f);
		gb.run_frame();
	}
	uint crc = screen(&gb, "bardigun");
	test::@check(crc == 0x58c27170, "Nyaari hatched (screen CRC %08x)", crc);
}
