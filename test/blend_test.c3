module blend_test;
import display;
import std::core::test;

// Frame blending (display/blend.c3) on a 2x2 picture: black, then white.
fn char[] two_frames(display::Blend mode, bool odd) {
	display::Display d;
	d.prev = mem::temp_array(char, 12);
	d.mixed = mem::temp_array(char, 12);
	d.blend = mode;
	char[12] black;
	char[12] white;
	white[..] = 0xFF;
	d.blended(&black, 2, 2);
	d.odd_frame = odd;
	char[] out = mem::temp_array(char, 12);
	out[..] = d.blended(&white, 2, 2)[:12];
	return out;
}

fn void off_shows_the_frame() @test {
	char[] out = two_frames(OFF, false);
	test::eq(out[0], 0xFF);
	test::eq(out[9], 0xFF);
}

fn void simple_mixes_half_and_half_in_linear_light() @test {
	char[] out = two_frames(SIMPLE, false);
	// (0.5 ^ (1 / 2.2)) * 255
	test::eq(out[0], 186);
	test::eq(out[6], 186);
}

fn void accurate_alternates_rows_and_swaps_on_odd_frames() @test {
	char[] even = two_frames(ACCURATE, false);
	char[] odd = two_frames(ACCURATE, true);
	// Even frame: row 0 keeps a third of the last frame, row 1 two thirds.
	test::eq(even[0], 212); // (2/3) ^ (1/2.2) * 255
	test::eq(even[6], 155); // (1/3) ^ (1/2.2) * 255
	test::eq(odd[0], 155);
	test::eq(odd[6], 212);
}

fn void first_frame_and_size_changes_are_not_blended() @test {
	display::Display d;
	d.prev = mem::temp_array(char, 12);
	d.mixed = mem::temp_array(char, 12);
	d.blend = SIMPLE;
	char[12] white;
	white[..] = 0xFF;
	test::eq(d.blended(&white, 2, 2)[0], 0xFF);
	char[3] one = { 0, 0, 0 };
	test::eq(d.blended(&one, 1, 1)[0], 0);
}
