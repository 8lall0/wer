module record_test;
import record, std::io, std::io::file, std::os::env, std::core::test;

// GIF's LZW, decoded the way a viewer does it: the encoder's output must
// give back the pixels, through the table filling up and starting over.
fn char[] lzw_decode(char[] data, int min_code, usz count) {
	// The sub-blocks, joined.
	DString bytes;
	bytes.tinit();
	usz i = 0;
	while (data[i]) {
		bytes.append(data[i + 1 : data[i]]);
		i += (usz)data[i] + 1;
	}
	char[] in = bytes.str_view();
	char[] out = mem::temp_array(char, (sz)count);
	usz n = 0;
	int clear = 1 << min_code;
	int width = min_code + 1;
	int next = clear + 2;
	int[4096] prefix;
	char[4096] suffix;
	char[4096] stack;
	int prev = -1;
	usz bit = 0;
	while (bit + (usz)width <= in.len * 8) {
		int code = 0;
		for (int b = 0; b < width; b++, bit++) code |= (int)((in[bit / 8] >> (bit % 8)) & 1) << b;
		if (code == clear) {
			width = min_code + 1;
			next = clear + 2;
			prev = -1;
			continue;
		}
		if (code == clear + 1) break;
		int c = code;
		int sp = 0;
		if (c >= next) {          // the code being defined: prev's string + its first byte
			c = prev;
			sp = 1;
		}
		while (c >= clear) {
			stack[sp++] = suffix[c];
			c = prefix[c];
		}
		char first = (char)c;
		stack[sp++] = first;
		if (code >= next) stack[0] = first;
		if (prev >= 0 && next < 4096) {
			prefix[next] = prev;
			suffix[next] = first;
			next++;
			if (next >= 1 << width && width < 12) width++;
		}
		while (sp) out[n++] = stack[--sp];
		prev = code;
	}
	test::eq(n, count);
	return out;
}

fn void lzw_round_trip() @test {
	record::Lzw* lzw = mem::new(record::Lzw);
	defer free(lzw);
	ulong seed = 99;
	foreach (int bits : (int[]){ 1, 2, 4, 8 }) {
		// Noise fills the table (and starts it over); runs make long codes.
		char[] pixels = mem::temp_array(char, 160 * 144);
		foreach (i, &p : pixels) {
			seed = seed * 6364136223846793005 + 1442695040888963407;
			ulong mask = (1ul << bits) - 1;
			*p = i % 3000 < 1500 ? (char)((seed >> 33) & mask) : (char)(((ulong)i / 500) & mask);
		}
		int min_code = bits < 2 ? 2 : bits;
		DString d;
		d.tinit();
		lzw.encode(pixels, min_code, &d);
		test::eq(lzw_decode(d.str_view(), min_code, pixels.len), pixels);
	}
}

fn void gif_and_wav_files() @test {
	String base = string::tformat("%s/wer-record-test", env::tget_var("TMPDIR") ?? "/tmp");
	record::Recorder r;
	r.start(base, 4, 2, 1.0 / 60, 48000)!!;
	char[24] a;
	char[24] b;
	b[0] = 0xFF;
	r.frame(&a, 4, 2);
	r.frame(&b, 4, 2);                        // 1/60 s later: too soon, it replaces a
	r.frame(&a, 4, 2);
	r.frame(&a, 4, 2);
	r.frame(&b, 4, 2);                        // 3/60 s: a shows for 5/100 s
	short[4] sound = { 1, -1, 300, -300 };
	r.audio(&sound);
	test::eq(r.frame(&a, 8, 2), false);       // another size: the end
	test::eq(r.on, false);
	char[] gif = file::load_temp(r.gif_path)!!;
	char[] wav = file::load_temp(r.wav_path)!!;
	(void)file::delete(r.gif_path);
	(void)file::delete(r.wav_path);
	r.free_paths();
	test::eq((String)gif[:6], "GIF89a");
	test::eq(gif[^1], (char)0x3B);
	test::eq(wav.len, 44 + 8);
	test::eq((String)wav[:4], "RIFF");
	test::eq(wav[40], (char)8);               // the data's size
	test::eq(wav[44 + 4], (char)0x2C);        // 300, little-endian
	test::eq(wav[44 + 5], (char)0x01);
}
