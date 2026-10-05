module mappers_test;
import cart;
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
