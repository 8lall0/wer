module cpu;

// CCF : flip the carry flag. N=0, H=0.
fn void Cpu.ccf(&self) {
	self.assignFlag(C, self.getFlag(C) == 0);
	self.unsetFlag(N);
	self.unsetFlag(H);

	self.required_cycles = 1;
}

// SCF : set the carry flag. N=0, H=0.
fn void Cpu.scf(&self) {
	self.setFlag(C);
	self.unsetFlag(N);
	self.unsetFlag(H);

	self.required_cycles = 1;
}
