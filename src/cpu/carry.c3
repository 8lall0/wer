module cpu;

fn void Cpu.ccf(&self) {
	if (self.getFlag(C) == 0) {
		self.setFlag(C);
	} else {
		self.unsetFlag(C);
	}
	self.unsetFlag(N);
	self.unsetFlag(H);

	self.required_cycles = 1;
}

fn void Cpu.scf(&self) {
	self.setFlag(C);
	self.unsetFlag(N);
	self.unsetFlag(H);

	self.required_cycles = 1;
}
