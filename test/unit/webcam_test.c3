module webcam_test;
import display, sdl;
import std::core::test;

// A camera frame becomes the sensor picture: the middle 8:7 of it, upright,
// mirrored for a camera facing the player.

// A 320x240 XRGB frame: white where x < 160 (its left half), else black.
fn sdl::Surface frame(uint[] px, int w, int h, bool left_white) {
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) px[y * w + x] = (x < w / 2) == left_white ? 0xFFFFFF : 0;
	}
	return { .format = sdl::PIXELFORMAT_XRGB8888, .w = w, .h = h, .pitch = w * 4, .pixels = px.ptr };
}

fn char at(display::Display* d, int x, int y) => d.cam_image[y * 128 + x];

fn void upright_and_mirrored() @test {
	display::Display* d = mem::new(display::Display);
	defer free(d);
	uint[] px = mem::new_array(uint, 320 * 240);
	defer free(px.ptr);
	sdl::Surface f = frame(px, 320, 240, true);
	d.sensor_from(&f, 0);
	test::eq(at(d, 0, 50), 255);
	test::eq(at(d, 127, 50), 0);
	d.cam_mirror = true;
	d.sensor_from(&f, 0);
	test::eq(at(d, 0, 50), 0);
	test::eq(at(d, 127, 50), 255);
	d.cam_mirror = false;
	// A frame to turn a quarter clockwise: its left half becomes the top.
	d.sensor_from(&f, 1);
	test::eq(at(d, 64, 0), 255);
	test::eq(at(d, 64, 111), 0);
	d.sensor_from(&f, 3);
	test::eq(at(d, 64, 0), 0);
	test::eq(at(d, 64, 111), 255);
	d.sensor_from(&f, 2);
	test::eq(at(d, 0, 50), 0);
	test::eq(at(d, 127, 50), 255);
}

fn void brightness_is_luma() @test {
	display::Display* d = mem::new(display::Display);
	defer free(d);
	uint[] px = mem::new_array(uint, 160 * 140);
	defer free(px.ptr);
	foreach (&p : px) *p = 0x00FF00; // green
	sdl::Surface f = { .format = sdl::PIXELFORMAT_XRGB8888, .w = 160, .h = 140, .pitch = 160 * 4, .pixels = px.ptr };
	d.sensor_from(&f, 0);
	test::eq(at(d, 10, 10), 149);
}
