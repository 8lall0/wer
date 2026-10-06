module mappers_test;
import cart, gameboy;
import std::core::test;

// HuC1, HuC3, MMM01 and TAMA5 on made-up ROMs: each 16 KiB bank holds its
// own number at $x000 + $2000.

const ushort MARK = 0x2000;

fn char[] rom_of(char type, usz banks, char ram_code = 0) {
	char[] rom = mem::temp_array(char, (sz)(banks * 0x4000));
	for (usz b = 0; b < banks; b++) rom[b * 0x4000 + MARK] = (char)b;
	rom[0x147] = type;
	rom[0x149] = ram_code;
	return rom;
}

fn char bank_at(cart::Cartridge* c, ushort base) => c.read(base + MARK);

fn void huc1_banks_ram_and_infrared() @test {
	cart::Cartridge* c = cart::new(rom_of(0xFF, 16, 3), "");
	defer c.free();
	c.write(0x2000, 5);
	test::eq(bank_at(c, 0x4000), 5);
	c.write(0x4000, 2);
	c.write(0xA010, 0x42); // no RAM enable on a HuC1
	test::eq(c.read(0xA010), 0x42);
	test::eq(c.ram[2 * 0x2000 + 0x10], 0x42);
	c.write(0x0000, 0x0E); // the infrared port
	test::eq(c.read(0xA000), 0xC0);
	c.write(0xA000, 0x01);
	assert(c.ir_out);
	c.write(0x0000, 0x00);
	test::eq(c.read(0xA010), 0x42);
}

// A HuC3 clock command through mode $B.
fn void huc3_cmd(cart::Cartridge* c, char v) {
	c.write(0x0000, 0x0B);
	c.write(0xA000, v);
}

fn char huc3_result(cart::Cartridge* c) {
	c.write(0x0000, 0x0C);
	return c.read(0xA000);
}

fn void huc3_ram_and_clock() @test {
	cart::Cartridge* c = cart::new(rom_of(0xFE, 16, 3), "");
	defer c.free();
	c.write(0x2000, 9);
	test::eq(bank_at(c, 0x4000), 9);
	c.write(0x0000, 0x0A);
	c.write(0xA000, 0x77);
	c.write(0x0000, 0x00); // read-only RAM
	test::eq(c.read(0xA000), 0x77);
	c.write(0xA000, 0x11);
	test::eq(c.read(0xA000), 0x77);

	// Set the time: 23:59 (1439 minutes = $59F) on day $123.
	huc3_cmd(c, 0x40);
	huc3_cmd(c, 0x50);
	foreach (n : (char[]){ 0xF, 0x9, 0x5, 0x3, 0x2, 0x1, 0x0 }) huc3_cmd(c, 0x30 | n);
	test::eq(c.huc3.minutes, 1439);
	test::eq(c.huc3.days, 0x123);
	// A minute later: midnight of the next day.
	c.rtc.cpu_hz = 1000;
	for (int i = 0; i < 60; i++) c.tick(1000);
	test::eq(c.huc3.minutes, 0);
	test::eq(c.huc3.days, 0x124);
	// Read the day counter's low nibble back.
	huc3_cmd(c, 0x43);
	huc3_cmd(c, 0x50);
	huc3_cmd(c, 0x10);
	test::eq(huc3_result(c), 0x4);
	// Status reads 1; the save block keeps the clock.
	c.write(0x0000, 0x0D);
	test::eq(c.read(0xA000), 1);
	char[cart::HUC3_SAVE_LEN] block;
	c.huc3.serialize(&block, 1_000_000);
	cart::Huc3 h;
	h.deserialize(&block, 1_000_000 + 3600 * 25); // a day and an hour later
	test::eq(h.days, 0x125);
	test::eq(h.minutes, 60);
}

fn void mmm01_menu_then_game() @test {
	// Dumped menu first: the menu is banks 0-1, the games after it.
	char[] rom = rom_of(0x0B, 8);
	cart::Cartridge* c = cart::new(rom, "");
	defer c.free();
	// The menu runs from the cartridge's last 32 KiB.
	test::eq(bank_at(c, 0x0000), 0);
	test::eq(bank_at(c, 0x4000), 1);
	// It maps the first game (bank 2 of the dump) and locks.
	c.write(0x2000, 0x00);
	c.write(0x6000, 0x00);
	c.write(0x0000, 0x40);
	test::eq(bank_at(c, 0x0000), 2);
	test::eq(bank_at(c, 0x4000), 3);
	// The game banks on its own; the lock holds.
	c.write(0x2000, 0x03);
	test::eq(bank_at(c, 0x4000), 5);
	c.write(0x0000, 0x00);
	test::eq(bank_at(c, 0x0000), 2);
}

fn void tama5_reg(cart::Cartridge* c, char reg, char value) {
	c.write(0xA001, reg);
	c.write(0xA000, value);
}

fn void tama5_ram_and_banks() @test {
	cart::Cartridge* c = cart::new(rom_of(0xFD, 32), "");
	defer c.free();
	tama5_reg(c, 0x0, 0x3);
	tama5_reg(c, 0x1, 0x1);
	test::eq(bank_at(c, 0x4000), 0x13);
	// Write $5A to RAM $07: the byte, then the address with the command.
	tama5_reg(c, 0x4, 0xA);
	tama5_reg(c, 0x5, 0x5);
	tama5_reg(c, 0x6, 0x0);
	tama5_reg(c, 0x7, 0x7);
	test::eq(c.ram[7], 0x5A);
	// Read it back, a nibble at a time.
	tama5_reg(c, 0x6, 0x2);
	tama5_reg(c, 0x7, 0x7);
	c.write(0xA001, 0xC);
	test::eq(c.read(0xA000), 0xFA);
	c.write(0xA001, 0xD);
	test::eq(c.read(0xA000), 0xF5);
	c.write(0xA001, 0xA);
	test::eq(c.read(0xA000), 0xF1);
}

fn void tama5_clock_runs() @test {
	cart::Cartridge* c = cart::new(rom_of(0xFD, 32), "");
	defer c.free();
	// Start the timer, set 12:58 (24-hour), then let 3 minutes pass.
	c.tama5.alarm[cart::RTC_24_HOUR] = 1;
	tama5_reg(c, 0x6, 0x4);
	tama5_reg(c, 0x7, 0x1); // ENABLE_TIMER
	tama5_reg(c, 0x4, 0x8);
	tama5_reg(c, 0x5, 0x5);
	tama5_reg(c, 0x7, 0x4); // MINUTE_WRITE 58
	tama5_reg(c, 0x4, 0x2);
	tama5_reg(c, 0x5, 0x1);
	tama5_reg(c, 0x7, 0x5); // HOUR_WRITE 12
	c.rtc.cpu_hz = 1000;
	for (int i = 0; i < 180; i++) c.tick(1000);
	tama5_reg(c, 0x7, 0x6); // MINUTE_READ
	c.write(0xA001, 0xC);
	test::eq(c.read(0xA000) & 0xF, 1);
	c.write(0xA001, 0xD);
	test::eq(c.read(0xA000) & 0xF, 0);
	tama5_reg(c, 0x7, 0x7); // HOUR_READ
	c.write(0xA001, 0xC);
	test::eq(c.read(0xA000) & 0xF, 3);
}

// The clock chip's four pages read back what was written to each.
fn void tama5_pages_read_back() @test {
	cart::Cartridge* c = cart::new(rom_of(0xFD, 32), "");
	defer c.free();
	// Register 4 of page n (written with ADDR_LO 0/2/4/6) = n + 5.
	for (int page = 0; page < 4; page++) {
		tama5_reg(c, 0x4, 0x4);              // the register
		tama5_reg(c, 0x5, (char)(page + 5)); // the value
		tama5_reg(c, 0x6, 0x8);              // clock access
		tama5_reg(c, 0x7, (char)(page * 2)); // write to the page
	}
	for (int page = 0; page < 4; page++) {
		tama5_reg(c, 0x7, (char)(page * 2 + 1)); // read from the page
		c.write(0xA001, 0xC);
		test::eq(c.read(0xA000) & 0xF, page + 5);
	}
}

// Tamagotchi 3's minute status (command $03): $F1 is the pet calling, which
// the cartridge buzzes for; $11 is all well.
fn void tama5_calling_buzzes() @test {
	cart::Cartridge* c = cart::new(rom_of(0xFD, 32), "");
	defer c.free();
	tama5_reg(c, 0x4, 0x1);
	tama5_reg(c, 0x5, 0xF);
	tama5_reg(c, 0x6, 0x4);
	tama5_reg(c, 0x7, 0x3);  // $03 with $F1
	assert(c.tama5.calling);
	test::eq(c.tama5.buzzes, 1u);
	tama5_reg(c, 0x7, 0x3);  // a minute later, still calling
	test::eq(c.tama5.buzzes, 2u);
	tama5_reg(c, 0x5, 0x1);
	tama5_reg(c, 0x7, 0x3);  // $11: cared for
	assert(!c.tama5.calling);
	test::eq(c.tama5.buzzes, 2u);
}

// A flash command through window A.
fn void mbc6_cmd(cart::Cartridge* c, char v) {
	c.write(0x2000, 2);
	c.write(0x5555, 0xAA);
	c.write(0x2000, 1);
	c.write(0x4AAA, 0x55);
	c.write(0x2000, 2);
	c.write(0x5555, v);
}

// MBC6: two 8 KiB windows on ROM or flash, two 4 KiB RAM windows; the
// flash takes JEDEC commands (Pan Docs).
fn void mbc6_windows_and_flash() @test {
	char[] rom = mem::temp_array(char, 0x40000);
	for (usz b = 0; b < 0x40000 / 0x2000; b++) rom[b * 0x2000 + 0x100] = (char)b;
	rom[0x147] = 0x20;
	cart::Cartridge* c = cart::new(rom, "");
	defer c.free();
	c.write(0x2000, 5);
	c.write(0x3000, 9);
	test::eq(c.read(0x4100), 5);
	test::eq(c.read(0x6100), 9);
	// RAM: bank 3 in window B.
	c.write(0x0000, 0x0A);
	c.write(0x0800, 3);
	c.write(0xB010, 0x77);
	test::eq(c.ram[3 * 0x1000 + 0x10], 0x77);
	// The flash in window A, bank 4 (sector 0 is write-protected without $1000).
	c.write(0x0C00, 1);
	c.write(0x2800, 0x08);
	c.write(0x2000, 0x10); // flash $20000: sector 1
	test::eq(c.read(0x4000), 0xFF);   // erased
	// Command addresses are flash addresses: $5555 = bank 2 + $1555, $2AAA = bank 1 + $0AAA.
	mbc6_cmd(c, 0xA0);                       // program
	c.write(0x2000, 0x10);
	c.write(0x4000, 0x5A);
	c.write(0x4000, 0xF0);              // done: reading again
	test::eq(c.read(0x4000), 0x5A);
	mbc6_cmd(c, 0x90);                       // ID
	test::eq(c.read(0x4000), 0xC2);
	test::eq(c.read(0x4001), 0x81);
	c.write(0x4000, 0xF0);
	mbc6_cmd(c, 0x80);                       // erase prefix, then sector erase
	c.write(0x2000, 2); c.write(0x5555, 0xAA);
	c.write(0x2000, 1); c.write(0x4AAA, 0x55);
	c.write(0x2000, 0x10); c.write(0x4000, 0x30);
	test::eq(c.read(0x4000), 0x80);     // status: done
	c.write(0x4000, 0xF0);
	test::eq(c.read(0x4000), 0xFF);
}

fn void m161_and_wisdom_tree() @test {
	char[] rom = mem::temp_array(char, 0x40000);
	for (usz b = 0; b < 8; b++) rom[b * 0x8000 + 0x150] = (char)b;
	rom[0x134 : 10] = ((char[])"TETRIS SET")[..];
	rom[0x147] = 0x10;
	cart::Cartridge* m = cart::new(rom, "");
	defer m.free();
	test::eq(m.read(0x0150), 0);
	m.write(0x5000, 3);
	test::eq(m.read(0x0150), 3);
	m.write(0x5000, 5);                 // once only
	test::eq(m.read(0x0150), 3);

	char[] wt = mem::temp_array(char, 0x40000);
	for (usz b = 0; b < 8; b++) wt[b * 0x8000 + 0x150] = (char)b;
	wt[0x1000 : 11] = ((char[])"WISDOM TREE")[..];
	cart::Cartridge* w = cart::new(wt, "");
	defer w.free();
	test::eq(w.read(0x0150), 0);
	w.write(0x0006, 0x00);              // the address picks the bank
	test::eq(w.read(0x0150), 6);
	test::eq(w.read(0x4000 + 0x150 - 0x150), w.rom[6 * 0x8000 + 0x4000]);
}

// TPP1: registers by address bits 0-1, MR3 commands, the clock.
fn void tpp1_banks_ram_clock_rumble() @test {
	char[] rom = mem::temp_array(char, 0x80000);
	for (usz b = 0; b < 32; b++) rom[b * 0x4000 + 0x150] = (char)b;
	rom[0x147] = 0xBC;
	rom[0x149] = 0xC1;
	rom[0x14A] = 0x65;
	rom[0x152] = 1;                     // 8 KiB RAM
	rom[0x153] = 0x0D;                  // rumble, clock, battery
	cart::Cartridge* c = cart::new(rom, "");
	defer c.free();
	c.write(0x0000, 0x13);
	c.write(0x0001, 0x00);
	test::eq(c.read(0x4150), 0x13);
	c.write(0x0003, 0x03);              // RAM read/write
	c.write(0xA005, 0x42);
	test::eq(c.read(0xA005), 0x42);
	c.write(0x0003, 0x02);              // read-only
	c.write(0xA005, 0x99);
	test::eq(c.read(0xA005), 0x42);
	c.write(0x0003, 0x00);              // the MR registers
	test::eq(c.read(0xA000), 0x13);
	c.write(0x0003, 0x22);              // rumble 2
	test::eq(c.read(0xA003) & 3, 2);
	// Set 23:59:59, Saturday (6), week 0, start the clock, let a second pass.
	c.write(0x0003, 0x05);
	c.write(0xA003, 59);                // seconds (read back at address 3)
	c.write(0xA002, 59);
	c.write(0xA001, 23 | (6 << 5));
	c.write(0xA000, 0);
	c.write(0x0003, 0x11);              // set from the latch
	c.write(0x0003, 0x19);              // start
	c.rtc.cpu_hz = 1000;
	c.tick(1000);
	c.write(0x0003, 0x10);              // latch
	c.write(0x0003, 0x05);
	test::eq(c.read(0xA003), 0);
	test::eq(c.read(0xA001), 0);        // midnight, Sunday
	test::eq(c.read(0xA000), 1);        // week 1
}

// Sachen: base bank and mask (open only with bank bits 4-5 set), and $01xx
// reads through scrambled address lines.
fn void sachen_banks_and_scrambling() @test {
	char[] rom = mem::temp_array(char, 0x40000);
	for (usz b = 0; b < 16; b++) rom[b * 0x4000 + 0x2000] = (char)b;
	rom[0x104] = 0xCE; rom[0x144] = 0xED; rom[0x114] = 0x66; // MMC1's scrambled logo
	rom[0x103] = 0x5A;                                       // $0150 reads $0103: bits 6 and 4 move to 0 and 1
	cart::Cartridge* c = cart::new(rom, "");
	defer c.free();
	test::eq(c.mbc, cart::Mbc.SACHEN);
	c.sachen.locked = false;
	test::eq(c.read(0x0150), 0x5A);
	c.write(0x2000, 0x05);
	test::eq(c.read(0x6000), 5);
	// Open the base/mask registers, then put game 2 (banks 8-15) in place.
	c.write(0x2000, 0x30);
	c.write(0x0000, 0x08);                // base
	c.write(0x4000, 0x08);                // mask: bit 3 comes from the base
	test::eq(c.read(0x2000), 8);          // $0000-$3FFF: base & mask
	c.write(0x2000, 0x03);
	test::eq(c.read(0x6000), 11);         // 3 | 8
}

// Mappers the header doesn't name still get their cartridge when a game loads.
fn void unnamed_mappers_load_as_cartridges() @test {
	char[] rom = mem::temp_array(char, 0x40000);
	rom[0x147] = 0xBC; rom[0x149] = 0xC1; rom[0x14A] = 0x65;
	gameboy::GameBoy a = gameboy::new(false, DMG);
	defer a.destroy();
	a.load_rom(rom);
	assert(a.mmu.cart != null && a.mmu.cart.mbc == cart::Mbc.TPP1);

	char[] wt = mem::temp_array(char, 0x40000);
	wt[0x1000 : 11] = ((char[])"WISDOM TREE")[..];
	gameboy::GameBoy b = gameboy::new(false, DMG);
	defer b.destroy();
	b.load_rom(wt);
	assert(b.mmu.cart != null && b.mmu.cart.mbc == cart::Mbc.WISDOM);

	char[] sa = mem::temp_array(char, 0x40000);
	sa[0x104] = 0xCE; sa[0x144] = 0xED; sa[0x114] = 0x66;
	gameboy::GameBoy c = gameboy::new(false, DMG);
	defer c.destroy();
	c.load_rom(sa);
	assert(c.mmu.cart != null && c.mmu.cart.mbc == cart::Mbc.SACHEN && !c.mmu.cart.sachen.locked);
}
