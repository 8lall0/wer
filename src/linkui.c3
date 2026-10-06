module wer;
import std::io, std::io::file;
import gameboy, mmu, display, netlink, png;

// The link cable in the menu: off, a second Game Boy in this window (both
// pictures side by side), or another wer (or BGB) over the network.
enum LinkMode : char {
	OFF,
	LOCAL,  // two Game Boys here
	PRINTER, // the Game Boy Printer: printouts become PNG files
	HOST,   // waiting for, or linked with, a side that joined
	JOIN,   // linked with a side that hosts
}

const String[5] LINK_LABELS = { "Off", "2 players here", "Printer", "Host", "Join" };

// Pixels between the two pictures.
const int LINK_GAP = 8;

LinkMode link_mode;
LinkMode link_pick;      // the menu's choice, applied with Enter
netlink::NetLink net;

// PRINTER: the printer and its cable.
mmu::Printer printer;
mmu::Link printer_cable;
bool printer_on;

// LOCAL: the second Game Boy and the cable between them.
gameboy::GameBoy gb2;
gameboy::Cartridge cart2;
bool has_p2;
String p2_path;
mmu::Link cable1;
mmu::Link cable2;
int keyboard_player;     // 0 or 1: who the keyboard, touch and first gamepad play
bool dialog_p2;          // the open file dialog picks player 2's game
char[] rgb2;             // player 2's picture
char[] both;             // the two side by side

// JOIN: the address being typed.
bool typing;
char[64] typed;
int typed_len;

fn bool link_available(LinkMode m) => true;

fn void link_step(int step) {
	int n = (int)LINK_LABELS.len;
	do {
		link_pick = (LinkMode)(((int)link_pick.ordinal + n + step) % n);
	} while (!link_available(link_pick));
}

fn String link_line() {
	if (typing) return string::tformat("Join: %s_", (String)typed[:typed_len]);
	// The choice only takes effect with Enter: say so until it has.
	String state;
	if (link_pick != link_mode) {
		state = link_pick == OFF ? "  Enter: unplug" : "  Enter: plug in";
	} else {
		switch (link_mode) {
			case HOST:    state = net.connected() ? "  linked" : "  waiting";
			case JOIN:    state = net.connected() ? "  linked" : net.state == CONNECTING ? "  connecting" : "  lost";
			case PRINTER:
			case LOCAL:   state = "  on";
			default:      break;
		}
	}
	return string::tformat("Link:    < %s >%s", LINK_LABELS[link_pick.ordinal], state);
}

// Unplug everything.
fn void link_stop() {
	net.close(&gb.mmu);
	if (has_p2) {
		gb2.destroy();
		has_p2 = false;
	}
	gb.mmu.unplug();
	if (printer_on) printer.free();
	printer_on = false;
	screen.two_players = false;
	link_mode = OFF;
	keyboard_player = 0;
}

// Enter on the Link line.
fn void link_apply() {
	switch (link_pick) {
		case OFF:
			link_stop();
			notice.show("Link cable unplugged");
		case PRINTER:
			link_printer();
		case LOCAL:
			// The second game comes from the file dialog (link_second_chosen).
			dialog_p2 = true;
			screen.open_rom_dialog();
		case HOST:
			link_stop();
			if (catch net.host(netlink::DEFAULT_PORT, &gb.mmu)) {
				notice.show("Can't listen on port 8765");
				return;
			}
			link_mode = HOST;
			notice.show(env::EMSCRIPTEN ? "Waiting: the code is on the page" : "Waiting on port 8765");
		case JOIN:
			$if env::EMSCRIPTEN:
				// The page asks for the code (a phone's keyboard comes up for it).
				display::run_script("werNetAskJoin()");
				return;
			$endif
			typing = true;
			typed_len = 0;
			foreach (c : cfg.link) if (typed_len < typed.len) typed[typed_len++] = c;
			screen.start_text();
	}
}

// Typing the address to join: text, Backspace, Enter (join), Esc (cancel).
// True while it takes the input.
fn bool link_typing(display::Input* in) {
	if (!typing) return false;
	for (int i = 0; i < in.text_len && typed_len < typed.len; i++) {
		// A cheat's description may have spaces; an address can't.
		if (in.text[i] > ' ' || (typing_cheat && in.text[i] == ' ')) typed[typed_len++] = in.text[i];
	}
	if ((in.pressed & display::KEY_BACKSPACE) && typed_len > 0) typed_len--;
	if (in.pressed & display::KEY_MENU) {
		typing = false;
		typing_cheat = false;
		screen.stop_text();
	} else if (in.pressed & display::KEY_ENTER && typing_cheat) {
		typing = false;
		typing_cheat = false;
		screen.stop_text();
		String code = (String)typed[:typed_len];
		if (code.len && @catch(cheat_add(code))) notice.show("Not a Game Genie or GameShark code");
	} else if (in.pressed & display::KEY_ENTER) {
		typing = false;
		screen.stop_text();
		String address = (String)typed[:typed_len];
		if (!address.len) return true;
		cfg.set("link", address);
		save_settings(&cfg, mode, pal, scale);
		link_stop();
		if (catch net.join(address, &gb.mmu)) {
			notice.show("Couldn't reach it");
			return true;
		}
		link_mode = JOIN;
		menu = false;
		notice.show(env::EMSCRIPTEN ? "Connecting..." : "Linked");
	}
	in.pressed = 0;
	return true;
}

// Player 2's game, chosen in the dialog. The same file as player 1's keeps
// its battery save and states apart ("-2").
fn void link_second_chosen(String path) {
	char[]? data = file::load_temp(path);
	if (catch data) data = display::load_file_temp(path);
	if (catch data) {
		notice.show("Could not load that ROM");
		return;
	}
	net.close(&gb.mmu);
	if (has_p2) gb2.destroy();
	mmu::Model model = gb.mmu.model;
	if (model != CGB && gameboy::requires_cgb(data)) model = CGB;
	gb2 = gameboy::new(boot, model);
	gb2.set_cgb_revision(mode.revision());
	gb2.set_dmg_revision(mode.dmg_revision());
	apply_preset(&gb2, pal);
	String base = gameboy::save_base(path, data);
	if (base == save_base) {
		gameboy::migrate_saves(path.tconcat("-2"), base.tconcat("-2"));
		base = base.tconcat("-2");
	} else {
		gameboy::migrate_saves(path, base);
	}
	cart2 = gb2.load_rom_named(data, base);
	has_p2 = true;
	if (p2_path.len) free(p2_path.ptr);
	p2_path = path.copy(mem);
	mmu::connect_local(&gb.mmu, &cable1, &gb2.mmu, &cable2);
	screen.two_players = true;
	link_mode = LOCAL;
	keyboard_player = 0;
	notice.show("Linked: ` switches the keyboard");
}

// Player 1's Game Boy was replaced (another game, Reset, the model): the
// cable goes back in; a second Game Boy here restarts too.
fn void link_replug() {
	switch (link_mode) {
		case LOCAL:
			if (p2_path.len) {
				String path = p2_path.tcopy();
				link_second_chosen(path);
			}
		case PRINTER:
			gb.mmu.connect_printer(&printer_cable, &printer);
		case HOST:
		case JOIN:
			net.replug(&gb.mmu);
		default:
			break;
	}
}

fn void link_printer() {
	link_stop();
	printer.init((uint)gb.mmu.model.clock_hz());
	printer_on = true;
	gb.mmu.connect_printer(&printer_cable, &printer);
	link_mode = PRINTER;
	notice.show("Printer connected");
}

// A finished printout: a PNG next to the game's saves (game-print-1.png,
// -2, ...); in a browser it downloads too.
fn void link_printout() {
	if (!printer_on) return;
	char[] page = printer.take_page(gb.mmu.rt_clock);
	if (!page.len) return;
	defer printer.clear_page();
	char[] grey = mem::temp_array(char, page.len);
	const char[4] SHADES = { 255, 170, 85, 0 };
	foreach (i, s : page) grey[i] = SHADES[s & 3];
	String path;
	for (int n = 1; n < 10000; n++) {
		path = string::tformat("%s-print-%d.png", save_base, n);
		if (!file::is_file(path)) break;
	}
	char[] data = png::grey(grey, mmu::PAPER_W, (int)(page.len / mmu::PAPER_W), tmem);
	if (catch file::save(path, data)) {
		notice.show("Could not save the printout");
		return;
	}
	io::printfn("printed %s", path);
	sz slash = path.rindex_of_char('/') ?? -1;
	notice.show(string::tformat("Printed %s", path[slash + 1..]));
	$if env::EMSCRIPTEN:
		display::run_script(string::tformat("werDownload('%s')", path).zstr_tcopy());
	$endif
}

// One frame of emulation with whatever is on the cable. The input goes to
// the keyboard's player, and the second gamepad's to the other.
fn void link_run_frame(display::Input* in) {
	if (link_mode == LOCAL && has_p2) {
		bool second = keyboard_player == 1;
		gb.mmu.set_input(second ? in.buttons2 : in.buttons, second ? in.dpad2 : in.dpad);
		gb2.mmu.set_input(second ? in.buttons : in.buttons2, second ? in.dpad : in.dpad2);
		gameboy::run_linked_frame(&gb, &gb2);
		short[4096] discard;
		gb2.audio(&discard); // one game's sound is enough
		return;
	}
	gb.mmu.set_input(in.buttons, in.dpad);
	if (printer_on) {
		gb.run_frame();
		link_printout();
		return;
	}
	if (net.state != OFF) {
		gb.run_frame_polled(fn (ctx) { (void)net.poll(&gb.mmu); }, null, 8);
		(void)net.poll(&gb.mmu);
		return;
	}
	gb.run_frame();
}

// The picture: player 1's, or both side by side (in `out`).
fn gameboy::FrameSize link_picture(char[]* out) {
	gameboy::FrameSize a = gb.frame_rgb(rgb, colors);
	*out = rgb;
	if (link_mode != LOCAL || !has_p2) return a;
	if (!rgb2.len) {
		rgb2 = mem::new_array(char, gameboy::MAX_FRAME_RGB);
		both = mem::new_array(char, display::MAX_W * display::MAX_H * 3);
	}
	gameboy::FrameSize b = gb2.frame_rgb(rgb2, colors);
	int w = a.w + LINK_GAP + b.w;
	int h = a.h > b.h ? a.h : b.h;
	both[:(usz)(w * h * 3)] = 0x10;
	for (int y = 0; y < a.h; y++) {
		int top = (h - a.h) / 2;
		both[(usz)(((top + y) * w) * 3) : (usz)(a.w * 3)] = rgb[(usz)(y * a.w * 3) : (usz)(a.w * 3)];
	}
	for (int y = 0; y < b.h; y++) {
		int top = (h - b.h) / 2;
		both[(usz)(((top + y) * w + a.w + LINK_GAP) * 3) : (usz)(b.w * 3)] = rgb2[(usz)(y * b.w * 3) : (usz)(b.w * 3)];
	}
	*out = both;
	return { w, h };
}

// Browser: the code the player typed in the page's prompt (empty: cancelled).
fn void web_join_code(ZString code) @export("wer_net_join_code") @if(env::EMSCRIPTEN) {
	String c = code.str_view();
	if (!c.len) return;
	link_stop();
	if (catch net.join(c, &gb.mmu)) {
		notice.show("That's not a link code");
		return;
	}
	link_mode = JOIN;
	link_pick = JOIN;
	menu = false;
	notice.show("Connecting...");
}
