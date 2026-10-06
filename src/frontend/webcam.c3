module display;
import sdl, std::io;

// The Game Boy Camera's sensor, fed from a real camera: a webcam, the
// phone's front camera (else its first one), or the browser's. Opened only
// while a camera cartridge runs (the system may ask the player first); its
// newest frame becomes the 128x112 grey picture the cartridge sees, cut to
// the sensor's shape from the middle, turned upright and, for a camera that
// faces the player, mirrored.

const int SENSOR_W = 128;
const int SENSOR_H = 112;

// Camera picture size to ask for: the smallest one at least this big.
const int CAMERA_MIN_W = 160;
const int CAMERA_MIN_H = 144;

// The newest picture for a camera cartridge (empty until the camera gives
// one); `wanted` false closes the camera.
fn char[] Display.camera(&self, bool wanted) {
	if (!wanted) {
		if (self.cam) sdl::close_camera(self.cam);
		self.cam = null;
		self.cam_tried = false;
		return {};
	}
	if (!self.cam && !self.cam_tried) self.open_camera();
	if (!self.cam) return {};

	// Every frame that is waiting: only the newest one counts.
	sdl::Surface* newest;
	ulong ts;
	while (sdl::Surface* f = sdl::acquire_camera_frame(self.cam, &ts)) {
		if (newest) sdl::release_camera_frame(self.cam, newest);
		newest = f;
	}
	if (!newest) return self.cam_have ? self.cam_image[..] : (char[]){};
	float rotation = sdl::get_float_property(sdl::get_surface_properties(newest), sdl::PROP_SURFACE_ROTATION_FLOAT, 0);
	sdl::Surface* rgb = newest;
	if (newest.format != sdl::PIXELFORMAT_XRGB8888) rgb = sdl::convert_surface(newest, sdl::PIXELFORMAT_XRGB8888);
	if (rgb) {
		self.sensor_from(rgb, ((int)(rotation + 360.5f) / 90) % 4);
		self.cam_have = true;
		if (rgb != newest) sdl::destroy_surface(rgb);
	}
	sdl::release_camera_frame(self.cam, newest);
	return self.cam_have ? self.cam_image[..] : (char[]){};
}

fn void Display.open_camera(&self) {
	self.cam_tried = true;
	if (!sdl::init_subsystem(sdl::INIT_CAMERA)) return;
	int count;
	uint* ids = sdl::get_cameras(&count);
	if (!ids) return;
	defer sdl::free(ids);
	if (count == 0) {
		io::printfn("no camera: the Game Boy Camera sees noise");
		return;
	}
	uint id = ids[0];
	for (int i = 0; i < count; i++) {
		if (sdl::get_camera_position(ids[i]) == sdl::CAMERA_POSITION_FRONT_FACING) {
			id = ids[i];
			break;
		}
	}
	self.cam_mirror = sdl::get_camera_position(id) == sdl::CAMERA_POSITION_FRONT_FACING;

	// The smallest picture the camera makes as it is (not Motion JPEG, which
	// SDL can't turn into pixels), asked for as XRGB.
	sdl::CameraSpec want = { .format = sdl::PIXELFORMAT_XRGB8888, .width = 320, .height = 240 };
	int n;
	sdl::CameraSpec** specs = sdl::get_camera_supported_formats(id, &n);
	if (specs) {
		sdl::CameraSpec* best;
		for (int i = 0; i < n; i++) {
			sdl::CameraSpec* s = specs[i];
			if (s.format == sdl::PIXELFORMAT_MJPG || s.width < CAMERA_MIN_W || s.height < CAMERA_MIN_H) continue;
			if (!best || s.width * s.height < best.width * best.height) best = s;
		}
		if (best) {
			want = *best;
			want.format = sdl::PIXELFORMAT_XRGB8888;
		}
		sdl::free(specs);
	}
	self.cam = sdl::open_camera(id, &want);
	if (!self.cam) io::eprintfn("camera: %s", sdl::get_error().str_view());
}

// The sensor picture from an XRGB frame that has to be turned `quarter`
// quarter turns clockwise to stand upright.
fn void Display.sensor_from(&self, sdl::Surface* f, int quarter) {
	int w = f.w;
	int h = f.h;
	int uw = quarter & 1 ? h : w; // upright size
	int uh = quarter & 1 ? w : h;
	// The middle of it, in the sensor's shape (8:7).
	int cw = uw;
	int ch = uh;
	if (cw * SENSOR_H > ch * SENSOR_W) {
		cw = ch * SENSOR_W / SENSOR_H;
	} else {
		ch = cw * SENSOR_H / SENSOR_W;
	}
	int x0 = (uw - cw) / 2;
	int y0 = (uh - ch) / 2;
	char* px = f.pixels;
	for (int ty = 0; ty < SENSOR_H; ty++) {
		int v0 = y0 + ty * ch / SENSOR_H;
		int v1 = y0 + (ty + 1) * ch / SENSOR_H;
		if (v1 == v0) v1++;
		for (int tx = 0; tx < SENSOR_W; tx++) {
			int u0 = x0 + tx * cw / SENSOR_W;
			int u1 = x0 + (tx + 1) * cw / SENSOR_W;
			if (u1 == u0) u1++;
			// The average brightness of the block it covers.
			uint sum;
			uint count;
			for (int v = v0; v < v1; v++) {
				for (int u = u0; u < u1; u++) {
					int mu = self.cam_mirror ? uw - 1 - u : u;
					int x;
					int y;
					switch (quarter) {
						case 1:  x = v;          y = h - 1 - mu;
						case 2:  x = w - 1 - mu; y = h - 1 - v;
						case 3:  x = w - 1 - v;  y = mu;
						default: x = mu;         y = v;
					}
					uint p = *(uint*)(px + y * f.pitch + x * 4);
					sum += ((p >> 16 & 0xFF) * 77 + (p >> 8 & 0xFF) * 150 + (p & 0xFF) * 29) >> 8;
					count++;
				}
			}
			self.cam_image[ty * SENSOR_W + tx] = (char)(sum / count);
		}
	}
}
