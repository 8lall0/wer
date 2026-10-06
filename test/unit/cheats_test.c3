module cheats_test;
import gameboy, mmu;
import std::core::test;

fn void parses_codes() @test {
	mmu::Cheat g = mmu::parse_cheat("00A-17B-C49")!!;
	assert(g.genie && g.compare);
	test::eq(g.value, 0x00);
	test::eq(g.addr, (ushort)0x4A17);    // (B^F) A 1 7
	test::eq(g.old, 0xC8);              // C9 rotated right by 2, XOR BA
	mmu::Cheat short_code = mmu::parse_cheat("3E1-23C")!!;
	assert(short_code.genie && !short_code.compare);
	test::eq(short_code.value, 0x3E);
	test::eq(short_code.addr, (ushort)0x3123);
	mmu::Cheat s = mmu::parse_cheat("01FF34D1")!!;
	assert(!s.genie);
	test::eq(s.type, 0x01);
	test::eq(s.value, 0xFF);
	test::eq(s.addr, (ushort)0xD134);  // low byte first
	test::@check(@catch(mmu::parse_cheat("hello")) == mmu::NOT_A_CODE, "not hex");
	test::@check(@catch(mmu::parse_cheat("1234567")) == mmu::NOT_A_CODE, "7 digits");
	test::@check(@catch(mmu::parse_cheat("00A-170-C49")) == mmu::NOT_A_CODE, "a Game Genie address past ROM");
}

fn void genie_patches_rom_and_shark_writes_ram() @test {
	char[] rom = mem::temp_array(char, 0x8000);
	rom[0x0150] = 0x11;
	rom[0x0151] = 0x22;
	rom[0x100] = 0x18; // jr $
	rom[0x101] = 0xFE;
	gameboy::GameBoy gb = gameboy::new(false, DMG);
	defer gb.destroy();
	gb.load_rom(rom);
	mmu::Cheats c;
	gb.mmu.cheats = &c;
	// $0150 reads $99; $0151 only where the ROM holds $33 (it holds $22).
	c.add("991-50F")!!;
	mmu::Cheat k = mmu::parse_cheat("880-15F-E6A")!!;
	k.addr = 0x0151;
	c.list[c.count++] = k;
	c.recount();
	test::eq(gb.mmu.get(0x0150), 0x99);
	test::eq(gb.mmu.get(0x0151), k.old == 0x22 ? 0x88 : 0x22);
	c.list[0].on = false;
	c.recount();
	test::eq(gb.mmu.get(0x0150), 0x11);
	// GameShark: $C123 = $42, each frame.
	c.add("0142 23C1")!!;
	gb.run_frame();
	test::eq(gb.mmu.get(0xC123), 0x42);
	gb.mmu.set(0xC123, 0);
	gb.run_frame();
	test::eq(gb.mmu.get(0xC123), 0x42);
}
