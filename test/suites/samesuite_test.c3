module samesuite_test;

import gameboy, mmu, cpu, parallel;
import std::io, std::io::file;
import std::core::test;

// SameSuite (https://github.com/LIJI32/SameSuite): APU, DMA, interrupt, PPU
// and SGB behaviour, mostly on a Game Boy Color (sgb/ on a Super Game Boy).
// Like Mooneye, each ROM stops at LD B,B with B C D E H L = 3 5 8 13 21 34 on
// success.
//
// Not vendored, and there are no prebuilt ROMs; build them with
//   scripts/fetch-samesuite.sh
// into test/samesuite/ . With none present the test prints one line and
// passes. Names ending in revisions (-cgb0B, -cgbDE, -A, ...) target that
// hardware; they run on the first revision named (see revision_of). The
// script restores the instruction encoding the tests were checked with on
// hardware (RGBDS of the time turned `ld [rXX]` into `ldh`).
//
// Entries marked `true` must keep passing; the others are reported only.
//   c3c test && ./build/testrun --test-nocapture --test-filter samesuite

const String DIR = "test/samesuite/";
const ulong TIMEOUT = 4194304UL / 4 * 20; // 20 s of M-cycles
const char[6] PASS_REGS = { 3, 5, 8, 13, 21, 34 };

struct Rom {
	String path;
	bool   must_pass;
}

const Rom[*] ROMS = {
	{ "apu/channel_1/channel_1_align", true },
	{ "apu/channel_1/channel_1_align_cpu", true },
	{ "apu/channel_1/channel_1_delay", true },
	{ "apu/channel_1/channel_1_duty", true },
	{ "apu/channel_1/channel_1_duty_delay", true },
	{ "apu/channel_1/channel_1_extra_length_clocking-cgb0B", true },
	{ "apu/channel_1/channel_1_freq_change", true },
	{ "apu/channel_1/channel_1_freq_change_timing-A", true },
	{ "apu/channel_1/channel_1_freq_change_timing-cgb0BC", true },
	{ "apu/channel_1/channel_1_freq_change_timing-cgbDE", true },
	{ "apu/channel_1/channel_1_nrx2_glitch", true },
	{ "apu/channel_1/channel_1_nrx2_speed_change", true },
	{ "apu/channel_1/channel_1_restart", true },
	{ "apu/channel_1/channel_1_restart_nrx2_glitch", true },
	{ "apu/channel_1/channel_1_stop_div", true },
	{ "apu/channel_1/channel_1_stop_restart", true },
	{ "apu/channel_1/channel_1_sweep", true },
	{ "apu/channel_1/channel_1_sweep_restart", true },
	{ "apu/channel_1/channel_1_sweep_restart_2", true },
	{ "apu/channel_1/channel_1_volume", true },
	{ "apu/channel_1/channel_1_volume_div", true },
	{ "apu/channel_2/channel_2_align", true },
	{ "apu/channel_2/channel_2_align_cpu", true },
	{ "apu/channel_2/channel_2_delay", true },
	{ "apu/channel_2/channel_2_duty", true },
	{ "apu/channel_2/channel_2_duty_delay", true },
	{ "apu/channel_2/channel_2_extra_length_clocking-cgb0B", true },
	{ "apu/channel_2/channel_2_freq_change", true },
	{ "apu/channel_2/channel_2_nrx2_glitch", true },
	{ "apu/channel_2/channel_2_nrx2_speed_change", true },
	{ "apu/channel_2/channel_2_restart", true },
	{ "apu/channel_2/channel_2_restart_nrx2_glitch", true },
	{ "apu/channel_2/channel_2_stop_div", true },
	{ "apu/channel_2/channel_2_stop_restart", true },
	{ "apu/channel_2/channel_2_volume", true },
	{ "apu/channel_2/channel_2_volume_div", true },
	{ "apu/channel_3/channel_3_and_glitch", true  },
	{ "apu/channel_3/channel_3_delay", true  },
	{ "apu/channel_3/channel_3_extra_length_clocking-cgb0", true },
	{ "apu/channel_3/channel_3_extra_length_clocking-cgbB", true },
	{ "apu/channel_3/channel_3_first_sample", true  },
	{ "apu/channel_3/channel_3_freq_change_delay", true  },
	{ "apu/channel_3/channel_3_restart_delay", true  },
	{ "apu/channel_3/channel_3_restart_during_delay", true  },
	{ "apu/channel_3/channel_3_restart_stop_delay", true  },
	{ "apu/channel_3/channel_3_shift_delay", true  },
	{ "apu/channel_3/channel_3_shift_skip_delay", true  },
	{ "apu/channel_3/channel_3_stop_delay", true  },
	{ "apu/channel_3/channel_3_stop_div", true  },
	{ "apu/channel_3/channel_3_wave_ram_dac_on_rw", true  },
	{ "apu/channel_3/channel_3_wave_ram_locked_write", true  },
	{ "apu/channel_3/channel_3_wave_ram_sync", true  },
	{ "apu/channel_4/channel_4_align", true },
	{ "apu/channel_4/channel_4_delay", true },
	{ "apu/channel_4/channel_4_equivalent_frequencies", true },
	{ "apu/channel_4/channel_4_extra_length_clocking-cgb0B", true },
	{ "apu/channel_4/channel_4_freq_change", true },
	{ "apu/channel_4/channel_4_frequency_alignment", true },
	{ "apu/channel_4/channel_4_lfsr", true  },
	{ "apu/channel_4/channel_4_lfsr15", true  },
	{ "apu/channel_4/channel_4_lfsr_15_7", true  },
	{ "apu/channel_4/channel_4_lfsr_7_15", true },
	{ "apu/channel_4/channel_4_lfsr_restart", true },
	{ "apu/channel_4/channel_4_lfsr_restart_fast", true },
	{ "apu/channel_4/channel_4_volume_div", true  },
	{ "apu/div_trigger_volume_10", true },
	{ "apu/div_write_trigger", true  },
	{ "apu/div_write_trigger_10", true },
	{ "apu/div_write_trigger_volume", true  },
	{ "apu/div_write_trigger_volume_10", true },
	{ "dma/gbc_dma_cont", true  },
	{ "dma/gdma_addr_mask", true  },
	{ "dma/hdma_lcd_off", true  },
	{ "dma/hdma_mode0", true  },
	{ "interrupt/ei_delay_halt", true  },
	{ "ppu/blocking_bgpi_increase", true  },
	{ "sgb/command_mlt_req", true  },
	{ "sgb/command_mlt_req_1_incrementing", true  },
};

enum Outcome : char {
	MISSING,
	PASS,
	FAIL,
	TIMEOUT,
}

// SameSuite targets a CGB-E, unless a test's name lists other revisions
// (-cgb0B: CGB 0 and B, -cgbB, -cgbDE; -A: a GBA): the
// first one named.
fn mmu::CgbRevision revision_of(String path) {
	if (path.ends_with("-A")) return AGB;
	if (path.contains("-cgb0")) return CGB0;
	if (path.contains("-cgbB")) return B;
	if (path.contains("-cgbD")) return D;
	return E;
}

fn Outcome run_rom(String path) {
	char[]? data = file::load_temp(string::tformat("%s%s.gb", DIR, path));
	if (catch data) return MISSING;
	mmu::Model model = path.starts_with("sgb/") ? mmu::Model.SGB : mmu::Model.CGB;
	gameboy::GameBoy gb = gameboy::new(false, model);
	gb.set_cgb_revision(revision_of(path));
	defer gb.destroy();
	gb.load_rom(data);
	if (gb.mmu.cart) gb.mmu.cart.has_battery = false;

	ulong limit = gb.cpu.clk + TIMEOUT;
	while (gb.cpu.clk < limit) {
		if (gb.mmu.get(gb.cpu.pc) == 0x40) { // LD B,B
			cpu::Cpu* c = &gb.cpu;
			char[6] regs = { c.bc.hi, c.bc.lo, c.de.hi, c.de.lo, c.hl.hi, c.hl.lo };
			return regs == PASS_REGS ? PASS : FAIL;
		}
		gb.step();
	}
	return TIMEOUT;
}

fn void run_job(void* ctx, usz i) {
	((Outcome*)ctx)[i] = run_rom(ROMS[i].path);
}

fn void run_all() @test
{
	uint present;
	uint passed;
	uint regressed;
	uint new_pass;
	Outcome[] outcomes = mem::new_array(Outcome, ROMS.len);
	defer free(outcomes.ptr);
	parallel::run(ROMS.len, &run_job, outcomes.ptr);
	foreach (i, rom : ROMS) {
		Outcome o = outcomes[i];
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
		if (rom.must_pass) regressed++;
		io::eprintfn("  %s%-9s %s", rom.must_pass ? "REGRESSED " : "", o == TIMEOUT ? "timeout" : "fail", rom.path);
	}
	if (present == 0) {
		io::eprintn("  samesuite: no ROMs in test/samesuite — run scripts/fetch-samesuite.sh");
		return;
	}
	io::eprintfn("  samesuite: %d/%d pass, %d newly passing, %d regressed", passed, present, new_pass, regressed);
	test::@check(regressed == 0, "a must-pass SameSuite ROM regressed (see lines above)");
}
