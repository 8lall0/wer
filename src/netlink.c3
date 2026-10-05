module netlink;
import std::net, std::net::tcp, std::net::os, std::io, std::time;
import mmu;

// The link cable over a network, in BGB's link protocol (1.4), so wer links
// with another wer or with BGB. One side hosts (listens, port 8765 like BGB),
// the other joins it. Each side runs its own Game Boy; a transfer's bytes
// cross when it happens (mmu/link.c3):
//
//   sync1  the side clocking a transfer sends its byte
//   sync2  the other side, waiting for one, answers with its byte
//   sync3  ... or, not waiting, says so (the clocking side reads $FF);
//          also sent now and then with the time, which BGB keeps up with
//
// Every packet is 8 bytes: command, three bytes, a 32-bit time in 2 MiHz
// units.

const int DEFAULT_PORT = 8765;

const char CMD_VERSION = 1;
const char CMD_JOYPAD  = 101;
const char CMD_SYNC1   = 104;
const char CMD_SYNC2   = 105;
const char CMD_SYNC3   = 106;
const char CMD_STATUS  = 108;
const char CMD_DISCONNECT = 109;

const CInt IPPROTO_TCP = 6;
const CInt TCP_NODELAY = 1;

enum State : char {
	OFF,
	HOSTING,    // waiting for the other side to join
	CONNECTED,
}

struct NetLink {
	State           state;
	TcpServerSocket server;
	bool            listening; // server is open
	TcpSocket       sock;
	char[256]       inbuf;
	usz             inlen;
	mmu::Link       cable;    // plugged into the Game Boy while connected
	Clock           last_time; // when the time was last sent
}

fn bool NetLink.connected(&self) => self.state == CONNECTED;

// Listen for the other side on `port`.
fn void? NetLink.host(&self, int port) {
	self.server = tcp::listen("0.0.0.0", port, 1, REUSEADDR)!;
	self.listening = true;
	self.state = HOSTING;
}

// Connect to a side that hosts ("host" or "host:port").
fn void? NetLink.join(&self, String address, mmu::Mmu* m) {
	String host = address;
	int port = DEFAULT_PORT;
	if (try colon = address.rindex_of_char(':')) {
		host = address[:colon];
		port = address[colon + 1..].to_int() ?? DEFAULT_PORT;
	}
	self.sock = tcp::connect(host, port, time::sec(3))!;
	self.start(m);
}

fn void NetLink.start(&self, mmu::Mmu* m) {
	CInt on = 1;
	os::setsockopt(self.sock.sock, IPPROTO_TCP, TCP_NODELAY, &on, CInt::size);
	self.state = CONNECTED;
	self.inlen = 0;
	self.cable = {};
	m.link = &self.cable;
	self.send(CMD_VERSION, 1, 4, 0, 0);
	self.send(CMD_STATUS, 1, 0, 0, 0); // running
}

// Unplug and close everything.
fn void NetLink.close(&self, mmu::Mmu* m) {
	if (self.state == CONNECTED) {
		self.send(CMD_DISCONNECT, 0, 0, 0, 0);
		(void)self.sock.close();
		self.drop_cable(m);
	}
	if (self.listening) (void)self.server.close();
	self.listening = false;
	self.state = OFF;
}

fn void NetLink.drop_cable(&self, mmu::Mmu* m) {
	if (m.link == &self.cable) {
		if (m.serial_waiting) m.link_answer(-1); // a transfer waiting for an answer that won't come
		m.unplug();
	}
}

// The Game Boy was replaced (a new game): plug the cable into it again.
fn void NetLink.replug(&self, mmu::Mmu* m) {
	if (self.state == CONNECTED) {
		self.cable = {};
		m.link = &self.cable;
	}
}

fn void NetLink.send(&self, char cmd, char b2, char b3, char b4, uint stamp) {
	if (self.state != CONNECTED) return;
	char[8] p = { cmd, b2, b3, b4, (char)stamp, (char)(stamp >> 8), (char)(stamp >> 16), (char)(stamp >> 24) };
	if (catch self.sock.write(&p)) self.lost();
}

fn void NetLink.lost(&self) {
	(void)self.sock.close();
	self.state = self.listening ? HOSTING : OFF;
	self.inlen = 0;
}

fn bool readable(NativeSocket s) {
	net::Poll[1] p = { { .socket = s, .events = net::PollSubscribe.ANY_READ } };
	ulong? n = net::poll_ms(&p, 0);
	return (n ?? 0) > 0;
}

fn uint stamp(mmu::Mmu* m) => (uint)(m.rt_clock / 2) & 0x7FFF_FFFF;

// Between slices of emulation: accept the other side, send what the Game
// Boy has to send, and act on what came in. False when the other side left.
fn bool NetLink.poll(&self, mmu::Mmu* m) {
	if (self.state == HOSTING && readable(self.server.sock)) {
		if (try s = tcp::accept(&self.server)) {
			self.sock = s;
			self.start(m);
		}
	}
	if (self.state != CONNECTED) return true;

	if (self.cable.out_pending) {
		self.cable.out_pending = false;
		self.send(CMD_SYNC1, self.cable.out_byte, self.cable.out_control, 0, stamp(m));
	}
	if (clock::now() - self.last_time > (NanoDuration)8_000_000) {
		self.last_time = clock::now();
		self.send(CMD_SYNC3, 0, 0, 0, stamp(m));
	}

	while (self.state == CONNECTED && readable(self.sock.sock)) {
		sz n = self.sock.read(self.inbuf[self.inlen..]) ?? 0;
		if (n <= 0) {
			self.drop_cable(m);
			self.lost();
			return false;
		}
		self.inlen += (usz)n;
		usz at;
		while (self.inlen - at >= 8) {
			self.handle(self.inbuf[at : 8], m);
			at += 8;
		}
		for (usz i = at; i < self.inlen; i++) self.inbuf[i - at] = self.inbuf[i];
		self.inlen -= at;
	}
	return self.state == CONNECTED;
}

fn void NetLink.handle(&self, char[] p, mmu::Mmu* m) {
	switch (p[0]) {
		case CMD_VERSION:
			if (p[1] != 1 || p[2] != 4) {
				io::eprintfn("link: the other side speaks BGB link protocol %d.%d, not 1.4", p[1], p[2]);
				self.drop_cable(m);
				self.lost();
			}
		case CMD_SYNC1:
			int mine = m.link_take(p[1]);
			if (mine >= 0) {
				self.send(CMD_SYNC2, (char)mine, 0x80, 1, stamp(m));
			} else {
				self.send(CMD_SYNC3, 1, 0, 0, stamp(m));
			}
		case CMD_SYNC2:
			m.link_answer(p[1]);
		case CMD_SYNC3:
			if (p[1] == 1) m.link_answer(-1);
		case CMD_DISCONNECT:
			self.drop_cable(m);
			self.lost();
		default:
			break; // joypad, status: nothing to do
	}
}
