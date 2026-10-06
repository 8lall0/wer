module rewind_test;
import gameboy, mmu;
import std::io, std::io::file;
import std::core::test;

// Rewind: back N steps lands exactly where the machine was 2N frames ago,
// and goes on from there the same way.

const String ROM = "test/blargg/dmg_sound/03-trigger.gb";

fn gameboy::GameBoy? boot() {
	char[] data = file::load_temp(ROM)!;
	gameboy::GameBoy gb = gameboy::new(true, DMG);
	gb.load_rom(data);
	if (gb.mmu.cart) gb.mmu.cart.has_battery = false;
	return gb;
}

fn void back_in_time() @test {
	gameboy::GameBoy? a = boot();
	if (catch a) {
		io::printfn("  (%s missing: scripts/fetch-blargg.sh)", ROM);
		return;
	}
	defer a.destroy();
	gameboy::Rewind r;
	defer r.free();
	short[4096] drop;
	for (int f = 0; f < 140; f++) {
		a.run_frame();
		a.audio(&drop);
		r.record(&a);
	}
	io::printfn("  %d steps, %d bytes (%d a step)", r.len(), r.bytes, r.bytes / r.len());
	for (int i = 0; i < 20; i++) assert(r.back(&a));

	// A machine that only ever ran 100 frames.
	gameboy::GameBoy b = boot()!!;
	defer b.destroy();
	for (int f = 0; f < 100; f++) {
		b.run_frame();
		b.audio(&drop);
	}
	test::eq(a.cpu.clk, b.cpu.clk);
	test::eq(a.cpu.pc, b.cpu.pc);
	for (int f = 0; f < 60; f++) {
		a.run_frame();
		b.run_frame();
		test::@check(a.mmu.ppu.fb == b.mmu.ppu.fb, "same picture %d frames on", f);
	}
	test::@check(a.mmu.wram == b.mmu.wram, "same WRAM");

	// All the way back, then no further.
	while (r.back(&a)) {}
	test::eq(r.len(), 0u);
}

fn void xor_rle_round_trip() @test {
	char[] a = mem::temp_array(char, 100000);
	char[] b = mem::temp_array(char, 100000);
	for (int i = 0; i < 100000; i += 997) b[i] = (char)i | 1;
	for (int i = 50000; i < 50300; i++) b[i] = 0x55;
	b[99999] = 7;
	char[] step = gameboy::xor_rle(a, b, mem);
	defer free(step.ptr);
	char[] c = mem::temp_array(char, 100000);
	c[..] = b[..];
	gameboy::xor_unrle(c, step);
	test::@check(c == a, "b back to a");
	test::@check(step.len < 2000, "small: %d bytes", step.len);
}
