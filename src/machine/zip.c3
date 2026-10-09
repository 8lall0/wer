module zip;

import std::hash::crc32, std::core::mem::alloc;

// Game Boy ROMs in a .zip archive. The archive's directory sits at its end:
// the end record gives where it starts, each entry its name, method, sizes,
// CRC32 and where its local header is; the data follows that header. Entries
// are stored as they are (method 0) or deflated (method 8, RFC 1951, below).
// No encryption, no ZIP64 (Game Boy ROMs are 8 MiB at most).

faultdef NOT_A_ZIP, NO_ROM, UNSUPPORTED, BROKEN;

const usz MAX_SIZE = 0x2000000;

fn bool is_zip(char[] data) => data.len >= 4 && data[0] == 'P' && data[1] == 'K' && data[2] == 3 && data[3] == 4;

fn uint le16(char[] d, usz at) => (uint)d[at] | (uint)d[at + 1] << 8;
fn uint le32(char[] d, usz at) => le16(d, at) | le16(d, at + 2) << 16;

fn bool is_rom_name(String name) {
	foreach (ext : (String[]){ ".gb", ".gbc", ".cgb", ".sgb" }) {
		if (name.len > ext.len && name[name.len - ext.len..].to_lower_tcopy() == ext) return true;
	}
	return false;
}

// The first Game Boy ROM in the archive (by its name), unpacked into a new
// array from `allocator`.
fn char[]? extract_rom(char[] z, Allocator allocator = mem) {
	if (z.len < 22) return NOT_A_ZIP~;
	// The end record: its signature, up to 64 KiB of comment from the end.
	usz end = z.len - 22;
	usz lowest = z.len > 22 + 0xFFFF ? z.len - 22 - 0xFFFF : 0;
	while (le32(z, end) != 0x06054B50) {
		if (end == lowest) return NOT_A_ZIP~;
		end--;
	}
	usz count = le16(z, end + 10);
	usz at = le32(z, end + 16);
	for (usz i = 0; i < count; i++) {
		if (at + 46 > z.len || le32(z, at) != 0x02014B50) return BROKEN~;
		uint flags = le16(z, at + 8);
		uint method = le16(z, at + 10);
		uint crc = le32(z, at + 16);
		usz packed = le32(z, at + 20);
		usz size = le32(z, at + 24);
		usz name_len = le16(z, at + 28);
		usz skip = 46 + name_len + le16(z, at + 30) + le16(z, at + 32);
		usz local = le32(z, at + 42);
		if (at + 46 + name_len > z.len) return BROKEN~;
		String name = (String)z[at + 46 : name_len];
		at += skip;
		if (!is_rom_name(name)) continue;
		if (flags & 1) return UNSUPPORTED~;               // encrypted
		if (size > MAX_SIZE || packed > z.len) return UNSUPPORTED~;
		if (local + 30 > z.len || le32(z, local) != 0x04034B50) return BROKEN~;
		usz data = local + 30 + le16(z, local + 26) + le16(z, local + 28);
		if (data + packed > z.len) return BROKEN~;
		char[] input = z[data : packed];
		char[] out = alloc::new_array(allocator, char, (sz)size);
		switch (method) {
			case 0:
				if (packed != size) {
					alloc::free(allocator, out);
					return BROKEN~;
				}
				out[..] = input[..];
			case 8:
				if (catch e = inflate(input, out)) {
					alloc::free(allocator, out);
					return e~;
				}
			default:
				alloc::free(allocator, out);
				return UNSUPPORTED~;
		}
		if (crc32::hash(out) != crc) {
			alloc::free(allocator, out);
			return BROKEN~;
		}
		return out;
	}
	return NO_ROM~;
}

// --- inflate (RFC 1951) ----------------------------------------------------------
//
// Blocks: stored (a length, then bytes), or Huffman coded with the fixed
// codes or with codes the block describes first. Codes are read a bit at a
// time, from the low bit; a code's symbol is a byte, the end of the block, or
// a length that copies earlier output (with a distance code after it).

struct Bits {
	char[] in;
	usz pos;
	uint acc;
	int count;
}

fn uint? Bits.get(&self, int n) {
	while (self.count < n) {
		if (self.pos >= self.in.len) return BROKEN~;
		self.acc |= (uint)self.in[self.pos++] << self.count;
		self.count += 8;
	}
	uint v = self.acc & ((1u << n) - 1);
	self.acc = n == 32 ? 0 : self.acc >> n;
	self.count -= n;
	return v;
}

const int MAX_BITS = 15;

// A canonical Huffman code: how many codes of each length, and the symbols
// in code order.
struct Huffman {
	short[MAX_BITS + 1] count;
	short[288] symbol;
}

fn void? Huffman.build(&self, char[] lengths) {
	self.count[..] = 0;
	foreach (l : lengths) self.count[l]++;
	self.count[0] = 0;
	int left = 1;
	for (int len = 1; len <= MAX_BITS; len++) {
		left <<= 1;
		left -= self.count[len];
		if (left < 0) return BROKEN~;              // more codes than fit
	}
	short[MAX_BITS + 1] offs;
	for (int len = 1; len < MAX_BITS; len++) offs[len + 1] = offs[len] + self.count[len];
	foreach (s, l : lengths) {
		if (l) self.symbol[offs[l]++] = (short)s;
	}
}

fn int? Huffman.decode(&self, Bits* b) {
	int code;
	int first;
	int index;
	for (int len = 1; len <= MAX_BITS; len++) {
		code |= (int)b.get(1)!;
		int n = self.count[len];
		if (code - n < first) return self.symbol[index + (code - first)];
		index += n;
		first += n;
		first <<= 1;
		code <<= 1;
	}
	return BROKEN~;
}

const short[29] LENGTH_BASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const char[29] LENGTH_EXTRA = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const ushort[30] DIST_BASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
const char[30] DIST_EXTRA = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };
const char[19] CODE_ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

// Unpacks `in` into `out`, which must come out exactly full.
fn void? inflate(char[] in, char[] out) {
	Bits b = { .in = in };
	usz n = 0;
	Huffman lit;
	Huffman dist;
	bool last;
	while (!last) {
		last = b.get(1)! == 1;
		switch (b.get(2)!) {
			case 0:
				// Stored: from the next byte, a length and its complement.
				b.acc = 0;
				b.count = 0;
				if (b.pos + 4 > in.len) return BROKEN~;
				usz len = le16(in, b.pos);
				if ((le16(in, b.pos + 2) ^ 0xFFFF) != len) return BROKEN~;
				b.pos += 4;
				if (b.pos + len > in.len || n + len > out.len) return BROKEN~;
				out[n : len] = in[b.pos : len];
				b.pos += len;
				n += len;
				continue;
			case 1:
				char[288] l;
				l[0:144] = 8;
				l[144:112] = 9;
				l[256:24] = 7;
				l[280:8] = 8;
				lit.build(&l)!;
				char[30] d;
				d[..] = 5;
				dist.build(&d)!;
			case 2:
				read_codes(&b, &lit, &dist)!;
			default:
				return BROKEN~;
		}
		while (true) {
			int sym = lit.decode(&b)!;
			if (sym < 256) {
				if (n >= out.len) return BROKEN~;
				out[n++] = (char)sym;
				continue;
			}
			if (sym == 256) break;
			sym -= 257;
			if (sym >= 29) return BROKEN~;
			usz len = (usz)LENGTH_BASE[sym] + b.get(LENGTH_EXTRA[sym])!;
			int ds = dist.decode(&b)!;
			if (ds >= 30) return BROKEN~;
			usz back = (usz)DIST_BASE[ds] + b.get(DIST_EXTRA[ds])!;
			if (back > n || n + len > out.len) return BROKEN~;
			for (usz k = 0; k < len; k++, n++) out[n] = out[n - back];
		}
	}
	if (n != out.len) return BROKEN~;
}

// A dynamic block's codes: the code lengths' own code first, then the
// literal/length and distance code lengths with it (16: repeat the last,
// 17 and 18: runs of zeros).
fn void? read_codes(Bits* b, Huffman* lit, Huffman* dist) {
	int nlit = (int)b.get(5)! + 257;
	int ndist = (int)b.get(5)! + 1;
	int ncode = (int)b.get(4)! + 4;
	if (nlit > 286 || ndist > 30) return BROKEN~;
	char[19] cl;
	for (int i = 0; i < ncode; i++) cl[CODE_ORDER[i]] = (char)b.get(3)!;
	Huffman lens;
	lens.build(&cl)!;
	char[316] l;
	int i = 0;
	while (i < nlit + ndist) {
		int sym = lens.decode(b)!;
		if (sym < 16) {
			l[i++] = (char)sym;
			continue;
		}
		char v = 0;
		int rep;
		switch (sym) {
			case 16:
				if (i == 0) return BROKEN~;
				v = l[i - 1];
				rep = 3 + (int)b.get(2)!;
			case 17: rep = 3 + (int)b.get(3)!;
			default: rep = 11 + (int)b.get(7)!;
		}
		if (i + rep > nlit + ndist) return BROKEN~;
		for (int k = 0; k < rep; k++) l[i++] = v;
	}
	if (!l[256]) return BROKEN~;                     // no end of block
	lit.build(l[:nlit])!;
	dist.build(l[nlit : ndist])!;
}
