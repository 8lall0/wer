module wer @feat(ANDROID);

// Android: SDL's Java activity (org.libsdl.app.SDLActivity) loads libmain.so
// and calls SDL_main on its own thread, which needs its own temp allocator
// (C3 makes one by itself only on the thread that loaded the program).
fn CInt sdl_main(CInt argc, ZString* argv) @export("SDL_main") {
	CInt result;
	@pool_init(mem, 4 * mem::MB) {
		String[] args = mem::temp_array(String, (sz)argc);
		for (CInt i = 0; i < argc; i++) args[i] = argv[i].str_view();
		result = (CInt)main(args);
	};
	return result;
}
