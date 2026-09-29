module cgb_test;

import gameboy, mmu;
import std::core::test;

// A 32 KiB CGB-only ROM with `code` at $0100.
fn char[] cgb_rom(char[] code)
{
	char[] rom = mem::new_array(char, 0x8000);
	rom[0x143] = 0xC0;
	foreach (i, b : code) rom[0x100 + i] = b;
	return rom;
}

fn void speed_switch_with_stop() @test
{
	// LD A,$01 ; LDH ($4D),A ; STOP ; JR -2 (spin)
	char[] rom = cgb_rom({ 0x3E, 0x01, 0xE0, 0x4D, 0x10, 0x00, 0x18, 0xFE });
	defer free(rom.ptr);
	gameboy::GameBoy gb = gameboy::new(false, CGB);
	defer gb.destroy();
	gb.load_rom(rom);

	test::eq((char)0x7E, gb.mmu.get(0xFF4D));   // normal speed, not armed
	gb.step();
	gb.step();
	test::eq((char)0x7F, gb.mmu.get(0xFF4D));   // armed
	ulong before = gb.cpu.clk;
	gb.step();                                   // STOP: switch
	test::eq((char)0xFE, gb.mmu.get(0xFF4D));   // double speed, disarmed
	test::@check(gb.cpu.clk - before > 2000, "the CPU pauses during the switch");
	test::@check(gb.mmu.double_speed, "double speed on");
}

fn void double_speed_ppu_keeps_real_time() @test
{
	// LD A,$01 ; LDH ($4D),A ; STOP ; JR -2
	char[] rom = cgb_rom({ 0x3E, 0x01, 0xE0, 0x4D, 0x10, 0x00, 0x18, 0xFE });
	defer free(rom.ptr);
	gameboy::GameBoy gb = gameboy::new(false, CGB);
	defer gb.destroy();
	gb.load_rom(rom);
	for (int i = 0; i < 3; i++) gb.step();
	gb.run_frame();                              // finish the frame the switch was in

	ulong before = gb.cpu.clk;
	gb.run_frame();
	ulong mcycles = gb.cpu.clk - before;
	// One frame is 35112 CPU M-cycles in double speed (give or take the
	// last instruction).
	test::@check(mcycles >= 35110 && mcycles <= 35116, "frame length in double speed");
}

fn void stop_without_arming_keeps_speed() @test
{
	// STOP ; JR -2
	char[] rom = cgb_rom({ 0x10, 0x00, 0x18, 0xFE });
	defer free(rom.ptr);
	gameboy::GameBoy gb = gameboy::new(false, CGB);
	defer gb.destroy();
	gb.load_rom(rom);
	gb.step();
	test::@check(!gb.mmu.double_speed, "no switch without KEY1 bit 0");
}

fn void key1_absent_for_dmg_games() @test
{
	char[] rom = mem::new_array(char, 0x8000);   // $0143 = 0: DMG game
	defer free(rom.ptr);
	gameboy::GameBoy gb = gameboy::new(false, CGB);
	defer gb.destroy();
	gb.load_rom(rom);
	gb.mmu.set(0xFF4D, 0x01);
	test::eq((char)0xFF, gb.mmu.get(0xFF4D));
}

// A CGB in CGB mode running `code`, with WRAM at $C000 holding 0, 1, 2, ...
fn gameboy::GameBoy cgb_with_pattern(char[] rom)
{
	gameboy::GameBoy gb = gameboy::new(false, CGB);
	gb.load_rom(rom);
	for (int i = 0; i < 0x800; i++) gb.mmu.set((ushort)(0xC000 + i), (char)i);
	return gb;
}

fn void vdma_program(gameboy::GameBoy* gb, ushort src, ushort dst)
{
	gb.mmu.set(0xFF51, (char)(src >> 8));
	gb.mmu.set(0xFF52, (char)src);
	gb.mmu.set(0xFF53, (char)(dst >> 8));
	gb.mmu.set(0xFF54, (char)dst);
}

fn void general_purpose_dma_copies_everything() @test
{
	char[] rom = cgb_rom({ 0x18, 0xFE });
	defer free(rom.ptr);
	gameboy::GameBoy gb = cgb_with_pattern(rom);
	defer gb.destroy();
	gb.mmu.set(0xFF40, 0x00);                    // LCD off: VRAM always reachable

	gb.mmu.set(0xFF4F, 1);                       // into VRAM bank 1
	vdma_program(&gb, 0xC105, 0x8203);          // low 4 bits are ignored
	gb.mmu.set(0xFF55, 0x02);                    // 3 blocks, general purpose
	for (int i = 0; i < 48; i++) test::eq((char)(0x00 + i), gb.mmu.ppu.vram1[0x200 + i]);
	test::eq((char)0x00, gb.mmu.ppu.vram1[0x230]); // stops after 3 blocks
	test::eq((char)0xFF, gb.mmu.get(0xFF55));
	test::eq(24, gb.mmu.vdma_stall);             // 8 M-cycles per block

	ulong before = gb.cpu.clk;
	gb.step();
	test::@check(gb.cpu.clk - before >= 24, "the CPU waits for the copy");
	test::eq(0, gb.mmu.vdma_stall);
}

fn void hblank_dma_one_block_per_hblank() @test
{
	char[] rom = cgb_rom({ 0x18, 0xFE });
	defer free(rom.ptr);
	gameboy::GameBoy gb = cgb_with_pattern(rom);
	defer gb.destroy();

	vdma_program(&gb, 0xC000, 0x8000);
	gb.mmu.set(0xFF55, 0x83);                    // 4 blocks, HBlank DMA
	test::eq((char)0x03, gb.mmu.get(0xFF55));    // running, 3 left after this

	// Run until one HBlank has happened.
	int hblanks = 0;
	char last = gb.mmu.ppu.mode;
	while (hblanks < 1) {
		gb.step();
		if (gb.mmu.ppu.mode == 0 && last != 0) hblanks++;
		last = gb.mmu.ppu.mode;
	}
	test::eq((char)0x02, gb.mmu.get(0xFF55));
	test::eq((char)0x0F, gb.mmu.ppu.vram[0x0F]);
	test::eq((char)0x00, gb.mmu.ppu.vram[0x10]);  // second block not yet

	// Stop it: bit 7 set, blocks left kept.
	gb.mmu.set(0xFF55, 0x00);
	test::eq((char)0x82, gb.mmu.get(0xFF55));
	for (int i = 0; i < 1000; i++) gb.step();
	test::eq((char)0x00, gb.mmu.ppu.vram[0x10]);  // nothing more copied
}

fn void hblank_dma_finishes() @test
{
	char[] rom = cgb_rom({ 0x18, 0xFE });
	defer free(rom.ptr);
	gameboy::GameBoy gb = cgb_with_pattern(rom);
	defer gb.destroy();

	vdma_program(&gb, 0xC000, 0x9000);
	gb.mmu.set(0xFF55, 0x81);                    // 2 blocks
	gb.run_frame();
	test::eq((char)0xFF, gb.mmu.get(0xFF55));
	for (int i = 0; i < 32; i++) test::eq((char)i, gb.mmu.ppu.vram[0x1000 + i]);
	test::eq((char)0x00, gb.mmu.ppu.vram[0x1020]);
}

// A 32 KiB DMG-only ROM ($0143 = 0) spinning at $0100.
fn char[] dmg_rom()
{
	char[] rom = mem::new_array(char, 0x8000);
	rom[0x100] = 0x18;
	rom[0x101] = 0xFE;
	return rom;
}

fn void boot_rom_runs_dmg_game_in_compat_mode() @test
{
	char[] rom = dmg_rom();
	defer free(rom.ptr);
	gameboy::GameBoy gb = gameboy::new(true, CGB);
	defer gb.destroy();
	gb.load_rom(rom);
	test::@check(gb.mmu.cgb_mode, "CGB features on while the boot ROM runs");

	for (int f = 0; f < 600 && gb.mmu.boot_active; f++) gb.run_frame();
	test::@check(!gb.mmu.boot_active, "the boot ROM finished");
	test::@check(!gb.mmu.cgb_mode && gb.mmu.ppu.compat, "DMG game: compatibility mode");
	test::eq((char)0xFF, gb.mmu.get(0xFF4C));    // KEY0 gone after boot
	test::eq((char)0xFF, gb.mmu.get(0xFF70));    // CGB registers locked
	test::@check(gb.cpu.pc >= 0x100 && gb.cpu.pc < 0x102, "running the game");
}

fn void boot_rom_keeps_cgb_mode_for_cgb_game() @test
{
	char[] rom = cgb_rom({ 0x18, 0xFE });
	defer free(rom.ptr);
	gameboy::GameBoy gb = gameboy::new(true, CGB);
	defer gb.destroy();
	gb.load_rom(rom);
	for (int f = 0; f < 600 && gb.mmu.boot_active; f++) gb.run_frame();
	test::@check(!gb.mmu.boot_active, "the boot ROM finished");
	test::@check(gb.mmu.cgb_mode && !gb.mmu.ppu.compat, "CGB game: CGB mode");
}

fn void key0_only_while_booting() @test
{
	mmu::Mmu m;
	m.model = CGB;
	m.cgb_mode = true;
	m.boot_active = true;
	m.set(0xFF4C, 0x04);
	m.set(0xFF50, 0x01);
	test::@check(!m.cgb_mode && m.ppu.compat && m.ppu.opri == 1, "KEY0 bit 2 selects compatibility mode");
	m.set(0xFF4C, 0x80);                          // too late: ignored
	test::eq((char)0x04, m.key0);
}

fn void compat_without_boot_rom_is_grey() @test
{
	char[] rom = dmg_rom();
	defer free(rom.ptr);
	gameboy::GameBoy gb = gameboy::new(false, CGB);
	defer gb.destroy();
	gb.load_rom(rom);
	test::@check(gb.mmu.ppu.compat, "compatibility mode");

	gb.mmu.set(0xFF47, 0xE4);                     // BGP: identity
	gb.mmu.ppu.line = 0;
	gb.mmu.ppu.render_line();                     // an empty BG: colour 0
	char[] rgb = mem::new_array(char, gameboy::MAX_FRAME_RGB);
	defer free(rgb.ptr);
	gb.frame_rgb(rgb, {});
	test::eq((char)0xFF, rgb[0]);                 // white, through BG palette 0
	gb.mmu.set(0xFF47, 0xFF);                     // everything maps to shade 3
	gb.mmu.ppu.render_line();
	gb.frame_rgb(rgb, {});
	test::eq((char)0x00, rgb[0]);                 // black
}
