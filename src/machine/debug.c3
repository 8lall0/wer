module gameboy;
import mmu, ppu;

// The debugger's view of the machine (frontend/debugger.c3): SM83
// disassembly, breakpoints, stepping.

// Mnemonics by opcode; in the operands %b is a byte, %w a 16-bit word, %h a
// high-page address ($FF00 + byte), %r a relative jump's target, %e a signed
// byte offset. "-": not an instruction.
const String[256] OPS = {
	"NOP", "LD BC,%w", "LD (BC),A", "INC BC",
	"INC B", "DEC B", "LD B,%b", "RLCA",
	"LD (%w),SP", "ADD HL,BC", "LD A,(BC)", "DEC BC",
	"INC C", "DEC C", "LD C,%b", "RRCA",
	"STOP", "LD DE,%w", "LD (DE),A", "INC DE",
	"INC D", "DEC D", "LD D,%b", "RLA",
	"JR %r", "ADD HL,DE", "LD A,(DE)", "DEC DE",
	"INC E", "DEC E", "LD E,%b", "RRA",
	"JR NZ,%r", "LD HL,%w", "LD (HL+),A", "INC HL",
	"INC H", "DEC H", "LD H,%b", "DAA",
	"JR Z,%r", "ADD HL,HL", "LD A,(HL+)", "DEC HL",
	"INC L", "DEC L", "LD L,%b", "CPL",
	"JR NC,%r", "LD SP,%w", "LD (HL-),A", "INC SP",
	"INC (HL)", "DEC (HL)", "LD (HL),%b", "SCF",
	"JR C,%r", "ADD HL,SP", "LD A,(HL-)", "DEC SP",
	"INC A", "DEC A", "LD A,%b", "CCF",
	"LD B,B", "LD B,C", "LD B,D", "LD B,E",
	"LD B,H", "LD B,L", "LD B,(HL)", "LD B,A",
	"LD C,B", "LD C,C", "LD C,D", "LD C,E",
	"LD C,H", "LD C,L", "LD C,(HL)", "LD C,A",
	"LD D,B", "LD D,C", "LD D,D", "LD D,E",
	"LD D,H", "LD D,L", "LD D,(HL)", "LD D,A",
	"LD E,B", "LD E,C", "LD E,D", "LD E,E",
	"LD E,H", "LD E,L", "LD E,(HL)", "LD E,A",
	"LD H,B", "LD H,C", "LD H,D", "LD H,E",
	"LD H,H", "LD H,L", "LD H,(HL)", "LD H,A",
	"LD L,B", "LD L,C", "LD L,D", "LD L,E",
	"LD L,H", "LD L,L", "LD L,(HL)", "LD L,A",
	"LD (HL),B", "LD (HL),C", "LD (HL),D", "LD (HL),E",
	"LD (HL),H", "LD (HL),L", "HALT", "LD (HL),A",
	"LD A,B", "LD A,C", "LD A,D", "LD A,E",
	"LD A,H", "LD A,L", "LD A,(HL)", "LD A,A",
	"ADD A,B", "ADD A,C", "ADD A,D", "ADD A,E",
	"ADD A,H", "ADD A,L", "ADD A,(HL)", "ADD A,A",
	"ADC A,B", "ADC A,C", "ADC A,D", "ADC A,E",
	"ADC A,H", "ADC A,L", "ADC A,(HL)", "ADC A,A",
	"SUB B", "SUB C", "SUB D", "SUB E",
	"SUB H", "SUB L", "SUB (HL)", "SUB A",
	"SBC A,B", "SBC A,C", "SBC A,D", "SBC A,E",
	"SBC A,H", "SBC A,L", "SBC A,(HL)", "SBC A,A",
	"AND B", "AND C", "AND D", "AND E",
	"AND H", "AND L", "AND (HL)", "AND A",
	"XOR B", "XOR C", "XOR D", "XOR E",
	"XOR H", "XOR L", "XOR (HL)", "XOR A",
	"OR B", "OR C", "OR D", "OR E",
	"OR H", "OR L", "OR (HL)", "OR A",
	"CP B", "CP C", "CP D", "CP E",
	"CP H", "CP L", "CP (HL)", "CP A",
	"RET NZ", "POP BC", "JP NZ,%w", "JP %w",
	"CALL NZ,%w", "PUSH BC", "ADD A,%b", "RST 00H",
	"RET Z", "RET", "JP Z,%w", "PREFIX CB",
	"CALL Z,%w", "CALL %w", "ADC A,%b", "RST 08H",
	"RET NC", "POP DE", "JP NC,%w", "-",
	"CALL NC,%w", "PUSH DE", "SUB %b", "RST 10H",
	"RET C", "RETI", "JP C,%w", "-",
	"CALL C,%w", "-", "SBC A,%b", "RST 18H",
	"LDH (%h),A", "POP HL", "LD (C),A", "-",
	"-", "PUSH HL", "AND %b", "RST 20H",
	"ADD SP,%e", "JP HL", "LD (%w),A", "-",
	"-", "-", "XOR %b", "RST 28H",
	"LDH A,(%h)", "POP AF", "LD A,(C)", "DI",
	"-", "PUSH AF", "OR %b", "RST 30H",
	"LD HL,SP%e", "LD SP,HL", "LD A,(%w)", "EI",
	"-", "-", "CP %b", "RST 38H",
};

const String[8] CB_OPS = { "RLC", "RRC", "RL", "RR", "SLA", "SRA", "SWAP", "SRL" };
const String[8] REG8 = { "B", "C", "D", "E", "H", "L", "(HL)", "A" };

// The instruction at `pc` as text, and its length in bytes.
fn String disasm(mmu::Mmu* m, ushort pc, int* len) {
	char op = m.peek(pc);
	if (op == 0xCB) {
		char c = m.peek(pc + 1);
		*len = 2;
		int y = (c >> 3) & 7;
		String reg = REG8[c & 7];
		switch (c >> 6) {
			case 0:  return string::tformat("%s %s", CB_OPS[y], reg);
			case 1:  return string::tformat("BIT %d,%s", y, reg);
			case 2:  return string::tformat("RES %d,%s", y, reg);
			default: return string::tformat("SET %d,%s", y, reg);
		}
	}
	String f = OPS[op];
	DString out;
	out.init(tmem);
	int n = 1;
	char b1 = m.peek(pc + 1);
	for (usz i = 0; i < f.len; i++) {
		if (f[i] != '%' || i + 1 == f.len) {
			out.append_char(f[i]);
			continue;
		}
		i++;
		switch (f[i]) {
			case 'b':
				out.appendf("$%02X", b1);
				n = 2;
			case 'h':
				out.appendf("$FF%02X", b1);
				n = 2;
			case 'w':
				out.appendf("$%04X", (ushort)(b1 | (ushort)m.peek(pc + 2) << 8));
				n = 3;
			case 'r':
				out.appendf("$%04X", (ushort)(pc + 2 + (int)(ichar)b1));
				n = 2;
			case 'e':
				int v = (int)(ichar)b1;
				out.appendf(v < 0 ? "-$%02X" : "+$%02X", v < 0 ? -v : v);
				n = 2;
			default:
				out.append_char(f[i]);
		}
	}
	*len = n;
	return out.str_view();
}

// CALL and RST: what "step over" runs to the end of.
fn bool is_call(char op) => op == 0xCD || (op & 0xE7) == 0xC4 || (op & 0xC7) == 0xC7;

const int MAX_BREAKPOINTS = 32;

struct Breakpoints {
	ushort[MAX_BREAKPOINTS] at;
	int  n;
	int  temp;    // a one-shot breakpoint (step over, run to the cursor), or -1
}

fn void Breakpoints.init(&self) {
	*self = { .temp = -1 };
}

fn bool Breakpoints.has(&self, ushort a) {
	for (int i = 0; i < self.n; i++) if (self.at[i] == a) return true;
	return false;
}

fn bool Breakpoints.hit(&self, ushort a) => (self.temp >= 0 && a == (ushort)self.temp) || self.has(a);

fn bool Breakpoints.active(&self) => self.n > 0 || self.temp >= 0;

// Set one at `a`, or clear the one there.
fn void Breakpoints.toggle(&self, ushort a) {
	for (int i = 0; i < self.n; i++) {
		if (self.at[i] == a) {
			self.at[i] = self.at[--self.n];
			return;
		}
	}
	if (self.n < MAX_BREAKPOINTS) self.at[self.n++] = a;
}

// GameBoy.run_frame, stopping before the CPU runs an instruction at a
// breakpoint: true then, and the next call goes on with the same frame.
// `resume`: the instruction at PC runs even with a breakpoint there (going
// on from a break).
fn bool GameBoy.run_frame_breaking(&self, Breakpoints* b, bool resume) {
	self.mmu.apply_gameshark();
	ulong frame = self.mmu.double_speed ? 35112 : 17556;
	bool lcd = (self.mmu.ppu.lcdc & ppu::LCDC_ENABLE) != 0;
	self.mmu.ppu.frame_ready = false;
	ulong end = self.cpu.clk + (lcd ? frame * 2 : frame);
	bool skip = resume;
	while ((!lcd || !self.mmu.ppu.frame_ready) && self.cpu.clk < end) {
		if (!skip && !self.cpu.halted && !self.cpu.stopped && b.hit(self.cpu.pc)) {
			self.mmu.ppu_touch();
			return true;
		}
		skip = false;
		self.step();
	}
	self.mmu.ppu_touch();
	self.mmu.ppu.frame_ready = false;
	return false;
}

// One instruction (or an interrupt's call). A halted or stopped CPU runs
// until it wakes up (a frame's time at most).
fn void GameBoy.step_instruction(&self) {
	if (self.cpu.halted || self.cpu.stopped) {
		ulong end = self.cpu.clk + 70224;
		while ((self.cpu.halted || self.cpu.stopped) && self.cpu.clk < end) self.step();
	} else {
		self.step();
	}
	self.mmu.ppu_touch();
}
