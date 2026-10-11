module mobile_test;
import mmu, mobilenet;
import std::core::test;

// The Mobile Adapter GB (link/mobile.c3): packets in and out a byte at a
// time as a game clocks them, its commands on a pretend network, and a
// call between two adapters over this computer's own sockets.

const uint HZ = 4194304;

// A network that does what each test says.
struct FakeNet (mmu::MobileNet) {
	bool[3] opened;
	bool[3] udp;
	int     connect_result;  // what connect says (default: connected)
	char[4] connected_ip;
	int     connected_port;
	char[512] sent;          // what the game sent on conn 0
	int     sent_len;
	char[512] incoming;      // what conn 0 receives next
	int     incoming_len;
	bool    remote_closed;   // conn 0's other side closed, after incoming
	char[4] dns_ip;          // a DNS question gets this address
	char[4] dns_server;      // where the question went
	int     dns_port;
	ushort  dns_id;
	bool    dns_asked;
	bool    dns_silent;      // no DNS answer at all
}

fn bool FakeNet.open(&self, int conn, bool udp, int bind_port) @dynamic {
	self.opened[conn] = true;
	self.udp[conn] = udp;
	return true;
}
fn bool FakeNet.listen(&self, int conn) @dynamic => true;
fn bool FakeNet.accept(&self, int conn) @dynamic => false;
fn int FakeNet.connect(&self, int conn, char[4] ip, int port) @dynamic {
	if (conn == mmu::MOBILE_DNS_CONN) {
		self.dns_server = ip;
		self.dns_port = port;
		return 1;
	}
	self.connected_ip = ip;
	self.connected_port = port;
	return self.connect_result ? self.connect_result : 1;
}
fn int FakeNet.send(&self, int conn, char[] data) @dynamic {
	if (conn == mmu::MOBILE_DNS_CONN) {
		self.dns_id = (ushort)data[0] << 8 | data[1];
		self.dns_asked = true;
		return (int)data.len;
	}
	self.sent[self.sent_len:data.len] = data[..];
	self.sent_len += (int)data.len;
	return (int)data.len;
}
fn int FakeNet.recv(&self, int conn, char[] buf) @dynamic {
	if (conn == mmu::MOBILE_DNS_CONN) {
		if (!self.dns_asked || self.dns_silent) return 0;
		self.dns_asked = false;
		// An answer the way servers write it: the question, then the
		// address with a pointer back to the question's name.
		char[] a = buf;
		a[0:12] = 0;
		a[0] = (char)(self.dns_id >> 8);
		a[1] = (char)self.dns_id;
		a[2] = 0x81;
		a[3] = 0x80;
		a[5] = 1;
		a[7] = 1;
		char[] question = { 7, 'g', 'a', 'm', 'e', 'b', 'o', 'y', 2, 'j', 'p', 0, 0, 1, 0, 1 };
		a[12:question.len] = question[..];
		int at = 12 + (int)question.len;
		char[] answer = { 0xC0, 12, 0, 1, 0, 1, 0, 0, 1, 0, 0, 4 };
		a[at:answer.len] = answer[..];
		at += (int)answer.len;
		a[at:4] = self.dns_ip[..];
		return at + 4;
	}
	if (self.incoming_len) {
		int n = self.incoming_len;
		buf[:n] = self.incoming[:n];
		self.incoming_len = 0;
		return n;
	}
	return self.remote_closed ? -2 : 0;
}
fn void FakeNet.close(&self, int conn) @dynamic {
	self.opened[conn] = false;
}

// A game on the cable: sends packets, reads replies.
struct Game {
	mmu::MobileAdapter* ma;
	ulong now;
	char ack;            // the adapter's answer in the packet's acknowledgement
	char reply_command;
	char[256] reply;
	int reply_len;
}

fn char Game.byte(&self, char b) {
	self.now += 1024; // a byte at the fast clock, more or less
	return self.ma.exchange(b, self.now);
}

// Sends a packet; false when the adapter didn't take it (no $88 back). The
// reply, if one comes, is in reply_command / reply.
fn bool Game.send(&self, char command, char[] data, bool wait_reply = true) {
	char[] bytes = mem::temp_array(char, data.len + 8);
	bytes[0] = 0x99;
	bytes[1] = 0x66;
	bytes[2] = command;
	bytes[3] = 0;
	bytes[4] = 0;
	bytes[5] = (char)data.len;
	bytes[6:data.len] = data[..];
	ushort sum = (ushort)(command + data.len);
	foreach (c : data) sum += c;
	bytes[6 + data.len] = (char)(sum >> 8);
	bytes[7 + data.len] = (char)sum;
	foreach (b : bytes) self.byte(b);
	char device = self.byte(0x80);
	self.ack = self.byte(0x00);
	self.reply_command = 0;
	if (device != 0x88) return false;
	if (!wait_reply || self.ack != (command ^ 0x80)) return true;
	// Waiting: $4B until the reply's $99 (time goes by meanwhile).
	char b;
	for (int i = 0; i < 100000 && b != 0x99; i++) b = self.byte(0x4B);
	if (b != 0x99) return true;
	test::eq(self.byte(0x4B), 0x66);
	self.reply_command = self.byte(0x4B);
	self.byte(0x4B);
	self.byte(0x4B);
	self.reply_len = self.byte(0x4B);
	ushort got_sum = (ushort)(self.reply_command + self.reply_len);
	for (int i = 0; i < self.reply_len; i++) {
		self.reply[i] = self.byte(0x4B);
		got_sum += self.reply[i];
	}
	ushort sum_in = (ushort)self.byte(0x4B) << 8;
	sum_in |= self.byte(0x4B);
	test::eq(sum_in, got_sum);
	test::eq(self.byte(0x80), 0x88);           // both say who they are
	test::eq(self.byte(self.reply_command ^ 0x80), 0x00);
	return true;
}

fn String Game.text(&self) => (String)self.reply[:self.reply_len];

fn void Game.begin(&self) {
	self.send(mmu::MA_BEGIN, "NINTENDO");
	test::eq(self.reply_command, 0x90);
	test::eq(self.text(), "NINTENDO");
}

fn void starts_a_session() @test {
	FakeNet net;
	mmu::MobileAdapter ma;
	ma.init(&net, HZ);
	Game g = { .ma = &ma };
	// Nothing but the session's start is taken before it.
	test::@check(!g.send(mmu::MA_STATUS, {}), "no session yet: ignored");
	test::@check(!ma.active(), "not active");
	g.begin();
	test::@check(ma.active(), "active");
	// Twice: an error ($EE: the command and a code).
	g.send(mmu::MA_BEGIN, "NINTENDO");
	test::eq(g.reply_command, 0xEE);
	test::@check(g.reply[:2] == (char[]){ 0x10, 1 }, "sent twice");
	g.send(mmu::MA_END, {});
	test::eq(g.reply_command, 0x91);
	test::@check(!ma.active(), "ended");
	g.send(mmu::MA_BEGIN, "NINTENDX");
	test::@check(g.reply[:2] == (char[]){ 0x10, 2 }, "the wrong word");
}

fn void bad_packets() @test {
	FakeNet net;
	mmu::MobileAdapter ma;
	ma.init(&net, HZ);
	Game g = { .ma = &ma };
	g.begin();
	// A bad sum: $F1 instead of the command, and no reply.
	char[] bytes = { 0x99, 0x66, 0x17, 0, 0, 0, 0x00, 0x18 };
	foreach (b : bytes) g.byte(b);
	test::eq(g.byte(0x80), 0x88);
	test::eq(g.byte(0x00), mmu::MOBILE_ERR_SUM);
	for (int i = 0; i < 10; i++) test::eq(g.byte(0x4B), mmu::MOBILE_IDLE);
	// A command it doesn't know: $F0.
	g.send(0x30, {});
	test::eq(g.ack, mmu::MOBILE_ERR_COMMAND);
	test::eq(g.reply_command, 0);
	// Still there after.
	g.send(mmu::MA_STATUS, {});
	test::eq(g.reply_command, 0x97);
	test::@check(g.reply[:3] == (char[]){ 0, 0x4D, 0 }, "hung up, blue adapter");
}

fn void reads_and_writes_its_memory() @test {
	FakeNet net;
	mmu::MobileAdapter ma;
	ma.init(&net, HZ);
	Game g = { .ma = &ma };
	g.begin();
	g.send(mmu::MA_WRITE_CONFIG, { 0x10, 'M', 'A', 0x81 });
	test::eq(g.reply_command, 0x9A);
	test::@check(g.reply[:2] == (char[]){ 0x10, 3 }, "offset, size written");
	test::@check(ma.config_changed, "to be saved");
	g.send(mmu::MA_READ_CONFIG, { 0x0F, 5 });
	test::eq(g.reply_command, 0x99);
	test::@check(g.reply[:6] == (char[]){ 0x0F, 0, 'M', 'A', 0x81, 0 }, "offset, then the bytes");
	// Past its 256 bytes, or more than 128 at once.
	g.send(mmu::MA_READ_CONFIG, { 0xC0, 0x41 });
	test::@check(g.reply[:2] == (char[]){ 0x19, 2 }, "past the end");
	g.send(mmu::MA_READ_CONFIG, { 0x00, 0x81 });
	test::@check(g.reply[:2] == (char[]){ 0x19, 2 }, "too much");
	// A reply of 129 bytes, all of it.
	g.send(mmu::MA_READ_CONFIG, { 0x00, 0x80 });
	test::eq(g.reply_len, 0x81);
}

fn void goes_online() @test {
	FakeNet net;
	net.dns_ip = { 10, 1, 2, 3 };
	mmu::MobileAdapter ma;
	ma.dns1 = { 192, 168, 0, 53 };
	ma.init(&net, HZ);
	Game g = { .ma = &ma };
	g.begin();
	// The internet needs the ISP called and a login.
	g.send(mmu::MA_TCP_OPEN, { 1, 2, 3, 4, 0, 80 });
	test::@check(g.reply[:2] == (char[]){ 0x23, 1 }, "not logged in");
	g.send(mmu::MA_DIAL, { 0, '#', '9', '6', '7', '7' });
	test::eq(g.reply_command, 0x92);
	g.send(mmu::MA_STATUS, {});
	test::eq(g.reply[0], 4);
	// Login: ID, password, then DNS servers 0.0.0.0 (the adapter picks).
	g.send(mmu::MA_LOGIN, { 3, 'g', '0', '1', 2, 'p', 'w', 0, 0, 0, 0, 0, 0, 0, 0 });
	test::eq(g.reply_command, 0xA1);
	test::@check(g.reply[:12] == (char[]){ 127, 0, 0, 1, 192, 168, 0, 53, 0, 0, 0, 0 }, "IP, the player's DNS");
	// The name of the game's server, through the player's DNS.
	g.send(mmu::MA_DNS, "gameboy.datacenter.ne.jp");
	test::eq(g.reply_command, 0xA8);
	test::@check(g.reply[:4] == (char[]){ 10, 1, 2, 3 }, "its address");
	test::@check(net.dns_server == (char[4]){ 192, 168, 0, 53 } && net.dns_port == 53, "asked the player's DNS");
	test::@check(!net.opened[mmu::MOBILE_DNS_CONN], "the DNS socket closed");
	// An address needs no DNS.
	g.send(mmu::MA_DNS, "10.20.30.40");
	test::@check(g.reply[:4] == (char[]){ 10, 20, 30, 40 }, "the address itself");
	// TCP: connection 0.
	g.send(mmu::MA_TCP_OPEN, { 10, 1, 2, 3, 0, 80 });
	test::eq(g.reply_command, 0xA3);
	test::eq(g.reply[0], 0);
	test::@check(net.connected_ip == (char[4]){ 10, 1, 2, 3 } && net.connected_port == 80, "to the server");
	// Data out; the answer comes back on the same command.
	net.incoming[:8] = "HTTP/1.0"[..];
	net.incoming_len = 8;
	g.send(mmu::MA_DATA, { 0, 'G', 'E', 'T', ' ', '/' });
	test::eq(g.reply_command, 0x95);
	test::eq((String)net.sent[:net.sent_len], "GET /");
	test::eq(g.reply[0], 0);
	test::eq((String)g.reply[1:8], "HTTP/1.0");
	// Nothing to send, nothing comes: an empty reply after a second.
	ulong before = g.now;
	g.send(mmu::MA_DATA, { 0 });
	test::eq(g.reply_command, 0x95);
	test::eq(g.reply_len, 1);
	test::@check(g.now - before >= HZ, "waited a second");
	// The server closed: $9F, and the connection is gone.
	net.remote_closed = true;
	g.send(mmu::MA_DATA, { 0 });
	test::eq(g.reply_command, 0x9F);
	test::@check(!net.opened[0], "closed");
	g.send(mmu::MA_TCP_CLOSE, { 0 });
	test::@check(g.reply[:2] == (char[]){ 0x24, 0 }, "already closed");
	// Logging out, hanging up.
	g.send(mmu::MA_LOGOUT, {});
	test::eq(g.reply_command, 0xA2);
	g.send(mmu::MA_HANG_UP, {});
	test::eq(g.reply_command, 0x93);
	g.send(mmu::MA_HANG_UP, {});
	test::@check(g.reply[:2] == (char[]){ 0x13, 1 }, "not in a call");
}

fn void dns_fails() @test {
	FakeNet net;
	net.dns_silent = true;
	mmu::MobileAdapter ma;
	ma.init(&net, HZ);
	Game g = { .ma = &ma };
	g.begin();
	g.send(mmu::MA_DIAL, { 0, '#', '9', '6', '7', '7' });
	// The game's own DNS servers (Nintendo's, long gone): no answer.
	g.send(mmu::MA_LOGIN, { 0, 0, 210, 196, 3, 183, 210, 141, 112, 163 });
	test::@check(g.reply[4:8] == (char[]){ 0, 0, 0, 0, 0, 0, 0, 0 }, "the game's servers kept");
	ulong before = g.now;
	g.send(mmu::MA_DNS, "gameboy.datacenter.ne.jp");
	test::@check(g.reply[:2] == (char[]){ 0x28, 2 }, "lookup failed");
	test::@check(g.now - before >= 6 * (ulong)HZ, "after both servers' 3 seconds");
	test::@check(net.dns_server == (char[4]){ 210, 141, 112, 163 }, "the second server tried last");
}

fn void sleeps_after_three_seconds() @test {
	FakeNet net;
	mmu::MobileAdapter ma;
	ma.init(&net, HZ);
	Game g = { .ma = &ma };
	g.begin();
	g.send(mmu::MA_DIAL, { 0, '#', '9', '6', '7', '7' });
	ma.poll(g.now + 2 * (ulong)HZ);
	test::@check(ma.active(), "still there");
	ma.poll(g.now + 4 * (ulong)HZ);
	test::@check(!ma.active(), "the session ended");
	test::eq(ma.line, mmu::MobileLine.HUNG_UP);
}

fn void dns_questions() @test {
	char[300] q;
	int n = mmu::dns_question("a.bc", 0x1234, &q);
	test::@check(q[:n] == (char[]){ 0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1, 'a', 2, 'b', 'c', 0, 0, 1, 0, 1 }, "a question");
	test::eq(mmu::dns_question("", 1, &q), -1);
	char[4] ip;
	// Not an answer to this question; then "no such name".
	char[] other = { 0x12, 0x35, 0x81, 0x80, 0, 0, 0, 0, 0, 0, 0, 0 };
	test::eq(mmu::dns_answer(other, 0x1234, &ip), 0);
	char[] missing = { 0x12, 0x34, 0x81, 0x83, 0, 0, 0, 0, 0, 0, 0, 0 };
	test::eq(mmu::dns_answer(missing, 0x1234, &ip), -1);
}

fn void phone_numbers() @test {
	char[4] ip;
	test::@check(mmu::phone_ip("127000000001", &ip) && ip == (char[4]){ 127, 0, 0, 1 }, "an address");
	test::@check(!mmu::phone_ip("256000000001", &ip), "too big");
	test::@check(!mmu::phone_ip("12700000001", &ip), "11 digits");
}

// Two adapters, one calling the other over this computer's sockets.
fn void call_between_two() @test {
	mobilenet::Sockets na;
	mobilenet::Sockets nb;
	mmu::MobileAdapter a;
	mmu::MobileAdapter b;
	a.p2p_port = 41027;
	b.p2p_port = 41027;
	a.init(&na, HZ);
	b.init(&nb, HZ);
	defer { a.close_all(); b.close_all(); }
	Game ga = { .ma = &a };
	Game gb = { .ma = &b };
	ga.begin();
	gb.begin();
	// B waits: a second, then "no call", still listening.
	gb.send(mmu::MA_WAIT_CALL, {});
	test::@check(gb.reply[:2] == (char[]){ 0x14, 0 }, "no call yet");
	test::eq(b.line, mmu::MobileLine.WAITING);
	// A calls 127.0.0.1; B picks up.
	ga.send(mmu::MA_DIAL, { 0, '1', '2', '7', '0', '0', '0', '0', '0', '0', '0', '0', '1' });
	test::eq(ga.reply_command, 0x92);
	gb.send(mmu::MA_WAIT_CALL, {});
	test::eq(gb.reply_command, 0x94);
	gb.send(mmu::MA_STATUS, {});
	test::eq(gb.reply[0], 5);
	// Data across, both ways (the connection byte is ignored on a call).
	ga.send(mmu::MA_DATA, { 0xFF, 'h', 'i' });
	test::eq(ga.reply_command, 0x95);
	char[] got;
	for (int i = 0; i < 100 && !got.len; i++) {
		gb.send(mmu::MA_DATA, { 0xFF });
		got = gb.reply[1:gb.reply_len - 1];
	}
	test::eq((String)got, "hi");
	gb.send(mmu::MA_DATA, { 0xFF, 'y', 'o' });
	got = {};
	for (int i = 0; i < 100 && !got.len; i++) {
		ga.send(mmu::MA_DATA, { 0xFF });
		got = ga.reply[1:ga.reply_len - 1];
	}
	test::eq((String)got, "yo");
	ga.send(mmu::MA_HANG_UP, {});
	test::eq(ga.reply_command, 0x93);
}
