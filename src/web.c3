module wer @feat(EMSCRIPTEN);
import std::time;

// WebAssembly: a browser page can't loop forever. The browser calls web_tick
// at each display refresh, and it runs the main loop's frame() whenever a
// Game Boy frame's time (59.73 per second) has built up, so 60, 120 or
// 144 Hz screens all see 60 frames a second (on a 60 Hz one, one per
// refresh: 0.45% fast, which the audio rate control evens out).
alias LoopFn = fn void();
extern fn void set_main_loop(LoopFn f, CInt fps, bool simulate_infinite_loop) @cname("emscripten_set_main_loop");
extern fn void cancel_main_loop() @cname("emscripten_cancel_main_loop");

Clock last_tick;
NanoDuration owed; // emulated time the display is waiting for

fn void web_run() {
	last_tick = clock::now();
	set_main_loop(&web_tick, 0, true); // 0: at the display's refresh rate
}

fn void web_tick() {
	Clock now = clock::now();
	NanoDuration elapsed = now - last_tick;
	last_tick = now;
	if (elapsed > (NanoDuration)100_000_000) elapsed = (NanoDuration)100_000_000; // a hidden tab
	owed += elapsed;
	NanoDuration period = frame_period(gb.mmu.model);
	if (owed < period * 95 / 100) return; // a faster screen: not this refresh
	owed -= period;
	if (owed < (NanoDuration)0) owed = (NanoDuration)0;
	if (!frame()) cancel_main_loop();
}

// Frames emulated so far (for the page, e.g. to measure the speed).
fn ulong frames_emulated() @export("wer_frames") => frames_run;

// The page calls this before it copies the files to IndexedDB (every few
// seconds, and when the tab is hidden or closed): the battery save first.
fn void save_battery() @export("wer_save") {
	if (gb.mmu.cart) gb.mmu.cart.save();
}
