module cpu;

import mmu;


// Z from result, N=0, H=0, C as given.
fn void Cpu.shift_flags(&self, char result, bool carry) {
	self.updateZero(result);
	self.unsetFlag(N);
	self.unsetFlag(H);
	self.assignFlag(C, carry);
}

// ---------------------------------------------------------------------------
// Value helpers
// ---------------------------------------------------------------------------

// RLC: rotate left, bit 7 -> C and -> bit 0.
fn char Cpu.rlc_value(&self, char value) {
	char result = (char)((value << 1) | (value >> 7));
	self.shift_flags(result, (value & 0x80) != 0);
	return result;
}

// RRC: rotate right, bit 0 -> C and -> bit 7.
fn char Cpu.rrc_value(&self, char value) {
	char result = (char)((value >> 1) | (value << 7));
	self.shift_flags(result, (value & 0x01) != 0);
	return result;
}

// RL: rotate left through carry (old C -> bit 0, bit 7 -> C).
fn char Cpu.rl_value(&self, char value) {
	char result = (char)((value << 1) | self.getFlag(C));
	self.shift_flags(result, (value & 0x80) != 0);
	return result;
}

// RR: rotate right through carry (old C -> bit 7, bit 0 -> C).
fn char Cpu.rr_value(&self, char value) {
	char result = (char)((value >> 1) | (self.getFlag(C) << 7));
	self.shift_flags(result, (value & 0x01) != 0);
	return result;
}

// SLA: shift left, bit 0 = 0, bit 7 -> C.
fn char Cpu.sla_value(&self, char value) {
	char result = (char)(value << 1);
	self.shift_flags(result, (value & 0x80) != 0);
	return result;
}

// SRA: arithmetic shift right, bit 7 kept, bit 0 -> C.
fn char Cpu.sra_value(&self, char value) {
	char result = (char)((value >> 1) | (value & 0x80));
	self.shift_flags(result, (value & 0x01) != 0);
	return result;
}

// SRL: logical shift right, bit 7 = 0, bit 0 -> C.
fn char Cpu.srl_value(&self, char value) {
	char result = (char)(value >> 1);
	self.shift_flags(result, (value & 0x01) != 0);
	return result;
}

// SWAP: exchange the two nibbles. C is cleared.
fn char Cpu.swap_value(&self, char value) {
	char result = (char)((value << 4) | (value >> 4));
	self.shift_flags(result, false);
	return result;
}

// ---------------------------------------------------------------------------
// Accumulator forms (RLCA / RRCA / RLA / RRA): 1 byte, Z always cleared.
// ---------------------------------------------------------------------------

fn void Cpu.rlca(&self) {
	self.af.hi = self.rlc_value(self.af.hi);
	self.unsetFlag(Z);
	self.required_cycles = 1;
}

fn void Cpu.rrca(&self) {
	self.af.hi = self.rrc_value(self.af.hi);
	self.unsetFlag(Z);
	self.required_cycles = 1;
}

fn void Cpu.rla(&self) {
	self.af.hi = self.rl_value(self.af.hi);
	self.unsetFlag(Z);
	self.required_cycles = 1;
}

fn void Cpu.rra(&self) {
	self.af.hi = self.rr_value(self.af.hi);
	self.unsetFlag(Z);
	self.required_cycles = 1;
}

// ---------------------------------------------------------------------------
// CB-prefixed forms on r8 (2 cycles) and [HL] (4 cycles).
// ---------------------------------------------------------------------------

fn void Cpu.rlc_r8(&self, char *reg) {
	*reg = self.rlc_value(*reg);
	self.required_cycles = 2;
}

fn void Cpu.rlc_hl(&self, mmu::Mmu *mmu) {
	mmu.set(self.hl.reg, self.rlc_value(mmu.get(self.hl.reg)));
	self.required_cycles = 4;
}

fn void Cpu.rrc_r8(&self, char *reg) {
	*reg = self.rrc_value(*reg);
	self.required_cycles = 2;
}

fn void Cpu.rrc_hl(&self, mmu::Mmu *mmu) {
	mmu.set(self.hl.reg, self.rrc_value(mmu.get(self.hl.reg)));
	self.required_cycles = 4;
}

fn void Cpu.rl_r8(&self, char *reg) {
	*reg = self.rl_value(*reg);
	self.required_cycles = 2;
}

fn void Cpu.rl_hl(&self, mmu::Mmu *mmu) {
	mmu.set(self.hl.reg, self.rl_value(mmu.get(self.hl.reg)));
	self.required_cycles = 4;
}

fn void Cpu.rr_r8(&self, char *reg) {
	*reg = self.rr_value(*reg);
	self.required_cycles = 2;
}

fn void Cpu.rr_hl(&self, mmu::Mmu *mmu) {
	mmu.set(self.hl.reg, self.rr_value(mmu.get(self.hl.reg)));
	self.required_cycles = 4;
}

fn void Cpu.sla_r8(&self, char *reg) {
	*reg = self.sla_value(*reg);
	self.required_cycles = 2;
}

fn void Cpu.sla_hl(&self, mmu::Mmu *mmu) {
	mmu.set(self.hl.reg, self.sla_value(mmu.get(self.hl.reg)));
	self.required_cycles = 4;
}

fn void Cpu.sra_r8(&self, char *reg) {
	*reg = self.sra_value(*reg);
	self.required_cycles = 2;
}

fn void Cpu.sra_hl(&self, mmu::Mmu *mmu) {
	mmu.set(self.hl.reg, self.sra_value(mmu.get(self.hl.reg)));
	self.required_cycles = 4;
}

fn void Cpu.srl_r8(&self, char *reg) {
	*reg = self.srl_value(*reg);
	self.required_cycles = 2;
}

fn void Cpu.srl_hl(&self, mmu::Mmu *mmu) {
	mmu.set(self.hl.reg, self.srl_value(mmu.get(self.hl.reg)));
	self.required_cycles = 4;
}

fn void Cpu.swap_r8(&self, char *reg) {
	*reg = self.swap_value(*reg);
	self.required_cycles = 2;
}

fn void Cpu.swap_hl(&self, mmu::Mmu *mmu) {
	mmu.set(self.hl.reg, self.swap_value(mmu.get(self.hl.reg)));
	self.required_cycles = 4;
}
