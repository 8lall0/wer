module wer @feat(WIN32);
import libc;

// Windows: wer.exe is a GUI program (no console window of its own); started
// from a terminal, it prints there, as --headless and the error messages do.
extern fn CInt attach_console(uint pid) @cname("AttachConsole");
fn void use_parent_console() {
	if (attach_console(0xFFFFFFFF) == 0) return; // ATTACH_PARENT_PROCESS
	libc::freopen("CONOUT$", "w", libc::stdout());
	libc::freopen("CONOUT$", "w", libc::stderr());
}

// Windows: the whole command line, program name first as elsewhere (a
// WinMain entry gets the arguments only).
extern fn Char16* get_command_line() @cname("GetCommandLineW");
extern fn Char16** command_line_to_argv(Char16* line, CInt* argc) @cname("CommandLineToArgvW");
fn String[] windows_args() {
	CInt argc;
	Char16** argv = command_line_to_argv(get_command_line(), &argc);
	String[] list = mem::temp_array(String, (sz)argc);
	for (CInt i = 0; i < argc; i++) {
		usz n = 0;
		while (argv[i][n]) n++;
		list[i] = string::from_utf16(tmem, argv[i][:n]) ?? "";
	}
	return list;
}
