module accessories_test;
import gameboy, mmu;
import std::core::test;

// The small link port devices: the Turbo File GB, the Power Antenna, the
// Bardigun reader and the Full Changer.

// A packet as the game sends it: $6C, body, checksum, $F1 $7E, then $F2s
// for the reply (whose length is given). Returns the reply.
fn char[] turbo_talk(mmu::TurboFile* t, char[] body, int reply_len) {
	test::eq(t.answer(0x6C), 0xC6);
	char sum;
	foreach (c : body) {
		t.answer(c);
		sum -= c;
	}
	t.answer(sum);
	test::eq(t.answer(0xF1), 0xE7);
	test::eq(t.answer(0x7E), 0xA5);
	char[] reply = mem::temp_array(char, reply_len);
	char check = 0x5B;
	foreach (i, &r : reply) {
		*r = t.answer(0xF2);
		if (i + 1 < reply_len) check -= *r;
	}
	test::eq(reply[reply_len - 1], check);
	test::eq(t.state, mmu::TurboState.SYNC);
	return reply;
}

fn void turbo_file_saves_and_loads() @test {
	char[] data = mem::temp_array(char, mmu::TURBO_SIZE);
	data[..] = 0xFF;
	mmu::TurboFile t;
	t.init(data, 4194304);
	// Not yet $6C: nothing.
	test::eq(t.answer(0x00), 0x00);
	char[] status = turbo_talk(&t, { 0x5A, 0x10 }, 9);
	test::@check(status[:8] == (char[]){ 0x10, 0, 0x03, 0x05, 0, 0, 0, 0 }, "ready, a card in, bank 0");
	turbo_talk(&t, { 0x5A, 0x20, 0x00 }, 4);
	// Write 64 bytes in bank $81 (the card) at $0140.
	char[] reply = turbo_talk(&t, { 0x5A, 0x22, 0x01, 0x01 }, 4);
	test::eq(reply[2], 0x0B); // a bank was set
	char[68] write;
	write[:4] = (char[]){ 0x5A, 0x30, 0x01, 0x40 }[..];
	for (int i = 0; i < 64; i++) write[4 + i] = (char)(i * 3);
	turbo_talk(&t, &write, 4);
	test::@check(t.changed, "to be saved");
	test::eq(data[0x81 * 0x2000 + 0x140 + 5], 15);
	status = turbo_talk(&t, { 0x5A, 0x10 }, 9);
	test::@check(status[4] == 1 && status[5] == 1, "bank $81");
	// Read it back.
	turbo_talk(&t, { 0x5A, 0x23, 0x01, 0x01 }, 4);
	reply = turbo_talk(&t, { 0x5A, 0x40, 0x01, 0x40 }, 68);
	test::eq(reply[0], 0x40);
	test::@check(reply[3:64] == write[4:64], "the same 64 bytes");
	turbo_talk(&t, { 0x5A, 0x24 }, 4);
}

fn void turbo_file_clocks_the_cable() @test {
	char[] rom = mem::temp_array(char, 0x8000);
	gameboy::GameBoy gb = gameboy::new(false, DMG);
	defer gb.destroy();
	gb.load_rom(rom);
	char[] data = mem::temp_array(char, mmu::TURBO_SIZE);
	mmu::TurboFile t;
	t.init(data, 4194304);
	mmu::Link l;
	gb.mmu.connect_turbo(&l, &t);
	// The game not waiting: the drive does nothing.
	t.tick(&gb.mmu);
	test::eq(t.state, mmu::TurboState.SYNC);
	// Waiting with $6C: the drive clocks $C6 in and the transfer ends.
	gb.mmu.io[0x01] = 0x6C;
	gb.mmu.io[0x02] = 0x80;
	t.tick(&gb.mmu);
	test::eq(gb.mmu.io[0x01], 0xC6);
	test::eq(gb.mmu.io[0x02] & 0x80, 0);
	test::eq(t.state, mmu::TurboState.BODY);
}

fn void power_antenna() @test {
	mmu::PowerAntenna a;
	a.init(4194304);
	test::eq(a.exchange(0x01, 0), 0xF3);
	test::@check(a.lit(1_000_000_000), "stays lit");
	test::eq(a.exchange(0x00, 10), 0xF2);
	test::eq(a.exchange(0x02, 20), 0xF3);  // a dim flash
	test::@check(!a.lit(20 + 4194304), "gone after a moment");
}

fn void ean13_codes() @test {
	// The usual example: 5901234123457.
	bool[95] m;
	mmu::ean13("5901234123457", &m)!!;
	String want = "10100010110100111011001100100110111101001110101010110011011011001000010101110010011101000100101";
	foreach (i, c : want) test::@check(m[i] == (c == '1'), "module %d", i);
	test::@check(@catch(mmu::ean13("590123412345", &m)), "12 digits");
}

fn void bardigun_swipe() @test {
	mmu::Bardigun b;
	test::eq(b.exchange(0xFF), 0x00);
	b.swipe("4901330547479")!!;
	// Read it back as bars and white, 15 bits a module.
	char[] stream = mem::temp_array(char, 512);
	int n;
	for (; n < 512; n++) {
		if (b.at >= b.len) break;
		stream[n] = b.exchange(0xFF);
	}
	bool[95] want;
	mmu::ean13("4901330547479", &want)!!;
	// White first (the quiet zone), then the code.
	for (int i = 0; i < mmu::BARDIGUN_QUIET * mmu::BARDIGUN_BITS; i++) {
		test::@check((stream[i >> 3] >> (7 - (i & 7))) & 1 != 0, "white before, bit %d", i);
	}
	for (int i = 0; i < 95; i++) {
		int bit = (mmu::BARDIGUN_QUIET + i) * mmu::BARDIGUN_BITS + 7;
		bool white = (stream[bit >> 3] >> (7 - (bit & 7))) & 1 != 0;
		test::@check(white == !want[i], "module %d", i);
	}
	test::eq(b.exchange(0xFF), 0x00); // done
}

// A GBC in double speed waiting for the toy as Zok Zok Heroes does (Dan
// Docs' description): the 18 counts it keeps decode to the character.
fn void full_changer_sends_a_character() @test {
	char[] rom = mem::temp_array(char, 0x8000);
	char[] code = {
		0xF3, 0x3E, 0x01, 0xE0, 0x4D, 0x10, 0x00,  // di; double speed
		0x3E, 0xC0, 0xE0, 0x56, 0x0E, 0x56,        // RP reading on; c = $56
		0xCD, 0x62, 0x01, 0x18, 0xFB,              // main: call receive; jr main
		0x06, 0xFF,                                // receive: ld b,$FF
		0x05, 0xC8, 0xF2, 0xE6, 0x02, 0x20, 0xF9,  // until the light: dec b; ret z; ld a,(c); and 2; jr nz
		0x21, 0x05, 0xD0, 0x06, 0x12,              // ld hl,$D005; ld b,18
		0x16, 0x00, 0xCD, 0x84, 0x01, 0xCD, 0x8C, 0x01, // grab: ld d,0; call off; call on
		0x72, 0x23, 0x05, 0x20, 0xF3,              // ld (hl),d; inc hl; dec b; jr nz,grab
		0x3E, 0x01, 0xEA, 0x00, 0xD0, 0x18, 0xFE,  // ld ($D000),1; done
		0x14, 0xC8, 0xF2, 0xE6, 0x02, 0x28, 0xF9, 0xC9, // off: inc d; ret z; ld a,(c); and 2; jr z,off; ret
		0x14, 0xC8, 0xF2, 0xE6, 0x02, 0x20, 0xF9, 0xC9, // on:  ... jr nz,on; ret
	};
	rom[0x150:code.len] = code[..];
	rom[0x100:4] = (char[]){ 0x00, 0xC3, 0x50, 0x01 }[..]; // nop; jp $0150
	rom[0x143] = 0x80;
	gameboy::GameBoy gb = gameboy::new(false, CGB);
	defer gb.destroy();
	gb.load_rom(rom);
	mmu::FullChanger c;
	mmu::Link l;
	gb.mmu.connect_changer(&l, &c);
	gb.run_frame();
	c.wave(43); // Rocket Bastard
	for (int f = 0; f < 10 && gb.mmu.get(0xD000) != 1; f++) gb.run_frame();
	test::eq(gb.mmu.get(0xD000), 1);
	char[18] counts;
	for (int i = 0; i < 18; i++) counts[i] = gb.mmu.get((ushort)(0xD005 + i));
	// As the game reads them.
	test::@check(counts[0] > 0x20, "a long start (%02x)", counts[0]);
	char first;
	char second;
	for (int i = 0; i < 8; i++) {
		test::@check(counts[1 + i] <= 0x20 && counts[9 + i] <= 0x20, "not too long");
		if (counts[1 + i] >= 0x14) first |= (char)(1 << i);
		if (counts[9 + i] >= 0x14) second |= (char)(1 << i);
	}
	test::eq(first + second, 0xFF);
	test::eq((char)~second, 43);
	// Each count near what was meant (0x0A short, 0x1A long).
	foreach (i, n : counts[1:16]) test::@check(n >= 0x08 && n <= 0x1C, "count %d: %02x", i + 1, n);
}
