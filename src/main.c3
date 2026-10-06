module wer;
import std::io, std::io::file, std::time::clock, std::thread::os, std::math;
import gameboy, ppu, display, mmu, config, netlink;

// Real time per frame: 70224 T-cycles at the model's clock (59.73 fps on a
// DMG, 61.17 fps on an original SGB).
fn NanoDuration frame_period(mmu::Model model) {
	return (NanoDuration)(70224UL * 1_000_000_000UL / model.clock_hz());
}
const NanoDuration MAX_LAG = (NanoDuration)100_000_000;

// Fast forward runs at most this many frames per shown frame.
const int FAST_FORWARD_MAX = 16;

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
// `mode` is the player's choice; CGB-only games run on a CGB regardless
// (gb.mmu.model is the model actually running).
fn gameboy::Cartridge? load_game(gameboy::GameBoy* gb, String path, bool boot, Mode mode, int pal) {
	mmu::Model model = mode.model();
	char[]? data = file::load_temp(path);
	if (catch data) data = display::load_file_temp(path); // content:// URIs
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
	gb.set_cgb_revision(mode.revision());
	gb.set_dmg_revision(mode.dmg_revision());
	apply_preset(gb, pal);
	gb.mmu.serial_echo = true; // Blargg-style test ROMs report over serial
	if (gb.mmu.sgb) gb.mmu.sgb.log = sgb_log;
	String base = gameboy::save_base(path, data);
	gameboy::migrate_saves(path, base);
	if (save_base.len) free(save_base.ptr);
	save_base = base.copy(mem);
	gameboy::Cartridge cart = gb.load_rom_named(data, base);
	cart.print();
	link_replug();
	return cart;
}

const String[6] REV_LETTERS = { "0", "A", "B", "C", "D", "E" };

fn String window_title(gameboy::Cartridge* cart, gameboy::GameBoy* gb) {
	String tag;
	switch (gb.mmu.model) {
		case DMG:  tag = gb.mmu.dmg_rev == ABC ? "" : gb.mmu.dmg_rev == MGB ? " [Pocket]" : " [DMG-0]";
		case SGB:  tag = " [SGB]";
		case SGB2: tag = " [SGB2]";
		case CGB:  tag = gb.mmu.cgb_rev == C ? " [CGB]" : string::tformat(" [CGB-%s]", REV_LETTERS[gb.mmu.cgb_rev.ordinal]);
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

fn char[12] mode_colors(Mode mode, int pal) {
	char[12] colors;
	display::palette_rgb(mode.model().is_sgb() ? PALETTE_NAMES[pal] : mode == MGB ? "mgb" : "dmg", &colors);
	return colors;
}

// What the player picks: a model, and for a CGB its chip revision. In the
// menu's order (Left/Right cycles through them).
enum Mode : char {
	DMG_0,  // CPU DMG 0, the first DMGs
	DMG,    // CPU DMG A, B or C
	MGB,    // Game Boy Pocket / Light
	SGB,
	SGB2,
	CGB_0,  // CPU CGB 0 ... E: the CGB's chip revisions
	CGB_A,
	CGB_B,
	CGB,    // CPU CGB C, the default CGB
	CGB_D,
	CGB_E,
}

const String[11] MODE_NAMES = { "dmg-0", "dmg", "mgb", "sgb", "sgb2", "cgb-0", "cgb-a", "cgb-b", "cgb", "cgb-d", "cgb-e" };
const String[11] MODE_LABELS = { "DMG (0)", "DMG", "Pocket", "SGB", "SGB2", "CGB (0)", "CGB (A)", "CGB (B)", "CGB (C)", "CGB (D)", "CGB (E)" };

fn mmu::Model Mode.model(self) {
	switch (self) {
		case DMG_0:
		case DMG:
		case MGB:   return mmu::Model.DMG;
		case SGB:   return mmu::Model.SGB;
		case SGB2:  return mmu::Model.SGB2;
		default:    return mmu::Model.CGB;
	}
}

fn mmu::CgbRevision Mode.revision(self) {
	switch (self) {
		case CGB_0: return mmu::CgbRevision.CGB0;
		case CGB_A: return mmu::CgbRevision.A;
		case CGB_B: return mmu::CgbRevision.B;
		case CGB_D: return mmu::CgbRevision.D;
		case CGB_E: return mmu::CgbRevision.E;
		default:    return mmu::CgbRevision.C;
	}
}

fn mmu::DmgRevision Mode.dmg_revision(self) {
	switch (self) {
		case DMG_0: return mmu::DmgRevision.DMG0;
		case MGB:   return mmu::DmgRevision.MGB;
		default:    return mmu::DmgRevision.ABC;
	}
}

// The mode after `m` (dir = +1 / -1).
fn Mode cycle_mode(Mode m, int dir) {
	int n = (int)MODE_NAMES.len;
	return (Mode)((m.ordinal + (dir > 0 ? 1 : n - 1)) % n);
}

// A mode's name in the settings and on the command line ("cgb-c" is "cgb").
fn Mode? mode_from(String name) {
	if (name == "cgb-c") return CGB;
	foreach (i, n : MODE_NAMES) if (name == n) return (Mode)(i);
	return NOT_FOUND~;
}

// Store the current settings in ~/.wer/wer.conf.
fn void save_settings(config::Config* cfg, Mode mode, int pal, int scale) {
	cfg.set("mode", MODE_NAMES[mode.ordinal]);
	cfg.set("palette", PALETTE_NAMES[pal]);
	cfg.set("color", gameboy::COLOR_NAMES[gameboy::color_correction.ordinal]);
	cfg.set("blend", display::BLEND_NAMES[blend.ordinal]);
	cfg.scale = scale;
	if (catch cfg.save()) io::eprintfn("could not save %s", config::tpath());
}

// A one-line notice shown over the game for a moment.
struct Notice {
	char[64] text;
	usz      len;
	Clock    until;
}

fn void Notice.show(&self, String s) {
	self.len = s.len < self.text.len ? s.len : self.text.len;
	for (usz i = 0; i < self.len; i++) self.text[i] = s[i];
	self.until = clock::now() + (NanoDuration)2_000_000_000;
}

fn String Notice.current(&self) => clock::now() < self.until ? (String)self.text[:self.len] : "";

// Frame blending (display::Blend) and the frames run so far (its parity).
display::Blend blend;
ulong frames_run;

// Where the loaded game's battery save and save states go (gameboy::save_base).
String save_base;

// Save states: slots 1-9 per game, files next to the ROM (see gameboy::state_path).
const int STATE_SLOTS = 9;

fn void save_slot(gameboy::GameBoy* gb, String rom_path, int n, Notice* notice) {
	if (catch gb.save_state_file(gameboy::state_path(rom_path, n))) {
		notice.show(string::tformat("Could not save state %d", n));
		return;
	}
	notice.show(string::tformat("Saved state %d", n));
}

// True when the state was loaded (the game continues from it).
fn bool load_slot(gameboy::GameBoy* gb, String rom_path, int n, Notice* notice) {
	String path = gameboy::state_path(rom_path, n);
	if (!file::is_file(path)) {
		notice.show(string::tformat("State %d is empty", n));
		return false;
	}
	if (catch f = gb.load_state_file(path)) {
		String why;
		switch (f) {
			case gameboy::STATE_OTHER_BUILD: why = "another wer version";
			case gameboy::STATE_OTHER_MODEL: why = "another model";
			case gameboy::STATE_OTHER_GAME:  why = "another game";
			default:                         why = "unreadable";
		}
		notice.show(string::tformat("State %d: %s", n, why));
		return false;
	}
	notice.show(string::tformat("Loaded state %d", n));
	return true;
}

fn bool slot_used(String rom_path, int n) => file::is_file(gameboy::state_path(rom_path, n));

enum MenuItem : char {
	RESUME,
	SAVE_STATE,
	LOAD_STATE,
	OPEN,
	MODE,
	PALETTE,
	COLORS,
	BLEND,
	SCALE,
	CONTROLS,
	LINK,
	RESET,
	QUIT,
}

// Labels of the Game Boy buttons in the Controls menu (config::Button order).
const String[8] BUTTON_LABELS = { "A", "B", "Select", "Start", "Up", "Down", "Left", "Right" };

// Controls menu lines after the 8 buttons.
const int CONTROLS_DEFAULTS = 8;
const int CONTROLS_BACK     = 9;
const int CONTROLS_COUNT    = 10;

// The main loop's state, shared by main() and frame().
config::Config cfg;
bool boot = true;
Mode mode;
int scale;
int pal;
char[12] colors;
gameboy::GameBoy gb;
gameboy::Cartridge cart;
bool has_rom;
display::Display screen;
// The path of the running ROM, kept for Reset (heap copy: args and dialog
// results don't live that long).
String rom_path;
bool menu;              // the menu is showing
int selected;           // its highlighted line
bool controls;          // the Controls submenu is showing
int binding = -1;       // Controls: the button waiting for a new key/pad button
bool paused;            // P: the game stops (N runs it one frame)
int slot = 1;           // save state slot the menu works on
Notice notice;
char[] rgb;             // the picture, gameboy::MAX_FRAME_RGB
short[4096] audio;
Clock next;             // when the next frame is due
float avg = AUDIO_TARGET_BYTES; // audio queue level, smoothed (rate control)
float integ;
bool skip_picture;      // catching up (web.c3): emulate, don't draw

// One pass of the main loop: input, the menu, a frame of emulation, the
// picture. False when wer should quit. The caller paces it (until `next`).
fn bool frame() {
	display::Input in = screen.poll();
	if (in.quit) return false;

	// A ROM chosen in the file dialog (menu or Ctrl+O) replaces the game.
	String chosen = screen.take_dialog_result();
	if (chosen.len && dialog_p2) {
		link_second_chosen(chosen);
		menu = false;
		chosen = "";
	}
	if (!screen.dialog_open()) dialog_p2 = false;
	if (chosen.len) {
		if (try loaded = load_game(&gb, chosen, boot, mode, pal)) {
			cart = loaded;
			has_rom = true;
			menu = false;
			if (rom_path.len) free(rom_path.ptr);
			rom_path = chosen.copy(mem);
			screen.set_title(window_title(&cart, &gb));
			screen.clear_audio();
			paused = false;
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
		save_settings(&cfg, mode, pal, scale);
		binding = -1;
		in.pressed = 0;
	}

	link_typing(&in);
	if (in.pressed & display::KEY_OPEN) screen.open_rom_dialog();
	if ((in.pressed & display::KEY_MENU) && controls) {
		controls = false;               // back to the main menu
		selected = 0;
	} else if ((in.pressed & display::KEY_MENU) && has_rom) {
		menu = !menu;
		selected = 0;
		screen.clear_audio();
	}

	// Hotkeys while a game is showing: pause, frame advance, save states.
	bool advance = false;
	if (has_rom && !menu) {
		if (in.pressed & display::KEY_PAUSE) {
			paused = !paused;
			screen.clear_audio();
			notice.show(paused ? "Paused" : "");
		}
		if ((in.pressed & display::KEY_SWAP) && link_mode == LOCAL) {
			keyboard_player ^= 1;
			notice.show(keyboard_player ? "Keyboard: player 2" : "Keyboard: player 1");
		}
		if (in.pressed & display::KEY_ADVANCE) {
			if (!paused) screen.clear_audio();
			paused = true;
			advance = true;
		}
		if (in.state_slot > 0) {
			slot = in.state_slot;
			if (in.state_save) {
				save_slot(&gb, save_base, slot, &notice);
			} else if (load_slot(&gb, save_base, slot, &notice)) {
				screen.clear_audio();
				next = clock::now();
			}
		}
	}

	// The menu: which items exist depends on whether a game is loaded.
	MenuItem[16] items;
	String[16] lines;
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
						save_settings(&cfg, mode, pal, scale);
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
		if (has_rom) {
			items[count++] = RESUME;
			items[count++] = SAVE_STATE;
			items[count++] = LOAD_STATE;
		}
		items[count++] = OPEN;
		items[count++] = MODE;
		if (mode.model().is_sgb()) items[count++] = PALETTE;
		if (mode.model() == CGB || mode.model().is_sgb()) items[count++] = COLORS;
		items[count++] = BLEND;
		// (On a phone the picture fills the screen; in a browser the page sizes it.)
		if (!env::ANDROID && !env::EMSCRIPTEN) items[count++] = SCALE;
		items[count++] = CONTROLS;
		items[count++] = LINK;
		if (has_rom) items[count++] = RESET;
		items[count++] = QUIT;
		if (selected >= count) selected = count - 1;

		if (in.pressed & display::KEY_UP)   selected = (selected + count - 1) % count;
		if (in.pressed & display::KEY_DOWN) selected = (selected + 1) % count;

		MenuItem item = items[selected];
		bool enter = (in.pressed & display::KEY_ENTER) != 0;
		int step = 0;
		if (in.pressed & display::KEY_LEFT) step = -1;
		if ((in.pressed & display::KEY_RIGHT) || (enter && (item == PALETTE || item == COLORS || item == BLEND))) step = 1;

		// Switching the model restarts the running game on the other hardware.
		if (item == MODE && (step != 0 || enter)) {
			mode = cycle_mode(mode, step < 0 ? -1 : 1);
			colors = mode_colors(mode, pal);
			apply_preset(&gb, pal);
			if (has_rom) {
				if (try loaded = load_game(&gb, rom_path, boot, mode, pal)) {
					cart = loaded;
					screen.set_title(window_title(&cart, &gb));
				}
			} else {
				gb.destroy();
				gb = gameboy::new(false, mode.model());
				gb.set_cgb_revision(mode.revision());
				gb.set_dmg_revision(mode.dmg_revision());
				apply_preset(&gb, pal);
			}
			save_settings(&cfg, mode, pal, scale);
		}
		if (item == SCALE && (step != 0 || enter)) {
			int n = display::MAX_SCALE - display::MIN_SCALE + 1;
			scale = (scale - display::MIN_SCALE + (step < 0 ? n - 1 : 1)) % n + display::MIN_SCALE;
			screen.set_scale(scale);
			save_settings(&cfg, mode, pal, scale);
		}
		if (item == BLEND && step != 0) {
			blend = (display::Blend)(((int)blend.ordinal + 3 + step) % 3);
			screen.blend = blend;
			save_settings(&cfg, mode, pal, scale);
		}
		if (item == COLORS && step != 0) {
			int n = (int)gameboy::COLOR_NAMES.len;
			gameboy::color_correction = (gameboy::ColorCorrection)(((int)gameboy::color_correction.ordinal + n + step) % n);
			save_settings(&cfg, mode, pal, scale);
		}
		if (item == LINK && step != 0) link_step(step);
		if ((item == SAVE_STATE || item == LOAD_STATE) && step != 0) {
			slot = (slot - 1 + step + STATE_SLOTS) % STATE_SLOTS + 1;
		}
		if (item == PALETTE && step != 0) {
			int n = (int)PALETTE_NAMES.len;
			pal = (pal + step + n) % n;
			colors = mode_colors(mode, pal);
			apply_preset(&gb, pal);
			save_settings(&cfg, mode, pal, scale);
		}
		if (enter) {
			switch (item) {
				case RESUME: menu = false;
				case SAVE_STATE:
					save_slot(&gb, save_base, slot, &notice);
					menu = false;
				case LOAD_STATE:
					if (load_slot(&gb, save_base, slot, &notice)) {
						menu = false;
						next = clock::now();
					}
				case OPEN:   screen.open_rom_dialog();
				case CONTROLS:
					controls = true;
					selected = 0;
				case LINK:
					link_apply();
					if (link_mode == HOST) menu = false;
				case RESET:
					if (try loaded = load_game(&gb, rom_path, boot, mode, pal)) {
						cart = loaded;
						menu = false;
						paused = false;
						next = clock::now();
					}
				case QUIT:   break;
				case PALETTE: break;
				case COLORS:  break;
				case BLEND:   break;
				case MODE:   break;
				case SCALE:  break;
			}
			if (item == QUIT) return false;
		}

		for (int i = 0; i < count; i++) {
			switch (items[i]) {
				case RESUME:  lines[i] = "Resume";
				case SAVE_STATE:
					lines[i] = string::tformat("Save state: < %d >%s", slot, slot_used(save_base, slot) ? "" : " (empty)");
				case LOAD_STATE:
					lines[i] = string::tformat("Load state: < %d >%s", slot, slot_used(save_base, slot) ? "" : " (empty)");
				// At 1x the window is 20 characters wide: no hints there.
				case OPEN:
					if (scale == 1) {
						lines[i] = "Open ROM...";
					} else {
						lines[i] = screen.dialog_open() ? "Open ROM...  (dialog open)" : env::ANDROID || env::EMSCRIPTEN ? "Open ROM..." : "Open ROM...  (Ctrl+O)";
					}
				case SCALE:   lines[i] = string::tformat("Scale:   < %dx >", scale);
				case MODE:    lines[i] = string::tformat("Mode:    < %s >", MODE_LABELS[mode.ordinal]);
				case PALETTE: lines[i] = string::tformat("Palette: < %s >", PALETTE_NAMES[pal]);
				case COLORS:  lines[i] = string::tformat("Colors:  < %s >", gameboy::COLOR_LABELS[gameboy::color_correction.ordinal]);
				case BLEND:   lines[i] = string::tformat("Blending: < %s >", display::BLEND_LABELS[blend.ordinal]);
				case CONTROLS: lines[i] = "Controls...";
				case LINK:    lines[i] = link_line();
				case RESET:   lines[i] = "Reset";
				case QUIT:    lines[i] = "Quit";
			}
		}
	}

	// The game only runs while neither the menu nor the file dialog is up,
	// and not while paused (except the one frame N asks for).
	bool running = !menu && !screen.dialog_open() && (!paused || advance);
	// MBC7 tilt in; a rumble cartridge's motor out (still while stopped).
	float[<2>] tilt = screen.tilt(has_rom && gb.has_tilt());
	gb.set_tilt(tilt.x, tilt.y);
	char[] view = screen.camera(has_rom && gb.has_camera());
	if (view.len) gb.set_camera_image(view);
	if (running && in.fast && !paused) {
		// Fast forward: as many frames as fit in most of a frame's time,
		// the last one shown, without sound.
		Clock start = clock::now();
		NanoDuration budget = frame_period(gb.mmu.model) * 3 / 4;
		int n = 0;
		do {
			link_run_frame(&in);
			frames_run++;
			gb.audio(&audio);
			n++;
		} while (n < FAST_FORWARD_MAX && clock::now() - start < budget);
		screen.clear_audio();
	} else if (running) {
		link_run_frame(&in);
		frames_run++;
		if (paused) {
			gb.audio(&audio); // a single frame's sound would only click
		} else {
			screen.queue_audio(&audio, gb.audio(&audio));
			int queued = screen.audio_queued();
			avg += (queued - avg) / 32;
			float e = (avg - AUDIO_TARGET_BYTES) / AUDIO_TARGET_BYTES;
			e = math::clamp(e, -1, 1);
			integ += e * INTEG_GAIN;
			integ = math::clamp(integ, -MAX_INTEG, +MAX_INTEG);
			gb.set_audio_rate((uint)(display::AUDIO_RATE * (1 - MAX_RATE_ADJ * e - integ)));
		}
	}
	float motor = gb.rumble();
	screen.rumble(running && !paused ? motor : 0);
	String message = notice.current();
	if (!message.len && has_rom && !menu) {
		if (paused) message = "Paused";
		if (in.fast && !paused) message = "Fast forward";
	}
	if (!skip_picture) {
		char[] picture;
		gameboy::FrameSize size = link_picture(&picture);
		screen.odd_frame = (frames_run & 1) != 0;
		screen.blend_simple = gb.mmu.sgb != null;
		screen.present(picture, size.w, size.h, lines[:count], selected, message);
	}

	next += frame_period(gb.mmu.model);
	Clock now = clock::now();
	if (now - next > MAX_LAG) next = now;
	return true;
}

fn int main(String[] args) @winmain
{
	$if env::WIN32:
		use_parent_console();
		args = windows_args();
	$endif
	$if env::ANDROID:
		// No home directory, and ROMs come as content:// URIs: settings,
		// battery saves and save states go in the app's own folder.
		gameboy::data_dir = display::pref_path();
		config::fallback_dir = gameboy::data_dir;
	$endif
	bool headless = false;
	int frames = 600;
	String rom;
	String palette;
	String link_arg;     // --link=host or --link=ADDRESS
	String link_rom;     // --link-rom=ROM: a second Game Boy here

	// Settings from ~/.wer/wer.conf; the command line overrides them.
	cfg = config::load();
	defer cfg.free();
	mode = mode_from(cfg.mode) ?? DMG;
	scale = cfg.scale;
	pal = palette_index(cfg.palette);
	if (pal < 0) pal = 0; // 1-A
	gameboy::color_correction = (gameboy::ColorCorrection)config::color_index(cfg.color);
	blend = (display::Blend)config::blend_index(cfg.blend);

	foreach (a : args[1..]) {
		switch {
			case a == "--headless": headless = true;
			case a == "--no-boot": boot = false;
			case a.starts_with("--frames="): frames = a[9..].to_int() ?? 600;
			case a.starts_with("--palette="): palette = a[10..];
			case a == "--sgb-log": sgb_log = true;
			case a == "--printer-log": mmu::printer_log = true;
			case a.starts_with("--link="): link_arg = a[7..];
			case a.starts_with("--link-rom="): link_rom = a[11..];
			case a.starts_with("--colors="):
				int c = config::color_index(a[9..]);
				if (c < 0) {
					io::eprintfn("unknown colors '%s': use off, balanced, accurate, boost, reduce or low", a[9..]);
					return 1;
				}
				gameboy::color_correction = (gameboy::ColorCorrection)c;
			case a.starts_with("--blend="):
				int b = config::blend_index(a[8..]);
				if (b < 0) {
					io::eprintfn("unknown blend '%s': use off, simple or accurate", a[8..]);
					return 1;
				}
				blend = (display::Blend)b;
			case a.starts_with("--scale="):
				scale = a[8..].to_int() ?? 0;
				if (scale < display::MIN_SCALE || scale > display::MAX_SCALE) {
					io::eprintfn("unknown scale '%s': use 1, 2, 3 or 4", a[8..]);
					return 1;
				}
			case a.starts_with("--mode="):
				if (try m = mode_from(a[7..])) {
					mode = m;
				} else {
					io::eprintfn("unknown mode '%s': use dmg, dmg-0, mgb, sgb, sgb2, cgb (= cgb-c), cgb-0, cgb-a, cgb-b, cgb-d or cgb-e", a[7..]);
					return 1;
				}
			default: rom = a;
		}
	}

	if (palette.len) {
		if (!mode.model().is_sgb()) {
			io::eprintn("--palette only applies to --mode=sgb/sgb2 (DMG mode is always green)");
			return 1;
		}
		pal = palette_index(palette);
		if (pal < 0) {
			io::eprintfn("unknown palette '%s': use an SGB palette 1-A .. 4-H", palette);
			return 1;
		}
	}
	colors = mode_colors(mode, pal);

	gb = gameboy::new(false, mode.model());
	gb.set_cgb_revision(mode.revision());
	gb.set_dmg_revision(mode.dmg_revision());
	defer gb.destroy();
	apply_preset(&gb, pal);

	has_rom = false;
	if (rom.len) {
		gameboy::Cartridge? loaded = load_game(&gb, rom, boot, mode, pal);
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

	display::Display? opened = display::open("wer", scale);
	if (catch opened) {
		io::eprintn("no display available; re-run with --headless");
		return 1;
	}
	screen = opened;
	defer screen.close();
	defer link_stop(); // player 2's battery save, the network
	// Going to the background (Android may end the app there): write the
	// battery save now.
	display::background_hook = fn (ctx) {
		gameboy::GameBoy* g = ctx;
		if (g.mmu.cart) g.mmu.cart.save();
		if (has_p2 && gb2.mmu.cart) gb2.mmu.cart.save();
	};
	display::background_ctx = &gb;
	screen.bindings = display::bindings_from(&cfg);
	screen.blend = blend;

	rom_path = has_rom ? rom.copy(mem) : "";
	defer if (rom_path.len) free(rom_path.ptr);
	if (has_rom) screen.set_title(window_title(&cart, &gb));

	// Without a ROM there is nothing to run: start in the menu.
	menu = !has_rom;

	// The link cable from the command line.
	if (link_rom.len && has_rom) link_second_chosen(link_rom);
	if (link_arg == "printer") {
		link_printer();
		link_pick = LinkMode.PRINTER;
	} else if (link_arg == "host") {
		if (catch net.host(netlink::DEFAULT_PORT, &gb.mmu)) {
			io::eprintn("link: can't listen on port 8765");
		} else {
			link_mode = HOST;
			link_pick = LinkMode.HOST;
			io::printn("link: waiting on port 8765");
		}
	} else if (link_arg.len) {
		if (catch net.join(link_arg, &gb.mmu)) {
			io::eprintfn("link: can't reach %s", link_arg);
		} else {
			link_mode = JOIN;
			link_pick = LinkMode.JOIN;
		}
	}

	rgb = mem::new_array(char, gameboy::MAX_FRAME_RGB);
	defer free(rgb.ptr);
	next = clock::now();
	$if env::EMSCRIPTEN:
		web_run(); // the browser calls frame() at each display refresh (web.c3)
	$else
		while (frame()) {
			NanoDuration remaining = next - clock::now();
			(void)os::native_sleep_nano(remaining);
		}
	$endif
	return 0;
}
