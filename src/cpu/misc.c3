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

// M-cycles the CPU stays halted after a CGB speed switch: 0x20008 cycles of
// the new clock (SameBoy). The timer runs on (Gambatte speedchange_tima00:
// TIMA +$80, speedchange_div: DIV back at $00), the APU stands still
// (speedchange_ch2_nr52: no length clocks; *_ch1_duty0_*: no duty steps).
const int SPEED_SWITCH_HALT = 0x20008 / 4;

// NB: stop is just a simple DIV handling, on emulation we don't need to preserve power.
// On a CGB with a speed switch armed (KEY1 bit 0), STOP is how the switch
// happens: the clock changes, then the CPU waits halted while the rest of the
// machine runs on, unless an interrupt wakes it first.
fn void Cpu.stop(&self, mmu::Mmu *mmu) {
	mmu.timer.write_div(); // side effect of STOP, not a CPU bus access
	if (!mmu.cgb_mode || (mmu.key1 & 1) == 0) return;
	// With IME off, the DIV reset is held for one more M-cycle (SameBoy: div_cycles = -4).
	if (!self.ime) mmu.timer_hold = 1;
	bool pending = self.interrupt_pending(mmu);
	if (pending) {
		self.pc--; // with an interrupt pending the byte after STOP runs as an instruction
	} else {
		self.idle(mmu); // reading that byte
	}
	mmu.set_double_speed(!mmu.double_speed);
	mmu.ppu_freeze = mmu::SWITCH_PPU_FREEZE[mmu.double_speed ? 0 : 1];
	if (!pending) {
		self.halted = true;
		self.just_halted = true;
		self.speed_switch_halt = SPEED_SWITCH_HALT;
		mmu.apu_frozen = true;
	}
}