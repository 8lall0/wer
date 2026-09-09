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

	self.required_cycles = 1;
}

fn void Cpu.nop(&self) {
	self.required_cycles = 1;
}

fn void Cpu.stop(&self, mmu::Mmu *mmu) {
	self.stopped = true;
	mmu.set(DIV_ADDR, 0);

	self.required_cycles = 1;
}