module display @feat(EMSCRIPTEN);
import sdl;

// The browser has no file dialog SDL can show: the page (web/shell.html)
// offers a file input, writes the chosen ROM into Emscripten's in-memory
// filesystem and hands its path back through wer_rom_chosen.
extern fn void run_script(ZString script) @cname("emscripten_run_script");

fn void web_pick_rom() => run_script("werPickRom()");

fn void rom_chosen(ZString path) @export("wer_rom_chosen") {
	ZString[2] files = { path, null };
	on_dialog(null, path ? &files : null, 0);
}

extern fn CInt run_script_int(ZString script) @cname("emscripten_run_script_int");

// A touch-first screen (phone, tablet): the browser's coarse pointer.
fn bool web_touch_screen() => run_script_int("matchMedia('(pointer: coarse)').matches ? 1 : 0") != 0;

// On-screen controls (touch.c3), with the canvas filling the page (SDL hides
// the rest of it and follows the browser window's size and rotation).
fn void Display.web_touch_mode(&self) {
	self.touch_ui = true;
	sdl::set_window_fill_document(self.window, true);
	// The page's own CSS would still size it as on a desktop.
	run_script("var c = document.getElementById('canvas'); c.style.width = '100vw'; c.style.height = '100dvh'; c.style.aspectRatio = 'auto';");
}
