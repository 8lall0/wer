module barcode_test;
import gameboy, mmu;
import std::core::test;

mmu::BarcodeBoy reader;
gameboy::GameBoy gb;

fn void hello_answers() @test {
	mmu::BarcodeBoy b;
	b.init(4194304);
	char[4] got;
	foreach (i, c : (char[]){ 0x10, 0x07, 0x10, 0x07 }) got[i] = b.exchange(c);
	test::@check(got == (char[4]){ 0xFF, 0xFF, 0x10, 0x07 }, "the reader's hello");
}

// A game waiting for bytes from the reader (external clock), storing each
// at $C000 on.
fn void swipe_reaches_the_game() @test {
	char[] rom = mem::temp_array(char, 0x8000);
	char[] code = {
		0x21, 0x00, 0xC0,       // ld hl,$C000
		0x3E, 0x80,             // loop: ld a,$80
		0xE0, 0x02,             // ldh ($02),a   ; wait for a byte
		0xF0, 0x02,             // wait: ldh a,($02)
		0xCB, 0x7F,             // bit 7,a
		0x20, 0xFA,             // jr nz,wait
		0xF0, 0x01,             // ldh a,($01)
		0x22,                   // ld (hl+),a
		0x18, 0xF1,             // jr loop
	};
	rom[0x100:code.len] = code[..];
	gb = gameboy::new(false, DMG);
	defer gb.destroy();
	gb.load_rom(rom);
	reader.init(4194304);
	mmu::Link l;
	gb.mmu.connect_barcode(&l, &reader);
	gb.run_frame();
	reader.swipe_card("4 902370 503494", gb.mmu.rt_clock)!!;
	test::@check(@catch(reader.swipe_card("123", gb.mmu.rt_clock)) == mmu::NOT_A_BARCODE, "13 digits");
	for (int f = 0; f < 10; f++) gb.run_frame_polled(fn (ctx) { reader.tick(&gb.mmu); }, null, 16);
	char[30] want;
	String digits = "4902370503494";
	for (int c = 0; c < 2; c++) {
		want[c * 15] = 0x02;
		want[c * 15 + 1 : 13] = ((char[])digits)[..];
		want[c * 15 + 14] = 0x03;
	}
	char[30] got;
	for (int i = 0; i < 30; i++) got[i] = gb.mmu.get((ushort)(0xC000 + i));
	test::@check(got == want, "the card, twice, framed by $02/$03");
}
