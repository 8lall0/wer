module cpu;

// DI : disable interrupts immediately.
fn void Cpu.di(&self) {
	self.ime = false;

	self.required_cycles = 1;
}

// EI : enable interrupts. NOTE: on hardware the effect is delayed by one
// instruction (IME is set after the instruction *following* EI). That timing
// is not modelled yet.
fn void Cpu.ei(&self) {
	self.ime = true;

	self.required_cycles = 1;
}

// TODO: HALT (and the "halt bug" when IME=0 with a pending interrupt).
fn void Cpu.halt(&self) {
	self.required_cycles = 1;
}
