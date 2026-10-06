module printer_test;
import mmu, png;
import std::io, std::io::file;
import std::core::test;

// The Game Boy Printer, talked to as a game does: packets of bytes, each
// answered with what the printer decided after the one before.

const uint HZ = 4194304;

struct Sent {
	char active; // the answer to the first $00 after the checksum: $81
	char status; // ... and to the second
}

fn Sent packet(mmu::Printer* p, char command, char[] data, ulong* now, bool compressed = false) {
	char[] head = { 0x88, 0x33, command, compressed ? 1 : 0, (char)data.len, (char)(data.len >> 8) };
	ushort sum;
	foreach (i, b : head) {
		p.exchange(b, *now += 4096);
		if (i >= 2) sum += b;
	}
	foreach (b : data) {
		p.exchange(b, *now += 4096);
		sum += b;
	}
	p.exchange((char)sum, *now += 4096);
	p.exchange((char)(sum >> 8), *now += 4096);
	Sent s;
	s.active = p.exchange(0, *now += 4096);
	s.status = p.exchange(0, *now += 4096);
	return s;
}

fn void prints_a_page() @test {
	mmu::Printer p;
	p.init(HZ);
	defer p.free();
	ulong now;
	Sent s = packet(&p, 1, {}, &now); // initialise
	test::eq(s.active, 0x81);
	test::eq(s.status, 0);

	// Two rows of 20 tiles: tile 0 all shade 3, the rest shade 0.
	char[640] data;
	for (int y = 0; y < 8; y++) {
		data[y * 2] = 0xFF;
		data[y * 2 + 1] = 0xFF;
	}
	packet(&p, 4, &data, &now);
	s = packet(&p, 15, {}, &now); // a packet's own answer is from before it
	test::eq(s.status, mmu::PRINTER_UNPRINTED);

	// Print: no margin before, 2 after, the usual palette ($E4), exposure.
	s = packet(&p, 2, { 1, 0x02, 0xE4, 0x40 }, &now);
	s = packet(&p, 15, {}, &now);
	test::eq(s.status & mmu::PRINTER_PRINTING, mmu::PRINTER_PRINTING);
	now += HZ; // 16 rows take half a second
	s = packet(&p, 15, {}, &now);
	test::eq(s.status, mmu::PRINTER_DONE);

	char[] page = p.take_page(now);
	test::eq(page.len, 160 * 16);
	test::eq(page[0], 3);
	test::eq(page[7], 3);
	test::eq(page[8], 0);
	test::eq(page[160 * 7 + 7], 3);
	test::eq(page[160 * 8], 0); // the second row of tiles: blank
	p.clear_page();
	test::eq(p.take_page(now).len, 0);
}

fn void compressed_data_and_bad_checksums() @test {
	mmu::Printer p;
	p.init(HZ);
	defer p.free();
	ulong now;
	packet(&p, 1, {}, &now);
	// 640 bytes of $FF as runs: $80|n repeats the next byte n + 2 times.
	char[] runs = { 0x80 | 126, 0xFF, 0x80 | 126, 0xFF, 0x80 | 126, 0xFF, 0x80 | 126, 0xFF, 0x80 | 126, 0xFF, 0x80 | 0, 0xFF, 0x80 | 0, 0xFF, 0x80 | 0, 0xFF, 0x80 | 0, 0xFF, 0x80 | 0, 0xFF };
	packet(&p, 4, runs, &now, true);
	Sent s = packet(&p, 15, {}, &now);
	test::eq(s.status, mmu::PRINTER_UNPRINTED);
	packet(&p, 2, { 1, 0x01, 0xE4, 0x40 }, &now);
	char[] page = p.take_page(now);
	test::eq(page.len, 160 * 16);
	test::eq(page[160 * 16 - 1], 3);
	p.clear_page();

	// A checksum that doesn't add up: no "here", status bit 0.
	foreach (b : (char[]){ 0x88, 0x33, 15, 0, 0, 0, 0x99, 0x00 }) p.exchange(b, now += 4096);
	test::eq(p.exchange(0, now += 4096), 0);
	s = packet(&p, 15, {}, &now);
	test::eq(s.status & mmu::PRINTER_BAD_CHECKSUM, 0); // cleared by the next good packet
}

fn void png_signature_and_size() @test {
	char[] img = { 0, 85, 170, 255, 255, 170, 85, 0 };
	char[] out = png::grey(img, 4, 2, mem);
	defer free(out.ptr);
	test::@check(out[:8] == (char[]){ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A }, "signature");
	(void)file::save("build/printer_test.png", out);
}
