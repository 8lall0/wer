module cpu;

import mmu;

/*
PC convention: the fetch/decode loop advances `self.pc` past the whole
instruction (opcode + operands) *before* the handler runs. So on entry to a
jump/call handler `self.pc` already points at the next sequential instruction,
which is exactly the address to push for CALL/RST and to offset for JR.

Conditional control-flow instructions cost more cycles when the branch is
taken; each handler sets `required_cycles` accordingly.
*/

fn void Cpu.call_n16(&self, mmu::Mmu *mmu, ushort address) {
	self.idle(mmu);
	self.push16(mmu, self.pc);
	self.pc = address;

	self.required_cycles = 6;
}

fn void Cpu.call_cc_n16(&self, mmu::Mmu *mmu, bool condition, ushort address) {
	if (condition) {
		self.call_n16(mmu, address); // sets required_cycles = 6
		return;
	}
	self.required_cycles = 3;
}

fn void Cpu.jp_hl(&self) {
	self.pc = self.hl.reg;

	self.required_cycles = 1;
}

fn void Cpu.jp_n16(&self, mmu::Mmu *mmu, ushort address) {
	self.idle(mmu);
	self.pc = address;

	self.required_cycles = 4;
}

fn void Cpu.jp_cc_n16(&self, mmu::Mmu *mmu, bool condition, ushort address) {
	if (condition) {
		self.idle(mmu);
		self.pc = address;
		self.required_cycles = 4;
		return;
	}
	self.required_cycles = 3;
}

fn void Cpu.jr_n16(&self, mmu::Mmu *mmu, ichar e8) {
	self.idle(mmu);
	self.pc = (ushort)((int)self.pc + (int)e8);

	self.required_cycles = 3;
}

fn void Cpu.jr_cc_n16(&self, mmu::Mmu *mmu, bool condition, ichar e8) {
	if (condition) {
		self.idle(mmu);
		self.pc = (ushort)((int)self.pc + (int)e8);
		self.required_cycles = 3;
		return;
	}
	self.required_cycles = 2;
}

fn void Cpu.ret(&self, mmu::Mmu *mmu) {
	self.pc = self.pop16(mmu);
	self.idle(mmu);

	self.required_cycles = 4;
}

fn void Cpu.ret_cc(&self, mmu::Mmu *mmu, bool condition) {
	self.idle(mmu);
	if (condition) {
		self.pc = self.pop16(mmu);
		self.idle(mmu);
		self.required_cycles = 5;
		return;
	}
	self.required_cycles = 2;
}

fn void Cpu.reti(&self, mmu::Mmu *mmu) {
	self.pc = self.pop16(mmu);
	self.idle(mmu);
	self.ime = true;

	self.required_cycles = 4;
}

// RST: call one of the fixed vectors ($00, $08, $10, ... $38).
fn void Cpu.rst_vec(&self, mmu::Mmu *mmu, char vec) {
	self.idle(mmu);
	self.push16(mmu, self.pc);
	self.pc = vec;

	self.required_cycles = 4;
}
