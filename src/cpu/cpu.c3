module cpu;

import mmu;
import std::core::env;

// The HiLoReg union below aliases two `char` fields over a `ushort` and relies
// on the host byte order to place `hi`/`lo` correctly. Only little-endian hosts
// are supported; fail the build loudly anywhere else.
$assert !env::BIG_ENDIAN : "wer assumes a little-endian host (see HiLoReg).";

// ---------------------------------------------------------------------------
// Flag helpers
// ---------------------------------------------------------------------------

// Half-carry out of bit 3 for an 8-bit addition `a + b + carry`.
fn bool check_bit3_overflow(char a, char b, char carry) {
	return ((a & 0x0F) + (b & 0x0F) + (carry & 0x0F)) > 0x0F;
}

// Carry out of bit 7 for an 8-bit addition `a + b + carry`.
fn bool check_bit7_overflow(char a, char b, char carry) {
	return ((uint)a + (uint)b + (uint)carry) > 0xFF;
}

// Half-borrow out of bit 4 for an 8-bit subtraction `a - b - carry`.
fn bool check_bit3_borrow(char a, char b, char carry) {
	return ((int)(a & 0x0F) - (int)(b & 0x0F) - (int)(carry & 0x0F)) < 0;
}

// Borrow out of bit 8 for an 8-bit subtraction `a - b - carry`.
fn bool check_bit7_borrow(char a, char b, char carry) {
	return ((int)a - (int)b - (int)carry) < 0;
}

// Half-carry out of bit 11 for a 16-bit addition `a + b`.
fn bool check_bit11_overflow(ushort a, ushort b) {
	return ((a & 0x0FFF) + (b & 0x0FFF)) > 0x0FFF;
}

// Carry out of bit 15 for a 16-bit addition `a + b`.
fn bool check_bit15_overflow(ushort a, ushort b) {
	return ((uint)a + (uint)b) > 0xFFFF;
}

// ADD SP,e8 / LD HL,SP+e8 compute H and C from the *unsigned* low nibble/byte
// of the (signed) offset added to SP.
fn bool check_bit3_signed_overflow(ushort sp, ichar e8) {
	return ((sp & 0x0F) + ((char)e8 & 0x0F)) > 0x0F;
}

fn bool check_bit7_signed_overflow(ushort sp, ichar e8) {
	return ((sp & 0xFF) + ((char)e8 & 0xFF)) > 0xFF;
}

// ---------------------------------------------------------------------------
// Registers
// ---------------------------------------------------------------------------

alias Flag = char;

// Bit positions inside the F register.
const Flag C = 4; // Carry
const Flag H = 5; // Half carry (BCD)
const Flag N = 6; // Subtraction (BCD)
const Flag Z = 7; // Zero

// Interrupt-related I/O registers, and the mask of the 5 real interrupt lines
// (VBlank, LCD STAT, Timer, Serial, Joypad).
const ushort IE_ADDR = 0xFFFF; // Interrupt Enable
const ushort IF_ADDR = 0xFF0F; // Interrupt Flag (pending)
const ushort DIV_ADDR = 0xFF04; // Divider register (reset by STOP)
const char INT_MASK = 0x1F;

// Little-endian host only: the first field is the low byte.
union HiLoReg {
	struct {
		char lo;
		char hi;
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

	// HALT: CPU is idle until an interrupt is pending.
	bool halted;
	// STOP: CPU (and on DMG the whole system) is idle until a button is pressed.
	bool stopped;
	// HALT bug: the next opcode fetch must not advance PC (it is read twice).
	bool halt_bug;
	// EI is delayed by one instruction. Counts down at the end of each step;
	// IME is set when it reaches 0. DI resets it to 0.
	char ime_delay;
}

// Post-boot DMG register state (boot ROM skipped).
fn Cpu init() {
	return (Cpu) {
		.af.reg = 0x01B0,
		.bc.reg = 0x0013,
		.de.reg = 0x00D8,
		.hl.reg = 0x014D,
		.sp = 0xFFFE,
		.pc = 0x0100,
	};
}

// ---------------------------------------------------------------------------
// Flag access (flags live in F, the low byte of AF)
// ---------------------------------------------------------------------------

fn void Cpu.resetFlag(&self) {
	self.af.lo = 0;
}

fn void Cpu.setFlag(&self, Flag flag) {
	self.af.lo |= (char)(1 << flag);
}

fn void Cpu.unsetFlag(&self, Flag flag) {
	self.af.lo &= (char)~(1 << flag);
}

// Returns 0 or 1. Does not mutate F.
fn char Cpu.getFlag(&self, Flag flag) {
	return (self.af.lo >> flag) & 1;
}

fn void Cpu.assignFlag(&self, Flag flag, bool value) {
	if (value) {
		self.setFlag(flag);
	} else {
		self.unsetFlag(flag);
	}
}

// Z is set if `value` is zero.
fn void Cpu.updateZero(&self, char value) {
	self.assignFlag(Z, value == 0);
}
