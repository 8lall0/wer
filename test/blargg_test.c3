module blargg_test;

import gameboy;
import std::io;
import std::io::file;
import std::core::test;

// Blargg's dmg_sound test ROMs (sound hardware as the CPU can observe it).
//
// The ROMs are not vendored. Fetch them with
//   scripts/fetch-blargg.sh
// into test/blargg/dmg_sound/ . With none present the test prints one line
// and passes.
//
// Each ROM reports through cartridge RAM: $A001-$A003 = $DE $B0 $61 once the
// output is valid, $A000 = $80 while running, then the result (0 = pass), and
// a zero-terminated text at $A004 explaining a failure.
//
// Entries marked `true` must keep passing; the others are reported only.
// To see the report:
//   c3c test && ./build/testrun --test-nocapture --test-filter blargg

const String DIR = "test/blargg/dmg_sound/";

// Emulated time before a ROM counts as hung; the tests take a few seconds.
const int TIMEOUT_FRAMES = 60 * 40;

struct Rom {
	String name;
	bool   must_pass;
}

const Rom[*] ROMS = {
	{ "01-registers", true  },
	{ "02-len ctr", true  },
	{ "03-trigger", true  },
	{ "04-sweep", true  },
	{ "05-sweep details", true  },
	{ "06-overflow on trigger", true  },
	{ "07-len sweep period sync", true  },
	{ "08-len ctr during power", true  },
	{ "09-wave read while on", true  },
	{ "10-wave trigger while on", true  },
	{ "11-regs after power", true  },
	{ "12-wave write while on", true  },
};

enum Outcome : char {
	MISSING,
	PASS,
	FAIL,
	TIMEOUT,
}

// Runs one ROM; on failure `text` gets the ROM's own explanation.
fn Outcome run_rom(String path, char* code, String* text) {
	char[]? data = file::load_temp(path);
	if (catch data) return MISSING;

	gameboy::GameBoy gb = gameboy::new(false);
	defer gb.destroy();
	gb.load_rom_named(data, path);
	if (!gb.mmu.cart || gb.mmu.cart.ram.len < 0x100) return FAIL;
	gb.mmu.cart.has_battery = false; // never write .sav files
	char[] ram = gb.mmu.cart.ram;

	for (int f = 0; f < TIMEOUT_FRAMES; f++) {
		gb.run_frame();
		bool signed = ram[1] == 0xDE && ram[2] == 0xB0 && ram[3] == 0x61;
		if (!signed || ram[0] == 0x80) continue;
		*code = ram[0];
		if (ram[0] == 0) return PASS;
		usz end = 4;
		while (end < ram.len && ram[end] != 0) end++;
		*text = ((String)ram[4:end - 4]).tcopy();
		return FAIL;
	}
	return TIMEOUT;
}

fn void run_all() @test
{
	uint present;
	uint passed;
	uint regressed;
	uint new_pass;

	foreach (rom : ROMS) {
		char code;
		String text;
		Outcome o = run_rom(string::tformat("%s%s.gb", DIR, rom.name), &code, &text);
		if (o == MISSING) continue;
		present++;

		if (o == PASS) {
			passed++;
			if (!rom.must_pass) {
				new_pass++;
				io::eprintfn("  NEW PASS  %s  (mark it `true`)", rom.name);
			}
			continue;
		}
		if (rom.must_pass) regressed++;
		String what = o == TIMEOUT ? "timeout" : string::tformat("fail #%d", code);
		io::eprintfn("  %s%-9s %s", rom.must_pass ? "REGRESSED " : "", what, rom.name);
		// The ROM's own explanation, without its long hex dumps.
		int shown = 0;
		foreach (line : text.tsplit("\n")) {
			if (line.len == 0 || line.len > 60 || shown == 3) continue;
			io::eprintfn("              %s", line);
			shown++;
		}
	}

	if (present == 0) {
		io::eprintn("  dmg_sound: no ROMs in test/blargg/dmg_sound — run scripts/fetch-blargg.sh");
		return;
	}
	io::eprintfn("  dmg_sound: %d/%d pass, %d newly passing, %d regressed",
		passed, present, new_pass, regressed);
	test::@check(regressed == 0, "a must-pass dmg_sound ROM regressed (see lines above)");
}
