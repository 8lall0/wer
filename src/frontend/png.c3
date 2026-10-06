module png;

// A minimal PNG writer: 8-bit greyscale or RGB, the image data in stored
// (uncompressed) deflate blocks. Enough for printouts and screenshots.

fn uint crc32(char[] data, uint crc = 0) {
	crc = ~crc;
	foreach (b : data) {
		crc ^= b;
		for (int k = 0; k < 8; k++) crc = (crc >> 1) ^ (0xEDB88320 & (uint)-(int)(crc & 1));
	}
	return ~crc;
}

fn void put32(DString* out, uint v) {
	out.append_char((char)(v >> 24));
	out.append_char((char)(v >> 16));
	out.append_char((char)(v >> 8));
	out.append_char((char)v);
}

fn void chunk(DString* out, String type, char[] body) {
	put32(out, (uint)body.len);
	usz start = (usz)out.len();
	out.append_string(type);
	out.append_bytes(body);
	put32(out, crc32(out.str_view()[start..]));
}

// `grey` is w x h bytes, row by row.
fn char[] grey(char[] grey, int w, int h, Allocator alloc) => encode(grey, w, h, 1, alloc);

// `rgb` is w x h x 3 bytes, row by row.
fn char[] rgb(char[] rgb, int w, int h, Allocator alloc) => encode(rgb, w, h, 3, alloc);

fn char[] encode(char[] px, int w, int h, int channels, Allocator alloc) {
	DString out;
	out.init(tmem);
	out.append_bytes({ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A });

	char[13] ihdr = { (char)(w >> 24), (char)(w >> 16), (char)(w >> 8), (char)w,
		(char)(h >> 24), (char)(h >> 16), (char)(h >> 8), (char)h, 8, channels == 3 ? 2 : 0, 0, 0, 0 };
	chunk(&out, "IHDR", &ihdr);

	// The rows, each after its filter byte (0: none), in a zlib stream of
	// stored blocks.
	DString raw;
	raw.init(tmem);
	for (int y = 0; y < h; y++) {
		raw.append_char(0);
		raw.append_bytes(px[(usz)(y * w * channels) : (usz)(w * channels)]);
	}
	char[] r = raw.str_view();
	DString z;
	z.init(tmem);
	z.append_bytes({ 0x78, 0x01 });
	usz pos;
	do {
		usz n = r.len - pos > 65535 ? 65535 : r.len - pos;
		z.append_char(pos + n == r.len ? 1 : 0);
		z.append_char((char)n);
		z.append_char((char)(n >> 8));
		z.append_char((char)~n);
		z.append_char((char)(~n >> 8));
		z.append_bytes(r[pos:n]);
		pos += n;
	} while (pos < r.len);
	uint a = 1;
	uint b = 0;
	foreach (c : r) {
		a = (a + c) % 65521;
		b = (b + a) % 65521;
	}
	put32(&z, b << 16 | a);
	chunk(&out, "IDAT", z.str_view());
	chunk(&out, "IEND", {});
	return out.str_view().copy(alloc);
}
