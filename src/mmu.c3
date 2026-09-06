module mmu;

struct Mmu {
	char[65536] ram;
}

fn char Mmu.get(&self, char address) {
	return self.ram[address];
}

fn void Mmu.set(&self, char address, char value) {
	self.ram[address] = value;
}