module wer;
import std::io, std::io::file;
import gameboy, ppu, display;

const char[12] PPM_PALETTE = {
	0xE0, 0xF8, 0xD0,  0x88, 0xC0, 0x70,  0x34, 0x68, 0x56,  0x08, 0x18, 0x20,
};

fn void setup_demo_scene(gameboy::GameBoy* gb) {
	for (int r = 0; r < 8; r++) {
		char bits = (char)(0x80 >> r);
		gb.mmu.set((ushort)(0x8010 + r * 2), (char)~bits);
		gb.mmu.set((ushort)(0x8010 + r * 2 + 1), (char)0xFF);
	}
	for (int ty = 0; ty < 18; ty++) {
		for (int tx = 0; tx < 20; tx++) gb.mmu.set((ushort)(0x9800 + ty * 32 + tx), 0x01);
	}
	gb.mmu.set(0xFF47, 0xE4);
	gb.mmu.set(0xFF40, ppu::LCDC_ENABLE | ppu::LCDC_BG_ENABLE | ppu::LCDC_TILE_DATA);
}

fn void? write_ppm(gameboy::GameBoy* gb, String path) {
	char[] fb = gb.framebuffer();
	DString out;
	out.init(mem);
	defer out.free();
	out.appendf("P6\n%d %d\n255\n", ppu::WIDTH, ppu::HEIGHT);
	for (int i = 0; i < ppu::WIDTH * ppu::HEIGHT; i++) {
		int p = (fb[i] & 3) * 3;
		out.append_char(PPM_PALETTE[p]);
		out.append_char(PPM_PALETTE[p + 1]);
		out.append_char(PPM_PALETTE[p + 2]);
	}
	file::save(path, out.str_view())!;
}

fn int main(String[] args)
{
	bool headless = false;
	bool boot = true;
	int frames = 600;
	String rom;
	foreach (a : args[1..]) {
		switch {
			case a == "--headless": headless = true;
			case a == "--no-boot": boot = false;
			case a.starts_with("--frames="): frames = a[9..].to_int() ?? 600;
			default: rom = a;
		}
	}

	// The boot ROM draws its logo from the cartridge header, so skip it with no ROM.
	gameboy::GameBoy gb = gameboy::new(boot && rom.len > 0);
	defer gb.destroy();

	if (rom.len) {
		gb.mmu.serial_echo = true; // Blargg-style test ROMs report over serial
		gameboy::Cartridge? cart = gb.load_rom_file(rom);
		if (catch cart) {
			io::printfn("could not load ROM: %s", rom);
			return 1;
		}
		cart.print();
	} else {
		setup_demo_scene(&gb);
	}

	if (headless) {
		for (int f = 0; f < frames; f++) gb.run_frame();
		if (catch write_ppm(&gb, "wer-frame.ppm")) {
			io::eprintn("could not write wer-frame.ppm");
			return 1;
		}
		io::printfn("ran %d frames, wrote wer-frame.ppm", frames);
		return 0;
	}

	display::Display? screen = display::open("wer");
	if (catch screen) {
		io::eprintn("no display available; re-run with --headless");
		return 1;
	}
	defer screen.close();

	short[4096] audio;
	while (true) {
		display::Input in = screen.poll();
		if (in.quit) break;
		gb.mmu.set_input(in.buttons, in.dpad);

		gb.run_frame();
		screen.present(gb.framebuffer());
		screen.queue_audio(&audio, gb.audio(&audio));
	}
	return 0;
}
