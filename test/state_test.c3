module state_test;

import gameboy, mmu;
import std::io, std::io::file;
import std::core::test;

// Save states: a state taken mid-run and loaded into a fresh machine must
// continue exactly like the original (picture, registers, memory, sound).
// Uses test ROMs fetched by the scripts; without them these pass with a note.

const String DMG_ROM = "test/blargg/dmg_sound/03-trigger.gb"; // MBC1 + RAM, sound
const String CGB_ROM = "test/blargg/cgb_sound/04-sweep.gb";

fn gameboy::GameBoy? boot(String path, mmu::Model model) {
	char[] data = file::load_temp(path)!;
	gameboy::GameBoy gb = gameboy::new(true, model);
	gb.load_rom(data);
	if (gb.mmu.cart) gb.mmu.cart.has_battery = false;
	return gb;
}

// `frames` more frames on both machines; everything observable must agree.
fn void same_future(gameboy::GameBoy* a, gameboy::GameBoy* b, int frames) {
	short[4096] sa;
	short[4096] sb;
	for (int f = 0; f < frames; f++) {
		a.run_frame();
		b.run_frame();
		uint na = a.audio(&sa);
		uint nb = b.audio(&sb);
		test::eq(na, nb);
		test::@check(sa[:na] == sb[:nb], "same sound in frame %d", f);
		test::@check(a.mmu.ppu.fb == b.mmu.ppu.fb, "same picture in frame %d", f);
		test::@check(a.mmu.ppu.cfb == b.mmu.ppu.cfb, "same colour picture in frame %d", f);
	}
	test::eq(a.cpu.clk, b.cpu.clk);
	test::eq(a.cpu.pc, b.cpu.pc);
	test::@check(a.mmu.wram == b.mmu.wram, "same WRAM");
	test::@check(a.mmu.ppu.vram == b.mmu.ppu.vram, "same VRAM");
	if (a.mmu.cart) test::@check(a.mmu.cart.ram == b.mmu.cart.ram, "same cartridge RAM");
}

fn void round_trip(String path, mmu::Model model) {
	gameboy::GameBoy? a = boot(path, model);
	if (catch a) {
		io::printfn("  (%s missing: scripts/fetch-blargg.sh)", path);
		return;
	}
	defer a.destroy();
	short[4096] drop;
	for (int f = 0; f < 150; f++) { // past the boot ROM, test running
		a.run_frame();
		a.audio(&drop);
	}
	char[] state = a.save_state(mem);
	defer free(state.ptr);

	// A fresh machine, somewhere else entirely, takes over.
	gameboy::GameBoy b = boot(path, model)!!;
	defer b.destroy();
	for (int f = 0; f < 7; f++) b.run_frame();
	b.load_state(state)!!;
	same_future(&a, &b, 120);
}

fn void dmg_round_trip() @test => round_trip(DMG_ROM, DMG);
fn void cgb_round_trip() @test => round_trip(CGB_ROM, CGB);
fn void sgb_round_trip() @test => round_trip(DMG_ROM, SGB);

fn void refuses_what_does_not_fit() @test {
	gameboy::GameBoy? a = boot(DMG_ROM, DMG);
	if (catch a) return;
	defer a.destroy();
	a.run_frame();
	char[] state = a.save_state(mem);
	defer free(state.ptr);

	gameboy::GameBoy other_model = boot(DMG_ROM, SGB)!!;
	defer other_model.destroy();
	test::@check(@catch(other_model.load_state(state)) == gameboy::STATE_OTHER_MODEL, "other model");

	gameboy::GameBoy other_game = boot("test/blargg/dmg_sound/05-sweep details.gb", DMG)!!;
	defer other_game.destroy();
	test::@check(@catch(other_game.load_state(state)) == gameboy::STATE_OTHER_GAME, "other game");

	test::@check(@catch(a.load_state(state[:state.len - 1])) == gameboy::STATE_INVALID, "truncated");

	state[12]++; // the layout fingerprint
	test::@check(@catch(a.load_state(state)) == gameboy::STATE_OTHER_BUILD, "other build");
	state[12]--;
	state[0] = 'X';
	test::@check(@catch(a.load_state(state)) == gameboy::STATE_INVALID, "not a state");
}

// Through a file, as the hotkeys and the menu do.
fn void state_file_round_trip() @test {
	gameboy::GameBoy? a = boot(DMG_ROM, DMG);
	if (catch a) return;
	defer a.destroy();
	short[4096] drop;
	for (int f = 0; f < 30; f++) {
		a.run_frame();
		a.audio(&drop);
	}
	String path = gameboy::state_path("build/state_test", 1);
	a.save_state_file(path)!!;
	defer (void)file::delete(path);

	gameboy::GameBoy b = boot(DMG_ROM, DMG)!!;
	defer b.destroy();
	b.load_state_file(path)!!;
	test::eq(a.cpu.clk, b.cpu.clk);
	same_future(&a, &b, 10);
}
