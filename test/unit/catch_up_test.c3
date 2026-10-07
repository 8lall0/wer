module catch_up_test;
import gameboy, mmu, ppu;
import std::core::test, std::io::file;

// The PPU runs behind and catches up in batches (Mmu.ppu_catch_up), faster
// than dot by dot: each batch is also run the ordinary way on a copy, and
// the two must leave the PPU and the picture the same. Test ROMs that
// aren't there (scripts/fetch-*.sh) are skipped.
fn void catch_up_matches_dot_by_dot() @test {
	String[] roms = {
		"test/acid2/dmg-acid2.gb",
		"test/acid2/cgb-acid2.gbc",
		"test/mealybug/roms/m3_bgp_change_sprites.gb",
		"test/mealybug/roms/m3_window_timing.gb",
	};
	foreach (path : roms) {
		char[]? rom = file::load_temp(path);
		if (catch rom) continue;
		gameboy::GameBoy* g = mem::new(gameboy::GameBoy);
		*g = gameboy::new(false, path.ends_with(".gbc") ? mmu::Model.CGB : mmu::Model.DMG);
		g.load_rom(rom);
		ppu::catch_up_checked = 0;
		ppu::catch_up_mismatches = 0;
		ppu::check_catch_up = true;
		for (int f = 0; f < 15; f++) g.run_frame();
		ppu::check_catch_up = false;
		g.destroy();
		free(g);
		test::@check(ppu::catch_up_checked > 0, "%s: nothing caught up", path);
		test::eq(ppu::catch_up_mismatches, 0);
	}
}

fn gameboy::GameBoy* boot(String path) {
	char[]? rom = file::load_temp(path);
	if (catch rom) return null;
	gameboy::GameBoy* g = mem::new(gameboy::GameBoy);
	*g = gameboy::new(false, path.ends_with(".gbc") ? mmu::Model.CGB : mmu::Model.DMG);
	g.load_rom(rom);
	return g;
}

// Everything that can wait running behind (the PPU, Mmu.quiet M-cycles), or
// everything in step: the machine must be the same after each frame.
fn void lazy_runs_like_exact() @test {
	String[] roms = {
		"test/acid2/cgb-acid2.gbc",
		"test/blargg/dmg_sound/03-trigger.gb",
		"test/blargg/cgb_sound/04-sweep.gb",
		"test/mealybug/roms/m3_scx_low_3_bits.gb",
	};
	foreach (path : roms) {
		gameboy::GameBoy* a = boot(path);
		if (!a) continue;
		gameboy::GameBoy* b = boot(path);
		for (int f = 0; f < 120; f++) {
			mmu::lazy_ppu = false;
			a.run_frame();
			mmu::lazy_ppu = true;
			b.run_frame();
			b.mmu.ppu_touch();
			a.mmu.apu.sync();
			b.mmu.apu.sync();
			bool same = a.cpu.clk == b.cpu.clk && a.cpu.pc == b.cpu.pc && a.cpu.sp == b.cpu.sp && mem::equals(&a.cpu.af, &b.cpu.af, 8)
				&& a.mmu.wram == b.mmu.wram && a.mmu.hram == b.mmu.hram && a.mmu.io == b.mmu.io
				&& a.mmu.ppu.vram == b.mmu.ppu.vram && a.mmu.ppu.oam == b.mmu.ppu.oam && a.mmu.ppu.fb == b.mmu.ppu.fb && a.mmu.ppu.cfb == b.mmu.ppu.cfb
				&& a.mmu.ppu.cc == b.mmu.ppu.cc && a.mmu.ppu.stat == b.mmu.ppu.stat
				&& a.mmu.timer.div == b.mmu.timer.div && a.mmu.apu.gcc == b.mmu.apu.gcc && a.mmu.apu.sample_acc == b.mmu.apu.sample_acc
				&& a.mmu.apu.samples == b.mmu.apu.samples && a.mmu.apu.active == b.mmu.apu.active;
			if (!same) {
				test::@check(false, "%s: differs after frame %d", path, f);
				break;
			}
		}
		a.destroy(); b.destroy(); free(a); free(b);
	}
}
