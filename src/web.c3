module wer @feat(EMSCRIPTEN);
import std::time;

// WebAssembly: a browser page can't loop forever. The browser calls web_tick
// at each display refresh, and it runs the main loop's frame() for the Game
// Boy frames (59.73 per second) whose time has come: on a 60 Hz screen one
// per refresh (0.45% fast, which the audio rate control evens out), on 120
// or 144 Hz screens one every few. When a refresh comes late (a slow phone,
// a busy page) it catches up with up to MAX_CATCH_UP frames, drawing only
// the last, so the game keeps its speed; further behind, it lets it go.
alias LoopFn = fn void();
extern fn void set_main_loop(LoopFn f, CInt fps, bool simulate_infinite_loop) @cname("emscripten_set_main_loop");
extern fn void cancel_main_loop() @cname("emscripten_cancel_main_loop");

const int MAX_CATCH_UP = 3;
Clock last_tick;
NanoDuration owed; // emulated time the display is waiting for

fn void web_run() {
	last_tick = clock::now();
	set_main_loop(&web_tick, 0, true); // 0: at the display's refresh rate
}

// For index.html?fps: the longest tick (wer's own work) and the longest
// time between ticks since the page last asked.
long longest_work_ns;
long longest_gap_ns;
fn double take_longest_work() @export("wer_longest_work") {
	double ms = longest_work_ns / 1e6;
	longest_work_ns = 0;
	return ms;
}
fn double take_longest_gap() @export("wer_longest_gap") {
	double ms = longest_gap_ns / 1e6;
	longest_gap_ns = 0;
	return ms;
}

fn void web_tick() {
	Clock now = clock::now();
	if ((long)(now - last_tick) > longest_gap_ns) longest_gap_ns = (long)(now - last_tick);
	NanoDuration elapsed = now - last_tick;
	last_tick = now;
	if (elapsed > (NanoDuration)250_000_000) elapsed = (NanoDuration)250_000_000; // a hidden tab
	owed += elapsed;
	NanoDuration period = frame_period(gb.mmu.model);
	int n = 0;
	while (owed >= period * 95 / 100 && n < MAX_CATCH_UP) {
		owed -= period;
		n++;
	}
	if (owed > period) owed = period;   // too far behind to catch up: let it go
	if (owed < (NanoDuration)0) owed = (NanoDuration)0;
	for (int i = 0; i < n; i++) {
		skip_picture = i < n - 1;
		if (!frame()) {
			skip_picture = false;
			cancel_main_loop();
			return;
		}
	}
	skip_picture = false;
	long work = (long)(clock::now() - now);
	if (work > longest_work_ns) longest_work_ns = work;
}

// Frames emulated so far (for the page, e.g. to measure the speed).
fn ulong frames_emulated() @export("wer_frames") => frames_run;

// The page calls this before it copies the files to IndexedDB (every few
// seconds, and when the tab is hidden or closed): the battery save first.
fn void save_battery() @export("wer_save") {
	if (gb.mmu.cart) gb.mmu.cart.save();
}
