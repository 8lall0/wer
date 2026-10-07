module record;

import std::io, std::io::file, std::math;

// Recording a game: the picture as an animated GIF, the sound as a WAV.
//
// GIF frames carry only the rectangle that changed since the last one, with
// their own colour table (up to 256 colours; a picture with more falls back
// to 3-3-2 RGB). GIF delays count hundredths of a second and players stretch
// anything under 2 to 10, so a picture that lasted less than 2/100 s gives
// way to the next one (a game changing its picture every frame plays at 50
// frames a second, on time). The WAV is 16-bit stereo, written as it comes.

struct Recorder {
	bool on;
	String gif_path;
	String wav_path;
	File gif;
	File wav;
	uint wav_bytes;
	uint rate;
	int w;
	int h;
	char[] canvas;      // what the GIF shows after the frames written
	char[] pending;     // the latest picture, not written yet
	bool has_pending;
	long pending_cs;    // when it started showing (hundredths of a second)
	double frame_cs;    // one frame of the game
	ulong frames;
	Lzw lzw;
}

faultdef CANT_WRITE;

// Starts writing `base`.gif and `base`.wav.
fn void? Recorder.start(&self, String base, int w, int h, double frame_seconds, uint rate) {
	self.stop();
	self.gif_path = string::format(mem, "%s.gif", base);
	self.wav_path = string::format(mem, "%s.wav", base);
	File? g = file::open(self.gif_path, "wb");
	if (catch g) {
		self.free_paths();
		return CANT_WRITE~;
	}
	File? a = file::open(self.wav_path, "wb");
	if (catch a) {
		(void)g.close();
		self.free_paths();
		return CANT_WRITE~;
	}
	self.gif = g;
	self.wav = a;
	self.w = w;
	self.h = h;
	self.rate = rate;
	self.frame_cs = frame_seconds * 100;
	self.frames = 0;
	self.has_pending = false;
	self.pending_cs = 0;
	self.wav_bytes = 0;
	self.canvas = mem::new_array(char, (sz)(w * h * 3));
	self.pending = mem::new_array(char, (sz)(w * h * 3));
	self.on = true;

	// GIF: the screen, no global colours, looping forever.
	DString d;
	d.tinit();
	d.append("GIF89a");
	put16(&d, w);
	put16(&d, h);
	d.append_char(0);
	d.append_char(0);
	d.append_char(0);
	d.append_char(0x21);
	d.append_char(0xFF);
	d.append_char(11);
	d.append("NETSCAPE2.0");
	d.append_char(3);
	d.append_char(1);
	put16(&d, 0);
	d.append_char(0);
	(void)self.gif.write(d.str_view());

	self.write_wav_header();
}

fn void Recorder.free_paths(&self) {
	if (self.gif_path.len) free(self.gif_path.ptr);
	if (self.wav_path.len) free(self.wav_path.ptr);
	self.gif_path = "";
	self.wav_path = "";
}

fn void put16(DString* d, int v) {
	d.append_char((char)v);
	d.append_char((char)(v >> 8));
}

fn void put32(DString* d, uint v) {
	for (int i = 0; i < 4; i++) d.append_char((char)(v >> (8 * i)));
}

fn void Recorder.write_wav_header(&self) {
	DString d;
	d.tinit();
	d.append("RIFF");
	put32(&d, 36 + self.wav_bytes);
	d.append("WAVEfmt ");
	put32(&d, 16);
	put16(&d, 1);                  // PCM
	put16(&d, 2);                  // stereo
	put32(&d, self.rate);
	put32(&d, self.rate * 4);      // bytes a second
	put16(&d, 4);                  // bytes a sample (both channels)
	put16(&d, 16);
	d.append("data");
	put32(&d, self.wav_bytes);
	(void)self.wav.write(d.str_view());
}

// Sound: interleaved stereo samples.
fn void Recorder.audio(&self, short[] samples) {
	if (!self.on || !samples.len) return;
	char[] bytes = mem::temp_array(char, (sz)samples.len * 2);
	foreach (i, s : samples) {
		bytes[i * 2] = (char)s;
		bytes[i * 2 + 1] = (char)(s >> 8);
	}
	(void)self.wav.write(bytes);
	self.wav_bytes += (uint)bytes.len;
}

// A frame of the game (RGB, 3 bytes a pixel). False when the picture changed
// size (a Super Game Boy border, the link cable's views): the recording ends.
fn bool Recorder.frame(&self, char[] rgb, int w, int h) {
	if (!self.on) return true;
	if (w != self.w || h != self.h) {
		self.stop();
		return false;
	}
	usz n = (usz)(w * h * 3);
	long now = (long)math::round(self.frames * self.frame_cs);
	self.frames++;
	if (!self.has_pending) {
		self.pending[..] = rgb[:n];
		self.has_pending = true;
		self.pending_cs = now;
		return true;
	}
	if (self.pending[..] == rgb[:n]) return true;
	long shown = now - self.pending_cs;
	if (shown >= 2) {
		self.write_pending((int)shown);
		self.pending_cs = now;
	}
	self.pending[..] = rgb[:n];
	return true;
}

fn void Recorder.stop(&self) {
	if (!self.on) return;
	if (self.has_pending) {
		long end = (long)math::round(self.frames * self.frame_cs);
		long shown = end - self.pending_cs;
		self.write_pending(shown < 2 ? 2 : (int)shown);
	}
	char[1] trailer = { 0x3B };
	(void)self.gif.write(&trailer);
	(void)self.gif.close();
	(void)self.wav.seek(0);
	self.write_wav_header();
	(void)self.wav.close();
	free(self.canvas);
	free(self.pending);
	self.canvas = {};
	self.pending = {};
	self.on = false;
	// The paths stay for the caller's message.
}

// Writes the pending picture, shown for `delay` hundredths of a second: the
// rectangle that differs from the canvas (one unchanged pixel if none does).
fn void Recorder.write_pending(&self, int delay) {
	int x0 = self.w;
	int y0 = self.h;
	int x1 = -1;
	int y1 = -1;
	for (int y = 0; y < self.h; y++) {
		usz row = (usz)(y * self.w * 3);
		if (self.canvas[row : (usz)(self.w * 3)] == self.pending[row : (usz)(self.w * 3)]) continue;
		for (int x = 0; x < self.w; x++) {
			usz i = row + (usz)(x * 3);
			if (self.canvas[i] == self.pending[i] && self.canvas[i + 1] == self.pending[i + 1] && self.canvas[i + 2] == self.pending[i + 2]) continue;
			if (x < x0) x0 = x;
			if (x > x1) x1 = x;
			if (y < y0) y0 = y;
			if (y > y1) y1 = y;
		}
	}
	if (x1 < 0) {
		x0 = y0 = x1 = y1 = 0;
	}
	int rw = x1 - x0 + 1;
	int rh = y1 - y0 + 1;

	// The rectangle's colours.
	Palette pal;
	char[] idx = mem::temp_array(char, (sz)(rw * rh));
	bool fits = true;
	for (int y = 0; y < rh && fits; y++) {
		for (int x = 0; x < rw; x++) {
			usz i = (usz)(((y0 + y) * self.w + x0 + x) * 3);
			int c = pal.index_of(self.pending[i], self.pending[i + 1], self.pending[i + 2]);
			if (c < 0) {
				fits = false;
				break;
			}
			idx[y * rw + x] = (char)c;
		}
	}
	if (!fits) {
		pal.rgb332();
		for (int y = 0; y < rh; y++) {
			for (int x = 0; x < rw; x++) {
				usz i = (usz)(((y0 + y) * self.w + x0 + x) * 3);
				idx[y * rw + x] = (char)((self.pending[i] & 0xE0) | (self.pending[i + 1] & 0xE0) >> 3 | self.pending[i + 2] >> 6);
			}
		}
	}
	int bits = 1;
	while ((1 << bits) < pal.count) bits++;

	DString d;
	d.tinit();
	// Graphic control: leave the frame in place, the delay.
	d.append_char(0x21);
	d.append_char(0xF9);
	d.append_char(4);
	d.append_char(0x04);
	put16(&d, delay);
	d.append_char(0);
	d.append_char(0);
	// The image and its colours.
	d.append_char(0x2C);
	put16(&d, x0);
	put16(&d, y0);
	put16(&d, rw);
	put16(&d, rh);
	d.append_char((char)(0x80 | (bits - 1)));
	for (int c = 0; c < 1 << bits; c++) {
		if (c < pal.count) {
			d.append_char(pal.r[c]);
			d.append_char(pal.g[c]);
			d.append_char(pal.b[c]);
		} else {
			d.append("\0\0\0");
		}
	}
	int min_code = bits < 2 ? 2 : bits;
	d.append_char((char)min_code);
	self.lzw.encode(idx, min_code, &d);
	(void)self.gif.write(d.str_view());

	for (int y = y0; y <= y1; y++) {
		usz at = (usz)((y * self.w + x0) * 3);
		self.canvas[at : (usz)(rw * 3)] = self.pending[at : (usz)(rw * 3)];
	}
}

// --- colours -------------------------------------------------------------------

struct Palette {
	int count;
	char[256] r;
	char[256] g;
	char[256] b;
	uint[1024] slots;   // colour + 1 (0: free) ...
	char[1024] index;   // ... and its index
}

fn int Palette.index_of(&self, char r, char g, char b) {
	uint key = (uint)r << 16 | (uint)g << 8 | b;
	uint h = (key * 2654435761u) >> 22;
	while (true) {
		uint s = self.slots[h];
		if (s == key + 1) return self.index[h];
		if (!s) break;
		h = (h + 1) & 1023;
	}
	if (self.count == 256) return -1;
	self.slots[h] = key + 1;
	self.index[h] = (char)self.count;
	self.r[self.count] = r;
	self.g[self.count] = g;
	self.b[self.count] = b;
	return self.count++;
}

// Every colour as 3 bits of red, 3 of green, 2 of blue.
fn void Palette.rgb332(&self) {
	for (int c = 0; c < 256; c++) {
		self.r[c] = (char)((c >> 5) * 255 / 7);
		self.g[c] = (char)(((c >> 2) & 7) * 255 / 7);
		self.b[c] = (char)((c & 3) * 255 / 3);
	}
	self.count = 256;
}

// --- LZW -----------------------------------------------------------------------

// GIF's LZW: codes of growing width (up to 12 bits), packed from the low bit,
// in blocks of up to 255 bytes; a clear code when the table fills.
struct Lzw {
	int[8192] keys;     // (prefix << 8 | byte) + 1, 0: free
	short[8192] codes;
	DString* out;
	uint acc;
	int acc_bits;
	char[255] block;
	int block_len;
}

fn void Lzw.put_byte(&self, char c) {
	self.block[self.block_len++] = c;
	if (self.block_len == 255) self.flush_block();
}

fn void Lzw.flush_block(&self) {
	if (!self.block_len) return;
	self.out.append_char((char)self.block_len);
	self.out.append(self.block[:self.block_len]);
	self.block_len = 0;
}

fn void Lzw.put_code(&self, int code, int width) {
	self.acc |= (uint)code << self.acc_bits;
	self.acc_bits += width;
	while (self.acc_bits >= 8) {
		self.put_byte((char)self.acc);
		self.acc >>= 8;
		self.acc_bits -= 8;
	}
}

fn void Lzw.reset_table(&self) {
	self.keys[..] = 0;
}

fn void Lzw.encode(&self, char[] pixels, int min_code, DString* out) {
	self.out = out;
	self.acc = 0;
	self.acc_bits = 0;
	self.block_len = 0;
	int clear = 1 << min_code;
	int width = min_code + 1;
	int max_code = clear + 1;
	self.reset_table();
	self.put_code(clear, width);
	int cur = pixels[0];
	for (usz i = 1; i < pixels.len; i++) {
		int k = pixels[i];
		int key = cur << 8 | k;
		uint h = ((uint)key * 2654435761u) >> 19;
		bool found = false;
		while (true) {
			int s = self.keys[h];
			if (s == key + 1) {
				cur = self.codes[h];
				found = true;
				break;
			}
			if (!s) break;
			h = (h + 1) & 8191;
		}
		if (found) continue;
		self.put_code(cur, width);
		max_code++;
		self.keys[h] = key + 1;
		self.codes[h] = (short)max_code;
		if (max_code >= 1 << width) width++;
		if (max_code == 4095) {
			self.put_code(clear, width);
			self.reset_table();
			width = min_code + 1;
			max_code = clear + 1;
		}
		cur = k;
	}
	self.put_code(cur, width);
	// The decoder adds an entry after this code too: same width rule.
	max_code++;
	if (max_code >= 1 << width && width < 12) width++;
	self.put_code(clear + 1, width);
	if (self.acc_bits) self.put_byte((char)self.acc);
	self.flush_block();
	out.append_char(0);
}
