module cpu;

import mmu;

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

fn void Cpu.ld_hl_r8(&self, mmu::Mmu mmu, char *reg) {
	mmu.set(self.hl.reg, *reg);

	self.required_cycles = 2;
}

fn void Cpu.ld_hl_n8(&self, mmu::Mmu mmu, char value) {
	mmu.set(self.hl.reg, value);

	self.required_cycles = 3;
}

fn void Cpu.ld_r8_hl(&self, mmu::Mmu mmu, char *reg) {
	*reg = mmu.get(self.hl.reg);

	self.required_cycles = 2;
}

fn void Cpu.ld_r16_a(&self, mmu::Mmu mmu, HiLoReg *reg) {
	self.af.hi = mmu.get(reg.reg);

	self.required_cycles = 2;
}

fn void Cpu.ld_n16_a(&self, mmu::Mmu mmu, ushort address) {
	mmu.set(address, self.af.hi);

	self.required_cycles = 4;
}

/*
TODO: analyze this
The destination address n16 is encoded as its 8-bit low byte and assumes a high byte of $FF, so it must be between $FF00 and $FFFF.
*/
fn void Cpu.ldh_n16_a(&self, mmu::Mmu mmu, ushort address) {
	self.af.hi = mmu.get(address);

	self.required_cycles = 3;
}
// TODO: analyze this
// Copy the value in register A into the byte at address $FF00+C.
fn void Cpu.ldh_c_a(&self, mmu::Mmu mmu, ushort address) {
	self.af.hi = mmu.get(address);

	self.required_cycles = 2;
}

fn void Cpu.ld_a_r16(&self, mmu::Mmu mmu, HiLoReg *reg) {
	self.af.hi = mmu.get(reg.reg);

	self.required_cycles = 2;
}

fn void Cpu.ld_a_n16(&self, mmu::Mmu mmu, ushort address) {
	self.af.hi = mmu.get(address);

	self.required_cycles = 3;
}

/*
TODO: analyze this
The source address n16 is encoded as its 8-bit low byte and assumes a high byte of $FF, so it must be between $FF00 and $FFFF.
*/
fn void Cpu.ldh_a_n16(&self, mmu::Mmu mmu, ushort address) {
	//self.af.hi = mmu.get(address);

	self.required_cycles = 3;
}
// TODO: analyze this
// Copy the value in register A into the byte at address $FF00+C.
fn void Cpu.ldh_a_c(&self, mmu::Mmu mmu, ushort address) {
	//self.af.hi = mmu.get(address);

	self.required_cycles = 2;
}

fn void Cpu.ldh_hli_a(&self, mmu::Mmu mmu) {
	mmu.set(self.hl.reg, self.af.hi);

	self.af.hi++;

	self.required_cycles = 2;
}

fn void Cpu.ldh_hld_a(&self, mmu::Mmu mmu) {
	mmu.set(self.hl.reg, self.af.hi);

	self.af.hi--;

	self.required_cycles = 2;
}

fn void Cpu.ldh_a_hli(&self, mmu::Mmu mmu) {
	self.af.hi = mmu.get(self.hl.reg);

	self.af.hi++;

	self.required_cycles = 2;
}

fn void Cpu.ldh_a_hld(&self, mmu::Mmu mmu) {
	self.af.hi = mmu.get(self.hl.reg);

	self.af.hi--;

	self.required_cycles = 2;
}