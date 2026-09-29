module sgb_test;

import mmu, sgb;
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
