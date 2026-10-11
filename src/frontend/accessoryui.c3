module wer;
import std::io, std::io::file;
import mmu, config, gameboy;

// The small link port devices in the Link menu:
//
//   Turbo File GB (RPG Tsukuru GB 1 and 2): its memory and card are
//     ~/.wer/turbo-file.bin (2 MiB), one drive for every game, as the real one
//   Power Antenna / Bug Sensor (Telefang, Bugsite): a red light at the
//     picture's top right while lit
//   Bardigun reader (Barcode Taisen Bardigun): Swipe card..., a 13-digit
//     barcode typed in
//   Full Changer (Zok Zok Heroes): the Character line picks one of the 70,
//     Enter waves it

const String TURBO_FILE = "turbo-file.bin";

mmu::TurboFile turbo;
mmu::Link turbo_cable;
char[] turbo_data;

mmu::PowerAntenna antenna;
mmu::Link antenna_cable;

mmu::Bardigun bardigun;
mmu::Link bardigun_cable;

mmu::FullChanger changer;
mmu::Link changer_cable;
int changer_pick = 1;   // the character on the menu's line

fn String turbo_path() {
	String conf = config::tpath();
	if (!conf.len) return "";
	return conf[:conf.len - config::FILE.len].tconcat(TURBO_FILE);
}

fn void turbo_plug() {
	if (!turbo_data.len) {
		turbo_data = mem::new_array(char, mmu::TURBO_SIZE);
		turbo_data[..] = 0xFF; // erased flash
		String path = turbo_path();
		if (path.len) {
			if (try saved = file::load_temp(path)) {
				usz n = saved.len < turbo_data.len ? saved.len : turbo_data.len;
				turbo_data[:n] = saved[:n];
			}
		}
	}
	turbo.init(turbo_data, (uint)gb.mmu.model.clock_hz());
	gb.mmu.connect_turbo(&turbo_cable, &turbo);
	link_mode = TURBO;
	notice.show("Turbo File GB connected");
}

// After each frame: what the game wrote is kept.
fn void turbo_save() {
	if (!turbo.changed) return;
	turbo.changed = false;
	String path = turbo_path();
	if (!path.len) return;
	config::make_dir(path);
	if (catch file::save(path, turbo_data)) notice.show("Could not save the Turbo File");
}

fn void antenna_plug() {
	antenna.init((uint)gb.mmu.model.clock_hz());
	gb.mmu.connect_antenna(&antenna_cable, &antenna);
	link_mode = ANTENNA;
	notice.show("Power Antenna connected");
}

fn void bardigun_plug() {
	bardigun = {};
	gb.mmu.connect_bardigun(&bardigun_cable, &bardigun);
	link_mode = BARDIGUN;
	notice.show("Bardigun: Menu > Swipe card");
}

fn void changer_plug() {
	changer = {};
	gb.mmu.connect_changer(&changer_cable, &changer);
	link_mode = CHANGER;
	notice.show("Full Changer: Menu > Character");
}

fn void accessory_replug() {
	switch (link_mode) {
		case TURBO:    gb.mmu.connect_turbo(&turbo_cable, &turbo);
		case ANTENNA:  gb.mmu.connect_antenna(&antenna_cable, &antenna);
		case BARDIGUN: gb.mmu.connect_bardigun(&bardigun_cable, &bardigun);
		case CHANGER:  gb.mmu.connect_changer(&changer_cable, &changer);
		default:       break;
	}
}

fn String changer_line() => string::tformat("Character: < %02d %s >", changer_pick, mmu::CHANGER_NAMES[changer_pick - 1]);

fn void changer_step(int step) {
	changer_pick = (changer_pick - 1 + step + 70) % 70 + 1;
}

fn void changer_wave() {
	changer.wave(changer_pick);
	menu = false;
	notice.show(string::tformat("Full Changer: %s", mmu::CHANGER_NAMES[changer_pick - 1]));
}

// The Power Antenna's light on the picture: a red dot, top right.
fn void antenna_light(char[] picture, gameboy::FrameSize size) {
	if (link_mode != ANTENNA || !antenna.lit(gb.mmu.rt_clock)) return;
	for (int y = 2; y < 7; y++) {
		for (int x = size.w - 7; x < size.w - 2; x++) {
			usz at = (usz)((y * size.w + x) * 3);
			picture[at] = 0xFF;
			picture[at + 1] = 0x20;
			picture[at + 2] = 0x20;
		}
	}
}
