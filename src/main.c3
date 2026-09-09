module wer;
import std::io, gameboy;

fn int main(String[] args)
{
	gameboy::GameBoy gb = gameboy::new();

	if (args.len > 1) {
		if (catch gb.load_rom_file(args[1])) {
			io::printfn("could not load ROM: %s", args[1]);
			return 1;
		}
	} else {
		// A tiny hand-assembled program at the reset vector:
		//   LD A,0x10 ; LD B,0x05 ; ADD A,B ; DAA ; JR -2 (spin)
		char[] program = { 0x3E, 0x10, 0x06, 0x05, 0x80, 0x27, 0x18, 0xFE };
		gb.load_rom(program);
		gb.cpu.pc = 0x0000; // this toy program lives at the start of ROM
	}

	for (int i = 0; i < 6; i++) {
		char cycles = gb.step();
		io::printfn("PC=%04x A=%02x B=%02x F=%02x DIV=%02x  (%d cyc, clk=%d)",
			gb.cpu.pc, gb.cpu.af.hi, gb.cpu.bc.hi, gb.cpu.af.lo,
			gb.mmu.get(0xFF04), cycles, gb.cpu.clk);
	}
	return 0;
}
