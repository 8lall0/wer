module cpu_test;

import cpu;
import mmu;
import std::core::test;

// ---------------------------------------------------------------------------
// Flag register
// ---------------------------------------------------------------------------

fn void flags_set_unset_get() @test
{
	cpu::Cpu c;
	c.af.lo = 0;

	c.setFlag(cpu::Z);
	c.setFlag(cpu::C);
	test::@check(c.getFlag(cpu::Z) == 1, "Z should be set");
	test::@check(c.getFlag(cpu::C) == 1, "C should be set");
	test::@check(c.getFlag(cpu::N) == 0, "N should be clear");
	test::@check(c.getFlag(cpu::H) == 0, "H should be clear");
	// F layout: Z=bit7, C=bit4 -> 0b1001_0000
	test::eq((char)0x90, c.af.lo);

	c.unsetFlag(cpu::Z);
	test::@check(c.getFlag(cpu::Z) == 0, "Z should now be clear");
	test::@check(c.getFlag(cpu::C) == 1, "C should still be set");
}

fn void get_flag_does_not_mutate() @test
{
	cpu::Cpu c;
	c.af.lo = 0xF0; // all four flags set

	c.getFlag(cpu::C);
	c.getFlag(cpu::H);
	test::eq((char)0xF0, c.af.lo);
}

fn void assign_and_update_zero() @test
{
	cpu::Cpu c;
	c.af.lo = 0;

	c.assignFlag(cpu::H, true);
	c.assignFlag(cpu::H, false);
	test::@check(c.getFlag(cpu::H) == 0, "assignFlag(false) should clear");

	c.updateZero(0);
	test::@check(c.getFlag(cpu::Z) == 1, "updateZero(0) sets Z");
	c.updateZero(5);
	test::@check(c.getFlag(cpu::Z) == 0, "updateZero(nonzero) clears Z");
}

// ---------------------------------------------------------------------------
// Carry / half-carry helpers
// ---------------------------------------------------------------------------

fn void half_carry_add8() @test
{
	test::@check(cpu::check_bit3_overflow(0x0F, 0x01, 0), "0xF + 1 crosses bit 3");
	test::@check(!cpu::check_bit3_overflow(0x01, 0x01, 0), "1 + 1 does not");
	test::@check(cpu::check_bit3_overflow(0x0F, 0x00, 1), "carry-in alone crosses bit 3");
}

fn void carry_add8() @test
{
	test::@check(cpu::check_bit7_overflow(0xFF, 0x01, 0), "0xFF + 1 carries");
	test::@check(!cpu::check_bit7_overflow(0x80, 0x7F, 0), "0x80 + 0x7F does not");
	test::@check(cpu::check_bit7_overflow(0xFF, 0xFF, 1), "0xFF + 0xFF + 1 carries");
}

fn void borrow_sub8() @test
{
	test::@check(cpu::check_bit3_borrow(0x10, 0x01, 0), "low nibble 0 - 1 borrows");
	test::@check(!cpu::check_bit3_borrow(0x12, 0x01, 0), "2 - 1 does not");
	test::@check(cpu::check_bit7_borrow(0x00, 0x01, 0), "0 - 1 borrows");
	test::@check(!cpu::check_bit7_borrow(0x01, 0x01, 0), "1 - 1 does not");
	test::@check(cpu::check_bit7_borrow(0x01, 0x01, 1), "1 - 1 - carry borrows");
}

fn void half_carry_add16() @test
{
	test::@check(cpu::check_bit11_overflow(0x0FFF, 0x0001), "bit 11 carry");
	test::@check(!cpu::check_bit11_overflow(0x0F00, 0x00FF), "no bit 11 carry");
	test::@check(cpu::check_bit15_overflow(0xFFFF, 0x0001), "bit 15 carry");
	test::@check(!cpu::check_bit15_overflow(0x8000, 0x7FFF), "no bit 15 carry");
}

fn void signed_sp_offset_helpers() @test
{
	// SP=0x000F, e8 = +1 -> half carry from bit 3, no bit 7 carry
	test::@check(cpu::check_bit3_signed_overflow(0x000F, 1), "nibble 0xF + 1");
	test::@check(!cpu::check_bit7_signed_overflow(0x000F, 1), "no byte carry");
	// SP=0x00FF, e8 = +1 -> both
	test::@check(cpu::check_bit7_signed_overflow(0x00FF, 1), "0xFF + 1 byte carry");
	// negative offset uses the unsigned byte value (0xFF for -1)
	test::@check(cpu::check_bit7_signed_overflow(0x0001, -1), "0x01 + 0xFF byte carry");
}

// ---------------------------------------------------------------------------
// Reset state
// ---------------------------------------------------------------------------

fn void init_registers() @test
{
	cpu::Cpu c = cpu::init();
	test::eq((char)0x01, c.af.hi);
	test::eq((char)0xB0, c.af.lo);
	test::eq((ushort)0x0013, c.bc.reg);
	test::eq((ushort)0x00D8, c.de.reg);
	test::eq((ushort)0x014D, c.hl.reg);
	test::eq((ushort)0xFFFE, c.sp);
	test::eq((ushort)0x0100, c.pc);
	// hi/lo split matches the 16-bit value
	test::eq((char)0x00, c.bc.hi);
	test::eq((char)0x13, c.bc.lo);
}

// ---------------------------------------------------------------------------
// 8-bit arithmetic
// ---------------------------------------------------------------------------

fn void add_a_r8_sets_all_flags() @test
{
	cpu::Cpu c = cpu::init();
	c.af.hi = 0x01;
	c.af.lo = 0;
	char n = 0xFF;
	c.add_a_r8(&n);

	test::eq((char)0x00, c.af.hi);
	test::@check(c.getFlag(cpu::Z) == 1, "Z: result is zero");
	test::@check(c.getFlag(cpu::N) == 0, "N: add clears N");
	test::@check(c.getFlag(cpu::H) == 1, "H: 0x1 + 0xF crosses bit 3");
	test::@check(c.getFlag(cpu::C) == 1, "C: 0x01 + 0xFF carries");
	test::eq((char)1, c.required_cycles);
}

fn void add_a_clears_stale_flags() @test
{
	cpu::Cpu c = cpu::init();
	c.af.hi = 0x01;
	c.af.lo = 0xF0; // every flag stale-set
	char n = 0x01;
	c.add_a_r8(&n);

	test::eq((char)0x02, c.af.hi);
	test::@check(c.getFlag(cpu::Z) == 0, "Z cleared");
	test::@check(c.getFlag(cpu::N) == 0, "N cleared");
	test::@check(c.getFlag(cpu::H) == 0, "H cleared");
	test::@check(c.getFlag(cpu::C) == 0, "C cleared");
}

fn void adc_a_n8_uses_carry_in() @test
{
	cpu::Cpu c = cpu::init();
	c.af.hi = 0x0E;
	c.af.lo = 0;
	c.setFlag(cpu::C);
	c.adc_a_n8(0x01); // 0x0E + 0x01 + 1 = 0x10

	test::eq((char)0x10, c.af.hi);
	test::@check(c.getFlag(cpu::H) == 1, "H: 0xE + 0x1 + 1 crosses bit 3");
	test::@check(c.getFlag(cpu::C) == 0, "C: no byte carry");
	test::@check(c.getFlag(cpu::Z) == 0, "Z clear");
}

fn void sub_a_r8_flags() @test
{
	cpu::Cpu c = cpu::init();
	c.af.hi = 0x10;
	c.af.lo = 0;
	char n = 0x01;
	c.sub_a_r8(&n);

	test::eq((char)0x0F, c.af.hi);
	test::@check(c.getFlag(cpu::N) == 1, "N: sub sets N");
	test::@check(c.getFlag(cpu::H) == 1, "H: low nibble 0 - 1 borrows");
	test::@check(c.getFlag(cpu::C) == 0, "C: 0x10 >= 0x01");
	test::@check(c.getFlag(cpu::Z) == 0, "Z clear");
}

fn void sub_a_underflow_sets_carry() @test
{
	cpu::Cpu c = cpu::init();
	c.af.hi = 0x00;
	c.af.lo = 0;
	c.sub_a_n8(0x01);

	test::eq((char)0xFF, c.af.hi);
	test::@check(c.getFlag(cpu::C) == 1, "C: 0x00 - 0x01 borrows");
	test::@check(c.getFlag(cpu::H) == 1, "H: nibble borrow");
	test::@check(c.getFlag(cpu::Z) == 0, "Z clear");
}

fn void sub_a_equal_sets_zero() @test
{
	cpu::Cpu c = cpu::init();
	c.af.hi = 0x42;
	c.af.lo = 0;
	char n = 0x42;
	c.sub_a_r8(&n);

	test::eq((char)0x00, c.af.hi);
	test::@check(c.getFlag(cpu::Z) == 1, "Z: equal operands");
	test::@check(c.getFlag(cpu::C) == 0, "C clear");
}

fn void sbc_a_uses_carry_in() @test
{
	cpu::Cpu c = cpu::init();
	// 0x05 - 0x04 - 1 = 0x00
	c.af.hi = 0x05;
	c.af.lo = 0;
	c.setFlag(cpu::C);
	char n = 0x04;
	c.sbc_a_r8(&n);

	test::eq((char)0x00, c.af.hi);
	test::@check(c.getFlag(cpu::Z) == 1, "Z: result is zero incl. carry-in");
	test::@check(c.getFlag(cpu::N) == 1, "N set");
	test::@check(c.getFlag(cpu::C) == 0, "C: no borrow");
}

fn void sbc_a_borrow_from_carry_in() @test
{
	cpu::Cpu c = cpu::init();
	// 0x00 - 0x00 - 1 = 0xFF, borrows
	c.af.hi = 0x00;
	c.af.lo = 0;
	c.setFlag(cpu::C);
	c.sbc_a_n8(0x00);

	test::eq((char)0xFF, c.af.hi);
	test::@check(c.getFlag(cpu::C) == 1, "C: carry-in alone causes borrow");
	test::@check(c.getFlag(cpu::H) == 1, "H: nibble borrow from carry-in");
	test::@check(c.getFlag(cpu::Z) == 0, "Z clear");
}

fn void cp_a_does_not_change_a() @test
{
	cpu::Cpu c = cpu::init();
	c.af.hi = 0x3C;
	c.af.lo = 0;
	char n = 0x2F;
	c.cp_a_r8(&n); // 0x3C - 0x2F = 0x0D

	test::eq((char)0x3C, c.af.hi); // A untouched
	test::@check(c.getFlag(cpu::N) == 1, "N set");
	test::@check(c.getFlag(cpu::H) == 1, "H: 0xC - 0xF borrows");
	test::@check(c.getFlag(cpu::C) == 0, "C: 0x3C >= 0x2F");
	test::@check(c.getFlag(cpu::Z) == 0, "Z clear");

	c.cp_a_n8(0x3C);
	test::@check(c.getFlag(cpu::Z) == 1, "Z: A == operand");
	test::eq((char)0x3C, c.af.hi);
}

fn void inc_r8_half_carry_and_c_preserved() @test
{
	cpu::Cpu c = cpu::init();
	char reg = 0x0F;
	c.af.lo = 0;
	c.setFlag(cpu::C); // must survive INC

	c.inc_r8(&reg);
	test::eq((char)0x10, reg);
	test::@check(c.getFlag(cpu::N) == 0, "N cleared");
	test::@check(c.getFlag(cpu::H) == 1, "H: bit 3 carry");
	test::@check(c.getFlag(cpu::Z) == 0, "Z clear");
	test::@check(c.getFlag(cpu::C) == 1, "C untouched by INC");
	test::eq((char)1, c.required_cycles);
}

fn void inc_r8_wraps_to_zero() @test
{
	cpu::Cpu c = cpu::init();
	char reg = 0xFF;
	c.af.lo = 0;

	c.inc_r8(&reg);
	test::eq((char)0x00, reg);
	test::@check(c.getFlag(cpu::Z) == 1, "Z: wrapped to 0");
	test::@check(c.getFlag(cpu::H) == 1, "H: 0xF + 1");
}

fn void dec_r8_half_borrow_and_c_preserved() @test
{
	cpu::Cpu c = cpu::init();
	char reg = 0x10;
	c.af.lo = 0;
	c.setFlag(cpu::C);

	c.dec_r8(&reg);
	test::eq((char)0x0F, reg);
	test::@check(c.getFlag(cpu::N) == 1, "N set");
	test::@check(c.getFlag(cpu::H) == 1, "H: low nibble borrow");
	test::@check(c.getFlag(cpu::C) == 1, "C untouched by DEC");
}

fn void dec_r8_to_zero_and_underflow() @test
{
	cpu::Cpu c = cpu::init();
	char reg = 0x01;
	c.af.lo = 0;
	c.dec_r8(&reg);
	test::eq((char)0x00, reg);
	test::@check(c.getFlag(cpu::Z) == 1, "Z: reached 0");
	test::@check(c.getFlag(cpu::H) == 0, "H: 0x1 - 1, no borrow");

	c.dec_r8(&reg);
	test::eq((char)0xFF, reg);
	test::@check(c.getFlag(cpu::Z) == 0, "Z clear");
	test::@check(c.getFlag(cpu::H) == 1, "H: 0x0 - 1 borrows");
}

fn void inc_dec_hl_memory() @test
{
	cpu::Cpu c = cpu::init();
	mmu::Mmu m;
	c.hl.reg = 0xC000;
	m.set(0xC000, 0x0F);
	c.af.lo = 0;

	c.inc_hl(&m);
	test::eq((char)0x10, m.get(0xC000));
	test::@check(c.getFlag(cpu::H) == 1, "H: bit 3 carry");
	test::eq((char)3, c.required_cycles);

	c.dec_hl(&m);
	test::eq((char)0x0F, m.get(0xC000));
	test::@check(c.getFlag(cpu::N) == 1, "N set by DEC");
	test::eq((char)3, c.required_cycles);
}

// ---------------------------------------------------------------------------
// 16-bit arithmetic
// ---------------------------------------------------------------------------

fn void add_hl_r16_flags() @test
{
	cpu::Cpu c = cpu::init();
	c.hl.reg = 0x0FFF;
	c.af.lo = 0;
	cpu::HiLoReg de;
	de.reg = 0x0001;
	c.add_hl_r16(&de);

	test::eq((ushort)0x1000, c.hl.reg);
	test::@check(c.getFlag(cpu::N) == 0, "N cleared");
	test::@check(c.getFlag(cpu::H) == 1, "H: bit 11 carry");
	test::@check(c.getFlag(cpu::C) == 0, "C: no bit 15 carry");
}

fn void inc_dec_r16_no_flags() @test
{
	cpu::Cpu c = cpu::init();
	c.af.lo = 0xF0;
	cpu::HiLoReg r;
	r.reg = 0x00FF;
	c.inc_r16(&r);
	test::eq((ushort)0x0100, r.reg);
	c.dec_r16(&r);
	c.dec_r16(&r);
	test::eq((ushort)0x00FE, r.reg);
	test::eq((char)0xF0, c.af.lo); // untouched
}

// ---------------------------------------------------------------------------
// Logic ops
// ---------------------------------------------------------------------------

fn void and_or_xor_flags() @test
{
	cpu::Cpu c = cpu::init();

	c.af.hi = 0b1100;
	c.af.lo = 0;
	c.and_a_n8(0b1010); // -> 0b1000
	test::eq((char)0b1000, c.af.hi);
	test::@check(c.getFlag(cpu::H) == 1 && c.getFlag(cpu::N) == 0 && c.getFlag(cpu::C) == 0, "AND: H=1,N=0,C=0");
	test::@check(c.getFlag(cpu::Z) == 0, "AND: not zero");

	c.af.hi = 0b1010;
	c.xor_a_n8(0b1010); // -> 0
	test::@check(c.getFlag(cpu::Z) == 1, "XOR: zero");
	test::@check(c.getFlag(cpu::H) == 0, "XOR: H cleared");

	c.af.hi = 0x00;
	c.or_a_n8(0x00);
	test::@check(c.getFlag(cpu::Z) == 1, "OR: zero");
}

// ---------------------------------------------------------------------------
// CB bit ops
// ---------------------------------------------------------------------------

fn void bit_does_not_modify_operand() @test
{
	cpu::Cpu c = cpu::init();
	char reg = 0b1111_1011; // bit 2 is clear
	c.af.lo = 0;

	c.bit_u3_r8(&reg, 2);
	test::eq((char)0b1111_1011, reg); // unchanged
	test::@check(c.getFlag(cpu::Z) == 1, "Z: tested bit was 0");
	test::@check(c.getFlag(cpu::N) == 0, "N cleared");
	test::@check(c.getFlag(cpu::H) == 1, "H set");

	c.bit_u3_r8(&reg, 0);
	test::@check(c.getFlag(cpu::Z) == 0, "Z: tested bit was 1");
}

fn void res_set_bit() @test
{
	cpu::Cpu c = cpu::init();
	char reg = 0x00;

	c.set_u3_r8(&reg, 7);
	test::eq((char)0x80, reg);
	c.set_u3_r8(&reg, 0);
	test::eq((char)0x81, reg);
	c.res_u3_r8(&reg, 7);
	test::eq((char)0x01, reg);
}

fn void bit_ops_on_hl_memory() @test
{
	cpu::Cpu c = cpu::init();
	mmu::Mmu m;
	c.hl.reg = 0xC000;
	m.set(0xC000, 0x00);

	c.set_u3_hl(&m, 3);
	test::eq((char)0x08, m.get(0xC000));
	c.res_u3_hl(&m, 3);
	test::eq((char)0x00, m.get(0xC000));
}

// ---------------------------------------------------------------------------
// Carry flag ops
// ---------------------------------------------------------------------------

fn void ccf_scf() @test
{
	cpu::Cpu c = cpu::init();
	c.af.lo = 0;

	c.scf();
	test::@check(c.getFlag(cpu::C) == 1, "SCF sets C");
	c.ccf();
	test::@check(c.getFlag(cpu::C) == 0, "CCF flips C to 0");
	c.ccf();
	test::@check(c.getFlag(cpu::C) == 1, "CCF flips C to 1");
	test::@check(c.getFlag(cpu::N) == 0 && c.getFlag(cpu::H) == 0, "N=H=0");
}

// ---------------------------------------------------------------------------
// Loads
// ---------------------------------------------------------------------------

fn void ld_hli_hld_move_hl_not_a() @test
{
	cpu::Cpu c = cpu::init();
	mmu::Mmu m;
	c.af.hi = 0x42;
	c.hl.reg = 0xC000;

	c.ld_hli_a(&m);
	test::eq((char)0x42, m.get(0xC000));
	test::eq((ushort)0xC001, c.hl.reg);
	test::eq((char)0x42, c.af.hi); // A untouched

	m.set(0xC001, 0x77);
	c.ld_a_hld(&m); // reads [0xC001], then HL-- back to 0xC000
	test::eq((char)0x77, c.af.hi);
	test::eq((ushort)0xC000, c.hl.reg);
}

fn void ldh_c_uses_register_c() @test
{
	cpu::Cpu c = cpu::init();
	mmu::Mmu m;
	c.af.hi = 0x99;
	c.bc.lo = 0x80; // C register -> address 0xFF80

	c.ldh_c_a(&m);
	test::eq((char)0x99, m.get(0xFF80));

	c.af.hi = 0x00;
	c.ldh_a_c(&m);
	test::eq((char)0x99, c.af.hi);
}

fn void ld_r16_a_stores_to_memory() @test
{
	cpu::Cpu c = cpu::init();
	mmu::Mmu m;
	c.af.hi = 0x7E;
	cpu::HiLoReg bc;
	bc.reg = 0xC123;

	c.ld_r16_a(&m, &bc);
	test::eq((char)0x7E, m.get(0xC123));
}

// ---------------------------------------------------------------------------
// Stack
// ---------------------------------------------------------------------------

fn void push_pop_roundtrip() @test
{
	cpu::Cpu c = cpu::init();
	mmu::Mmu m;
	c.sp = 0xFFFE;

	c.push16(&m, 0xBEEF);
	test::eq((ushort)0xFFFC, c.sp);
	ushort v = c.pop16(&m);
	test::eq((ushort)0xBEEF, v);
	test::eq((ushort)0xFFFE, c.sp);
}

fn void push_r16_pop_r16() @test
{
	cpu::Cpu c = cpu::init();
	mmu::Mmu m;
	c.sp = 0xFFFE;
	cpu::HiLoReg src;
	src.reg = 0x1234;

	c.push_r16(&m, &src);
	cpu::HiLoReg dst;
	dst.reg = 0;
	c.pop_r16(&m, &dst);
	test::eq((ushort)0x1234, dst.reg);
}

fn void pop_af_masks_low_nibble() @test
{
	cpu::Cpu c = cpu::init();
	mmu::Mmu m;
	c.sp = 0xFFF0;
	m.set(0xFFF0, 0xFF); // F byte on stack
	m.set(0xFFF1, 0xAA); // A byte on stack

	c.pop_af(&m);
	test::eq((char)0xAA, c.af.hi);
	test::eq((char)0xF0, c.af.lo); // low nibble forced to 0
}

fn void add_sp_e8_flags() @test
{
	cpu::Cpu c = cpu::init();
	c.sp = 0x000F;
	c.af.lo = 0xF0;

	c.add_sp_e8(1);
	test::eq((ushort)0x0010, c.sp);
	test::@check(c.getFlag(cpu::Z) == 0, "Z always 0");
	test::@check(c.getFlag(cpu::N) == 0, "N always 0");
	test::@check(c.getFlag(cpu::H) == 1, "H: nibble 0xF + 1");
	test::@check(c.getFlag(cpu::C) == 0, "C: no byte carry");

	c.sp = 0x0001;
	c.add_sp_e8(-1);
	test::eq((ushort)0x0000, c.sp);
}

// ---------------------------------------------------------------------------
// Control flow  (PC is assumed already past the instruction on entry)
// ---------------------------------------------------------------------------

fn void jr_relative() @test
{
	cpu::Cpu c = cpu::init();
	c.pc = 0x0200;
	c.jr_n16(-5);
	test::eq((ushort)0x01FB, c.pc);

	c.pc = 0x0200;
	c.jr_n16(0x10);
	test::eq((ushort)0x0210, c.pc);
}

fn void jr_cc_cycles_and_branch() @test
{
	cpu::Cpu c = cpu::init();
	c.pc = 0x0200;
	c.jr_cc_n16(false, 0x10);
	test::eq((ushort)0x0200, c.pc);
	test::eq((char)2, c.required_cycles);

	c.jr_cc_n16(true, 0x10);
	test::eq((ushort)0x0210, c.pc);
	test::eq((char)3, c.required_cycles);
}

fn void call_then_ret() @test
{
	cpu::Cpu c = cpu::init();
	mmu::Mmu m;
	c.sp = 0xFFFE;
	c.pc = 0x0150; // "next instruction" address

	c.call_n16(&m, 0x4000);
	test::eq((ushort)0x4000, c.pc);
	test::eq((ushort)0xFFFC, c.sp);

	c.ret(&m);
	test::eq((ushort)0x0150, c.pc);
	test::eq((ushort)0xFFFE, c.sp);
}

fn void call_cc_not_taken() @test
{
	cpu::Cpu c = cpu::init();
	mmu::Mmu m;
	c.sp = 0xFFFE;
	c.pc = 0x0150;

	c.call_cc_n16(&m, false, 0x4000);
	test::eq((ushort)0x0150, c.pc);
	test::eq((ushort)0xFFFE, c.sp); // nothing pushed
	test::eq((char)3, c.required_cycles);
}

fn void reti_sets_ime() @test
{
	cpu::Cpu c = cpu::init();
	mmu::Mmu m;
	c.sp = 0xFFFE;
	c.pc = 0x0150;
	c.ime = false;
	c.call_n16(&m, 0x4000);

	c.reti(&m);
	test::eq((ushort)0x0150, c.pc);
	test::@check(c.ime, "RETI enables interrupts");
}

fn void rst_pushes_and_jumps() @test
{
	cpu::Cpu c = cpu::init();
	mmu::Mmu m;
	c.sp = 0xFFFE;
	c.pc = 0x0150;

	c.rst_vec(&m, 0x38);
	test::eq((ushort)0x0038, c.pc);
	ushort ret = c.pop16(&m);
	test::eq((ushort)0x0150, ret);
}
