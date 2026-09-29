module cpu;

import mmu;

// ---------------------------------------------------------------------------
// 16-bit stack helpers (GB pushes the high byte first, at the lower address
// after both decrements, so memory ends up little-endian).
// ---------------------------------------------------------------------------
fn void Cpu.push16(&self, mmu::Mmu *mmu, ushort value) {
	self.sp--;
	self.write(mmu, self.sp, (char)(value >> 8));
	self.sp--;
	self.write(mmu, self.sp, (char)(value & 0xFF));
}

fn ushort Cpu.pop16(&self, mmu::Mmu *mmu) {
	char lo = self.read(mmu, self.sp);
	self.sp++;
	char hi = self.read(mmu, self.sp);
	self.sp++;
	return (ushort)((hi << 8) | lo);
}

// ADD HL,SP : HL = HL + SP. N=0, H = carry from bit 11, C = carry from bit 15.
fn void Cpu.add_hl_sp(&self, mmu::Mmu *mmu) {
	self.idle(mmu);
	self.unsetFlag(N);
	self.assignFlag(H, check_bit11_overflow(self.hl.reg, self.sp));
	self.assignFlag(C, check_bit15_overflow(self.hl.reg, self.sp));

	self.hl.reg += self.sp;
}

// ADD SP,e8 : SP = SP + (signed) e8. Z=0, N=0, H and C come from the
// unsigned low nibble/byte of e8.
fn void Cpu.add_sp_e8(&self, mmu::Mmu *mmu, ichar e8) {
	self.idle(mmu);
	self.idle(mmu);
	self.unsetFlag(Z);
	self.unsetFlag(N);
	self.assignFlag(H, check_bit3_signed_overflow(self.sp, e8));
	self.assignFlag(C, check_bit7_signed_overflow(self.sp, e8));

	self.sp = (ushort)((int)self.sp + (int)e8);
}

// LD HL,SP+e8 : HL = SP + (signed) e8, SP unchanged. Flags identical to
// ADD SP,e8 (Z=0, N=0, H/C from the unsigned low nibble/byte of e8).
fn void Cpu.ld_hl_sp_e8(&self, mmu::Mmu *mmu, ichar e8) {
	self.idle(mmu);
	self.unsetFlag(Z);
	self.unsetFlag(N);
	self.assignFlag(H, check_bit3_signed_overflow(self.sp, e8));
	self.assignFlag(C, check_bit7_signed_overflow(self.sp, e8));

	self.hl.reg = (ushort)((int)self.sp + (int)e8);
}

fn void Cpu.dec_sp(&self, mmu::Mmu *mmu) {
	self.idle(mmu);
	self.sp--;
}

fn void Cpu.inc_sp(&self, mmu::Mmu *mmu) {
	self.idle(mmu);
	self.sp++;
}

fn void Cpu.ld_sp_n16(&self, ushort value) {
	self.sp = value;
}

fn void Cpu.ld_n16_sp(&self, mmu::Mmu *mmu, ushort address) {
	self.write(mmu, address, (char)(self.sp & 0xFF));
	self.write(mmu, address + 1, (char)(self.sp >> 8));
}

fn void Cpu.ld_sp_hl(&self, mmu::Mmu *mmu) {
	self.idle(mmu);
	self.sp = self.hl.reg;
}

// POP AF : the low nibble of F is always zero on hardware.
fn void Cpu.pop_af(&self, mmu::Mmu *mmu) {
	self.af.lo = self.read(mmu, self.sp) & 0xF0;
	self.sp++;
	self.af.hi = self.read(mmu, self.sp);
	self.sp++;
}

fn void Cpu.pop_r16(&self, mmu::Mmu *mmu, HiLoReg *reg) {
	reg.lo = self.read(mmu, self.sp);
	self.sp++;
	reg.hi = self.read(mmu, self.sp);
	self.sp++;
}

fn void Cpu.push_af(&self, mmu::Mmu *mmu) {
	self.idle(mmu);
	self.sp--;
	self.write(mmu, self.sp, self.af.hi);
	self.sp--;
	self.write(mmu, self.sp, self.af.lo);
}

fn void Cpu.push_r16(&self, mmu::Mmu *mmu, HiLoReg *reg) {
	self.idle(mmu);
	self.sp--;
	self.write(mmu, self.sp, reg.hi);
	self.sp--;
	self.write(mmu, self.sp, reg.lo);
}
