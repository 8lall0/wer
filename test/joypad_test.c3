module joypad_test;

import joypad, mmu;
import std::core::test;

fn void nothing_pressed_reads_all_high() @test
{
	joypad::Joypad j;
	j.write(0x00); // select both groups
	test::eq((char)0xCF, j.read()); // bits 6-7 high, low nibble all released
}

fn void dpad_group_selection() @test
{
	joypad::Joypad j;
	j.dpad = joypad::PAD_LEFT | joypad::PAD_DOWN;
	j.buttons = joypad::BTN_A;

	j.write(0x20); // bit 5 high -> action group NOT selected; bit 4 low -> d-pad
	// Left = bit 1, Down = bit 3 -> low nibble 0b0101 = 0x5
	test::eq((char)0x5, (char)(j.read() & 0x0F));

	j.write(0x10); // bit 4 high -> d-pad NOT selected; bit 5 low -> action
	// A = bit 0 -> low nibble 0b1110 = 0xE
	test::eq((char)0xE, (char)(j.read() & 0x0F));
}

fn void set_state_flags_a_press() @test
{
	joypad::Joypad j;
	j.write(0x10); // action group selected

	test::@check(j.set_state(joypad::BTN_A, 0), "A newly pressed -> interrupt");
	test::@check(!j.set_state(joypad::BTN_A, 0), "still held -> no new press");
	test::@check(!j.set_state(0, 0), "release -> no interrupt");
}

fn void routes_through_mmu_and_raises_interrupt() @test
{
	mmu::Mmu m;
	m.set(0xFF00, 0x10);              // select action buttons
	test::eq((char)0xDF, m.get(0xFF00)); // 0xC0 | 0x10 | 0x0F

	m.set_input(joypad::BTN_START, 0);
	test::@check((m.get(0xFF0F) & 0x10) != 0, "Joypad interrupt requested");
	// Start = bit 3 -> low nibble 0b0111
	test::eq((char)0x7, (char)(m.get(0xFF00) & 0x0F));
}
