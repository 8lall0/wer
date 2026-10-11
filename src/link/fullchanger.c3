module mmu;

// The Full Changer of Zok Zok Heroes (Media Factory, 2000): a toy waved in
// the air to draw a "Cosmic Character", which it then sends to the GBC's
// infrared port. From Dan Docs (shonumi.github.io/dandocs.html#zzh):
//
//   18 pulses, each light on then off; the game counts loops through each
//   (20 cycles of normal speed a loop) and keeps the count: the first long
//   (over $20), then 16 bits LSB first, short (up to $13) a 0 and long
//   ($14-$20) a 1: a byte, then the character's ID complemented, the two
//   adding up to $FF. The 18th pulse is needed but not read.
//
// The light comes on just after the game first looks at RP once the toy is
// waved (then the game's own counting starts with it), as GBE+ does.

const int[3] CHANGER_COUNT = { 0x0A, 0x1A, 0x30 }; // short, long, the first

// The 70 characters' names (IDs 1-70).
const String[70] CHANGER_NAMES = {
	"Alkaline Powered", "In Water", "Ultra Runner", "Aero Power", "Ochaapa",
	"Kaizer Edge", "King Batter", "Crash Car", "Cellphone Tiger", "Cup Ace",
	"Sakanard", "Thin Delta", "Skateboard Rider", "Celery Star", "Cleaning Killer",
	"Takoyaki Kid", "Chinkoman", "Tsukai Stater", "Teppangar", "Tongararin",
	"Nagashiman", "Ninja", "Plushy-chan", "Screw Razor", "Nobel Brain",
	"Hard Hammer", "Heat Man", "Flame Gourmet", "Hercules Army", "Hot Card",
	"Mr. Muscle", "Mist Water", "Mushimushi Man", "Megaaten", "Mobile Robot X",
	"Yaki Bird", "Utron", "Yo-Yo Mask", "Radial Road", "Remote-Control Man",
	"Ruby Hook", "Retro Sounder", "Rocket Bastard", "Wild Sword", "Guts Lago",
	"Giniun", "Great Fire", "Gamemark", "Gorilla Killa", "The Climber",
	"G Shark", "Zoom Laser", "Zenmai", "Elephant Shower", "Diamond Mall",
	"Digronyan", "Ziza One", "Danger Red", "Dohatsuten", "Balloon",
	"Videoja", "Boo Boo", "Belt Jain", "Boat Ron", "Perfect Sun",
	"Pinspawn", "Press Arm", "Pegasus Boy", "Pop Thunder", "Ndjamenas",
};

struct FullChanger {
	ulong[37] edge;     // rt_clock of each change, from the first light on
	int       edges;
	bool      waved;    // waiting for the game to look
	ulong     start;    // rt_clock of the first light
	bool      sending;
}

// Each pulse's loop count: the start, the byte, the ID complemented, one more.
fn void changer_counts(int id, int[18]* counts) {
	char second = (char)~id;
	char first = 0xFF - second;
	(*counts)[0] = CHANGER_COUNT[2];
	for (int i = 0; i < 8; i++) {
		(*counts)[1 + i] = CHANGER_COUNT[(first >> i) & 1];
		(*counts)[9 + i] = CHANGER_COUNT[(second >> i) & 1];
	}
	(*counts)[17] = CHANGER_COUNT[1];
}

// Wave the toy: character `id` (1-70) goes out.
fn void FullChanger.wave(&self, int id) {
	int[18] counts;
	changer_counts(id, &counts);
	// Each count split between the light on and off; the game's loops take
	// 20 cycles, plus a few for the code around them.
	ulong t;
	self.edges = 0;
	foreach (i, c : counts) {
		int on = c / 2;
		int off = c - on;
		t += (ulong)((i == 0 ? 74 : 78) + 20 * (on - 2));
		self.edge[self.edges++] = t;  // goes off
		t += (ulong)(38 + 20 * (off - 2));
		self.edge[self.edges++] = t;  // comes on
	}
	t += 400;
	self.edge[self.edges++] = t;      // the last light off
	self.waved = true;
	self.sending = false;
}

// Is the light on, as the game reads RP at `now`?
fn bool FullChanger.seen(&self, ulong now) {
	if (self.waved) {
		// The game looked: the light comes on just after.
		self.waved = false;
		self.sending = true;
		self.start = now + 4;
		return false;
	}
	if (!self.sending) return false;
	if (now < self.start) return false;
	ulong t = now - self.start;
	int changes;
	while (changes < self.edges && t >= self.edge[changes]) changes++;
	if (changes == self.edges) {
		self.sending = false;
		return false;
	}
	return changes % 2 == 0; // on at the start, off after the first edge ...
}

fn void Mmu.connect_changer(&self, Link* l, FullChanger* c) {
	*l = { .changer = c };
	self.link = l;
}
