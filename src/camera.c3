module cart;

// The Game Boy Camera ($FC, POCKET CAMERA), after SameBoy (MIT: see
// LICENSE-sameboy). Its mapper is MBC5-like with 128 KiB of RAM; RAM bank
// values with bit 4 set map the M64282FP sensor's registers at $A000-$A035
// instead:
//   $A000  bit 0: shoot (reads 1 until the picture is in RAM)
//   $A001  gain (bits 0-4), edge enhancement on when bits 5-7 are all set
//   $A002/3  exposure time, in units of 16 cycles of its 1 MHz clock
//   $A004  edge enhancement ratio (bits 4-6)
//   $A006-$A035  4x4 dithering thresholds, three per pixel
// A shot takes a while (32 ms plus the exposure), then the 128x112 picture
// sits in RAM bank 0 at $A100-$AEFF as 16x14 tiles, where the game copies it
// from. The frontend gives the sensor a picture (GameBoy.set_camera_image);
// without one it sees noise.

const int CAM_W = 128;
const int CAM_H = 112;
const int CAM_REGS = 0x36;
const usz CAM_IMAGE_AT = 0x100; // in RAM bank 0
const usz CAM_IMAGE_LEN = 0xE00;

struct Camera {
	bool  mapped;               // RAM bank bit 4: the registers at $A000
	char[CAM_REGS] regs;
	int   countdown;            // T-cycles until the shot is done (0 = idle)
	uint  noise_seed;
	bool  has_image;            // the frontend gave a picture
	char[CAM_W * CAM_H] sensor; // brightness 0-255, row by row
}

fn void Cartridge.camera_control(&self, ushort addr, char value) {
	switch {
		case addr < 0x2000: self.ram_enabled = (value & 0x0F) == 0x0A;
		case addr < 0x4000: self.rom_bank = value & 0x3F;
		case addr < 0x6000:
			self.ram_bank = value & 0x0F;
			self.camera.mapped = (value & 0x10) != 0;
		default: break;
	}
}

fn bool Cartridge.camera_busy(&self) => (self.camera.regs[0] & 1) != 0;

fn char Cartridge.camera_read(&self, ushort addr) {
	if (self.camera.mapped) return (addr & 0x7F) == 0 ? self.camera.regs[0] : 0;
	// Readable without the RAM enable, but not while the sensor writes to it.
	if (self.camera_busy()) return 0;
	return self.ram_byte(addr);
}

fn void Cartridge.camera_write(&self, ushort addr, char value) {
	Camera* c = &self.camera;
	if (c.mapped) {
		int reg = addr & 0x7F;
		if (reg == 0) {
			value &= 7;
			if ((value & 1) && !self.camera_busy()) {
				int exposure = (int)c.regs[2] << 8 | c.regs[3];
				c.countdown = 129792 + ((c.regs[1] & 0x80) ? 0 : 2048) + exposure * 64;
				c.noise_seed = c.noise_seed * 1103515245 + 12345;
			}
			if (self.camera_busy()) value |= 1; // a shot can't be cancelled
			c.regs[0] = value;
		} else if (reg < CAM_REGS) {
			c.regs[reg] = value;
		}
		return;
	}
	if (!self.ram_enabled || self.camera_busy()) return;
	self.set_ram_byte(addr, value);
}

fn void Cartridge.camera_tick(&self, uint tcycles) {
	Camera* c = &self.camera;
	if (c.countdown == 0) return;
	c.countdown -= (int)tcycles;
	if (c.countdown > 0) return;
	c.countdown = 0;
	self.camera_develop();
	c.regs[0] &= 0xFE;
}

fn char camera_noise(int x, int y, uint seed) {
	uint value = (uint)(x * 151 + y * 149) ^ seed;
	uint hash;
	while (value) {
		hash <<= 1;
		if (hash & 0x100) hash ^= 0x101;
		if (value & 0x80000000) hash ^= 0xA1;
		value <<= 1;
	}
	return (char)hash;
}

const double[32] CAM_GAIN = {
	0.8809390, 0.9149149, 0.9457498, 0.9739758, 1.0000000, 1.0241412, 1.0466537, 1.0677433,
	1.0875793, 1.1240310, 1.1568911, 1.1868043, 1.2142561, 1.2396208, 1.2743837, 1.3157323,
	1.3525190, 1.3856512, 1.4157897, 1.4434309, 1.4689574, 1.4926697, 1.5148087, 1.5355703,
	1.5551159, 1.5735801, 1.5910762, 1.6077008, 1.6235366, 1.6386550, 1.6531183, 1.6669808,
};
const double[8] CAM_EDGE = { 0.5, 0.75, 1, 1.25, 2, 3, 4, 5 };

// A sensor pixel after gain and exposure; outside the picture, its edge.
fn long Camera.pixel(&self, int x, int y) {
	if (x >= CAM_W) x = x == CAM_W ? CAM_W - 1 : 0;
	if (x < 0) x = 0;
	if (y >= CAM_H) y = y == CAM_H ? CAM_H - 1 : 0;
	if (y < 0) y = 0;
	long v = self.has_image ? self.sensor[y * CAM_W + x] : camera_noise(x, y, self.noise_seed);
	v = (long)(v * CAM_GAIN[self.regs[1] & 0x1F]);
	return v * ((long)self.regs[2] << 8 | self.regs[3]) / 0x1000;
}

// The picture into RAM bank 0, in the tile layout the game reads.
fn void Cartridge.camera_develop(&self) {
	Camera* c = &self.camera;
	if (self.ram.len < CAM_IMAGE_AT + CAM_IMAGE_LEN) return;
	bool edges = (c.regs[1] & 0xE0) == 0xE0;
	double ratio = CAM_EDGE[(c.regs[4] >> 4) & 7];
	for (int y = 0; y < CAM_H; y++) {
		for (int x = 0; x < CAM_W; x++) {
			long v = c.pixel(x, y);
			if (edges) {
				double e = (double)v + (double)v * 4 * ratio;
				e -= (double)(c.pixel(x - 1, y) + c.pixel(x + 1, y) + c.pixel(x, y - 1) + c.pixel(x, y + 1)) * ratio;
				v = (long)e;
			}
			int t = ((x & 3) + (y & 3) * 4) * 3 + 6;
			char shade = v < c.regs[t] ? 3 : v < c.regs[t + 1] ? 2 : v < c.regs[t + 2] ? 1 : 0;
			usz at = CAM_IMAGE_AT + (usz)((y / 8) * 16 + x / 8) * 16 + (usz)(y & 7) * 2;
			char bit = (char)(0x80 >> (x & 7));
			self.ram[at] = (self.ram[at] & ~bit) | ((shade & 1) ? bit : 0);
			self.ram[at + 1] = (self.ram[at + 1] & ~bit) | ((shade & 2) ? bit : 0);
		}
	}
}
