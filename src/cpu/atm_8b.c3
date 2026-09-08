module cpu;

import mmu;
/*
CP A,r8
CP A,[HL]
CP A,n8
DEC r8
DEC [HL]
INC r8
INC [HL]
SBC A,r8
SBC A,[HL]
SBC A,n8
SUB A,r8
SUB A,[HL]
SUB A,n8
*/

// Addition with carriage
fn void Cpu.adc_a_r8(&self, char *reg) {
	char carriage = self.getFlag(C);
	if (check_bit3_overflow(self.af.hi, *reg + carriage)) {
		self.setFlag(H);
	}
	if (check_bit7_overflow(self.af.hi, *reg + carriage)) {
		self.setFlag(C);
	}

	self.af.hi += *reg + carriage;

	if (self.af.hi == 0) {
		self.setFlag(Z);
	} else {
		self.unsetFlag(Z);
	}

	self.required_cycles = 2;
}

fn void Cpu.adc_a_hl(&self, mmu::Mmu *mmu, HiLoReg *reg) {
	char carriage = self.getFlag(C);
	char value = mmu.get(reg.reg);

	if (check_bit3_overflow(self.af.hi, value + carriage)) {
		self.setFlag(H);
	}
	if (check_bit7_overflow(self.af.hi, value + carriage)) {
		self.setFlag(C);
	}

	self.af.hi += value + carriage;

	if (self.af.hi == 0) {
		self.setFlag(Z);
	} else {
		self.unsetFlag(Z);
	}

	self.required_cycles = 2;
}

fn void Cpu.adc_a_n8(&self, char value) {
	char carriage = self.getFlag(C);

	if (check_bit3_overflow(self.af.hi, value + carriage)) {
		self.setFlag(H);
	}
	if (check_bit7_overflow(self.af.hi, value + carriage)) {
		self.setFlag(C);
	}

	self.af.hi += value + carriage;

	if (self.af.hi == 0) {
		self.setFlag(Z);
	} else {
		self.unsetFlag(Z);
	}

	self.required_cycles = 2;
}

// Addition without carriage

fn void Cpu.add_a_n8(&self, char value) {
	if (check_bit3_overflow(self.af.hi, value)) {
		self.setFlag(H);
	}
	if (check_bit7_overflow(self.af.hi, value)) {
		self.setFlag(C);
	}

	self.af.hi += value;

	if (self.af.hi == 0) {
		self.setFlag(Z);
	} else {
		self.unsetFlag(Z);
	}

	self.required_cycles = 2;
}

fn void Cpu.add_a_r8(&self, char *reg) {
	if (check_bit3_overflow(self.af.hi, *reg)) {
		self.setFlag(H);
	}
	if (check_bit7_overflow(self.af.hi, *reg)) {
		self.setFlag(C);
	}

	self.af.hi += *reg;

	if (self.af.hi == 0) {
		self.setFlag(Z);
	} else {
		self.unsetFlag(Z);
	}

	self.required_cycles = 2;
}

fn void Cpu.add_a_hl(&self, mmu::Mmu *mmu, HiLoReg *reg) {
	char value = mmu.get(reg.reg);

	if (check_bit3_overflow(self.af.hi, value)) {
		self.setFlag(H);
	}
	if (check_bit7_overflow(self.af.hi, value)) {
		self.setFlag(C);
	}

	self.af.hi += value;

	if (self.af.hi == 0) {
		self.setFlag(Z);
	} else {
		self.unsetFlag(Z);
	}

	self.required_cycles = 2;
}