module mooneye_test;

import gameboy, cpu;
import std::io;
import std::io::file;
import std::core::test;

// Mooneye Test Suite harness  (https://github.com/Gekkio/mooneye-test-suite).
//
// The ROMs are not vendored. Fetch them with
//   scripts/fetch-mooneye.sh
// into test/mooneye/ . With none present the test prints one line and passes.
//
// Every Mooneye test ends by executing LD B,B ($40) as a breakpoint. At that
// point B,C,D,E,H,L hold 3,5,8,13,21,34 on pass and all $42 on fail. A ROM
// that never gets there within TIMEOUT counts as a timeout.
//
// ROMS lists every test that applies to a DMG: no model suffix, -GS, -dmgABC
// or -dmgABCmgb. Skipped: dmg0/mgb/sgb/S/A/C/cgb variants, manual-only/,
// madness/, misc/ (CGB) and utils/.
//
// Entries marked `true` are known to pass and must keep passing: the test
// fails only if one of them regresses. The others are reported, not enforced.
// When a fix makes a new ROM pass, the summary says so; flip its flag.
//
// The runner hides output of passing tests; to see the per-ROM report run
//   c3c test && ./build/testrun --test-nocapture --test-filter mooneye

const String DIR = "test/mooneye/";

// 10 emulated seconds; passing ROMs finish well within one.
const ulong TIMEOUT = 10 * 4194304 / 4;

const char[6] PASS_REGS = { 3, 5, 8, 13, 21, 34 };

enum Outcome : char {
	MISSING,
	PASS,
	FAIL,
	TIMEOUT,
}

struct Rom {
	String path;
	bool   must_pass;
}

const Rom[*] ROMS = {
	{ "acceptance/add_sp_e_timing.gb", true  },
	{ "acceptance/bits/mem_oam.gb", true  },
	{ "acceptance/bits/reg_f.gb", true  },
	{ "acceptance/bits/unused_hwio-GS.gb", true  },
	{ "acceptance/boot_div-dmgABCmgb.gb", true  },
	{ "acceptance/boot_hwio-dmgABCmgb.gb", true  },
	{ "acceptance/boot_regs-dmgABC.gb", true  },
	{ "acceptance/call_cc_timing2.gb", true  },
	{ "acceptance/call_cc_timing.gb", true  },
	{ "acceptance/call_timing2.gb", true  },
	{ "acceptance/call_timing.gb", true  },
	{ "acceptance/di_timing-GS.gb", true  },
	{ "acceptance/div_timing.gb", true  },
	{ "acceptance/ei_sequence.gb", true  },
	{ "acceptance/ei_timing.gb", true  },
	{ "acceptance/halt_ime0_ei.gb", true  },
	{ "acceptance/halt_ime0_nointr_timing.gb", true  },
	{ "acceptance/halt_ime1_timing2-GS.gb", true  },
	{ "acceptance/halt_ime1_timing.gb", true  },
	{ "acceptance/if_ie_registers.gb", true  },
	{ "acceptance/instr/daa.gb", true  },
	{ "acceptance/interrupts/ie_push.gb", true  },
	{ "acceptance/intr_timing.gb", true  },
	{ "acceptance/jp_cc_timing.gb", true  },
	{ "acceptance/jp_timing.gb", true  },
	{ "acceptance/ld_hl_sp_e_timing.gb", true  },
	{ "acceptance/oam_dma/basic.gb", true  },
	{ "acceptance/oam_dma/reg_read.gb", true  },
	{ "acceptance/oam_dma_restart.gb", true  },
	{ "acceptance/oam_dma/sources-GS.gb", true  },
	{ "acceptance/oam_dma_start.gb", true  },
	{ "acceptance/oam_dma_timing.gb", true  },
	{ "acceptance/pop_timing.gb", true  },
	{ "acceptance/ppu/hblank_ly_scx_timing-GS.gb", true  },
	{ "acceptance/ppu/intr_1_2_timing-GS.gb", true  },
	{ "acceptance/ppu/intr_2_0_timing.gb", true  },
	{ "acceptance/ppu/intr_2_mode0_timing.gb", true  },
	{ "acceptance/ppu/intr_2_mode0_timing_sprites.gb", true  },
	{ "acceptance/ppu/intr_2_mode3_timing.gb", true  },
	{ "acceptance/ppu/intr_2_oam_ok_timing.gb", true  },
	{ "acceptance/ppu/lcdon_timing-GS.gb", true  },
	{ "acceptance/ppu/lcdon_write_timing-GS.gb", true  },
	{ "acceptance/ppu/stat_irq_blocking.gb", true  },
	{ "acceptance/ppu/stat_lyc_onoff.gb", true  },
	{ "acceptance/ppu/vblank_stat_intr-GS.gb", true  },
	{ "acceptance/push_timing.gb", true  },
	{ "acceptance/rapid_di_ei.gb", true  },
	{ "acceptance/ret_cc_timing.gb", true  },
	{ "acceptance/reti_intr_timing.gb", true  },
	{ "acceptance/reti_timing.gb", true  },
	{ "acceptance/ret_timing.gb", true  },
	{ "acceptance/rst_timing.gb", true  },
	{ "acceptance/serial/boot_sclk_align-dmgABCmgb.gb", true  },
	{ "acceptance/timer/div_write.gb", true  },
	{ "acceptance/timer/rapid_toggle.gb", true  },
	{ "acceptance/timer/tim00_div_trigger.gb", true  },
	{ "acceptance/timer/tim00.gb", true  },
	{ "acceptance/timer/tim01_div_trigger.gb", true  },
	{ "acceptance/timer/tim01.gb", true  },
	{ "acceptance/timer/tim10_div_trigger.gb", true  },
	{ "acceptance/timer/tim10.gb", true  },
	{ "acceptance/timer/tim11_div_trigger.gb", true  },
	{ "acceptance/timer/tim11.gb", true  },
	{ "acceptance/timer/tima_reload.gb", true  },
	{ "acceptance/timer/tima_write_reloading.gb", true  },
	{ "acceptance/timer/tma_write_reloading.gb", true  },
	{ "emulator-only/mbc1/bits_bank1.gb", true  },
	{ "emulator-only/mbc1/bits_bank2.gb", true  },
	{ "emulator-only/mbc1/bits_mode.gb", true  },
	{ "emulator-only/mbc1/bits_ramg.gb", true  },
	{ "emulator-only/mbc1/multicart_rom_8Mb.gb", true  },
	{ "emulator-only/mbc1/ram_256kb.gb", true  },
	{ "emulator-only/mbc1/ram_64kb.gb", true  },
	{ "emulator-only/mbc1/rom_16Mb.gb", true  },
	{ "emulator-only/mbc1/rom_1Mb.gb", true  },
	{ "emulator-only/mbc1/rom_2Mb.gb", true  },
	{ "emulator-only/mbc1/rom_4Mb.gb", true  },
	{ "emulator-only/mbc1/rom_512kb.gb", true  },
	{ "emulator-only/mbc1/rom_8Mb.gb", true  },
	{ "emulator-only/mbc2/bits_ramg.gb", true  },
	{ "emulator-only/mbc2/bits_romb.gb", true  },
	{ "emulator-only/mbc2/bits_unused.gb", true  },
	{ "emulator-only/mbc2/ram.gb", true  },
	{ "emulator-only/mbc2/rom_1Mb.gb", true  },
	{ "emulator-only/mbc2/rom_2Mb.gb", true  },
	{ "emulator-only/mbc2/rom_512kb.gb", true  },
	{ "emulator-only/mbc5/rom_16Mb.gb", true  },
	{ "emulator-only/mbc5/rom_1Mb.gb", true  },
	{ "emulator-only/mbc5/rom_2Mb.gb", true  },
	{ "emulator-only/mbc5/rom_32Mb.gb", true  },
	{ "emulator-only/mbc5/rom_4Mb.gb", true  },
	{ "emulator-only/mbc5/rom_512kb.gb", true  },
	{ "emulator-only/mbc5/rom_64Mb.gb", true  },
	{ "emulator-only/mbc5/rom_8Mb.gb", true  },
};

fn Outcome run_rom(String path) {
	char[]? data = file::load_temp(path);
	if (catch data) return MISSING;

	gameboy::GameBoy gb = gameboy::new(false);
	defer gb.destroy();
	gb.load_rom_named(data, path);
	if (gb.mmu.cart) gb.mmu.cart.has_battery = false; // never write .sav files

	ulong limit = gb.cpu.clk + TIMEOUT;
	while (gb.cpu.clk < limit) {
		if (gb.mmu.get(gb.cpu.pc) == 0x40) return verdict(&gb.cpu); // LD B,B
		gb.step();
	}
	return TIMEOUT;
}

fn Outcome verdict(cpu::Cpu* c) {
	char[6] regs = { c.bc.hi, c.bc.lo, c.de.hi, c.de.lo, c.hl.hi, c.hl.lo };
	return regs == PASS_REGS ? PASS : FAIL;
}

fn void run_all() @test
{
	uint present;
	uint passed;
	uint regressed;
	uint new_pass;

	foreach (rom : ROMS) {
		Outcome o = run_rom(string::tformat("%s%s", DIR, rom.path));
		if (o == MISSING) continue;
		present++;

		if (o == PASS) {
			passed++;
			if (!rom.must_pass) {
				new_pass++;
				io::eprintfn("  NEW PASS  %s  (mark it `true`)", rom.path);
			}
			continue;
		}
		if (rom.must_pass) {
			regressed++;
			io::eprintfn("  REGRESSED %s  (%s)", rom.path, o == FAIL ? "fail" : "timeout");
		} else {
			io::eprintfn("  %-9s %s", o == FAIL ? "fail" : "timeout", rom.path);
		}
	}

	if (present == 0) {
		io::eprintn("  mooneye: no ROMs in test/mooneye — run scripts/fetch-mooneye.sh");
		return;
	}

	io::eprintfn("  mooneye: %d/%d pass, %d newly passing, %d regressed",
		passed, present, new_pass, regressed);
	test::@check(regressed == 0, "a must-pass Mooneye ROM regressed (see lines above)");
}
