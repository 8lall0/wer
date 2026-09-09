module cpu;

import mmu;

fn char Cpu.step(&self, mmu::Mmu *mmu) {
	char ic = self.service_interrupt(mmu);
	if (ic > 0) {
		self.clk += ic;
		return ic;
	}

	if (self.halted || self.stopped) {
		self.clk += 1;
		return 1;
	}

	char op = self.fetch8(mmu);
	if (self.halt_bug) {
		// The HALT bug: the byte after HALT is read without advancing PC.
		self.pc--;
		self.halt_bug = false;
	}

	self.required_cycles = 1;
	self.execute(mmu, op);

	// A pending EI becomes effective one instruction after it ran.
	if (self.ime_delay > 0) {
		self.ime_delay--;
		if (self.ime_delay == 0) self.ime = true;
	}

	self.clk += self.required_cycles;
	return self.required_cycles;
}

fn void Cpu.illegal(&self, char op) {
	// Not a valid opcode. On hardware the CPU locks up; approximate with STOP.
	self.stopped = true;
	self.required_cycles = 1;
}

// The 8 ALU operations selected by bits 3..5 of the 0x80-0xBF range and by
// the 0xC6/0xCE/0xD6/0xDE/0xE6/0xEE/0xF6/0xFE immediate opcodes.
fn void Cpu.alu(&self, char sel, char v) {
	switch (sel & 7) {
		case 0: self.add_a(v, 0);                    // ADD
		case 1: self.add_a(v, self.getFlag(C));      // ADC
		case 2: self.af.hi = self.sub_a(v, 0);       // SUB
		case 3: self.af.hi = self.sub_a(v, self.getFlag(C)); // SBC
		case 4: self.and_a(v);                       // AND
		case 5: self.xor_a(v);                       // XOR
		case 6: self.or_a(v);                        // OR
		case 7: self.sub_a(v, 0);                    // CP (result discarded)
	}
}

fn void Cpu.execute(&self, mmu::Mmu *mmu, char op) {
	// --- Quadrant 1: LD r,r  (0x40-0x7F, with 0x76 == HALT) ---
	if (op >= 0x40 && op <= 0x7F) {
		if (op == 0x76) {
			self.halt(mmu);
			return;
		}
		self.write_r8(mmu, op >> 3, self.read_r8(mmu, op));
		self.required_cycles = (self.r8_is_mem(op) || self.r8_is_mem(op >> 3)) ? 2 : 1;
		return;
	}

	// --- Quadrant 2: <alu> A,r  (0x80-0xBF) ---
	if (op >= 0x80 && op <= 0xBF) {
		self.alu(op >> 3, self.read_r8(mmu, op));
		self.required_cycles = self.r8_is_mem(op) ? 2 : 1;
		return;
	}

	switch (op) {
		// ================= 0x00 - 0x3F =================
		case 0x00: self.nop();
		case 0x01: self.ld_r16_n16(&self.bc, self.fetch16(mmu));
		case 0x02: self.ld_r16_a(mmu, &self.bc);
		case 0x03: self.inc_r16(&self.bc);
		case 0x04: self.inc_r8(&self.bc.hi);
		case 0x05: self.dec_r8(&self.bc.hi);
		case 0x06: self.ld_r8_n8(&self.bc.hi, self.fetch8(mmu));
		case 0x07: self.rlca();
		case 0x08: self.ld_n16_sp(mmu, self.fetch16(mmu));
		case 0x09: self.add_hl_r16(&self.bc);
		case 0x0A: self.ld_a_r16(mmu, &self.bc);
		case 0x0B: self.dec_r16(&self.bc);
		case 0x0C: self.inc_r8(&self.bc.lo);
		case 0x0D: self.dec_r8(&self.bc.lo);
		case 0x0E: self.ld_r8_n8(&self.bc.lo, self.fetch8(mmu));
		case 0x0F: self.rrca();

		case 0x10: self.fetch8(mmu); self.stop(mmu); // STOP: consume the $00 pad byte
		case 0x11: self.ld_r16_n16(&self.de, self.fetch16(mmu));
		case 0x12: self.ld_r16_a(mmu, &self.de);
		case 0x13: self.inc_r16(&self.de);
		case 0x14: self.inc_r8(&self.de.hi);
		case 0x15: self.dec_r8(&self.de.hi);
		case 0x16: self.ld_r8_n8(&self.de.hi, self.fetch8(mmu));
		case 0x17: self.rla();
		case 0x18: self.jr_n16((ichar)self.fetch8(mmu));
		case 0x19: self.add_hl_r16(&self.de);
		case 0x1A: self.ld_a_r16(mmu, &self.de);
		case 0x1B: self.dec_r16(&self.de);
		case 0x1C: self.inc_r8(&self.de.lo);
		case 0x1D: self.dec_r8(&self.de.lo);
		case 0x1E: self.ld_r8_n8(&self.de.lo, self.fetch8(mmu));
		case 0x1F: self.rra();

		case 0x20: self.jr_cc_n16(self.cond(0), (ichar)self.fetch8(mmu));
		case 0x21: self.ld_r16_n16(&self.hl, self.fetch16(mmu));
		case 0x22: self.ld_hli_a(mmu);
		case 0x23: self.inc_r16(&self.hl);
		case 0x24: self.inc_r8(&self.hl.hi);
		case 0x25: self.dec_r8(&self.hl.hi);
		case 0x26: self.ld_r8_n8(&self.hl.hi, self.fetch8(mmu));
		case 0x27: self.daa();
		case 0x28: self.jr_cc_n16(self.cond(1), (ichar)self.fetch8(mmu));
		case 0x29: self.add_hl_r16(&self.hl);
		case 0x2A: self.ld_a_hli(mmu);
		case 0x2B: self.dec_r16(&self.hl);
		case 0x2C: self.inc_r8(&self.hl.lo);
		case 0x2D: self.dec_r8(&self.hl.lo);
		case 0x2E: self.ld_r8_n8(&self.hl.lo, self.fetch8(mmu));
		case 0x2F: self.cpl();

		case 0x30: self.jr_cc_n16(self.cond(2), (ichar)self.fetch8(mmu));
		case 0x31: self.ld_sp_n16(self.fetch16(mmu));
		case 0x32: self.ld_hld_a(mmu);
		case 0x33: self.inc_sp();
		case 0x34: self.inc_hl(mmu);
		case 0x35: self.dec_hl(mmu);
		case 0x36: self.ld_hl_n8(mmu, self.fetch8(mmu));
		case 0x37: self.scf();
		case 0x38: self.jr_cc_n16(self.cond(3), (ichar)self.fetch8(mmu));
		case 0x39: self.add_hl_sp();
		case 0x3A: self.ld_a_hld(mmu);
		case 0x3B: self.dec_sp();
		case 0x3C: self.inc_r8(&self.af.hi);
		case 0x3D: self.dec_r8(&self.af.hi);
		case 0x3E: self.ld_r8_n8(&self.af.hi, self.fetch8(mmu));
		case 0x3F: self.ccf();

		// ================= 0xC0 - 0xFF =================
		case 0xC0: self.ret_cc(mmu, self.cond(0));
		case 0xC1: self.pop_r16(mmu, &self.bc);
		case 0xC2: self.jp_cc_n16(self.cond(0), self.fetch16(mmu));
		case 0xC3: self.jp_n16(self.fetch16(mmu));
		case 0xC4: self.call_cc_n16(mmu, self.cond(0), self.fetch16(mmu));
		case 0xC5: self.push_r16(mmu, &self.bc);
		case 0xC6: self.add_a_n8(self.fetch8(mmu));
		case 0xC7: self.rst_vec(mmu, 0x00);
		case 0xC8: self.ret_cc(mmu, self.cond(1));
		case 0xC9: self.ret(mmu);
		case 0xCA: self.jp_cc_n16(self.cond(1), self.fetch16(mmu));
		case 0xCB: self.execute_cb(mmu, self.fetch8(mmu));
		case 0xCC: self.call_cc_n16(mmu, self.cond(1), self.fetch16(mmu));
		case 0xCD: self.call_n16(mmu, self.fetch16(mmu));
		case 0xCE: self.adc_a_n8(self.fetch8(mmu));
		case 0xCF: self.rst_vec(mmu, 0x08);

		case 0xD0: self.ret_cc(mmu, self.cond(2));
		case 0xD1: self.pop_r16(mmu, &self.de);
		case 0xD2: self.jp_cc_n16(self.cond(2), self.fetch16(mmu));
		case 0xD3: self.illegal(op);
		case 0xD4: self.call_cc_n16(mmu, self.cond(2), self.fetch16(mmu));
		case 0xD5: self.push_r16(mmu, &self.de);
		case 0xD6: self.sub_a_n8(self.fetch8(mmu));
		case 0xD7: self.rst_vec(mmu, 0x10);
		case 0xD8: self.ret_cc(mmu, self.cond(3));
		case 0xD9: self.reti(mmu);
		case 0xDA: self.jp_cc_n16(self.cond(3), self.fetch16(mmu));
		case 0xDB: self.illegal(op);
		case 0xDC: self.call_cc_n16(mmu, self.cond(3), self.fetch16(mmu));
		case 0xDD: self.illegal(op);
		case 0xDE: self.sbc_a_n8(self.fetch8(mmu));
		case 0xDF: self.rst_vec(mmu, 0x18);

		case 0xE0: self.ldh_n16_a(mmu, (ushort)self.fetch8(mmu));
		case 0xE1: self.pop_r16(mmu, &self.hl);
		case 0xE2: self.ldh_c_a(mmu);
		case 0xE3: self.illegal(op);
		case 0xE4: self.illegal(op);
		case 0xE5: self.push_r16(mmu, &self.hl);
		case 0xE6: self.and_a_n8(self.fetch8(mmu));
		case 0xE7: self.rst_vec(mmu, 0x20);
		case 0xE8: self.add_sp_e8((ichar)self.fetch8(mmu));
		case 0xE9: self.jp_hl();
		case 0xEA: self.ld_n16_a(mmu, self.fetch16(mmu));
		case 0xEB: self.illegal(op);
		case 0xEC: self.illegal(op);
		case 0xED: self.illegal(op);
		case 0xEE: self.xor_a_n8(self.fetch8(mmu));
		case 0xEF: self.rst_vec(mmu, 0x28);

		case 0xF0: self.ldh_a_n16(mmu, (ushort)self.fetch8(mmu));
		case 0xF1: self.pop_af(mmu);
		case 0xF2: self.ldh_a_c(mmu);
		case 0xF3: self.di();
		case 0xF4: self.illegal(op);
		case 0xF5: self.push_af(mmu);
		case 0xF6: self.or_a_n8(self.fetch8(mmu));
		case 0xF7: self.rst_vec(mmu, 0x30);
		case 0xF8: self.ld_hl_sp_e8((ichar)self.fetch8(mmu));
		case 0xF9: self.ld_sp_hl();
		case 0xFA: self.ld_a_n16(mmu, self.fetch16(mmu));
		case 0xFB: self.ei();
		case 0xFC: self.illegal(op);
		case 0xFD: self.illegal(op);
		case 0xFE: self.cp_a_n8(self.fetch8(mmu));
		case 0xFF: self.rst_vec(mmu, 0x38);

		default: self.illegal(op);
	}
}

// 0xCB-prefixed: rotate/shift (0x00-0x3F), BIT (0x40-0x7F), RES (0x80-0xBF),
// SET (0xC0-0xFF). The target r8 is bits 0..2, the bit index is bits 3..5.
fn void Cpu.execute_cb(&self, mmu::Mmu *mmu, char op) {
	char n = (op >> 3) & 7;
	char kind = op >> 6; // 0 rot/shift, 1 BIT, 2 RES, 3 SET

	if (kind == 1) {
		// BIT does not write the operand back; the existing methods set cycles.
		if (self.r8_is_mem(op)) {
			self.bit_u3_hl(mmu, n);
		} else {
			self.bit_u3_r8(self.r8_ptr(op), n);
		}
		return;
	}

	char v = self.read_r8(mmu, op);
	char result = v;

	if (kind == 2) {
		result = (char)(v & ~(1 << n)); // RES
	} else if (kind == 3) {
		result = (char)(v | (1 << n)); // SET
	} else {
		switch (op >> 3) { // 0..7
			case 0: result = self.rlc_value(v);
			case 1: result = self.rrc_value(v);
			case 2: result = self.rl_value(v);
			case 3: result = self.rr_value(v);
			case 4: result = self.sla_value(v);
			case 5: result = self.sra_value(v);
			case 6: result = self.swap_value(v);
			case 7: result = self.srl_value(v);
			default: break;
		}
	}

	self.write_r8(mmu, op, result);
	self.required_cycles = self.r8_is_mem(op) ? 4 : 2;
}
