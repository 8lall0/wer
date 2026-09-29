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

// M-cycles the CPU stands still while a CGB changes speed (Pan Docs).
const int SPEED_SWITCH_MCYCLES = 2050;

// NB: stop is just a simple DIV handling, on emulation we don't need to preserve power.
// On a CGB with a speed switch armed (KEY1 bit 0), STOP is how the switch
// happens: the CPU pauses while the clock changes, the rest of the machine
// keeps running.
fn void Cpu.stop(&self, mmu::Mmu *mmu) {
	mmu.timer.write_div(); // side effect of STOP, not a CPU bus access
	if (!mmu.cgb_mode || (mmu.key1 & 1) == 0) return;
	mmu.set_double_speed(!mmu.double_speed);
	for (int i = 0; i < SPEED_SWITCH_MCYCLES; i++) mmu.tick(1);
	self.clk += SPEED_SWITCH_MCYCLES; // too long for bus_cycles
}