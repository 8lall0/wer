module wer;
import std::io, std::io::file, std::time::clock;
import gameboy, mmu, display;

// Movies (gameboy::Movie, movie.c3), for tool-assisted play: recorded and
// played from the menu (Movie), with --record-movie=FILE / --movie=FILE, or
// by opening or dropping a .wer file on the window. Recorded next to the
// game as game-movie-N.wer.
//
// While recording, rewinding (R) or loading a save state goes back in the
// movie: what follows is recorded again. Pause (P) and frame advance (N)
// play it a frame at a time. Not with a link cable (the other side isn't
// in the movie); tilt and the camera aren't recorded.

enum MovieState : char {
	OFF,
	RECORDING,
	PLAYING,
}

gameboy::Movie movie;
MovieState movie_state;
String movie_path;   // the file recorded to, or played (heap)
int movie_choice;    // the menu's action (MOVIE_IDLE / MOVIE_PLAYING)
long movie_last = -1; // the frame recorded last: one at or before it again is a rerecord

const String[3] MOVIE_IDLE    = { "Record", "Rec here", "Play" };
const String[2] MOVIE_PLAYING = { "Stop", "Take over" };

fn String movie_base() => save_base.len ? save_base : "wer";

fn String next_movie_path() {
	for (int n = 1; n < 10000; n++) {
		String p = string::tformat("%s-movie-%d.wer", movie_base(), n);
		if (!file::is_file(p)) return p;
	}
	return string::tformat("%s-movie.wer", movie_base());
}

// The game's last movie (the highest N), or "".
fn String last_movie_path() {
	String last;
	for (int n = 1; n < 10000; n++) {
		String p = string::tformat("%s-movie-%d.wer", movie_base(), n);
		if (!file::is_file(p)) break;
		last = p;
	}
	return last;
}

fn String file_name(String path) {
	sz slash = path.rindex_of_char('/') ?? -1;
	return path[slash + 1..];
}

fn void set_movie_path(String path) {
	if (movie_path.len) free(movie_path.ptr);
	movie_path = path.copy(mem);
}

fn bool movie_allowed() {
	if (!has_rom) {
		notice.show("Open the game first");
		return false;
	}
	if (link_mode != OFF && link_mode != PRINTER) {
		notice.show("Not with the link cable");
		return false;
	}
	return true;
}

// Record from power-on (the game reset), or from here. `path` "": the next
// game-movie-N.wer.
fn void movie_record(bool from_reset, String path = "") {
	if (!movie_allowed()) return;
	movie_stop();
	if (from_reset) {
		if (try loaded = load_game(&gb, rom_path, boot, mode, pal)) {
			cart = loaded;
			paused = false;
			next = clock::now();
		} else {
			return;
		}
	}
	movie.begin(&gb, ((ZString)&cart.title[0]).str_view());
	set_movie_path(path.len ? path : next_movie_path());
	movie_state = RECORDING;
	movie_last = -1;
	io::printfn("recording a movie to %s", movie_path);
	notice.show(from_reset ? "Recording a movie from power-on" : "Recording a movie from here");
}

// Play a movie file for the game running: from its start, its buttons
// instead of the player's.
fn void movie_play(String path) {
	if (!movie_allowed()) return;
	movie_stop();
	gameboy::Movie? m = gameboy::load_movie(path);
	if (catch m) {
		notice.show(string::tformat("%s isn't a wer movie", file_name(path)));
		return;
	}
	movie = m;
	if (catch f = movie.restart(&gb)) {
		String why;
		switch (f) {
			case gameboy::STATE_OTHER_GAME:  why = string::tformat("It's a movie of another game (%s)", movie.game);
			case gameboy::STATE_OTHER_MODEL: why = "It was recorded on another model: switch Mode";
			case gameboy::STATE_OTHER_BUILD: why = "It was recorded by another wer version";
			default:                         why = "Its starting state is damaged";
		}
		notice.show(why);
		movie.free();
		return;
	}
	rewind.reset();
	set_movie_path(path);
	movie_state = PLAYING;
	movie_choice = 0;
	paused = false;
	next = clock::now();
	notice.show(string::tformat("Playing %s (%d frames)", file_name(path), movie.len()));
}

// Playing: the player takes over from here, recording on into a new file
// (the movie so far comes along).
fn void movie_take_over() {
	if (movie_state != PLAYING) return;
	set_movie_path(next_movie_path());
	movie_state = RECORDING;
	movie_last = -1;
	notice.show("Recording on from here");
}

// Stop playing or recording; a recording is saved. `why`: shown instead of
// the usual notice.
fn void movie_stop(String why = "") {
	switch (movie_state) {
		case OFF:
			return;
		case RECORDING:
			String name = file_name(movie_path);
			if (catch movie.save(movie_path)) {
				io::eprintfn("could not write %s", movie_path);
				notice.show(string::tformat("Could not save %s", name));
			} else {
				io::printfn("wrote %s (%d frames, %d rerecords)", movie_path, movie.len(), movie.rerecords);
				notice.show(why.len ? string::tformat("%s: saved %s", why, name) : string::tformat("Saved %s (%d frames)", name, movie.len()));
				$if env::EMSCRIPTEN:
					display::run_script(string::tformat("werDownload('%s')", movie_path).zstr_tcopy());
				$endif
			}
		case PLAYING:
			notice.show(why.len ? why : "Movie stopped");
	}
	movie_state = OFF;
	movie_choice = 0;
	movie.free();
}

// Before each frame of the game: playing, the movie's buttons for it;
// recording, the player's go in the movie. A machine that isn't on the
// movie's timeline any more (a state from elsewhere) ends it.
fn void movie_frame(char* buttons, char* dpad) {
	if (movie_state == OFF) return;
	ulong? k = movie.position(&gb);
	if (catch k) {
		movie_stop(movie_state == RECORDING ? "That isn't part of the movie" : "Left the movie");
		return;
	}
	if (movie_state == PLAYING) {
		if (k == movie.len()) {
			movie_stop("Movie ended");
			return;
		}
		movie.at(k, buttons, dpad);
		return;
	}
	if ((long)k <= movie_last) movie.rerecords++;
	movie_last = (long)k;
	movie.record(k, *buttons, *dpad);
}

// The menu's Movie line, and what Left/Right/Enter do on it.
fn String movie_line() {
	switch (movie_state) {
		case OFF:       return string::tformat("Movie: < %s >", MOVIE_IDLE[movie_choice]);
		case RECORDING: return "Movie: Stop rec";
		case PLAYING:   return string::tformat("Movie: < %s >", MOVIE_PLAYING[movie_choice]);
	}
}

fn void movie_step(int step) {
	int n = movie_state == OFF ? MOVIE_IDLE.len : movie_state == PLAYING ? MOVIE_PLAYING.len : 1;
	movie_choice = (movie_choice + step + n) % n;
}

// Enter on the Movie line. True when the menu should close.
fn bool movie_enter() {
	switch (movie_state) {
		case RECORDING:
			movie_stop();
			return false;
		case PLAYING:
			if (movie_choice == 1) {
				movie_take_over();
				return true;
			}
			movie_stop();
			return false;
		case OFF:
			switch (movie_choice) {
				case 0: movie_record(true);
				case 1: movie_record(false);
				case 2:
					String last = last_movie_path();
					if (!last.len) {
						notice.show("No movie of this game yet");
						return false;
					}
					movie_play(last);
			}
			return movie_state != OFF;
	}
}
