module accessories_suite;

import gameboy, mmu, zip;
import std::io, std::io::file, std::io::path, std::os::env, std::hash::crc32;
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

// Pokémon Silver (Italian) and the Pokémon Pikachu 2: a new game started
// and saved, Mystery Gift unlocked in the save (as the girl in Goldenrod's
// department store does), then DONO SEGRETO from the main menu and 999
// watts sent: a Rare Candy, kept for the player to collect.
fn void pikachu_2_mystery_gift() @test {
	char[]? rom = game("Pokemon - Versione Argento (Italy) (SGB Enhanced).gbc");
	if (catch rom) {
		io::printn("  (Pokémon Silver (Italy) not in resources/: the Pikachu 2 not tested with it)");
		return;
	}
	String dir = (env::tget_var("TMPDIR") ?? "/tmp").tconcat("/wer-pikachu-test");
	(void)path::mkdir(dir, true);
	String base = dir.tconcat("/silver");
	(void)file::delete(base.tconcat(".sav"));

	// A new game, named AAAAAAA, saved in the bedroom.
	gameboy::GameBoy gb = gameboy::new(false, CGB);
	gb.load_rom_named(rom, base);
	Press[200] presses;
	int n;
	foreach (p : (Press[*]){ { 600, 'S' }, { 900, 'S' }, { 1100, 'A' } }) presses[n++] = p;
	for (int f = 1500; f <= 5940; f += 90) presses[n++] = { f, 'A' };
	presses[n++] = { 6040, 'S' };
	presses[n++] = { 6100, 'A' };
	for (int f = 6200; f <= 9980; f += 90) presses[n++] = { f, 'A' };
	foreach (p : (Press[*]){ { 10220, 'S' }, { 10260, 'D' }, { 10300, 'D' }, { 10340, 'A' }, { 10460, 'A' }, { 10600, 'A' }, { 10750, 'A' } }) presses[n++] = p;
	for (int f = 0; f < 11100; f++) {
		press(&gb, presses[:n], f);
		gb.run_frame();
	}
	gb.destroy(); // the save written
	char[] sav = file::load_temp(base.tconcat(".sav"))!!;
	sav[0xBE3] = 0; // sMysteryGiftUnlocked
	sav[0xBE5] = 0; // sNumDailyMysteryGiftPartnerIDs
	file::save(base.tconcat(".sav"), sav)!!;

	// Main menu > DONO SEGRETO, and the pet's watts.
	gb = gameboy::new(false, CGB);
	defer gb.destroy();
	gb.load_rom_named(rom, base);
	gb.mmu.cart.has_battery = false;
	mmu::Pikachu2* pet = mem::new(mmu::Pikachu2);
	defer free(pet);
	mmu::Link l;
	gb.mmu.connect_pikachu(&l, pet);
	Press[*] menu = { { 600, 'S' }, { 900, 'S' }, { 1420, 'D' }, { 1460, 'D' }, { 1500, 'D' }, { 1560, 'A' } };
	for (int f = 0; f < 1920; f++) {
		if (f == 1700) pet.send(999);
		press(&gb, &menu, f);
		gb.run_frame();
	}
	test::eq(pet.state, mmu::PikaState.DONE);
	test::eq(pet.region, 0x99); // Italy's
	// The gift chosen: the Mystery Gift item list's Rare Candy ($20 in the
	// games' items), in the save until the player collects it.
	test::eq(gb.mmu.cart.ram[0xBE4], 0x20); // sBackupMysteryGiftItem: RARE_CANDY
	uint crc = screen(&gb, "pikachu-2");
	test::@check(crc == 0xc3815229, "the gift sent (screen CRC %08x)", crc);
}

// Sakura Taisen GB and the Pocket Sakura: from the title, the game's own
// receiving scene ($10, entered as the game enters it: the scene to go
// back to kept at $C942), the pet sends event $16 (1000 points): the game
// takes it ("受信に成功しました").
fn void pocket_sakura_sends_a_gift() @test {
	char[]? rom = game("Sakura Taisen GB - Geki Hana Gumi Nyuutai! (Japan).zip");
	if (catch rom) {
		io::printn("  (Sakura Taisen GB not in resources/: the Pocket Sakura not tested with it)");
		return;
	}
	gameboy::GameBoy gb = gameboy::new(false, CGB);
	defer gb.destroy();
	gb.load_rom(rom);
	gb.mmu.cart.has_battery = false;
	mmu::Pikachu2* pet = mem::new(mmu::Pikachu2);
	defer free(pet);
	mmu::Link l;
	gb.mmu.connect_pikachu(&l, pet);
	Press[*] presses = { { 300, 'A' }, { 450, 'S' } };
	for (int f = 0; f < 1100; f++) {
		if (f == 910) {
			gb.mmu.set(0xC942, gb.mmu.get(0xC2A0));
			gb.mmu.set(0xC943, gb.mmu.get(0xC2A1));
			gb.mmu.set(0xC2A0, 0x10);
			gb.mmu.set(0xC2A1, 0);
		}
		if (f == 940) pet.send_sakura(0x16);
		press(&gb, &presses, f);
		gb.run_frame();
	}
	test::eq(pet.state, mmu::PikaState.DONE);
	test::eq(gb.mmu.get(0xC902), 0x6C);        // the game's status: fine
	test::eq(gb.mmu.get(0xC903), 0x43);        // from a Pocket Sakura
	char[12] got;
	for (int i = 0; i < 12; i++) got[i] = gb.mmu.get((ushort)(0xC8C2 + i));
	test::@check((String)got[:5] == "CRJDM" && got[8] == 0 && got[9] == 0x16, "the block as received");
	uint crc = screen(&gb, "pocket-sakura");
	test::@check(crc == 0xde32a3ce, "received (screen CRC %08x)", crc);
}
