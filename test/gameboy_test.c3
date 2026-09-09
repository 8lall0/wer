module gameboy_test;

import gameboy;
import std::core::test;

fn void load_rom_copies_into_rom() @test
{
	gameboy::GameBoy gb = gameboy::new();
	gb.load_rom({ 0x00, 0xC3, 0x50, 0x01 });
	test::eq((char)0xC3, gb.mmu.get(0x0001));
	test::eq((char)0x01, gb.mmu.get(0x0003));
}

fn void step_runs_cpu_and_ticks_peripherals() @test
{
	gameboy::GameBoy gb = gameboy::new();
	// NOP * 64  -> 64 M-cycles = 256 T-cycles -> DIV ticks to 1
	char[64] nops;
	gb.load_rom(nops[..]);
	gb.cpu.pc = 0x0000;

	for (int i = 0; i < 64; i++) gb.step();

	test::eq((char)1, gb.mmu.get(0xFF04));
	test::eq((ushort)64, gb.cpu.pc);
}

fn void timer_interrupt_is_serviced() @test
{
	gameboy::GameBoy gb = gameboy::new();

	// Program at 0x0000: EI ; then spin with JR -2.
	gb.load_rom({ 0xFB, 0x18, 0xFE });
	gb.cpu.pc = 0x0000;
	gb.cpu.sp = 0xFFFE;

	// Enable the timer at the fastest rate and enable the Timer interrupt.
	gb.mmu.set(0xFF07, 0x05); // TAC: enable, period 16 T
	gb.mmu.set(0xFF06, 0x00); // TMA
	gb.mmu.set(0xFFFF, 0x04); // IE: Timer

	bool reached_vector = false;
	for (int i = 0; i < 20000; i++) {
		gb.step();
		if (gb.cpu.pc == 0x0050) {
			reached_vector = true;
			break;
		}
	}

	test::@check(reached_vector, "CPU jumped to the Timer interrupt vector");
	test::@check(!gb.cpu.ime, "IME cleared by dispatch");
}
