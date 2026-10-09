module fuzz_test;
import gameboy, mmu, cart, patch, zip, zip_test;
import std::core::test, std::io, std::io::file, std::os::env, std::hash::crc32;

// Fuzzing what wer reads from outside: ROMs (random code and headers, every
// mapper), ROM patches, zip archives and save states (a field at a time set to a random or extreme
// value). Nothing may read or write out of bounds: run it with the checks
// on (c3c test -O1 --test-filter fuzz), where that stops with a backtrace.
// A few iterations by default; WER_FUZZ=n for n, WER_FUZZ_SEED for another
// seed, WER_FUZZ_LOG to print each case before it runs.

struct Rng {
	ulong s;
}

fn ulong Rng.next(&self) {
	self.s ^= self.s << 13;
	self.s ^= self.s >> 7;
	self.s ^= self.s << 17;
	return self.s;
}

fn ulong Rng.below(&self, ulong n) => n ? self.next() % n : 0;

fn int iterations(int dflt) => (env::tget_var("WER_FUZZ") ?? "").to_int() ?? dflt;

fn Rng rng() {
	ulong seed = (ulong)((env::tget_var("WER_FUZZ_SEED") ?? "").to_int() ?? 1);
	return { .s = seed * 0x9E3779B97F4A7C15 | 1 };
}

bool log;

// --- ROMs --------------------------------------------------------------------

// Cartridge types worth a header ($0147): every one wer knows, and a few it
// doesn't.
const char[*] CART_TYPES = {
	0x00, 0x01, 0x02, 0x03, 0x05, 0x06, 0x08, 0x09, 0x0B, 0x0C, 0x0D, 0x0F, 0x10, 0x11, 0x12, 0x13,
	0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x20, 0x22, 0xFC, 0xFD, 0xFE, 0xFF, 0x04, 0x07, 0x14, 0x30,
};

fn void random_rom(Rng* r, char[]* out) {
	usz size = (usz)0x8000 << r.below(7);       // 32 KiB - 2 MiB
	if (r.below(8) == 0) size = (usz)(0x150 + r.below(0x8000)); // and odd sizes
	char[] rom = mem::new_array(char, (sz)size);
	for (usz i = 0; i < size; i++) rom[i] = (char)r.next();
	rom[0x147] = CART_TYPES[r.below(CART_TYPES.len)];
	rom[0x148] = (char)r.below(10);
	rom[0x149] = (char)r.below(7);
	switch (r.below(8)) {
		case 0: // Sachen's logo where its mappers keep it
			rom[0x104] = 0xCE; rom[0x144] = 0xED; rom[0x114] = 0x66;
		case 1:
			if (size > 0x200) { rom[0x184] = 0xCE; rom[0x1C4] = 0xED; rom[0x194] = 0x66; }
		case 2: // TPP1
			rom[0x147] = 0xBC; rom[0x149] = 0xC1; rom[0x14A] = 0x65;
		case 3: // M161, Wisdom Tree
			rom[0x147] = 0;
			rom[0x134:10] = ((char[])"TETRIS SET")[:10];
		default: break;
	}
	*out = rom;
}

fn void fuzz_rom(Rng* r, int n) {
	char[] rom;
	random_rom(r, &rom);
	defer free(rom.ptr);
	mmu::Model[3] models = { DMG, CGB, SGB };
	mmu::Model model = models[r.below(3)];
	if (log) io::eprintfn("rom %d: %d bytes, type %02X, rom %02X ram %02X, %s", n, rom.len, rom[0x147], rom[0x148], rom[0x149], model);
	gameboy::GameBoy* g = mem::new(gameboy::GameBoy);
	*g = gameboy::new(r.below(2) == 0, model);
	defer { g.destroy(); free(g); }
	g.load_rom(rom);
	// The bootleg mappers are only known by CRCs: force one now and then.
	if (g.mmu.cart && r.below(4) == 0) {
		cart::Mbc[*] bootlegs = { BBD, HITEK, GGB81, LI_CHENG, SINTAX, NT_OLD1, NT_OLD2, NT_NEW, PKJD,
			ROCKET, LASAMA, YONG, ROCKMAN8, SM3SP, NEWGBCHK, VF001, LIEBAO, CHONGWU, SLMULTI, GBCK003, SKOB, POKE2IN1, HICOL };
		g.mmu.cart.mbc = bootlegs[r.below(bootlegs.len)];
		g.mmu.cart.unl = {};
		g.mmu.cart.unl_init();
		g.mmu.cart.hhugboy_init();
		g.mmu.cart.rom_mapped = false;
		if (log) io::eprintfn("  as %s", g.mmu.cart.mbc);
	}
	for (int f = 0; f < 10; f++) {
		g.mmu.set_input((char)r.next(), (char)r.next());
		g.run_frame();
	}
	// What the debugger looks at, and a save state's round trip.
	for (int a = 0; a < 0x10000; a += 7) g.mmu.peek((ushort)a);
	int len;
	for (int a = 0; a < 0x8000; a += 3) gameboy::disasm(&g.mmu, (ushort)a, &len);
	char[] st = g.save_state(mem);
	defer free(st.ptr);
	(void)g.load_state(st);
	g.run_frame();
}

fn void random_roms() @test {
	log = @ok(env::tget_var("WER_FUZZ_LOG"));
	Rng r = rng();
	int n = iterations(20);
	for (int i = 0; i < n; i++) fuzz_rom(&r, i);
}

// --- patches -------------------------------------------------------------------

fn void put_number(DString* s, ulong v) {
	while (true) {
		char x = (char)(v & 0x7F);
		v >>= 7;
		if (!v) {
			s.append_char(x | 0x80);
			return;
		}
		s.append_char(x);
		v--;
	}
}

fn void put_le32(DString* s, uint v) {
	for (int i = 0; i < 4; i++) s.append_char((char)(v >> (8 * i)));
}

// IPS, UPS and BPS patches of random bytes; the UPS/BPS ones mostly with the
// right sizes and CRCs for the ROM, so that their commands get read.
fn void random_patches() @test {
	Rng r = rng();
	int n = iterations(20) * 50;
	String[3] magic = { "PATCH", "UPS1", "BPS1" };
	for (int i = 0; i < n; i++) {
		char[] rom = mem::temp_array(char, (sz)r.below(64));
		foreach (&b : rom) *b = (char)r.next();
		usz kind = (usz)r.below(3);
		DString s;
		s.tinit();
		s.append(magic[kind]);
		bool framed = kind > 0 && r.below(4) != 0;
		if (framed) {
			put_number(&s, rom.len);
			put_number(&s, r.below(96));
			if (kind == 2) put_number(&s, r.below(3));
		}
		ulong body = r.below(64);
		for (ulong k = 0; k < body; k++) {
			// Small numbers and command bytes more often than not.
			s.append_char(r.below(2) ? (char)(0x80 | r.below(8)) : (char)r.next());
		}
		if (kind == 0 && r.below(2)) s.append("EOF");
		if (framed) {
			put_le32(&s, crc32::hash(rom));
			put_le32(&s, (uint)r.next());
			put_le32(&s, crc32::hash(s.str_view()));
		}
		if (log) io::eprintfn("patch %d: %s, %d bytes", i, magic[kind], s.len());
		(void)patch::apply(rom, s.str_view(), tmem);
	}
}

// --- zip archives --------------------------------------------------------------

// The zip tests' archives with bytes changed (the directory, the headers,
// the deflated data), and random bytes after a zip's signature.
fn void damaged_zips() @test {
	Rng r = rng();
	int n = iterations(20) * 50;
	char[][4] good = { &zip_test::STORED, &zip_test::FIXED, &zip_test::DYNAMIC, &zip_test::NO_ROM };
	for (int i = 0; i < n; i++) {
		char[] z;
		if (r.below(8)) {
			char[] src = good[r.below(4)];
			z = mem::temp_array(char, (sz)src.len);
			z[..] = src[..];
			ulong changes = 1 + r.below(8);
			for (ulong k = 0; k < changes; k++) {
				usz at = (usz)r.below(z.len);
				z[at] = r.below(2) ? (char)r.next() : z[at] ^ (char)(1 << r.below(8));
			}
		} else {
			z = mem::temp_array(char, (sz)(4 + r.below(300)));
			foreach (&b : z) *b = (char)r.next();
			z[0] = 'P';
			z[1] = 'K';
			z[2] = 3;
			z[3] = 4;
		}
		if (log) io::eprintfn("zip %d: %d bytes", i, z.len);
		(void)zip::extract_rom(z, tmem);
	}
}

// --- save states ---------------------------------------------------------------

// A value in a state: an integer field, an array's elements, raw bytes.
struct Leaf {
	usz    at;
	usz    len;
	char   tag;
	String name;
}

const char TAG_STRUCT = 1;
const char TAG_SIGNED = 2;
const char TAG_UNSIGNED = 3;
const char TAG_ARRAY = 4;

fn uint get32(char[] d, usz at) => (uint)d[at] | (uint)d[at + 1] << 8 | (uint)d[at + 2] << 16 | (uint)d[at + 3] << 24;

fn void leaves(char[] data, usz base, String path, Leaf[] out, int* count) {
	char[] rec = data[base..];
	int left = rec[0] | (int)rec[1] << 8;
	usz pos = 2;
	for (int i = 0; i < left; i++) {
		usz len = rec[pos];
		String name = string::tformat("%s.%s", path, (String)rec[pos + 1 : len]);
		char tag = rec[pos + 1 + len];
		usz n = get32(rec, pos + 2 + len);
		usz start = pos + 6 + len;
		switch (tag) {
			case TAG_STRUCT:
				leaves(data, base + start, name, out, count);
			case TAG_ARRAY:
				if (n > 4 && *count < out.len) out[(*count)++] = { base + start + 4, n - 4, tag, name };
			default:
				if (n > 0 && *count < out.len) out[(*count)++] = { base + start, n, tag, name };
		}
		pos = start + n;
	}
}

fn void mutate(Rng* r, char[] st, Leaf* l) {
	char[] v = st[l.at : l.len];
	if (l.tag == TAG_SIGNED || l.tag == TAG_UNSIGNED) {
		switch (r.below(6)) {
			case 0: v[..] = 0;
			case 1: v[..] = 0xFF;
			case 2:
				v[..] = 0xFF;
				v[^1] = 0x7F;
			case 3:
				v[..] = 0;
				v[0] = (char)r.below(300);
				if (v.len > 1) v[1] = (char)r.below(2);
			default:
				foreach (&b : v) *b = (char)r.next();
		}
		return;
	}
	// Arrays, raw bytes: a few of them.
	for (int k = 0; k < 4; k++) v[r.below(v.len)] = (char)r.next();
}

// After a mutated state ran: back to the good one, or (a state may rewrite
// even a plain cartridge's ROM, its header included, and then no state of
// this game fits) a new machine with it.
fn void back(gameboy::GameBoy* g, char[] good, char[] rom, mmu::Model model) {
	if (catch g.load_state(good)) {
		g.destroy();
		*g = gameboy::new(false, model);
		g.load_rom(rom);
		(void)g.load_state(good);
	}
}

// `path`, or "sgb:path" for a Super Game Boy.
fn void fuzz_states(Rng* r, String path, int n) {
	mmu::Model model = path.ends_with(".gbc") ? mmu::Model.CGB : mmu::Model.DMG;
	if (path.starts_with("sgb:")) {
		path = path[4..];
		model = SGB;
	}
	char[]? rom = file::load_temp(path);
	if (catch rom) return;
	gameboy::GameBoy* g = mem::new(gameboy::GameBoy);
	*g = gameboy::new(false, model);
	defer { g.destroy(); free(g); }
	g.load_rom(rom);
	for (int f = 0; f < 30; f++) g.run_frame();
	char[] good = g.save_state(mem);
	defer free(good.ptr);
	Leaf[] all = mem::new_array(Leaf, 4096);
	defer free(all.ptr);
	int count;
	leaves(good, gameboy::StateHeader::size, "", all, &count);
	char[] st = mem::new_array(char, good.len);
	defer free(st.ptr);
	int loaded;
	defer if (log) io::eprintfn("%s: %d fields, %d of %d mutated states loaded", path, count, loaded, n);
	char[] raw = g.save_state_raw(mem);
	defer free(raw.ptr);
	char[] rst = mem::new_array(char, raw.len);
	defer free(rst.ptr);
	for (int i = 0; i < n; i++) {
		// Every fourth case an old (version 1) state, bytes changed anywhere.
		if (i % 4 == 3) {
			rst[..] = raw[..];
			int k = (int)r.below(4) + 1;
			usz at = 0;
			for (int j = 0; j < k; j++) {
				at = gameboy::StateHeader::size + (usz)r.below((ulong)(raw.len - gameboy::StateHeader::size));
				rst[at] = (char)r.next();
			}
			if (log) io::eprintfn("state %d: %s raw byte %d", i, path, at);
			if (try g.load_state(rst)) {
				loaded++;
				for (int f = 0; f < 3; f++) g.run_frame();
				back(g, good, rom, model);
			}
			continue;
		}
		// Every eighth a state damaged anywhere, its framing too.
		if (i % 8 == 1) {
			st[..] = good[..];
			for (int j = (int)r.below(8); j >= 0; j--) st[gameboy::StateHeader::size + (usz)r.below((ulong)(st.len - gameboy::StateHeader::size))] = (char)r.next();
			if (log) io::eprintfn("state %d: %s damaged", i, path);
			if (try g.load_state(st)) {
				loaded++;
				for (int f = 0; f < 3; f++) g.run_frame();
				back(g, good, rom, model);
			}
			continue;
		}
		st[..] = good[..];
		Leaf* l;
		for (int j = (int)r.below(3); j >= 0; j--) {
			l = &all[r.below((ulong)count)];
			mutate(r, st, l);
		}
		if (log) io::eprintfn("state %d: %s%s", i, path, l.name);
		if (catch g.load_state(st)) continue;
		loaded++;
		for (int f = 0; f < 3; f++) g.run_frame();
		g.framebuffer();
		back(g, good, rom, model);
	}
}

fn void mutated_states() @test {
	log = @ok(env::tget_var("WER_FUZZ_LOG"));
	Rng r = rng();
	int n = iterations(50);
	foreach (path : (String[]){ "test/acid2/dmg-acid2.gb", "test/acid2/cgb-acid2.gbc", "test/blargg/dmg_sound/03-trigger.gb",
		"test/mbc3/rtc3test.gb", "sgb:test/acid2/dmg-acid2.gb" }) {
		fuzz_states(&r, path, n);
	}
	// WER_FUZZ_ROMS: more games, comma-separated (copies: their saves aren't touched).
	foreach (path : (env::tget_var("WER_FUZZ_ROMS") ?? "").tsplit(",")) {
		if (path.len) fuzz_states(&r, path, n);
	}
}
