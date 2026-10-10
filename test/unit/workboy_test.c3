module workboy_test;
import gameboy, mmu;
import std::core::test;

// The WorkBoy (link/workboy.c3): its answers to the program's bytes, a byte
// late.

fn char[] talk(mmu::WorkBoy* w, String bytes) {
	char[] got = mem::temp_array(char, bytes.len);
	foreach (i, c : bytes) got[i] = w.exchange(c);
	return got;
}

// 2026-10-10 (a Saturday) 18:42:07, as local time.
const long SATURDAY = 20736 * 86400 + 18 * 3600 + 42 * 60 + 7;

fn void reads_the_clock() @test {
	mmu::WorkBoy w;
	w.init(0);
	w.fixed_now = SATURDAY;
	test::@check(!w.active(), "quiet until the program talks");
	// 'R', then a byte per hex digit (the answers come a byte late).
	char[] got = talk(&w, "R................................");
	test::@check(w.active(), "the program talked");
	test::eq(got[1], 'D');
	// From digit 1: $04's low digit, then $00, seconds, minutes, hours,
	// day, month | weekday << 5 (October, Saturday: $D0).
	test::eq((String)got[2:13], "40007421810D0");
	test::eq((String)got[31:2], "7E"); // 126 years since 1900
}

fn void keys_and_shift() @test {
	mmu::WorkBoy w;
	w.init(0);
	w.press(mmu::workboy_key('a'));
	w.press(mmu::workboy_key('1'));
	w.press(mmu::workboy_key('Q'));
	w.press(mmu::WORKBOY_ENTER);
	char[] got = talk(&w, "OOOOOOOO");
	test::@check(got == (char[]){ 0, 28, 39, 17, 50, 17, 38, 0xFF }, "a, Shift, 1, Shift up, q, Enter, then none");
	test::eq(mmu::workboy_key('{'), mmu::WORKBOY_NONE);
}

fn void sets_the_clock() @test {
	mmu::WorkBoy w;
	w.init(0);
	w.fixed_now = SATURDAY;
	// 'W', 2 bytes, then 21: 1999-12-31 23:59:30.
	char[23] set;
	set[7 + 2] = 0x30;
	set[8 + 2] = 0x59;
	set[9 + 2] = 0x23;
	set[0x0A + 2] = 0x31;
	set[0x0B + 2] = 0x12;
	set[0x14 + 2] = 99;
	w.exchange('W');
	foreach (b : set) w.exchange(b);
	test::@check(w.clock_set, "the program set the clock");
	test::eq(w.mode, 'O');
	char[] got = talk(&w, "R................................");
	test::eq((String)got[2:13], "40030592331B2"); // a Friday
	test::eq((String)got[31:2], "63"); // 99 at $0F
	// Time goes on from there.
	w.fixed_now += 45;
	got = talk(&w, "R................................");
	test::eq((String)got[2:13], "40015000001C1"); // a Saturday
	test::eq((String)got[31:2], "64"); // 2000
}

// A program clocking 'O' out and keeping the answers at $C000 on.
fn void the_program_gets_keys() @test {
	char[] rom = mem::temp_array(char, 0x8000);
	char[] code = {
		0x21, 0x00, 0xC0,       // ld hl,$C000
		0x3E, 0x4F,             // loop: ld a,'O'
		0xE0, 0x01,             // ldh ($01),a
		0x3E, 0x81,             // ld a,$81
		0xE0, 0x02,             // ldh ($02),a   ; clock it out
		0xF0, 0x02,             // wait: ldh a,($02)
		0xCB, 0x7F,             // bit 7,a
		0x20, 0xFA,             // jr nz,wait
		0xF0, 0x01,             // ldh a,($01)
		0x22,                   // ld (hl+),a
		0x18, 0xED,             // jr loop
	};
	rom[0x100:code.len] = code[..];
	gameboy::GameBoy gb = gameboy::new(false, DMG);
	defer gb.destroy();
	gb.load_rom(rom);
	mmu::WorkBoy w;
	w.init(0);
	mmu::Link l;
	gb.mmu.connect_workboy(&l, &w);
	w.press(mmu::workboy_key('h'));
	w.press(mmu::workboy_key('?'));
	gb.run_frame();
	char[6] got;
	for (int i = 0; i < 6; i++) got[i] = gb.mmu.get((ushort)(0xC000 + i));
	test::@check(got == (char[6]){ 0, 33, 39, 49, 0xFF, 0xFF }, "h, Shift, ?, then none");
}
