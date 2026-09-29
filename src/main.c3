module wer;
import std::io, std::io::file, std::time::clock, std::thread::os, std::math;
import gameboy, ppu, display, mmu;

// 70224 T-cycles per frame / 4 194 304 Hz ≈ 59.73 fps.
const NanoDuration PERIOD = (NanoDuration)16_742_706;
const NanoDuration MAX_LAG = (NanoDuration)100_000_000;

const float AUDIO_TARGET_BYTES = 9600;  // 50 ms of s16 stereo @ 48 kHz
const float MAX_RATE_ADJ = 0.005; // ±0.5%
const float MAX_INTEG = 0.002;  // ±0.2%
const float INTEG_GAIN = 0.000004; // per frame; slow enough not to chase startup spikes.

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

fn void? write_ppm(gameboy::GameBoy* gb, String path, char[12] colors) {
	char[] rgb = mem::new_array(char, ppu::WIDTH * ppu::HEIGHT * 3);
	defer free(rgb.ptr);
	gb.frame_rgb(rgb, colors);
	DString out;
	out.init(mem);
	defer out.free();
	out.appendf("P6\n%d %d\n255\n", ppu::WIDTH, ppu::HEIGHT);
	foreach (b : rgb) out.append_char(b);
	file::save(path, out.str_view())!;
}

faultdef ROM_UNREADABLE;

// --sgb-log: print every command an SGB game sends.
bool sgb_log;

// Replace the running game with the ROM at `path`. The file is read first, so
// a failed load leaves the current game untouched; destroy() writes the old
// game's battery save before it goes away.
fn gameboy::Cartridge? load_game(gameboy::GameBoy* gb, String path, bool boot, mmu::Model model, int pal) {
	char[]? data = file::load_temp(path);
	if (catch data) {
		io::eprintfn("could not load ROM: %s", path);
		return ROM_UNREADABLE~;
	}
	gb.destroy();
	*gb = gameboy::new(boot, model);
	apply_preset(gb, pal);
	gb.mmu.serial_echo = true; // Blargg-style test ROMs report over serial
	if (gb.mmu.sgb) gb.mmu.sgb.log = sgb_log;
	gameboy::Cartridge cart = gb.load_rom_named(data, path);
	cart.print();
	return cart;
}

fn String window_title(gameboy::Cartridge* cart, mmu::Model model) {
	return string::tformat("wer - %s%s", (ZString)&cart.title[0], model == SGB ? " [SGB]" : "");
}

// The SGB's built-in palettes, offered in SGB mode (DMG mode is always the
// green DMG screen), in the order Left/Right cycles through them. The first,
// 1-A, is the SGB's default.
const String[32] PALETTE_NAMES = {
	"1-A", "1-B", "1-C", "1-D", "1-E", "1-F", "1-G", "1-H",
	"2-A", "2-B", "2-C", "2-D", "2-E", "2-F", "2-G", "2-H",
	"3-A", "3-B", "3-C", "3-D", "3-E", "3-F", "3-G", "3-H",
	"4-A", "4-B", "4-C", "4-D", "4-E", "4-F", "4-G", "4-H",
};

// Index into PALETTE_NAMES, or -1; the letter may be lower case ("4-h").
fn int palette_index(String name) {
	foreach (i, n : PALETTE_NAMES) {
		if (name == n) return (int)i;
		if (name.len == 3 && name[0] == n[0] && name[1] == n[1] && (name[2] | 0x20) == (n[2] | 0x20)) return (int)i;
	}
	return -1;
}

// The colours shades 0-3 are shown in: the fixed DMG green, or in SGB mode
// the chosen SGB palette.
// In SGB mode the chosen preset colours everything until the game sends its
// own palettes (and again whenever the player picks one in the menu).
fn void apply_preset(gameboy::GameBoy* gb, int pal) {
	if (gb.mmu.sgb) gb.mmu.sgb.set_preset(display::SGB_PALETTES[pal]);
}

fn char[12] mode_colors(mmu::Model model, int pal) {
	char[12] colors;
	display::palette_rgb(model == SGB ? PALETTE_NAMES[pal] : "dmg", &colors);
	return colors;
}

enum MenuItem : char {
	RESUME,
	OPEN,
	MODE,
	PALETTE,
	RESET,
	QUIT,
}

fn int main(String[] args)
{
	bool headless = false;
	bool boot = true;
	int frames = 600;
	String rom;
	String palette;
	mmu::Model model = DMG;
	foreach (a : args[1..]) {
		switch {
			case a == "--headless": headless = true;
			case a == "--no-boot": boot = false;
			case a.starts_with("--frames="): frames = a[9..].to_int() ?? 600;
			case a.starts_with("--palette="): palette = a[10..];
			case a == "--sgb-log": sgb_log = true;
			case a == "--mode=dmg": model = DMG;
			case a == "--mode=sgb": model = SGB;
			case a.starts_with("--mode="):
				io::eprintfn("unknown mode '%s': use dmg or sgb", a[7..]);
				return 1;
			default: rom = a;
		}
	}

	int pal = 0; // 1-A
	if (palette.len) {
		if (model != SGB) {
			io::eprintn("--palette only applies to --mode=sgb (DMG mode is always green)");
			return 1;
		}
		pal = palette_index(palette);
		if (pal < 0) {
			io::eprintfn("unknown palette '%s': use an SGB palette 1-A .. 4-H", palette);
			return 1;
		}
	}
	char[12] colors = mode_colors(model, pal);

	gameboy::GameBoy gb = gameboy::new(false, model);
	defer gb.destroy();
	apply_preset(&gb, pal);

	gameboy::Cartridge cart;
	bool has_rom = false;
	if (rom.len) {
		gameboy::Cartridge? loaded = load_game(&gb, rom, boot, model, pal);
		if (catch loaded) return 1;
		cart = loaded;
		has_rom = true;
	}

	if (headless) {
		if (!has_rom) setup_demo_scene(&gb);
		for (int f = 0; f < frames; f++) gb.run_frame();
		if (catch write_ppm(&gb, "wer-frame.ppm", colors)) {
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

	// The path of the running ROM, kept for Reset (heap copy: args and dialog
	// results don't live that long).
	String rom_path = has_rom ? rom.copy(mem) : "";
	defer if (rom_path.len) free(rom_path.ptr);
	if (has_rom) screen.set_title(window_title(&cart, model));

	// Without a ROM there is nothing to run: start in the menu.
	bool menu = !has_rom;
	int selected = 0;

	char[] rgb = mem::new_array(char, ppu::WIDTH * ppu::HEIGHT * 3);
	defer free(rgb.ptr);
	short[4096] audio;
	Clock next = clock::now();
	float avg = AUDIO_TARGET_BYTES;
	float integ = 0;
	while (true) {
		display::Input in = screen.poll();
		if (in.quit) break;

		// A ROM chosen in the file dialog (menu or Ctrl+O) replaces the game.
		String chosen = screen.take_dialog_result();
		if (chosen.len) {
			if (try loaded = load_game(&gb, chosen, boot, model, pal)) {
				cart = loaded;
				has_rom = true;
				menu = false;
				if (rom_path.len) free(rom_path.ptr);
				rom_path = chosen.copy(mem);
				screen.set_title(window_title(&cart, model));
				screen.clear_audio();
				next = clock::now();
			}
		}

		if (in.pressed & display::KEY_OPEN) screen.open_rom_dialog();
		if ((in.pressed & display::KEY_MENU) && has_rom) {
			menu = !menu;
			selected = 0;
			screen.clear_audio();
		}

		// The menu: which items exist depends on whether a game is loaded.
		MenuItem[6] items;
		String[6] lines;
		int count = 0;
		if (menu) {
			if (has_rom) items[count++] = RESUME;
			items[count++] = OPEN;
			items[count++] = MODE;
			if (model == SGB) items[count++] = PALETTE;
			if (has_rom) items[count++] = RESET;
			items[count++] = QUIT;
			if (selected >= count) selected = count - 1;

			if (in.pressed & display::KEY_UP)   selected = (selected + count - 1) % count;
			if (in.pressed & display::KEY_DOWN) selected = (selected + 1) % count;

			MenuItem item = items[selected];
			bool enter = (in.pressed & display::KEY_ENTER) != 0;
			int step = 0;
			if (in.pressed & display::KEY_LEFT) step = -1;
			if ((in.pressed & display::KEY_RIGHT) || (enter && item == PALETTE)) step = 1;

			// Switching the model restarts the running game on the other hardware.
			if (item == MODE && (step != 0 || enter)) {
				model = model == DMG ? mmu::Model.SGB : mmu::Model.DMG;
				colors = mode_colors(model, pal);
				apply_preset(&gb, pal);
				if (has_rom) {
					if (try loaded = load_game(&gb, rom_path, boot, model, pal)) {
						cart = loaded;
						screen.set_title(window_title(&cart, model));
					}
				} else {
					gb.destroy();
					gb = gameboy::new(false, model);
					apply_preset(&gb, pal);
				}
			}
			if (item == PALETTE && step != 0) {
				int n = (int)PALETTE_NAMES.len;
				pal = (pal + step + n) % n;
				colors = mode_colors(model, pal);
				apply_preset(&gb, pal);
			}
			if (enter) {
				switch (item) {
					case RESUME: menu = false;
					case OPEN:   screen.open_rom_dialog();
					case RESET:
						if (try loaded = load_game(&gb, rom_path, boot, model, pal)) {
							cart = loaded;
							menu = false;
							next = clock::now();
						}
					case QUIT:   break;
					case PALETTE: break;
					case MODE:   break;
				}
				if (item == QUIT) break;
			}

			for (int i = 0; i < count; i++) {
				switch (items[i]) {
					case RESUME:  lines[i] = "Resume";
					case OPEN:    lines[i] = screen.dialog_open() ? "Open ROM...  (dialog open)" : "Open ROM...  (Ctrl+O)";
					case MODE:    lines[i] = string::tformat("Mode:    < %s >", model == SGB ? "SGB" : "DMG");
					case PALETTE: lines[i] = string::tformat("Palette: < %s >", PALETTE_NAMES[pal]);
					case RESET:   lines[i] = "Reset";
					case QUIT:    lines[i] = "Quit";
				}
			}
		}

		// The game only runs while neither the menu nor the file dialog is up.
		if (!menu && !screen.dialog_open()) {
			gb.mmu.set_input(in.buttons, in.dpad);
			gb.run_frame();
			screen.queue_audio(&audio, gb.audio(&audio));
			int queued = screen.audio_queued();
			avg += (queued - avg) / 32;
			float e = (avg - AUDIO_TARGET_BYTES) / AUDIO_TARGET_BYTES;
			e = math::clamp(e, -1, 1);
			integ += e * INTEG_GAIN;
			integ = math::clamp(integ, -MAX_INTEG, +MAX_INTEG);
			gb.set_audio_rate((uint)(display::AUDIO_RATE * (1 - MAX_RATE_ADJ * e - integ)));
		}
		gb.frame_rgb(rgb, colors);
		screen.present(rgb, lines[:count], selected);

		next += PERIOD;
		Clock now = clock::now();
		if (now - next > MAX_LAG) next = now;
		NanoDuration remaining = next - now;
		(void)os::native_sleep_nano(remaining);
	}
	return 0;
}
