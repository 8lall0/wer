module gbmemory_test;
import cart;
import std::core::test, std::io::file, std::os::env;

// The Nintendo Power GB Memory cartridge on a made-up 1 MiB flash: a "menu"
// (its title, its list of games) and three games; each 16 KiB bank of the
// flash holds its own number at $x000 + $2000.

const ushort MARK = 0x2000;

fn char[] np_image() {
	char[] rom = mem::temp_array(char, 0x100000);
	rom[..] = 0xFF;
	for (usz b = 0; b < 64; b++) rom[b * 0x4000 + MARK] = (char)b;
	rom[0x134 : 9] = ((String)"NP M-MENU")[..];
	rom[0x147] = 0x19;
	// The menu's list: number, first 128 KiB block, -, size in blocks.
	char[3][3] games = { { 1, 1, 1 }, { 2, 2, 4 }, { 3, 6, 2 } };
	foreach (usz i, g : games) {
		usz e = 0x1C200 + i * 512;
		rom[e] = g[0];
		rom[e + 1] = g[1];
		rom[e + 2] = 0;
		rom[e + 3] = g[2];
	}
	rom[0x20147] = 0x00;                     // Tetris-like: no MBC, no RAM
	rom[0x40147] = 0x03; rom[0x40149] = 2;   // MBC1, 8 KiB
	rom[0xC0147] = 0x1B; rom[0xC0149] = 3;   // MBC5, 32 KiB
	return rom;
}

fn char bank_at(cart::Cartridge* c, ushort base) => c.read(base + MARK);

fn void mmc(cart::Cartridge* c, char command) {
	c.write(0x0120, 0x09);
	c.write(0x0121, 0xAA);
	c.write(0x0122, 0x55);
	c.write(0x013F, 0xA5);
	c.write(0x0120, command);
	c.write(0x013F, 0xA5);
}

fn void the_map_from_the_menus_list() @test {
	cart::Cartridge* c = cart::new(np_image(), "");
	defer c.free();
	test::eq(c.mbc, cart::Mbc.GBMEM);
	test::eq((ulong)c.ram.len, (ulong)0x20000);
	char[] m = c.np.map[..];
	test::@check(m[0:3] == (char[]){ 0xA8, 0x00, 0x00 }, "the menu: MBC5, 128 KiB");
	test::@check(m[3:3] == (char[]){ 0x08, 0x04, 0x00 }, "no MBC, 128 KiB at $20000");
	test::@check(m[6:3] == (char[]){ 0x31, 0x08, 0x04 }, "MBC1, 512 KiB at $40000, 8 KiB of RAM at $2000");
	test::@check(m[9:3] == (char[]){ 0xAD, 0x98, 0x08 }, "MBC5, 256 KiB at $C0000, 32 KiB of RAM at $4000");
	test::eq(m[0x7F], 0);
	// On power up: the menu, as an MBC5 cartridge.
	test::eq(bank_at(c, 0x0000), 0);
	test::eq(bank_at(c, 0x4000), 1);
	c.write(0x2000, 7);
	test::eq(bank_at(c, 0x4000), 7);
}

fn void commands_need_enabling_first() @test {
	cart::Cartridge* c = cart::new(np_image(), "");
	defer c.free();
	c.write(0x0120, 0xC2);
	c.write(0x013F, 0xA5);
	test::eq(c.np.index, 0);
	c.write(0x0120, 0x09);
	c.write(0x0121, 0xAA);
	c.write(0x0122, 0x55);
	c.write(0x013F, 0xA5);
	// Its registers, over the ROM at $0120-$013F.
	test::eq(c.read(0x0120), 0x21);
	test::eq(c.read(0x0122), 0xA8);
	test::eq(c.read(0x0125), 0x87);
	test::eq(c.read(0x0126), 0x78);
	test::eq(c.read(0x0127), 0x5A);
	test::eq(c.read(0x013F), 0xA5);
	c.write(0x0120, 0x08);
	c.write(0x013F, 0xA5);
	test::eq(c.read(0x0120), 0xFF); // the flash again
}

fn void switching_to_an_mbc1_game() @test {
	cart::Cartridge* c = cart::new(np_image(), "");
	defer c.free();
	mmc(c, 0xC2);
	test::eq(c.np.index, 2);
	assert(!c.reset_request);
	test::eq(c.read(0x0120), 0xFF); // the commands are off again
	test::eq(bank_at(c, 0x0000), 0x10);
	test::eq(bank_at(c, 0x4000), 0x11);
	c.write(0x2000, 0);                // MBC1: 0 is 1
	test::eq(bank_at(c, 0x4000), 0x11);
	c.write(0x2000, 0x1F);             // within the game's 512 KiB
	test::eq(bank_at(c, 0x4000), 0x10 + 0x1F % 32);
	c.write(0x2000, 0x23);
	test::eq(bank_at(c, 0x4000), 0x13);
	// Its RAM: from $2000 of the cartridge's 128 KiB, once enabled.
	c.write(0xA123, 0x55);
	test::eq(c.ram[0x2123], 0);
	c.write(0x0000, 0x0A);
	c.write(0xA123, 0x55);
	test::eq(c.ram[0x2123], 0x55);
	test::eq(c.read(0xA123), 0x55);
}

fn void switching_with_a_reset_to_an_mbc5_game() @test {
	cart::Cartridge* c = cart::new(np_image(), "");
	defer c.free();
	mmc(c, 0x83);
	assert(c.reset_request); // the Game Boy Color's menu: the console restarts
	test::eq(c.np.index, 3);
	test::eq(bank_at(c, 0x0000), 0x30);
	c.write(0x2000, 0);                // MBC5: bank 0 up high too
	test::eq(bank_at(c, 0x4000), 0x30);
	c.write(0x2000, 0x0F);
	test::eq(bank_at(c, 0x4000), 0x3F);
	c.write(0x2000, 0x10);             // wraps in the game's 256 KiB
	test::eq(bank_at(c, 0x4000), 0x30);
	c.write(0x0000, 0x0A);
	c.write(0x4000, 2);
	c.write(0xA000, 0x77);
	test::eq(c.ram[0x4000 + 2 * 0x2000], 0x77);
	// The reset: the game stays, its MBC as at power on.
	c.unl_reset();
	assert(!c.reset_request);
	test::eq(c.np.index, 3);
	test::eq(bank_at(c, 0x4000), 0x31);
	test::eq(c.read(0xA000), 0xFF);
}

fn void the_whole_flash_and_back() @test {
	cart::Cartridge* c = cart::new(np_image(), "");
	defer c.free();
	c.write(0x2000, 5);
	mmc(c, 0x04);
	test::eq(c.read(0x0122), 0x9A); // the registers show the mapping $04 makes
	test::eq(bank_at(c, 0x4000), 1);
	c.write(0x2000, 0x3A);
	test::eq(bank_at(c, 0x4000), 0x3A);
	c.write(0x2000, 0);             // not bank 0, unlike an MBC5
	test::eq(bank_at(c, 0x4000), 1);
	c.write(0x0120, 0x05);
	c.write(0x013F, 0xA5);
	test::eq(c.read(0x0122), 0xA8);
	test::eq(bank_at(c, 0x4000), 5);
}

fn void a_map_file_beside_the_rom() @test {
	String dir = env::tget_var("TMPDIR") ?? "/tmp";
	String base = dir.tconcat("/wer-gbmemory-test");
	char[128] map;
	map[..] = 0xFF;
	map[0x7F] = 0;
	map[0] = 0x08; // power on straight into the game at $40000
	map[1] = 0x08;
	map[2] = 0x00;
	file::save(base.tconcat(".map"), &map)!!;
	defer (void)file::delete(base.tconcat(".map"));
	char[] rom = np_image();
	rom[0x134 : 9] = ((String)"SOMETHING")[..]; // not the menu: the map says what it is
	cart::Cartridge* c = cart::new(rom, base);
	defer c.free();
	test::eq(c.mbc, cart::Mbc.GBMEM);
	test::eq(bank_at(c, 0x0000), 0x10);
}

fn void an_invalid_map_maps_nothing() @test {
	cart::Cartridge* c = cart::new(np_image(), "");
	defer c.free();
	c.np.map[0x7F] = 1; // the MMC ignores it all
	mmc(c, 0xC2);
	test::@check(c.np.entry[..] == (char[]){ 0, 0, 0 }, "a null entry");
	test::eq(bank_at(c, 0x0000), 0);
	test::eq(bank_at(c, 0x4000), 1);
	c.np.map[0x7F] = 0;
	c.np.map[6] = 0xC0; // MBC type 6: invalid
	mmc(c, 0xC2);
	test::@check(c.np.entry[..] == (char[]){ 0, 0, 0 }, "a null entry");
}
