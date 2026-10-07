module mmu;

// The debugger's watchpoints (frontend/debugger.c3): the CPU's reads and
// writes of chosen addresses (Cpu.read, Cpu.write look while Mmu.watch is
// set). The first access that matches is kept, and the frame stops after
// that instruction (GameBoy.run_frame_breaking).

const char WATCH_READ  = 1;
const char WATCH_WRITE = 2;
const int  MAX_WATCHES = 8;

struct Watch {
	ushort at;
	char   mode;  // WATCH_READ | WATCH_WRITE
}

struct Watches {
	Watch[MAX_WATCHES] list;
	int    n;
	bool   hit;
	ushort hit_at;
	bool   hit_write;
	char   hit_value;
}

fn void Watches.check(&self, ushort addr, bool write, char value) {
	if (self.hit) return;
	for (int i = 0; i < self.n; i++) {
		Watch* w = &self.list[i];
		if (w.at == addr && (w.mode & (write ? WATCH_WRITE : WATCH_READ))) {
			self.hit = true;
			self.hit_at = addr;
			self.hit_write = write;
			self.hit_value = value;
			return;
		}
	}
}

// Watch `at` for `mode`, or stop watching it if it was watched just so.
fn void Watches.toggle(&self, ushort at, char mode) {
	for (int i = 0; i < self.n; i++) {
		if (self.list[i].at == at) {
			if (self.list[i].mode == mode) {
				self.list[i] = self.list[--self.n];
			} else {
				self.list[i].mode = mode;
			}
			return;
		}
	}
	if (self.n < MAX_WATCHES) self.list[self.n++] = { at, mode };
}
