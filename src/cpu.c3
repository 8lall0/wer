module cpu;

import mmu;

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

struct FlagRegister {
	bool[3] padding;
	bool c;
	bool h;
	bool n;
	bool z;
}

union HiLoReg {
	struct {
		char hi;
		union {
			FlagRegister flag;
			char lo;
		}
	}
	ushort reg;
}

struct Cpu {
	ulong clk;

	HiLoReg af;
	HiLoReg bc;
	HiLoReg de;
	HiLoReg hl;

	ushort sp;
	ushort pc;

	char required_cycles;
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

fn void Cpu.nop(&self) {
	self.required_cycles++;
}

fn void Cpu.adc_a_r8(&self, char *reg) {
	char carriage = (char)self.af.flag.c;
	bool overflow = (self.af.hi + *reg + carriage < self.af.hi);
	self.af.hi += *reg + carriage;

	if (self.af.hi == 0) {
		self.af.flag.z = 0;
	}

	self.af.flag.n = 0;
	self.af.flag.c = overflow;
	// Set if overflow from bit 3.
	self.af.flag.h = overflow;
	self.required_cycles = 2;
}

fn void Cpu.adc_a_hl(&self, mmu::Mmu *mmu, HiLoReg *reg) {
	char carriage = (char)self.af.flag.c;
	char value = mmu.get(reg.reg);
	bool overflow = (self.af.hi + *reg + carriage < self.af.hi);
	self.af.hi += *reg + carriage;

	if (self.af.hi == 0) {
		self.af.flag.z = 0;
	}

	self.af.flag.n = 0;
	self.af.flag.c = overflow;
	// Set if overflow from bit 3.
	self.af.flag.h = overflow;
	self.required_cycles = 2;
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