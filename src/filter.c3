module display;
import sdl, png, std::io::file;

// Screen filters: how the picture's pixels become the window's.
//
//   Off        square pixels, nearest
//   Sharp      SDL's pixel-art scaling: crisp, but even at sizes that aren't a
//              whole multiple (full screen on a phone, a resized window)
//   Smooth     bilinear
//   LCD grid   the faint gaps between the dots of a Game Boy's screen
//   Scanlines  dark lines between rows, like a TV
//
// Grid and scanlines are thin translucent bands drawn over the picture, once
// it is at least 3 window pixels a Game Boy pixel (finer, they only darken).
enum Filter : char {
	OFF,
	SHARP,
	SMOOTH,
	LCD,
	SCANLINES,
}

const String[5] FILTER_NAMES  = { "off", "sharp", "smooth", "lcd", "scanlines" };
const String[5] FILTER_LABELS = { "Off", "Sharp", "Smooth", "LCD grid", "Scanlines" };

fn int filter_index(String name) {
	foreach (i, n : FILTER_NAMES) {
		if (n == name) return (int)i;
	}
	return -1;
}

fn int Filter.scale_mode(self) {
	switch (self) {
		case SHARP:  return sdl::SCALEMODE_PIXELART;
		case SMOOTH: return sdl::SCALEMODE_LINEAR;
		default:     return sdl::SCALEMODE_NEAREST;
	}
}

fn void Display.set_filter(&self, Filter f) {
	self.filter = f;
	if (self.texture) sdl::set_texture_scale_mode(self.texture, f.scale_mode());
}

// The grid or the scanlines over the picture at `r`, `w` x `h` pixels.
fn void Display.draw_filter(&self, sdl::FRect r, int w, int h) {
	if (self.filter != LCD && self.filter != SCANLINES) return;
	float px = r.w / (float)w;
	float py = r.h / (float)h;
	if (px < 3 || py < 3) return;
	sdl::FRect[MAX_W + MAX_H] bands;
	int n;
	sdl::set_render_draw_blend_mode(self.renderer, sdl::BLENDMODE_BLEND);
	if (self.filter == LCD) {
		// A band a quarter of a pixel wide (at least one window pixel) at
		// every pixel's left and top edge.
		float tx = px / 4 < 1 ? 1 : (float)(int)(px / 4);
		float ty = py / 4 < 1 ? 1 : (float)(int)(py / 4);
		for (int x = 1; x < w; x++) bands[n++] = { r.x + (float)(int)((float)x * px), r.y, tx, r.h };
		for (int y = 1; y < h; y++) bands[n++] = { r.x, r.y + (float)(int)((float)y * py), r.w, ty };
		sdl::set_render_draw_color(self.renderer, 0, 0, 0, 0x38);
	} else {
		// The lower third of every row.
		float t = py / 3 < 1 ? 1 : (float)(int)(py / 3);
		for (int y = 0; y < h; y++) bands[n++] = { r.x, r.y + (float)(int)((float)(y + 1) * py) - t, r.w, t };
		sdl::set_render_draw_color(self.renderer, 0, 0, 0, 0x60);
	}
	sdl::render_fill_rects(self.renderer, &bands, n);
	sdl::set_render_draw_color(self.renderer, 0, 0, 0, 0xFF);
}

// The picture area of what is being drawn, as a PNG at shot_path.
fn void Display.save_shot(&self, sdl::FRect r) {
	self.shot_ok = false;
	sdl::Rect area = { (int)r.x, (int)r.y, (int)r.w, (int)r.h };
	sdl::Surface* s = sdl::render_read_pixels(self.renderer, &area);
	if (!s) return;
	defer sdl::destroy_surface(s);
	sdl::Surface* c = sdl::convert_surface(s, sdl::PIXELFORMAT_RGB24);
	if (!c) return;
	defer sdl::destroy_surface(c);
	char[] px = mem::temp_array(char, (usz)(c.w * c.h * 3));
	for (int y = 0; y < c.h; y++) {
		px[(usz)(y * c.w * 3) : (usz)(c.w * 3)] = ((char*)c.pixels)[(usz)(y * c.pitch) : (usz)(c.w * 3)];
	}
	self.shot_ok = !@catch(file::save(self.shot_path, png::rgb(px, c.w, c.h, tmem)));
}
