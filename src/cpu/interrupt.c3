module cpu;

import mmu;

// True when at least one enabled interrupt line is pending (IE & IF).
fn bool Cpu.interrupt_pending(&self, mmu::Mmu *mmu) {
	return (mmu.get(IE_ADDR) & mmu.get(IF_ADDR) & INT_MASK) != 0;
}

// DI : disable interrupts immediately (and cancel a pending EI).
fn void Cpu.di(&self) {
	self.ime = false;
	self.ime_delay = 0;

	self.required_cycles = 1;
}

// EI : enable interrupts, but only after the instruction *following* EI.
// `Cpu.step` counts `ime_delay` down and sets IME when it hits 0.
fn void Cpu.ei(&self) {
	self.ime_delay = 2;

	self.required_cycles = 1;
}

fn char Cpu.service_interrupt(&self, mmu::Mmu *mmu) {
	char pending = (char)(mmu.get(IE_ADDR) & mmu.get(IF_ADDR) & INT_MASK);
	if (pending == 0) return 0;

	self.halted = false;
	// TODO: STOP is only released by joypad.

	if (!self.ime) return 0;

	// Bit 0 (VBlank) is the highest priority, bit 4 (Joypad) the lowest.
	char bit = 0;
	while ((pending & (char)(1 << bit)) == 0) bit++;

	self.ime = false;
	mmu.set(IF_ADDR, (char)(mmu.get(IF_ADDR) & ~(1 << bit)));
	self.push16(mmu, self.pc);
	self.pc = (ushort)(0x0040 + (int)bit * 8);

	return 5;
}

fn void Cpu.halt(&self, mmu::Mmu *mmu) {
	if (!self.ime && self.interrupt_pending(mmu)) {
		self.halt_bug = true;
	} else {
		self.halted = true;
	}

	self.required_cycles = 1;
}
