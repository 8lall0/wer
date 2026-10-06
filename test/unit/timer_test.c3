module timer_test;

import timer;
import std::core::test;

fn void div_high_byte_advances() @test
{
	timer::Timer t;
	t.tick(255);
	test::eq((char)0, t.div_reg());
	t.tick(1);
	test::eq((char)1, t.div_reg());
	t.tick(256 * 3);
	test::eq((char)4, t.div_reg());
}

fn void write_div_resets_counter() @test
{
	timer::Timer t;
	t.tick(1000);
	test::@check(t.div_reg() != 0, "DIV advanced");
	t.write_div();
	test::eq((char)0, t.div_reg());
}

fn void tima_does_not_run_when_disabled() @test
{
	timer::Timer t;
	t.write_tac(0x00); // frequency 00, timer disabled (bit 2 clear)
	t.tick(5000);
	test::eq((char)0, t.read_tima());
}

fn void tima_increments_at_selected_rate() @test
{
	timer::Timer t;
	t.write_tac(0x05); // enable + frequency 01 -> bit 3 -> every 16 T
	t.tick(16);
	test::eq((char)1, t.read_tima());
	t.tick(16 * 9);
	test::eq((char)10, t.read_tima());
}

fn void tac_slow_frequency() @test
{
	timer::Timer t;
	t.write_tac(0x04); // enable + frequency 00 -> bit 9 -> every 1024 T
	t.tick(1023);
	test::eq((char)0, t.read_tima());
	t.tick(1);
	test::eq((char)1, t.read_tima());
}

fn void tima_overflow_delays_reload_and_irq() @test
{
	timer::Timer t;
	t.write_tma(0xAB);
	t.write_tima(0xFF);
	t.write_tac(0x05); // every 16 T

	timer::TickResult r = t.tick(16); // TIMA 0xFF -> 0x00
	test::@check(!r.timer_irq, "no IRQ on the overflow itself");
	test::eq((char)0x00, t.read_tima());    // reads 0 during the reload window

	r = t.tick(4);                    // reload window elapses
	test::@check(r.timer_irq, "IRQ once the reload happens");
	test::eq((char)0xAB, t.read_tima());
}

fn void writing_tima_during_reload_window_cancels_it() @test
{
	timer::Timer t;
	t.write_tma(0xAB);
	t.write_tima(0xFF);
	t.write_tac(0x05);

	t.tick(16);          // overflow -> reload window open
	t.write_tima(0x42);  // cancel the pending reload
	timer::TickResult r = t.tick(8);
	test::@check(!r.timer_irq, "cancelled reload raises no IRQ");
	test::eq((char)0x42, t.read_tima());
}

// The falling-edge behaviour a threshold accumulator cannot reproduce:

fn void write_div_can_immediately_tick_tima() @test
{
	timer::Timer t;
	t.write_tac(0x05); // frequency 01 -> gated by bit 3

	t.tick(8);         // div = 8 -> bit 3 is high, TIMA still 0
	test::eq((char)0, t.read_tima());

	t.write_div();     // zeroing div drops bit 3: 1 -> 0 falling edge
	timer::TickResult r = t.tick(1);
	test::@check(!r.timer_irq, "no overflow here");
	test::eq((char)1, t.read_tima()); // ... the edge incremented TIMA immediately
}

fn void changing_tac_can_tick_tima() @test
{
	timer::Timer t;
	t.write_tac(0x05); // frequency 01 -> bit 3
	t.tick(8);         // div = 8, bit 3 high
	test::eq((char)0, t.read_tima());

	t.write_tac(0x00); // disable the timer: gated bit 3 drops to 0
	t.tick(1);
	test::eq((char)1, t.read_tima());
}

fn void div_clocks_the_apu_frame_sequencer() @test
{
	timer::Timer t;
	// Bit 12 falls every 8192 T-cycles -> one 512 Hz step.
	timer::TickResult r = t.tick(8192);
	test::eq((uint)1, r.apu_steps);

	r = t.tick(8192 * 3);
	test::eq((uint)3, r.apu_steps);

	// Bit 12 rising is the APU's secondary event.
	r = t.tick(4096); // bit 12 now high
	test::eq((uint)1, r.apu_rises);
	test::eq((uint)0, r.apu_steps);

	// A DIV write while bit 12 is high also produces a step, reported apart
	// (it times the sweep differently).
	t.write_div();
	r = t.tick(1);
	test::@check(r.apu_div_write, "DIV write step");
	test::eq((uint)0, r.apu_steps);
}

// In the M-cycle TMA is copied into TIMA, a TIMA write loses to the reload.
fn void writing_tima_in_reload_cycle_is_ignored() @test
{
	timer::Timer t;
	t.write_tma(0xAB);
	t.write_tima(0xFF);
	t.write_tac(0x05);

	t.tick(16);          // overflow -> TIMA reads $00 for one M-cycle
	t.tick(4);           // reload: TIMA = TMA
	t.write_tima(0x42);  // same M-cycle as the reload: ignored
	test::eq((char)0xAB, t.read_tima());

	t.tick(4);           // one M-cycle later writes work again
	t.write_tima(0x42);
	test::eq((char)0x42, t.read_tima());
}

// In the M-cycle TMA is copied into TIMA, a TMA write is copied too.
fn void writing_tma_in_reload_cycle_also_loads_tima() @test
{
	timer::Timer t;
	t.write_tma(0xAB);
	t.write_tima(0xFF);
	t.write_tac(0x05);

	t.tick(16);          // overflow
	t.tick(4);           // reload: TIMA = $AB
	t.write_tma(0x77);   // same M-cycle: the new TMA is what TIMA gets
	test::eq((char)0x77, t.read_tima());
	test::eq((char)0x77, t.tma);

	t.tick(4);
	t.write_tma(0x10);   // later TMA writes leave TIMA alone
	test::eq((char)0x77, t.read_tima());
}
