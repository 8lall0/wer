module boot_test;

import gameboy;
import std::core::test;

// The DMG boot ROM runs to the game with the post-boot registers, leaving its
// 8x2-tile WER logo in the tile map and, like the original, (R) as tile 25.
fn void dmg_boot_rom_reaches_game() @test
{
	char[] rom = mem::new_array(char, 0x8000);
	defer free(rom.ptr);
	rom[0x100] = 0x18;                            // JR -2
	rom[0x101] = 0xFE;
	gameboy::GameBoy gb = gameboy::new(true);
	defer gb.destroy();
	gb.load_rom(rom);

	ulong limit = gb.cpu.clk + 4194304UL; // 4 s
	while (gb.mmu.boot_active && gb.cpu.clk < limit) gb.step();
	test::@check(!gb.mmu.boot_active, "the boot ROM finished");
	// The hand-over: the registers a DMG leaves, at $0100.
	test::eq((ushort)0x0100, gb.cpu.pc);
	test::eq((ushort)0x01B0, gb.cpu.af.reg);
	test::eq((ushort)0x0013, gb.cpu.bc.reg);
	test::eq((ushort)0x00D8, gb.cpu.de.reg);
	test::eq((ushort)0x014D, gb.cpu.hl.reg);
	test::eq((ushort)0xFFFE, gb.cpu.sp);
	test::eq((char)0x30, gb.mmu.ppu.vram[0x1906]); // first WER tile, row 1
	test::eq((char)0x3F, gb.mmu.ppu.vram[0x192D]); // last WER tile, row 2
	test::eq((char)0x00, gb.mmu.ppu.vram[0x1905]);
	// Like the original: tile 25 is (R), tiles 1-24 the header logo.
	test::eq((char)0x3C, gb.mmu.ppu.vram[0x190]);
	test::eq((char)0x42, gb.mmu.ppu.vram[0x192]);
}
