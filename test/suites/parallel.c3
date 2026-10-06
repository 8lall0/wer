module parallel;

import std::thread, std::os, std::atomic;

// Runs the test ROM suites' independent checks on every CPU. Each check builds
// its own machine; the emulator has no shared mutable state, and the temp
// allocator is per thread.

alias Job = fn void(void* ctx, usz index);

const int MAX_THREADS = 64;

struct Work {
	Job  job;
	void* ctx;
	usz  count;
	Atomic{usz} next;
}

fn int worker(void* arg) {
	Work* w = arg;
	// A new thread has no temp allocator until it makes one.
	@pool_init(mem, 16 * 1024 * 1024) {
		while (true) {
			usz i = w.next.add(1);
			if (i >= w.count) break;
			@pool() {
				w.job(w.ctx, i);
			};
		}
	};
	return 0;
}

// job(ctx, i) for every i below count, spread over the CPUs (WER_THREADS=n
// sets how many threads; 1 runs everything here, in order).
fn void run(usz count, Job job, void* ctx) {
	int n = os::num_cpu();
	if (try t = std::os::env::tget_var("WER_THREADS").to_int()) n = t;
	if (n < 1) n = 1;
	if (n > MAX_THREADS) n = MAX_THREADS;
	if (n > (int)count) n = (int)count;

	Work w = { .job = job, .ctx = ctx, .count = count };
	if (n <= 1) {
		while (true) {
			usz i = w.next.add(1);
			if (i >= w.count) return;
			@pool() {
				job(ctx, i);
			};
		}
	}
	Thread[MAX_THREADS] threads;
	// Each check keeps a whole GameBoy on its stack.
	for (int i = 0; i < n; i++) threads[i].create(&worker, &w, { .stack_size = 16 * 1024 * 1024 })!!;
	for (int i = 0; i < n; i++) (void)threads[i].join();
}
