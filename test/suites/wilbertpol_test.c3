module wilbertpol_test;

import gameboy, mmu, cpu, parallel;
import std::io, std::io::file, std::collections::list;
import std::core::test;

// wilbertpol's 2016 fork of the Mooneye test suite: older versions of many
// Mooneye tests plus his own (LY/LYC, STAT, boot registers). A test ends at
// the undefined opcode $ED with B C D E H L = 3 5 8 13 21 34 on success. Its
// CGB results match a CGB-D/E (ly00_mode1_2-C, ly_new_frame-C,
// stat_irq_blocking fail on a CGB-C), so the CGB checks run on a CGB-E.
//
// Not vendored; fetch them with
//   scripts/fetch-wilbertpol.sh
// into test/wilbertpol/ . With none present the test prints one line and passes.
//   c3c test && ./build/testrun --test-nocapture --test-filter wilbertpol

const String DIR = "test/wilbertpol/";
const ulong TIMEOUT = 4194304UL / 4 * 20; // 20 s of M-cycles
const char[6] PASS_REGS = { 3, 5, 8, 13, 21, 34 };

struct Check {
	String model; // dmg, mgb, sgb, sgb2 or cgb
	String rom;
	bool   passed;
	bool   missing;
}

fn void Check.run(&self) {
	char[]? data = file::load_temp(DIR.tconcat(self.rom));
	if (catch data) {
		self.missing = true;
		return;
	}
	mmu::Model model;
	switch (self.model) {
		case "cgb":  model = CGB;
		case "sgb":  model = SGB;
		case "sgb2": model = SGB2;
		default:     model = DMG;
	}
	gameboy::GameBoy gb = gameboy::new(false, model);
	defer gb.destroy();
	gb.set_cgb_revision(E);
	if (self.model == "mgb") gb.set_dmg_revision(MGB);
	gb.load_rom(data);
	if (gb.mmu.cart) gb.mmu.cart.has_battery = false;
	ulong limit = gb.cpu.clk + TIMEOUT;
	while (gb.mmu.get(gb.cpu.pc) != 0xED) {
		if (gb.cpu.clk >= limit) return;
		gb.step();
	}
	cpu::Cpu* c = &gb.cpu;
	char[6] regs = { c.bc.hi, c.bc.lo, c.de.hi, c.de.lo, c.hl.hi, c.hl.lo };
	self.passed = regs == PASS_REGS;
}

fn void run_job(void* ctx, usz i) {
	((Check*)ctx)[i].run();
}

fn void run_all() @test
{
	char[]? index = file::load_temp(DIR.tconcat("index.txt"));
	if (catch index) {
		io::eprintn("  wilbertpol: no ROMs in test/wilbertpol — run scripts/fetch-wilbertpol.sh");
		return;
	}
	List{Check} list;
	list.tinit();
	foreach (line : ((String)index).tsplit("\n")) {
		String[] f = line.trim().tsplit(" ");
		if (f.len < 2) continue;
		list.push({ .model = f[0], .rom = f[1] });
	}
	Check[] checks = list.array_view();
	parallel::run(checks.len, &run_job, checks.ptr);

	uint present;
	uint passed;
	foreach (&c : checks) {
		if (c.missing) continue;
		present++;
		if (c.passed) {
			passed++;
		} else {
			io::eprintfn("  FAIL %s %s", c.model, c.rom);
		}
	}
	io::eprintfn("  wilbertpol: %d/%d pass", passed, present);
	test::@check(passed == present, "a wilbertpol test failed (see lines above)");
}
