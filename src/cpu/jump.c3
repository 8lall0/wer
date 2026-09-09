module cpu;

import mmu;

fn void Cpu.call_n16(&self, mmu::Mmu *mmu, ushort address) {

	ushort return_address = self.pc + 3;

	self.sp--;
	mmu.set(self.sp, (char)return_address >> 8);
	self.sp--;
	mmu.set(self.sp, (char)return_address & 0xFF);

	self.pc = address;

	self.required_cycles = 6;
}

// TODO: study how to call the condition
fn void Cpu.call_cc_n16(&self, mmu::Mmu *mmu, bool condition, ushort address) {
	bool cc = false;

	if (condition) {
		self.call_n16(mmu, address);
	}
	
	self.required_cycles = 3;
}

fn void Cpu.jp_hl(&self) {
	self.pc = self.hl.reg;

	self.required_cycles = 1;
}

fn void Cpu.jp_n16(&self,mmu::Mmu *mmu, ushort address) {
	self.pc = mmu.get(address);

	self.required_cycles = 4;
}

fn void Cpu.jp_cc_n16(&self, mmu::Mmu *mmu, bool condition, ushort address) {
	if (condition) {
		self.call_n16(mmu, address);
	}
	self.required_cycles = 3;
}

fn void Cpu.jr_n16(&self) {
	self.required_cycles = 2;
}

fn void Cpu.jr_cc_n16(&self) {

}

fn void Cpu.ret_cc(&self) {

}

fn void Cpu.ret(&self) {

}

fn void Cpu.reti(&self) {

}

fn void Cpu.rst_vec(&self) {

}