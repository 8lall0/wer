module cpu;

import mmu;

// Loads never affect flags.

fn void Cpu.ld_r8_r8(&self, char *regA, char *regB) {
	*regA = *regB;

	self.required_cycles = 1;
}

fn void Cpu.ld_r8_n8(&self, char *regA, char value) {
	*regA = value;

	self.required_cycles = 2;
}

fn void Cpu.ld_r16_n16(&self, HiLoReg *reg, ushort value) {
	reg.reg = value;

	self.required_cycles = 3;
}

// LD [HL],r8
fn void Cpu.ld_hl_r8(&self, mmu::Mmu *mmu, char *reg) {
	mmu.set(self.hl.reg, *reg);

	self.required_cycles = 2;
}

// LD [HL],n8
fn void Cpu.ld_hl_n8(&self, mmu::Mmu *mmu, char value) {
	mmu.set(self.hl.reg, value);

	self.required_cycles = 3;
}

// LD r8,[HL]
fn void Cpu.ld_r8_hl(&self, mmu::Mmu *mmu, char *reg) {
	*reg = mmu.get(self.hl.reg);

	self.required_cycles = 2;
}

// LD [r16],A  (r16 is BC or DE)
fn void Cpu.ld_r16_a(&self, mmu::Mmu *mmu, HiLoReg *reg) {
	mmu.set(reg.reg, self.af.hi);

	self.required_cycles = 2;
}

// LD [n16],A
fn void Cpu.ld_n16_a(&self, mmu::Mmu *mmu, ushort address) {
	mmu.set(address, self.af.hi);

	self.required_cycles = 4;
}

// LDH [n16],A : n16 is encoded as its low byte; the high byte is $FF.
fn void Cpu.ldh_n16_a(&self, mmu::Mmu *mmu, ushort address) {
	mmu.set(0xFF00 | (address & 0xFF), self.af.hi);

	self.required_cycles = 3;
}

// LDH [C],A : write A to $FF00 + C.
fn void Cpu.ldh_c_a(&self, mmu::Mmu *mmu) {
	mmu.set(0xFF00 | (ushort)self.bc.lo, self.af.hi);

	self.required_cycles = 2;
}

// LD A,[r16]  (r16 is BC or DE)
fn void Cpu.ld_a_r16(&self, mmu::Mmu *mmu, HiLoReg *reg) {
	self.af.hi = mmu.get(reg.reg);

	self.required_cycles = 2;
}

// LD A,[n16]
fn void Cpu.ld_a_n16(&self, mmu::Mmu *mmu, ushort address) {
	self.af.hi = mmu.get(address);

	self.required_cycles = 4;
}

// LDH A,[n16] : n16 is encoded as its low byte; the high byte is $FF.
fn void Cpu.ldh_a_n16(&self, mmu::Mmu *mmu, ushort address) {
	self.af.hi = mmu.get(0xFF00 | (address & 0xFF));

	self.required_cycles = 3;
}

// LDH A,[C] : read from $FF00 + C.
fn void Cpu.ldh_a_c(&self, mmu::Mmu *mmu) {
	self.af.hi = mmu.get(0xFF00 | (ushort)self.bc.lo);

	self.required_cycles = 2;
}

// LD [HL+],A : store A at [HL], then increment HL.
fn void Cpu.ld_hli_a(&self, mmu::Mmu *mmu) {
	mmu.set(self.hl.reg, self.af.hi);
	self.hl.reg++;

	self.required_cycles = 2;
}

// LD [HL-],A : store A at [HL], then decrement HL.
fn void Cpu.ld_hld_a(&self, mmu::Mmu *mmu) {
	mmu.set(self.hl.reg, self.af.hi);
	self.hl.reg--;

	self.required_cycles = 2;
}

// LD A,[HL+] : load A from [HL], then increment HL.
fn void Cpu.ld_a_hli(&self, mmu::Mmu *mmu) {
	self.af.hi = mmu.get(self.hl.reg);
	self.hl.reg++;

	self.required_cycles = 2;
}

// LD A,[HL-] : load A from [HL], then decrement HL.
fn void Cpu.ld_a_hld(&self, mmu::Mmu *mmu) {
	self.af.hi = mmu.get(self.hl.reg);
	self.hl.reg--;

	self.required_cycles = 2;
}
