module wer;
import std::io, cpu, mmu;

fn int main(String[] args)
{
	cpu::Cpu cpu = cpu::init();
	mmu::Mmu ram;

	// A tiny hand-assembled program at the reset vector:
	//   LD A,0x10 ; LD B,0x05 ; ADD A,B ; DAA ; JR -2 (spin)
	char[] program = { 0x3E, 0x10, 0x06, 0x05, 0x80, 0x27, 0x18, 0xFE };
	foreach (i, b : program) ram.set(0x0100 + (ushort)i, b);

	for (int i = 0; i < 6; i++) {
		char cycles = cpu.step(&ram);
		io::printfn("PC=%04x A=%02x B=%02x F=%02x  (%d cyc, clk=%d)",
			cpu.pc, cpu.af.hi, cpu.bc.hi, cpu.af.lo, cycles, cpu.clk);
	}
	return 0;
}
