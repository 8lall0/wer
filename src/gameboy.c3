module gameboy;

import cpu, mmu, ppu, apu, cart, sgb;
import std::io, std::io::file;

// Top-level machine: owns the CPU and the memory map, drives them in step.
struct GameBoy {
	cpu::Cpu cpu;
	mmu::Mmu mmu;
}

struct Cartridge {
	char[17] title;   // NUL-terminated copy of $0134-$0143
	char type;        // $0147
	int  rom_kib;
	int  ram_kib;
	bool battery;
	bool cgb;         // $0143 bit 7: the game supports (or needs) a CGB
	bool logo_ok;     // $0104-$0133 matches the Nintendo logo
	bool header_ok;   // $014D header checksum is valid
}

// Header $0143 = $C0: the game runs only on a Game Boy Color.
fn bool requires_cgb(char[] rom) => rom.len > 0x143 && rom[0x143] == 0xC0;

fn bool header_checksum_ok(char[] rom) {
	if (rom.len < 0x14E) return false;
	char x = 0;
	for (int i = 0x134; i <= 0x14C; i++) x = (char)(x - rom[i] - 1);
	return x == rom[0x14D];
}

// A CGB-C's object palette RAM at power-on (measured by Gambatte's author).
const char[64] CGB_POWER_ON_OBJ_PAL = {
	0x00, 0x00, 0xF2, 0xAB, 0x61, 0xC2, 0xD9, 0xBA, 0x88, 0x6E, 0xDD, 0x63, 0x28, 0x27, 0xFB, 0x9F,
	0x35, 0x42, 0xD6, 0xD4, 0x50, 0x48, 0x57, 0x5E, 0x23, 0x3E, 0x3D, 0xCA, 0x71, 0x21, 0x37, 0xC0,
	0xC6, 0xB3, 0xFB, 0xF9, 0x08, 0x00, 0x8D, 0x29, 0xA3, 0x20, 0xDB, 0x87, 0x62, 0x05, 0x5D, 0xD4,
	0x0E, 0x08, 0xFE, 0xAF, 0x20, 0x02, 0xD7, 0xFF, 0x07, 0x6A, 0x55, 0xEC, 0x83, 0x40, 0x0B, 0x77,
};

// Where battery saves and save states go: next to the ROM, or, when set
// (Android, where the ROM is a content:// URI), in this folder (ending in
// '/') under the game's header title and global checksum.
String data_dir;

// The path a game's .sav and .ssN files extend (temp memory).
fn String save_base(String rom_path, char[] rom) {
	if (!data_dir.len || rom.len < 0x150) return rom_path;
	char[16] title;
	usz n;
	for (usz i = 0x134; i < 0x144 && rom[i]; i++) {
		char c = rom[i];
		bool ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9');
		title[n++] = ok ? c : '_';
	}
	return string::tformat("%s%s-%02X%02X", data_dir, (String)title[:n], rom[0x14E], rom[0x14F]);
}

const ushort DMG0_BOOT_DIV = 0x1830; // Mooneye boot_div-dmg0
const int DMG0_BOOT_DOT = 168; // on line 145
const int DMG_BOOT_DOT = 396; // post-boot DMG PPU dot on line 153 (Gambatte; gbmicrotest poweron_*)
fn GameBoy new(bool boot = true, mmu::Model model = DMG) {
	GameBoy gb;
	gb.mmu.model = model;
	if (model.is_sgb()) gb.mmu.sgb = sgb::new();
	gb.mmu.ppu.fb = mem::new_array(char, ppu::WIDTH * ppu::HEIGHT);
	gb.mmu.apu.init();
	gb.mmu.apu.clock_hz = model.clock_hz();
	gb.mmu.apu.cgb = model == CGB;
	gb.mmu.ppu.cgb_hw = model == CGB;
	gb.set_cgb_revision(C);
	gb.mmu.dmg_rev = ABC;
	gb.mmu.ppu.sgb_hw = model.is_sgb();
	gb.mmu.apu.set_ring(mem::new_array(short, 16384));
	if (model == CGB) {
		gb.mmu.wram_ext = mem::new_array(char, mmu::WRAM_EXT_SIZE).ptr;
		gb.mmu.ppu.vram1 = mem::new_array(char, 0x2000).ptr;
		gb.mmu.ppu.cfb = mem::new_array(ushort, ppu::WIDTH * ppu::HEIGHT);
		gb.mmu.ppu.blank(); // the LCD starts off: a white screen
		// Until a cartridge says otherwise (load_rom_named).
		gb.mmu.cgb_mode = true;
		gb.mmu.ppu.cgb = true;
		gb.mmu.vdma_ff55 = 0xFF; // no VRAM DMA has run
	}

	gb.mmu.power_on_wram();
	if (boot) {
		gb.cpu = cpu::init_cold();
		gb.mmu.boot_active = true;
	} else {
		switch (model) {
			case DMG:  gb.cpu = cpu::init();
			case SGB:
			case SGB2: gb.cpu = cpu::init_sgb();
			case CGB:  gb.cpu = cpu::init_cgb();
		}
		// The only register the SGB2 boot ROM leaves differently.
		if (model == SGB2) gb.cpu.af.hi = 0xFF;
		gb.mmu.set(0xFF47, 0xFC); // BGP
		// OBP0/OBP1: $FF on a DMG; a CGB's boot ROM never writes them, they
		// stay $00 (SameBoy; Mooneye wilbertpol boot_hwio-C).
		gb.mmu.set(0xFF48, model == CGB ? 0x00 : 0xFF);
		gb.mmu.set(0xFF49, model == CGB ? 0x00 : 0xFF);
		gb.mmu.set(0xFF40, 0x91); // LCDC: on, BG on, tile data $8000
		// DMA reads $FF on a DMG (gbmicrotest poweron_dma_000), $00 on a CGB
		// (Mooneye wilbertpol boot_hwio-C); no transfer.
		gb.mmu.io[0x46] = model == CGB ? 0x00 : 0xFF;
		// The boot ROM turned the LCD on long ago, and hands over in VBlank:
		// a CGB at line 144 dot 164, a DMG at line 153 dot 396 (Gambatte
		// setPostBiosState; display_startstate).
		gb.mmu.ppu.first_line = false;
		gb.mmu.ppu.line = model == CGB ? 144 : 153;
		gb.mmu.ppu.dot = model == CGB ? 164 : DMG_BOOT_DOT;
		gb.mmu.ppu.ly = model == CGB ? 144 : 0;
		gb.mmu.ppu.mode = 1;
		gb.mmu.ppu.stat = (gb.mmu.ppu.stat & 0xFC) | 1;
		gb.mmu.ppu.irq_reschedule(true);
		// DMG post-boot DIV counter (Pan Docs); the SGB boot ROMs run longer,
		// the SGB2's 4 M-cycles less (values found with Mooneye boot_div-S /
		// boot_div2-S).
		switch (model) {
			case DMG:  gb.mmu.timer.div = 0xABCC;
			case SGB:  gb.mmu.timer.div = 0xD860;
			case SGB2: gb.mmu.timer.div = 0xD850;
			case CGB:  gb.mmu.timer.div = 0x2678; // boot_div-cgbABCDE (DMG game; CGB games unverified)
		}
		// The SGB and CGB boot ROMs leave both P1 select lines high, so P1
		// reads $FF (the SGB's talks to the SNES through them).
		if (model != DMG) gb.mmu.set(0xFF00, 0x30);
		if (model == CGB) {
			// The boot ROM makes every background colour white (Gambatte;
			// bully on a CGB).
			for (int i = 0; i < 64; i += 2) {
				gb.mmu.ppu.bg_pal[i] = 0xFF;
				gb.mmu.ppu.bg_pal[i + 1] = 0x7F;
			}
			// It leaves object palette RAM as it powered up: random, per unit;
			// these are a CPU CGB C's (Gambatte's cgbObjpDump; its
			// scx_during_m3_spx2 screenshots show one of them).
			gb.mmu.ppu.obj_pal = CGB_POWER_ON_OBJ_PAL;
			// The palette indices after the last colour the boot ROM wrote
			// (Mooneye boot_hwio-C).
			gb.mmu.ppu.bcps = 0xC8;
			gb.mmu.ppu.ocps = 0xD0;
		}
		gb.mmu.set(0xFF0F, 0x01);   // IF: VBlank left pending by the boot ROM

		// APU as the boot chime leaves it: powered, channel 1 still on but
		// its envelope already at volume 0, so it is silent.
		gb.mmu.set(0xFF26, 0x80);   // NR52: power on (must precede other APU writes)
		gb.mmu.set(0xFF11, 0x80);   // NR11: duty 50%
		gb.mmu.set(0xFF12, 0xF3);   // NR12: envelope
		gb.mmu.set(0xFF24, 0x77);   // NR50: master volume
		gb.mmu.set(0xFF25, 0xF3);   // NR51: panning
		// The DMG and CGB boot ROMs play the chime; the SGB's leaves channel 1 off.
		gb.mmu.apu.active[apu::SQ1] = !model.is_sgb();
		// Where the chime leaves channel 1's duty cycle: frequency $7C1, and
		// the step and the 2 MHz ticks to the next one (Gambatte
		// setPostBiosState; sound/ch1_duty*_pattern_pos*, ch1_init_pos_*).
		gb.mmu.apu.sq[0].sample_length = 0x7C1;
		gb.mmu.apu.sq[0].current_sample_index = model == CGB ? 6 : 3;
		gb.mmu.apu.sq[0].sample_countdown = model == CGB ? 37 * 2 - 1 : 69 * 2 - 1;
		// The frame sequencer step the DMG boot ROM leaves (Gambatte
		// setPostBiosState: spu counter $24xx; sound/ch2_init_env_counter_timing_*).
		if (model == DMG) gb.mmu.apu.div_divider = 1;
		gb.mmu.apu.latch_duty(0);
		// Gambatte's post-boot 2 MHz count (setPostBiosState): its low bits
		// decide the APU clock phase (Apu.clock).
		gb.mmu.apu.gspu = model == CGB ? 0x1F50 : 0x25E6;
	}
	return gb;
}

// Which CGB chip revision to emulate (C unless set).
fn void GameBoy.set_cgb_revision(&self, mmu::CgbRevision rev) {
	self.mmu.cgb_rev = rev;
	self.mmu.apu.rev = (char)rev.ordinal;
	self.mmu.ppu.rev = (char)rev.ordinal;
}

// Which DMG revision to emulate (A/B/C unless set). Call it right after new():
// without the boot ROM it sets the registers that revision's boot ROM leaves.
fn void GameBoy.set_dmg_revision(&self, mmu::DmgRevision rev) {
	if (self.mmu.model != DMG) return;
	self.mmu.dmg_rev = rev;
	self.mmu.ppu.mgb = rev == MGB;
	self.mmu.apu.mgb = rev == MGB;
	if (self.mmu.boot_active) return;
	switch (rev) {
		case DMG0:
			self.cpu = cpu::init_dmg0();
			self.mmu.timer.div = DMG0_BOOT_DIV;
			// Its boot ROM hands over earlier in the frame: Mooneye
			// boot_hwio-dmg0 passes from line 145 dot 88 to 252.
			self.mmu.ppu.line = 145;
			self.mmu.ppu.ly = 145;
			self.mmu.ppu.dot = DMG0_BOOT_DOT;
			self.mmu.ppu.irq_reschedule(true);
		case ABC:
			self.cpu = cpu::init();
			self.mmu.timer.div = 0xABCC;
		case MGB:
			self.cpu = cpu::init();
			self.cpu.af.hi = 0xFF; // how games tell a Pocket (Mooneye boot_regs-mgb)
			self.mmu.timer.div = 0xABCC;
	}
}

// MBC7 (Kirby Tilt 'n' Tumble): the cartridge has an accelerometer.
fn bool GameBoy.has_tilt(&self) => self.mmu.cart != null && self.mmu.cart.mbc == MBC7;

// The player's tilt for an MBC7 cartridge, -1..1 each way: x > 0 tilted
// right, y > 0 tilted toward the player (like a stick pushed right / down).
fn void GameBoy.set_tilt(&self, float x, float y) {
	if (!self.mmu.cart) return;
	self.mmu.cart.tilt_x = x < -1 ? -1 : x > 1 ? 1 : x;
	self.mmu.cart.tilt_y = y < -1 ? -1 : y > 1 ? 1 : y;
}

// A rumble cartridge's motor since the last call, 0 (still) to 1 (full):
// the share of the game's writes to it that switched it on, or, without
// writes, whether it is running.
fn float GameBoy.rumble(&self) {
	cart::Cartridge* c = self.mmu.cart;
	if (!c || !c.has_rumble) return 0;
	float level = c.rumble_writes ? (float)c.rumble_on / c.rumble_writes : c.rumble ? 1 : 0;
	c.rumble_writes = c.rumble_on = 0;
	return level;
}

fn bool GameBoy.has_rumble(&self) => self.mmu.cart != null && self.mmu.cart.has_rumble;

fn void GameBoy.destroy(&self) {
	if (self.mmu.cart) {
		self.mmu.cart.save();
		self.mmu.cart.free();
		self.mmu.cart = null;
	}
	if (self.mmu.sgb) {
		self.mmu.sgb.free();
		self.mmu.sgb = null;
	}
	if (self.mmu.wram_ext) free(self.mmu.wram_ext);
	if (self.mmu.ppu.vram1) free(self.mmu.ppu.vram1);
	self.mmu.wram_ext = null;
	self.mmu.ppu.vram1 = null;
	if (self.mmu.ppu.cfb.len) free(self.mmu.ppu.cfb.ptr);
	self.mmu.ppu.cfb = {};
	self.mmu.cgb_mode = false;
	self.mmu.ppu.cgb = false;
	if (self.mmu.ppu.fb.len) free(self.mmu.ppu.fb.ptr);
	if (self.mmu.apu.ring.len) free(self.mmu.apu.ring.ptr);
	self.mmu.ppu.fb = {};
	self.mmu.apu.ring = {};
}

fn void GameBoy.save(&self) {
	if (self.mmu.cart) self.mmu.cart.save();
}

fn uint GameBoy.audio(&self, short[] out) {
	return self.mmu.apu.drain(out);
}

fn Cartridge GameBoy.load_rom_named(&self, char[] data, String save_path) {
	Cartridge c;
	if (data.len >= 0x150) {
		for (int i = 0; i < 16; i++) {
			char ch = data[0x134 + i];
			c.title[i] = (char)((ch >= 0x20 && ch < 0x7F) ? ch : 0);
		}
		c.type = data[0x147];
		c.rom_kib = (2 << data[0x148]) * 16;
	}
	c.cgb       = data.len >= 0x150 && (data[0x143] & 0x80) != 0;
	c.logo_ok   = cart::logo_matches(data);

	// Started without a boot ROM: VRAM as the DMG / SGB boot ROM leaves it.
	if (!self.mmu.boot_active && self.mmu.model != CGB && data.len >= 0x134) {
		self.mmu.ppu.load_boot_logo(data[0x104:48]);
	}

	// A CGB turns its colour features on only for games that support them.
	// With the boot ROM running, it decides that itself (KEY0, then $FF50);
	// without it, do what it would have done: DMG compatibility mode with
	// slightly different registers, and plain grey palettes (the boot ROM
	// would pick colours from the title).
	if (self.mmu.model == CGB && !c.cgb && !self.mmu.boot_active) {
		self.mmu.enter_compat_mode();
		self.cpu = cpu::init_cgb_dmg();
		ppu::set_grey_palettes(&self.mmu.ppu);
	} else if (self.mmu.model == CGB && !self.mmu.boot_active) {
		// A CGB game skips the boot ROM's palette pick: DIV is further back
		// (Gambatte setPostBiosState; div/start_inc).
		self.mmu.timer.div = 0x1EA0;
	}
	c.header_ok = header_checksum_ok(data);

	if (cart::mbc_of(c.type) == cart::Mbc.NONE) {
		self.mmu.load(0, data);
		self.mmu.has_extram = c.type == 0x08 || c.type == 0x09;
	} else {
		self.mmu.cart = cart::new(data, save_path);
		// The cartridge clock has its own crystal: it keeps real time even
		// when the Game Boy runs fast (SGB).
		self.mmu.cart.rtc.cpu_hz = self.mmu.model.clock_hz();
		c.ram_kib = (int)(self.mmu.cart.ram.len / 1024);
		c.battery = self.mmu.cart.has_battery;
	}
	return c;
}

fn Cartridge GameBoy.load_rom(&self, char[] data) {
	return self.load_rom_named(data, "wer");
}

fn Cartridge? GameBoy.load_rom_file(&self, String path) {
	char[] data = file::load_temp(path)!;
	return self.load_rom_named(data, path);
}

fn void Cartridge.print(&self) {
	String extra;
	switch (self.type) {
		case 0x22:             extra = "  (tilt, 256-byte EEPROM)";
		case 0x1C..0x1E:       extra = "  (rumble)";
		case 0x0B..0x0D:       extra = "  (MMM01)";
		case 0xFD:             extra = "  (TAMA5 with clock)";
		case 0xFE:             extra = "  (HuC3 with clock, infrared)";
		case 0xFF:             extra = "  (HuC1, infrared)";
	}
	io::printfn("cartridge: \"%s\"  type=$%02x  rom=%dKiB  ram=%dKiB%s%s%s",
		(ZString)&self.title[0], self.type, self.rom_kib, self.ram_kib,
		self.battery ? "  (battery)" : "", extra, self.cgb ? "  (CGB)" : "");
	if (!self.logo_ok || !self.header_ok) {
		io::printfn("  WARNING: %s%s%s — a real DMG boot ROM would lock up",
			self.logo_ok ? "" : "Nintendo logo mismatch",
			(!self.logo_ok && !self.header_ok) ? ", " : "",
			self.header_ok ? "" : "bad header checksum");
	}
}

fn char GameBoy.step(&self) {
	char cycles = self.cpu.step(&self.mmu);
	return cycles;
}

fn char[] GameBoy.framebuffer(&self) {
	return self.mmu.ppu.fb;
}

struct FrameSize {
	int w;
	int h;
}

// Room for the largest picture frame_rgb produces (SGB screen with border).
const usz MAX_FRAME_RGB = sgb::BORDER_W * sgb::BORDER_H * 3;

// The finished picture as RGB, 3 bytes per pixel, and its size: coloured by
// the SGB in SGB mode (256x224 once the game sent a border), otherwise the
// PPU's shades 0-3 through `colors` (4 RGB triples).
fn FrameSize GameBoy.frame_rgb(&self, char[] rgb, char[12] colors) {
	// A CGB shows colours in both modes (DMG games through its palettes).
	if (self.mmu.model == CGB) {
		if (color_correction == OFF) {
			foreach (i, c : self.mmu.ppu.cfb) {
				rgb[i * 3]     = expand5(c & 0x1F);
				rgb[i * 3 + 1] = expand5((c >> 5) & 0x1F);
				rgb[i * 3 + 2] = expand5((c >> 10) & 0x1F);
			}
		} else {
			char[3]* lut = cgb_colors();
			foreach (i, c : self.mmu.ppu.cfb) rgb[i * 3 : 3] = lut[c & 0x7FFF][..];
		}
		return { ppu::WIDTH, ppu::HEIGHT };
	}
	char[] fb = self.framebuffer();
	if (self.mmu.sgb) {
		sgb::color_curve = color_correction != OFF;
		self.mmu.sgb.render(fb, rgb);
		return { self.mmu.sgb.width(), self.mmu.sgb.height() };
	}
	for (usz i = 0; i < fb.len; i++) {
		usz p = (usz)(fb[i] & 3) * 3;
		rgb[i * 3]     = colors[p];
		rgb[i * 3 + 1] = colors[p + 1];
		rgb[i * 3 + 2] = colors[p + 2];
	}
	return { ppu::WIDTH, ppu::HEIGHT };
}

// A 5-bit CGB colour channel as 8 bits (the formula cgb-acid2's reference
// image uses), without colour correction (color.c3).
fn char expand5(int c) => (char)((c << 3) | (c >> 2));

fn void GameBoy.run_frame(&self) {
	// A frame is 17556 M-cycles, twice as many in CGB double speed.
	ulong frame = self.mmu.double_speed ? 35112 : 17556;
	if ((self.mmu.ppu.lcdc & ppu::LCDC_ENABLE) == 0) {
		ulong target = self.cpu.clk + frame;
		while (self.cpu.clk < target) self.step();
		return;
	}
	self.mmu.ppu.frame_ready = false;
	ulong deadline = self.cpu.clk + frame * 2; // guards against a hang
	while (!self.mmu.ppu.frame_ready && self.cpu.clk < deadline) self.step();
	self.mmu.ppu.frame_ready = false;
}

fn void GameBoy.set_audio_rate(&self, uint rate) {
	self.mmu.apu.out_rate = rate;
}
