module mmu_test;

import mmu;
import std::core::test;

fn void wram_and_echo_alias() @test
{
	mmu::Mmu m;
	m.set(0xC000, 0x42);
	test::eq((char)0x42, m.get(0xE000)); // echo of C000-DDFF
	m.set(0xE100, 0x77);
	test::eq((char)0x77, m.get(0xC100));
}

fn void rom_area_is_read_only() @test
{
	mmu::Mmu m;
	m.load(0x2000, { 0x20, 0x99 });
	test::eq((char)0x20, m.get(0x2000));

	// A game writing an MBC bank-select value must NOT alter the ROM buffer.
	m.set(0x2000, 0x01);
	m.set(0x0147, 0xEE);
	test::eq((char)0x20, m.get(0x2000));
	test::eq((char)0x99, m.get(0x2001));
}

fn void unusable_region_reads_ff() @test
{
	mmu::Mmu m;
	test::eq((char)0xFF, m.get(0xFEA0));
	test::eq((char)0xFF, m.get(0xFEFF));
}

fn void ie_register() @test
{
	mmu::Mmu m;
	m.set(0xFFFF, 0x1F);
	test::eq((char)0x1F, m.get(0xFFFF));
}

fn void hram_roundtrip() @test
{
	mmu::Mmu m;
	m.set(0xFF80, 0xAA);
	m.set(0xFFFE, 0xBB);
	test::eq((char)0xAA, m.get(0xFF80));
	test::eq((char)0xBB, m.get(0xFFFE));
}

fn void div_write_resets_timer_via_mmu() @test
{
	mmu::Mmu m;
	m.tick(80); // 320 T-cycles -> DIV = 1
	test::eq((char)1, m.get(0xFF04));
	m.set(0xFF04, 0x55); // any write resets
	test::eq((char)0, m.get(0xFF04));
}

fn void tac_unused_bits_read_high() @test
{
	mmu::Mmu m;
	m.set(0xFF07, 0x05);
	test::eq((char)0xFD, m.get(0xFF07)); // 0x05 | 0xF8
}

fn void if_unused_bits_read_high() @test
{
	mmu::Mmu m;
	m.set(0xFF0F, 0x00);
	test::eq((char)0xE0, m.get(0xFF0F));
	m.set(0xFF0F, 0x04);
	test::eq((char)0xE4, m.get(0xFF0F));
}

fn void sc_unused_bits_read_high() @test
{
	mmu::Mmu m;
	m.set(0xFF02, 0x00);
	test::eq((char)0x7E, m.get(0xFF02));
}

fn void sb_reads_back_written_value() @test
{
	mmu::Mmu m;
	m.set(0xFF01, 0x5A);
	test::eq((char)0x5A, m.get(0xFF01));
}

fn void unmapped_io_reads_ff() @test
{
	mmu::Mmu m;
	ushort[*] unmapped = { 0xFF03, 0xFF08, 0xFF0E, 0xFF4C, 0xFF4D, 0xFF50, 0xFF7F };
	foreach (addr : unmapped) {
		m.set(addr, 0x00);
		test::eq((char)0xFF, m.get(addr));
	}
}

fn void mmu_tick_raises_timer_interrupt() @test
{
	mmu::Mmu m;
	m.set(0xFF06, 0x00);  // TMA
	m.set(0xFF05, 0xFF);  // TIMA about to overflow
	m.set(0xFF07, 0x05);  // enable, period 16 T

	m.tick(5); // 20 T-cycles: overflow + reload
	test::@check((m.get(0xFF0F) & 0x04) != 0, "Timer bit set in IF");
}

fn void oam_dma_from_high_pages_reads_wram() @test
{
	mmu::Mmu m;
	for (int i = 0; i < 0xA0; i++) {
		m.set((ushort)(0xDE00 + i), (char)i);          // what page $FE must copy
		m.set((ushort)(0xDF00 + i), (char)(0xFF - i)); // what page $FF must copy
	}

	m.set(0xFF46, 0xFE); // DMA sees $FE00 as $DE00, not OAM itself
	m.tick(200);         // let the 160-byte transfer finish
	test::eq((char)0x00, m.ppu.oam[0]);
	test::eq((char)0x9F, m.ppu.oam[0x9F]);

	m.set(0xFF46, 0xFF); // ... and $FF00 as $DF00, not IO/HRAM
	m.tick(200);
	test::eq((char)0xFF, m.ppu.oam[0]);
	test::eq((char)0x60, m.ppu.oam[0x9F]);
}

fn void oam_dma_copies_one_byte_per_mcycle() @test
{
	mmu::Mmu m;
	for (int i = 0; i < 0xA0; i++) m.set((ushort)(0xC000 + i), (char)(i + 1));

	m.set(0xFF46, 0xC0);
	test::@check(!m.dma_blocks(0xC000), "CPU not locked out during startup");

	m.tick((char)mmu::DMA_STARTUP + 10); // startup, then 10 bytes
	test::@check(m.dma_blocks(0xC000), "source bus (external) locked while copying");
	test::@check(m.dma_blocks(0x0150), "ROM shares the external bus");
	test::@check(m.dma_blocks(0xFE00), "OAM always locked");
	test::@check(!m.dma_blocks(0x8000), "VRAM is on the other bus");
	test::@check(!m.dma_blocks(0xFF80), "HRAM stays accessible");
	test::@check(!m.dma_blocks(0xFF46), "IO stays accessible");
	test::eq((char)10, m.ppu.oam[9]);  // copied
	test::eq((char)0, m.ppu.oam[10]);  // not yet

	m.tick(150);                       // the remaining 150 bytes
	test::eq((char)0xA0, m.ppu.oam[0x9F]);
	test::@check(!m.dma_blocks(0xC000), "CPU free again");
}

fn void oam_dma_from_vram_leaves_external_bus_free() @test
{
	mmu::Mmu m;
	m.set(0x8000, 0x42);
	m.set(0xC000, 0x99);

	m.set(0xFF46, 0x80);               // DMA from VRAM (video bus)
	m.tick((char)mmu::DMA_STARTUP);    // taken over, byte 0 not copied yet
	test::@check(m.dma_blocks(0x9000), "video bus locked");
	test::@check(m.dma_blocks(0xFE00), "OAM locked");
	test::@check(!m.dma_blocks(0xC000), "WRAM usable: code can run there");
	test::@check(!m.dma_blocks(0x0150), "ROM usable");
	test::eq((char)0x42, m.dma_conflict_read(0x9000)); // sees the byte the DMA reads now
	test::eq((char)0xFF, m.dma_conflict_read(0xFE00));
}

// Internal-clock serial transfer: 8 bits, one per falling edge of counter
// bit 8 (every 512 T-cycles), aligned to DIV rather than to the SC write.
fn void serial_transfer_takes_eight_clock_edges() @test
{
	mmu::Mmu m;                        // DIV counter starts at 0
	m.set(0xFF01, 0x42);
	m.set(0xFF02, 0x81);               // start, internal clock

	for (int i = 0; i < 1020; i++) m.tick(1);   // 4080 T: only 7 edges so far
	test::eq((char)0, m.get(0xFF0F) & 0x08);
	test::eq((char)0x81, m.get(0xFF02) & 0x81);  // still running

	for (int i = 0; i < 4; i++) m.tick(1);      // 4096 T: 8th edge
	test::eq((char)0x08, m.get(0xFF0F) & 0x08);  // serial IRQ
	test::eq((char)0x01, m.get(0xFF02) & 0x81);  // start bit cleared
	test::eq((char)0xFF, m.get(0xFF01));         // shifted in all 1s (no cable)
}

// A CGB in CGB mode, with its extra banks borrowed from the caller.
fn void cgb_setup(mmu::Mmu* m, char[] wram_ext, char[] vram1)
{
	m.model = CGB;
	m.cgb_mode = true;
	m.wram_ext = wram_ext.ptr;
	m.ppu.vram1 = vram1.ptr;
}

fn void cgb_wram_banks_at_d000() @test
{
	mmu::Mmu m;
	char[mmu::WRAM_EXT_SIZE] ext;
	char[0x2000] vram1;
	cgb_setup(&m, &ext, &vram1);

	for (char bank = 1; bank < 8; bank++) {
		m.set(0xFF70, bank);
		m.set(0xD123, (char)(0x10 + bank));
	}
	for (char bank = 1; bank < 8; bank++) {
		m.set(0xFF70, bank);
		test::eq((char)(0x10 + bank), m.get(0xD123));
		test::eq((char)(0x10 + bank), m.get(0xF123)); // echo follows SVBK
	}
	m.set(0xFF70, 0);                                // 0 selects bank 1
	test::eq((char)0x11, m.get(0xD123));
	test::eq((char)0xF8, m.get(0xFF70));
	m.set(0xC000, 0x5A);                             // bank 0 is fixed
	m.set(0xFF70, 5);
	test::eq((char)0x5A, m.get(0xC000));
	test::eq((char)0xFD, m.get(0xFF70));
}

fn void cgb_vram_banks() @test
{
	mmu::Mmu m;
	char[mmu::WRAM_EXT_SIZE] ext;
	char[0x2000] vram1;
	cgb_setup(&m, &ext, &vram1);

	m.set(0x9800, 0x01);
	m.set(0xFF4F, 1);
	test::eq((char)0xFF, m.get(0xFF4F));
	m.set(0x9800, 0x82);
	test::eq((char)0x82, m.get(0x9800));
	test::eq((char)0x82, vram1[0x1800]);
	m.set(0xFF4F, 0);
	test::eq((char)0xFE, m.get(0xFF4F));
	test::eq((char)0x01, m.get(0x9800));
}

fn void cgb_palette_ram_auto_increment() @test
{
	mmu::Mmu m;
	char[mmu::WRAM_EXT_SIZE] ext;
	char[0x2000] vram1;
	cgb_setup(&m, &ext, &vram1);

	m.set(0xFF68, 0x80 | 0x3E);         // auto-increment from byte 62
	m.set(0xFF69, 0x11);
	m.set(0xFF69, 0x22);
	m.set(0xFF69, 0x33);                // wraps to byte 0
	test::eq((char)0x11, m.ppu.bg_pal[62]);
	test::eq((char)0x22, m.ppu.bg_pal[63]);
	test::eq((char)0x33, m.ppu.bg_pal[0]);
	test::eq((char)0xC1, m.get(0xFF68)); // bit 6 reads 1

	m.set(0xFF6A, 0x05);                // no auto-increment
	m.set(0xFF6B, 0x44);
	m.set(0xFF6B, 0x55);
	test::eq((char)0x55, m.ppu.obj_pal[5]);
	test::eq((char)0x55, m.get(0xFF6B));
}

fn void cgb_registers_absent_on_dmg() @test
{
	mmu::Mmu m;
	m.set(0xFF70, 3);
	m.set(0xFF4F, 1);
	test::eq((char)0xFF, m.get(0xFF70));
	test::eq((char)0xFF, m.get(0xFF4F));
	test::eq((char)0xFF, m.get(0xFF68));
	test::eq((char)0xFF, m.get(0xFF4D));
}
