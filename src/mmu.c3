module mmu;

struct Mmu {
	char[65536] ram;
}

fn char Mmu.get(&self, ushort address) {
	return self.ram[address];
}

fn void Mmu.set(&self, ushort address, char value) {
	self.ram[address] = value;
}