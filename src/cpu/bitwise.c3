module cpu;

import mmu;

// CPL : A = ~A. Flags: N=1, H=1 (Z, C unaffected).
fn void Cpu.cpl(&self) {
	self.af.hi = ~self.af.hi;

	self.setFlag(N);
	self.setFlag(H);

	self.required_cycles = 1;
}

// ---------------------------------------------------------------------------
// AND : Z=* N=0 H=1 C=0
// ---------------------------------------------------------------------------
fn void Cpu.and_a(&self, char value) {
	self.af.hi &= value;

	self.updateZero(self.af.hi);
	self.unsetFlag(N);
	self.setFlag(H);
	self.unsetFlag(C);
}

fn void Cpu.and_a_r8(&self, char *reg) {
	self.and_a(*reg);
	self.required_cycles = 1;
}

fn void Cpu.and_a_hl(&self, mmu::Mmu *mmu) {
	self.and_a(mmu.get(self.hl.reg));
	self.required_cycles = 2;
}

fn void Cpu.and_a_n8(&self, char value) {
	self.and_a(value);
	self.required_cycles = 2;
}

// ---------------------------------------------------------------------------
// OR : Z=* N=0 H=0 C=0
// ---------------------------------------------------------------------------
fn void Cpu.or_a(&self, char value) {
	self.af.hi |= value;

	self.updateZero(self.af.hi);
	self.unsetFlag(N);
	self.unsetFlag(H);
	self.unsetFlag(C);
}

fn void Cpu.or_a_r8(&self, char *reg) {
	self.or_a(*reg);
	self.required_cycles = 1;
}

fn void Cpu.or_a_hl(&self, mmu::Mmu *mmu) {
	self.or_a(mmu.get(self.hl.reg));
	self.required_cycles = 2;
}

fn void Cpu.or_a_n8(&self, char value) {
	self.or_a(value);
	self.required_cycles = 2;
}

// ---------------------------------------------------------------------------
// XOR : Z=* N=0 H=0 C=0
// ---------------------------------------------------------------------------
fn void Cpu.xor_a(&self, char value) {
	self.af.hi ^= value;

	self.updateZero(self.af.hi);
	self.unsetFlag(N);
	self.unsetFlag(H);
	self.unsetFlag(C);
}

fn void Cpu.xor_a_r8(&self, char *reg) {
	self.xor_a(*reg);
	self.required_cycles = 1;
}

fn void Cpu.xor_a_hl(&self, mmu::Mmu *mmu) {
	self.xor_a(mmu.get(self.hl.reg));
	self.required_cycles = 2;
}

fn void Cpu.xor_a_n8(&self, char value) {
	self.xor_a(value);
	self.required_cycles = 2;
}
