module cpu;

import mmu;

// ---------------------------------------------------------------------------
// 16-bit stack helpers (GB pushes the high byte first, at the lower address
// after both decrements, so memory ends up little-endian).
// ---------------------------------------------------------------------------
fn void Cpu.push16(&self, mmu::Mmu *mmu, ushort value) {
	self.sp--;
	mmu.set(self.sp, (char)(value >> 8));
	self.sp--;
	mmu.set(self.sp, (char)(value & 0xFF));
}

fn ushort Cpu.pop16(&self, mmu::Mmu *mmu) {
	char lo = mmu.get(self.sp);
	self.sp++;
	char hi = mmu.get(self.sp);
	self.sp++;
	return (ushort)((hi << 8) | lo);
}

// ADD HL,SP : HL = HL + SP. N=0, H = carry from bit 11, C = carry from bit 15.
fn void Cpu.add_hl_sp(&self) {
	self.unsetFlag(N);
	self.assignFlag(H, check_bit11_overflow(self.hl.reg, self.sp));
	self.assignFlag(C, check_bit15_overflow(self.hl.reg, self.sp));

	self.hl.reg += self.sp;

	self.required_cycles = 2;
}

// ADD SP,e8 : SP = SP + (signed) e8. Z=0, N=0, H and C come from the
// unsigned low nibble/byte of e8.
fn void Cpu.add_sp_e8(&self, ichar e8) {
	self.unsetFlag(Z);
	self.unsetFlag(N);
	self.assignFlag(H, check_bit3_signed_overflow(self.sp, e8));
	self.assignFlag(C, check_bit7_signed_overflow(self.sp, e8));

	self.sp = (ushort)((int)self.sp + (int)e8);

	self.required_cycles = 4;
}

// LD HL,SP+e8 : HL = SP + (signed) e8, SP unchanged. Flags identical to
// ADD SP,e8 (Z=0, N=0, H/C from the unsigned low nibble/byte of e8).
fn void Cpu.ld_hl_sp_e8(&self, ichar e8) {
	self.unsetFlag(Z);
	self.unsetFlag(N);
	self.assignFlag(H, check_bit3_signed_overflow(self.sp, e8));
	self.assignFlag(C, check_bit7_signed_overflow(self.sp, e8));

	self.hl.reg = (ushort)((int)self.sp + (int)e8);

	self.required_cycles = 3;
}

fn void Cpu.dec_sp(&self) {
	self.sp--;

	self.required_cycles = 2;
}

fn void Cpu.inc_sp(&self) {
	self.sp++;

	self.required_cycles = 2;
}

fn void Cpu.ld_sp_n16(&self, ushort value) {
	self.sp = value;

	self.required_cycles = 3;
}

fn void Cpu.ld_n16_sp(&self, mmu::Mmu *mmu, ushort address) {
	mmu.set(address, (char)(self.sp & 0xFF));
	mmu.set(address + 1, (char)(self.sp >> 8));

	self.required_cycles = 5;
}

fn void Cpu.ld_sp_hl(&self) {
	self.sp = self.hl.reg;

	self.required_cycles = 2;
}

// POP AF : the low nibble of F is always zero on hardware.
fn void Cpu.pop_af(&self, mmu::Mmu *mmu) {
	self.af.lo = mmu.get(self.sp) & 0xF0;
	self.sp++;
	self.af.hi = mmu.get(self.sp);
	self.sp++;

	self.required_cycles = 3;
}

fn void Cpu.pop_r16(&self, mmu::Mmu *mmu, HiLoReg *reg) {
	reg.lo = mmu.get(self.sp);
	self.sp++;
	reg.hi = mmu.get(self.sp);
	self.sp++;

	self.required_cycles = 3;
}

fn void Cpu.push_af(&self, mmu::Mmu *mmu) {
	self.sp--;
	mmu.set(self.sp, self.af.hi);
	self.sp--;
	mmu.set(self.sp, self.af.lo);

	self.required_cycles = 4;
}

fn void Cpu.push_r16(&self, mmu::Mmu *mmu, HiLoReg *reg) {
	self.sp--;
	mmu.set(self.sp, reg.hi);
	self.sp--;
	mmu.set(self.sp, reg.lo);

	self.required_cycles = 4;
}
