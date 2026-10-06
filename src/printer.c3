module mmu;
import std::collections::list;

// The Game Boy Printer on the link cable, after SameBoy (MIT: see
// LICENSE-sameboy). The Game Boy clocks every byte; the printer answers each
// with what it decided after the one before. A packet:
//
//   $88 $33  command  compression  length (16 bits)  data  checksum (16 bits)  $00 $00
//
// answered $81 ("here") on the first $00 and with the status on the second.
// Commands: 1 initialise, 2 print (margins, palette, exposure), 4 data (two
// rows of 20 tiles, 640 bytes, maybe run-length compressed), 15 status.
// Printed rows go onto the paper; a print with a margin after it ends the
// page, which the frontend then takes (Printer.take_page).

const usz PRINTER_DATA = 0x280;
const int PAPER_W = 160;

enum PrinterState : char {
	MAGIC1,
	MAGIC2,
	COMMAND,
	COMPRESSION,
	LENGTH_LOW,
	LENGTH_HIGH,
	DATA,
	CHECKSUM_LOW,
	CHECKSUM_HIGH,
	ACTIVE,
	STATUS,
}

const char PRINTER_INIT  = 1;
const char PRINTER_PRINT = 2;
const char PRINTER_DATA_CMD = 4;

// Status bits.
const char PRINTER_BAD_CHECKSUM = 0x01;
const char PRINTER_PRINTING     = 0x02;
const char PRINTER_DONE         = 0x04;
const char PRINTER_UNPRINTED    = 0x08;

// Rows printed per second: a whole Game Boy screen in four and a half.
const ulong PRINTER_ROWS_PER_SEC = 32;
// No byte for this long in the middle of a packet: start over.
const ulong PRINTER_TIMEOUT_SEC = 1;
// A page with no margin after its last print is done after this long.
const ulong PRINTER_PAGE_SEC = 5;

struct Printer {
	PrinterState state;
	char      command;
	bool      compressed;
	ushort    length_left;
	char[PRINTER_DATA] data;
	usz       data_len;
	ushort    checksum;
	char      status;
	char      reply;          // the answer to the next byte
	char      run_left;       // compression: bytes left in this run
	bool      run_repeat;     // ... the run repeats one byte
	ulong     last_byte;      // rt_clock of the last byte
	ulong     busy_until;     // printing until this rt_clock
	ulong     last_print;
	uint      hz;             // rt_clock per second

	// The rows the data commands sent since the last print (shades 0-3).
	char[PAPER_W * 200] image;
	usz       image_len;

	// The paper coming out: shades 0 (white) - 3 (black), PAPER_W a row.
	List{char} paper;
	bool      page_done;
}

fn void Printer.init(&self, uint hz) {
	*self = { .hz = hz };
	self.paper.init(mem);
}

fn void Printer.free(&self) => self.paper.free();

// One byte from the Game Boy; the printer's answer to it.
fn char Printer.exchange(&self, char b, ulong now) {
	if (self.state != MAGIC1 && now - self.last_byte > PRINTER_TIMEOUT_SEC * self.hz) self.state = MAGIC1;
	self.last_byte = now;
	char answer = self.reply;
	self.receive(b, now);
	return answer;
}

fn void Printer.receive(&self, char b, ulong now) {
	self.reply = 0;
	switch (self.state) {
		case MAGIC1:
			if (b != 0x88) return;
			self.status &= (char)~PRINTER_BAD_CHECKSUM;
			self.data_len = 0;
			self.checksum = 0;
			self.run_left = 0;
		case MAGIC2:
			if (b != 0x33) {
				if (b != 0x88) self.state = MAGIC1;
				return;
			}
		case COMMAND:      self.command = b & 0x0F;
		case COMPRESSION:  self.compressed = (b & 1) != 0;
		case LENGTH_LOW:   self.length_left = b;
		case LENGTH_HIGH:  self.length_left |= (ushort)(b & 3) << 8;
		case DATA:
			self.take_data(b);
			self.length_left--;
		case CHECKSUM_LOW: self.checksum ^= b;
		case CHECKSUM_HIGH:
			self.checksum ^= (ushort)b << 8;
			if (self.checksum) {
				self.status |= PRINTER_BAD_CHECKSUM;
				self.state = MAGIC1;
				return;
			}
			self.reply = 0x81;
		case ACTIVE:
			if (self.command == PRINTER_INIT) {
				self.reply = 0; // games expect 0 after initialising
			} else {
				if ((self.status & PRINTER_PRINTING) && now >= self.busy_until) {
					self.status = (self.status & (char)~PRINTER_PRINTING) | PRINTER_DONE;
				}
				self.reply = self.status;
			}
		case STATUS:
			self.state = MAGIC1;
			self.run(now);
			return;
	}
	if (self.state >= COMMAND && self.state < CHECKSUM_LOW) self.checksum += b;
	if (self.state != DATA) self.state = (PrinterState)(self.state.ordinal + 1);
	if (self.state == DATA && self.length_left == 0) self.state = CHECKSUM_LOW;
}

fn void Printer.take_data(&self, char b) {
	if (self.data_len == PRINTER_DATA) return;
	if (!self.compressed) {
		self.data[self.data_len++] = b;
		return;
	}
	if (!self.run_left) {
		self.run_repeat = (b & 0x80) != 0;
		self.run_left = (b & 0x7F) + 1 + (self.run_repeat ? 1 : 0);
	} else if (self.run_repeat) {
		while (self.run_left && self.data_len < PRINTER_DATA) {
			self.data[self.data_len++] = b;
			self.run_left--;
		}
		self.run_left = 0;
	} else {
		self.data[self.data_len++] = b;
		self.run_left--;
	}
}

// A packet in full: act on it.
fn void Printer.run(&self, ulong now) {
	switch (self.command) {
		case PRINTER_INIT:
			self.status = 0;
			self.image_len = 0;
		case PRINTER_DATA_CMD:
			if (self.data_len != PRINTER_DATA) return;
			self.status |= PRINTER_UNPRINTED;
			if (self.image_len + PAPER_W * 16 > self.image.len) self.image_len = 0;
			// Two rows of 20 tiles, 2 bits a pixel.
			for (int row = 0; row < 2; row++) {
				for (int tile = 0; tile < 20; tile++) {
					for (int y = 0; y < 8; y++) {
						char lo = self.data[(row * 20 + tile) * 16 + y * 2];
						char hi = self.data[(row * 20 + tile) * 16 + y * 2 + 1];
						for (int x = 0; x < 8; x++) {
							char shade = ((lo >> (7 - x)) & 1) | (((hi >> (7 - x)) & 1) << 1);
							self.image[self.image_len + (usz)(y * PAPER_W + tile * 8 + x)] = shade;
						}
					}
				}
				self.image_len += PAPER_W * 8;
			}
		case PRINTER_PRINT:
			if (self.data_len != 4) return;
			char margins = self.data[1];
			char palette = self.data[2];
			// A margin before: the paper feeds (blank rows) first.
			for (int i = 0; i < (margins >> 4) * 8; i++) {
				for (int x = 0; x < PAPER_W; x++) self.paper.push(0);
			}
			foreach (s : self.image[:self.image_len]) self.paper.push((palette >> (s * 2)) & 3);
			ulong rows = self.image_len / PAPER_W;
			self.image_len = 0;
			self.status = (self.status & (char)~(PRINTER_UNPRINTED | PRINTER_DONE)) | PRINTER_PRINTING;
			self.busy_until = now + rows * self.hz / PRINTER_ROWS_PER_SEC;
			self.last_print = now;
			if (margins & 0x0F) self.page_done = true;
		default:
			break;
	}
}

// The finished page, if there is one (`now`: a page without a closing
// margin is done once the printer has been still for a while). Rows of
// PAPER_W shades; the caller clears it with clear_page.
fn char[] Printer.take_page(&self, ulong now) {
	if (!self.paper.len()) return {};
	if (!self.page_done && now - self.last_print < PRINTER_PAGE_SEC * self.hz) return {};
	return self.paper.array_view();
}

fn void Printer.clear_page(&self) {
	self.paper.clear();
	self.page_done = false;
}

// Plug the printer into this Game Boy's link port.
fn void Mmu.connect_printer(&self, Link* l, Printer* p) {
	*l = { .printer = p };
	self.link = l;
}
