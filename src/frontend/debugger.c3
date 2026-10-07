module wer;
import gameboy, mmu, ppu, cpu, display, sdl;
import std::io;

// The debugger: a second window (desktop) next to the game's, F10. On the
// left the CPU and the code around PC, on the right memory and the stack,
// the tiles in VRAM, or the objects and palettes (Tab). Its keys:
//   Space, F5    pause / go on
//   S, F7        one instruction
//   O, F8        step over a CALL or RST
//   C            run to the cursor
//   B, F9        breakpoint at the cursor
//   Up/Down      move the cursor; Home: back to PC
//   PgUp/PgDn    scroll memory (Shift: by $1000)
//   G / J        go to an address in memory / the code (hex, Enter)
//   Tab          memory, tiles, objects
//   Esc, F10     close

const int DBG_W = 1296;
const int DBG_H = 800;
const float DBG_FONT = 2;           // the 8x8 font, doubled
const int DBG_CELL = 16;            // ... a character's width in window pixels
const int DBG_ROW = 10;             // a line's height, in font pixels
const int CODE_LINES = 28;
const int MEM_LINES = 24;
const int TILES_W = 128;            // 16 tiles across
const int TILES_H = 192;            // 24 rows: $8000-$97FF

enum DebugPanel : char {
	MEMORY,
	TILES,
	OBJECTS,
}

struct Debugger {
	sdl::Window*   window;
	sdl::Renderer* renderer;
	sdl::Texture*  tiles;
	char[]         tile_px;       // RGBA, two banks side by side
	gameboy::Breakpoints breaks;
	ushort         top;           // first line of the code view
	ushort         cursor;        // its highlighted line
	bool           follow;        // the code view follows PC
	ushort         mem;           // first address of the memory view
	DebugPanel     panel;
	char           entering;      // 'G' or 'J' while an address is typed, else 0
	char[4]        entry;
	int            entry_len;
	bool           resume;        // the next frame goes on from a break
	bool           step;          // run one instruction now (main loop)
}

Debugger dbg;

fn bool Debugger.is_open(&self) => self.window != null;

fn void Debugger.open(&self, display::Display* screen) {
	if (self.window) return;
	// A browser and a phone have the one window (and no room for two).
	if (env::EMSCRIPTEN || env::ANDROID) {
		notice.show("The debugger needs a desktop");
		return;
	}
	self.window = sdl::create_window("wer debugger", DBG_W, DBG_H, 0);
	self.renderer = self.window ? sdl::create_renderer(self.window, null) : null;
	if (!self.renderer) {
		if (self.window) sdl::destroy_window(self.window);
		self.window = null;
		notice.show("Could not open the debugger's window");
		return;
	}
	self.tiles = sdl::create_texture(self.renderer, sdl::PIXELFORMAT_ABGR8888, sdl::TEXTUREACCESS_STREAMING, TILES_W * 2, TILES_H);
	if (self.tiles) sdl::set_texture_scale_mode(self.tiles, sdl::SCALEMODE_NEAREST);
	if (!self.tile_px.len) self.tile_px = mem::new_array(char, TILES_W * 2 * TILES_H * 4);
	if (self.breaks.temp == 0 && self.breaks.n == 0) self.breaks.init();
	self.follow = true;
	if (self.mem == 0) self.mem = 0xC000;
	screen.debug_window = sdl::get_window_id(self.window);
	screen.debug_closed = false;
}

fn void Debugger.close(&self, display::Display* screen) {
	if (!self.window) return;
	if (self.tiles) sdl::destroy_texture(self.tiles);
	sdl::destroy_renderer(self.renderer);
	sdl::destroy_window(self.window);
	self.window = null;
	self.renderer = null;
	self.tiles = null;
	self.breaks.temp = -1;
	self.entering = 0;
	screen.debug_window = 0;
}

// The keys typed in the debugger's window since the last frame. Pausing and
// stepping go through the main loop's `paused` (and dbg.step).
fn void Debugger.handle(&self, display::Display* screen, gameboy::GameBoy* gb) {
	if (screen.debug_closed) {
		self.close(screen);
		return;
	}
	for (int i = 0; i < screen.debug_n; i++) {
		int sc = screen.debug_keys[i] & 0xFFFF;
		bool shift = (screen.debug_keys[i] >> 16 & sdl::KMOD_SHIFT) != 0;
		if (self.entering) {
			self.type_key(sc);
			continue;
		}
		switch (sc) {
			case sdl::SC_ESCAPE:
			case sdl::SC_F10:
				self.close(screen);
				return;
			case sdl::SC_SPACE:
			case sdl::SC_F5:
				paused = !paused;
				screen.clear_audio();
				if (!paused) self.resume = true;
				notice.show(paused ? "Paused" : "");
			case sdl::SC_S:
			case sdl::SC_F7:
				self.step = true;
			case sdl::SC_O:
			case sdl::SC_F8:
				char op = gb.mmu.peek(gb.cpu.pc);
				if (gameboy::is_call(op)) {
					int len;
					gameboy::disasm(&gb.mmu, gb.cpu.pc, &len);
					self.run_to((ushort)(gb.cpu.pc + len));
				} else {
					self.step = true;
				}
			case sdl::SC_C:
				self.run_to(self.cursor);
			case sdl::SC_B:
			case sdl::SC_F9:
				self.breaks.toggle(self.cursor);
			case sdl::SC_UP:
				self.follow = false;
				self.move_cursor(gb, -1);
			case sdl::SC_DOWN:
				self.follow = false;
				self.move_cursor(gb, 1);
			case sdl::SC_HOME:
				self.follow = true;
			case sdl::SC_PAGEUP:
				self.mem -= shift ? 0x1000 : (ushort)(MEM_LINES * 8);
			case sdl::SC_PAGEDOWN:
				self.mem += shift ? 0x1000 : (ushort)(MEM_LINES * 8);
			case sdl::SC_G:
				self.entering = 'G';
				self.entry_len = 0;
			case sdl::SC_J:
				self.entering = 'J';
				self.entry_len = 0;
			case sdl::SC_TAB:
				self.panel = (DebugPanel)((self.panel.ordinal + 1) % 3);
		}
	}
}

// Run on (from a break) until PC is `at`.
fn void Debugger.run_to(&self, ushort at) {
	self.breaks.temp = at;
	self.resume = true;
	paused = false;
	screen.clear_audio();
}

// Typing an address: hex digits, Backspace, Enter, Esc.
fn void Debugger.type_key(&self, int sc) {
	char digit = 0xFF;
	if (sc >= sdl::SC_1 && sc < sdl::SC_0) digit = (char)(sc - sdl::SC_1 + 1);
	if (sc == sdl::SC_0) digit = 0;
	if (sc >= sdl::SC_A && sc <= sdl::SC_A + 5) digit = (char)(sc - sdl::SC_A + 10);
	if (digit != 0xFF && self.entry_len < 4) {
		self.entry[self.entry_len++] = digit;
		return;
	}
	if (sc == sdl::SC_BACKSPACE && self.entry_len > 0) self.entry_len--;
	if (sc == sdl::SC_ESCAPE) self.entering = 0;
	if (sc == sdl::SC_RETURN) {
		if (self.entry_len > 0) {
			ushort a;
			for (int i = 0; i < self.entry_len; i++) a = (ushort)(a << 4 | self.entry[i]);
			if (self.entering == 'G') {
				self.mem = a & 0xFFF8;
				self.panel = MEMORY;
			} else {
				self.top = a;
				self.cursor = a;
				self.follow = false;
			}
		}
		self.entering = 0;
	}
}

// The cursor a line up or down the code view (which scrolls along).
fn void Debugger.move_cursor(&self, gameboy::GameBoy* gb, int dir) {
	ushort[CODE_LINES] at;
	self.lines(gb, &at);
	int i = 0;
	while (i < CODE_LINES && at[i] != self.cursor) i++;
	if (i == CODE_LINES) i = 0;
	if (dir > 0) {
		if (i + 1 < CODE_LINES) {
			self.cursor = at[i + 1];
		} else {
			self.top = at[1];
			self.cursor = at[CODE_LINES - 1];
			self.lines(gb, &at);
			self.cursor = at[CODE_LINES - 1];
		}
	} else {
		if (i > 0) {
			self.cursor = at[i - 1];
		} else {
			// Code can't be read backwards for sure: a byte back.
			self.top--;
			self.cursor = self.top;
		}
	}
}

// The addresses the code view shows.
fn void Debugger.lines(&self, gameboy::GameBoy* gb, ushort[CODE_LINES]* at) {
	ushort a = self.top;
	for (int i = 0; i < CODE_LINES; i++) {
		(*at)[i] = a;
		int len;
		gameboy::disasm(&gb.mmu, a, &len);
		a += (ushort)len;
	}
}

// After a break or a step: show PC (a few lines down, if it's off screen).
fn void Debugger.show_pc(&self, gameboy::GameBoy* gb) {
	ushort pc = gb.cpu.pc;
	ushort[CODE_LINES] at;
	self.lines(gb, &at);
	bool seen = false;
	for (int i = 0; i < CODE_LINES - 4; i++) if (at[i] == pc) seen = true;
	if (!seen) self.top = pc;
	self.cursor = pc;
}

// --- drawing ---------------------------------------------------------------

fn void Debugger.text(&self, int col, int row, String s, char r = 0xC8, char g = 0xE0, char b = 0xC0) {
	sdl::set_render_draw_color(self.renderer, r, g, b, 0xFF);
	sdl::render_debug_text(self.renderer, (float)(col * 8 + 4), (float)(row * DBG_ROW + 4), s.zstr_tcopy());
}

fn void Debugger.draw(&self, gameboy::GameBoy* gb) {
	if (!self.window) return;
	if (self.follow) self.show_pc(gb);
	gb.mmu.ppu_touch();
	sdl::set_render_draw_color(self.renderer, 0x10, 0x14, 0x18, 0xFF);
	sdl::render_clear(self.renderer);
	sdl::set_render_scale(self.renderer, DBG_FONT, DBG_FONT);

	self.draw_cpu(gb);
	self.draw_code(gb);
	switch (self.panel) {
		case MEMORY:  self.draw_memory(gb);
		case TILES:   break; // drawn below, at full scale
		case OBJECTS: self.draw_objects(gb);
	}
	self.draw_help();
	sdl::set_render_scale(self.renderer, 1, 1);
	if (self.panel == TILES) self.draw_tiles(gb);
	if (self.panel == OBJECTS) self.draw_palettes(gb);
	sdl::render_present(self.renderer);
}

fn void Debugger.draw_cpu(&self, gameboy::GameBoy* gb) {
	cpu::Cpu* c = &gb.cpu;
	mmu::Mmu* m = &gb.mmu;
	char f = c.af.lo;
	self.text(0, 0, string::tformat("PC %04X  SP %04X  %s", c.pc, c.sp, paused ? "paused" : "running"), 0xF0, 0xF8, 0xE0);
	self.text(0, 1, string::tformat("AF %04X  BC %04X  DE %04X  HL %04X", c.af.reg, c.bc.reg, c.de.reg, c.hl.reg));
	self.text(0, 2, string::tformat("Flags %c%c%c%c  IME %d  IE %02X  IF %02X%s", f & 0x80 ? 'Z' : '-', f & 0x40 ? 'N' : '-',
		f & 0x20 ? 'H' : '-', f & 0x10 ? 'C' : '-', c.ime ? 1 : 0, m.peek(0xFFFF), m.peek(0xFF0F),
		c.halted ? "  HALT" : c.stopped ? "  STOP" : ""));
	self.text(0, 3, string::tformat("LCDC %02X STAT %02X LY %02X  dot %d", m.peek(0xFF40), m.peek(0xFF41), m.peek(0xFF44), m.ppu.dot));
	uint bank = m.cart ? m.cart.rom_bank : 1;
	self.text(0, 4, string::tformat("DIV %02X TIMA %02X  ROM bank %d%s", m.peek(0xFF04), m.peek(0xFF05), bank, m.double_speed ? "  2x" : ""));
}

fn void Debugger.draw_code(&self, gameboy::GameBoy* gb) {
	ushort a = self.top;
	for (int i = 0; i < CODE_LINES; i++) {
		int len;
		String s = gameboy::disasm(&gb.mmu, a, &len);
		DString bytes;
		bytes.init(tmem);
		for (int k = 0; k < len; k++) bytes.appendf("%02X", gb.mmu.peek((ushort)(a + k)));
		bool pc = a == gb.cpu.pc;
		bool bp = self.breaks.has(a);
		int row = 6 + i;
		if (a == self.cursor) {
			sdl::set_render_draw_color(self.renderer, 0x30, 0x40, 0x48, 0xFF);
			sdl::FRect hl = { 2, (float)(row * DBG_ROW + 2), 37 * 8, DBG_ROW };
			sdl::render_fill_rect(self.renderer, &hl);
		}
		String line = string::tformat("%c%c%04X %-6s %s", pc ? '>' : ' ', bp ? '*' : ' ', a, bytes.str_view(), s);
		if (bp) {
			self.text(0, row, line, 0xF0, 0x70, 0x60);
		} else if (pc) {
			self.text(0, row, line, 0xF0, 0xF8, 0xA0);
		} else {
			self.text(0, row, line);
		}
		a += (ushort)len;
	}
	if (self.entering) {
		DString e;
		e.init(tmem);
		for (int i = 0; i < self.entry_len; i++) e.appendf("%X", self.entry[i]);
		self.text(0, 6 + CODE_LINES + 1, string::tformat("%s address: %s_", self.entering == 'G' ? "Memory" : "Code", e.str_view()), 0xF0, 0xF8, 0xA0);
	}
}

const int RIGHT = 39; // first column of the right half

fn void Debugger.draw_memory(&self, gameboy::GameBoy* gb) {
	self.text(RIGHT, 0, "Memory (PgUp/PgDn, G)", 0xF0, 0xF8, 0xE0);
	for (int i = 0; i < MEM_LINES; i++) {
		ushort a = (ushort)(self.mem + i * 8);
		DString hex;
		hex.init(tmem);
		DString chars;
		chars.init(tmem);
		for (int k = 0; k < 8; k++) {
			char v = gb.mmu.peek((ushort)(a + k));
			hex.appendf(" %02X", v);
			chars.append_char(v >= 0x20 && v < 0x7F ? v : '.');
		}
		self.text(RIGHT, 1 + i, string::tformat("%04X%s  %s", a, hex.str_view(), chars.str_view()));
	}
	self.text(RIGHT, 2 + MEM_LINES, "Stack", 0xF0, 0xF8, 0xE0);
	for (int i = 0; i < 8; i++) {
		ushort a = (ushort)(gb.cpu.sp + i * 2);
		ushort v = (ushort)(gb.mmu.peek(a) | (ushort)gb.mmu.peek((ushort)(a + 1)) << 8);
		self.text(RIGHT, 3 + MEM_LINES + i, string::tformat("%04X  %04X", a, v));
	}
}

// Every tile in VRAM ($8000-$97FF), 16 to a row, both banks on a CGB, in
// four greys.
fn void Debugger.draw_tiles(&self, gameboy::GameBoy* gb) {
	self.text_scaled(RIGHT, 0, gb.mmu.ppu.vram1 ? "Tiles, banks 0 and 1 ($8000-$97FF)" : "Tiles ($8000-$97FF)");
	if (!self.tiles) return;
	const char[4] GREY = { 0xFF, 0xAA, 0x55, 0x00 };
	ppu::Ppu* p = &gb.mmu.ppu;
	for (int bank = 0; bank < 2; bank++) {
		char* v = bank == 0 ? &p.vram : p.vram1;
		for (int t = 0; t < 384; t++) {
			int tx = (t % 16) * 8 + bank * TILES_W;
			int ty = (t / 16) * 8;
			for (int y = 0; y < 8; y++) {
				char lo = v ? v[t * 16 + y * 2] : 0;
				char hi = v ? v[t * 16 + y * 2 + 1] : 0;
				for (int x = 0; x < 8; x++) {
					int c = ((hi >> (7 - x)) & 1) << 1 | ((lo >> (7 - x)) & 1);
					int at = ((ty + y) * TILES_W * 2 + tx + x) * 4;
					char g = v ? GREY[c] : 0x20;
					self.tile_px[at] = g;
					self.tile_px[at + 1] = g;
					self.tile_px[at + 2] = g;
					self.tile_px[at + 3] = 0xFF;
				}
			}
		}
	}
	sdl::update_texture(self.tiles, null, self.tile_px.ptr, TILES_W * 2 * 4);
	float x = (float)(RIGHT * DBG_CELL + 8);
	for (int bank = 0; bank < (p.vram1 ? 2 : 1); bank++) {
		sdl::FRect src = { (float)(bank * TILES_W), 0, TILES_W, TILES_H };
		sdl::FRect dst = { x + (float)bank * (TILES_W * 2 + 16), DBG_ROW * DBG_FONT * 2, TILES_W * 2, TILES_H * 2 };
		sdl::render_texture(self.renderer, self.tiles, &src, &dst);
	}
}

// Text at the debugger's font size while the render scale is 1.
fn void Debugger.text_scaled(&self, int col, int row, String s) {
	sdl::set_render_scale(self.renderer, DBG_FONT, DBG_FONT);
	self.text(col, row, s, 0xF0, 0xF8, 0xE0);
	sdl::set_render_scale(self.renderer, 1, 1);
}

// The 40 OAM entries: Y, X, tile, attributes.
fn void Debugger.draw_objects(&self, gameboy::GameBoy* gb) {
	self.text(RIGHT, 0, "Objects: number, Y, X, tile, attributes", 0xF0, 0xF8, 0xE0);
	char[] oam = &gb.mmu.ppu.oam;
	for (int i = 0; i < 40; i++) {
		int col = RIGHT + (i / 20) * 18;
		int row = 1 + i % 20;
		bool shown = oam[i * 4] > 0 && oam[i * 4] < 160 && oam[i * 4 + 1] > 0 && oam[i * 4 + 1] < 168;
		String s = string::tformat("%02d %02X %02X %02X %02X", i, oam[i * 4], oam[i * 4 + 1], oam[i * 4 + 2], oam[i * 4 + 3]);
		if (shown) {
			self.text(col, row, s);
		} else {
			self.text(col, row, s, 0x60, 0x70, 0x68);
		}
	}
	self.text(RIGHT, 22, "Palettes", 0xF0, 0xF8, 0xE0);
	mmu::Mmu* m = &gb.mmu;
	self.text(RIGHT, 23, string::tformat("BGP %02X  OBP0 %02X  OBP1 %02X", m.peek(0xFF47), m.peek(0xFF48), m.peek(0xFF49)));
}

// The CGB's 8 + 8 palettes as colour swatches (with the DMG ones above).
fn void Debugger.draw_palettes(&self, gameboy::GameBoy* gb) {
	ppu::Ppu* p = &gb.mmu.ppu;
	if (!p.cgb_hw) return;
	float x0 = (float)(RIGHT * DBG_CELL + 8);
	float y0 = (float)(25 * DBG_ROW) * DBG_FONT + 12;
	for (int obj = 0; obj < 2; obj++) {
		char[] pal = obj ? &p.obj_pal : &p.bg_pal;
		for (int n = 0; n < 8; n++) {
			for (int c = 0; c < 4; c++) {
				ushort rgb = ppu::pal_color(pal, n, c);
				char r = (char)((rgb & 0x1F) << 3);
				char g = (char)(((rgb >> 5) & 0x1F) << 3);
				char b = (char)(((rgb >> 10) & 0x1F) << 3);
				sdl::set_render_draw_color(self.renderer, r, g, b, 0xFF);
				sdl::FRect sw = { x0 + (float)(obj * 304 + c * 22), y0 + (float)(n * 22), 20, 20 };
				sdl::render_fill_rect(self.renderer, &sw);
			}
		}
	}
	sdl::set_render_scale(self.renderer, DBG_FONT, DBG_FONT);
	self.text(RIGHT, 24, "BG palettes 0-7", 0xF0, 0xF8, 0xE0);
	self.text(RIGHT + 19, 24, "OBJ palettes 0-7", 0xF0, 0xF8, 0xE0);
	sdl::set_render_scale(self.renderer, 1, 1);
}

fn void Debugger.draw_help(&self) {
	int row = (int)(DBG_H / DBG_FONT) / DBG_ROW - 4;
	self.text(0, row, "Space pause/go on  S step  O step over  C run to cursor  B breakpoint", 0x80, 0x98, 0x88);
	self.text(0, row + 1, "Up/Down cursor  Home PC  G/J go to (memory/code)  Tab memory/tiles/objects", 0x80, 0x98, 0x88);
	self.text(0, row + 2, "Esc close", 0x80, 0x98, 0x88);
}

