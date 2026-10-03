module cpu;

import mmu;

fn void Cpu.daa(&self) {
	char a = self.af.hi;

	if (self.getFlag(N) == 0) {
		// After an addition.
		if (self.getFlag(C) == 1 || a > 0x99) {
			a += 0x60;
			self.setFlag(C);
		}
		if (self.getFlag(H) == 1 || (a & 0x0F) > 0x09) {
			a += 0x06;
		}
	} else {
		// After a subtraction: only undo corrections that were needed.
		if (self.getFlag(C) == 1) {
			a -= 0x60;
		}
		if (self.getFlag(H) == 1) {
			a -= 0x06;
		}
	}

	self.af.hi = a;

	self.updateZero(a);
	self.unsetFlag(H);
}

fn void Cpu.nop(&self) {
	// Nothing to do: the opcode fetch is its only M-cycle.
}

// A CGB speed switch (Gambatte Memory::stop): the clock changes 2 normal
// M-cycles after STOP going to double speed, at once going back, and the CPU
// stays halted until 0x20004 CPU cycles after STOP. The timer and the APU
// run on.
const int[2] SWITCH_PRE = { 2, 1 };              // M-cycles before the clock changes: to double, to normal
const int[2] SWITCH_HALT = { 0x7FFF, 0x8001 };   // then halted this long (in M-cycles of the new clock)

// NB: stop is just a simple DIV handling, on emulation we don't need to preserve power.
// On a CGB with a speed switch armed (KEY1 bit 0), STOP is how the switch
// happens: the clock changes, then the CPU waits halted while the rest of the
// machine runs on, unless an interrupt wakes it first.
fn void Cpu.stop(&self, mmu::Mmu *mmu) {
	bool switching = mmu.cgb_mode && (mmu.key1 & 1) != 0;
	// A speed switch gives a fast-clocked timer 4 more cycles (Gambatte
	// Tima::speedChange, TAC >= 5).
	if (switching) mmu.timer.speed_change();
	bool to_double = switching && !mmu.double_speed;
	mmu.timer.write_div(switching && mmu.cgb_rev > C); // side effect of STOP, not a CPU bus access
	mmu.apu.clock_div_reset();
	if (!switching) return;
	// Going back to normal speed the clock changes at once (Gambatte): the
	// timer and the APU's clock don't see the M-cycle the PPU still runs
	// before it.
	bool pending = self.interrupt_pending(mmu);
	if (!to_double) {
		// With an interrupt waiting, a CGB-D/E's timer misses nothing here
		// (AGE spsw-interrupts-cgbE).
		mmu.timer_hold = pending && mmu.cgb_rev > C ? 0 : SWITCH_PRE[1];
		mmu.apu.clock_switch(false);
		mmu.apu.clock_hold = SWITCH_PRE[1];
	} else if (pending && mmu.cgb_rev <= C) {
		// ... and going to double speed an earlier CGB's misses an M-cycle
		// (AGE spsw-interrupts-cgbBC).
		mmu.timer_hold = 1;
	}
	if (pending) {
		self.pc--; // with an interrupt pending the byte after STOP runs as an instruction
	} else {
		// Halted from the STOP on as far as HBlank DMA requests go (Gambatte
		// Memory::stop halts before the clock changes).
		// With an HBlank DMA block requested the byte after STOP runs as an
		// instruction too, as read now, before the block's copy (Gambatte:
		// stop() returns it as prefetched).
		if (mmu.hdma_due) {
			self.pc--;
			self.prefetch_op = self.bus_value(mmu, self.pc);
			self.prefetched = true;
		}
		mmu.hdma_stop(to_double);
		mmu.hdma_hold = true;
		// The OAM DMA gets one more M-cycle, then stands still (Gambatte
		// Memory::stop: updateOamDma(cc + 4)).
		for (int i = 0; i < SWITCH_PRE[to_double ? 0 : 1]; i++) {
			mmu.oam_dma_hold = i > 0;
			self.idle(mmu); // reading that byte, ...
		}
		mmu.oam_dma_hold = false;
		mmu.hdma_hold = false;
	}
	if (to_double) mmu.apu.clock_switch(true);
	mmu.set_double_speed(to_double);
	mmu.ppu_freeze = mmu::SWITCH_PPU_FREEZE[mmu.double_speed ? 0 : 1];
	if (!pending) {
		self.halted = true;
		self.just_halted = true;
		self.halt_dma_ran = true; // (no extra OAM DMA cycle here)
		self.speed_switch_halt = SWITCH_HALT[to_double ? 0 : 1];
	}
}