module timer_test;

import timer;
import std::core::test;

fn void div_increments_every_256_tcycles() @test
{
	timer::Timer t;
	t.tick(255);
	test::eq((char)0, t.div());
	t.tick(1);
	test::eq((char)1, t.div());
	t.tick(256 * 3);
	test::eq((char)4, t.div());
}

fn void write_div_resets_counter() @test
{
	timer::Timer t;
	t.tick(1000);
	test::@check(t.div() != 0, "DIV advanced");
	t.write_div();
	test::eq((char)0, t.div());
}

fn void tima_does_not_run_when_disabled() @test
{
	timer::Timer t;
	t.write_tac(0x00); // speed 00, disabled (bit 2 clear)
	t.tick(5000);
	test::eq((char)0, t.tima);
}

fn void tima_increments_at_selected_rate() @test
{
	timer::Timer t;
	t.write_tac(0x05); // enable (bit 2) + speed 01 -> period 16 T
	t.tick(16);
	test::eq((char)1, t.tima);
	t.tick(16 * 9);
	test::eq((char)10, t.tima);
}

fn void tima_overflow_reloads_tma_and_signals_irq() @test
{
	timer::Timer t;
	t.tma = 0xAB;
	t.tima = 0xFF;
	t.write_tac(0x05); // period 16 T

	bool irq = t.tick(16);      // TIMA 0xFF -> 0x00, overflow pending
	test::@check(!irq, "no irq on the overflow tick itself");
	test::eq((char)0x00, t.tima);

	irq = t.tick(1);            // reload happens ~next tick
	test::@check(irq, "irq raised after reload");
	test::eq((char)0xAB, t.tima);
}

fn void tac_slow_speed_period() @test
{
	timer::Timer t;
	t.write_tac(0x04); // enable + speed 00 -> period 1024 T
	t.tick(1023);
	test::eq((char)0, t.tima);
	t.tick(1);
	test::eq((char)1, t.tima);
}
