module cpu;

import mmu;

fn void Cpu.cpl(&self) {
	self.af.hi = ~self.af.hi;

	self.setFlag(N);
	self.setFlag(H);

	self.required_cycles = 1;
}

// AND
fn void Cpu.and_a_r8(&self, char *reg) {

	self.af.hi &= *reg;
	self.setFlag(H);
	self.unsetFlag(N);
	self.unsetFlag(C);

	if (self.af.hi == 0) {
		self.setFlag(Z);
	} else {
		self.unsetFlag(Z);
	}

	self.required_cycles = 2;
}

fn void Cpu.and_a_hl(&self, mmu::Mmu *mmu) {
	self.setFlag(H);
	self.af.hi &= mmu.get(self.hl.reg);

	if (self.af.hi == 0) {
		self.setFlag(Z);
	} else {
		self.unsetFlag(Z);
	}

	self.required_cycles = 1;
}

fn void Cpu.and_a_n8(&self, char value) {
	self.setFlag(H);
	self.af.hi &= value;

	if (self.af.hi == 0) {
		self.setFlag(Z);
	} else {
		self.unsetFlag(Z);
	}

	self.required_cycles = 2;
}

// OR
fn void Cpu.or_a_r8(&self, char *reg) {
	self.af.hi |= *reg;

	self.unsetFlag(N);
	self.unsetFlag(H);
	self.unsetFlag(C);
	if (self.af.hi == 0) {
		self.setFlag(Z);
	} else {
		self.unsetFlag(Z);
	}

	self.required_cycles = 1;
}

fn void Cpu.or_a_hl(&self, mmu::Mmu *mmu) {
	self.af.hi |= mmu.get(self.hl.reg);

	self.unsetFlag(N);
	self.unsetFlag(H);
	self.unsetFlag(C);
	if (self.af.hi == 0) {
		self.setFlag(Z);
	} else {
		self.unsetFlag(Z);
	}

	self.required_cycles = 2;
}

fn void Cpu.or_a_n8(&self, char value) {
	self.af.hi |= value;

	self.unsetFlag(N);
	self.unsetFlag(H);
	self.unsetFlag(C);
	if (self.af.hi == 0) {
		self.setFlag(Z);
	} else {
		self.unsetFlag(Z);
	}

	self.required_cycles = 2;
}

//XOR
fn void Cpu.xor_a_r8(&self, char *reg) {
	self.af.hi ^= *reg;

	self.unsetFlag(N);
	self.unsetFlag(H);
	self.unsetFlag(C);
	if (self.af.hi == 0) {
		self.setFlag(Z);
	} else {
		self.unsetFlag(Z);
	}

	self.required_cycles = 1;
}

fn void Cpu.xor_a_hl(&self, mmu::Mmu *mmu) {
	self.af.hi ^= mmu.get(self.hl.reg);

	self.unsetFlag(N);
	self.unsetFlag(H);
	self.unsetFlag(C);
	if (self.af.hi == 0) {
		self.setFlag(Z);
	} else {
		self.unsetFlag(Z);
	}

	self.required_cycles = 2;
}

fn void Cpu.xor_a_n8(&self, char value) {
	self.af.hi ^= value;

	self.unsetFlag(N);
	self.unsetFlag(H);
	self.unsetFlag(C);
	if (self.af.hi == 0) {
		self.setFlag(Z);
	} else {
		self.unsetFlag(Z);
	}

	self.required_cycles = 2;
}