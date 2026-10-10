module movie_test;

import gameboy, mmu, joypad;
import std::io, std::io::file;
import std::core::test;

// Movies (movie.c3): played back from their state they must give the run
// they were recorded from; going back re-records; a state from another
// timeline isn't taken for part of the movie.
// Uses a test ROM fetched by the scripts; without it these pass with a note.

const String ROM = "test/blargg/dmg_sound/03-trigger.gb";

fn gameboy::GameBoy? boot() {
	char[] data = file::load_temp(ROM)!;
	gameboy::GameBoy gb = gameboy::new(true, DMG);
	gb.load_rom(data);
	if (gb.mmu.cart) gb.mmu.cart.has_battery = false;
	return gb;
}

// Some made-up play: buttons that change every few frames.
fn void buttons_for(ulong f, char* buttons, char* dpad) {
	uint x = (uint)(f / 5) * 2654435761u;
	*buttons = (char)(x >> 28);
	*dpad = (char)((x >> 24) & 0x0F);
}

// A frame with these buttons, recorded into the movie.
fn void play_recording(gameboy::GameBoy* gb, gameboy::Movie* m, char buttons, char dpad) {
	ulong k = m.position(gb)!!;
	m.record(k, buttons, dpad);
	gb.mmu.set_input(buttons, dpad);
	gb.run_frame();
}

fn void recorded_run_plays_back_the_same() @test {
	gameboy::GameBoy? gb = boot();
	if (catch gb) {
		io::printfn("  (%s missing: scripts/fetch-blargg.sh)", ROM);
		return;
	}
	defer gb.destroy();
	for (int f = 0; f < 40; f++) gb.run_frame();

	gameboy::Movie m;
	defer m.free();
	m.begin(&gb, "TEST");
	for (ulong f = 0; f < 300; f++) {
		char b;
		char d;
		buttons_for(f, &b, &d);
		play_recording(&gb, &m, b, d);
	}
	test::eq(m.len(), 300ul);
	char[] end_fb = mem::new_array(char, gb.mmu.ppu.fb.len);
	defer free(end_fb.ptr);
	end_fb[..] = gb.mmu.ppu.fb[..];
	ulong end_clk = gb.cpu.clk;
	uint end_hash = gb.mmu.input_hash;

	// Through the file and back, then played on a fresh machine.
	gameboy::Movie back = gameboy::parse_movie(m.to_text(tmem))!!;
	defer back.free();
	test::eq(back.len(), 300ul);
	test::@check(back.start == m.start, "same starting state");
	gameboy::GameBoy other = boot()!!;
	defer other.destroy();
	back.restart(&other)!!;
	for (ulong k = 0; k < back.len(); k++) {
		test::eq(back.position(&other)!!, k);
		char b;
		char d;
		back.at(k, &b, &d);
		other.mmu.set_input(b, d);
		other.run_frame();
	}
	test::eq(other.cpu.clk, end_clk);
	test::eq(other.mmu.input_hash, end_hash);
	test::@check(other.mmu.ppu.fb[..] == end_fb, "same picture at the end");
	test::eq(back.position(&other)!!, 300ul); // at the end
}

fn void going_back_rerecords() @test {
	gameboy::GameBoy? gb = boot();
	if (catch gb) return;
	defer gb.destroy();
	gameboy::Movie m;
	defer m.free();
	m.begin(&gb, "TEST");
	char[] at50;
	char[] at80;
	defer free(at50.ptr);
	defer free(at80.ptr);
	for (ulong f = 0; f < 100; f++) {
		if (f == 50) at50 = gb.save_state(mem);
		if (f == 80) at80 = gb.save_state(mem);
		play_recording(&gb, &m, 0, (char)(f & 3));
	}
	// Back to frame 50: the movie goes on from there, other buttons.
	gb.load_state(at50)!!;
	test::eq(m.position(&gb)!!, 50ul);
	for (ulong f = 50; f < 90; f++) play_recording(&gb, &m, joypad::BTN_A, 0);
	test::eq(m.len(), 90ul);
	// The state at 80 was from the first take: not this movie any more.
	gb.load_state(at80)!!;
	test::@check(!@ok(m.position(&gb)), "a state from another timeline");
}

fn void bad_files_are_refused() @test {
	foreach (text : (String[]){
		"",
		"not a movie\nframes: 1\ninput:\nstate:\nAAAA\n",
		"wer movie 1\ninput:\nstate:\nAAAA\n",                          // no frames
		"wer movie 1\nframes: 10\ninput:\n8:a*5\nstate:\nAAAA\n",       // past the end
		"wer movie 1\nframes: 10\ninput:\n2:jump*1\nstate:\nAAAA\n",    // no such button
		"wer movie 1\nframes: 10\ninput:\nstate:\n",                     // no state
		"wer movie 1\nframes: 10\ninput:\nstate:\n!!!!\n",               // not base64
	}) {
		test::@check(!@ok(gameboy::parse_movie(text)), "refused: %s", text);
	}
	gameboy::Movie m = gameboy::parse_movie("wer movie 1\ngame: X\nframes: 10\nrerecords: 3\ninput:\n2:a+up*3,7:start*1\nstate:\nAAAA\n")!!;
	defer m.free();
	test::eq(m.len(), 10ul);
	test::eq(m.rerecords, 3ul);
	char b;
	char d;
	m.at(3, &b, &d);
	test::eq(b, joypad::BTN_A);
	test::eq(d, joypad::PAD_UP);
	m.at(5, &b, &d);
	test::eq(b | d, (char)0);
	test::eq(gameboy::keys_text((char)(joypad::BTN_START << 4 | joypad::PAD_LEFT)), "start+left");
}
