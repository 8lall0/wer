module cpu;

import mmu;

// Loads never affect flags.

fn void Cpu.ld_r8_r8(&self, char *regA, char *regB) {
	*regA = *regB;
}

fn void Cpu.ld_r8_n8(&self, char *regA, char value) {
	*regA = value;
}

fn void Cpu.ld_r16_n16(&self, HiLoReg *reg, ushort value) {
	reg.reg = value;
}

// LD [HL],r8
fn void Cpu.ld_hl_r8(&self, mmu::Mmu *mmu, char *reg) {
	self.write(mmu, self.hl.reg, *reg);
}

// LD [HL],n8
fn void Cpu.ld_hl_n8(&self, mmu::Mmu *mmu, char value) {
	self.write(mmu, self.hl.reg, value);
}

// LD r8,[HL]
fn void Cpu.ld_r8_hl(&self, mmu::Mmu *mmu, char *reg) {
	*reg = self.read(mmu, self.hl.reg);
}

// LD [r16],A  (r16 is BC or DE)
fn void Cpu.ld_r16_a(&self, mmu::Mmu *mmu, HiLoReg *reg) {
	self.write(mmu, reg.reg, self.af.hi);
}

// LD [n16],A
fn void Cpu.ld_n16_a(&self, mmu::Mmu *mmu, ushort address) {
	self.write(mmu, address, self.af.hi);
}

// LDH [n16],A : n16 is encoded as its low byte; the high byte is $FF.
fn void Cpu.ldh_n16_a(&self, mmu::Mmu *mmu, ushort address) {
	self.write(mmu, 0xFF00 | (address & 0xFF), self.af.hi);
}

// LDH [C],A : write A to $FF00 + C.
fn void Cpu.ldh_c_a(&self, mmu::Mmu *mmu) {
	self.write(mmu, 0xFF00 | (ushort)self.bc.lo, self.af.hi);
}

// LD A,[r16]  (r16 is BC or DE)
fn void Cpu.ld_a_r16(&self, mmu::Mmu *mmu, HiLoReg *reg) {
	self.af.hi = self.read(mmu, reg.reg);
}

// LD A,[n16]
fn void Cpu.ld_a_n16(&self, mmu::Mmu *mmu, ushort address) {
	self.af.hi = self.read(mmu, address);
}

// LDH A,[n16] : n16 is encoded as its low byte; the high byte is $FF.
fn void Cpu.ldh_a_n16(&self, mmu::Mmu *mmu, ushort address) {
	self.af.hi = self.read(mmu, 0xFF00 | (address & 0xFF));
}

// LDH A,[C] : read from $FF00 + C.
fn void Cpu.ldh_a_c(&self, mmu::Mmu *mmu) {
	self.af.hi = self.read(mmu, 0xFF00 | (ushort)self.bc.lo);
}

// LD [HL+],A : store A at [HL], then increment HL.
fn void Cpu.ld_hli_a(&self, mmu::Mmu *mmu) {
	self.idu_next(self.hl.reg);
	self.write(mmu, self.hl.reg, self.af.hi);
	self.hl.reg++;
}

// LD [HL-],A : store A at [HL], then decrement HL.
fn void Cpu.ld_hld_a(&self, mmu::Mmu *mmu) {
	self.idu_next(self.hl.reg);
	self.write(mmu, self.hl.reg, self.af.hi);
	self.hl.reg--;
}

// LD A,[HL+] : load A from [HL], then increment HL.
fn void Cpu.ld_a_hli(&self, mmu::Mmu *mmu) {
	self.idu_next(self.hl.reg);
	self.af.hi = self.read(mmu, self.hl.reg);
	self.hl.reg++;
}

// LD A,[HL-] : load A from [HL], then decrement HL.
fn void Cpu.ld_a_hld(&self, mmu::Mmu *mmu) {
	self.idu_next(self.hl.reg);
	self.af.hi = self.read(mmu, self.hl.reg);
	self.hl.reg--;
}
