module adapter_test;
import gameboy, mmu;
import std::core::test;

// The DMG-07 4-Player Adapter against four Game Boys that answer as a game
// does: each transfer, every Game Boy waits (SC = $80) with its reply in SB.

struct Rig {
	gameboy::GameBoy[4] gb;
	mmu::Adapter a;
}

// One transfer: each player's reply in, what each got back out.
fn char[4] Rig.transfer(&self, char[4] replies) {
	mmu::Mmu*[4] m;
	for (int p = 0; p < 4; p++) {
		self.gb[p].mmu.io[0x01] = replies[p];
		self.gb[p].mmu.io[0x02] = 0x80;
		m[p] = &self.gb[p].mmu;
	}
	self.a.tick(m, self.a.next_at);
	char[4] got;
	for (int p = 0; p < 4; p++) got[p] = self.gb[p].mmu.io[0x01];
	return got;
}

fn char[4] all(char v) => { v, v, v, v };

fn void ping_then_transmission() @test {
	Rig* r = mem::new(Rig);
	defer free(r);
	for (int p = 0; p < 4; p++) r.gb[p] = gameboy::new(false, DMG);
	defer { for (int p = 0; p < 4; p++) r.gb[p].destroy(); }
	r.a.init(4194304);

	// Ping: $FE, then status bytes with each player's number. A Game Boy's
	// answer to a byte comes with the byte after: the packet size (from the
	// last packet), $88, $88, the rate.
	char[4] got = r.transfer(all(0x01));
	test::@check(got == all(0xFE), "ping header");
	got = r.transfer(all(0x88));
	test::@check(got == (char[4]){ 1, 2, 3, 4 }, "nobody connected yet, player numbers");
	r.transfer(all(0x88));
	r.transfer(all(0x00));                     // rate
	// The next packet knows all four are there.
	r.transfer(all(0x01));                     // one byte a player
	got = r.transfer(all(0x88));
	test::@check(got == (char[4]){ 0xF1, 0xF2, 0xF3, 0xF4 }, "all connected");
	r.transfer(all(0x88));
	r.transfer(all(0x00));

	// Player 1 asks for transmission with $AA; after this packet the
	// adapter answers $CC.
	for (int i = 0; i < 4; i++) r.transfer({ 0xAA, 0x88, 0x88, 0x88 });
	for (int i = 0; i < 4; i++) {
		got = r.transfer(all(0x00));
		test::@check(got == all(0xCC), "confirm %d", i);
	}

	// Transmission, one byte a player: each one's byte comes with the
	// second transfer; everyone gets all four in the next packet.
	char[4] sent = { 0x10, 0x11, 0x12, 0x13 };
	r.transfer(all(0x00));
	r.transfer(sent);
	for (int i = 2; i < 4; i++) r.transfer(all(0x00));
	for (int i = 0; i < 4; i++) {
		got = r.transfer(i == 1 ? (char[4]){ 0x20, 0x21, 0x22, 0x23 } : all(0x00));
		test::@check(got == all(sent[i]), "player %d's byte to everyone", i + 1);
	}

	// $FF twice from player 1: a packet of $FF, then ping again.
	for (int i = 0; i < 4; i++) r.transfer({ 0xFF, 0x00, 0x00, 0x00 });
	for (int i = 0; i < 4; i++) {
		got = r.transfer(all(0x00));
		test::@check(got == all(0xFF), "restart %d", i);
	}
	got = r.transfer(all(0x88));
	test::@check(got == all(0xFE), "ping again");
}
