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

fn void mmu_tick_raises_timer_interrupt() @test
{
	mmu::Mmu m;
	m.set(0xFF06, 0x00);  // TMA
	m.set(0xFF05, 0xFF);  // TIMA about to overflow
	m.set(0xFF07, 0x05);  // enable, period 16 T

	m.tick(5); // 20 T-cycles: overflow + reload
	test::@check((m.get(0xFF0F) & 0x04) != 0, "Timer bit set in IF");
}
