module wer @feat(ANDROID);

// Android: SDL's Java activity (org.libsdl.app.SDLActivity) loads libmain.so
// and calls SDL_main on its own thread.
fn CInt sdl_main(CInt argc, ZString* argv) @export("SDL_main") {
	String[] args = mem::temp_array(String, (sz)argc);
	for (CInt i = 0; i < argc; i++) args[i] = argv[i].str_view();
	return (CInt)main(args);
}
