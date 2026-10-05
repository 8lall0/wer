module display @feat(EMSCRIPTEN);

// The browser has no file dialog SDL can show: the page (web/shell.html)
// offers a file input, writes the chosen ROM into Emscripten's in-memory
// filesystem and hands its path back through wer_rom_chosen.
extern fn void run_script(ZString script) @cname("emscripten_run_script");

fn void web_pick_rom() => run_script("werPickRom()");

fn void rom_chosen(ZString path) @export("wer_rom_chosen") {
	ZString[2] files = { path, null };
	on_dialog(null, path ? &files : null, 0);
}
