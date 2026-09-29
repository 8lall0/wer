module boot_test;

import gameboy;
import std::core::test;

// The DMG boot ROM (bootix with the REW logo) runs to the game with the
// post-boot registers, leaving its 8x2-tile logo in the tile map.
fn void dmg_boot_rom_reaches_game() @test
{
	char[] rom = mem::new_array(char, 0x8000);
	defer free(rom.ptr);
	rom[0x100] = 0x18;                            // JR -2
	rom[0x101] = 0xFE;
	gameboy::GameBoy gb = gameboy::new(true);
	defer gb.destroy();
	gb.load_rom(rom);

	for (int f = 0; f < 600 && gb.mmu.boot_active; f++) gb.run_frame();
	test::@check(!gb.mmu.boot_active, "the boot ROM finished");
	test::@check(gb.cpu.pc >= 0x100 && gb.cpu.pc < 0x102, "running the game");
	test::eq((char)0x01, gb.cpu.af.hi);
	test::eq((char)0x01, gb.mmu.ppu.vram[0x1906]); // first logo tile, row 1
	test::eq((char)0x10, gb.mmu.ppu.vram[0x192D]); // last logo tile, row 2
	test::eq((char)0x00, gb.mmu.ppu.vram[0x1905]);
}
