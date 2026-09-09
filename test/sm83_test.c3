module sm83_test;

import cpu, mmu;
import std::io;
import std::io::file;
import std::collections::object;

// SingleStepTests / sm83 harness  (https://github.com/SingleStepTests/sm83).
//
// The vectors are NOT vendored — hundreds of MB. Fetch them with
//   scripts/fetch-sm83-tests.sh          (curated subset, ~25 MB)
//   scripts/fetch-sm83-tests.sh --all    (everything, ~500 MB, ~5 min run)
// into test/sm83/v1/ . The harness runs whatever files are present; with none
// it prints one line and passes.
//
// Each vector is one instruction: set registers + flat RAM from `initial`, run
// exactly one instruction (`Cpu.execute_one`, no interrupt dispatch), then
// compare every register and every touched RAM byte against `final`. The
// length of the `cycles` array is the expected M-cycle count.

const String DIR = "test/sm83/v1";

// STOP ($10) and HALT ($76): their SST models (1-byte, extra internal cycles,
// no observable halt/stop state) don't match a functional core.
// $D3 $DB $DD $E3 $E4 $EB $EC $ED $F4 $FC $FD: no such opcode on the SM83.
fn bool skip_opcode(int op) {
	switch (op) {
		case 0x10:
		case 0x76:
		case 0xD3:
		case 0xDB:
		case 0xDD:
		case 0xE3:
		case 0xE4:
		case 0xEB:
		case 0xEC:
		case 0xED:
		case 0xF4:
		case 0xFC:
		case 0xFD:
			return true;
		default:
			return false;
	}
}

struct Result {
	uint total;
	uint state_fail;
	uint cycle_fail;
	int first_fail; // case index of the first failure, -1 if none
}

fn char u8(Object* o, String key) {
	return (char)(o.get_int(key) ?? 0);
}

fn ushort u16(Object* o, String key) {
	return (ushort)(o.get_int(key) ?? 0);
}

fn void apply_regs(cpu::Cpu* c, Object* st) {
	*c = {};
	c.af.hi = u8(st, "a");
	c.af.lo = u8(st, "f");
	c.bc.hi = u8(st, "b");
	c.bc.lo = u8(st, "c");
	c.de.hi = u8(st, "d");
	c.de.lo = u8(st, "e");
	c.hl.hi = u8(st, "h");
	c.hl.lo = u8(st, "l");
	c.pc = u16(st, "pc");
	c.sp = u16(st, "sp");
	c.ime = (st.get_int("ime") ?? 0) != 0;
}

fn void apply_ram(mmu::Mmu* m, Object* st) {
	Object* ram = st.get("ram") ?? null;
	if (!ram) return;
	for (sz i = 0; i < ram.get_len(); i++) {
		Object* pair = ram.get_at(i);
		m.set((ushort)(pair.get_int_at(0) ?? 0), (char)(pair.get_int_at(1) ?? 0));
	}
}

fn bool regs_match(cpu::Cpu* c, Object* st) {
	bool want_ei = (st.get_int("ei") ?? 0) != 0;
	return c.af.hi == u8(st, "a")
		&& c.af.lo == u8(st, "f")
		&& c.bc.hi == u8(st, "b")
		&& c.bc.lo == u8(st, "c")
		&& c.de.hi == u8(st, "d")
		&& c.de.lo == u8(st, "e")
		&& c.hl.hi == u8(st, "h")
		&& c.hl.lo == u8(st, "l")
		&& c.pc == u16(st, "pc")
		&& c.sp == u16(st, "sp")
		&& c.ime == ((st.get_int("ime") ?? 0) != 0)
		&& (c.ime_delay > 0) == want_ei;
}

// Zero exactly the addresses named in this state's `ram` list. Since SST lists
// every changed byte in `final`, clearing initial+final addresses after a case
// restores an all-zero buffer without touching all 64 KiB.
fn void zero_ram(char[] flat, Object* st) {
	Object* ram = st.get("ram") ?? null;
	if (!ram) return;
	for (sz i = 0; i < ram.get_len(); i++) {
		flat[(ushort)(ram.get_at(i).get_int_at(0) ?? 0)] = 0;
	}
}

fn bool ram_match(mmu::Mmu* m, Object* st) {
	Object* ram = st.get("ram") ?? null;
	if (!ram) return true;
	for (sz i = 0; i < ram.get_len(); i++) {
		Object* pair = ram.get_at(i);
		if (m.get((ushort)(pair.get_int_at(0) ?? 0)) != (char)(pair.get_int_at(1) ?? 0)) {
			return false;
		}
	}
	return true;
}

// Returns false if the vector file is missing.
fn bool run_file(String opcode, char[] flat, Result* out) {
	*out = { .first_fail = -1 };

	String path = string::tformat("%s/%s.json", DIR, opcode);
	char[]? data = file::load(mem, path);
	if (catch data) return false;
	defer free(data.ptr);

	Object*? root = ((String)data).parse_json(mem);
	if (catch root) return false;
	defer root.free();

	mmu::Mmu m;
	m.flat = flat.ptr;

	for (sz i = 0; i < root.get_len(); i++) {
		Object* t = root.get_at(i);
		Object* initial = t.get("initial") ?? null;
		Object* final = t.get("final") ?? null;
		if (!initial || !final) continue;

		cpu::Cpu c;
		apply_regs(&c, initial);
		apply_ram(&m, initial);

		char cycles = c.execute_one(&m);

		out.total++;
		bool state_ok = regs_match(&c, final) && ram_match(&m, final);
		sz want_cycles = (t.get("cycles") ?? null) ? t.get("cycles")!!.get_len() : 0;

		if (!state_ok) {
			out.state_fail++;
			if (out.first_fail < 0) out.first_fail = (int)i;
		} else if ((sz)cycles != want_cycles) {
			out.cycle_fail++;
			if (out.first_fail < 0) out.first_fail = (int)i;
		}

		zero_ram(flat, initial);
		zero_ram(flat, final);
	}
	return true;
}

fn void run_one(String name, char[] flat, uint* files, uint* total, uint* state_fail, uint* cycle_fail) {
	Result r;
	if (!run_file(name, flat, &r)) return; // no vector file
	(*files)++;
	*total += r.total;
	*state_fail += r.state_fail;
	*cycle_fail += r.cycle_fail;

	if (r.state_fail != 0 || r.cycle_fail != 0) {
		io::eprintfn("  %-6s %d/%d  (%d state, %d cycle)  first fail: case %d",
			name, r.total - r.state_fail - r.cycle_fail, r.total,
			r.state_fail, r.cycle_fail, r.first_fail);
	}
}

fn void run_all() @test {
	char[] flat = mem::new_array(char, 0x10000);
	defer free(flat.ptr);

	uint files;
	uint total;
	uint state_fail;
	uint cycle_fail;

	for (int op = 0; op < 256; op++) {
		if (skip_opcode(op)) continue;
		run_one(string::tformat("%02x", op), flat, &files, &total, &state_fail, &cycle_fail);
	}
	for (int op = 0; op < 256; op++) {
		run_one(string::tformat("cb %02x", op), flat, &files, &total, &state_fail, &cycle_fail);
	}

	if (files == 0) {
		io::eprintn("  sm83: no vectors in test/sm83/v1 — run scripts/fetch-sm83-tests.sh");
		return;
	}

	io::eprintfn("  sm83: %d files, %d cases, %d state fails, %d cycle fails",
		files, total, state_fail, cycle_fail);

	test::@check(state_fail == 0, "sm83 state mismatches (see lines above)");
	test::@check(cycle_fail == 0, "sm83 cycle-count mismatches (see lines above)");
}
