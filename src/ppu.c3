module ppu;

const int WIDTH  = 160;
const int HEIGHT = 144;

const int DOTS_PER_LINE = 456;
const int TOTAL_LINES   = 154;
const int VBLANK_LINE   = 144;
const int MODE2_DOTS    = 80;   // OAM scan
const int MODE3_DOTS    = 172;  // drawing (fixed; really 172-289)

// LCDC ($FF40)
const char LCDC_ENABLE     = 0x80;
const char LCDC_WIN_MAP    = 0x40;
const char LCDC_WIN_ENABLE = 0x20;
const char LCDC_TILE_DATA  = 0x10;
const char LCDC_BG_MAP     = 0x08;
const char LCDC_OBJ_SIZE   = 0x04;
const char LCDC_OBJ_ENABLE = 0x02;
const char LCDC_BG_ENABLE  = 0x01;

// STAT ($FF41)
const char STAT_LYC_IE    = 0x40;
const char STAT_OAM_IE    = 0x20;
const char STAT_VBLANK_IE = 0x10;
const char STAT_HBLANK_IE = 0x08;
const char STAT_LYC_FLAG  = 0x04;

// Interrupt request bits returned by tick().
const char INT_VBLANK = 0x01;
const char INT_STAT   = 0x02;

struct Ppu {
	char[0x2000] vram;
	char[0xA0]   oam;
	char[] fb;

	char lcdc;
	char stat;
	char scy;
	char scx;
	char ly;
	char lyc;
	char bgp;
	char obp0;
	char obp1;
	char wy;
	char wx;

	int  dot;          // 0..455 within the current line
	char mode;         // 0 HBlank, 1 VBlank, 2 OAM, 3 drawing
	int  win_line;     // internal window line counter
	bool frame_ready;  // set when VBlank begins; cleared by the consumer

	char[WIDTH] bg_color; // BG colour index per pixel of the current line (sprite priority)
}

fn char shade(char palette, char index) {
	return (palette >> (index * 2)) & 3;
}

fn void Ppu.write_lcdc(&self, char value) {
	bool was_on = (self.lcdc & LCDC_ENABLE) != 0;
	self.lcdc = value;
	if (!was_on && (value & LCDC_ENABLE) != 0) {
		self.dot = 0;
		self.ly = 0;
		self.win_line = 0;
		self.mode = 2;
		self.stat = (self.stat & 0xFC) | 2;
		self.frame_ready = false;
	}
}

fn char Ppu.tick(&self, uint tcycles) {
	if ((self.lcdc & LCDC_ENABLE) == 0) {
		self.dot = 0;
		self.ly = 0;
		self.win_line = 0;
		self.mode = 0;
		self.stat &= 0xFC;
		return 0;
	}

	char irq = 0;
	for (uint i = 0; i < tcycles; i++) {
		self.dot++;
		if (self.dot >= DOTS_PER_LINE) {
			self.dot = 0;
			self.ly++;
			if (self.ly >= TOTAL_LINES) {
				self.ly = 0;
				self.win_line = 0;
			}
			irq |= self.check_lyc();
		}
		irq |= self.update_mode();
	}
	return irq;
}

fn char Ppu.check_lyc(&self) {
	if (self.ly == self.lyc) {
		self.stat |= STAT_LYC_FLAG;
		if (self.stat & STAT_LYC_IE) return INT_STAT;
	} else {
		self.stat &= (char)~STAT_LYC_FLAG;
	}
	return 0;
}

fn char Ppu.update_mode(&self) {
	char want;
	if (self.ly >= VBLANK_LINE) {
		want = 1;
	} else if (self.dot < MODE2_DOTS) {
		want = 2;
	} else if (self.dot < MODE2_DOTS + MODE3_DOTS) {
		want = 3;
	} else {
		want = 0;
	}

	if (want == self.mode) return 0;
	self.mode = want;
	self.stat = (self.stat & 0xFC) | want;

	char irq = 0;
	switch (want) {
		case 0:
			self.render_line();
			if (self.stat & STAT_HBLANK_IE) irq |= INT_STAT;
		case 1:
			self.frame_ready = true;
			irq |= INT_VBLANK;
			if (self.stat & STAT_VBLANK_IE) irq |= INT_STAT;
		case 2:
			if (self.stat & STAT_OAM_IE) irq |= INT_STAT;
	}
	return irq;
}

fn char Ppu.tile_pixel(&self, ushort map_base, bool signed_tiles, int px, int py) {
	int col = (px >> 3) & 31;
	int row = (py >> 3) & 31;
	char tile = self.vram[map_base + row * 32 + col];

	ushort base;
	if (signed_tiles) {
		base = (ushort)(0x1000 + (int)(ichar)tile * 16);
	} else {
		base = (ushort)((uint)tile * 16);
	}
	int fine = py & 7;
	char lo = self.vram[base + fine * 2];
	char hi = self.vram[base + fine * 2 + 1];
	int bit = 7 - (px & 7);
	return (char)((((hi >> bit) & 1) << 1) | ((lo >> bit) & 1));
}

fn void Ppu.render_line(&self) {
	if (self.fb.len == 0) return;

	int y = self.ly;
	int row = y * WIDTH;

	bool bg_on   = (self.lcdc & LCDC_BG_ENABLE) != 0;
	bool win_row = (self.lcdc & LCDC_WIN_ENABLE) != 0 && y >= (int)self.wy;
	bool signed_tiles = (self.lcdc & LCDC_TILE_DATA) == 0;
	ushort bg_map  = (self.lcdc & LCDC_BG_MAP)  ? (ushort)0x1C00 : (ushort)0x1800;
	ushort win_map = (self.lcdc & LCDC_WIN_MAP) ? (ushort)0x1C00 : (ushort)0x1800;
	int win_x0 = (int)self.wx - 7;

	for (int x = 0; x < WIDTH; x++) {
		char idx = 0;
		if (win_row && x >= win_x0) {
			idx = self.tile_pixel(win_map, signed_tiles, x - win_x0, self.win_line);
		} else if (bg_on) {
			idx = self.tile_pixel(bg_map, signed_tiles, (x + self.scx) & 0xFF, (y + self.scy) & 0xFF);
		}
		self.bg_color[x] = idx;
		self.fb[row + x] = shade(self.bgp, idx);
	}

	if (win_row) self.win_line++;

	if (self.lcdc & LCDC_OBJ_ENABLE) self.render_sprites(y);
}

fn void Ppu.render_sprites(&self, int y) {
	int height = (self.lcdc & LCDC_OBJ_SIZE) ? 16 : 8;
	int row = y * WIDTH;

	int[10] chosen;
	int n = 0;
	for (int i = 0; i < 40 && n < 10; i++) {
		int oy = (int)self.oam[i * 4] - 16;
		if (y >= oy && y < oy + height) chosen[n++] = i;
	}

	// DMG priority: smaller X wins; ties broken by OAM index. Sort ascending so
	// the first sprite to touch a pixel is the winner.
	for (int a = 1; a < n; a++) {
		int v = chosen[a];
		int vx = self.oam[v * 4 + 1];
		int b = a - 1;
		while (b >= 0 && (int)self.oam[chosen[b] * 4 + 1] > vx) {
			chosen[b + 1] = chosen[b];
			b--;
		}
		chosen[b + 1] = v;
	}

	bool[WIDTH] painted;
	for (int s = 0; s < n; s++) {
		int i = chosen[s];
		int oy = (int)self.oam[i * 4] - 16;
		int ox = (int)self.oam[i * 4 + 1] - 8;
		char tile = self.oam[i * 4 + 2];
		char flags = self.oam[i * 4 + 3];

		int line = y - oy;
		if (flags & 0x40) line = height - 1 - line; // y-flip
		if (height == 16) tile &= 0xFE;

		ushort addr = (ushort)((int)tile * 16 + line * 2);
		char lo = self.vram[addr];
		char hi = self.vram[addr + 1];
		char pal = (flags & 0x10) ? self.obp1 : self.obp0;
		bool behind = (flags & 0x80) != 0;
		bool xflip = (flags & 0x20) != 0;

		for (int px = 0; px < 8; px++) {
			int sx = ox + px;
			if (sx < 0 || sx >= WIDTH || painted[sx]) continue;
			int bit = xflip ? px : 7 - px;
			char cidx = (char)((((hi >> bit) & 1) << 1) | ((lo >> bit) & 1));
			if (cidx == 0) continue;              // transparent
			painted[sx] = true;
			if (behind && self.bg_color[sx] != 0) continue;
			self.fb[row + sx] = shade(pal, cidx);
		}
	}
}
