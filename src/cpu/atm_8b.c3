module cpu;

import mmu;

// Core of ADD/ADC: A = A + value + carry, updating Z N H C.
fn void Cpu.add_a(&self, char value, char carry) {
	char a = self.af.hi;
	uint result = (uint)a + (uint)value + (uint)carry;

	self.assignFlag(H, check_bit3_overflow(a, value, carry));
	self.assignFlag(C, result > 0xFF);

	self.af.hi = (char)result;

	self.updateZero(self.af.hi);
	self.unsetFlag(N);
}

// Sum with carry (ADC A,...)
fn void Cpu.adc_a_r8(&self, char *reg) {
	self.add_a(*reg, self.getFlag(C));
	self.required_cycles = 1;
}

fn void Cpu.adc_a_hl(&self, mmu::Mmu *mmu) {
	self.add_a(mmu.get(self.hl.reg), self.getFlag(C));
	self.required_cycles = 2;
}

fn void Cpu.adc_a_n8(&self, char value) {
	self.add_a(value, self.getFlag(C));
	self.required_cycles = 2;
}

// Sum without carry (ADD A,...)
fn void Cpu.add_a_r8(&self, char *reg) {
	self.add_a(*reg, 0);
	self.required_cycles = 1;
}

fn void Cpu.add_a_n8(&self, char value) {
	self.add_a(value, 0);
	self.required_cycles = 2;
}

fn void Cpu.add_a_hl(&self, mmu::Mmu *mmu) {
	self.add_a(mmu.get(self.hl.reg), 0);
	self.required_cycles = 2;
}

// Core of SUB/SBC/CP: computes A - value - carry, updating Z N H C.
// Returns the 8-bit result; the caller decides whether to store it in A.
fn char Cpu.sub_a(&self, char value, char carry) {
	char result = self.af.hi - value - carry;

	self.updateZero(result);
	self.setFlag(N);
	self.assignFlag(H, check_bit3_borrow(self.af.hi, value, carry));
	self.assignFlag(C, check_bit7_borrow(self.af.hi, value, carry));

	return result;
}

fn void Cpu.cp_a_r8(&self, char *reg) {
	self.sub_a(*reg, 0);
	self.required_cycles = 1;
}

fn void Cpu.cp_a_hl(&self, mmu::Mmu *mmu) {
	self.sub_a(mmu.get(self.hl.reg), 0);
	self.required_cycles = 2;
}

fn void Cpu.cp_a_n8(&self, char value) {
	self.sub_a(value, 0);
	self.required_cycles = 2;
}

fn void Cpu.sub_a_r8(&self, char *reg) {
	self.af.hi = self.sub_a(*reg, 0);
	self.required_cycles = 1;
}

fn void Cpu.sub_a_hl(&self, mmu::Mmu *mmu) {
	self.af.hi = self.sub_a(mmu.get(self.hl.reg), 0);
	self.required_cycles = 2;
}

fn void Cpu.sub_a_n8(&self, char value) {
	self.af.hi = self.sub_a(value, 0);
	self.required_cycles = 2;
}

// Subtract with carry (SBC A,...)
fn void Cpu.sbc_a_r8(&self, char *reg) {
	self.af.hi = self.sub_a(*reg, self.getFlag(C));
	self.required_cycles = 1;
}

fn void Cpu.sbc_a_hl(&self, mmu::Mmu *mmu) {
	self.af.hi = self.sub_a(mmu.get(self.hl.reg), self.getFlag(C));
	self.required_cycles = 2;
}

fn void Cpu.sbc_a_n8(&self, char value) {
	self.af.hi = self.sub_a(value, self.getFlag(C));
	self.required_cycles = 2;
}

// INC operand: Z=* N=0 H=carry from bit 3. C is NOT affected.
fn char Cpu.inc_value(&self, char value) {
	char result = value + 1;

	self.updateZero(result);
	self.unsetFlag(N);
	self.assignFlag(H, check_bit3_overflow(value, 1, 0));

	return result;
}

// DEC operand: Z=* N=1 H=borrow from bit 4. C is NOT affected.
fn char Cpu.dec_value(&self, char value) {
	char result = value - 1;

	self.updateZero(result);
	self.setFlag(N);
	self.assignFlag(H, check_bit3_borrow(value, 1, 0));

	return result;
}

fn void Cpu.inc_r8(&self, char *reg) {
	*reg = self.inc_value(*reg);
	self.required_cycles = 1;
}

fn void Cpu.dec_r8(&self, char *reg) {
	*reg = self.dec_value(*reg);
	self.required_cycles = 1;
}

fn void Cpu.inc_hl(&self, mmu::Mmu *mmu) {
	mmu.set(self.hl.reg, self.inc_value(mmu.get(self.hl.reg)));
	self.required_cycles = 3;
}

fn void Cpu.dec_hl(&self, mmu::Mmu *mmu) {
	mmu.set(self.hl.reg, self.dec_value(mmu.get(self.hl.reg)));
	self.required_cycles = 3;
}