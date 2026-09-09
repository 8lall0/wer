module cpu;

import mmu;

// True when at least one enabled interrupt line is pending (IE & IF).
fn bool Cpu.interrupt_pending(&self, mmu::Mmu *mmu) {
	return (mmu.get(IE_ADDR) & mmu.get(IF_ADDR) & INT_MASK) != 0;
}

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

// HALT : suspend the CPU until an interrupt becomes pending.
//
//  - IME = 1: the CPU wakes and the pending interrupt is serviced normally.
//  - IME = 0, nothing pending: the CPU wakes when something becomes pending,
//    but the interrupt is NOT serviced (execution just continues after HALT).
//  - IME = 0, something ALREADY pending: the "halt bug" — the CPU does not
//    halt at all and the byte right after HALT is fetched twice (PC does not
//    advance on that fetch).
//
// The fetch/decode loop is responsible for: staying in `halted` and burning
// cycles while no interrupt is pending, and consuming `halt_bug` on the next
// fetch.
fn void Cpu.halt(&self, mmu::Mmu *mmu) {
	if (!self.ime && self.interrupt_pending(mmu)) {
		self.halt_bug = true;
	} else {
		self.halted = true;
	}

	self.required_cycles = 1;
}
