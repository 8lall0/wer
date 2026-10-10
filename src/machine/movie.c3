module gameboy;
import mmu, joypad;
import std::io, std::io::file, std::collections::list, std::encoding::base64;

// A movie (for tool-assisted play): the save state it starts from, and the
// buttons held in each frame after it. Played from that state with those
// buttons the game runs exactly as it did when recorded.
//
// While recording, going back (rewind, loading a save state) re-records:
// the movie is cut back to that frame and goes on from there. A state is
// only taken as part of the movie when the machine's frame count and the
// hash of every frame's buttons (Mmu.frames, Mmu.input_hash) match the
// movie's at that frame; otherwise it belongs to another timeline.
//
// The file (game-movie-N.wer) is text:
//   wer movie 1
//   game: TETRIS
//   frames: 1800
//   rerecords: 12
//   input:
//   400:down*6,460:a*6,600:start*30
//   state:
//   <the starting state, base64>
// The input is --input's FRAME:KEYS*N (joypad::Script), FRAME counted from
// the movie's start, one item per run of frames with the same buttons; the
// frames not mentioned have none.

const String MOVIE_MAGIC = "wer movie 1";
// The longest movie read: over a day at 60 frames a second (a damaged
// header asks for no more memory than that).
const ulong MOVIE_MAX_FRAMES = 6_000_000;

faultdef NOT_A_MOVIE, OFF_THE_MOVIE;

struct Movie {
	char[]     start;      // the state it starts from (heap)
	ulong      first;      // its frame count (Mmu.frames)
	uint       first_hash; // and buttons hash
	List{char} input;      // a frame's buttons: joypad buttons << 4 | dpad
	List{uint} hashes;     // Mmu.input_hash after each frame
	ulong      rerecords;  // times it went back while recording
	String     game;       // the game's title (heap)
}

fn void Movie.free(&self) {
	free(self.start.ptr);
	self.input.free();
	self.hashes.free();
	free(self.game.ptr);
	*self = {};
}

// A new movie, from the machine as it is now.
fn void Movie.begin(&self, GameBoy* gb, String game) {
	self.free();
	self.start = gb.save_state(mem);
	self.game = game.copy(mem);
	self.input.init(mem);
	self.hashes.init(mem);
	self.first = gb.mmu.frames;
	self.first_hash = gb.mmu.input_hash;
}

fn ulong Movie.len(&self) => (ulong)self.input.len();

// The machine back at the movie's start.
fn void? Movie.restart(&self, GameBoy* gb) {
	gb.load_state(self.start)!;
	self.first = gb.mmu.frames;
	self.first_hash = gb.mmu.input_hash;
	uint h = self.first_hash;
	self.hashes.clear();
	foreach (v : self.input) {
		h = mmu::input_mix(h, v >> 4, v & 0x0F);
		self.hashes.push(h);
	}
}

// Where the machine is in the movie (frames from its start, up to its
// length), if it is on the movie's timeline.
fn ulong? Movie.position(&self, GameBoy* gb) {
	if (gb.mmu.frames < self.first) return OFF_THE_MOVIE~;
	ulong k = gb.mmu.frames - self.first;
	if (k > self.len()) return OFF_THE_MOVIE~;
	uint h = k ? self.hashes[(sz)k - 1] : self.first_hash;
	if (h != gb.mmu.input_hash) return OFF_THE_MOVIE~;
	return k;
}

// Frame `k` (Movie.position) is played with these buttons; any frames
// recorded after it are dropped.
fn void Movie.record(&self, ulong k, char buttons, char dpad) {
	while (self.len() > k) {
		self.input.remove_last();
		self.hashes.remove_last();
	}
	uint h = k ? self.hashes[(sz)k - 1] : self.first_hash;
	self.input.push((char)(buttons << 4 | dpad));
	self.hashes.push(mmu::input_mix(h, buttons, dpad));
}

// Frame `k`'s buttons (k < Movie.len).
fn void Movie.at(&self, ulong k, char* buttons, char* dpad) {
	char v = self.input[(sz)k];
	*buttons = v >> 4;
	*dpad = v & 0x0F;
}

const String[8] MOVIE_KEYS = { "a", "b", "select", "start", "right", "left", "up", "down" };

// A frame's buttons as --input names them ("a+right").
fn String keys_text(char v) {
	DString s;
	s.init(tmem);
	// buttons in the high nibble (A, B, Select, Start), then the dpad.
	for (int bit = 0; bit < 8; bit++) {
		if (!(v & (1 << (bit < 4 ? bit + 4 : bit - 4)))) continue;
		if (s.len()) s.append("+");
		s.append(MOVIE_KEYS[bit]);
	}
	return s.str_view();
}

fn String Movie.to_text(&self, Allocator alloc) {
	DString out;
	out.init(alloc);
	out.appendf("%s\ngame: %s\nframes: %d\nrerecords: %d\ninput:\n", MOVIE_MAGIC, self.game, self.len(), self.rerecords);
	sz n = self.input.len();
	int items;
	for (sz i = 0; i < n;) {
		char v = self.input[i];
		sz j = i;
		while (j < n && self.input[j] == v) j++;
		if (v) {
			out.appendf("%s%d:%s*%d", items % 8 ? "," : items ? "\n" : "", i, keys_text(v), j - i);
			items++;
		}
		i = j;
	}
	out.append("\nstate:\n");
	String b64 = base64::encode(tmem, self.start);
	for (usz i = 0; i < b64.len; i += 76) {
		out.append(b64[i : (b64.len - i < 76 ? b64.len - i : 76)]);
		out.append("\n");
	}
	return out.str_view();
}

fn void? Movie.save(&self, String path) {
	file::save(path, self.to_text(tmem))!;
}

// A movie file's contents (Movie.restart then puts the machine at its start).
fn Movie? parse_movie(String text) {
	String[] lines = text.tsplit("\n");
	if (!lines.len || lines[0].trim() != MOVIE_MAGIC) return NOT_A_MOVIE~;
	Movie m;
	m.input.init(mem);
	m.hashes.init(mem);
	defer catch m.free(); // whichever way it turns out not to be one
	ulong frames;
	bool has_frames;
	usz i = 1;
	// The header, up to "input:".
	for (; i < lines.len; i++) {
		String line = lines[i].trim();
		if (line == "input:") break;
		sz? colon = line.index_of_char(':');
		if (catch colon) continue;
		String key = line[:colon].trim();
		String value = line[colon + 1..].trim();
		switch (key) {
			case "game":
				free(m.game.ptr);
				m.game = value.copy(mem);
			case "frames":
				frames = value.to_ulong() ?? NOT_A_MOVIE~!;
				has_frames = true;
			case "rerecords": m.rerecords = value.to_ulong() ?? 0;
		}
	}
	if (!has_frames || i == lines.len || frames > MOVIE_MAX_FRAMES) return NOT_A_MOVIE~;
	m.input.free();
	m.input.init(mem, (sz)frames);
	for (ulong f = 0; f < frames; f++) m.input.push(0);
	// The runs, up to "state:".
	for (i++; i < lines.len; i++) {
		String line = lines[i].trim();
		if (line == "state:") break;
		foreach (item : line.tsplit(",")) {
			item = item.trim();
			if (!item.len) continue;
			movie_run(&m, item, frames)!;
		}
	}
	// The state, base64 to the end.
	DString b64;
	b64.init(tmem);
	for (i++; i < lines.len; i++) b64.append(lines[i].trim());
	m.start = base64::decode(mem, b64.str_view()) ?? NOT_A_MOVIE~!;
	if (!m.start.len) return NOT_A_MOVIE~;
	if (!m.game.len) m.game = "".copy(mem);
	return m;
}

// FRAME:KEYS*N into the frames it covers.
fn void? movie_run(Movie* m, String item, ulong frames) @private {
	String[] at = item.tsplit(":");
	if (at.len != 2) return NOT_A_MOVIE~;
	ulong from = at[0].trim().to_ulong() ?? NOT_A_MOVIE~!;
	String[] held = at[1].trim().tsplit("*");
	if (held.len > 2) return NOT_A_MOVIE~;
	ulong count = held.len == 2 ? held[1].trim().to_ulong() ?? NOT_A_MOVIE~! : 1;
	char buttons;
	char dpad;
	foreach (k : held[0].tsplit("+")) {
		if (catch joypad::key_bits(k.trim(), &buttons, &dpad)) return NOT_A_MOVIE~;
	}
	if (!count || from >= frames || count > frames - from) return NOT_A_MOVIE~;
	for (ulong f = from; f < from + count; f++) m.input[(sz)f] = (char)(buttons << 4 | dpad);
}

fn Movie? load_movie(String path) {
	char[] data = file::load_temp(path) ?? NOT_A_MOVIE~!;
	return parse_movie((String)data);
}
