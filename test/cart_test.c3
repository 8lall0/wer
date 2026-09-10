module cart_test;

import cart;
import std::core::test;

// A cartridge from a synthetic ROM of `banks` * 16 KiB where byte 0 of bank N
// is N. The temporary image is freed here (cart::new copies it).
fn cart::Cartridge* build(int banks, char type, char ram_code) {
	char[] rom = mem::new_array(char, (usz)banks * 0x4000);
	defer free(rom.ptr);
	for (int b = 0; b < banks; b++) rom[(usz)b * 0x4000] = (char)b;
	rom[0x147] = type;
	rom[0x148] = (char)(ilog2(banks) - 1);
	rom[0x149] = ram_code;
	return cart::new(rom, "x");
}

fn int ilog2(int v) {
	int n = 0;
	while (v > 1) { v >>= 1; n++; }
	return n;
}

fn void mbc0_is_flat() @test
{
	cart::Cartridge* c = build(2, 0x00, 0);
	defer c.free();
	test::@check(c.mbc == cart::Mbc.NONE, "mbc type");
	test::eq((char)0, c.read(0x0000));
	test::eq((char)1, c.read(0x4000)); // bank 1 fixed
}

fn void mbc1_rom_bank_switching() @test
{
	cart::Cartridge* c = build(8, 0x01, 0);
	defer c.free();
	test::@check(c.mbc == cart::Mbc.MBC1, "mbc type");

	test::eq((char)0, c.read(0x0000)); // bank 0 always
	test::eq((char)1, c.read(0x4000)); // default bank 1

	c.write(0x2000, 0x05);             // select bank 5
	test::eq((char)5, c.read(0x4000));

	c.write(0x2000, 0x00);             // bank 0 request -> reads as bank 1
	test::eq((char)1, c.read(0x4000));
}

fn void mbc1_ram_enable_and_banking() @test
{
	cart::Cartridge* c = build(4, 0x03, 0x03); // 32 KiB RAM (4 banks)
	defer c.free();
	test::@check(c.ram.len == 0x8000, "ram size");

	c.write(0xA000, 0x42);            // RAM disabled -> write ignored
	c.write(0x0000, 0x0A);            // enable RAM
	c.write(0xA000, 0x42);
	test::eq((char)0x42, c.read(0xA000));

	c.write(0x6000, 0x01);            // advanced (mode 1) banking
	c.write(0x4000, 0x02);            // RAM bank 2
	c.write(0xA000, 0x99);
	test::eq((char)0x99, c.read(0xA000));

	c.write(0x4000, 0x00);            // back to RAM bank 0
	test::eq((char)0x42, c.read(0xA000));
}

fn void mbc3_rom_bank_7bit() @test
{
	cart::Cartridge* c = build(0x20, 0x13, 0x03); // 32 banks
	defer c.free();
	c.write(0x2000, 0x1F);            // bank 31 (7-bit register, no 5-bit wrap)
	test::eq((char)0x1F, c.read(0x4000));
}

fn void mbc5_rom_bank_9bit() @test
{
	cart::Cartridge* c = build(0x200, 0x19, 0); // 512 banks
	defer c.free();
	c.write(0x2000, 0x00);            // low 8 bits = 0
	c.write(0x3000, 0x01);            // bit 8 = 1  -> bank 0x100
	test::eq((char)0x00, c.read(0x4000)); // bank 0x100, byte 0 = 0x00 (256 & 0xFF)
	c.write(0x2000, 0x05);            // bank 0x105
	test::eq((char)0x05, c.read(0x4000));

	c.write(0x2000, 0x00);            // MBC5 bank 0 is a *real* bank 0 (no +1)
	c.write(0x3000, 0x00);
	test::eq((char)0x00, c.read(0x4000));
}

fn void mbc2_builtin_ram() @test
{
	cart::Cartridge* c = build(4, 0x06, 0);
	defer c.free();
	test::@check(c.mbc == cart::Mbc.MBC2, "mbc type");
	test::@check(c.ram.len == 0x200, "ram size");

	c.write(0x0000, 0x0A);            // bit 8 of addr clear -> RAM enable
	c.write(0xA000, 0xFF);
	test::eq((char)0xFF, c.read(0xA000)); // stored as 4-bit, read back with 0xF0

	c.write(0x0100, 0x03);            // bit 8 set -> ROM bank select
	test::eq((char)0x03, c.read(0x4000));
}
