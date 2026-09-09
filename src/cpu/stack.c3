module cpu;

import mmu;

// TODO: check overflow!
fn void Cpu.add_hl_sp(&self) {
	self.unsetFlag(N);
	if (check_bit15_overflow(self.hl.reg, self.sp)) {
		self.setFlag(H);
	}
	if (check_bit11_overflow(self.hl.reg, self.sp)) {
		self.setFlag(C);
	}

	self.hl.reg += self.sp;

	self.required_cycles = 2;
}

fn void Cpu.add_sp_e8(&self, ichar e8) {
	self.unsetFlag(Z);
	self.unsetFlag(N);

	if (check_bit3_signed_overflow(self.sp, e8)) {
		self.setFlag(H);
	} else {
		self.unsetFlag(H);
	}

	if (check_bit7_signed_overflow(self.sp, e8)) {
		self.setFlag(C);
	} else {
		self.unsetFlag(C);
	}

	int sum = (int)self.sp + (int)e8;

	self.sp = (ushort)sum;

	self.required_cycles = 4;
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
	mmu.set(address+1, (char)(self.sp >> 8));

	self.required_cycles = 5;
}

fn void Cpu.ld_sp_hl(&self) {
	self.sp = self.hl.reg;

	self.required_cycles = 2;
}

fn void Cpu.pop_af(&self, mmu::Mmu *mmu) {
	self.af.lo = mmu.get(self.sp);
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