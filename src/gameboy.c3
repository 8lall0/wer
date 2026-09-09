module gameboy;

import cpu, mmu;
import std::io::file;

// Top-level machine: owns the CPU and the memory map, and drives them in step.
struct GameBoy {
	cpu::Cpu cpu;
	mmu::Mmu mmu;
}

fn GameBoy new() {
	GameBoy gb;
	gb.cpu = cpu::init();
	return gb;
}

// Copy a cartridge image into ROM. No MBC yet, so anything past the first
// 32 KiB is dropped.
fn void GameBoy.load_rom(&self, char[] data) {
	usz n = data.len < 0x8000 ? data.len : 0x8000;
	for (usz i = 0; i < n; i++) {
		self.mmu.rom[i] = data[i];
	}
}

// Load a cartridge image from a file on disk.
fn void? GameBoy.load_rom_file(&self, String path) {
	char[] data = file::load_temp(path)!;
	self.load_rom(data);
}

// Run one CPU instruction (or interrupt / idle cycle) and advance the
// peripherals by the cycles it took. Returns the M-cycles consumed.
fn char GameBoy.step(&self) {
	char cycles = self.cpu.step(&self.mmu);
	self.mmu.tick(cycles);
	return cycles;
}
