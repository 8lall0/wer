module cpu;

import mmu;

// ---------------------------------------------------------------------------
// Operand fetch. After an instruction is fully fetched, `pc` points at the
// next instruction — the convention the jump/call/ret handlers assume.
// ---------------------------------------------------------------------------

fn char Cpu.fetch8(&self, mmu::Mmu *mmu) {
	char v = mmu.get(self.pc);
	self.pc++;
	return v;
}

fn ushort Cpu.fetch16(&self, mmu::Mmu *mmu) {
	char lo = self.fetch8(mmu);
	char hi = self.fetch8(mmu);
	return (ushort)((hi << 8) | lo);
}

// ---------------------------------------------------------------------------
// Field decoding. Opcodes encode registers/conditions in fixed bit fields:
//   r8  (3 bits): B C D E H L (HL) A          -> index 6 means memory at HL
//   r16 (2 bits): BC DE HL SP  (or ..AF for push/pop)
//   cc  (2 bits): NZ Z NC C
// ---------------------------------------------------------------------------

// Pointer to the register selected by a 3-bit r8 field. Returns null for the
// (HL) slot (index 6) — use read_r8 / write_r8 for a uniform accessor.
fn char* Cpu.r8_ptr(&self, char code) {
	switch (code & 7) {
		case 0: return &self.bc.hi;
		case 1: return &self.bc.lo;
		case 2: return &self.de.hi;
		case 3: return &self.de.lo;
		case 4: return &self.hl.hi;
		case 5: return &self.hl.lo;
		case 7: return &self.af.hi;
		default: return null; // 6 == (HL)
	}
}

fn bool Cpu.r8_is_mem(&self, char code) {
	return (code & 7) == 6;
}

fn char Cpu.read_r8(&self, mmu::Mmu *mmu, char code) {
	if (self.r8_is_mem(code)) return mmu.get(self.hl.reg);
	return *self.r8_ptr(code);
}

fn void Cpu.write_r8(&self, mmu::Mmu *mmu, char code, char value) {
	if (self.r8_is_mem(code)) {
		mmu.set(self.hl.reg, value);
		return;
	}
	*self.r8_ptr(code) = value;
}

// BC / DE / HL for a 2-bit r16 field; null for 3 (which means SP in most
// opcodes and AF in push/pop — callers special-case those).
fn HiLoReg* Cpu.r16_ptr(&self, char code) {
	switch (code & 3) {
		case 0: return &self.bc;
		case 1: return &self.de;
		case 2: return &self.hl;
		default: return null;
	}
}

fn bool Cpu.cond(&self, char code) {
	switch (code & 3) {
		case 0: return self.getFlag(Z) == 0; // NZ
		case 1: return self.getFlag(Z) == 1; // Z
		case 2: return self.getFlag(C) == 0; // NC
		default: return self.getFlag(C) == 1; // C
	}
}
