module cpu;

/*
ADD SP,e8
DEC SP
INC SP
LD SP,n16
LD [n16],SP
LD HL,SP+e8
LD SP,HL
POP AF
POP r16
PUSH AF
PUSH r16
*/

// TODO: check overflow!
fn void Cpu.add_hl_sp(&self) {
	cpu.unsetFlag(N);
	if (check_bit15_overflow(self.hl, self.sp)) {
		self.setFlag(H);
	}
	if (check_bit11_overflow(self.hl, self.sp)) {
		self.setFlag(C);
	}

	self.hl += self.sp;

	self.required_cycles = 2;
}