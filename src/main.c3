module wer;
import std::io, std::io::file, std::time::clock, std::thread::os, std::math;
import gameboy, ppu, display, mmu, config;

// Real time per frame: 70224 T-cycles at the model's clock (59.73 fps on a
// DMG, 61.17 fps on an original SGB).
fn NanoDuration frame_period(mmu::Model model) {
	return (NanoDuration)(70224UL * 1_000_000_000UL / model.clock_hz());
}
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
	char[] rgb = mem::new_array(char, gameboy::MAX_FRAME_RGB);
	defer free(rgb.ptr);
	gameboy::FrameSize size = gb.frame_rgb(rgb, colors);
	DString out;
	out.init(mem);
	defer out.free();
	out.appendf("P6\n%d %d\n255\n", size.w, size.h);
	foreach (b : rgb[:(usz)(size.w * size.h * 3)]) out.append_char(b);
	file::save(path, out.str_view())!;
}

faultdef ROM_UNREADABLE;

// --sgb-log: print every command an SGB game sends.
bool sgb_log;

// Replace the running game with the ROM at `path`. The file is read first, so
// a failed load leaves the current game untouched; destroy() writes the old
// game's battery save before it goes away.
// `model` is the player's choice; CGB-only games run on a CGB regardless
// (gb.mmu.model is the model actually running).
fn gameboy::Cartridge? load_game(gameboy::GameBoy* gb, String path, bool boot, mmu::Model model, int pal) {
	char[]? data = file::load_temp(path);
	if (catch data) {
		io::eprintfn("could not load ROM: %s", path);
		return ROM_UNREADABLE~;
	}
	if (model != CGB && gameboy::requires_cgb(data)) {
		io::printfn("CGB-only game: running on a CGB instead of %s", model);
		model = CGB;
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
	String tag;
	switch (model) {
		case DMG:  tag = "";
		case SGB:  tag = " [SGB]";
		case SGB2: tag = " [SGB2]";
		case CGB:  tag = " [CGB]";
	}
	return string::tformat("wer - %s%s", (ZString)&cart.title[0], tag);
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
	display::palette_rgb(model.is_sgb() ? PALETTE_NAMES[pal] : "dmg", &colors);
	return colors;
}

// The model after `m` in the menu's DMG -> SGB -> SGB2 -> CGB order (dir = +1 / -1).
fn mmu::Model cycle_model(mmu::Model m, int dir) {
	switch (m) {
		case DMG:  return dir > 0 ? mmu::Model.SGB : mmu::Model.CGB;
		case SGB:  return dir > 0 ? mmu::Model.SGB2 : mmu::Model.DMG;
		case SGB2: return dir > 0 ? mmu::Model.CGB : mmu::Model.SGB;
		case CGB:  return dir > 0 ? mmu::Model.DMG : mmu::Model.SGB2;
	}
}

fn mmu::Model? model_from(String name) {
	switch (name) {
		case "dmg":  return DMG;
		case "sgb":  return SGB;
		case "sgb2": return SGB2;
		case "cgb":  return CGB;
		default:     return NOT_FOUND~;
	}
}

fn String model_name(mmu::Model m) {
	switch (m) {
		case DMG:  return "dmg";
		case SGB:  return "sgb";
		case SGB2: return "sgb2";
		case CGB:  return "cgb";
	}
}

// Store the current settings in ~/.wer/wer.conf.
fn void save_settings(config::Config* cfg, mmu::Model model, int pal, int scale) {
	cfg.set("mode", model_name(model));
	cfg.set("palette", PALETTE_NAMES[pal]);
	cfg.scale = scale;
	if (catch cfg.save()) io::eprintfn("could not save %s", config::tpath());
}

enum MenuItem : char {
	RESUME,
	OPEN,
	MODE,
	PALETTE,
	SCALE,
	CONTROLS,
	RESET,
	QUIT,
}

// Labels of the Game Boy buttons in the Controls menu (config::Button order).
const String[8] BUTTON_LABELS = { "A", "B", "Select", "Start", "Up", "Down", "Left", "Right" };

// Controls menu lines after the 8 buttons.
const int CONTROLS_DEFAULTS = 8;
const int CONTROLS_BACK     = 9;
const int CONTROLS_COUNT    = 10;

fn int main(String[] args)
{
	bool headless = false;
	bool boot = true;
	int frames = 600;
	String rom;
	String palette;

	// Settings from ~/.wer/wer.conf; the command line overrides them.
	config::Config cfg = config::load();
	defer cfg.free();
	mmu::Model model = model_from(cfg.mode) ?? DMG;
	int scale = cfg.scale;
	int pal = palette_index(cfg.palette);
	if (pal < 0) pal = 0; // 1-A

	foreach (a : args[1..]) {
		switch {
			case a == "--headless": headless = true;
			case a == "--no-boot": boot = false;
			case a.starts_with("--frames="): frames = a[9..].to_int() ?? 600;
			case a.starts_with("--palette="): palette = a[10..];
			case a == "--sgb-log": sgb_log = true;
			case a.starts_with("--scale="):
				scale = a[8..].to_int() ?? 0;
				if (scale < display::MIN_SCALE || scale > display::MAX_SCALE) {
					io::eprintfn("unknown scale '%s': use 1, 2, 3 or 4", a[8..]);
					return 1;
				}
			case a == "--mode=dmg": model = DMG;
			case a == "--mode=sgb": model = SGB;
			case a == "--mode=sgb2": model = SGB2;
			case a == "--mode=cgb": model = CGB;
			case a.starts_with("--mode="):
				io::eprintfn("unknown mode '%s': use dmg, sgb, sgb2 or cgb", a[7..]);
				return 1;
			default: rom = a;
		}
	}

	if (palette.len) {
		if (!model.is_sgb()) {
			io::eprintn("--palette only applies to --mode=sgb/sgb2 (DMG mode is always green)");
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

	display::Display? screen = display::open("wer", scale);
	if (catch screen) {
		io::eprintn("no display available; re-run with --headless");
		return 1;
	}
	defer screen.close();
	screen.bindings = display::bindings_from(&cfg);

	// The path of the running ROM, kept for Reset (heap copy: args and dialog
	// results don't live that long).
	String rom_path = has_rom ? rom.copy(mem) : "";
	defer if (rom_path.len) free(rom_path.ptr);
	if (has_rom) screen.set_title(window_title(&cart, gb.mmu.model));

	// Without a ROM there is nothing to run: start in the menu.
	bool menu = !has_rom;
	int selected = 0;
	bool controls = false;  // the Controls submenu is showing
	int  binding = -1;      // Controls: the button waiting for a new key/pad button

	char[] rgb = mem::new_array(char, gameboy::MAX_FRAME_RGB);
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
				screen.set_title(window_title(&cart, gb.mmu.model));
				screen.clear_audio();
				next = clock::now();
			}
		}

		// Controls: the next key or gamepad button becomes the binding (Esc
		// cancels). Nothing else reacts to this poll.
		if (binding >= 0 && (in.key >= 0 || in.pad_button >= 0)) {
			if (display::is_escape(in.key)) {
				// cancelled
			} else if (in.key >= 0) {
				cfg.set(string::tformat("key.%s", config::BUTTON_NAMES[binding]), display::key_name(in.key));
			} else {
				cfg.set(string::tformat("pad.%s", config::BUTTON_NAMES[binding]), display::pad_button_name(in.pad_button));
			}
			screen.bindings = display::bindings_from(&cfg);
			save_settings(&cfg, model, pal, scale);
			binding = -1;
			in.pressed = 0;
		}

		if (in.pressed & display::KEY_OPEN) screen.open_rom_dialog();
		if ((in.pressed & display::KEY_MENU) && controls) {
			controls = false;               // back to the main menu
			selected = 0;
		} else if ((in.pressed & display::KEY_MENU) && has_rom) {
			menu = !menu;
			selected = 0;
			screen.clear_audio();
		}

		// The menu: which items exist depends on whether a game is loaded.
		MenuItem[8] items;
		String[CONTROLS_COUNT] lines;
		int count = 0;
		if (menu && controls) {
			count = CONTROLS_COUNT;
			if (binding < 0) {
				if (in.pressed & display::KEY_UP)   selected = (selected + count - 1) % count;
				if (in.pressed & display::KEY_DOWN) selected = (selected + 1) % count;
				if (in.pressed & display::KEY_ENTER) {
					switch (selected) {
						case CONTROLS_BACK:
							controls = false;
							selected = 0;
						case CONTROLS_DEFAULTS:
							for (int i = 0; i < 8; i++) {
								cfg.set(string::tformat("key.%s", config::BUTTON_NAMES[i]), config::DEFAULT_KEYS[i]);
								cfg.set(string::tformat("pad.%s", config::BUTTON_NAMES[i]), config::DEFAULT_PADS[i]);
							}
							screen.bindings = display::bindings_from(&cfg);
							save_settings(&cfg, model, pal, scale);
						default:
							binding = selected;
					}
				}
			}
			if (controls) {
				for (int i = 0; i < 8; i++) {
					if (i == binding) {
						lines[i] = string::tformat("%-7spress key/button", BUTTON_LABELS[i]);
					} else {
						lines[i] = string::tformat("%-7s%s | %s", BUTTON_LABELS[i],
							display::key_name(screen.bindings.keys[i]), display::pad_button_name(screen.bindings.pads[i]));
					}
				}
				lines[CONTROLS_DEFAULTS] = "Reset to defaults";
				lines[CONTROLS_BACK] = "Back";
			} else {
				count = 0; // left the submenu: the main menu draws from the next frame
			}
		} else if (menu) {
			if (has_rom) items[count++] = RESUME;
			items[count++] = OPEN;
			items[count++] = MODE;
			if (model.is_sgb()) items[count++] = PALETTE;
			items[count++] = SCALE;
			items[count++] = CONTROLS;
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
				model = cycle_model(model, step < 0 ? -1 : 1);
				colors = mode_colors(model, pal);
				apply_preset(&gb, pal);
				if (has_rom) {
					if (try loaded = load_game(&gb, rom_path, boot, model, pal)) {
						cart = loaded;
						screen.set_title(window_title(&cart, gb.mmu.model));
					}
				} else {
					gb.destroy();
					gb = gameboy::new(false, model);
					apply_preset(&gb, pal);
				}
				save_settings(&cfg, model, pal, scale);
			}
			if (item == SCALE && (step != 0 || enter)) {
				int n = display::MAX_SCALE - display::MIN_SCALE + 1;
				scale = (scale - display::MIN_SCALE + (step < 0 ? n - 1 : 1)) % n + display::MIN_SCALE;
				screen.set_scale(scale);
				save_settings(&cfg, model, pal, scale);
			}
			if (item == PALETTE && step != 0) {
				int n = (int)PALETTE_NAMES.len;
				pal = (pal + step + n) % n;
				colors = mode_colors(model, pal);
				apply_preset(&gb, pal);
				save_settings(&cfg, model, pal, scale);
			}
			if (enter) {
				switch (item) {
					case RESUME: menu = false;
					case OPEN:   screen.open_rom_dialog();
					case CONTROLS:
						controls = true;
						selected = 0;
					case RESET:
						if (try loaded = load_game(&gb, rom_path, boot, model, pal)) {
							cart = loaded;
							menu = false;
							next = clock::now();
						}
					case QUIT:   break;
					case PALETTE: break;
					case MODE:   break;
					case SCALE:  break;
				}
				if (item == QUIT) break;
			}

			for (int i = 0; i < count; i++) {
				switch (items[i]) {
					case RESUME:  lines[i] = "Resume";
					// At 1x the window is 20 characters wide: no hints there.
					case OPEN:
						if (scale == 1) {
							lines[i] = "Open ROM...";
						} else {
							lines[i] = screen.dialog_open() ? "Open ROM...  (dialog open)" : "Open ROM...  (Ctrl+O)";
						}
					case SCALE:   lines[i] = string::tformat("Scale:   < %dx >", scale);
					case MODE:    lines[i] = string::tformat("Mode:    < %s >", model);
					case PALETTE: lines[i] = string::tformat("Palette: < %s >", PALETTE_NAMES[pal]);
					case CONTROLS: lines[i] = "Controls...";
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
		gameboy::FrameSize size = gb.frame_rgb(rgb, colors);
		screen.present(rgb, size.w, size.h, lines[:count], selected);

		next += frame_period(gb.mmu.model);
		Clock now = clock::now();
		if (now - next > MAX_LAG) next = now;
		NanoDuration remaining = next - now;
		(void)os::native_sleep_nano(remaining);
	}
	return 0;
}
