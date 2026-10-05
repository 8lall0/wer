module link_test;
import gameboy, mmu, netlink, std::io;
import std::core::test;

// Two Game Boys on a link cable: the one clocking the transfer (SC = $81)
// and the one waiting for it (SC = $80) swap their SB bytes.

fn char[] program(char sb, char sc) {
	char[] rom = mem::temp_array(char, 0x8000);
	char[] code = { 0x3E, sb, 0xE0, 0x01, 0x3E, sc, 0xE0, 0x02, 0x18, 0xFE }; // ld a,sb; ldh (1),a; ld a,sc; ldh (2),a; jr $
	rom[0x100:code.len] = code[..];
	return rom;
}

fn void local_cable_swaps_bytes() @test {
	gameboy::GameBoy a = gameboy::new(false, DMG);
	gameboy::GameBoy b = gameboy::new(false, DMG);
	defer { a.destroy(); b.destroy(); }
	a.load_rom(program(0x42, 0x81));
	b.load_rom(program(0x99, 0x80));
	mmu::Link la;
	mmu::Link lb;
	mmu::connect_local(&a.mmu, &la, &b.mmu, &lb);
	gameboy::run_linked_frame(&a, &b);
	test::eq(a.mmu.io[0x01], 0x99);
	test::eq(b.mmu.io[0x01], 0x42);
	test::eq(a.mmu.io[0x02] & 0x80, 0);
	test::eq(b.mmu.io[0x02] & 0x80, 0);
	test::eq(b.mmu.io[0x0F] & 0x08, 0x08); // the slave's serial interrupt
}

fn void nobody_listening_reads_ff() @test {
	gameboy::GameBoy a = gameboy::new(false, DMG);
	gameboy::GameBoy b = gameboy::new(false, DMG);
	defer { a.destroy(); b.destroy(); }
	a.load_rom(program(0x42, 0x81));
	b.load_rom(program(0x99, 0x00)); // not waiting for a transfer
	mmu::Link la;
	mmu::Link lb;
	mmu::connect_local(&a.mmu, &la, &b.mmu, &lb);
	gameboy::run_linked_frame(&a, &b);
	test::eq(a.mmu.io[0x01], 0xFF);
	test::eq(b.mmu.io[0x01], 0x99);
}

fn void network_answer_ends_the_transfer() @test {
	gameboy::GameBoy a = gameboy::new(false, DMG);
	defer a.destroy();
	a.load_rom(program(0x42, 0x81));
	mmu::Link l;
	a.mmu.link = &l;
	a.run_frame();
	// The byte went out; the transfer waits for the answer.
	assert(l.out_pending);
	test::eq(l.out_byte, 0x42);
	test::eq(a.mmu.io[0x02] & 0x80, 0x80);
	a.mmu.link_answer(0x37);
	test::eq(a.mmu.io[0x01], 0x37);
	test::eq(a.mmu.io[0x02] & 0x80, 0);
	// And the side that waits: the master's byte comes in.
	gameboy::GameBoy b = gameboy::new(false, DMG);
	defer b.destroy();
	b.load_rom(program(0x99, 0x80));
	b.run_frame();
	test::eq(b.mmu.link_take(0x55), 0x99);
	test::eq(b.mmu.io[0x01], 0x55);
}

// Two Game Boys over TCP on this machine, in BGB's protocol: one hosts, the
// other joins; their transfer crosses the connection.
fn void network_cable_swaps_bytes() @test {
	gameboy::GameBoy a = gameboy::new(false, DMG);
	gameboy::GameBoy b = gameboy::new(false, DMG);
	defer { a.destroy(); b.destroy(); }
	a.load_rom(program(0x42, 0x81));
	b.load_rom(program(0x99, 0x80));
	netlink::NetLink host;
	netlink::NetLink guest;
	if (catch host.host(28765)) {
		io::printn("link_test: can't listen on port 28765, skipped");
		return;
	}
	defer host.close(&a.mmu);
	// The slave arms first; then the guest joins.
	b.run_frame();
	guest.join("127.0.0.1:28765", &b.mmu)!!;
	defer guest.close(&b.mmu);
	for (int f = 0; f < 30 && (a.mmu.io[0x01] != 0x99 || b.mmu.io[0x01] != 0x42); f++) {
		host.poll(&a.mmu);
		a.run_frame();
		host.poll(&a.mmu);
		guest.poll(&b.mmu);
		b.run_frame();
		guest.poll(&b.mmu);
		host.poll(&a.mmu);
	}
	assert(host.connected());
	test::eq(a.mmu.io[0x01], 0x99);
	test::eq(b.mmu.io[0x01], 0x42);
	test::eq(a.mmu.io[0x02] & 0x80, 0);
}
