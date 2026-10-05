module display;

import sdl, ppu, joypad, sgb, config, icon;
import std::io, std::atomic;

// The window shows the picture enlarged by a whole factor (sharp square
// pixels): --scale=N or the menu, same factor with or without SGB border.
const int MIN_SCALE = 1;
const int MAX_SCALE = 4;
const int DEFAULT_SCALE = 3;

// Largest picture the display is ever handed (the SGB screen).
const int MAX_W = sgb::BORDER_W;
const int MAX_H = sgb::BORDER_H;

const char[12] PALETTE = {
	0xE0, 0xF8, 0xD0,
	0x88, 0xC0, 0x70,
	0x34, 0x68, 0x56,
	0x08, 0x18, 0x20,
};

// The Game Boy Pocket's grey screen.
const char[12] PALETTE_MGB = {
	0xE4, 0xE4, 0xDC,
	0xA4, 0xA4, 0x9C,
	0x5C, 0x5C, 0x54,
	0x14, 0x14, 0x10,
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
	char[]            pixels;   // RGBA staging, sized for MAX_W x MAX_H
	int               width;    // current picture size
	int               height;
	int               scale;    // window pixels per picture pixel

	Bindings          bindings;
	sdl::Gamepad*[MAX_PADS] pads; // open gamepads (any of them plays)
	int               stick_dir; // menu navigation by stick: last KEY_* direction held

	// Frame blending (blend.c3): the last raw frame, and the frame parity.
	Blend             blend;
	char[]            prev;      // RGB, sized for MAX_W x MAX_H
	char[]            mixed;     // the blended frame, the same size
	int               prev_w;
	int               prev_h;
	bool              odd_frame;  // set by the caller for each frame
	bool              blend_simple; // SGB: Accurate blends like Simple

	// Touch screens (Android): on-screen controls (touch.c3).
	bool              touch_ui;
	Finger[MAX_FINGERS] fingers;
	ushort            touch_held; // T_* held at the last poll
	ushort            touch_tap;  // T_* touched since the last poll (a tap may end before it)
}

// Gamepads used at once; all of them control the game.
const int MAX_PADS = 4;

// Left stick deflection that counts as a d-pad press (of 32767).
const short STICK_DEADZONE = 16000;

// What each Game Boy button (config::Button order) is bound to: an SDL
// scancode and an SDL gamepad button.
struct Bindings {
	int[8] keys;
	int[8] pads;
}

// Key presses (not held keys) for the menu and hotkeys, as bits in
// Input.pressed.
const ushort KEY_MENU    = 0x01; // Esc
const ushort KEY_UP      = 0x02;
const ushort KEY_DOWN    = 0x04;
const ushort KEY_LEFT    = 0x08;
const ushort KEY_RIGHT   = 0x10;
const ushort KEY_ENTER   = 0x20;
const ushort KEY_OPEN    = 0x40; // Ctrl+O
const ushort KEY_PAUSE   = 0x80; // P
const ushort KEY_ADVANCE = 0x100; // N: one frame while paused

struct Input {
	bool quit;     // window closed
	char buttons;  // held Game Boy buttons
	char dpad;
	ushort pressed; // KEY_* pressed this poll
	bool fast;     // Tab held: fast forward
	// F1-F9 pressed this poll: the save state slot (0 = none), to save with
	// Shift held, else to load.
	int  state_slot;
	bool state_save;
	// The first key / gamepad button pressed this poll (-1 = none), for
	// binding a control in the menu.
	int  key;
	int  pad_button;
}

// The config's key and gamepad button names as SDL codes. An unknown name
// keeps the default binding, with a warning.
fn Bindings bindings_from(config::Config* c) {
	Bindings b;
	for (int i = 0; i < 8; i++) {
		b.keys[i] = sdl::get_scancode_from_name(c.keys[i].zstr_tcopy());
		if (b.keys[i] == 0) {
			io::eprintfn("unknown key '%s' for %s, using %s", c.keys[i], config::BUTTON_NAMES[i], config::DEFAULT_KEYS[i]);
			b.keys[i] = sdl::get_scancode_from_name(config::DEFAULT_KEYS[i].zstr_tcopy());
		}
		b.pads[i] = sdl::get_gamepad_button_from_string(c.pads[i].zstr_tcopy());
		if (b.pads[i] == sdl::GAMEPAD_BUTTON_INVALID) {
			io::eprintfn("unknown gamepad button '%s' for %s, using %s", c.pads[i], config::BUTTON_NAMES[i], config::DEFAULT_PADS[i]);
			b.pads[i] = sdl::get_gamepad_button_from_string(config::DEFAULT_PADS[i].zstr_tcopy());
		}
	}
	return b;
}

// Esc cancels binding a control instead of becoming the binding.
fn bool is_escape(int scancode) => scancode == sdl::SC_ESCAPE;

// Names to store in the config (and show in the menu).
// A file through SDL: also an Android content:// URI from the file picker.
fn char[]? load_file_temp(String path) {
	usz n;
	char* p = sdl::load_file(path.zstr_tcopy(), &n);
	if (!p) return io::FILE_NOT_FOUND~;
	char[] data = mem::temp_array(char, (sz)n);
	data[..] = p[:n];
	sdl::free(p);
	return data;
}

// SDL's folder for this app's own files (ends in '/'), or "".
fn String pref_path() {
	ZString p = sdl::get_pref_path("8lall0", "wer");
	if (!p) return "";
	String s = p.str_view().copy(mem);
	sdl::free(p);
	return s;
}

fn String key_name(int scancode) => sdl::get_scancode_name(scancode).str_view();
fn String pad_button_name(int button) {
	ZString n = sdl::get_gamepad_string_for_button(button);
	return n ? n.str_view() : "?";
}

// joypad bits for each config::Button: buttons first, then the d-pad.
const char[8] JOYPAD_BIT = {
	joypad::BTN_A, joypad::BTN_B, joypad::BTN_SELECT, joypad::BTN_START,
	joypad::PAD_UP, joypad::PAD_DOWN, joypad::PAD_LEFT, joypad::PAD_RIGHT,
};

fn Display? open(ZString title, int scale = DEFAULT_SCALE) {
	// Android's Back comes as a key (it opens the menu) instead of leaving;
	// the phone may be held either way (touch.c3 lays out both).
	sdl::set_hint("SDL_ANDROID_TRAP_BACK_BUTTON", "1");
	sdl::set_hint("SDL_ORIENTATIONS", "LandscapeLeft LandscapeRight Portrait");
	if (sdl::init(sdl::INIT_VIDEO | sdl::INIT_EVENTS | sdl::INIT_AUDIO | sdl::INIT_GAMEPAD) == 0) {
		io::eprintfn("SDL_Init failed: %s", sdl::get_error().str_view());
		return SDL_FAILED~;
	}

	Display d;
	d.scale = scale;
	d.touch_ui = env::ANDROID;
	// Android: resizable lets SDL follow the phone's rotation.
	d.window = sdl::create_window(title, ppu::WIDTH * scale, ppu::HEIGHT * scale, env::ANDROID ? sdl::WINDOW_RESIZABLE : 0);
	d.renderer = d.window ? sdl::create_renderer(d.window, null) : null;
	if (!d.renderer) {
		io::eprintfn("SDL window/renderer failed: %s", sdl::get_error().str_view());
		sdl::quit();
		return SDL_FAILED~;
	}
	sdl::set_render_vsync(d.renderer, 0);
	sdl::add_event_watch(&on_app_event, null);
	// Android: the whole screen, without the status and navigation bars.
	if (env::ANDROID) sdl::set_window_fullscreen(d.window, true);
	// A browser on a phone or tablet: the touch layout over the whole page.
	$if env::EMSCRIPTEN:
		if (web_touch_screen()) d.web_touch_mode();
	$endif
	// On Windows SDL's window class already has wer.exe's own icon, every
	// size (resources/windows/wer.ico); one set here would replace it.
	$if !env::WIN32:
		set_icon(d.window);
	$endif

	d.resize(ppu::WIDTH, ppu::HEIGHT);

	d.pixels = mem::new_array(char, MAX_W * MAX_H * 4);
	d.prev = mem::new_array(char, MAX_W * MAX_H * 3);
	d.mixed = mem::new_array(char, MAX_W * MAX_H * 3);

	sdl::AudioSpec spec = { .format = sdl::AUDIO_S16, .channels = 2, .freq = AUDIO_RATE };
	d.audio = sdl::open_audio_device_stream(sdl::AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, null, null);
	if (d.audio) {
		sdl::resume_audio_stream_device(d.audio);
	} else {
		io::eprintfn("audio unavailable: %s", sdl::get_error().str_view());
	}
	return d;
}

// Called when the app goes to the background (Android, which may end it
// there without another word): the main loop's chance to write saves.
alias BackgroundHook = fn void(void* ctx);
BackgroundHook background_hook;
void* background_ctx;

// SDL calls watches as it queues an event: on Android the app blocks right
// after the background event is queued, so the hook runs here (on the
// thread that polls, so the emulator is between frames).
fn bool on_app_event(void* userdata, sdl::Event* e) {
	switch (e.type) {
		case sdl::EVENT_WILL_ENTER_BACKGROUND:
		case sdl::EVENT_TERMINATING:
			if (background_hook) background_hook(background_ctx);
	}
	return true;
}

// The window's icon: the 32x32 pixel art at 4x, so a desktop that shows it
// larger doesn't blur it. SDL copies the pixels.
const int ICON_SCALE = 4;

fn void set_icon(sdl::Window* window) {
	int w = icon::SIZE * ICON_SCALE;
	char[] pixels = mem::new_array(char, (usz)(w * w * 4));
	defer free(pixels.ptr);
	icon::rgba(pixels, ICON_SCALE);
	sdl::Surface* s = sdl::create_surface_from(w, w, sdl::PIXELFORMAT_ABGR8888, pixels.ptr, w * 4);
	if (!s) return;
	sdl::set_window_icon(window, s);
	sdl::destroy_surface(s);
}

fn void Display.close(&self) {
	foreach (p : self.pads) if (p) sdl::close_gamepad(p);
	if (self.pixels.len) free(self.pixels.ptr);
	if (self.prev.len) free(self.prev.ptr);
	if (self.mixed.len) free(self.mixed.ptr);
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

fn void Display.set_title(&self, String title) {
	sdl::set_window_title(self.window, title.zstr_tcopy());
}

// Drop queued audio, e.g. when pausing or switching ROMs.
fn void Display.clear_audio(&self) {
	if (self.audio) sdl::clear_audio_stream(self.audio);
}

// The frame (RGB, 3 bytes per pixel, from GameBoy.frame_rgb), plus a menu drawn
// over it when `menu` has lines: a dimmed screen, the lines in SDL's 8x8 debug
// font at 2x, `selected` highlighted.
// A new picture size (the SGB border appearing or going away): a matching
// texture, and a window scaled to fit it.
fn void Display.resize(&self, int w, int h) {
	if (self.texture) sdl::destroy_texture(self.texture);
	self.texture = sdl::create_texture(self.renderer, sdl::PIXELFORMAT_ABGR8888,
		sdl::TEXTUREACCESS_STREAMING, w, h);
	sdl::set_texture_scale_mode(self.texture, sdl::SCALEMODE_NEAREST);
	if (!env::ANDROID) sdl::set_window_size(self.window, w * self.scale, h * self.scale);
	self.width = w;
	self.height = h;
}

fn void Display.set_scale(&self, int scale) {
	self.scale = scale;
	if (!env::ANDROID) sdl::set_window_size(self.window, self.width * scale, self.height * scale);
}

fn void Display.present(&self, char[] rgb, int w, int h, String[] menu = {}, int selected = -1, String message = "") {
	if (w != self.width || h != self.height) self.resize(w, h);
	int pixels = w * h;
	rgb = self.blended(rgb, w, h);

	for (int i = 0; i < pixels; i++) {
		self.pixels[i * 4]     = rgb[i * 3];
		self.pixels[i * 4 + 1] = rgb[i * 3 + 1];
		self.pixels[i * 4 + 2] = rgb[i * 3 + 2];
		self.pixels[i * 4 + 3] = 0xFF;
	}
	sdl::update_texture(self.texture, null, self.pixels.ptr, w * 4);
	sdl::render_clear(self.renderer);
	Layout l = self.layout();
	sdl::render_texture(self.renderer, self.texture, null, &l.screen);
	if (self.touch_ui) self.draw_touch(&l);
	if (menu.len) self.draw_menu(menu, selected, l.screen);
	if (message.len && !menu.len) self.draw_message(message, l.screen);
	sdl::render_present(self.renderer);
}

// A one-line notice ("Saved state 1", "Paused") in the bottom left corner,
// on a dark strip.
fn void Display.draw_message(&self, String text, sdl::FRect area) {
	float font = ui_font(area);
	float pad = 4 * font;
	float h = 8 * font + pad * 2;
	float y = area.y + area.h - h;
	sdl::set_render_draw_blend_mode(self.renderer, sdl::BLENDMODE_BLEND);
	sdl::set_render_draw_color(self.renderer, 0x08, 0x18, 0x20, 0xC0);
	sdl::FRect strip = { area.x, y, (float)text.len * 8 * font + pad * 2, h };
	sdl::render_fill_rect(self.renderer, &strip);
	sdl::set_render_scale(self.renderer, font, font);
	sdl::set_render_draw_color(self.renderer, 0xE0, 0xF8, 0xD0, 0xFF);
	sdl::render_debug_text(self.renderer, (area.x + pad) / font, (y + pad) / font, text.zstr_tcopy());
	sdl::set_render_scale(self.renderer, 1, 1);
	sdl::set_render_draw_color(self.renderer, 0, 0, 0, 0xFF);
}

// The 8x8 font's size for text over `area` (the picture): 2x from 3x
// picture scale up, more on a phone.
fn float ui_font(sdl::FRect area) {
	float f = (float)(int)(area.h / 216);
	return f < 1 ? 1 : f;
}

// Menu layout in window pixels per unit of window scale (so at 4x: 48 px in,
// 28 px per line); the 8x8 font is drawn 2x from window scale 3 up.
const int MENU_MARGIN = 12;
const int MENU_LINE   = 7;

fn void Display.draw_menu(&self, String[] lines, int selected, sdl::FRect area) {
	sdl::set_render_draw_blend_mode(self.renderer, sdl::BLENDMODE_BLEND);
	sdl::set_render_draw_color(self.renderer, 0x08, 0x18, 0x20, 0xD0);
	sdl::render_fill_rect(self.renderer, &area);

	float font = ui_font(area);
	float scale = area.h / (float)self.height; // picture pixels to output pixels
	float margin = MENU_MARGIN * scale / font;
	float line_h = MENU_LINE * scale / font;
	if (line_h < 10) line_h = 10;           // never closer than the 8 px font
	sdl::set_render_scale(self.renderer, font, font);
	foreach (i, line : lines) {
		bool sel = (int)i == selected;
		if (sel) {
			sdl::set_render_draw_color(self.renderer, 0xE0, 0xF8, 0xD0, 0xFF);
		} else {
			sdl::set_render_draw_color(self.renderer, 0x88, 0xC0, 0x70, 0xFF);
		}
		String text = string::tformat("%s%s", sel ? "> " : "  ", line);
		sdl::render_debug_text(self.renderer, area.x / font + margin, area.y / font + margin + (float)i * line_h, text.zstr_tcopy());
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
	$if env::EMSCRIPTEN:
		web_pick_rom(); // the page's file input (display_web.c3)
	$else
		// Android's picker filters by MIME type, and .gb/.gbc files have
		// none: show every file there.
		sdl::show_open_file_dialog(&on_dialog, null, self.window, &rom_filters, env::ANDROID ? 0 : 1, null, false);
	$endif
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
	Input in = { .key = -1, .pad_button = -1 };

	sdl::Event e;
	while (sdl::poll_event(&e)) {
		switch (e.type) {
			case sdl::EVENT_QUIT:
				in.quit = true;
			case sdl::EVENT_KEY_DOWN:
				sdl::KeyboardEvent* k = (sdl::KeyboardEvent*)&e;
				if (!k.repeat && in.key < 0) in.key = (int)k.scancode;
				// Hotkeys give way to a Game Boy button bound to the same key.
				if (!k.repeat && !self.is_bound((int)k.scancode)) {
					switch (k.scancode) {
						case sdl::SC_P: in.pressed |= KEY_PAUSE;
						case sdl::SC_N: in.pressed |= KEY_ADVANCE;
						case sdl::SC_F1..sdl::SC_F9:
							in.state_slot = (int)k.scancode - sdl::SC_F1 + 1;
							in.state_save = (k.mod & sdl::KMOD_SHIFT) != 0;
					}
				}
				switch (k.scancode) {
					case sdl::SC_ESCAPE:
					case sdl::SC_AC_BACK: if (!k.repeat) in.pressed |= KEY_MENU;
					case sdl::SC_UP:     in.pressed |= KEY_UP;
					case sdl::SC_DOWN:   in.pressed |= KEY_DOWN;
					case sdl::SC_LEFT:   in.pressed |= KEY_LEFT;
					case sdl::SC_RIGHT:  in.pressed |= KEY_RIGHT;
					case sdl::SC_RETURN: if (!k.repeat) in.pressed |= KEY_ENTER;
					case sdl::SC_O:      if (!k.repeat && (k.mod & sdl::KMOD_CTRL) != 0) in.pressed |= KEY_OPEN;
				}
			case sdl::EVENT_FINGER_DOWN:
			case sdl::EVENT_FINGER_UP:
			case sdl::EVENT_FINGER_MOTION:
			case sdl::EVENT_FINGER_CANCELED:
				// A browser on a touch screen it didn't report: from now on.
				$if env::EMSCRIPTEN:
					if (!self.touch_ui && e.type == sdl::EVENT_FINGER_DOWN) self.web_touch_mode();
				$endif
				if (self.touch_ui) self.finger_event((sdl::TouchFingerEvent*)&e);
			case sdl::EVENT_GAMEPAD_ADDED:
				self.add_pad(((sdl::GamepadDeviceEvent*)&e).which);
			case sdl::EVENT_GAMEPAD_REMOVED:
				self.remove_pad(((sdl::GamepadDeviceEvent*)&e).which);
			case sdl::EVENT_GAMEPAD_BUTTON_DOWN:
				int button = ((sdl::GamepadButtonEvent*)&e).button;
				if (in.pad_button < 0) in.pad_button = button;
				in.pressed |= self.pad_menu_key(button);
		}
	}

	// The menu also follows the left stick: one step per push.
	int dir = self.stick_direction();
	if (dir != 0 && dir != self.stick_dir) in.pressed |= (ushort)dir;
	self.stick_dir = dir;

	int n;
	char* ks = sdl::get_keyboard_state(&n);
	in.fast = !self.is_bound(sdl::SC_TAB) && sdl::SC_TAB < n && ks[sdl::SC_TAB] != 0;
	for (int i = 0; i < 8; i++) {
		bool held = self.bindings.keys[i] < n && ks[self.bindings.keys[i]] != 0;
		foreach (p : self.pads) {
			if (p && sdl::get_gamepad_button(p, self.bindings.pads[i])) held = true;
		}
		if (!held) continue;
		if (i < (int)config::Button.UP.ordinal) {
			in.buttons |= JOYPAD_BIT[i];
		} else {
			in.dpad |= JOYPAD_BIT[i];
		}
	}
	if (self.touch_ui) self.touch_input(&in);
	switch (dir) {
		case KEY_UP:    in.dpad |= joypad::PAD_UP;
		case KEY_DOWN:  in.dpad |= joypad::PAD_DOWN;
		case KEY_LEFT:  in.dpad |= joypad::PAD_LEFT;
		case KEY_RIGHT: in.dpad |= joypad::PAD_RIGHT;
	}

	return in;
}

fn bool Display.is_bound(&self, int scancode) {
	foreach (k : self.bindings.keys) if (k == scancode) return true;
	return false;
}

// A newly connected gamepad (SDL also reports the ones present at start).
fn void Display.add_pad(&self, uint id) {
	foreach (&p : self.pads) {
		if (*p) continue;
		*p = sdl::open_gamepad(id);
		if (*p) io::printfn("gamepad connected: %s", sdl::get_gamepad_name(*p).str_view());
		return;
	}
}

fn void Display.remove_pad(&self, uint id) {
	foreach (&p : self.pads) {
		if (!*p || sdl::get_gamepad_id(*p) != id) continue;
		sdl::close_gamepad(*p);
		*p = null;
	}
}

// Menu keys on a gamepad: the d-pad moves, the bottom face button or Start
// confirms, Guide (or Back + Start, for pads whose Guide the system takes)
// opens and closes the menu.
fn ushort Display.pad_menu_key(&self, int button) {
	switch (button) {
		case sdl::GAMEPAD_BUTTON_DPAD_UP:    return KEY_UP;
		case sdl::GAMEPAD_BUTTON_DPAD_DOWN:  return KEY_DOWN;
		case sdl::GAMEPAD_BUTTON_DPAD_LEFT:  return KEY_LEFT;
		case sdl::GAMEPAD_BUTTON_DPAD_RIGHT: return KEY_RIGHT;
		case sdl::GAMEPAD_BUTTON_SOUTH:      return KEY_ENTER;
		case sdl::GAMEPAD_BUTTON_GUIDE:      return KEY_MENU;
		case sdl::GAMEPAD_BUTTON_START:
			foreach (p : self.pads) {
				if (p && sdl::get_gamepad_button(p, sdl::GAMEPAD_BUTTON_BACK)) return KEY_MENU;
			}
			return KEY_ENTER;
		default:
			return 0;
	}
}

// Where the left stick of any gamepad points, as KEY_UP/DOWN/LEFT/RIGHT, or 0.
fn int Display.stick_direction(&self) {
	foreach (p : self.pads) {
		if (!p) continue;
		short x = sdl::get_gamepad_axis(p, sdl::GAMEPAD_AXIS_LEFTX);
		short y = sdl::get_gamepad_axis(p, sdl::GAMEPAD_AXIS_LEFTY);
		int ax = x < 0 ? -(int)x : x;
		int ay = y < 0 ? -(int)y : y;
		if (ax < STICK_DEADZONE && ay < STICK_DEADZONE) continue;
		if (ax > ay) return x < 0 ? KEY_LEFT : KEY_RIGHT;
		return y < 0 ? KEY_UP : KEY_DOWN;
	}
	return 0;
}

fn int Display.audio_queued(&self) {
	if (self.audio == null) {
		return 0;
	}
	return sdl::get_audio_stream_queued(self.audio);
}

// RGB for shades 0-3 of a named palette: "dmg" (the default green), "mgb"
// (the Pocket's grey), or an SGB
// palette "1-A" .. "4-H" (case-insensitive). False for an unknown name.
fn bool palette_rgb(String name, char[12]* out) {
	if (name == "dmg") {
		*out = PALETTE;
		return true;
	}
	if (name == "mgb") {
		*out = PALETTE_MGB;
		return true;
	}
	if (name.len != 3 || name[1] != '-') return false;
	char group = name[0];
	char letter = name[2] | 0x20; // ASCII lower case
	if (group < '1' || group > '4' || letter < 'a' || letter > 'h') return false;

	int index = (group - '1') * 8 + (letter - 'a');
	for (int shade = 0; shade < 4; shade++) {
		sgb::bgr555_to_rgb(SGB_PALETTES[index][shade], (*out)[shade * 3 : 3]);
	}
	return true;
}