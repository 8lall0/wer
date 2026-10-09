module cpu;

import mmu;
import std::io;

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
	// just start: a DMG's HALT lasts 2 M-cycles at least, so an interrupt in
	// the first is taken after the second (Gambatte CPU 0x76: 4 + 4 * !cgb).
	if (self.halted) {
		bool seen_early = !self.just_halted && !self.halt_first_ran && mmu.irq_early;
		self.halted = false;
		self.just_halted = false;
		self.halt_first_ran = false;
		self.speed_switch_halt = 0;
		// The wake-up cycle still counts as halted for the OAM DMA and an
		// HBlank DMA request (Gambatte updates both before unhalting).
		if (!seen_early) {
			mmu.oam_dma_hold = true;
			mmu.cpu_halted = true;
			self.idle(mmu);
			mmu.cpu_halted = false;
			mmu.oam_dma_hold = false;
		}
		// Gambatte decides on an HBlank DMA block after that cycle; such a
		// block goes before the next opcode is read.
		mmu.hdma_unhalt();
		self.no_prefetch = mmu.hdma_due;
		// An HBlank DMA that came due meanwhile goes before the dispatch.
		if (mmu.hdma_due) return true;
		if (!self.ime) return !seen_early;
	}
	if (!self.ime) return false;

	if (io_trace) io::eprintfn("INT if %02X ly %d lc %d", pending, mmu.ppu.line, mmu.ppu.dot);
	self.prefetched = false; // a dispatch undoes the prefetch
	self.prefetch_keeps_pc = false;
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
	// 5 M-cycles: 3 internal, push PC high, push PC low (Gambatte
	// Interrupter::interrupt: the interrupt is picked between the pushes).
	self.idle(mmu);
	self.idle(mmu);
	self.sp_dec_idle(mmu);

	// PC is pushed by hand because the CPU picks the interrupt only after the
	// high byte is on the stack: with SP = $0000 that byte lands in IE ($FFFF)
	// and can disable the very interrupt being dispatched (Mooneye ie_push).
	self.sp--;
	self.idu_next(self.sp);
	self.write(mmu, self.sp, (char)(self.pc >> 8));
	char pending_now = (char)(mmu.get(IE_ADDR) & mmu.get(IF_ADDR) & INT_MASK);
	if (pending_now == 0) {
		// Cancelled: jump to $0000, IF untouched. IME stays off.
		self.sp--;
		self.write(mmu, self.sp, (char)(self.pc & 0xFF));
		self.pc = 0x0000;
		return true;
	}

	// Bit 0 (VBlank) is the highest priority, bit 4 (Joypad) the lowest.
	char bit = 0;
	while ((pending_now & (char)(1 << bit)) == 0) bit++;
	// Acknowledged now, and with it the same interrupt raised again in the
	// next couple of cycles (Gambatte Memory::ackIrq; Mmu.ack_bit).
	self.sp--;
	if (self.sp == IF_ADDR) {
		// The push lands on IF itself: it goes first, then the acknowledge.
		self.write(mmu, self.sp, (char)(self.pc & 0xFF));
		mmu.io[0x0F] &= (char)~(1 << bit);
	} else {
		mmu.io[0x0F] &= (char)~(1 << bit); // not a CPU IF write (see Mmu.if_written)
		mmu.ack_bit = (char)(1 << bit);
		self.write(mmu, self.sp, (char)(self.pc & 0xFF));
	}
	self.pc = (ushort)(0x0040 + (int)bit * 8);
	return true;
}

fn void Cpu.halt(&self, mmu::Mmu *mmu) {
	if (self.interrupt_pending(mmu)) {
		// An interrupt already pending: no HALT, the HALT bug. With IME on
		// the interrupt is taken at once and returns to the HALT, which then
		// runs again (Gambatte CPU 0x76: pendingIrqs; halt/late_m0int_*).
		self.halt_bug = true;
	} else {
		self.halted = true;
		self.just_halted = true;
		self.halt_dma_ran = false;
		// With an HBlank DMA block requested, the byte after HALT is read now
		// and runs first, without PC moving on: the same address is fetched
		// again after it (Gambatte CPU 0x76: prefetched = Memory::halt()).
		if (mmu.cgb_mode && mmu.hdma_due) {
			self.prefetch_op = self.bus_value(mmu, self.pc);
			self.prefetched = true;
			self.prefetch_keeps_pc = true;
		}
		mmu.hdma_halt();
	}
}
