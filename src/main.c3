module wer;
import std::io, cpu;

fn int main(String[] args)
{
	cpu::Cpu cpu = cpu::init();
	io::printfn("A=%02x F=%02x BC=%04x DE=%04x HL=%04x SP=%04x PC=%04x",
		cpu.af.hi, cpu.af.lo, cpu.bc.reg, cpu.de.reg, cpu.hl.reg, cpu.sp, cpu.pc);

	char n = 0xFF;
	cpu.add_a_r8(&n); // A: 0x01 + 0xFF -> 0x00, Z=1 H=1 C=1
	io::printfn("after ADD A,0xFF: A=%02x F=%02x", cpu.af.hi, cpu.af.lo);
	return 0;
}
