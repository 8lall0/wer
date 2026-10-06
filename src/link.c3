module mmu;

// The link cable. A transfer is clocked by one side (SC = $81, the master)
// and the other waits for it (SC = $80); here a transfer swaps whole bytes
// when the master's eight clock pulses are done, as BGB's link protocol does,
// rather than bit by bit.
//
// The other end is either a Game Boy in this process (`peer`), or one over
// the network: then the master's byte waits in `out_*` for the frontend to
// send it, and the transfer only ends when the answer comes back
// (Mmu.link_answer). A slave the master's byte reaches through the network
// takes it with Mmu.link_take.

struct Link {
	Mmu* peer;          // the other Game Boy here, or null: over the network
	Printer* printer;   // ... or the Game Boy Printer (printer.c3)
	bool out_pending;   // network: a byte to send for a transfer this side clocks
	char out_byte;
	char out_control;   // SC as written (bit 1: the CGB's fast clock)
	bool in_ready;      // network: the answer, if it came before the eighth pulse
	char in_byte;
}

// Connect two Game Boys in this process (both Links must stay where they are).
fn void connect_local(Mmu* a, Link* la, Mmu* b, Link* lb) {
	*la = { .peer = b };
	*lb = { .peer = a };
	a.link = la;
	b.link = lb;
}

fn void Mmu.unplug(&self) {
	self.link = null;
	self.serial_waiting = false;
}

// SC = $81: a transfer this side clocks starts.
fn void Mmu.link_start(&self) {
	if (!self.link || self.link.peer || self.link.printer) return;
	self.link.out_pending = true;
	self.link.out_byte = self.io[0x01];
	self.link.out_control = self.io[0x02];
	self.link.in_ready = false;
}

// The eighth clock pulse of this side's transfer: the byte from the other
// side, or -1 while it hasn't come yet.
fn int Mmu.link_exchange(&self) {
	Link* l = self.link;
	if (l.printer) return l.printer.exchange(self.serial_out, self.rt_clock);
	if (l.peer) return l.peer.link_take(self.serial_out);
	if (!l.in_ready) return -1;
	l.in_ready = false;
	return l.in_byte;
}

// The master's byte arriving: a slave waiting for it takes it and gives its
// own, finishing its transfer; otherwise -1 (nothing shifts, the master
// reads $FF).
fn int Mmu.link_take(&self, char b) {
	if ((self.io[0x02] & 0x81) != 0x80) return -1;
	char mine = self.io[0x01];
	self.io[0x01] = b;
	self.io[0x02] &= 0x7F;
	self.io[IF_REG - 0xFF00] |= 0x08;
	return mine;
}

// Network: the other side's answer to this side's transfer (-1: it wasn't
// waiting, so $FF).
fn void Mmu.link_answer(&self, int b) {
	char v = b < 0 ? 0xFF : (char)b;
	if (self.serial_waiting) {
		self.serial_waiting = false;
		self.serial_finish(v);
	} else if (self.serial_active) {
		self.link.in_ready = true;
		self.link.in_byte = v;
	}
}

fn void Mmu.serial_finish(&self, char received) {
	self.io[0x01] = received;
	self.serial_active = false;
	self.io[0x02] &= 0x7F;
	self.io[IF_REG - 0xFF00] |= 0x08;
}
