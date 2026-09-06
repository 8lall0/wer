module cpu;

import mmu;

fn bool check_bit3_overflow(char a, char b) {
	// Isolate the lower 4 bits (0 to 3) of both bytes
	char low_a = a & 0x0F;
	char low_b = b & 0x0F;

	// If their sum is greater than 15, it required a 5th bit (bit 4)
	return (low_a + low_b) > 0x0F;
}

fn bool check_bit7_overflow(char a, char b) {
	// Isolate the lower 4 bits (0 to 3) of both bytes
	char low_a = a & 0x0F;
	char low_b = b & 0x0F;

	// If their sum is greater than 15, it required a 5th bit (bit 4)
	return (low_a + low_b) > 0x0F;
}

fn bool check_bit11_overflow(ushort a, ushort b) {
	// Isola i bit da 0 a 11 (0x0FFF copre i primi 12 bit)
	ushort low_a = a & 0x0FFF;
	ushort low_b = b & 0x0FFF;

	// Se la loro somma supera 4095 (0x0FFF), c'è un carry out dal bit 11
	return (low_a + low_b) > 0x0FFF;
}

fn bool check_bit15_overflow(ushort a, ushort b) {
	ushort sum = a + b;
	// Se la somma "gira intorno" ed è più piccola di uno dei numeri di partenza,
	// significa che il bit 15 ha fatto overflow.
	return sum < a;
}

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
	HiLoReg af;
	HiLoReg bc;
	HiLoReg de;
	HiLoReg hl;

	ushort sp;
	ushort pc;

	ulong clk;
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

	self.af.flag.h = check_bit3_overflow(self.af.hi, *reg + carriage);
	self.af.flag.c = check_bit7_overflow(self.af.hi, *reg + carriage);

	self.af.hi += *reg + carriage;

	self.af.flag.z = self.af.hi != 0;
	self.af.flag.n = false;

	self.required_cycles = 2;
}

fn void Cpu.add_a_r8(&self, char *reg) {
	self.af.flag.h = check_bit3_overflow(self.af.hi, *reg);
	self.af.flag.c = check_bit7_overflow(self.af.hi, *reg);

	self.af.hi += *reg;

	self.af.flag.z = self.af.hi != 0;
	self.af.flag.n = false;

	self.required_cycles = 2;
}

fn void Cpu.adc_a_hl(&self, mmu::Mmu *mmu, HiLoReg *reg) {
	char carriage = (char)self.af.flag.c;
	char value = mmu.get(reg.reg);

	self.af.flag.h = check_bit3_overflow(self.af.hi, value + carriage);
	self.af.flag.c = check_bit7_overflow(self.af.hi, value + carriage);

	self.af.hi += value + carriage;

	self.af.flag.z = self.af.hi != 0;
	self.af.flag.n = false;

	self.required_cycles = 2;
}

fn void Cpu.add_a_hl(&self, mmu::Mmu *mmu, HiLoReg *reg) {
	char value = mmu.get(reg.reg);

	self.af.flag.h = check_bit3_overflow(self.af.hi, value);
	self.af.flag.c = check_bit7_overflow(self.af.hi, value);

	self.af.hi += value;

	self.af.flag.z = self.af.hi != 0;
	self.af.flag.n = false;

	self.required_cycles = 2;
}

fn void Cpu.adc_a_n8(&self, char value) {
	char carriage = (char)self.af.flag.c;

	self.af.flag.h = check_bit3_overflow(self.af.hi, value + carriage);
	self.af.flag.c = check_bit7_overflow(self.af.hi, value + carriage);

	self.af.hi += value + carriage;

	self.af.flag.z = self.af.hi != 0;
	self.af.flag.n = false;

	self.required_cycles = 2;
}

fn void Cpu.add_a_n8(&self, char value) {
	self.af.flag.h = check_bit3_overflow(self.af.hi, value);
	self.af.flag.c = check_bit7_overflow(self.af.hi, value);

	self.af.hi += value;

	self.af.flag.z = self.af.hi != 0;
	self.af.flag.n = false;

	self.required_cycles = 2;
}

fn void Cpu.add_hl_r16(&self, HiLoReg *reg) {
	self.af.flag.h = check_bit15_overflow(self.hl.reg, reg.reg);;
	self.af.flag.c = check_bit11_overflow(self.hl.reg, reg.reg);
	self.af.flag.n = false;
	self.hl.reg += reg.reg;

	self.required_cycles = 2;
}

fn void Cpu.add_hl_sp(&self) {
	self.af.flag.h = check_bit15_overflow(self.hl.reg, self.sp);
	self.af.flag.c = check_bit11_overflow(self.hl.reg, self.sp);
	self.af.flag.n = false;
	self.hl.reg += self.sp;

	self.required_cycles = 2;
}

fn void Cpu.add_sp_e8(&self, short value) {
	self.af.flag.z = false;
	self.af.flag.n = false;
	// TODO: change those, we need to handle signed
	self.af.flag.h = check_bit15_overflow(self.hl.reg, self.sp);;
	self.af.flag.c = check_bit11_overflow(self.hl.reg, self.sp);

	self.sp += (ushort)value;
	self.required_cycles = 4;
}

fn void Cpu.and_a_r8(&self, char *reg) {
	self.af.flag.h = true;
	self.af.flag.n = false;
	self.af.flag.c = false;
	self.af.hi &= *reg;
	self.af.flag.z = self.af.hi == 0;

	self.required_cycles = 2;
}

fn void Cpu.and_a_n8(&self, char value) {
	self.af.flag.h = true;
	self.af.flag.n = false;
	self.af.flag.c = false;
	self.af.hi &= value;
	self.af.flag.z = self.af.hi == 0;

	self.required_cycles = 2;
}

fn void Cpu.and_a_hl(&self, mmu::Mmu *mmu) {
	self.af.flag.h = true;
	self.af.flag.n = false;
	self.af.flag.c = false;
	self.af.hi &= mmu.get(self.hl.reg);
	self.af.flag.z = self.af.hi == 0;

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