module age_test;

import gameboy, mmu, cpu, parallel;
import std::io, std::io::file, std::collections::list;
import std::core::test;

// AGE test ROMs (https://github.com/c-sp/age-test-roms): PPU, HALT, speed
// switch and timer edge cases, each verified on named hardware revisions
// (DMG-CPU C; CPU CGB B, C and E; "ncm" = a CGB running a DMG game). wer
// runs every CGB test as a CGB-B, C and E (mmu::CgbRevision): it has to
// pass on the revisions in its name; on the others the hardware gives
// other results, so passing there means the two revisions don't differ
// where they should (reported, not an error).
// Numerical tests stop at LD B,B with B C D E H L = 3 5 8 13 21 34 on
// success; visual ones are compared with the device's screenshot then.
//
// Not vendored; fetch them with
//   scripts/fetch-age.sh
// into test/age/ . With none present the test prints one line and passes.
//   c3c test && ./build/testrun --test-nocapture --test-filter age

const String DIR = "test/age/";
const ulong TIMEOUT = 4194304UL / 4 * 30; // 30 s of M-cycles
const char[6] PASS_REGS = { 3, 5, 8, 13, 21, 34 };
const int PIXELS = 160 * 144;
const char[4] DMG_SHADE = { 0xFF, 0xAA, 0x55, 0x00 };
// AGE's colours for a DMG game on a CGB (RGB555): background and objects.
const ushort[4] NCM_BG = { 0x7FFF, 0x1BEF, 0x6180, 0x0000 };
const ushort[4] NCM_OBJ = { 0x7FFF, 0x421F, 0x1CF2, 0x0000 };

// Expected to pass but failing (`model rev rom`):
//  - speed-switch/caution: an interrupt ending the speed switch's halt
//    early; the author's CGB-E was unstable after running them.
//  - m3-bg-bgp (DMG): the BGP write glitch that Mealybug's DMG screenshots
//    don't show (different DMG revisions).
//  - oam-write (DMG): OAM write locking around mode 2.
const String[*] KNOWN_FAIL = {
	"cgb b speed-switch/caution/spsw-interrupts-cgbBC.gb",
	"cgb c speed-switch/caution/spsw-interrupts-cgbBC.gb",
	"cgb e speed-switch/caution/spsw-interrupts-cgbE.gb",
	"dmg c m3-bg-bgp/m3-bg-bgp.gb",
	"dmg c oam/oam-write-dmgC.gb",
};

struct Check {
	bool   cgb;
	char   rev;  // 'b', 'c' or 'e'
	bool   shot;
	String rom;
	String ref;
	bool   expect_pass;
	bool   passed;
	bool   missing;
}

fn void Check.run(&self) {
	char[]? data = file::load_temp(string::tformat("%s%s", DIR, self.rom));
	if (catch data) {
		self.missing = true;
		return;
	}
	gameboy::GameBoy gb = gameboy::new(false, self.cgb ? mmu::Model.CGB : mmu::Model.DMG);
	defer gb.destroy();
	gb.set_cgb_revision(self.rev == 'e' ? mmu::CgbRevision.E : self.rev == 'b' ? mmu::CgbRevision.B : mmu::CgbRevision.C);
	gb.load_rom(data);
	if (gb.mmu.cart) gb.mmu.cart.has_battery = false;
	if (self.cgb && !gb.mmu.cgb_mode) {
		for (int i = 0; i < 4; i++) {
			gb.mmu.ppu.bg_pal[i * 2] = (char)NCM_BG[i];
			gb.mmu.ppu.bg_pal[i * 2 + 1] = (char)(NCM_BG[i] >> 8);
			for (int o = 0; o < 2; o++) {
				gb.mmu.ppu.obj_pal[o * 8 + i * 2] = (char)NCM_OBJ[i];
				gb.mmu.ppu.obj_pal[o * 8 + i * 2 + 1] = (char)(NCM_OBJ[i] >> 8);
			}
		}
	}
	ulong limit = gb.cpu.clk + TIMEOUT;
	while (gb.mmu.get(gb.cpu.pc) != 0x40) { // LD B,B
		if (gb.cpu.clk >= limit) return;
		gb.step();
	}
	if (!self.shot) {
		cpu::Cpu* c = &gb.cpu;
		char[6] regs = { c.bc.hi, c.bc.lo, c.de.hi, c.de.lo, c.hl.hi, c.hl.lo };
		self.passed = regs == PASS_REGS;
		return;
	}
	char[]? ref = file::load_temp(string::tformat("%s%s", DIR, self.ref));
	if (catch ref) {
		self.missing = true;
		return;
	}
	if (ref.len < PIXELS * 3) return;
	char[] rgb = mem::new_array(char, gameboy::MAX_FRAME_RGB);
	defer free(rgb.ptr);
	if (self.cgb) {
		gb.frame_rgb(rgb, {});
	} else {
		char[] fb = gb.framebuffer();
		for (int i = 0; i < PIXELS; i++) rgb[i * 3] = rgb[i * 3 + 1] = rgb[i * 3 + 2] = DMG_SHADE[fb[i] & 3];
	}
	self.passed = rgb[:PIXELS * 3] == ref[:PIXELS * 3];
}

fn String Check.id(&self) => string::tformat("%s %c %s", self.cgb ? "cgb" : "dmg", self.rev, self.rom);

fn void run_job(void* ctx, usz i) {
	((Check*)ctx)[i].run();
}

fn void run_all() @test
{
	char[]? index = file::load_temp(DIR.tconcat("index.txt"));
	if (catch index) {
		io::eprintn("  age: no ROMs in test/age — run scripts/fetch-age.sh");
		return;
	}
	List{Check} list;
	list.tinit();
	foreach (line : ((String)index).tsplit("\n")) {
		String[] f = line.trim().tsplit(" ");
		if (f.len < 6) continue;
		list.push({
			.cgb = f[0] == "cgb",
			.rev = f[1][0],
			.shot = f[2] == "shot",
			.rom = f[3],
			.ref = f[4],
			.expect_pass = f[5] == "pass",
		});
	}
	Check[] checks = list.array_view();
	parallel::run(checks.len, &run_job, checks.ptr);

	uint expected;
	uint passed;
	uint regressed;
	uint revision_passes;
	foreach (&c : checks) {
		if (c.missing) continue;
		String id = c.id();
		bool known = false;
		foreach (k : KNOWN_FAIL) if (k == id) known = true;
		if (!c.expect_pass) {
			if (c.passed) {
				revision_passes++;
				io::eprintfn("  passes on a revision it shouldn't: %s", id);
			}
			continue;
		}
		expected++;
		if (c.passed) {
			passed++;
			if (known) io::eprintfn("  NEW PASS  %s  (remove it from KNOWN_FAIL)", id);
		} else if (!known) {
			regressed++;
			io::eprintfn("  REGRESSED %s", id);
		}
	}
	io::eprintfn("  age: %d/%d pass, %d regressed, %d pass on the wrong revision", passed, expected, regressed, revision_passes);
	test::@check(regressed == 0, "an AGE test regressed (see lines above)");
}
