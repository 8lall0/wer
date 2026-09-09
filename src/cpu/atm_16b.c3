module cpu;

// ADD HL,r16 : HL = HL + r16. Flags: N=0, H = carry from bit 11,
// C = carry from bit 15. Z is not affected.
fn void Cpu.add_hl_r16(&self, HiLoReg *reg) {
	self.unsetFlag(N);
	self.assignFlag(H, check_bit11_overflow(self.hl.reg, reg.reg));
	self.assignFlag(C, check_bit15_overflow(self.hl.reg, reg.reg));

	self.hl.reg += reg.reg;

	self.required_cycles = 2;
}

// INC/DEC r16 do not affect any flags.
fn void Cpu.dec_r16(&self, HiLoReg *reg) {
	reg.reg -= 1;

	self.required_cycles = 2;
}

fn void Cpu.inc_r16(&self, HiLoReg *reg) {
	reg.reg += 1;

	self.required_cycles = 2;
}
