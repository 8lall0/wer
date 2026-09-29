module display;

import sdl, ppu, joypad;
import std::io, std::atomic;

const int SCALE = 4;

const char[12] PALETTE = {
	0xE0, 0xF8, 0xD0,
	0x88, 0xC0, 0x70,
	0x34, 0x68, 0x56,
	0x08, 0x18, 0x20,
};

// The 32 built-in Super Game Boy palettes, 1-A .. 4-H, in the SGB's own 15-bit
// BGR format. Colour 0 is the lightest, so a DMG shade (0-3) indexes it
// directly: SGB_PALETTES[palette][shade]. Values from mGBA (src/gb/overrides.c).
const ushort[4][32] SGB_PALETTES = {
	{ 0x67BF, 0x265B, 0x10B5, 0x2866 }, // 1-A  F8E8C8 D89048 A82820 301850
	{ 0x637B, 0x3AD9, 0x0956, 0x0000 }, // 1-B  D8D8C0 C8B070 B05010 000000
	{ 0x7F1F, 0x2A7D, 0x30F3, 0x4CE7 }, // 1-C  F8C0F8 E89850 983860 383898
	{ 0x57FF, 0x2618, 0x001F, 0x006A }, // 1-D  F8F8A8 C08048 F80000 501800
	{ 0x5B7F, 0x3F0F, 0x222D, 0x10EB }, // 1-E  F8D8B0 78C078 688840 583820
	{ 0x7FBB, 0x2A3C, 0x0015, 0x0900 }, // 1-F  D8E8F8 E08850 A80000 004010
	{ 0x2800, 0x7680, 0x01EF, 0x2FFF }, // 1-G  000050 00A0E8 787800 F8F858
	{ 0x73BF, 0x46FF, 0x0110, 0x0066 }, // 1-H  F8E8E0 F8B888 804000 301800
	{ 0x533E, 0x2638, 0x01E5, 0x0000 }, // 2-A  F0C8A0 C08848 287800 000000
	{ 0x7FFF, 0x2BBF, 0x00DF, 0x2C0A }, // 2-B  F8F8F8 F8E850 F83000 500058
	{ 0x7F1F, 0x463D, 0x74CF, 0x4CA5 }, // 2-C  F8C0F8 E88888 7830E8 282898
	{ 0x53FF, 0x03E0, 0x00DF, 0x2800 }, // 2-D  F8F8A0 00F800 F83000 000050
	{ 0x433F, 0x72D2, 0x3045, 0x0822 }, // 2-E  F8C880 90B0E0 281060 100810
	{ 0x7FFA, 0x2A5F, 0x0014, 0x0003 }, // 2-F  D0F8F8 F89050 A00000 180000
	{ 0x1EED, 0x215C, 0x42FC, 0x0060 }, // 2-G  68B838 E05040 E0B880 001800
	{ 0x7FFF, 0x5EF7, 0x39CE, 0x0000 }, // 2-H  F8F8F8 B8B8B8 707070 000000
	{ 0x4F5F, 0x630E, 0x159F, 0x3126 }, // 3-A  F8D098 70C0C0 F86028 304860
	{ 0x637B, 0x121C, 0x0140, 0x0840 }, // 3-B  D8D8C0 E08020 005000 001010
	{ 0x66BC, 0x3FFF, 0x7EE0, 0x2C84 }, // 3-C  E0A8C8 F8F878 00B8F8 202058
	{ 0x5FFE, 0x3EBC, 0x0321, 0x0000 }, // 3-D  F0F8B8 E0A878 08C800 000000
	{ 0x63FF, 0x36DC, 0x11F6, 0x392A }, // 3-E  F8F8C0 E0B068 B07820 504870
	{ 0x65EF, 0x7DBF, 0x035F, 0x2108 }, // 3-F  7878C8 F868F8 F8D000 404040
	{ 0x2B6C, 0x7FFF, 0x1CD9, 0x0007 }, // 3-G  60D850 F8F8F8 C83038 380000
	{ 0x53FC, 0x1F2F, 0x0E29, 0x0061 }, // 3-H  E0F8A0 78C838 488818 081800
	{ 0x36BE, 0x7EAF, 0x681A, 0x3C00 }, // 4-A  F0A868 78A8F8 D000D0 000078
	{ 0x7BBE, 0x329D, 0x1DE8, 0x0423 }, // 4-B  F0E8F0 E8A060 407838 180808
	{ 0x739F, 0x6A9B, 0x7293, 0x0001 }, // 4-C  F8E0E0 D8A0D0 98A0E0 080000
	{ 0x5FFF, 0x6732, 0x3DA9, 0x2481 }, // 4-D  F8F8B8 90C8C8 486878 082048
	{ 0x577F, 0x3EBC, 0x456F, 0x1880 }, // 4-E  F8D8A8 E0A878 785888 002030
	{ 0x6B57, 0x6E1B, 0x5010, 0x0007 }, // 4-F  B8D0D0 D880D8 8000A0 380000
	{ 0x0F96, 0x2C97, 0x0045, 0x3200 }, // 4-G  B0E018 B82058 281000 008060
	{ 0x67FF, 0x2F17, 0x2230, 0x1548 }, // 4-H  F8F8C8 B8C058 808840 405028
};

faultdef SDL_FAILED;

const int AUDIO_RATE = 48000;

struct Display {
	sdl::Window*      window;
	sdl::Renderer*    renderer;
	sdl::Texture*     texture;
	sdl::AudioStream* audio;
	char[]            pixels;
	char[12]          colors; // RGB for shades 0-3 (see palette_rgb)
}

// Key presses (not held keys) for the menu, as bits in Input.pressed.
const char KEY_MENU  = 0x01; // Esc
const char KEY_UP    = 0x02;
const char KEY_DOWN  = 0x04;
const char KEY_LEFT  = 0x08;
const char KEY_RIGHT = 0x10;
const char KEY_ENTER = 0x20;
const char KEY_OPEN  = 0x40; // Ctrl+O

struct Input {
	bool quit;     // window closed
	char buttons;  // held Game Boy buttons
	char dpad;
	char pressed;  // KEY_* pressed this poll
}

fn Display? open(ZString title, char[12] colors) {
	if (sdl::init(sdl::INIT_VIDEO | sdl::INIT_EVENTS | sdl::INIT_AUDIO) == 0) {
		io::eprintfn("SDL_Init failed: %s", sdl::get_error().str_view());
		return SDL_FAILED~;
	}

	Display d;
	d.colors = colors;
	d.window = sdl::create_window(title, ppu::WIDTH * SCALE, ppu::HEIGHT * SCALE, 0);
	d.renderer = d.window ? sdl::create_renderer(d.window, null) : null;
	if (!d.renderer) {
		io::eprintfn("SDL window/renderer failed: %s", sdl::get_error().str_view());
		sdl::quit();
		return SDL_FAILED~;
	}
	sdl::set_render_vsync(d.renderer, 0);

	d.texture = sdl::create_texture(d.renderer, sdl::PIXELFORMAT_ABGR8888,
		sdl::TEXTUREACCESS_STREAMING, ppu::WIDTH, ppu::HEIGHT);
	sdl::set_texture_scale_mode(d.texture, sdl::SCALEMODE_NEAREST);

	d.pixels = mem::new_array(char, ppu::WIDTH * ppu::HEIGHT * 4);

	sdl::AudioSpec spec = { .format = sdl::AUDIO_S16, .channels = 2, .freq = AUDIO_RATE };
	d.audio = sdl::open_audio_device_stream(sdl::AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, null, null);
	if (d.audio) {
		sdl::resume_audio_stream_device(d.audio);
	} else {
		io::eprintfn("audio unavailable: %s", sdl::get_error().str_view());
	}
	return d;
}

fn void Display.close(&self) {
	if (self.pixels.len) free(self.pixels.ptr);
	if (self.audio)    sdl::destroy_audio_stream(self.audio);
	if (self.texture)  sdl::destroy_texture(self.texture);
	if (self.renderer) sdl::destroy_renderer(self.renderer);
	if (self.window)   sdl::destroy_window(self.window);
	sdl::quit();
}

fn void Display.queue_audio(&self, short[] samples, uint n) {
	if (!self.audio || n == 0) return;
	if (sdl::get_audio_stream_queued(self.audio) > AUDIO_RATE) return; // > ~0.25s (bytes)
	sdl::put_audio_stream_data(self.audio, samples.ptr, (int)(n * 2));
}

fn void Display.set_palette(&self, char[12] colors) {
	self.colors = colors;
}

fn void Display.set_title(&self, String title) {
	sdl::set_window_title(self.window, title.zstr_tcopy());
}

// Drop queued audio, e.g. when pausing or switching ROMs.
fn void Display.clear_audio(&self) {
	if (self.audio) sdl::clear_audio_stream(self.audio);
}

// The frame, plus a menu drawn over it when `menu` has lines: a dimmed screen,
// the lines in SDL's 8x8 debug font at 2x, `selected` highlighted.
fn void Display.present(&self, char[] fb, String[] menu = {}, int selected = -1) {
	int pixels = ppu::WIDTH * ppu::HEIGHT;

	for (int i = 0; i < pixels; i++) {
		int p = (fb[i] & 3) * 3;
		self.pixels[i * 4]     = self.colors[p];
		self.pixels[i * 4 + 1] = self.colors[p + 1];
		self.pixels[i * 4 + 2] = self.colors[p + 2];
		self.pixels[i * 4 + 3] = 0xFF;
	}
	sdl::update_texture(self.texture, null, self.pixels.ptr, ppu::WIDTH * 4);
	sdl::render_clear(self.renderer);
	sdl::render_texture(self.renderer, self.texture, null, null);
	if (menu.len) self.draw_menu(menu, selected);
	sdl::render_present(self.renderer);
}

const float MENU_SCALE  = 2;   // debug font 8x8 -> 16x16 pixels
const float MENU_LEFT   = 24;  // in scaled units (8 px each at scale 1)
const float MENU_TOP    = 24;
const float MENU_LINE   = 14;

fn void Display.draw_menu(&self, String[] lines, int selected) {
	sdl::set_render_draw_blend_mode(self.renderer, sdl::BLENDMODE_BLEND);
	sdl::set_render_draw_color(self.renderer, 0x08, 0x18, 0x20, 0xD0);
	sdl::FRect all = { 0, 0, ppu::WIDTH * SCALE, ppu::HEIGHT * SCALE };
	sdl::render_fill_rect(self.renderer, &all);

	sdl::set_render_scale(self.renderer, MENU_SCALE, MENU_SCALE);
	foreach (i, line : lines) {
		bool sel = (int)i == selected;
		if (sel) {
			sdl::set_render_draw_color(self.renderer, 0xE0, 0xF8, 0xD0, 0xFF);
		} else {
			sdl::set_render_draw_color(self.renderer, 0x88, 0xC0, 0x70, 0xFF);
		}
		String text = string::tformat("%s%s", sel ? "> " : "  ", line);
		sdl::render_debug_text(self.renderer, MENU_LEFT, MENU_TOP + (float)i * MENU_LINE, text.zstr_tcopy());
	}
	sdl::set_render_scale(self.renderer, 1, 1);
	sdl::set_render_draw_color(self.renderer, 0, 0, 0, 0xFF);
}

// ---------------------------------------------------------------------------
// ROM file dialog. SDL shows the desktop's native dialog and calls back later,
// possibly on another thread: the callback only copies the path and flips an
// atomic state, and the main loop collects it with take_dialog_result().
// ---------------------------------------------------------------------------

const int DIALOG_IDLE      = 0;
const int DIALOG_OPEN      = 1;
const int DIALOG_CHOSEN    = 2;
const int DIALOG_CANCELLED = 3;

Atomic{int} dialog_state;
char[4096] dialog_path;

// Must stay valid until the callback runs, so it isn't a local.
sdl::DialogFileFilter[1] rom_filters = {
	{ "Game Boy ROMs", "gb;gbc" },
};

fn void on_dialog(void* userdata, ZString* files, int filter) {
	if (files == null || files[0] == null) {
		dialog_state.store(DIALOG_CANCELLED);
		return;
	}
	String path = files[0].str_view();
	usz n = path.len < dialog_path.len - 1 ? path.len : dialog_path.len - 1;
	for (usz i = 0; i < n; i++) dialog_path[i] = path[i];
	dialog_path[n] = 0;
	dialog_state.store(DIALOG_CHOSEN);
}

fn bool Display.dialog_open(&self) {
	return dialog_state.load() == DIALOG_OPEN;
}

fn void Display.open_rom_dialog(&self) {
	if (dialog_state.load() == DIALOG_OPEN) return;
	dialog_state.store(DIALOG_OPEN);
	sdl::show_open_file_dialog(&on_dialog, null, self.window, &rom_filters, 1, null, false);
}

// The chosen path once the dialog has closed with a file; empty otherwise.
// Returned as a temp copy.
fn String Display.take_dialog_result(&self) {
	int state = dialog_state.load();
	if (state == DIALOG_CANCELLED) dialog_state.store(DIALOG_IDLE);
	if (state != DIALOG_CHOSEN) return "";
	dialog_state.store(DIALOG_IDLE);
	return ((ZString)&dialog_path).str_view().tcopy();
}

fn Input Display.poll(&self) {
	Input in;

	sdl::Event e;
	while (sdl::poll_event(&e)) {
		if (e.type == sdl::EVENT_QUIT) in.quit = true;
		if (e.type != sdl::EVENT_KEY_DOWN) continue;
		sdl::KeyboardEvent* k = (sdl::KeyboardEvent*)&e;
		switch (k.scancode) {
			case sdl::SC_ESCAPE: if (!k.repeat) in.pressed |= KEY_MENU;
			case sdl::SC_UP:     in.pressed |= KEY_UP;
			case sdl::SC_DOWN:   in.pressed |= KEY_DOWN;
			case sdl::SC_LEFT:   in.pressed |= KEY_LEFT;
			case sdl::SC_RIGHT:  in.pressed |= KEY_RIGHT;
			case sdl::SC_RETURN: if (!k.repeat) in.pressed |= KEY_ENTER;
			case sdl::SC_O:      if (!k.repeat && (k.mod & sdl::KMOD_CTRL) != 0) in.pressed |= KEY_OPEN;
		}
	}

	int n;
	char* ks = sdl::get_keyboard_state(&n);

	if (ks[sdl::SC_RIGHT]  != 0) in.dpad    |= joypad::PAD_RIGHT;
	if (ks[sdl::SC_LEFT]   != 0) in.dpad    |= joypad::PAD_LEFT;
	if (ks[sdl::SC_UP]     != 0) in.dpad    |= joypad::PAD_UP;
	if (ks[sdl::SC_DOWN]   != 0) in.dpad    |= joypad::PAD_DOWN;
	if (ks[sdl::SC_Z]      != 0) in.buttons |= joypad::BTN_A;
	if (ks[sdl::SC_X]      != 0) in.buttons |= joypad::BTN_B;
	if (ks[sdl::SC_RSHIFT] != 0) in.buttons |= joypad::BTN_SELECT;
	if (ks[sdl::SC_RETURN] != 0) in.buttons |= joypad::BTN_START;

	return in;
}

fn int Display.audio_queued(&self) {
	if (self.audio == null) {
		return 0;
	}
	return sdl::get_audio_stream_queued(self.audio);
}

// SGB/CGB 15-bit BGR -> 8-bit R, G, B (each channel << 3, which is what the
// commonly quoted values like 1-A = F8E8C8 assume).
fn void bgr555_to_rgb(ushort c, char[] out) {
	out[0] = (char)((c & 0x1F) << 3);
	out[1] = (char)(((c >> 5) & 0x1F) << 3);
	out[2] = (char)(((c >> 10) & 0x1F) << 3);
}

// RGB for shades 0-3 of a named palette: "dmg" (the default green), or an SGB
// palette "1-A" .. "4-H" (case-insensitive). False for an unknown name.
fn bool palette_rgb(String name, char[12]* out) {
	if (name == "dmg") {
		*out = PALETTE;
		return true;
	}
	if (name.len != 3 || name[1] != '-') return false;
	char group = name[0];
	char letter = name[2] | 0x20; // ASCII lower case
	if (group < '1' || group > '4' || letter < 'a' || letter > 'h') return false;

	int index = (group - '1') * 8 + (letter - 'a');
	for (int shade = 0; shade < 4; shade++) {
		bgr555_to_rgb(SGB_PALETTES[index][shade], (*out)[shade * 3 : 3]);
	}
	return true;
}