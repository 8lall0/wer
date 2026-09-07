module cpu;

/*
HALT
*/

fn void Cpu.di(&self) {
	self.ime = false;

	self.required_cycles = 1;
}

fn void Cpu.ei(&self) {
	self.ime = true;

	self.required_cycles = 1;
}

fn void Cpu.halt(&self) {

}