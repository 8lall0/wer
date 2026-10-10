module wer;
import std::io, std::io::file;
import gameboy, mmu, display;

// The GB KISS LINK (mmu::KissLink) in the menu: Link > GB KISS LINK plugs
// it in. A map Nectaris GB sends ("send to PC") is saved next to the game
// as game-map-N.bin (512 bytes, the game's own format); when the game asks
// for one ("receive from PC") it gets the one picked on the Map line,
// the newest at first.
//
// GB KISS files (.gbf): one the GB KISS menu sends (its Send command) is
// saved as game-kiss-N.gbf; when the menu receives (Start, or its Receive
// command) it gets the one picked on the File line: a .gbf opened or
// dropped on the window, or one received before.

mmu::KissLink kiss;
mmu::Link kiss_cable;
int kiss_pick;           // the Map line's choice: game-map-N.bin, 0 = none
String kiss_dropped;     // a .gbf opened or dropped on the window (heap)
int kiss_file;           // the File line's choice: 0 the dropped one, N game-kiss-N.gbf, -1 none

fn String kiss_gbf_path(int n) => n ? string::tformat("%s-kiss-%d.gbf", save_base.len ? save_base : "wer", n) : kiss_dropped;

fn int kiss_gbf_newest() {
	int n = 0;
	while (file::is_file(kiss_gbf_path(n + 1))) n++;
	return n;
}

// The picked file, ready to go to the menu.
fn void kiss_load_file() {
	kiss.has_gbf = false;
	if (kiss_file < 0) return;
	String path = kiss_gbf_path(kiss_file);
	if (!path.len) return;
	if (try data = file::load_temp(path)) {
		if (catch kiss.set_gbf(data)) notice.show("Not a GB KISS file");
	}
}

// A .gbf opened or dropped: the file to send.
fn void kiss_open(String path) {
	if (link_mode != KISS) {
		link_stop();
		kiss_plug();
	}
	if (kiss_dropped.len) free(kiss_dropped.ptr);
	kiss_dropped = path.copy(mem);
	kiss_file = 0;
	kiss_load_file();
	if (kiss.has_gbf) notice.show(string::tformat("%s: in the GB KISS menu, Start", file_name(path)));
}

fn String kiss_file_line() {
	if (kiss_file < 0 || !kiss_gbf_path(kiss_file).len) return "File: none yet";
	return string::tformat("File: < %s >", file_name(kiss_gbf_path(kiss_file)));
}

fn void kiss_file_step(int step) {
	int n = kiss_gbf_newest() + 1;   // the dropped one, then the received ones
	if (n == 1 && !kiss_dropped.len) return;
	int at = kiss_file < 0 ? 0 : kiss_file;
	do {
		at = (at + step + n) % n;
	} while (at == 0 && !kiss_dropped.len);
	kiss_file = at;
	kiss_load_file();
}

fn String kiss_map_path(int n) => string::tformat("%s-map-%d.bin", save_base.len ? save_base : "wer", n);

// The newest map file (its number), or 0.
fn int kiss_newest() {
	int n = 0;
	while (file::is_file(kiss_map_path(n + 1))) n++;
	return n;
}

// The picked map, ready to go to the game.
fn void kiss_load_pick() {
	kiss.has_map = false;
	if (!kiss_pick) return;
	char[]? data = file::load_temp(kiss_map_path(kiss_pick));
	if (try data) kiss.set_map(data);
}

fn void kiss_plug() {
	if (has_rom && gb.mmu.cart && gb.mmu.cart.mbc != HUC1 && gb.mmu.cart.mbc != HUC3) {
		notice.show("For HuC-1/HuC-3 games (Nectaris GB)");
	} else {
		notice.show("GB KISS LINK: the game's GB KISS menu");
	}
	kiss.init();
	kiss_pick = kiss_newest();
	kiss_load_pick();
	kiss_file = kiss_dropped.len ? 0 : kiss_gbf_newest() ? kiss_gbf_newest() : -1;
	kiss_load_file();
	gb.mmu.connect_kiss(&kiss_cable, &kiss);
	link_mode = KISS;
}

// After each frame: a map that came in is saved; what happened is shown.
fn void kiss_poll() {
	if (kiss.received) {
		kiss.received = false;
		int n = kiss_newest() + 1;
		String path = kiss_map_path(n);
		if (catch file::save(path, &kiss.map)) {
			notice.show("Could not save the map");
			return;
		}
		sz slash = path.rindex_of_char('/') ?? -1;
		io::printfn("wrote %s", path);
		String name = mmu::kiss_map_name(&kiss.map);
		notice.show(string::tformat("Map %s saved: %s", name, path[slash + 1..]));
		$if env::EMSCRIPTEN:
			display::run_script(string::tformat("werDownload('%s')", path).zstr_tcopy());
		$endif
		kiss_pick = n;
	}
	if (kiss.sent) {
		kiss.sent = false;
		notice.show(string::tformat("Map %s sent", mmu::kiss_map_name(&kiss.map)));
	}
	if (kiss.gbf_received) {
		kiss.gbf_received = false;
		int n = kiss_gbf_newest() + 1;
		String path = kiss_gbf_path(n);
		if (catch file::save(path, kiss.out_gbf[:kiss.out_len])) {
			notice.show("Could not save the file");
			return;
		}
		io::printfn("wrote %s", path);
		notice.show(string::tformat("File saved: %s", file_name(path)));
		$if env::EMSCRIPTEN:
			display::run_script(string::tformat("werDownload('%s')", path).zstr_tcopy());
		$endif
	}
	if (kiss.gbf_sent) {
		kiss.gbf_sent = false;
		notice.show("File sent");
	}
	if (kiss.status == "the menu wants a file: none to send") {
		kiss.status = "";
		notice.show("No file to send: drop a .gbf on the window");
	}
	if (kiss.status == "the game wants a map: none to send") {
		kiss.status = "";
		notice.show("No map to send: get one from the game first");
	}
}

// The Map line: which map goes to the game (Left/Right).
fn String kiss_map_line() {
	if (!kiss_pick) return "Map: none yet";
	String name;
	if (try data = file::load_temp(kiss_map_path(kiss_pick))) name = mmu::kiss_map_name(data);
	return string::tformat("Map: < %s >", name.len ? name : string::tformat("map %d", kiss_pick));
}

fn void kiss_map_step(int step) {
	int n = kiss_newest();
	if (!n) return;
	kiss_pick = (kiss_pick - 1 + step + n) % n + 1;
	kiss_load_pick();
}
