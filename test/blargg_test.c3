module blargg_test;

import gameboy, mmu;
import std::io;
import std::io::file;
import std::core::test;

// Blargg's test ROMs: CPU instructions and timing, memory access timing, the
// HALT bug, the OAM corruption bug, interrupt timing, and sound (dmg_sound on
// a DMG, cgb_sound and interrupt_time on a CGB).
//
// The ROMs are not vendored. Fetch them with
//   scripts/fetch-blargg.sh
// into test/blargg/<suite>/ . Missing suites print one line and pass.
//
// The newer ROMs report through cartridge RAM: $A001-$A003 = $DE $B0 $61 once
// the output is valid, $A000 = $80 while running, then the result (0 = pass),
// and a zero-terminated text at $A004 explaining a failure. The older ones
// (cpu_instrs, instr_timing, mem_timing) only print their text over the
// serial port, ending in "Passed" or "Failed"; halt_bug and interrupt_time
// only show it on screen (read back from the tile map).
//
// Entries marked `true` must keep passing; the others are reported only.
// To see the report:
//   c3c test && ./build/testrun --test-nocapture --test-filter blargg

const String DIR = "test/blargg/";

// Emulated time before a ROM counts as hung; the tests take a few seconds.
const int TIMEOUT_FRAMES = 60 * 40;

struct Rom {
	String name;
	bool   must_pass;
}

const Rom[*] SOUND_DMG = {
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

const Rom[*] SOUND_CGB = {
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
	{ "12-wave", true  },
};

const Rom[*] CPU_INSTRS = {
	{ "01-special", true  },
	{ "02-interrupts", true  },
	{ "03-op sp,hl", true  },
	{ "04-op r,imm", true  },
	{ "05-op rp", true  },
	{ "06-ld r,r", true  },
	{ "07-jr,jp,call,ret,rst", true  },
	{ "08-misc instrs", true  },
	{ "09-op r,r", true  },
	{ "10-bit ops", true  },
	{ "11-op a,(hl)", true  },
};

const Rom[*] INSTR_TIMING = { { "instr_timing", true  } };
const Rom[*] MEM_TIMING = {
	{ "01-read_timing", true  },
	{ "02-write_timing", true  },
	{ "03-modify_timing", true  },
};
const Rom[*] HALT_BUG = { { "halt_bug", true  } };
const Rom[*] INTERRUPT_TIME = { { "interrupt_time", true  } };
const Rom[*] OAM_BUG = {
	{ "1-lcd_sync", true  },
	{ "2-causes", false },
	{ "3-non_causes", true  },
	{ "4-scanline_timing", false },
	{ "5-timing_bug", false },
	{ "6-timing_no_bug", true  },
	{ "7-timing_effect", false },
	{ "8-instr_effect", false },
};

enum Outcome : char {
	MISSING,
	PASS,
	FAIL,
	TIMEOUT,
}

// Runs one ROM; on failure `text` gets the ROM's own explanation.
fn Outcome run_rom(String path, mmu::Model model, char* code, String* text) {
	char[]? data = file::load_temp(path);
	if (catch data) return MISSING;

	gameboy::GameBoy gb = gameboy::new(false, model);
	defer gb.destroy();
	gb.load_rom_named(data, path);
	char[] ram;
	if (gb.mmu.cart) {
		gb.mmu.cart.has_battery = false; // never write .sav files
		ram = gb.mmu.cart.ram;
	}

	for (int f = 0; f < TIMEOUT_FRAMES; f++) {
		gb.run_frame();
		// Cartridge RAM report.
		if (ram.len >= 0x100 && ram[1] == 0xDE && ram[2] == 0xB0 && ram[3] == 0x61 && ram[0] != 0x80) {
			*code = ram[0];
			if (ram[0] == 0) return PASS;
			usz end = 4;
			while (end < ram.len && ram[end] != 0) end++;
			*text = ((String)ram[4:end - 4]).tcopy();
			return FAIL;
		}
		if (ram.len >= 0x100) continue; // it reports there: wait for it
		// Serial report.
		String serial = (String)gb.mmu.serial_log[:gb.mmu.serial_log_len];
		if (serial.contains("Passed")) return PASS;
		if (serial.contains("Failed")) {
			*code = 1;
			*text = serial.tcopy();
			return FAIL;
		}
		// Screen report: the text is drawn with tile number = ASCII code.
		String screen = screen_text(&gb);
		if (screen.contains("Passed")) return PASS;
		if (screen.contains("Failed")) {
			*code = 1;
			*text = screen;
			return FAIL;
		}
	}
	return TIMEOUT;
}

// The BG tile map as text, one line per row (the ROMs' font puts each
// character at its ASCII code).
fn String screen_text(gameboy::GameBoy* gb) {
	DString out;
	out.init(tmem);
	for (int row = 0; row < 18; row++) {
		for (int col = 0; col < 20; col++) {
			char t = gb.mmu.ppu.vram[0x1800 + row * 32 + col];
			out.append_char(t >= 0x20 && t < 0x7F ? t : ' ');
		}
		out.append_char('\n');
	}
	return out.str_view();
}

struct Tally {
	uint present;
	uint passed;
	uint regressed;
	uint new_pass;
}

fn void run_suite(String name, Rom[] roms, mmu::Model model)
{
	String dir = string::tformat("%s%s/", DIR, name);
	Tally t;
	foreach (rom : roms) {
		char code;
		String text;
		Outcome o = run_rom(string::tformat("%s%s.gb", dir, rom.name), model, &code, &text);
		if (o == MISSING) continue;
		t.present++;

		if (o == PASS) {
			t.passed++;
			if (!rom.must_pass) {
				t.new_pass++;
				io::eprintfn("  NEW PASS  %s %s  (mark it `true`)", name, rom.name);
			}
			continue;
		}
		if (rom.must_pass) t.regressed++;
		String what = o == TIMEOUT ? "timeout" : string::tformat("fail #%d", code);
		io::eprintfn("  %s%-9s %s %s", rom.must_pass ? "REGRESSED " : "", what, name, rom.name);
		// The ROM's own explanation, without its long hex dumps.
		int shown = 0;
		foreach (line : text.tsplit("\n")) {
			if (line.len == 0 || line.len > 60 || shown == 3) continue;
			io::eprintfn("              %s", line);
			shown++;
		}
	}

	if (t.present == 0) {
		io::eprintfn("  %s: no ROMs in %s — run scripts/fetch-blargg.sh", name, dir);
		return;
	}
	io::eprintfn("  %s: %d/%d pass, %d newly passing, %d regressed",
		name, t.passed, t.present, t.new_pass, t.regressed);
	test::@check(t.regressed == 0, "a must-pass Blargg ROM regressed (see lines above)");
}

fn void sound() @test
{
	run_suite("dmg_sound", &SOUND_DMG, DMG);
	run_suite("cgb_sound", &SOUND_CGB, CGB);
}

fn void cpu() @test
{
	run_suite("cpu_instrs", &CPU_INSTRS, DMG);
	run_suite("instr_timing", &INSTR_TIMING, DMG);
}

fn void memory_timing() @test
{
	run_suite("mem_timing", &MEM_TIMING, DMG);
	run_suite("mem_timing-2", &MEM_TIMING, DMG);
}

fn void hardware_bugs() @test
{
	run_suite("halt_bug", &HALT_BUG, DMG);
	run_suite("oam_bug", &OAM_BUG, DMG);
	run_suite("interrupt_time", &INTERRUPT_TIME, CGB);
}
