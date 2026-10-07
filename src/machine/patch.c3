module patch;

import std::hash::crc32, std::core::mem::alloc;

// ROM patches (fan translations, hacks), applied as a game loads; the ROM
// file stays as it is.
//   IPS  "PATCH", then records: a 3-byte offset, a 2-byte length and that
//        many bytes (length 0: a 2-byte count and one byte repeated), up to
//        "EOF", optionally followed by a 3-byte size to cut the ROM to.
//   UPS  "UPS1", the sizes before and after, then runs of bytes XORed into
//        the ROM (each after a skip, ended by a 0); CRC32s of the ROM, the
//        result and the patch at the end.
//   BPS  "BPS1", the sizes, some metadata, then commands that build the
//        result from the ROM, from the patch, or from what was written
//        already; the same three CRC32s at the end.
// UPS and BPS numbers are variable-length (7 bits a byte, the last one with
// bit 7 set, each further byte adding one more step).

faultdef NOT_A_PATCH, WRONG_ROM, BROKEN;

// The largest result accepted (a Game Boy ROM is 8 MiB at most).
const usz MAX_SIZE = 0x2000000;

fn bool is_patch(char[] data) {
	return starts(data, "PATCH") || starts(data, "UPS1") || starts(data, "BPS1");
}

fn bool starts(char[] data, String magic) => data.len >= magic.len && (String)data[:magic.len] == magic;

// The patched ROM, in a new array from `alloc` (the ROM is left alone).
fn char[]? apply(char[] rom, char[] patch, Allocator alloc = mem) {
	if (starts(patch, "PATCH")) return apply_ips(rom, patch, alloc);
	if (starts(patch, "UPS1")) return apply_ups(rom, patch, alloc);
	if (starts(patch, "BPS1")) return apply_bps(rom, patch, alloc);
	return NOT_A_PATCH~;
}

// --- IPS ---------------------------------------------------------------------

fn char[]? apply_ips(char[] rom, char[] p, Allocator alloc) {
	// First pass: how big the result gets.
	usz size = rom.len;
	usz i = 5;
	usz cut = 0;
	bool has_cut = false;
	while (true) {
		if (i + 3 > p.len) return BROKEN~;
		if ((String)p[i : 3] == "EOF") {
			if (i + 6 <= p.len) {
				cut = (usz)p[i + 3] << 16 | (usz)p[i + 4] << 8 | p[i + 5];
				has_cut = true;
			}
			break;
		}
		if (i + 5 > p.len) return BROKEN~;
		usz at = (usz)p[i] << 16 | (usz)p[i + 1] << 8 | p[i + 2];
		usz n = (usz)p[i + 3] << 8 | p[i + 4];
		i += 5;
		if (n == 0) {
			if (i + 3 > p.len) return BROKEN~;
			n = (usz)p[i] << 8 | p[i + 1];
			i += 3;
		} else {
			if (i + n > p.len) return BROKEN~;
			i += n;
		}
		if (at + n > size) size = at + n;
	}
	if (has_cut) size = cut;
	if (size > MAX_SIZE) return BROKEN~;

	char[] out = alloc::new_array(alloc, char, (sz)size);
	usz keep = rom.len < size ? rom.len : size;
	out[:keep] = rom[:keep];
	i = 5;
	while ((String)p[i : 3] != "EOF") {
		usz at = (usz)p[i] << 16 | (usz)p[i + 1] << 8 | p[i + 2];
		usz n = (usz)p[i + 3] << 8 | p[i + 4];
		i += 5;
		if (n == 0) {
			n = (usz)p[i] << 8 | p[i + 1];
			char v = p[i + 2];
			i += 3;
			for (usz k = 0; k < n && at + k < size; k++) out[at + k] = v;
		} else {
			for (usz k = 0; k < n && at + k < size; k++) out[at + k] = p[i + k];
			i += n;
		}
	}
	return out;
}

// --- UPS and BPS -------------------------------------------------------------

struct Reader {
	char[] data;
	usz pos;
	usz end;  // where the CRCs start
}

fn char? Reader.byte(&self) {
	if (self.pos >= self.end) return BROKEN~;
	return self.data[self.pos++];
}

fn ulong? Reader.number(&self) {
	ulong value;
	ulong shift = 1;
	while (true) {
		char x = self.byte()!;
		value += (ulong)(x & 0x7F) * shift;
		if (x & 0x80) return value;
		shift <<= 7;
		if (shift > (ulong)MAX_SIZE * 256) return BROKEN~;
		value += shift;
	}
}

fn uint le32(char[] d, usz at) => (uint)d[at] | (uint)d[at + 1] << 8 | (uint)d[at + 2] << 16 | (uint)d[at + 3] << 24;

// The CRCs at the end: the patch's own, then whether it is for this ROM.
fn void? check_footer(char[] rom, char[] p) {
	if (p.len < 16) return BROKEN~;
	usz f = p.len - 12;
	if (crc32::hash(p[:p.len - 4]) != le32(p, f + 8)) return BROKEN~;
	if (crc32::hash(rom) != le32(p, f)) return WRONG_ROM~;
}

fn void? check_result(char[] out, char[] p) {
	if (crc32::hash(out) != le32(p, p.len - 8)) return BROKEN~;
}

fn char[]? apply_ups(char[] rom, char[] p, Allocator alloc) {
	check_footer(rom, p)!;
	Reader r = { p, 4, p.len - 12 };
	ulong in_size = r.number()!;
	ulong out_size = r.number()!;
	if (in_size != (ulong)rom.len || out_size > (ulong)MAX_SIZE) return WRONG_ROM~;
	char[] out = alloc::new_array(alloc, char, (sz)out_size);
	usz keep = rom.len < out.len ? rom.len : out.len;
	out[:keep] = rom[:keep];
	usz pos = 0;
	while (r.pos < r.end) {
		ulong skip = r.number()!;
		if (skip > (ulong)out.len) {
			alloc::free(alloc, out);
			return BROKEN~;
		}
		pos += (usz)skip;
		while (true) {
			char x = r.byte()!;
			if (pos < out.len) out[pos] = (pos < rom.len ? rom[pos] : 0) ^ x;
			pos++;
			if (!x) break;
		}
	}
	if (catch e = check_result(out, p)) {
		alloc::free(alloc, out);
		return e~;
	}
	return out;
}

fn char[]? apply_bps(char[] rom, char[] p, Allocator alloc) {
	check_footer(rom, p)!;
	Reader r = { p, 4, p.len - 12 };
	ulong in_size = r.number()!;
	ulong out_size = r.number()!;
	ulong meta = r.number()!;
	if (in_size != (ulong)rom.len || out_size > (ulong)MAX_SIZE || meta > (ulong)(r.end - r.pos)) return WRONG_ROM~;
	r.pos += (usz)meta;
	char[] out = alloc::new_array(alloc, char, (sz)out_size);
	if (catch e = bps_actions(rom, out, &r)) {
		alloc::free(alloc, out);
		return e~;
	}
	if (catch e = check_result(out, p)) {
		alloc::free(alloc, out);
		return e~;
	}
	return out;
}

fn void? bps_actions(char[] rom, char[] out, Reader* r) {
	usz pos = 0;
	long src_at = 0;
	long out_at = 0;
	while (r.pos < r.end) {
		ulong data = r.number()!;
		usz n = (usz)(data >> 2) + 1;
		if (n > out.len - pos) return BROKEN~;
		switch (data & 3) {
			case 0: // the ROM's own bytes, where they are
				if (pos + n > rom.len) return BROKEN~;
				out[pos : n] = rom[pos : n];
			case 1: // bytes from the patch
				for (usz k = 0; k < n; k++) out[pos + k] = r.byte()!;
			case 2: // bytes from elsewhere in the ROM
				src_at += signed(r.number()!);
				if (src_at < 0 || (ulong)src_at + (ulong)n > (ulong)rom.len) return BROKEN~;
				out[pos : n] = rom[(usz)src_at : n];
				src_at += (long)n;
			default: // bytes written already (they may overlap what is being written)
				out_at += signed(r.number()!);
				if (out_at < 0 || (ulong)out_at >= (ulong)pos) return BROKEN~;
				for (usz k = 0; k < n; k++) out[pos + k] = out[(usz)out_at + k];
				out_at += (long)n;
		}
		pos += n;
	}
	if (pos != out.len) return BROKEN~;
}

// BPS offsets: bit 0 the sign, the rest the distance.
fn long signed(ulong v) => v & 1 ? -(long)(v >> 1) : (long)(v >> 1);
