module cart;

import std::math;

// Gyogun Tanchiki: Pocket Sonar (Bandai, 1998): a fish finder in a
// cartridge. Its MBC1S is an MBC1 without RAM whose RAM registers work the
// sonar (Dan Docs, shonumi.github.io/dandocs.html#pocketsonar):
//   $2000-$3FFF  ROM bank, as the MBC1's
//   $4000-$5FFF  1 sends a pulse, 0 ends it (in sonar mode)
//   $6000-$7FFF  1: sonar mode
//   $A000        the echo now: before the floor 1 an object's edge, 2-3 its
//                inside, 4-7 open water; a single $00 is the floor, then 0-3
//                its surface, 4-7 the ground below
// The game reads $A000 at a pace that fits its depth setting (all of 2 m
// within a frame, 30 m over five), so what a read sees is how deep the sound
// has gone and come back since the pulse: half of 1500 m/s.
//
// What it sees is a made-up lake: a floor between 1 and 13 m that rises and
// falls as the boat drifts (a ping is a step), now and then a rock on it, and
// fish, each one echo for a few pings.

const double SONAR_SOUND = 750.0;   // metres of depth per second after the pulse

struct Sonar {
	bool  mode;
	bool  pulse;
	ulong since;      // emulated cycles since the last pulse
	uint  pings;
	// This ping's echoes so far.
	bool  floor_seen;
	bool  fish_seen;
}

fn bool is_pocket_sonar(char[] rom) => rom.len >= 0x150 && (String)rom[0x134 : 11] == "POCKETSONAR";

fn void Cartridge.sonar_control(&self, ushort addr, char value) {
	Sonar* s = &self.sonar;
	switch {
		case addr < 0x2000:
			break;
		case addr < 0x4000:
			self.bank1 = value & 0x1F;
			if (!self.bank1) self.bank1 = 1;
		case addr < 0x6000:
			if (!s.mode) return;
			bool on = (value & 1) != 0;
			if (on && !s.pulse) {
				s.since = 0;
				s.pings++;
				s.floor_seen = false;
				s.fish_seen = false;
			}
			s.pulse = on;
		default:
			s.mode = (value & 1) != 0;
	}
}

fn void Sonar.tick(&self, uint cycles) {
	self.since += cycles;
}

// The lake under ping p: the floor's depth, and a fish's (0: none).
fn double sonar_floor(uint p) {
	double x = (double)p;
	return 7.0 + 4.5 * math::sin(x / 47.0) + 1.5 * math::sin(x / 13.0 + 1.0);
}

fn uint sonar_hash(uint p) {
	uint h = p * 0x9E3779B1;
	h ^= h >> 15;
	h *= 0x85EBCA77;
	return h ^ (h >> 13);
}

fn double sonar_fish(uint p) {
	// A fish stays under the boat for a few pings: groups of 8, a fish in
	// one group of three, for pings 2-6 of it.
	uint g = p / 8;
	uint h = sonar_hash(g + 0x1000);
	if (h % 3 != 0 || p % 8 < 2 || p % 8 > 6) return 0;
	double floor = sonar_floor(g * 8);
	if (floor < 1.5) return 0;
	return 0.5 + (double)((h >> 8) % 1000) / 1000.0 * (floor - 1.0);
}

// A rock on the floor here: how high it stands (0: none).
fn double sonar_rock(uint p) {
	uint h = sonar_hash(p / 6 + 0x5000);
	if (h % 7 != 0) return 0;
	return 0.4 + (double)((h >> 8) % 100) / 100.0;
}

fn char Cartridge.sonar_read(&self) {
	Sonar* s = &self.sonar;
	if (!s.mode) return 0xFF;
	uint hz = self.rtc.cpu_hz ? self.rtc.cpu_hz : RTC_CPU_HZ;
	double depth = (double)s.since / (double)hz * SONAR_SOUND;
	double floor = sonar_floor(s.pings);
	if (s.floor_seen) return depth < floor + 0.4 ? 0 : 4;
	double fish = sonar_fish(s.pings);
	if (fish > 0 && !s.fish_seen && depth >= fish) {
		s.fish_seen = true;
		return 1;
	}
	double rock = sonar_rock(s.pings);
	if (rock > 0 && depth >= floor - rock) {
		if (depth < floor - rock + 0.15) return 1;
		if (depth < floor) return 2;
	}
	if (depth >= floor) {
		s.floor_seen = true;
		return 0;
	}
	return 7;
}
