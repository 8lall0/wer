module cpu;

import mmu, std::io;

fn bool check_bit3_overflow(char a, char b) {
	char low_a = a & 0x0F;
	char low_b = b & 0x0F;

	return (low_a + low_b) > 0x0F;
}

fn bool check_bit7_overflow(char a, char b) {
	char low_a = a & 0x0F;
	char low_b = b & 0x0F;

	return (low_a + low_b) > 0x0F;
}

fn bool check_bit11_overflow(ushort a, ushort b) {
	ushort low_a = a & 0x0FFF;
	ushort low_b = b & 0x0FFF;

	return (low_a + low_b) > 0x0FFF;
}

fn bool check_bit15_overflow(ushort a, ushort b) {
	ushort sum = a + b;

	return sum < a;
}

alias Flag = char;

const Flag C = 3;
const Flag H = 4;
const Flag N = 5;
const Flag Z = 6;

/*
AF	A	-	Accumulator & Flags
BC	B	C	BC
DE	D	E	DE
HL	H	L	HL
SP	-	-	Stack Pointer
PC	-	-	Program Counter/Pointer

lower af:
7	z	Zero flag
6	n	Subtraction flag (BCD)
5	h	Half Carry flag (BCD)
4	c	Carry flag
*/

union HiLoReg {
	struct {
		char hi;
		char lo;
	}
	ushort reg;
}

struct Cpu {
	HiLoReg af;
	HiLoReg bc;
	HiLoReg de;
	HiLoReg hl;

	ushort sp;
	ushort pc;

	ulong clk;
	char required_cycles;

	bool ime;
}

fn Cpu init() {
	return (Cpu) {
		.af.reg = 0x01B0,
		.bc.reg = 0x0013,
		.de.reg = (ushort)0x00D8,
		.hl.reg = (ushort)0x014D,
		.sp = (ushort)0xFFFE,
		.pc = (ushort)0x0100,
	};
}

fn void Cpu.resetFlag(&self) {
	self.af.lo = 0;
}

fn void Cpu.setFlag(&self, Flag flag) {
	self.af.lo |= 1 << flag;
}

fn void Cpu.unsetFlag(&self, Flag flag) {
	self.af.lo &= ~(1 << flag);
}

fn char Cpu.getFlag(&self, Flag flag) {
	return self.af.lo &= 1 << flag;
}

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
	}

	self.required_cycles = 2;
}

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
	}

	self.required_cycles = 2;
}



fn void Cpu.add_hl_sp(&self) {
	if (check_bit15_overflow(self.af.hi, self.sp)) {
		self.setFlag(H);
	}
	if (check_bit11_overflow(self.af.hi, self.sp)) {
		self.setFlag(C);
	}

	self.hl.reg += self.sp;

	self.required_cycles = 2;
}

fn void Cpu.add_sp_e8(&self, short value) {
	// TODO: change those, we need to handle signed
	self.af.flag.h = check_bit15_overflow(self.hl.reg, self.sp);
	self.af.flag.c = check_bit11_overflow(self.hl.reg, self.sp);

	self.sp += (ushort)value;

	self.required_cycles = 4;
}

fn void Cpu.and_a_r8(&self, char *reg) {
	self.setFlag(H);
	self.af.hi &= *reg;
	if (self.af.hi == 0) {
		self.setFlag(Z);
	}

	self.required_cycles = 2;
}

fn void Cpu.call_n16(&self) {

}

fn void Cpu.call_cc_n16(&self) {

}

fn void Cpu.a_r8(&self, char *reg) {
	char res = self.af.hi - *reg;

	if (self.af.hi == 0) {
		self.setFlag(Z);
	}
	self.unsetFlag(C);
	self.unsetFlag(N);
	self.setFlag(H);
}

fn void Cpu.and_a_n8(&self, char value) {
	self.setFlag(H);
	self.af.hi &= value;

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

fn void? Cpu.ld_r8_r8(&self, HiLoReg *reg) {
	reg.lo = reg.hi;
	self.required_cycles = 1;
}

fn void? Cpu.ld_r8_n8(&self, char *reg, char value) {
	*reg = value;
	self.required_cycles = 2;
}

fn void? Cpu.ld_r16_n16(&self, HiLoReg *reg, ushort value) {
	reg.reg = value;
	self.required_cycles = 3;
}

fn void Cpu.xor_a_n8(&self, char value) {
	self.af.hi ^= value;
}