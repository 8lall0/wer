module display;
import sdl, std::math;

// Tilt for MBC7 cartridges (Kirby Tilt 'n' Tumble) and their opposite,
// rumble cartridges' motor.
//
// Tilt comes from, in this order: a gamepad's left stick (then it isn't the
// d-pad), I/J/K/L on the keyboard (easing in and out, like tipping a Game
// Boy), or the phone's own accelerometer (Android; in a browser, the page's
// devicemotion handler, web/index.html). x > 0 is tilted right, y > 0 toward
// the player (the bottom edge down), in g.
//
// Rumble goes to every gamepad that has a motor, the phone's vibrator on
// Android, and navigator.vibrate in a browser (on or off only).

// Left stick deflection (of 32767) below which the stick leaves tilt to the
// keys and the accelerometer.
const short TILT_DEADZONE = 4000;
// Keyboard tilt: the change per frame (full tilt in a sixth of a second).
const float KEY_TILT_STEP = 0.1;
const int SC_I = 12;
const int SC_J = 13;
const int SC_K = 14;
const int SC_L = 15;
// Gamepad / phone rumble is asked for this long and renewed while it lasts.
const uint RUMBLE_MS = 1000;
const int RUMBLE_RENEW = 30; // frames

// The page's accelerometer reading (wer_motion), in g, screen-oriented.
float web_tilt_x;
float web_tilt_y;
bool  web_motion;

fn void web_motion_reading(float x, float y) @export("wer_motion") {
	web_tilt_x = x;
	web_tilt_y = y;
	web_motion = true;
}

// The tilt to give an MBC7 game this frame; `wanted` false (another game)
// stops reading the accelerometer.
fn float[<2>] Display.tilt(&self, bool wanted) {
	if (wanted != self.tilt_on) {
		self.tilt_on = wanted;
		self.key_tilt = {};
		if (wanted) {
			self.open_accelerometer();
		} else {
			self.close_accelerometer();
		}
	}
	if (!wanted) return {};

	foreach (p : self.pads) {
		if (!p) continue;
		short x = sdl::get_gamepad_axis(p, sdl::GAMEPAD_AXIS_LEFTX);
		short y = sdl::get_gamepad_axis(p, sdl::GAMEPAD_AXIS_LEFTY);
		if (math::abs((int)x) > TILT_DEADZONE || math::abs((int)y) > TILT_DEADZONE) {
			return { x / 32767.0f, y / 32767.0f };
		}
	}

	int n;
	char* ks = sdl::get_keyboard_state(&n);
	float[<2>] target;
	if (self.tilt_key(ks, n, SC_J)) target.x -= 1;
	if (self.tilt_key(ks, n, SC_L)) target.x += 1;
	if (self.tilt_key(ks, n, SC_I)) target.y -= 1;
	if (self.tilt_key(ks, n, SC_K)) target.y += 1;
	for (int i = 0; i < 2; i++) {
		float d = target[i] - self.key_tilt[i];
		self.key_tilt[i] += math::clamp(d, -KEY_TILT_STEP, KEY_TILT_STEP);
	}
	if (target != (float[<2>]){} || self.key_tilt != (float[<2>]){}) return self.key_tilt;

	return self.accelerometer();
}

fn bool Display.tilt_key(&self, char* ks, int n, int scancode) {
	return scancode < n && ks[scancode] != 0 && !self.is_bound(scancode);
}

fn void Display.open_accelerometer(&self) {
	$if env::ANDROID:
		int count;
		uint* ids = sdl::get_sensors(&count);
		if (!ids) return;
		for (int i = 0; i < count && !self.accel; i++) {
			if (sdl::get_sensor_type_for_id(ids[i]) == sdl::SENSOR_ACCEL) self.accel = sdl::open_sensor(ids[i]);
		}
		sdl::free(ids);
	$endif
	$if env::EMSCRIPTEN:
		run_script("werMotion(true)");
	$endif
}

fn void Display.close_accelerometer(&self) {
	$if env::ANDROID:
		if (self.accel) sdl::close_sensor(self.accel);
		self.accel = null;
	$endif
	$if env::EMSCRIPTEN:
		run_script("werMotion(false)");
		web_motion = false;
	$endif
}

// The accelerometer as screen tilt, or none without one.
fn float[<2>] Display.accelerometer(&self) {
	$if env::EMSCRIPTEN:
		return web_motion ? (float[<2>]){ web_tilt_x, web_tilt_y } : (float[<2>]){};
	$else
		if (!self.accel) return {};
		float[3] a;
		if (!sdl::get_sensor_data(self.accel, &a, 3)) return {};
		return screen_tilt(a[0], a[1], self.display_rotation());
	$endif
}

// How far the screen is turned from the device's natural orientation, in
// quarter turns counterclockwise (Android's Surface.ROTATION_*).
fn int Display.display_rotation(&self) {
	uint d = sdl::get_display_for_window(self.window);
	int now = quarter_turns(sdl::get_current_display_orientation(d));
	int natural = quarter_turns(sdl::get_natural_display_orientation(d));
	if (now < 0 || natural < 0) return 0;
	return (now - natural + 4) % 4;
}

fn int quarter_turns(int orientation) {
	switch (orientation) {
		case sdl::ORIENTATION_PORTRAIT:          return 0;
		case sdl::ORIENTATION_LANDSCAPE:         return 1;
		case sdl::ORIENTATION_PORTRAIT_FLIPPED:  return 2;
		case sdl::ORIENTATION_LANDSCAPE_FLIPPED: return 3;
		default:                                 return -1;
	}
}

// An accelerometer reading (m/s^2, device axes: x right, y up) as the tilt
// of the screen the player sees. Lying flat it reads +g out of the screen
// and nothing along it; tipping the right edge down shows -x, the bottom
// edge down +y.
fn float[<2>] screen_tilt(float ax, float ay, int rotation) {
	float sx, sy; // along the screen as shown: right, up
	switch (rotation) {
		case 1:  sx = -ay; sy = ax;
		case 2:  sx = -ax; sy = -ay;
		case 3:  sx = ay;  sy = -ax;
		default: sx = ax;  sy = ay;
	}
	return { -sx / sdl::STANDARD_GRAVITY, sy / sdl::STANDARD_GRAVITY };
}

// The motor of a rumble cartridge, 0..1, once a frame.
fn void Display.rumble(&self, float level) {
	// Eight steps: the share of on-writes jitters from frame to frame.
	int step = (int)(math::clamp(level, 0, 1) * 8 + 0.5f);
	bool renew = step != 0 && ++self.rumble_frames >= RUMBLE_RENEW;
	if (step == self.rumble_step && !renew) return;
	self.rumble_step = step;
	self.rumble_frames = 0;
	float s = step / 8.0f;
	ushort strength = (ushort)(s * 0xFFFF);
	foreach (p : self.pads) {
		if (p) sdl::rumble_gamepad(p, strength, strength, step ? RUMBLE_MS : 0);
	}
	$if env::ANDROID:
		if (!self.haptic_tried) {
			self.haptic_tried = true;
			int count;
			uint* ids = sdl::get_haptics(&count);
			if (ids && count > 0) {
				self.haptic = sdl::open_haptic(ids[0]);
				if (self.haptic && !sdl::init_haptic_rumble(self.haptic)) {
					sdl::close_haptic(self.haptic);
					self.haptic = null;
				}
			}
			if (ids) sdl::free(ids);
		}
		if (self.haptic) {
			if (step) {
				sdl::play_haptic_rumble(self.haptic, s, RUMBLE_MS);
			} else {
				sdl::stop_haptic_rumble(self.haptic);
			}
		}
	$endif
	$if env::EMSCRIPTEN:
		// A phone's vibrator is on or off.
		run_script(step >= 3 ? "navigator.vibrate && navigator.vibrate(1000)" : "navigator.vibrate && navigator.vibrate(0)");
	$endif
}
