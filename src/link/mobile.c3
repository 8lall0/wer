module mmu;
import std::io;

// The Mobile Adapter GB (CGB-005): a Japanese mobile phone on the link port,
// for Pocket Monsters Crystal, Mobile Trainer, Net de Get and others. The
// game sends it commands in packets and it dials, logs in to the ISP, opens
// TCP connections and carries their data. Written from the protocol as Dan
// Docs describes it (shonumi.github.io/dandocs.html#magb); where that says
// nothing, behaviour as libmobile (REON) has it, which was checked against
// real adapters.
//
// A packet, either way: $99 $66, command, $00, length (high, always 0),
// length, the data, a 16-bit big-endian sum of the four header bytes and the
// data, then two bytes of acknowledgement both sides exchange at once: the
// device ($80 | id) and, from the receiver, the command ^ $80 (or an error:
// $F0 unknown command, $F1 bad sum, $F2 busy). The game clocks every byte;
// while it sends the adapter answers $D2, while it waits for the reply it
// sends $4B. The reply's command is the request's | $80, or $EE (error, with
// the command and a code) when it failed.
//
// Each answer comes a byte late: the adapter shifts out its answer to a
// byte while the next one comes in.
//
// The phone line: a call to the ISP's number (#9677 ...) and a login give
// the internet; any other 12 digits call another adapter at that IP address
// (127000000001 = 127.0.0.1) on port 1027 directly, as libmobile does, and
// waiting for a call listens there. The sockets are the frontend's
// (MobileNet); the original servers are gone, so DNS asks the servers the
// player set (a REON server's), not the computer's.

const char MOBILE_IDLE = 0xD2;     // the adapter's byte with nothing to say
const char MOBILE_GB_IDLE = 0x4B;  // the Game Boy's, waiting for a reply

// The adapters (the id in the acknowledgement). Each phone network had its own.
const char MOBILE_BLUE = 0x08;     // PDC
const char MOBILE_YELLOW = 0x09;   // cdmaOne
const char MOBILE_RED = 0x0B;      // DDI

const char MOBILE_ERR_COMMAND = 0xF0;
const char MOBILE_ERR_SUM = 0xF1;
const char MOBILE_ERR_BUSY = 0xF2;

const char MA_NULL = 0x0F;
const char MA_BEGIN = 0x10;
const char MA_END = 0x11;
const char MA_DIAL = 0x12;
const char MA_HANG_UP = 0x13;
const char MA_WAIT_CALL = 0x14;
const char MA_DATA = 0x15;
const char MA_RESET = 0x16;
const char MA_STATUS = 0x17;
const char MA_SIO32 = 0x18;
const char MA_READ_CONFIG = 0x19;
const char MA_WRITE_CONFIG = 0x1A;
const char MA_DATA_END = 0x1F;     // reply only: the other side closed
const char MA_LOGIN = 0x21;
const char MA_LOGOUT = 0x22;
const char MA_TCP_OPEN = 0x23;
const char MA_TCP_CLOSE = 0x24;
const char MA_UDP_OPEN = 0x25;
const char MA_UDP_CLOSE = 0x26;
const char MA_DNS = 0x28;
const char MA_FIRMWARE = 0x3F;
const char MA_ERROR = 0x6E;

const int MOBILE_CONNS = 2;        // the game's connections at once
const int MOBILE_DNS_CONN = 2;     // the adapter's own, for DNS
const int MOBILE_P2P_PORT = 1027;
const int MOBILE_DNS_PORT = 53;
const int MOBILE_CONFIG_SIZE = 256;
const int MOBILE_MAX_DATA = 254;   // a reply's data after its connection byte

// The ISP's numbers (DION): calls to them reach the internet.
const String[5] MOBILE_ISP_NUMBERS = { "#9677", "#9477", "0077487751", "0077487752", "0755311973" };

// The network, the frontend's sockets (conn 0-1: the game's, 2: DNS).
interface MobileNet {
	// A socket for `conn`, TCP or UDP; with `bind_port`, bound to it.
	fn bool open(int conn, bool udp, int bind_port);
	fn bool listen(int conn);
	// A call to the listening `conn` came in: it is now that call.
	fn bool accept(int conn);
	// 1 connected, 0 not yet, -1 failed.
	fn int connect(int conn, char[4] ip, int port);
	// Bytes sent (0: none yet), -1 failed.
	fn int send(int conn, char[] data);
	// Bytes received (0: none yet), -1 failed, -2 closed by the other side.
	fn int recv(int conn, char[] buf);
	fn void close(int conn);
}

enum MobileSerial : char {
	MAGIC,          // waiting for $99 $66
	HEADER,
	DATA,
	CHECKSUM,
	ACK,            // the Game Boy's id coming in, our answer going out
	IDLE_CHECK,     // one byte, then $4B: the game waits for the reply
	BUSY,           // working on it: $D2 until the reply is ready
	REPLY_MAGIC,
	REPLY_HEADER,
	REPLY_DATA,
	REPLY_CHECKSUM,
	REPLY_ACK,
}

enum MobileLine : char {
	HUNG_UP,
	WAITING,    // listening for a call
	CALLING,    // in a call this adapter made
	ANSWERED,   // in a call it picked up
	ISP,        // called the ISP, not logged in
	ONLINE,     // logged in: TCP, UDP, DNS
}

struct MobileAdapter {
	MobileNet net;
	uint      hz;            // rt_clock per second
	char      device;        // MOBILE_BLUE ...
	bool      unmetered;     // the phone's plan: Crystal's battle time limit is lifted
	char[MOBILE_CONFIG_SIZE] config; // its memory, set up by Mobile Trainer
	bool      config_changed;
	char[4]   dns1;          // the player's DNS servers (0.0.0.0: none)
	char[4]   dns2;
	int       dns_port;
	int       p2p_port;

	// The cable.
	MobileSerial serial;
	char      answer;        // the byte the next transfer gets
	int       pos;
	char      command;       // the packet's, then the reply's
	int       length;
	char[256] data;
	ushort    sum;
	ushort    got_sum;
	char      error;
	ulong     last_byte;     // rt_clock of the last byte

	// The phone and the internet.
	bool      session;
	MobileLine line;
	bool[3]   open;          // each conn's socket
	char[4]   isp_dns1;      // the DNS servers the game logged in with
	char[4]   isp_dns2;
	bool      sio32;
	int       step;          // a command taking a while: how far it got
	ulong     step_at;
	int       sent;
	int       dns_try;
	ushort    dns_id;
	char[32]  number;        // the number of the call, for the frontend
	int       number_len;
	char[4]   call_ip;       // the number called, as an address
	int       opening;       // the conn being opened
	char[128] name;          // the name being looked up
	int       name_len;
	bool      trace;         // each command and its reply on stderr
}

fn void MobileAdapter.init(&self, MobileNet net, uint hz) {
	self.close_all();
	char[MOBILE_CONFIG_SIZE] config = self.config;
	char[4] dns1 = self.dns1;
	char[4] dns2 = self.dns2;
	int dns_port = self.dns_port;
	int p2p_port = self.p2p_port;
	char device = self.device;
	bool unmetered = self.unmetered;
	*self = { .net = net, .hz = hz, .config = config, .dns1 = dns1, .dns2 = dns2,
	          .dns_port = dns_port ? dns_port : MOBILE_DNS_PORT,
	          .p2p_port = p2p_port ? p2p_port : MOBILE_P2P_PORT,
	          .device = device ? device : MOBILE_BLUE, .unmetered = unmetered,
	          .answer = MOBILE_IDLE, .dns_id = 0x4D41 };
}

fn void Mmu.connect_mobile(&self, Link* l, MobileAdapter* m) {
	*l = { .mobile = m };
	self.link = l;
}

// The game has started a session (it found the adapter).
fn bool MobileAdapter.active(&self) => self.session;

// A byte the game clocks out: the answer to the one before.
fn char MobileAdapter.exchange(&self, char b, ulong now) {
	if (now - self.last_byte > 3 * (ulong)self.hz) self.time_out();
	self.last_byte = now;
	char out = self.answer;
	self.answer = self.receive(b, now);
	return out;
}

// Between frames: three seconds without a byte end the session, as the
// adapter goes to sleep.
fn void MobileAdapter.poll(&self, ulong now) {
	if ((self.session || self.serial != MAGIC) && now - self.last_byte > 3 * (ulong)self.hz) self.time_out();
}

fn void MobileAdapter.time_out(&self) {
	if (self.session) self.end_session();
	self.serial = MAGIC;
	self.pos = 0;
	self.answer = MOBILE_IDLE;
}

// Unplugged: everything closes.
fn void MobileAdapter.close_all(&self) {
	if (!self.net) return;
	for (int c = 0; c < self.open.len; c++) self.close(c);
	self.session = false;
	self.line = HUNG_UP;
}

fn void MobileAdapter.close(&self, int conn) {
	if (!self.open[conn]) return;
	self.net.close(conn);
	self.open[conn] = false;
}

fn bool mobile_known(char command) {
	switch (command) {
		case MA_NULL:
		case MA_BEGIN:
		case MA_END:
		case MA_DIAL:
		case MA_HANG_UP:
		case MA_WAIT_CALL:
		case MA_DATA:
		case MA_RESET:
		case MA_STATUS:
		case MA_SIO32:
		case MA_READ_CONFIG:
		case MA_WRITE_CONFIG:
		case MA_LOGIN:
		case MA_LOGOUT:
		case MA_TCP_OPEN:
		case MA_TCP_CLOSE:
		case MA_UDP_OPEN:
		case MA_UDP_CLOSE:
		case MA_DNS:
		case MA_FIRMWARE:
			return true;
		default:
			return false;
	}
}

// The game's byte in, the adapter's next one out.
fn char MobileAdapter.receive(&self, char b, ulong now) {
	switch (self.serial) {
		case MAGIC:
			if (b == 0x99) {
				self.pos = 1;
			} else if (b == 0x66 && self.pos == 1) {
				self.serial = HEADER;
				self.pos = 0;
				self.sum = 0;
				self.error = 0;
			} else {
				self.pos = 0;
			}
		case HEADER:
			self.sum += b;
			switch (self.pos++) {
				case 0: self.command = b;
				case 2: self.length = b << 8;
				case 3:
					self.length |= b;
					// Too long (it takes 255 bytes at most), or no session
					// yet and not the command that starts one: ignored.
					if (self.length > 0xFF || (!self.session && self.command != MA_BEGIN)) {
						self.serial = MAGIC;
						self.pos = 0;
						break;
					}
					if (!mobile_known(self.command)) self.error = MOBILE_ERR_COMMAND;
					self.pos = 0;
					self.serial = self.length ? DATA : CHECKSUM;
			}
		case DATA:
			self.data[self.pos++] = b;
			self.sum += b;
			if (self.pos == self.length) {
				self.pos = 0;
				self.serial = CHECKSUM;
			}
		case CHECKSUM:
			if (self.pos++ == 0) {
				self.got_sum = (ushort)b << 8;
				break;
			}
			if ((self.got_sum | b) != self.sum) self.error = MOBILE_ERR_SUM;
			self.serial = ACK;
			return self.device | 0x80;
		case ACK:
			// The Game Boy's id (a GBC's or a GBA's); the blue adapter
			// doesn't check it.
			if (self.device != MOBILE_BLUE && b != 0x80 && b != 0x81) {
				self.serial = MAGIC;
				self.pos = 0;
				break;
			}
			self.serial = IDLE_CHECK;
			self.pos = 1;
			return self.error ? self.error : self.command ^ 0x80;
		case IDLE_CHECK:
			if (self.pos) {
				self.pos = 0;
				break;
			}
			// An empty packet or one that failed has no reply.
			if (self.command == MA_NULL || self.error || b != MOBILE_GB_IDLE) {
				self.serial = MAGIC;
				self.pos = b == 0x99 ? 1 : 0;
				break;
			}
			self.serial = BUSY;
			self.step = 0;
			self.step_at = now;
			return self.busy(now);
		case BUSY:
			return self.busy(now);
		case REPLY_MAGIC:
			if (self.pos++ == 0) return 0x99;
			self.pos = 0;
			self.serial = REPLY_HEADER;
			return 0x66;
		case REPLY_HEADER:
			char[4] header = { self.command | 0x80, 0, 0, (char)self.length };
			char out = header[self.pos++];
			if (self.pos == 4) {
				self.pos = 0;
				self.serial = self.length ? REPLY_DATA : REPLY_CHECKSUM;
			}
			return out;
		case REPLY_DATA:
			char out = self.data[self.pos++];
			if (self.pos == self.length) {
				self.pos = 0;
				self.serial = REPLY_CHECKSUM;
			}
			return out;
		case REPLY_CHECKSUM:
			if (self.pos++ == 0) return (char)(self.sum >> 8);
			self.pos = 0;
			self.serial = REPLY_ACK;
			return (char)self.sum;
		case REPLY_ACK:
			switch (self.pos++) {
				case 0: return self.device | 0x80;
				case 1: return 0; // the game's id comes in
				default:
					// The game's answer: on an error, the reply again.
					self.pos = 0;
					self.serial = b == MOBILE_ERR_COMMAND || b == MOBILE_ERR_SUM || b == MOBILE_ERR_BUSY ? REPLY_MAGIC : MAGIC;
			}
	}
	return MOBILE_IDLE;
}

// The packet's command, worked on: the reply's first byte once it's done.
fn char MobileAdapter.busy(&self, ulong now) {
	char asked = self.command;
	int asked_len = self.length;
	if (!self.process(now)) return MOBILE_IDLE;
	if (self.trace) io::eprintfn("mobile: %02x (%d bytes) -> %02x %s", asked, asked_len, self.command | 0x80, self.command == MA_ERROR ? string::tformat("error %d", self.data[1]) : string::tformat("(%d bytes)", self.length));
	ushort sum = (ushort)((self.command | 0x80) + self.length);
	for (int i = 0; i < self.length; i++) sum += self.data[i];
	self.sum = sum;
	self.serial = REPLY_MAGIC;
	self.pos = 1;
	return 0x99;
}

fn bool MobileAdapter.ms_since(&self, ulong now, int ms) => now - self.step_at >= (ulong)ms * self.hz / 1000;

fn bool MobileAdapter.fail(&self, char code) {
	self.data[0] = self.command;
	self.data[1] = code;
	self.length = 2;
	self.command = MA_ERROR;
	return true;
}

fn bool MobileAdapter.reply(&self, int length) {
	self.length = length;
	return true;
}

fn void MobileAdapter.start_session(&self) {
	self.session = true;
	self.line = HUNG_UP;
}

fn void MobileAdapter.end_session(&self) {
	self.hang_up();
	self.close(0);
	self.session = false;
	self.sio32 = false;
}

// Logged out: the game's connections close.
fn bool MobileAdapter.log_out(&self) {
	if (self.line != ONLINE) return false;
	for (int c = 0; c < MOBILE_CONNS; c++) self.close(c);
	self.close(MOBILE_DNS_CONN);
	self.line = ISP;
	return true;
}

fn bool MobileAdapter.hang_up(&self) {
	self.log_out();
	if (self.line != CALLING && self.line != ANSWERED && self.line != ISP) return false;
	self.close(0);
	self.number_len = 0;
	self.line = HUNG_UP;
	return true;
}

// True when the reply is ready (in command, data, length).
fn bool MobileAdapter.process(&self, ulong now) {
	char[] data = self.data[:self.length];
	switch (self.command) {
		case MA_BEGIN:
			if (self.session) return self.fail(1);
			const String HELLO = "NINTENDO";
			const String HAPPY = "EVERYONE HAPPY MOBILE CONNECTION";
			if (self.device == MOBILE_RED && data.len > HELLO.len) data = data[:HELLO.len];
			if ((String)data != HELLO && (String)data != HAPPY) return self.fail(2);
			self.start_session();
			return self.reply(data.len);
		case MA_END:
			self.end_session();
			return self.reply(0);
		case MA_DIAL:
			return self.dial(now);
		case MA_HANG_UP:
			if (!self.hang_up()) return self.fail(1);
			return self.reply(0);
		case MA_WAIT_CALL:
			return self.wait_call(now);
		case MA_DATA:
			return self.transfer(now);
		case MA_RESET:
			self.end_session();
			self.start_session();
			return self.reply(0);
		case MA_STATUS:
			switch (self.line) {
				case CALLING:
				case ISP:
				case ONLINE:   self.data[0] = 4; // in a call
				case ANSWERED: self.data[0] = 5; // in a call that came in
				default:       self.data[0] = 0;
			}
			self.data[1] = self.device == MOBILE_BLUE ? 0x4D : 0x48;
			self.data[2] = self.unmetered ? 0xF0 : 0x00;
			return self.reply(3);
		case MA_SIO32:
			// The GBA's 32-bit transfers: told apart, never used here.
			if (data.len < 1 || data[0] > 1) return self.fail(2);
			self.sio32 = data[0] == 1;
			return self.reply(0);
		case MA_READ_CONFIG:
			if (data.len < 2) return self.fail(2);
			int offset = data[0];
			int size = data[1];
			if (size > 0x80 || offset + size > MOBILE_CONFIG_SIZE) return self.fail(2);
			self.data[1:size] = self.config[offset:size];
			return self.reply(size + 1);
		case MA_WRITE_CONFIG:
			if (data.len < 1) return self.fail(2);
			int offset = data[0];
			int size = data.len - 1;
			if (size > 0x80 || offset + size > MOBILE_CONFIG_SIZE) return self.fail(2);
			if (size) {
				self.config[offset:size] = data[1:size];
				self.config_changed = true;
			}
			self.data[1] = (char)size;
			return self.reply(2);
		case MA_LOGIN:
			return self.log_in();
		case MA_LOGOUT:
			if (!self.log_out()) return self.fail(1);
			return self.reply(0);
		case MA_TCP_OPEN:
		case MA_UDP_OPEN:
			return self.open_conn(now, self.command == MA_UDP_OPEN);
		case MA_TCP_CLOSE:
		case MA_UDP_CLOSE:
			if (self.line != ONLINE) return self.fail(1);
			if (data.len < 1 || data[0] >= MOBILE_CONNS || !self.open[data[0]]) return self.fail(0);
			self.close(data[0]);
			return self.reply(1);
		case MA_DNS:
			return self.lookup(now);
		default:
			// The firmware's test mode, never used by games.
			return self.fail(1);
	}
}

fn bool MobileAdapter.is_isp(&self, String number) {
	foreach (n : MOBILE_ISP_NUMBERS) if (n == number) return true;
	return false;
}

// 12 digits: an IP address, three digits each.
fn bool phone_ip(String number, char[4]* ip) {
	if (number.len != 12) return false;
	for (int i = 0; i < 4; i++) {
		int v;
		for (int j = 0; j < 3; j++) {
			char c = number[i * 3 + j];
			if (c < '0' || c > '9') return false;
			v = v * 10 + c - '0';
		}
		if (v > 255) return false;
		(*ip)[i] = (char)v;
	}
	return true;
}

fn bool MobileAdapter.dial(&self, ulong now) {
	if (self.step == 0) {
		if (self.line != HUNG_UP && self.line != WAITING) return self.fail(1);
		if (self.length < 1) return self.fail(2);
		self.close(0);
		self.line = HUNG_UP;
		// The first byte goes with the adapter.
		char kind = self.data[0];
		switch (self.device) {
			case MOBILE_BLUE: if (kind != 0 && kind != 16) return self.fail(2);
			case MOBILE_RED:  if (kind != 1 && kind != 9) return self.fail(2);
			default:          break;
		}
		// The number: digits, # and *.
		self.number_len = 0;
		for (int i = 1; i < self.length && self.number_len < self.number.len; i++) {
			char c = self.data[i];
			if ((c >= '0' && c <= '9') || c == '#' || c == '*') self.number[self.number_len++] = c;
		}
		String number = (String)self.number[:self.number_len];
		if (self.is_isp(number)) {
			self.line = ISP;
			return self.reply(0);
		}
		if (!phone_ip(number, &self.call_ip) || !self.net.open(0, false, 0)) {
			self.number_len = 0;
			return self.fail(3);
		}
		self.open[0] = true;
		self.step = 1;
	}
	int rc = self.net.connect(0, self.call_ip, self.p2p_port);
	if (rc == 0 && !self.ms_since(now, 60000)) return false;
	if (rc <= 0) {
		self.close(0);
		self.number_len = 0;
		return self.fail(3);
	}
	self.line = CALLING;
	return self.reply(0);
}

fn bool MobileAdapter.wait_call(&self, ulong now) {
	if (self.line != HUNG_UP && self.line != WAITING) return self.fail(1);
	if (self.line == HUNG_UP) {
		if (!self.net.open(0, false, self.p2p_port)) return self.fail(0);
		if (!self.net.listen(0)) {
			self.net.close(0);
			return self.fail(0);
		}
		self.open[0] = true;
		self.line = WAITING;
	}
	// Each wait lasts a second; the line keeps listening after it.
	if (!self.net.accept(0)) return self.ms_since(now, 1000) ? self.fail(0) : false;
	self.line = ANSWERED;
	return self.reply(0);
}

fn bool MobileAdapter.transfer(&self, ulong now) {
	if (self.line != CALLING && self.line != ANSWERED && self.line != ONLINE) return self.fail(1);
	if (self.length < 1) return self.fail(0);
	bool online = self.line == ONLINE;
	int conn = online ? self.data[0] : 0;
	if (conn >= MOBILE_CONNS || !self.open[conn]) return self.fail(0);
	if (self.step == 0) {
		self.sent = 0;
		self.step = 1;
	}
	int size = self.length - 1;
	if (self.sent < size) {
		int n = self.net.send(conn, self.data[1 + self.sent .. self.length - 1]);
		if (n < 0) return self.fail(0);
		self.sent += n;
		if (self.sent < size) return self.ms_since(now, 10000) ? self.fail(0) : false;
	}
	int got = self.net.recv(conn, self.data[1 : MOBILE_MAX_DATA]);
	if (got == -2) {
		// The other side closed: on the internet, the connection is done.
		if (online) {
			self.close(conn);
			self.command = MA_DATA_END;
		}
		return self.reply(1);
	}
	if (got < 0) return self.fail(0);
	// Nothing to send and nothing yet: up to a second for something to come.
	if (online && !size && !got && !self.ms_since(now, 1000)) return false;
	return self.reply(got + 1);
}

fn bool MobileAdapter.log_in(&self) {
	if (self.line != ISP) return self.fail(1);
	if (self.open[0]) return self.fail(3);
	// Login ID and password (each its length first), then two DNS servers.
	int at = 0;
	for (int i = 0; i < 2; i++) {
		if (at >= self.length) return self.fail(2);
		int n = self.data[at];
		at += 1 + (n > 0x20 ? 0x20 : n);
	}
	if (at + 8 > self.length) return self.fail(2);
	self.isp_dns1 = self.data[at:4];
	self.isp_dns2 = self.data[at + 4:4];
	// The phone's IP, then the DNS servers it picked (the player's, where the
	// game left them to it).
	char[4] none;
	char[4] ip = { 127, 0, 0, 1 };
	self.data[0:4] = ip[..];
	self.data[4:4] = none[..];
	self.data[8:4] = none[..];
	if (no_ip(self.isp_dns1)) self.data[4:4] = self.dns1[..];
	if (no_ip(self.isp_dns2)) self.data[8:4] = self.dns2[..];
	self.line = ONLINE;
	return self.reply(12);
}

fn bool MobileAdapter.open_conn(&self, ulong now, bool udp) {
	if (self.step == 0) {
		if (self.line != ONLINE) return self.fail(1);
		if (self.length < 6) return self.fail(3);
		int conn = -1;
		for (int c = MOBILE_CONNS - 1; c >= 0; c--) if (!self.open[c]) conn = c;
		if (conn < 0) return self.fail(0);
		if (!self.net.open(conn, udp, 0)) return self.fail(3);
		self.open[conn] = true;
		self.opening = conn;
		self.step = 1;
	}
	int conn = self.opening;
	char[4] ip = self.data[0:4];
	int rc = self.net.connect(conn, ip, (int)self.data[4] << 8 | self.data[5]);
	if (rc == 0 && !self.ms_since(now, 60000)) return false;
	if (rc <= 0) {
		self.close(conn);
		return self.fail(3);
	}
	self.data[0] = (char)conn;
	return self.reply(1);
}

fn bool no_ip(char[4] ip) => (ip[0] | ip[1] | ip[2] | ip[3]) == 0;

// "1.2.3.4": the address itself.
fn bool parse_ip(String s, char[4]* ip) {
	int part;
	int v = -1;
	foreach (c : s) {
		if (c == '.') {
			if (v < 0 || part == 3) return false;
			(*ip)[part++] = (char)v;
			v = -1;
		} else if (c >= '0' && c <= '9') {
			v = (v < 0 ? 0 : v * 10) + c - '0';
			if (v > 255) return false;
		} else {
			return false;
		}
	}
	if (v < 0 || part != 3) return false;
	(*ip)[3] = (char)v;
	return true;
}

// The DNS servers in the order they're asked: the player's first, the
// game's where the player set none. Two tries: the first server, then the
// second.
fn bool MobileAdapter.dns_server(&self, int n, char[4]* ip, int* port) {
	char[4][4] order = { self.dns1, self.isp_dns1, self.dns2, self.isp_dns2 };
	for (int i = n * 2; i < n * 2 + 2; i++) {
		if (no_ip(order[i])) continue;
		*ip = order[i];
		*port = i % 2 ? MOBILE_DNS_PORT : self.dns_port;
		return true;
	}
	return false;
}

fn bool MobileAdapter.lookup(&self, ulong now) {
	if (self.step == 0) {
		if (self.line != ONLINE) return self.fail(1);
		int n = 0;
		while (n < self.length && n < self.name.len && self.data[n]) n++;
		self.name[:n] = self.data[:n];
		self.name_len = n;
		char[4] ip;
		if (parse_ip((String)self.name[:n], &ip)) {
			if (no_ip(ip)) return self.fail(2);
			self.data[0:4] = ip[..];
			return self.reply(4);
		}
		self.dns_try = 0;
		if (!self.ask_dns(now)) {
			self.dns_try = 1;
			if (!self.ask_dns(now)) return self.fail(2);
		}
		self.step = 1;
	}
	char[512] answer;
	int got = self.net.recv(MOBILE_DNS_CONN, &answer);
	char[4] ip;
	int rc = got > 0 ? dns_answer(answer[:got], self.dns_id, &ip) : got < 0 ? -1 : 0;
	if (rc == 0 && !self.ms_since(now, 3000)) return false;
	self.close(MOBILE_DNS_CONN);
	if (rc <= 0) {
		if (self.dns_try == 0) {
			self.dns_try = 1;
			if (self.ask_dns(now)) return false;
		}
		return self.fail(2);
	}
	self.data[0:4] = ip[..];
	return self.reply(4);
}

// Sends the question for the name to try dns_try's server.
fn bool MobileAdapter.ask_dns(&self, ulong now) {
	char[4] ip;
	int port;
	if (!self.dns_server(self.dns_try, &ip, &port)) return false;
	if (!self.net.open(MOBILE_DNS_CONN, true, 0)) return false;
	self.open[MOBILE_DNS_CONN] = true;
	self.dns_id++;
	char[300] q;
	int n = dns_question((String)self.name[:self.name_len], self.dns_id, &q);
	if (n < 0 || self.net.connect(MOBILE_DNS_CONN, ip, port) <= 0 || self.net.send(MOBILE_DNS_CONN, q[:n]) != n) {
		self.close(MOBILE_DNS_CONN);
		return false;
	}
	self.step_at = now;
	return true;
}

// A DNS question for the name's IPv4 address; its length, -1 for a bad name.
fn int dns_question(String name, ushort id, char[300]* out) {
	char[] q = (*out)[..];
	q[0:12] = 0;
	q[0] = (char)(id >> 8);
	q[1] = (char)id;
	q[2] = 0x01; // recursion wanted
	q[5] = 1;    // one question
	int at = 12;
	foreach (part : name.tsplit(".")) {
		if (!part.len) continue;
		if (part.len > 63 || at + part.len + 6 >= q.len) return -1;
		q[at++] = (char)part.len;
		q[at:part.len] = part[..];
		at += part.len;
	}
	if (at == 12) return -1;
	q[at++] = 0;
	q[at++] = 0; q[at++] = 1; // A
	q[at++] = 0; q[at++] = 1; // IN
	return at;
}

// Past a name in a DNS message (labels or a pointer); -1 if it runs out.
fn int dns_skip_name(char[] m, int at) {
	while (at < (int)m.len) {
		char n = m[at];
		if (n == 0) return at + 1;
		if (n & 0xC0) return at + 2;
		at += 1 + n;
	}
	return -1;
}

// The answer to question `id`: 1 with an address, 0 not this one's, -1 no
// address (the name doesn't exist, or a bad answer).
fn int dns_answer(char[] m, ushort id, char[4]* ip) {
	if (m.len < 12 || ((ushort)m[0] << 8 | m[1]) != id || !(m[2] & 0x80)) return 0;
	if (m[3] & 0x0F) return -1;
	int questions = (int)m[4] << 8 | m[5];
	int answers = (int)m[6] << 8 | m[7];
	int at = 12;
	for (int i = 0; i < questions; i++) {
		at = dns_skip_name(m, at);
		if (at < 0) return -1;
		at += 4;
	}
	for (int i = 0; i < answers; i++) {
		at = dns_skip_name(m, at);
		if (at < 0 || at + 10 > (int)m.len) return -1;
		int type = (int)m[at] << 8 | m[at + 1];
		int class = (int)m[at + 2] << 8 | m[at + 3];
		int size = (int)m[at + 8] << 8 | m[at + 9];
		at += 10;
		if (at + size > (int)m.len) return -1;
		if (type == 1 && class == 1 && size == 4) {
			*ip = m[at:4];
			return 1;
		}
		at += size;
	}
	return -1;
}
