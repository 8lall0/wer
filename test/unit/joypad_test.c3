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

fn void input_script_presses() @test {
	joypad::Script s = joypad::parse_script("400:down, 460:a,600:start*30,900:a+b+up")!!;
	test::eq(s.len, (usz)4);
	char b;
	char d;
	s.at(399, &b, &d);
	test::eq(d, 0);
	s.at(400, &b, &d);
	test::eq(d, joypad::PAD_DOWN);
	d = 0;
	s.at(406, &b, &d);                        // held 6 frames: 400-405
	test::eq(d, 0);
	s.at(629, &b, &d);
	test::eq(b, joypad::BTN_START);
	b = 0;
	s.at(900, &b, &d);
	test::eq(b, joypad::BTN_A | joypad::BTN_B);
	test::eq(d, joypad::PAD_UP);
}

fn void input_script_rejects_mistakes() @test {
	test::eq(@ok(joypad::parse_script("400")), false);
	test::eq(@ok(joypad::parse_script("x:a")), false);
	test::eq(@ok(joypad::parse_script("400:jump")), false);
	test::eq(@ok(joypad::parse_script("400:a*0")), false);
	test::eq(@ok(joypad::parse_script("")), true);
}

fn void input_script_device_actions() @test {
	joypad::Script s = joypad::parse_script("600:start,11020:card=4900363432103,700:wave=43,800:watts=999,900:gift=22")!!;
	test::eq(s.len, (usz)1);
	test::eq(s.actions_len, (usz)4);
	test::eq(s.actions[0].frame, (ulong)11020);
	test::eq(s.actions[0].kind, joypad::ActionKind.CARD);
	test::@check((String)s.actions[0].digits[..] == "4900363432103", "the card's digits");
	test::eq(s.actions[1].kind, joypad::ActionKind.WAVE);
	test::eq(s.actions[1].number, 43);
	test::eq(s.actions[2].kind, joypad::ActionKind.WATTS);
	test::eq(s.actions[2].number, 999);
	test::eq(s.actions[3].kind, joypad::ActionKind.GIFT);
	test::eq(s.actions[3].number, 22);
}

fn void input_script_rejects_bad_actions() @test {
	test::eq(@ok(joypad::parse_script("100:card=123")), false);           // not 13 digits
	test::eq(@ok(joypad::parse_script("100:card=49003634321x3")), false);
	test::eq(@ok(joypad::parse_script("100:wave=0")), false);             // 1-70
	test::eq(@ok(joypad::parse_script("100:wave=71")), false);
	test::eq(@ok(joypad::parse_script("100:watts=1000")), false);
	test::eq(@ok(joypad::parse_script("100:gift=54")), false);
	test::eq(@ok(joypad::parse_script("100:jump=1")), false);
}
