module mbc7_test;
import cart, display, sdl;
import std::core::test;

// MBC7: the accelerometer registers and the 93LC56 EEPROM protocol, driven
// the way games do it (bit-banged through $A080).

fn cart::Cartridge* new_mbc7() {
	char[] rom = mem::temp_array(char, 0x8000);
	rom[0x147] = 0x22;
	return cart::new(rom, "");
}

fn void enable(cart::Cartridge* c) {
	c.write(0x0000, 0x0A);
	c.write(0x4000, 0x40);
}

// One EEPROM clock with CS high and DI = bit; returns DO after it.
fn bool clock(cart::Cartridge* c, bool bit) {
	char di = bit ? 2 : 0;
	c.write(0xA080, 0x80 | di);
	c.write(0xA080, 0xC0 | di);
	return (c.read(0xA080) & 1) != 0;
}

fn void command(cart::Cartridge* c, uint bits, int n) {
	for (int i = n - 1; i >= 0; i--) clock(c, ((bits >> i) & 1) != 0);
}

fn void deselect(cart::Cartridge* c) => c.write(0xA080, 0x00);

fn ushort read_word(cart::Cartridge* c, int word) {
	command(c, 0b110 << 8 | (uint)word, 11); // start, READ, address
	ushort v;
	for (int i = 0; i < 16; i++) v = (ushort)(v << 1 | (clock(c, false) ? 1 : 0));
	deselect(c);
	return v;
}

fn void write_word(cart::Cartridge* c, int word, ushort value) {
	command(c, 0b101 << 8 | (uint)word, 11); // start, WRITE, address
	command(c, value, 16);
	deselect(c);
}

fn void registers_need_both_enables() @test {
	cart::Cartridge* c = new_mbc7();
	defer c.free();
	test::eq(c.read(0xA020), 0xFF);
	c.write(0x0000, 0x0A);
	test::eq(c.read(0xA020), 0xFF);
	c.write(0x4000, 0x40);
	test::eq(c.read(0xA020), 0x00); // the latch starts at $8000
	test::eq(c.read(0xA030), 0x80);
}

fn void tilt_is_latched_around_81d0() @test {
	cart::Cartridge* c = new_mbc7();
	defer c.free();
	enable(c);
	c.tilt_x = 1;    // right
	c.tilt_y = -0.5; // away from the player
	c.write(0xA000, 0x55);
	c.write(0xA010, 0xAA);
	ushort x = (ushort)(c.read(0xA020) | (ushort)c.read(0xA030) << 8);
	ushort y = (ushort)(c.read(0xA040) | (ushort)c.read(0xA050) << 8);
	test::eq(x, 0x81D0 - 0x70);
	test::eq(y, 0x81D0 + 0x38);
	// The next $55 clears it back to $8000.
	c.write(0xA000, 0x55);
	test::eq(c.read(0xA030), 0x80);
}

fn void eeprom_write_needs_ewen_then_reads_back() @test {
	cart::Cartridge* c = new_mbc7();
	defer c.free();
	enable(c);
	test::eq(read_word(c, 5), 0xFFFF); // blank
	write_word(c, 5, 0x1234);          // not enabled yet: ignored
	test::eq(read_word(c, 5), 0xFFFF);
	command(c, 0b100_11 << 6, 11);     // EWEN
	deselect(c);
	write_word(c, 5, 0x1234);
	test::eq(read_word(c, 5), 0x1234);
	test::eq(c.ram[10], 0x34);         // little-endian words, as SameBoy saves them
	test::eq(c.ram[11], 0x12);
	command(c, 0b111 << 8 | 5, 11);    // ERASE
	deselect(c);
	test::eq(read_word(c, 5), 0xFFFF);
	command(c, 0b100_00 << 6, 11);     // EWDS
	deselect(c);
	write_word(c, 5, 0x0042);
	test::eq(read_word(c, 5), 0xFFFF);
}

fn void rumble_bit_on_rumble_carts_only() @test {
	char[] rom = mem::temp_array(char, 0x8000);
	rom[0x147] = 0x1C; // MBC5+RUMBLE
	cart::Cartridge* c = cart::new(rom, "");
	defer c.free();
	c.write(0x4000, 0x08);
	assert(c.rumble);
	test::eq(c.ram_bank, 0u);
	c.write(0x4000, 0x03);
	assert(!c.rumble);
	rom[0x147] = 0x1B; // MBC5+RAM+BATTERY: bit 3 is a RAM bank bit
	cart::Cartridge* d = cart::new(rom, "");
	defer d.free();
	d.write(0x4000, 0x08);
	assert(!d.rumble);
	test::eq(d.ram_bank, 8u);
}

// The phone's accelerometer as screen tilt, for each way it may be held.
fn void accelerometer_follows_the_screen() @test {
	float g = sdl::STANDARD_GRAVITY;
	// Portrait, right edge down: the reading leans to -x.
	test::eq(display::screen_tilt(-g, 0, 0), (float[<2>]){ 1, 0 });
	// Portrait, bottom edge down: +y.
	test::eq(display::screen_tilt(0, g, 0), (float[<2>]){ 0, 1 });
	// Landscape, turned counterclockwise (the device's top on the left): the
	// screen's right edge is the device's bottom, its bottom edge the
	// device's left.
	test::eq(display::screen_tilt(0, g, 1), (float[<2>]){ 1, 0 });
	test::eq(display::screen_tilt(g, 0, 1), (float[<2>]){ 0, 1 });
	test::eq(display::screen_tilt(0, g, 3), (float[<2>]){ -1, 0 });
	// Upside down.
	test::eq(display::screen_tilt(g, 0, 2), (float[<2>]){ 1, 0 });
}
