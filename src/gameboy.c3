module gameboy;

import cpu, mmu, ppu, apu, cart;
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
	bool logo_ok;     // $0104-$0133 matches the Nintendo logo
	bool header_ok;   // $014D header checksum is valid
}

const char[48] NINTENDO_LOGO = {
	0xCE, 0xED, 0x66, 0x66, 0xCC, 0x0D, 0x00, 0x0B, 0x03, 0x73, 0x00, 0x83, 0x00, 0x0C, 0x00, 0x0D,
	0x00, 0x08, 0x11, 0x1F, 0x88, 0x89, 0x00, 0x0E, 0xDC, 0xCC, 0x6E, 0xE6, 0xDD, 0xDD, 0xD9, 0x99,
	0xBB, 0xBB, 0x67, 0x63, 0x6E, 0x0E, 0xEC, 0xCC, 0xDD, 0xDC, 0x99, 0x9F, 0xBB, 0xB9, 0x33, 0x3E,
};

fn bool logo_matches(char[] rom) {
	if (rom.len < 0x134) return false;
	for (int i = 0; i < 48; i++) {
		if (rom[0x104 + i] != NINTENDO_LOGO[i]) return false;
	}
	return true;
}

fn bool header_checksum_ok(char[] rom) {
	if (rom.len < 0x14E) return false;
	char x = 0;
	for (int i = 0x134; i <= 0x14C; i++) x = (char)(x - rom[i] - 1);
	return x == rom[0x14D];
}

fn GameBoy new(bool boot = true) {
	GameBoy gb;
	gb.mmu.ppu.fb = mem::new_array(char, ppu::WIDTH * ppu::HEIGHT);
	gb.mmu.apu.init();
	gb.mmu.apu.set_ring(mem::new_array(short, 16384));

	if (boot) {
		gb.cpu = cpu::init_cold();
		gb.mmu.boot_active = true;
	} else {
		gb.cpu = cpu::init();
		gb.mmu.set(0xFF47, 0xFC); // BGP
		gb.mmu.set(0xFF48, 0xFF); // OBP0
		gb.mmu.set(0xFF49, 0xFF); // OBP1
		gb.mmu.set(0xFF40, 0x91); // LCDC: on, BG on, tile data $8000
	}
	return gb;
}

fn void GameBoy.destroy(&self) {
	if (self.mmu.cart) {
		self.mmu.cart.save();
		self.mmu.cart.free();
		self.mmu.cart = null;
	}
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
	c.logo_ok   = logo_matches(data);
	c.header_ok = header_checksum_ok(data);

	if (cart::mbc_of(c.type) == cart::Mbc.NONE) {
		self.mmu.load(0, data);
	} else {
		self.mmu.cart = cart::new(data, save_path);
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
	io::printfn("cartridge: \"%s\"  type=$%02x  rom=%dKiB  ram=%dKiB%s",
		(ZString)&self.title[0], self.type, self.rom_kib, self.ram_kib,
		self.battery ? "  (battery)" : "");
	if (!self.logo_ok || !self.header_ok) {
		io::printfn("  WARNING: %s%s%s — a real DMG boot ROM would lock up",
			self.logo_ok ? "" : "Nintendo logo mismatch",
			(!self.logo_ok && !self.header_ok) ? ", " : "",
			self.header_ok ? "" : "bad header checksum");
	}
}

fn char GameBoy.step(&self) {
	char cycles = self.cpu.step(&self.mmu);
	self.mmu.tick(cycles);
	return cycles;
}

fn char[] GameBoy.framebuffer(&self) {
	return self.mmu.ppu.fb;
}

fn void GameBoy.run_frame(&self) {
	if ((self.mmu.ppu.lcdc & ppu::LCDC_ENABLE) == 0) {
		ulong target = self.cpu.clk + 17556;
		while (self.cpu.clk < target) self.step();
		return;
	}
	self.mmu.ppu.frame_ready = false;
	ulong deadline = self.cpu.clk + 35112; // ~2 frames, guards against a hang
	while (!self.mmu.ppu.frame_ready && self.cpu.clk < deadline) self.step();
	self.mmu.ppu.frame_ready = false;
}
