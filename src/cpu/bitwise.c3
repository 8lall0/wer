module cpu;

import mmu;
/*
CPL
OR A,r8
OR A,[HL]
OR A,n8
XOR A,r8
XOR A,[HL]
XOR A,n8
*/

// AND
fn void Cpu.and_a_r8(&self, char *reg) {
	self.setFlag(H);
	self.af.hi &= *reg;
	if (self.af.hi == 0) {
		self.setFlag(Z);
	}

	self.required_cycles = 2;
}

fn void Cpu.and_a_hl(&self, mmu::Mmu *mmu) {
	self.setFlag(H);
	self.af.hi &= mmu.get(self.hl.reg);

	if (self.af.hi == 0) {
		self.setFlag(Z);
	}

	self.required_cycles = 1;
}

fn void Cpu.and_a_n8(&self, char value) {
	self.setFlag(H);
	self.af.hi &= value;

	if (self.af.hi == 0) {
		self.setFlag(Z);
	}

	self.required_cycles = 2;
}