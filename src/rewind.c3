module gameboy;
import std::collections::list;

// Rewind: the last stretch of play, to run backwards.
//
// Every few frames the machine is snapshotted (a version 1 state: the same
// build all session, so the plain struct bytes do) and only what changed
// since the snapshot before is kept, XORed with it and run-length coded:
// mostly zeros, so a few KB a step. Going back undoes the newest change on
// the current snapshot and loads the result. The oldest steps go when the
// history outgrows its budget.

const int REWIND_EVERY = 2;   // frames between snapshots
const usz REWIND_BUDGET = env::ANDROID || env::EMSCRIPTEN ? 24 * 1024 * 1024 : 64 * 1024 * 1024;

struct Rewind {
	char[]       cur;       // the newest snapshot
	List{char[]} steps;     // what each snapshot changed from the one before (oldest first)
	usz          bytes;     // the steps' total size
	int          frames;    // since the last snapshot
	bool         ready;     // steps initialised (on the heap)
}

fn void Rewind.reset(&self) {
	foreach (s : self.steps) free(s.ptr);
	self.steps.clear();
	self.bytes = 0;
	if (self.cur.len) free(self.cur.ptr);
	self.cur = {};
	self.frames = 0;
}

fn void Rewind.free(&self) {
	self.reset();
	if (self.ready) self.steps.free();
	self.ready = false;
}

fn usz Rewind.len(&self) => (usz)self.steps.len();

// After a frame of emulation.
fn void Rewind.record(&self, GameBoy* gb) {
	if (++self.frames < REWIND_EVERY) return;
	self.frames = 0;
	if (!self.ready) {
		self.steps.init(mem);
		self.ready = true;
	}
	@pool() {
		char[] snap = gb.save_state_raw(tmem);
		if (self.cur.len != snap.len) {
			// The first snapshot, or another machine: start over.
			self.reset();
			self.cur = (char[])((String)snap).copy(mem);
			return;
		}
		char[] step = xor_rle(self.cur, snap, mem);
		self.cur[..] = snap[..];
		self.steps.push(step);
		self.bytes += step.len;
		while (self.bytes > REWIND_BUDGET && self.steps.len() > 1) {
			char[] old = self.steps.pop_first()!!;
			self.bytes -= old.len;
			free(old.ptr);
		}
	};
}

// One snapshot back; false when there is no more history.
fn bool Rewind.back(&self, GameBoy* gb) {
	if (!self.steps.len()) return false;
	char[] step = self.steps.pop()!!;
	self.bytes -= step.len;
	xor_unrle(self.cur, step);
	free(step.ptr);
	(void)gb.load_state(self.cur);
	return true;
}

// `b` XOR `a` as runs: u16 zero count, u16 literal count, the literals.
fn char[] xor_rle(char[] a, char[] b, Allocator alloc) {
	DString out;
	out.init(tmem);
	usz i;
	usz n = a.len;
	while (i < n) {
		usz z = i;
		while (z < n && z - i < 0xFFFF && a[z] == b[z]) z++;
		usz l = z;
		// Literals until a run of 4 equal bytes (or the end).
		while (l < n && l - z < 0xFFFF) {
			if (a[l] == b[l] && l + 3 < n && a[l + 1] == b[l + 1] && a[l + 2] == b[l + 2] && a[l + 3] == b[l + 3]) break;
			if (a[l] == b[l] && l + 3 >= n) break;
			l++;
		}
		out.append_char((char)(z - i));
		out.append_char((char)((z - i) >> 8));
		out.append_char((char)(l - z));
		out.append_char((char)((l - z) >> 8));
		for (usz k = z; k < l; k++) out.append_char(a[k] ^ b[k]);
		i = l;
	}
	return (char[])out.str_view().copy(alloc);
}

fn void xor_unrle(char[] buf, char[] rle) {
	usz i;
	usz p;
	while (p + 4 <= rle.len) {
		usz z = rle[p] | (usz)rle[p + 1] << 8;
		usz l = rle[p + 2] | (usz)rle[p + 3] << 8;
		p += 4;
		i += z;
		for (usz k = 0; k < l; k++) buf[i + k] ^= rle[p + k];
		p += l;
		i += l;
	}
}
