module cpu;

import mmu;
import std::io;
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

const Flag C = 4; // Carry
const Flag H = 5; // Half carry (BCD)
const Flag N = 6; // Subtraction (BCD)
const Flag Z = 7; // Zero

const ushort IE_ADDR = 0xFFFF; // Interrupt Enable
const ushort IF_ADDR = 0xFF0F; // Interrupt Flag (pending)
const ushort DIV_ADDR = 0xFF04; // Divider register (reset by STOP)
const char INT_MASK = 0x1F;

// One entry of the optional bus trace (see Cpu.tracing): what the CPU did in
// one M-cycle. Used by the SingleStepTests harness to check access order.
enum BusOp : char {
	READ,
	WRITE,
	IDLE,
}

struct BusEvent {
	BusOp  op;
	ushort addr;  // unused for IDLE
	char   value;
}

const int TRACE_MAX = 8; // longest instruction is 6 M-cycles

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
	char bus_cycles; // M-cycles spent by the current step (read/write/idle calls)

	// Off by default. When set, execute_one records each M-cycle in `trace`.
	bool tracing;
	BusEvent[TRACE_MAX] trace;
	char trace_len;

	bool ime;

	// HALT: CPU is idle until an interrupt is pending.
	bool halted;
	// STOP: CPU (and on DMG the whole system) is idle until a button is pressed.
	bool stopped;
	// HALT bug: the next opcode fetch must not advance PC (it is read twice).
	bool halt_bug;
	bool just_halted; // the first M-cycle in HALT (samples interrupts like a CGB)
	bool prefetched;  // the next opcode was read already (before an HBlank DMA block): prefetch_op
	char prefetch_op;
	bool prefetch_keeps_pc; // ... by HALT: PC doesn't move on past it
	bool no_prefetch; // the HBlank DMA block due was released by a HALT wake-up: no prefetch
	bool halt_first_ran; // the M-cycle just run was HALT's first (a DMG can't wake before the next one ends)
	bool halt_dma_ran;   // the OAM DMA already had its extra M-cycle (a speed switch's STOP)
	int  speed_switch_halt; // M-cycles left of the halt after a speed switch
	// The 16-bit incrementer puts its value on the address bus in the next
	// bus cycle (DMG OAM corruption bug, see Mmu.oam_bug).
	bool   idu_on;
	ushort idu;
	// EI is delayed by one instruction. Counts down at the end of each step;
	// IME is set when it reaches 0. DI resets it to 0.
	char ime_delay;
}

// Post-boot DMG register state (boot ROM skipped): execution starts at $0100.
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

// The same after a CPU DMG 0's boot ROM (Mooneye boot_regs-dmg0).
fn Cpu init_dmg0() {
	return (Cpu) {
		.af.reg = 0x0100,
		.bc.reg = 0xFF13,
		.de.reg = 0x00C1,
		.hl.reg = 0x8403,
		.sp = 0xFFFE,
		.pc = 0x0100,
	};
}

// Post-boot register state on a Super Game Boy (Mooneye boot_regs-sgb).
fn Cpu init_sgb() {
	return (Cpu) {
		.af.reg = 0x0100,
		.bc.reg = 0x0014,
		.de.reg = 0x0000,
		.hl.reg = 0xC060,
		.sp = 0xFFFE,
		.pc = 0x0100,
	};
}

// Post-boot register state on a Game Boy Color running a CGB game (Mooneye
// boot_regs-cgb). A = $11 is how games detect a CGB.
fn Cpu init_cgb() {
	return (Cpu) {
		.af.reg = 0x1180,
		.bc.reg = 0x0000,
		.de.reg = 0xFF56,
		.hl.reg = 0x000D,
		.sp = 0xFFFE,
		.pc = 0x0100,
	};
}

// The same after the CGB boot ROM started a DMG game (compatibility mode).
fn Cpu init_cgb_dmg() {
	return (Cpu) {
		.af.reg = 0x1180,
		.bc.reg = 0x0000,
		.de.reg = 0x0008,
		.hl.reg = 0x007C,
		.sp = 0xFFFE,
		.pc = 0x0100,
	};
}

fn Cpu init_cold() {
	return (Cpu) {};
}

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

// ---------------------------------------------------------------------------
// Bus wrappers: one M-cycle each. Every CPU memory access and every internal
// cycle goes through exactly one of these, so an instruction's cost is the
// number of calls it makes. The access happens at the start of the M-cycle,
// then timer/PPU/APU advance 4 T-cycles. That order was measured on Mooneye:
// ticking before reads (or before writes) breaks a dozen timer tests.
// During OAM DMA, accesses to OAM or to the DMA's bus conflict (see mmu.c3).
// ---------------------------------------------------------------------------
fn void Cpu.record(&self, BusOp op, ushort addr, char value) @inline {
	if (!self.tracing || self.trace_len >= TRACE_MAX) return;
	self.trace[self.trace_len++] = { op, addr, value };
}

// The next bus cycle's 16-bit increment/decrement of `value`.
fn void Cpu.idu_next(&self, ushort value) @inline {
	self.idu = value;
	self.idu_on = true;
}

fn bool in_oam(ushort addr) @inline => addr >= 0xFE00 && addr <= 0xFEFF;

// This cycle's contribution to the OAM bug: a read or write of OAM and/or the
// incrementer pointing there.
fn void Cpu.oam_bug(&self, mmu::Mmu* mmu, bool read, bool write) @inline {
	bool idu = self.idu_on && in_oam(self.idu);
	self.idu_on = false;
	if (read || write || idu) mmu.oam_bug(read, write || idu);
}

// Debugging: print every IO access with the PPU's line and dot (the format of
// the instrumented Gambatte used to compare timings).
bool io_trace;

// What a read of `addr` gives now, without a bus cycle.
fn char Cpu.bus_value(&self, mmu::Mmu* mmu, ushort addr) {
	if (mmu.dma_blocks(addr)) return mmu.dma_conflict_read(addr);
	if (mmu.ppu_blocks(addr, false)) return 0xFF;
	return mmu.get(addr);
}

fn char Cpu.read(&self, mmu::Mmu* mmu, ushort addr) {
	self.bus_cycles++;
	self.oam_bug(mmu, in_oam(addr), false);
	char output;
	if (mmu.dma_blocks(addr)) {
		output = mmu.dma_conflict_read(addr);
	} else if (mmu.ppu_blocks(addr, false)) {
		output = 0xFF;
	} else {
		output = mmu.get(addr);
	}
	self.record(READ, addr, output);
	if (mmu.watch) mmu.watch.check(addr, false, output);
	if (io_trace && addr >= 0xFF00 && addr < 0xFF80) io::eprintfn("R %02X=%02X ly %d lc %d", addr & 0xFF, output, mmu.ppu.line, mmu.ppu.dot);
	mmu.tick(1);
	return output;
}

fn void Cpu.write(&self, mmu::Mmu* mmu, ushort addr, char value) {
	self.bus_cycles++;
	self.oam_bug(mmu, false, in_oam(addr));
	if (mmu.dma_blocks(addr)) {
		mmu.dma_conflict_write(addr, value);
	} else if (!mmu.ppu_blocks(addr, true)) {
		mmu.set(addr, value);
		if (addr >= 0xFE00 && addr < 0xFEA0 && mmu.ppu.oam_row0_window()) mmu.ppu.oam_row0_glitch(addr);
	}
	self.record(WRITE, addr, value);
	if (mmu.watch) mmu.watch.check(addr, true, value);
	if (io_trace && addr >= 0xFF00 && addr < 0xFF80) io::eprintfn("W %02X=%02X ly %d lc %d", addr & 0xFF, value, mmu.ppu.line, mmu.ppu.dot);
	mmu.tick(1);
}

fn void Cpu.idle(&self, mmu::Mmu* mmu) {
	self.bus_cycles++;
	self.oam_bug(mmu, false, false);
	self.record(IDLE, 0, 0);
	mmu.tick(1);
}
