module wer;
import std::io, std::io::file;
import gameboy, mmu, display, netlink, png;

// The link cable in the menu: off, a second Game Boy in this window (both
// pictures side by side), or another wer (or BGB) over the network.
enum LinkMode : char {
	OFF,
	LOCAL,  // two Game Boys here
	FOUR,   // four here, on the 4-Player Adapter
	PRINTER, // the Game Boy Printer: printouts become PNG files
	BARCODE, // the Barcode Boy: cards typed in by number
	HOST,   // waiting for, or linked with, a side that joined
	JOIN,   // linked with a side that hosts
}

const String[7] LINK_LABELS = { "Off", "2 players here", "4 players here", "Printer", "Barcode Boy", "Host", "Join" };

// Pixels between the two pictures.
const int LINK_GAP = 8;

LinkMode link_mode;
LinkMode link_pick;      // the menu's choice, applied with Enter
netlink::NetLink net;

// FOUR: players 2-4 (gb2 is player 2) and the adapter between all four.
gameboy::GameBoy gb3;
gameboy::GameBoy gb4;
mmu::Adapter adapter;
char[] rgb3;
char[] rgb4;

// BARCODE: the reader and its cable.
mmu::BarcodeBoy barcode;
mmu::Link barcode_cable;
bool typing_card;        // the text being typed is a card number

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

// A card number typed in: through the reader.
fn void swipe(String digits) {
	if (!digits.len) return;
	if (catch barcode.swipe_card(digits, gb.mmu.rt_clock)) {
		notice.show("A card number has 13 digits");
		return;
	}
	menu = false;
	notice.show("Card swiped");
}

// The Swipe card line, then asking for the number.
fn String swipe_line() => typing && typing_card ? string::tformat("Card: %s_", (String)typed[:typed_len]) : "Swipe card...";

fn void swipe_ask() {
	$if env::EMSCRIPTEN:
		display::run_script("werCardPrompt()");
	$else
		typing = true;
		typing_card = true;
		typed_len = 0;
		screen.start_text();
	$endif
}

fn void web_swipe(ZString code) @export("wer_barcode_swipe") @feat(EMSCRIPTEN) => swipe(code.str_view().trim());

fn String link_line() {
	if (typing && !typing_cheat && !typing_card) return string::tformat("Join: %s_", (String)typed[:typed_len]);
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
	if (link_mode == FOUR) {
		gb3.destroy();
		gb4.destroy();
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
		case FOUR:
			link_four();
		case PRINTER:
			link_printer();
		case BARCODE:
			link_stop();
			barcode.init((uint)gb.mmu.model.clock_hz());
			gb.mmu.connect_barcode(&barcode_cable, &barcode);
			link_mode = BARCODE;
			notice.show("Barcode Boy: Menu > Swipe card");
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
			$else
				typing = true;
				typed_len = 0;
				foreach (c : cfg.link) if (typed_len < typed.len) typed[typed_len++] = c;
				screen.start_text();
			$endif
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
		typing_card = false;
		screen.stop_text();
	} else if (in.pressed & display::KEY_ENTER && typing_card) {
		typing = false;
		typing_card = false;
		screen.stop_text();
		swipe((String)typed[:typed_len]);
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
		case FOUR:
			link_four();
		case PRINTER:
			gb.mmu.connect_printer(&printer_cable, &printer);
		case BARCODE:
			gb.mmu.connect_barcode(&barcode_cable, &barcode);
		case HOST:
		case JOIN:
			net.replug(&gb.mmu);
		default:
			break;
	}
}

// Four copies of the running game on the 4-Player Adapter (each its own
// battery save: game-2.sav ... game-4.sav).
fn void link_four() {
	if (!rom_path.len) {
		notice.show("Open the game first");
		return;
	}
	char[]? data = file::load_temp(rom_path);
	if (catch data) data = display::load_file_temp(rom_path);
	if (catch data) return;
	link_stop();
	gameboy::GameBoy*[3] others = { &gb2, &gb3, &gb4 };
	foreach (i, o : others) {
		*o = gameboy::new(boot, gb.mmu.model);
		o.set_cgb_revision(mode.revision());
		o.set_dmg_revision(mode.dmg_revision());
		apply_preset(o, pal);
		o.load_rom_named(data, string::tformat("%s-%d", save_base, i + 2));
	}
	has_p2 = true;
	adapter.init((uint)gb.mmu.model.clock_hz());
	link_mode = FOUR;
	screen.two_players = true;
	keyboard_player = 0;
	notice.show("4 players: gamepads 1-4, ` moves the keyboard");
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
	if (link_mode == FOUR) {
		gameboy::GameBoy*[4] g = { &gb, &gb2, &gb3, &gb4 };
		for (int p = 0; p < 4; p++) {
			char b = in.pad_buttons[p];
			char d = in.pad_dpad[p];
			if (p == keyboard_player) {
				b |= in.kb_buttons;
				d |= in.kb_dpad;
			}
			g[p].mmu.set_input(b, d);
		}
		gameboy::run_four_frame(g, &adapter);
		short[4096] discard;
		for (int p = 1; p < 4; p++) g[p].audio(&discard);
		return;
	}
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
	if (link_mode == BARCODE) {
		gb.run_frame_polled(fn (ctx) { barcode.tick(&gb.mmu); }, null, 16);
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
	if (link_mode == FOUR) return four_picture(a, out);
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
fn void web_join_code(ZString code) @export("wer_net_join_code") @feat(EMSCRIPTEN) {
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

// The four pictures, two by two, player 1 top left.
fn gameboy::FrameSize four_picture(gameboy::FrameSize a, char[]* out) {
	if (!rgb2.len) {
		rgb2 = mem::new_array(char, gameboy::MAX_FRAME_RGB);
		both = mem::new_array(char, display::MAX_W * display::MAX_H * 3);
	}
	if (!rgb3.len) {
		rgb3 = mem::new_array(char, gameboy::MAX_FRAME_RGB);
		rgb4 = mem::new_array(char, gameboy::MAX_FRAME_RGB);
	}
	char[][4] px = { rgb, rgb2, rgb3, rgb4 };
	gameboy::GameBoy*[4] g = { &gb, &gb2, &gb3, &gb4 };
	gameboy::FrameSize[4] size;
	size[0] = a;
	for (int p = 1; p < 4; p++) size[p] = g[p].frame_rgb(px[p], colors);
	int cw = a.w;
	int ch = a.h;
	foreach (s : size) {
		if (s.w > cw) cw = s.w;
		if (s.h > ch) ch = s.h;
	}
	int w = cw * 2 + LINK_GAP;
	int h = ch * 2 + LINK_GAP;
	both[:(usz)(w * h * 3)] = 0x10;
	for (int p = 0; p < 4; p++) {
		int x0 = (p & 1) * (cw + LINK_GAP) + (cw - size[p].w) / 2;
		int y0 = (p >> 1) * (ch + LINK_GAP) + (ch - size[p].h) / 2;
		for (int y = 0; y < size[p].h; y++) {
			both[(usz)(((y0 + y) * w + x0) * 3) : (usz)(size[p].w * 3)] = px[p][(usz)(y * size[p].w * 3) : (usz)(size[p].w * 3)];
		}
	}
	*out = both;
	return { w, h };
}
