module mmu;

// The Power Antenna (Keitai Denjuu Telefang) and Bug Sensor (Network
// Adventure Bugsite): a red light on the link port. From Dan Docs
// (shonumi.github.io/dandocs.html#pabs): the game clocks one byte; $00
// turns it off, an odd byte lights it, an even one flashes it dimly for a
// moment. It answers $F3 while lit, $F2 when dark.

const ulong ANTENNA_FLASH_US = 50_000; // how long a dim flash shows

struct PowerAntenna {
	bool  on;          // lit until $00
	ulong flash_until; // rt_clock a dim flash lasts until
	uint  hz;
}

fn void PowerAntenna.init(&self, uint hz) {
	*self = { .hz = hz };
}

fn void Mmu.connect_antenna(&self, Link* l, PowerAntenna* a) {
	*l = { .antenna = a };
	self.link = l;
}

fn char PowerAntenna.exchange(&self, char b, ulong now) {
	if (b == 0) {
		self.on = false;
		self.flash_until = 0;
	} else if (b & 1) {
		self.on = true;
	} else {
		self.flash_until = now + ANTENNA_FLASH_US * self.hz / 1_000_000;
	}
	return self.lit(now) ? 0xF3 : 0xF2;
}

fn bool PowerAntenna.lit(&self, ulong now) => self.on || now < self.flash_until;
