module wer;
import std::io, cpu;

fn int main(String[] args)
{
	cpu::Cpu cpu = cpu::init();
	io::printn(cpu.af.hi);
	cpu.xor_a_n8(10);
	io::printn(cpu.af.hi);
	io::printn("Hello, World!");
	return 0;
}
