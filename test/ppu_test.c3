module ppu_test;

import gameboy, ppu;
import std::core::test;

fn void advance(gameboy::GameBoy* gb, int mcycles) {
	for (int i = 0; i < mcycles; i++) gb.mmu.tick(1);
}

// ---------------------------------------------------------------------------
// Register routing through the MMU
// ---------------------------------------------------------------------------

fn void registers_route_to_ppu() @test
{
	gameboy::GameBoy gb = gameboy::new(false);
	defer gb.destroy();

	gb.mmu.set(0xFF40, 0x91);
	gb.mmu.set(0xFF42, 0x33); // SCY
	gb.mmu.set(0xFF47, 0xE4); // BGP
	gb.mmu.set(0xFF4A, 0x50); // WY

	test::eq((char)0x91, gb.mmu.get(0xFF40));
	test::eq((char)0x33, gb.mmu.ppu.scy);
	test::eq((char)0xE4, gb.mmu.get(0xFF47));
	test::eq((char)0x50, gb.mmu.ppu.wy);

	// STAT bit 7 always reads 1; only bits 3-6 are writable.
	gb.mmu.set(0xFF41, 0x78);
	test::@check((gb.mmu.get(0xFF41) & 0x80) != 0, "STAT bit 7 reads 1");
	test::eq((char)0x78, (char)(gb.mmu.ppu.stat & 0x78));

	// LY is read-only.
	gb.mmu.set(0xFF44, 0x42);
	test::@check(gb.mmu.get(0xFF44) != 0x42, "LY ignores writes");
}

// ---------------------------------------------------------------------------
// Timing state machine
// ---------------------------------------------------------------------------

fn void mode_and_ly_progression() @test
{
	gameboy::GameBoy gb = gameboy::new(false);
	defer gb.destroy();
	gb.mmu.set(0xFF40, ppu::LCDC_ENABLE);

	test::eq((char)2, (char)(gb.mmu.get(0xFF41) & 3)); // line 0 starts in OAM scan

	advance(&gb, 20);  // 80 dots -> drawing
	test::eq((char)3, (char)(gb.mmu.get(0xFF41) & 3));

	advance(&gb, 60);  // 240 more dots (>172) -> HBlank
	test::eq((char)0, (char)(gb.mmu.get(0xFF41) & 3));

	advance(&gb, 114); // finish the line
	test::eq((char)1, gb.mmu.get(0xFF44)); // LY = 1

	// Run to the top of VBlank.
	advance(&gb, 114 * 143);
	test::eq((char)144, gb.mmu.get(0xFF44));
	test::eq((char)1, (char)(gb.mmu.get(0xFF41) & 3)); // VBlank mode
}

fn void vblank_interrupt_fires_once_per_frame() @test
{
	gameboy::GameBoy gb = gameboy::new(false);
	defer gb.destroy();
	gb.mmu.set(0xFF40, ppu::LCDC_ENABLE);

	advance(&gb, 114 * 143); // just before line 144
	test::@check((gb.mmu.get(0xFF0F) & 0x01) == 0, "no VBlank yet");

	advance(&gb, 114 * 2);   // into VBlank
	test::@check((gb.mmu.get(0xFF0F) & 0x01) != 0, "VBlank interrupt requested");
}

fn void lyc_interrupt() @test
{
	gameboy::GameBoy gb = gameboy::new(false);
	defer gb.destroy();
	gb.mmu.set(0xFF40, ppu::LCDC_ENABLE);
	gb.mmu.set(0xFF45, 10);          // LYC
	gb.mmu.set(0xFF41, ppu::STAT_LYC_IE);

	advance(&gb, 114 * 9); // LY = 9
	test::@check((gb.mmu.get(0xFF0F) & 0x02) == 0, "no STAT int before LY==LYC");
	advance(&gb, 114);     // LY = 10
	test::eq((char)10, gb.mmu.get(0xFF44));
	test::@check((gb.mmu.get(0xFF0F) & 0x02) != 0, "STAT int on LY==LYC");
	test::@check((gb.mmu.get(0xFF41) & ppu::STAT_LYC_FLAG) != 0, "LYC flag set");
}

fn void lcd_off_holds_ly_zero() @test
{
	gameboy::GameBoy gb = gameboy::new(false);
	defer gb.destroy();
	gb.mmu.set(0xFF40, 0x00); // LCD disabled
	advance(&gb, 5000);
	test::eq((char)0, gb.mmu.get(0xFF44));
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

// Fill 8x8 tile `n` (at $8000 + n*16) with colour index `cidx` on every pixel.
fn void solid_tile(gameboy::GameBoy* gb, int n, char cidx) {
	char lo = (cidx & 1) ? (char)0xFF : (char)0x00;
	char hi = (cidx & 2) ? (char)0xFF : (char)0x00;
	for (int r = 0; r < 8; r++) {
		gb.mmu.set((ushort)(0x8000 + n * 16 + r * 2), lo);
		gb.mmu.set((ushort)(0x8000 + n * 16 + r * 2 + 1), hi);
	}
}

fn void renders_background_tile() @test
{
	gameboy::GameBoy gb = gameboy::new(false);
	defer gb.destroy();

	gb.mmu.set(0xFF47, 0xE4); // BGP: identity (idx n -> shade n)
	solid_tile(&gb, 1, 3);    // tile 1 = solid colour 3
	gb.mmu.set(0x9800, 0x01); // tilemap (0,0) -> tile 1  (0,1..) stay tile 0 = blank
	gb.mmu.set(0xFF40, ppu::LCDC_ENABLE | ppu::LCDC_BG_ENABLE | ppu::LCDC_TILE_DATA);

	advance(&gb, 80); // past the mode 3 -> 0 transition of line 0

	char[] fb = gb.framebuffer();
	test::eq((char)3, fb[0]);
	test::eq((char)3, fb[7]);
	test::eq((char)0, fb[8]); // second tile column is blank
}

fn void background_scroll() @test
{
	gameboy::GameBoy gb = gameboy::new(false);
	defer gb.destroy();

	gb.mmu.set(0xFF47, 0xE4);
	solid_tile(&gb, 1, 3);
	gb.mmu.set(0x9800, 0x01);         // only tile (0,0) is solid
	gb.mmu.set(0xFF43, 4);            // SCX = 4: shift view left by 4
	gb.mmu.set(0xFF40, ppu::LCDC_ENABLE | ppu::LCDC_BG_ENABLE | ppu::LCDC_TILE_DATA);

	advance(&gb, 80);

	char[] fb = gb.framebuffer();
	test::eq((char)3, fb[0]);  // screen x0 now shows tile pixel 4
	test::eq((char)3, fb[3]);  // .. through pixel 7
	test::eq((char)0, fb[4]);  // then into the blank tile
}

fn void renders_sprite_over_background() @test
{
	gameboy::GameBoy gb = gameboy::new(false);
	defer gb.destroy();

	gb.mmu.set(0xFF47, 0xE4);
	gb.mmu.set(0xFF48, 0xE4); // OBP0
	solid_tile(&gb, 2, 2);    // sprite tile = colour 2

	// OAM entry 0: on-screen at (0,0), tile 2.
	gb.mmu.set(0xFE00, 16);   // y = 16 -> top row 0
	gb.mmu.set(0xFE01, 8);    // x = 8  -> left column 0
	gb.mmu.set(0xFE02, 2);
	gb.mmu.set(0xFE03, 0x00);

	gb.mmu.set(0xFF40, ppu::LCDC_ENABLE | ppu::LCDC_BG_ENABLE
		| ppu::LCDC_TILE_DATA | ppu::LCDC_OBJ_ENABLE);

	advance(&gb, 80);

	char[] fb = gb.framebuffer();
	test::eq((char)2, fb[0]); // sprite pixel
	test::eq((char)2, fb[7]);
	test::eq((char)0, fb[8]); // past the sprite -> background (blank)
}

fn void sprite_behind_background_priority() @test
{
	gameboy::GameBoy gb = gameboy::new(false);
	defer gb.destroy();

	gb.mmu.set(0xFF47, 0xE4);
	gb.mmu.set(0xFF48, 0xE4);
	solid_tile(&gb, 1, 1); // BG tile colour 1 (non-zero -> wins over "behind" sprite)
	solid_tile(&gb, 2, 3); // sprite tile colour 3
	gb.mmu.set(0x9800, 0x01);

	gb.mmu.set(0xFE00, 16);
	gb.mmu.set(0xFE01, 8);
	gb.mmu.set(0xFE02, 2);
	gb.mmu.set(0xFE03, 0x80); // priority: behind BG colours 1-3

	gb.mmu.set(0xFF40, ppu::LCDC_ENABLE | ppu::LCDC_BG_ENABLE
		| ppu::LCDC_TILE_DATA | ppu::LCDC_OBJ_ENABLE);

	advance(&gb, 80);

	char[] fb = gb.framebuffer();
	test::eq((char)1, fb[0]); // BG shows through
}

// ---------------------------------------------------------------------------
// OAM DMA
// ---------------------------------------------------------------------------

fn void oam_dma_copies_page() @test
{
	gameboy::GameBoy gb = gameboy::new(false);
	defer gb.destroy();

	for (int i = 0; i < 0xA0; i++) {
		gb.mmu.set((ushort)(0xC000 + i), (char)(i + 1));
	}
	gb.mmu.set(0xFF46, 0xC0); // DMA from $C000

	test::eq((char)1, gb.mmu.get(0xFE00));
	test::eq((char)0xA0, gb.mmu.get(0xFE9F));
	test::eq((char)0xC0, gb.mmu.get(0xFF46)); // register reads back
}
