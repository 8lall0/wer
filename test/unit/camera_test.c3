module camera_test;
import cart;
import std::core::test;

// The Game Boy Camera: a shot takes time, then the picture is in RAM bank 0
// as tiles, dithered by the thresholds the game set.

fn cart::Cartridge* new_camera() {
	char[] rom = mem::temp_array(char, 0x10000);
	rom[0x147] = 0xFC;
	rom[0x149] = 4; // 128 KiB
	return cart::new(rom, "");
}

fn void shot_takes_time_then_fills_ram() @test {
	cart::Cartridge* c = new_camera();
	defer c.free();
	// Left half black, right half white.
	for (int y = 0; y < cart::CAM_H; y++) {
		for (int x = 0; x < cart::CAM_W; x++) c.camera.sensor[y * cart::CAM_W + x] = x < 64 ? 0 : 255;
	}
	c.camera.has_image = true;
	c.write(0x0000, 0x0A);
	c.write(0x4000, 0x10);    // the registers
	c.write(0xA001, 0x04);    // gain 1.0
	c.write(0xA002, 0x10);    // exposure $1000: brightness unchanged
	c.write(0xA003, 0x00);
	for (int i = 6; i < 0x36; i += 3) {
		c.write((ushort)(0xA000 + i), 0x40);
		c.write((ushort)(0xA000 + i + 1), 0x80);
		c.write((ushort)(0xA000 + i + 2), 0xC0);
	}
	c.write(0xA000, 0x01);    // shoot
	test::eq(c.read(0xA000), 0x01);
	c.camera_tick(100_000);
	test::eq(c.read(0xA000), 0x01); // still exposing
	c.camera_tick(500_000);
	test::eq(c.read(0xA000), 0x00);
	// The first tile row: tile 0 black (both planes set), tile 15 white.
	c.write(0x4000, 0x00);
	test::eq(c.read(0xA100), 0xFF);
	test::eq(c.read(0xA101), 0xFF);
	test::eq(c.read(0xA100 + 15 * 16), 0x00);
	test::eq(c.read(0xA101 + 15 * 16), 0x00);
	// The last tile, row 7 (tile 16*14-1).
	test::eq(c.read((ushort)(0xA100 + 223 * 16 + 14)), 0x00);
}

fn void ram_waits_while_busy() @test {
	cart::Cartridge* c = new_camera();
	defer c.free();
	c.write(0x0000, 0x0A);
	c.write(0x4000, 0x01);
	c.write(0xA123, 0x55);
	test::eq(c.read(0xA123), 0x55);
	c.write(0x4000, 0x10);
	c.write(0xA000, 0x01);
	c.write(0x4000, 0x01);
	test::eq(c.read(0xA123), 0x00); // busy
	c.write(0xA123, 0x66);          // dropped
	c.camera_tick(1_000_000);
	test::eq(c.read(0xA123), 0x55);
}
