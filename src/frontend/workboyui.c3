module wer;
import mmu, display;

// The WorkBoy on the link port (Menu > Link > WorkBoy, --link=workboy). Once
// its program talks to it, the computer's keyboard is the WorkBoy's: typed
// characters, F1-F9 its nine tools, the arrows, Enter, Backspace, Esc.
// Shift+Esc (or a gamepad) opens wer's menu. Its clock is the computer's
// local time plus what the program set it to (wer.conf: workboy-clock).

mmu::WorkBoy workboy;
mmu::Link workboy_cable;
bool workboy_typing;     // the keyboard types on it (text input on)
bool workboy_told;       // the notice about it was shown

fn void workboy_plug() {
	workboy.init(cfg.workboy_clock);
	gb.mmu.connect_workboy(&workboy_cable, &workboy);
	link_mode = WORKBOY;
	workboy_told = false;
	notice.show("WorkBoy: start the WorkBoy program");
}

// The game restarted: the keyboard waits for its program again.
fn void workboy_replug() {
	workboy.init(workboy.offset);
	gb.mmu.connect_workboy(&workboy_cable, &workboy);
}

// Each poll, before the menu sees it: while the program runs and the menu
// is closed, the keys go to the WorkBoy.
fn void workboy_keys(display::Input* in) {
	bool on = link_mode == WORKBOY && workboy.active() && !menu && !typing && has_rom;
	if (on != workboy_typing) {
		workboy_typing = on;
		if (on) {
			screen.start_text();
			if (!workboy_told) notice.show("Typing on the WorkBoy (Shift+Esc: menu)");
			workboy_told = true;
		} else {
			screen.stop_text();
		}
	}
	if (!on) return;
	for (int i = 0; i < in.text_len; i++) workboy.press(mmu::workboy_key(in.text[i]));
	if (in.fkey >= 1 && in.fkey <= 9) workboy.press((char)(mmu::WORKBOY_CLOCK + in.fkey - 1));
	if (in.pressed & display::KEY_UP) workboy.press(mmu::WORKBOY_UP);
	if (in.pressed & display::KEY_DOWN) workboy.press(mmu::WORKBOY_DOWN);
	if (in.pressed & display::KEY_LEFT) workboy.press(mmu::WORKBOY_LEFT);
	if (in.pressed & display::KEY_RIGHT) workboy.press(mmu::WORKBOY_RIGHT);
	if (in.pressed & display::KEY_ENTER) workboy.press(mmu::WORKBOY_ENTER);
	if (in.pressed & display::KEY_BACKSPACE) workboy.press(mmu::WORKBOY_BACKSPACE);
	if (in.esc) {
		workboy.press(mmu::WORKBOY_ESCAPE);
		in.pressed &= (ushort)~display::KEY_MENU;
	}
	in.pressed &= display::KEY_MENU; // the rest was typed on the WorkBoy
}

// After each frame: a clock the program set is kept for next time.
fn void workboy_poll() {
	if (!workboy.clock_set) return;
	workboy.clock_set = false;
	cfg.workboy_clock = workboy.offset;
	save_settings(&cfg, mode, pal, scale);
	notice.show("WorkBoy clock set");
}
