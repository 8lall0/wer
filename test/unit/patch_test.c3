module patch_test;
import patch, std::hash::crc32, std::core::test;

// Patches built here, small enough to check by hand.

fn void ips_records_runs_growth_and_cut() @test {
	char[] rom = { 1, 2, 3, 4, 5, 6 };
	char[] p = { 'P', 'A', 'T', 'C', 'H',
		0, 0, 1,  0, 2,  0xAA, 0xBB,       // $0001: two bytes
		0, 0, 4,  0, 0,  0, 3,  0x77,      // $0004: $77 three times (past the end)
		'E', 'O', 'F' };
	char[] out = patch::apply(rom, p, tmem)!!;
	test::eq(out, (char[]){ 1, 0xAA, 0xBB, 4, 0x77, 0x77, 0x77 });
	test::eq(rom, (char[]){ 1, 2, 3, 4, 5, 6 });       // untouched
	char[] cut = { 'P', 'A', 'T', 'C', 'H', 'E', 'O', 'F', 0, 0, 4 };
	test::eq(patch::apply(rom, cut, tmem)!!, (char[]){ 1, 2, 3, 4 });
	char[] short_record = { 'P', 'A', 'T', 'C', 'H', 0, 0, 1, 0, 9, 1, 'E', 'O', 'F' };
	test::eq(@catch(patch::apply(rom, short_record, tmem)), patch::BROKEN);
	test::eq(@catch(patch::apply(rom, "hello", tmem)), patch::NOT_A_PATCH);
}

// A UPS/BPS number: 7 bits a byte, the last with bit 7 set.
fn void put_number(DString* s, ulong v) {
	while (true) {
		char x = (char)(v & 0x7F);
		v >>= 7;
		if (!v) {
			s.append_char(x | 0x80);
			return;
		}
		s.append_char(x);
		v--;
	}
}

fn void put_le32(DString* s, uint v) {
	for (int i = 0; i < 4; i++) s.append_char((char)(v >> (8 * i)));
}

fn char[] with_footer(DString* s, char[] rom, char[] result) {
	put_le32(s, crc32::hash(rom));
	put_le32(s, crc32::hash(result));
	put_le32(s, crc32::hash(s.str_view()));
	return s.str_view();
}

fn void ups_xors_and_grows() @test {
	char[] rom = { 1, 2, 3, 4 };
	char[] want = { 1, 9, 3, 4, 5 };
	DString s;
	s.tinit();
	s.append("UPS1");
	put_number(&s, 4);
	put_number(&s, 5);
	put_number(&s, 1);                      // skip 1
	s.append_char(2 ^ 9);
	s.append_char(0);                       // the end of the run (byte 2 as it is)
	put_number(&s, 1);                      // skip byte 3
	s.append_char(5);                       // byte 4: past the ROM's end
	s.append_char(0);
	char[] p = with_footer(&s, rom, want);
	test::eq(patch::apply(rom, p, tmem)!!, want);
	test::eq(@catch(patch::apply(want, p, tmem)), patch::WRONG_ROM);
}

fn void bps_all_four_commands() @test {
	char[] rom = { 1, 2, 3, 4 };
	char[] want = { 1, 2, 7, 7, 7, 7, 3, 4 };
	DString s;
	s.tinit();
	s.append("BPS1");
	put_number(&s, 4);
	put_number(&s, 8);
	put_number(&s, 0);                      // no metadata
	put_number(&s, (2 - 1) << 2 | 0);       // the ROM's own 2 bytes
	put_number(&s, (1 - 1) << 2 | 1);       // 1 byte from the patch
	s.append_char(7);
	put_number(&s, (3 - 1) << 2 | 3);       // 3 bytes from the result, from offset 2
	put_number(&s, 2 << 1);
	put_number(&s, (2 - 1) << 2 | 2);       // 2 bytes from ROM offset 2
	put_number(&s, 2 << 1);
	char[] p = with_footer(&s, rom, want);
	test::eq(patch::apply(rom, p, tmem)!!, want);
	char[] damaged = mem::temp_array(char, p.len);
	damaged[..] = p[..];
	damaged[6] ^= 1;
	test::eq(@catch(patch::apply(rom, damaged, tmem)), patch::BROKEN);
}
