module cpu;

import mmu;

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

fn bool check_bit3_signed_overflow(ushort a, ichar b) {
	int mask = 0x7;
	int carry = ((a & mask) + (b & mask)) >> 3;

	return carry != 0;
}

fn bool check_bit7_signed_overflow(ushort a, ichar b) {
	int mask = 0x7;
	int carry = ((a & mask) + (b & mask)) >> 7;

	return carry != 0;
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

// TODO: check how to operate with unsigned and signed
fn bool check_bit11_signed_overflow(ushort a, short b) {
	int mask = (1 << 11) - 1; // 0x7FF

	int carry = ((a & mask) + (b & mask)) >> 11;

	return carry != 0;
}

fn bool check_bit15_signed_overflow(ushort a, short b) {
	int mask = 0x7FFF;

	int carry = ((a & mask) + (b & mask)) >> 15;

	return carry != 0;
}

alias Flag = char;

const Flag C = 4;
const Flag H = 5;
const Flag N = 6;
const Flag Z = 7;

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