module mmu;

// The DMG-07 4-Player Adapter (Pan Docs, and Shonumi's "Edge of Emulation"
// write-up). It clocks every transfer; the four Game Boys wait for it with
// an external clock (SC = $80). Each byte it sends to all four at once, and
// takes each one's SB in exchange (Mmu.link_take).
//
// Ping phase: packets of 4 bytes, $FE then three status bytes (bits 4-7: the
// players connected, bits 0-2: the player's own number). A Game Boy answers
// $88 $88 (it's there), then the rate and the packet size it wants (player
// 1's count). Four $AA from player 1 in place of a packet ask for the
// transmission phase; the adapter answers four $CC.
//
// Transmission phase: packets of SIZE x 4 bytes. In each, every Game Boy
// sends its SIZE bytes first, while the adapter sends everyone what it
// collected in the packet before: player 1's bytes, then 2's, 3's, 4's
// (zeros for a missing player). Three $FF from player 1 go back to ping,
// after a packet of $FF.

enum AdapterPhase : char {
	PING,
	CONFIRM,    // four $CC, then transmission
	TRANSMIT,
	RESTART,    // a packet of $FF, then ping
}

const ulong ADAPTER_PING_BYTE_US  = 4000; // ~256 bytes a second
const ulong ADAPTER_DATA_BYTE_US  = 1000; // ~1 KB a second
const ulong ADAPTER_PACKET_GAP_US = 12200;

struct Adapter {
	AdapterPhase phase;
	int   index;            // byte in the packet
	ulong next_at;          // rt_clock of the next transfer
	uint  hz;               // rt_clock per second
	char  connected;        // bits 4-7: players 1-4
	char  pending;          // ... as this ping packet finds them
	char  rate;
	int   size;             // bytes per player in a packet
	char  new_rate;         // ... as player 1 answers this ping packet
	int   new_size;
	int   aa;               // $AA from player 1 in a row
	int   ff;               // $FF from player 1 in a row
	char[4 * 255] collect;  // this packet's bytes, by player
	char[4 * 255] out;      // last packet's, to send
}

fn void Adapter.init(&self, uint hz) {
	*self = { .hz = hz, .size = 1 };
}

fn ulong Adapter.us(&self, ulong us) => us * self.hz / 1_000_000;

fn int Adapter.packet_len(&self) {
	switch (self.phase) {
		case TRANSMIT: return self.size * 4;
		case RESTART:  return self.size * 4;
		default:       return 4;
	}
}

// The byte the adapter sends player `p` (0-3) at this point of the packet.
fn char Adapter.byte_for(&self, int p) {
	switch (self.phase) {
		case PING:
			if (self.index == 0) return 0xFE;
			return self.connected | (char)(p + 1);
		case CONFIRM:  return 0xCC;
		case RESTART:  return 0xFF;
		case TRANSMIT: return self.out[self.index];
	}
}

// Time `now` on player 1's clock: the transfers due by now, to all four.
fn void Adapter.tick(&self, Mmu*[4] gbs, ulong now) {
	while (now >= self.next_at) {
		int[4] got;
		for (int p = 0; p < 4; p++) {
			got[p] = gbs[p] ? gbs[p].link_take(self.byte_for(p)) : -1;
		}
		self.receive(got);
		self.index++;
		ulong byte_us = self.phase == TRANSMIT ? ADAPTER_DATA_BYTE_US : ADAPTER_PING_BYTE_US;
		if (self.index < self.packet_len()) {
			self.next_at += self.us(byte_us);
		} else {
			self.index = 0;
			self.end_packet();
			self.next_at += self.us(ADAPTER_PACKET_GAP_US + (ulong)(self.rate & 0x0F) * 1000);
		}
	}
}

// What the four sent for the byte at `index` (-1: not waiting for it).
fn void Adapter.receive(&self, int[4] got) {
	int p1 = got[0];
	switch (self.phase) {
		case PING:
			if (p1 == 0xAA) {
				self.aa++;
			} else {
				self.aa = 0;
			}
			for (int p = 0; p < 4; p++) {
				char bit = (char)(0x10 << p);
				switch (self.index) {
					case 0:
					case 1:
						if (got[p] == 0x88) {
							if (self.index == 0) self.pending |= bit;
						} else {
							self.pending &= ~bit;
						}
					case 2: if (p == 0 && got[p] >= 0) self.new_rate = (char)got[p];
					case 3: if (p == 0 && got[p] > 0) self.new_size = got[p];
				}
			}
		case TRANSMIT:
			if (self.index < self.size) {
				for (int p = 0; p < 4; p++) {
					self.collect[p * self.size + self.index] = got[p] >= 0 && (self.connected & (0x10 << p)) ? (char)got[p] : 0;
				}
			}
			if (p1 == 0xFF) {
				self.ff++;
			} else {
				self.ff = 0;
			}
		default:
			break;
	}
}

fn void Adapter.end_packet(&self) {
	switch (self.phase) {
		case PING:
			if (self.aa >= 4) {
				self.phase = CONFIRM;
			} else {
				self.connected = self.pending;
				// Player 1's rate and size count once it answered the packet.
				if ((self.pending & 0x10) && self.new_size) {
					self.rate = self.new_rate;
					self.size = self.new_size;
				}
			}
			self.new_size = 0;
			self.pending = 0;
			self.aa = 0;
		case CONFIRM:
			self.phase = TRANSMIT;
			self.out[..] = 0;
			self.collect[..] = 0;
			self.ff = 0;
		case TRANSMIT:
			if (self.ff >= 3) {
				self.phase = RESTART;
			} else {
				int n = self.size * 4;
				self.out[:n] = self.collect[:n];
				self.collect[:n] = 0;
			}
		case RESTART:
			self.phase = PING;
			self.ff = 0;
	}
}
