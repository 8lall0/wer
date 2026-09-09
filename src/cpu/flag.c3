module cpu;

import mmu;

/*
BIT u3,r8   BIT u3,[HL]
RES u3,r8   RES u3,[HL]
SET u3,r8   SET u3,[HL]

u3 is the bit index (0..7) encoded in the opcode.
*/

// BIT: test bit u3 of the operand. Z = complement of the tested bit,
// N=0, H=1, C unaffected. The operand is NOT modified.
fn void Cpu.bit_u3_r8(&self, char *reg, uint u3) {
	self.updateZero((char)(*reg & (1 << u3)));
	self.unsetFlag(N);
	self.setFlag(H);

	self.required_cycles = 2;
}

fn void Cpu.bit_u3_hl(&self, mmu::Mmu *mmu, uint u3) {
	char value = mmu.get(self.hl.reg);

	self.updateZero((char)(value & (1 << u3)));
	self.unsetFlag(N);
	self.setFlag(H);

	self.required_cycles = 3;
}

// RES: clear bit u3. No flags affected.
fn void Cpu.res_u3_r8(&self, char *reg, uint u3) {
	*reg &= (char)~(1 << u3);

	self.required_cycles = 2;
}

fn void Cpu.res_u3_hl(&self, mmu::Mmu *mmu, uint u3) {
	char value = mmu.get(self.hl.reg);
	value &= (char)~(1 << u3);
	mmu.set(self.hl.reg, value);

	self.required_cycles = 4;
}

// SET: set bit u3. No flags affected.
fn void Cpu.set_u3_r8(&self, char *reg, uint u3) {
	*reg |= (char)(1 << u3);

	self.required_cycles = 2;
}

fn void Cpu.set_u3_hl(&self, mmu::Mmu *mmu, uint u3) {
	char value = mmu.get(self.hl.reg);
	value |= (char)(1 << u3);
	mmu.set(self.hl.reg, value);

	self.required_cycles = 4;
}
