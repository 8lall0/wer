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
