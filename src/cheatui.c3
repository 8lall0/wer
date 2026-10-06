module wer;
import std::io, std::io::file;
import gameboy, mmu, display;

// Cheat codes in the menu, kept per game in a text file next to its saves
// (game.cht): a code per line, maybe followed by what it does; a line
// starting with # is switched off.
//
//   00A-17B-C49  Infinite lives
//   # 010538C1   Max money

mmu::Cheats cheats;
String[mmu::MAX_CHEATS] cheat_lines; // each code as written, with its description (heap)
bool cheat_menu;                     // the Cheats submenu is showing
bool typing_cheat;                   // the text being typed is a new code

fn String cheats_path() => save_base.tconcat(".cht");

fn void cheats_clear() {
	foreach (&l : cheat_lines[:cheats.count]) {
		free(l.ptr);
		*l = "";
	}
	cheats = {};
}

// The game's codes, plugged into its Game Boy.
fn void cheats_load(gameboy::GameBoy* g) {
	cheats_clear();
	g.mmu.cheats = &cheats;
	char[]? text = file::load_temp(cheats_path());
	if (catch text) return;
	foreach (raw : ((String)text).tsplit("\n")) {
		String line = raw.trim();
		bool on = true;
		if (line.starts_with("#")) {
			on = false;
			line = line[1..].trim();
		}
		if (!line.len) continue;
		if (catch cheat_add(line, on, false)) io::eprintfn("%s: not a cheat code: %s", cheats_path(), line);
	}
}

fn void cheats_save() {
	DString out;
	out.init(tmem);
	for (int i = 0; i < cheats.count; i++) {
		out.appendf("%s%s\n", cheats.list[i].on ? "" : "# ", cheat_lines[i]);
	}
	if (catch file::save(cheats_path(), out.str_view())) notice.show("Could not save the cheats");
}

// A code (and what follows it: its description).
fn void? cheat_add(String line, bool on = true, bool save = true) {
	String code = line;
	if (try sp = line.index_of_char(' ')) code = line[:sp];
	// "ABC-DEF GHI"-style spacing inside a Game Genie code: take it all if it parses.
	if (catch mmu::parse_cheat(code)) code = line;
	cheats.add(code)!;
	cheat_lines[cheats.count - 1] = line.copy(mem);
	cheats.list[cheats.count - 1].on = on;
	cheats.recount();
	if (save) cheats_save();
}

const String CHEAT_ADD = "Add code...";

// The Cheats submenu: the codes (Enter switches one on or off), then
// "Add code..." and "Back". Fills `lines`, returns how many.
fn int cheat_menu_lines(display::Input* in, String[] lines, int* sel) {
	int count = cheats.count + 2;
	if (count > lines.len) count = (int)lines.len;
	int add = count - 2;
	int back = count - 1;
	if (!typing) {
		if (in.pressed & display::KEY_UP)   *sel = (*sel + count - 1) % count;
		if (in.pressed & display::KEY_DOWN) *sel = (*sel + 1) % count;
		if (in.pressed & display::KEY_ENTER) {
			switch {
				case *sel == back:
					cheat_menu = false;
					*sel = 0;
				case *sel == add:
					$if env::EMSCRIPTEN:
						display::run_script("werCheatPrompt()");
					$else
						typing = true;
						typing_cheat = true;
						typed_len = 0;
						screen.start_text();
					$endif
				default:
					cheats.list[*sel].on = !cheats.list[*sel].on;
					cheats.recount();
					cheats_save();
			}
		}
	}
	for (int i = 0; i < add; i++) {
		lines[i] = string::tformat("[%s] %s", cheats.list[i].on ? "on " : "off", cheat_lines[i]);
	}
	lines[add] = typing && typing_cheat ? string::tformat("Code: %s_", (String)typed[:typed_len]) : CHEAT_ADD;
	lines[back] = "Back";
	return cheat_menu ? count : 0;
}

// Browser: the code typed in the page's prompt.
fn void web_cheat(ZString code) @export("wer_cheat_add") @if(env::EMSCRIPTEN) {
	String c = code.str_view().trim();
	if (!c.len) return;
	if (catch cheat_add(c)) notice.show("Not a Game Genie or GameShark code");
}
