module debug_test;
import gameboy, mmu;
import std::core::test;

// The debugger's disassembler, breakpoints and stepping.

fn void disassembles() @test {
	char[0x10000] ram;
	gameboy::GameBoy gb = gameboy::new(false);
	defer gb.destroy();
	gb.mmu.flat = &ram;
	char[] code = {
		0x00,                   // NOP
		0x01, 0x34, 0x12,       // LD BC,$1234
		0x18, 0xFE,             // JR $0006 (itself)
		0x3E, 0x42,             // LD A,$42
		0xE0, 0x40,             // LDH ($FF40),A
		0xCB, 0x7C,             // BIT 7,H
		0xE8, 0xF0,             // ADD SP,-$10
		0xCD, 0x00, 0x40,       // CALL $4000
		0xD3,                   // (none)
	};
	ram[0x100 : code.len] = code[..];
	String[] want = { "NOP", "LD BC,$1234", "JR $0104", "LD A,$42", "LDH ($FF40),A", "BIT 7,H", "ADD SP,-$10", "CALL $4000", "-" };
	int[] lens = { 1, 3, 2, 2, 2, 2, 2, 3, 1 };
	ushort pc = 0x100;
	foreach (i, w : want) {
		int len;
		String got = gameboy::disasm(&gb.mmu, pc, &len);
		test::@check(got == w, "at $%04X: %s, not %s", pc, got, w);
		test::eq(len, lens[i]);
		pc += (ushort)len;
	}
	test::@check(gameboy::is_call(0xCD) && gameboy::is_call(0xC4) && gameboy::is_call(0xDC) && gameboy::is_call(0xFF), "calls");
	test::@check(!gameboy::is_call(0xC3) && !gameboy::is_call(0xC9) && !gameboy::is_call(0xC5), "not calls");
}

// A loop at $0150: INC A; JR $0150. A breakpoint on the JR stops the frame
// there; going on, it stops there again one INC A later.
fn void breaks_and_steps() @test {
	char[] rom = mem::new_array(char, 0x8000);
	defer free(rom.ptr);
	char[4] entry = { 0x00, 0xC3, 0x50, 0x01 };   // JP $0150
	rom[0x100 : 4] = entry[..];
	char[3] loop = { 0x3C, 0x18, 0xFD };          // INC A; JR $0150
	rom[0x150 : 3] = loop[..];
	gameboy::GameBoy gb = gameboy::new(false);
	defer gb.destroy();
	gb.load_rom(rom);
	gameboy::Breakpoints b;
	b.init();
	b.toggle(0x151);
	test::@check(b.active() && b.has(0x151), "set");
	test::@check(gb.run_frame_breaking(&b, false), "stopped");
	test::eq(gb.cpu.pc, (ushort)0x151);
	char a = gb.cpu.af.hi;
	test::@check(gb.run_frame_breaking(&b, true), "stopped again");
	test::eq(gb.cpu.pc, (ushort)0x151);
	test::eq(gb.cpu.af.hi, (char)(a + 1));
	// Stepping: the JR, then INC A.
	gb.step_instruction();
	test::eq(gb.cpu.pc, (ushort)0x150);
	gb.step_instruction();
	test::eq(gb.cpu.pc, (ushort)0x151);
	test::eq(gb.cpu.af.hi, (char)(a + 2));
	// Cleared, a frame runs through.
	b.toggle(0x151);
	test::@check(!b.active(), "cleared");
	test::@check(!gb.run_frame_breaking(&b, false), "ran the frame");
}
