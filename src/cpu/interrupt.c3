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
	// A second EI while one is pending does not restart the delay.
	if (self.ime_delay == 0) self.ime_delay = 2;

	self.required_cycles = 1;
}

fn char Cpu.service_interrupt(&self, mmu::Mmu *mmu) {
	char pending = (char)(mmu.get(IE_ADDR) & mmu.get(IF_ADDR) & INT_MASK);
	if (pending == 0) return 0;

	self.halted = false;
	// TODO: STOP is only released by joypad.

	if (!self.ime) return 0;

	self.ime = false;
	self.ime_delay = 0;  // a pending EI must not re-enable IME inside the handler

	// PC is pushed by hand because the CPU picks the interrupt only after the
	// high byte is on the stack: with SP = $0000 that byte lands in IE ($FFFF)
	// and can disable the very interrupt being dispatched (Mooneye ie_push).
	self.sp--;
	mmu.set(self.sp, (char)(self.pc >> 8));
	char pending_now = (char)(mmu.get(IE_ADDR) & mmu.get(IF_ADDR) & INT_MASK);
	self.sp--;
	mmu.set(self.sp, (char)(self.pc & 0xFF));

	if (pending_now == 0) {
		// Cancelled: jump to $0000, IF untouched. IME stays off.
		self.pc = 0x0000;
		return 5;
	}

	// Bit 0 (VBlank) is the highest priority, bit 4 (Joypad) the lowest.
	char bit = 0;
	while ((pending_now & (char)(1 << bit)) == 0) bit++;

	mmu.set(IF_ADDR, (char)(mmu.get(IF_ADDR) & ~(1 << bit)));
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
