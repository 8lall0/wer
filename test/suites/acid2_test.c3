module acid2_test;

import gameboy, ppu, mmu;
import std::io;
import std::io::file;
import std::core::test;

// dmg-acid2 and cgb-acid2 PPU tests (https://github.com/mattcurrie/dmg-acid2,
// https://github.com/mattcurrie/cgb-acid2).
//
// The ROM draws a face in which every feature exercises one PPU behaviour
// (window, tile data/maps, sprite flips, priority, 8x16, LCDC bits mid-frame).
// It is not vendored. Fetch it with
//   scripts/fetch-acid2.sh
// into test/acid2/ . With no files present the tests print one line and pass.
//
// The references are stored as binary PGM / PPM (converted by the fetch
// script), so the comparison is a plain byte compare. On mismatch our frame is
// written next to them (wer-acid2.pgm, wer-cgb-acid2.ppm) for viewing.

const String ROM = "test/acid2/dmg-acid2.gb";
const String REF = "test/acid2/reference-dmg.pgm";
const String OUT = "test/acid2/wer-acid2.pgm";

const int FRAMES = 60; // the face is complete after a handful of frames
const int PIXELS = ppu::WIDTH * ppu::HEIGHT;

// Framebuffer shade (0 = lightest) -> reference gray level.
const char[4] GRAY = { 0xFF, 0xAA, 0x55, 0x00 };

fn void? write_pgm(char[] fb) {
	DString out;
	out.init(mem);
	defer out.free();
	out.appendf("P5\n%d %d\n255\n", ppu::WIDTH, ppu::HEIGHT);
	for (int i = 0; i < PIXELS; i++) out.append_char(GRAY[fb[i] & 3]);
	file::save(OUT, out.str_view())!;
}

fn void matches_reference() @test
{
	char[]? rom = file::load_temp(ROM);
	char[]? ref = file::load_temp(REF);
	if (catch rom) {
		io::eprintn("  acid2: no ROM in test/acid2 — run scripts/fetch-acid2.sh");
		return;
	}
	if (catch ref) {
		io::eprintn("  acid2: no reference in test/acid2 — run scripts/fetch-acid2.sh");
		return;
	}
	// Binary PGM: short text header, then exactly WIDTH*HEIGHT gray bytes.
	test::@check(ref.len > PIXELS && ref[0] == 'P' && ref[1] == '5', "reference is not a binary PGM");
	char[] want = ref[ref.len - PIXELS..];

	gameboy::GameBoy gb = gameboy::new(false);
	defer gb.destroy();
	gb.load_rom(rom);
	for (int f = 0; f < FRAMES; f++) gb.run_frame();

	char[] fb = gb.framebuffer();
	int wrong;
	int first = -1;
	for (int i = 0; i < PIXELS; i++) {
		if (GRAY[fb[i] & 3] == want[i]) continue;
		if (first < 0) first = i;
		wrong++;
	}

	if (wrong != 0) {
		io::eprintfn("  acid2: %d pixels differ, first at (%d, %d); frame written to %s",
			wrong, first % ppu::WIDTH, first / ppu::WIDTH, OUT);
		(void)write_pgm(fb);
	}
	test::@check(wrong == 0, "dmg-acid2 frame differs from reference (see line above)");
}

const String CGB_ROM = "test/acid2/cgb-acid2.gbc";
const String CGB_REF = "test/acid2/reference-cgb.ppm";
const String CGB_OUT = "test/acid2/wer-cgb-acid2.ppm";

fn void? write_ppm(char[] rgb) {
	DString out;
	out.init(mem);
	defer out.free();
	out.appendf("P6\n%d %d\n255\n", ppu::WIDTH, ppu::HEIGHT);
	foreach (b : rgb) out.append_char(b);
	file::save(CGB_OUT, out.str_view())!;
}

fn void cgb_matches_reference() @test
{
	char[]? rom = file::load_temp(CGB_ROM);
	char[]? ref = file::load_temp(CGB_REF);
	if (catch rom, ref) {
		io::eprintn("  cgb-acid2: no ROM/reference in test/acid2 — run scripts/fetch-acid2.sh");
		return;
	}
	// Binary PPM: short text header, then WIDTH*HEIGHT RGB triples.
	test::@check(ref.len > PIXELS * 3 && ref[0] == 'P' && ref[1] == '6', "reference is not a binary PPM");
	char[] want = ref[ref.len - PIXELS * 3..];

	gameboy::GameBoy gb = gameboy::new(false, CGB);
	defer gb.destroy();
	gb.load_rom(rom);
	for (int f = 0; f < FRAMES; f++) gb.run_frame();

	char[] rgb = mem::new_array(char, gameboy::MAX_FRAME_RGB);
	defer free(rgb.ptr);
	gameboy::FrameSize size = gb.frame_rgb(rgb, {});
	test::@check(size.w == ppu::WIDTH && size.h == ppu::HEIGHT, "unexpected frame size");
	rgb = rgb[:PIXELS * 3];

	int wrong;
	int first = -1;
	for (int i = 0; i < PIXELS; i++) {
		if (rgb[i * 3:3] == want[i * 3:3]) continue;
		if (first < 0) first = i;
		wrong++;
	}

	if (wrong != 0) {
		io::eprintfn("  cgb-acid2: %d pixels differ, first at (%d, %d); frame written to %s",
			wrong, first % ppu::WIDTH, first / ppu::WIDTH, CGB_OUT);
		(void)write_ppm(rgb);
	}
	test::@check(wrong == 0, "cgb-acid2 frame differs from reference (see line above)");
}
