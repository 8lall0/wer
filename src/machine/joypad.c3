module joypad;

const char BTN_A      = 0x01;
const char BTN_B      = 0x02;
const char BTN_SELECT = 0x04;
const char BTN_START  = 0x08;

const char PAD_RIGHT  = 0x01;
const char PAD_LEFT   = 0x02;
const char PAD_UP     = 0x04;
const char PAD_DOWN   = 0x08;

struct Joypad {
	char buttons; // A / B / Select / Start
	char dpad;    // Right / Left / Up / Down
	char select;  // bits 4-5 of the last write
}

fn char Joypad.read(&self) {
	char lo = 0x0F;
	if ((self.select & 0x10) == 0) lo &= (char)~self.dpad;
	if ((self.select & 0x20) == 0) lo &= (char)~self.buttons;
	return (char)(0xC0 | (self.select & 0x30) | (lo & 0x0F));
}

fn void Joypad.write(&self, char value) {
	self.select = value & 0x30;
}

fn bool Joypad.set_state(&self, char buttons, char dpad) {
	char before = self.read() & 0x0F;
	self.buttons = buttons;
	self.dpad = dpad;
	char after = self.read() & 0x0F;
	return (before & (char)~after) != 0;
}
