module sgb_test;

import mmu, sgb, ppu;
import std::core::test;

// A bare Mmu in SGB mode. Free with drop().
fn mmu::Mmu* sgb_mmu() {
	mmu::Mmu* m = mem::new(mmu::Mmu);
	m.model = SGB;
	m.sgb = sgb::new();
	return m;
}

// A packet whose first two bytes are set, the rest zero.
fn char[16] pkt(char b0, char b1 = 0) {
	char[16] p;
	p[0] = b0;
	p[1] = b1;
	return p;
}

fn void drop(mmu::Mmu* m) {
	m.sgb.free();
	mem::free(m);
}

// Send 16 bytes the way a game does: start pulse, 128 bits LSB first, a stop
// bit, with P1 back to $30 after every pulse.
fn void send_packet(mmu::Mmu* m, char[16] bytes, bool good_stop = true) {
	m.set(0xFF00, 0x00);
	m.set(0xFF00, 0x30);
	for (int i = 0; i < 128; i++) {
		bool one = ((bytes[i / 8] >> (i % 8)) & 1) != 0;
		m.set(0xFF00, one ? 0x10 : 0x20);
		m.set(0xFF00, 0x30);
	}
	m.set(0xFF00, good_stop ? 0x20 : 0x10);
	m.set(0xFF00, 0x30);
}

fn void packet_is_decoded_and_executed() @test
{
	mmu::Mmu* m = sgb_mmu();
	defer drop(m);

	send_packet(m, pkt(sgb::CMD_MASK_EN * 8 + 1, 0x01));
	test::eq(1u, m.sgb.seen[sgb::CMD_MASK_EN]);
	test::eq((char)0x01, m.sgb.data[1]);
}

fn void bad_stop_bit_drops_the_packet() @test
{
	mmu::Mmu* m = sgb_mmu();
	defer drop(m);

	send_packet(m, pkt(sgb::CMD_MASK_EN * 8 + 1), false);
	test::eq(0u, m.sgb.seen[sgb::CMD_MASK_EN]);
}

fn void multi_packet_command_waits_for_all_packets() @test
{
	mmu::Mmu* m = sgb_mmu();
	defer drop(m);

	send_packet(m, pkt(sgb::CMD_ATTR_BLK * 8 + 2, 0x03));
	test::eq(0u, m.sgb.seen[sgb::CMD_ATTR_BLK]);    // one of two packets so far
	send_packet(m, pkt(0xAA));
	test::eq(1u, m.sgb.seen[sgb::CMD_ATTR_BLK]);
	test::eq((char)0xAA, m.sgb.data[16]);           // second packet's data follows
}

fn void mlt_req_lets_the_game_detect_the_sgb() @test
{
	mmu::Mmu* m = sgb_mmu();
	defer drop(m);

	m.set(0xFF00, 0x30);
	test::eq((char)0x0F, m.get(0xFF00) & 0x0F);     // one player: id reads $F

	send_packet(m, pkt(sgb::CMD_MLT_REQ * 8 + 1, 0x01)); // two players
	char first = m.get(0xFF00) & 0x0F;
	m.set(0xFF00, 0x10);                            // P15 low ...
	m.set(0xFF00, 0x30);                            // ... and high: next joypad
	char second = m.get(0xFF00) & 0x0F;
	test::@check(first != second, "joypad id changes: this is an SGB");
	test::@check((first == 0x0F || first == 0x0E) && (second == 0x0F || second == 0x0E),
		"two players: ids $F and $E");
}

fn void dmg_mode_ignores_packets() @test
{
	mmu::Mmu m;                                     // DMG: no Sgb at all
	send_packet(&m, pkt(sgb::CMD_MLT_REQ * 8 + 1, 0x01));
	m.set(0xFF00, 0x30);
	test::eq((char)0x0F, m.get(0xFF00) & 0x0F);
}

// --- colours ----------------------------------------------------------------

// Run a command directly (its data as the game would send it).
fn void run(sgb::Sgb* s, char[] data) {
	s.execute(data[0] >> 3, data);
}

fn void pal01_sets_two_palettes_and_shared_color0() @test
{
	sgb::Sgb* s = sgb::new();
	defer s.free();
	char[16] d = { sgb::CMD_PAL01 * 8 + 1,
		0x11, 0x00,                              // colour 0 (shared)
		0x01, 0x00, 0x02, 0x00, 0x03, 0x00,      // palette 0, colours 1-3
		0x04, 0x00, 0x05, 0x00, 0x06, 0x00,      // palette 1, colours 1-3
		0 };
	run(s, &d);
	test::eq((ushort)0x0011, s.pal[0][0]);
	test::eq((ushort)0x0011, s.pal[3][0]);   // colour 0 is shared by all four
	test::eq((ushort)0x0003, s.pal[0][3]);
	test::eq((ushort)0x0006, s.pal[1][3]);
}

fn void attr_blk_colours_inside_line_and_outside() @test
{
	sgb::Sgb* s = sgb::new();
	defer s.free();
	char[16] d;
	d[0] = sgb::CMD_ATTR_BLK * 8 + 1;
	d[1] = 1;                                // one data set
	d[2] = 7;                                // inside, line and outside
	d[3] = 1 | (2 << 2) | (3 << 4);          // inside 1, line 2, outside 3
	d[4] = 2; d[5] = 2; d[6] = 6; d[7] = 6;  // rectangle (2,2)-(6,6)
	run(s, &d);
	test::eq((char)1, s.attr[4 * 20 + 4]);   // inside
	test::eq((char)2, s.attr[2 * 20 + 4]);   // on the line
	test::eq((char)3, s.attr[0]);            // outside
}

fn void attr_blk_inside_only_colours_the_line_too() @test
{
	sgb::Sgb* s = sgb::new();
	defer s.free();
	char[16] d;
	d[0] = sgb::CMD_ATTR_BLK * 8 + 1;
	d[1] = 1;
	d[2] = 1;                                // inside only
	d[3] = 2;                                // inside palette 2
	d[4] = 0; d[5] = 0; d[6] = 3; d[7] = 3;
	run(s, &d);
	test::eq((char)2, s.attr[0]);            // the line takes the inside colour
	test::eq((char)0, s.attr[10]);           // outside untouched
}

fn void attr_lin_and_div() @test
{
	sgb::Sgb* s = sgb::new();
	defer s.free();
	char[16] lin;
	lin[0] = sgb::CMD_ATTR_LIN * 8 + 1;
	lin[1] = 1;
	lin[2] = 0x80 | (3 << 5) | 5;            // horizontal line 5, palette 3
	run(s, &lin);
	test::eq((char)3, s.attr[5 * 20 + 19]);
	test::eq((char)0, s.attr[4 * 20]);

	char[16] div;
	div[0] = sgb::CMD_ATTR_DIV * 8 + 1;
	div[1] = 1 | (2 << 2) | (3 << 4);        // after 1, before 2, line 3; split left/right
	div[2] = 10;
	run(s, &div);
	test::eq((char)2, s.attr[9]);
	test::eq((char)3, s.attr[10]);
	test::eq((char)1, s.attr[11]);
}

fn void attr_chr_writes_cells_in_order() @test
{
	sgb::Sgb* s = sgb::new();
	defer s.free();
	char[16] d;
	d[0] = sgb::CMD_ATTR_CHR * 8 + 1;
	d[1] = 18; d[2] = 0;                     // start at (18, 0)
	d[3] = 3;                                // three cells
	d[5] = 0;                                // left to right, wrapping
	d[6] = 0b01_10_11_00;                    // palettes 1, 2, 3
	run(s, &d);
	test::eq((char)1, s.attr[18]);
	test::eq((char)2, s.attr[19]);
	test::eq((char)3, s.attr[20]);           // wrapped to (0, 1)
}

fn void pal_trn_then_pal_set_from_vram() @test
{
	ppu::Ppu p;
	p.lcdc = ppu::LCDC_ENABLE | ppu::LCDC_BG_ENABLE | ppu::LCDC_TILE_DATA;
	for (int t = 0; t < 256; t++) p.vram[0x1800 + (t / 20) * 32 + t % 20] = (char)t;
	p.vram[5 * 8] = 0x34;                    // system palette 5, colour 0 = $1234
	p.vram[5 * 8 + 1] = 0x12;
	p.vram[5 * 8 + 6] = 0xCD;                // colour 3 = $ABCD
	p.vram[5 * 8 + 7] = 0xAB;

	sgb::Sgb* s = sgb::new();
	defer s.free();
	char[16] trn = { sgb::CMD_PAL_TRN * 8 + 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
	run(s, &trn);
	s.capture_transfer(&p);                  // the next VBlank

	char[16] set;
	set[0] = sgb::CMD_PAL_SET * 8 + 1;
	set[1] = 5;                              // palette 0 := system palette 5
	run(s, &set);
	test::eq((ushort)0x1234, s.pal[0][0]);
	test::eq((ushort)0x1234, s.pal[2][0]);   // shared colour 0
	test::eq((ushort)0xABCD, s.pal[0][3]);
}

fn void render_colours_by_cell_and_freezes() @test
{
	sgb::Sgb* s = sgb::new();
	defer s.free();
	s.pal[0] = { 0, 0, 0, 0x001F };          // palette 0, shade 3 = red
	s.pal[1] = { 0, 0, 0, 0x7C00 };          // palette 1, shade 3 = blue
	s.attr[1] = 1;                           // second cell of the first row

	char[] shades = mem::new_array(char, ppu::WIDTH * ppu::HEIGHT);
	defer free(shades.ptr);
	char[] rgb = mem::new_array(char, ppu::WIDTH * ppu::HEIGHT * 3);
	defer free(rgb.ptr);
	for (usz i = 0; i < shades.len; i++) shades[i] = 3;

	s.render(shades, rgb);
	test::eq((char)0xF8, rgb[0]);            // x=0: red
	test::eq((char)0xF8, rgb[8 * 3 + 2]);    // x=8: blue

	s.mask = sgb::MASK_FREEZE;
	for (usz i = 0; i < shades.len; i++) shades[i] = 0;
	s.render(shades, rgb);
	test::eq((char)0xF8, rgb[0]);            // still the frozen picture
}
