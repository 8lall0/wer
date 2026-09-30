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

fn GameBoy new(bool boot = true, mmu::Model model = DMG) {
	GameBoy gb;
	gb.mmu.model = model;
	if (model.is_sgb()) gb.mmu.sgb = sgb::new();
	gb.mmu.ppu.fb = mem::new_array(char, ppu::WIDTH * ppu::HEIGHT);
	gb.mmu.apu.init();
	gb.mmu.apu.clock_hz = model.clock_hz();
	gb.mmu.apu.cgb = model == CGB;
	gb.mmu.ppu.cgb_hw = model == CGB;
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
		gb.mmu.set(0xFF48, 0xFF); // OBP0
		gb.mmu.set(0xFF49, 0xFF); // OBP1
		gb.mmu.set(0xFF40, 0x91); // LCDC: on, BG on, tile data $8000
		// The boot ROM turned the LCD on long ago: normal line 0, not the
		// special first line after LCD-on.
		gb.mmu.ppu.first_line = false;
		gb.mmu.ppu.lcd_on_by_cpu = false; // switched on by the boot ROM, long ago
		gb.mmu.ppu.dot = 0;
		gb.mmu.ppu.line = 0;
		gb.mmu.ppu.mode = 2;
		gb.mmu.ppu.stat = (gb.mmu.ppu.stat & 0xFC) | 2;
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
		gb.mmu.apu.ch1.enabled = !model.is_sgb();
	}
	return gb;
}

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
	}
	c.header_ok = header_checksum_ok(data);

	if (cart::mbc_of(c.type) == cart::Mbc.NONE) {
		self.mmu.load(0, data);
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
	io::printfn("cartridge: \"%s\"  type=$%02x  rom=%dKiB  ram=%dKiB%s%s",
		(ZString)&self.title[0], self.type, self.rom_kib, self.ram_kib,
		self.battery ? "  (battery)" : "", self.cgb ? "  (CGB)" : "");
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
		foreach (i, c : self.mmu.ppu.cfb) {
			rgb[i * 3]     = expand5(c & 0x1F);
			rgb[i * 3 + 1] = expand5((c >> 5) & 0x1F);
			rgb[i * 3 + 2] = expand5((c >> 10) & 0x1F);
		}
		return { ppu::WIDTH, ppu::HEIGHT };
	}
	char[] fb = self.framebuffer();
	if (self.mmu.sgb) {
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
// image uses). No LCD colour correction.
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
