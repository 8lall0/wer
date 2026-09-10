module display;

import sdl, ppu, joypad;
import std::io;

const int SCALE = 4;

const char[12] PALETTE = {
	0xE0, 0xF8, 0xD0,
	0x88, 0xC0, 0x70,
	0x34, 0x68, 0x56,
	0x08, 0x18, 0x20,
};

faultdef SDL_FAILED;

const int AUDIO_RATE = 48000;

struct Display {
	sdl::Window*      window;
	sdl::Renderer*    renderer;
	sdl::Texture*     texture;
	sdl::AudioStream* audio;
	char[]            pixels;
}

struct Input {
	bool quit;
	char buttons;
	char dpad;
}

fn Display? open(ZString title) {
	if (sdl::init(sdl::INIT_VIDEO | sdl::INIT_EVENTS | sdl::INIT_AUDIO) == 0) {
		io::eprintfn("SDL_Init failed: %s", sdl::get_error().str_view());
		return SDL_FAILED~;
	}

	Display d;
	d.window = sdl::create_window(title, ppu::WIDTH * SCALE, ppu::HEIGHT * SCALE, 0);
	d.renderer = d.window ? sdl::create_renderer(d.window, null) : null;
	if (!d.renderer) {
		io::eprintfn("SDL window/renderer failed: %s", sdl::get_error().str_view());
		sdl::quit();
		return SDL_FAILED~;
	}
	sdl::set_render_vsync(d.renderer, 1);

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

fn void Display.present(&self, char[] fb) {
	int pixels = ppu::WIDTH * ppu::HEIGHT;
	for (int i = 0; i < pixels; i++) {
		int p = (fb[i] & 3) * 3;
		self.pixels[i * 4]     = PALETTE[p];
		self.pixels[i * 4 + 1] = PALETTE[p + 1];
		self.pixels[i * 4 + 2] = PALETTE[p + 2];
		self.pixels[i * 4 + 3] = 0xFF;
	}
	sdl::update_texture(self.texture, null, self.pixels.ptr, ppu::WIDTH * 4);
	sdl::render_clear(self.renderer);
	sdl::render_texture(self.renderer, self.texture, null, null);
	sdl::render_present(self.renderer);
}

fn Input Display.poll(&self) {
	Input in;

	sdl::Event e;
	while (sdl::poll_event(&e)) {
		if (e.type == sdl::EVENT_QUIT) in.quit = true;
	}

	int n;
	char* ks = sdl::get_keyboard_state(&n);
	if (ks[sdl::SC_ESCAPE] != 0) in.quit = true;

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
