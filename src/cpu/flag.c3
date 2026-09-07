module cpu;

import mmu;

/*
BIT u3,r8
BIT u3,[HL]
RES u3,r8
RES u3,[HL]
SET u3,r8
SET u3,[HL]
*/

// What's U3?

fn void Cpu.bit_u3_r8(&self, char *reg, uint u3) {
	char val = *reg &= 1 << u3;

	if (val == 0) {
		self.setFlag(Z);
	}
	self.unsetFlag(N);
	self.setFlag(H);

	self.required_cycles = 2;
}

fn void Cpu.bit_u3_hl(&self, mmu::Mmu *mmu, uint u3) {
	char value = mmu.get(self.hl.reg);
	char val = value &= 1 << u3;

	if (val == 0) {
		self.setFlag(Z);
	}
	self.unsetFlag(N);
	self.setFlag(H);

	self.required_cycles = 3;
}

fn void Cpu.res_u3_r8(&self, char *reg, uint u3) {
	*(reg) &= ~(1 << u3);

	self.required_cycles = 2;
}

fn void Cpu.res_u3_hl(&self, mmu::Mmu *mmu, uint u3) {
	char value = mmu.get(self.hl.reg);
	value &= ~(1 << u3);
	mmu.set(self.hl.reg, value);

	self.required_cycles = 4;
}

fn void Cpu.set_u3_r8(&self, char *reg, uint u3) {
	*(reg) |= 1 << u3;

	self.required_cycles = 2;
}

fn void Cpu.set_u3_hl(&self, mmu::Mmu *mmu, uint u3) {
	char value = mmu.get(self.hl.reg);
	value |= 1 << u3;
	mmu.set(self.hl.reg, value);

	self.required_cycles = 4;
}