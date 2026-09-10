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
	test::eq((char)0, t.tima);
}

fn void tima_increments_at_selected_rate() @test
{
	timer::Timer t;
	t.write_tac(0x05); // enable + frequency 01 -> bit 3 -> every 16 T
	t.tick(16);
	test::eq((char)1, t.tima);
	t.tick(16 * 9);
	test::eq((char)10, t.tima);
}

fn void tac_slow_frequency() @test
{
	timer::Timer t;
	t.write_tac(0x04); // enable + frequency 00 -> bit 9 -> every 1024 T
	t.tick(1023);
	test::eq((char)0, t.tima);
	t.tick(1);
	test::eq((char)1, t.tima);
}

fn void tima_overflow_delays_reload_and_irq() @test
{
	timer::Timer t;
	t.tma = 0xAB;
	t.tima = 0xFF;
	t.write_tac(0x05); // every 16 T

	timer::TickResult r = t.tick(16); // TIMA 0xFF -> 0x00
	test::@check(!r.timer_irq, "no IRQ on the overflow itself");
	test::eq((char)0x00, t.tima);    // reads 0 during the reload window

	r = t.tick(4);                    // reload window elapses
	test::@check(r.timer_irq, "IRQ once the reload happens");
	test::eq((char)0xAB, t.tima);
}

fn void writing_tima_during_reload_window_cancels_it() @test
{
	timer::Timer t;
	t.tma = 0xAB;
	t.tima = 0xFF;
	t.write_tac(0x05);

	t.tick(16);          // overflow -> reload window open
	t.write_tima(0x42);  // cancel the pending reload
	timer::TickResult r = t.tick(8);
	test::@check(!r.timer_irq, "cancelled reload raises no IRQ");
	test::eq((char)0x42, t.tima);
}

// The falling-edge behaviour a threshold accumulator cannot reproduce:

fn void write_div_can_immediately_tick_tima() @test
{
	timer::Timer t;
	t.write_tac(0x05); // frequency 01 -> gated by bit 3

	t.tick(8);         // div = 8 -> bit 3 is high, TIMA still 0
	test::eq((char)0, t.tima);

	t.write_div();     // zeroing div drops bit 3: 1 -> 0 falling edge
	timer::TickResult r = t.tick(1);
	test::@check(!r.timer_irq, "no overflow here");
	test::eq((char)1, t.tima); // ... the edge incremented TIMA immediately
}

fn void changing_tac_can_tick_tima() @test
{
	timer::Timer t;
	t.write_tac(0x05); // frequency 01 -> bit 3
	t.tick(8);         // div = 8, bit 3 high
	test::eq((char)0, t.tima);

	t.write_tac(0x00); // disable the timer: gated bit 3 drops to 0
	t.tick(1);
	test::eq((char)1, t.tima);
}

fn void div_clocks_the_apu_frame_sequencer() @test
{
	timer::Timer t;
	// Bit 12 falls every 8192 T-cycles -> one 512 Hz step.
	timer::TickResult r = t.tick(8192);
	test::eq((uint)1, r.apu_steps);

	r = t.tick(8192 * 3);
	test::eq((uint)3, r.apu_steps);

	// A DIV write while bit 12 is high also produces a step.
	t.tick(4096); // bit 12 now high
	r = t.tick(0);
	test::eq((uint)0, r.apu_steps);
	t.write_div();
	r = t.tick(1);
	test::eq((uint)1, r.apu_steps);
}
