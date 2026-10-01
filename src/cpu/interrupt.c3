module cpu;

import mmu;

// True when at least one enabled interrupt line is pending (IE & IF).
// IE/IF are read directly, not through Cpu.read: the interrupt controller
// sees these lines without spending a bus cycle.
fn bool Cpu.interrupt_pending(&self, mmu::Mmu *mmu) {
	return (mmu.get(IE_ADDR) & mmu.get(IF_ADDR) & INT_MASK) != 0;
}

// DI : disable interrupts immediately (and cancel a pending EI).
fn void Cpu.di(&self) {
	self.ime = false;
	self.ime_delay = 0;
}

// EI : enable interrupts, but only after the instruction *following* EI.
// `Cpu.step` counts `ime_delay` down and sets IME when it hits 0.
fn void Cpu.ei(&self) {
	// A second EI while one is pending does not restart the delay.
	if (self.ime_delay == 0) self.ime_delay = 2;
}

// Returns true when an interrupt was dispatched (5 M-cycles, counted by the
// bus wrappers). A pending interrupt also ends HALT even with IME off.
fn bool Cpu.service_interrupt(&self, mmu::Mmu *mmu) {
	char pending = (char)(mmu.get(IE_ADDR) & mmu.get(IF_ADDR) & INT_MASK);
	if (pending == 0) return false;

	// Waking from HALT takes one more M-cycle before the CPU carries on or
	// dispatches (Gambatte tima tests; SameBoy), unless the interrupt came
	// early enough in its M-cycle to be seen at once (Mmu.irq_early: the
	// PPU's; Mooneye intr_2_*, di_timing; Gambatte halt) and HALT didn't only
	// just start.
	if (self.halted) {
		bool seen_early = !self.just_halted && mmu.irq_early;
		self.halted = false;
		self.just_halted = false;
		self.speed_switch_halt = 0;
		mmu.apu_frozen = false;
		if (!seen_early) self.idle(mmu);
		if (!self.ime) return !seen_early;
	}
	// TODO: STOP is only released by joypad.

	if (!self.ime) return false;

	self.ime = false;
	self.ime_delay = 0;  // a pending EI must not re-enable IME inside the handler
	// EI; HALT with an interrupt already pending: HALT hits the HALT bug (IME
	// is still off), then IME comes on and the interrupt is taken at once.
	// The PC it pushes is HALT's own, so HALT runs again on return
	// (SameSuite ei_delay_halt).
	if (self.halt_bug) {
		self.pc--;
		self.halt_bug = false;
	}
	// 5 M-cycles: 2 internal, push PC high, push PC low, 1 internal (jump).
	self.idle(mmu);
	self.sp_dec_idle(mmu);

	// PC is pushed by hand because the CPU picks the interrupt only after the
	// high byte is on the stack: with SP = $0000 that byte lands in IE ($FFFF)
	// and can disable the very interrupt being dispatched (Mooneye ie_push).
	self.sp--;
	self.idu_next(self.sp);
	self.write(mmu, self.sp, (char)(self.pc >> 8));
	char pending_now = (char)(mmu.get(IE_ADDR) & mmu.get(IF_ADDR) & INT_MASK);
	self.sp--;
	self.write(mmu, self.sp, (char)(self.pc & 0xFF));

	if (pending_now == 0) {
		// Cancelled: jump to $0000, IF untouched. IME stays off.
		self.pc = 0x0000;
		self.idle(mmu);
		return true;
	}

	// Bit 0 (VBlank) is the highest priority, bit 4 (Joypad) the lowest.
	char bit = 0;
	while ((pending_now & (char)(1 << bit)) == 0) bit++;

	mmu.set(IF_ADDR, (char)(mmu.get(IF_ADDR) & ~(1 << bit)));
	self.pc = (ushort)(0x0040 + (int)bit * 8);
	self.idle(mmu);

	return true;
}

fn void Cpu.halt(&self, mmu::Mmu *mmu) {
	if (!self.ime && self.interrupt_pending(mmu)) {
		self.halt_bug = true;
	} else {
		self.halted = true;
		self.just_halted = true;
	}
}
