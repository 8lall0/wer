module gameboy_test;

import gameboy;
import std::core::test;

fn void load_rom_copies_into_rom() @test
{
	gameboy::GameBoy gb = gameboy::new(false);
	defer gb.destroy();
	gb.load_rom({ 0x00, 0xC3, 0x50, 0x01 });
	test::eq((char)0xC3, gb.mmu.get(0x0001));
	test::eq((char)0x01, gb.mmu.get(0x0003));
}

fn void step_runs_cpu_and_ticks_peripherals() @test
{
	gameboy::GameBoy gb = gameboy::new(false);
	defer gb.destroy();
	// NOP * 64  -> 64 M-cycles = 256 T-cycles -> DIV ticks to 1
	char[64] nops;
	gb.load_rom(nops[..]);
	gb.cpu.pc = 0x0000;
	gb.mmu.set(0xFF04, 0); // DIV starts at its post-boot value; reset it

	for (int i = 0; i < 64; i++) gb.step();

	test::eq((char)1, gb.mmu.get(0xFF04));
	test::eq((ushort)64, gb.cpu.pc);
}

fn void timer_interrupt_is_serviced() @test
{
	gameboy::GameBoy gb = gameboy::new(false);
	defer gb.destroy();

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

fn void sgb_post_boot_state() @test
{
	gameboy::GameBoy gb = gameboy::new(false, SGB);
	defer gb.destroy();
	test::eq((ushort)0x0100, gb.cpu.af.reg);   // A = $01: not a CGB
	test::eq((ushort)0x0014, gb.cpu.bc.reg);
	test::eq((ushort)0xC060, gb.cpu.hl.reg);
	test::eq((char)0xFF, gb.mmu.get(0xFF00));  // both P1 select lines high
	test::eq((char)0xF0, gb.mmu.get(0xFF26));  // no boot chime: channel 1 off
}

// A Game Boy Advance hands over with B one higher (Pan Docs): B = $01 and
// F = $00 for a Game Boy Color game, whether the boot ROM runs or not.
fn void gba_hands_over_with_b_set() @test {
	char[] rom = mem::temp_array(char, 0x8000);
	rom[0x143] = 0x80; // CGB game
	rom[0x100] = 0x18; // jr $
	rom[0x101] = 0xFE;
	foreach (boot : (bool[]){ false, true }) {
		gameboy::GameBoy gb = gameboy::new(boot, CGB);
		defer gb.destroy();
		gb.set_cgb_revision(AGB);
		gb.load_rom(rom);
		while (gb.cpu.pc != 0x100 || gb.mmu.boot_active) gb.step();
		gb.step(); // the boot ROM's last INC B lands before the game's first instruction
		test::eq(gb.cpu.bc.hi, 0x01);
		test::eq(gb.cpu.af.lo, 0x00);
		test::eq(gb.cpu.af.hi, 0x11);
	}
	// A CGB, for comparison.
	gameboy::GameBoy c = gameboy::new(false, CGB);
	defer c.destroy();
	c.set_cgb_revision(E);
	c.load_rom(rom);
	c.step();
	test::eq(c.cpu.bc.hi, 0x00);
	test::eq(c.cpu.af.lo, 0x80);
}
