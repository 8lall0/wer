module cpu;

fn void Cpu.add_hl_r16(&self, HiLoReg *reg) {
	if (check_bit15_overflow(self.af.hi, reg.reg)) {
		self.setFlag(H);
	}
	if (check_bit11_overflow(self.af.hi, reg.reg)) {
		self.setFlag(C);
	}

	self.hl.reg += reg.reg;

	self.required_cycles = 2;
}

fn void Cpu.dec_r16(&self, HiLoReg *reg) {
	reg.reg -= 1;

	self.required_cycles = 2;
}

fn void Cpu.inc_r16(&self, HiLoReg *reg) {
	reg.reg += 1;

	self.required_cycles = 2;
}