module mobile_suite;

import gameboy, mmu;
import std::io, std::io::file, std::os::env, std::hash::crc32;
import std::core::test;

// The Mobile Adapter GB (link/mobile.c3) with Net de Get: from power on,
// one minigame played (that opens the Server menu), then the Server: the
// game reads the adapter's memory, calls the ISP, logs in, looks up its
// server and downloads the server's minigame list over HTTP. The network is
// pretend (below): it answers as a REON server would, with REON's files.
// Needs the game, which isn't in the repository:
// resources/Net de Get - Minigame @ 100 (Japan).gbc; without it the test
// passes with a note. WER_MOBILE_SHOTS=DIR writes the last screen there.

const String ROM = "resources/Net de Get - Minigame @ 100 (Japan).gbc";

// REON's files for the game (github.com/REONTeam/reon, MIT, web/cgb/download/
// A4/CGB-BMVJ): the server's greeting and its list of minigames.
const char[*] GREETING = x"4d4e474c011212121212e5dbfecc3ce6f0d1d910101010101010000001";
const char[*] ROM_LIST = x"0418007800b800f80000000000000000000000000000000000000000630900000000000000000000000000000b4d696e691047616d6510210f4d696e6967616d65105465737410210030313030473930302e636762000000000000000000000000000000000000000000000000000000000000000000000000000000300600000000000000000000000000000b4d696e691047616d6510220f4d696e6967616d65105465737410220030313030473930312e63676200000000000000020400000000000000000000000000000b4d696e691047616d6510230f4d696e6967616d65105465737410230030313030473930322e63676200000000000000050b00000000000000000000000000000b4d696e691047616d6510240f4d696e6967616d65105465737410240030313030473930332e6367620000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";

// The buttons pressed (each for 6 frames): to the title, through the
// introduction, a minigame of sushi lost on purpose, back to the room (a
// telegram: the Server menu is open), Menu > Server, a password typed
// (AAAA), Start connection, yes to the charges, the minigame list.
struct Press {
	int  frame;
	char keys; // A B s(elect) S(tart) U D L R
}

const Press[*] PRESSES = {
	{ 1200, 'S' }, { 1400, 'A' }, { 1600, 'S' },
	{ 1800, 'A' }, { 1860, 'A' }, { 1920, 'A' }, { 1980, 'A' }, { 2040, 'A' }, { 2100, 'A' },
	{ 2160, 'A' }, { 2220, 'A' }, { 2280, 'A' }, { 2340, 'A' }, { 2400, 'A' }, { 2460, 'A' },
	{ 2600, 'A' }, { 2700, 'A' }, { 2800, 'A' }, { 2900, 'A' }, { 3000, 'A' }, { 4800, 'A' }, { 4900, 'A' },
	{ 5080, 'B' }, { 5160, 'B' }, { 5260, 'A' },
	{ 6480, 'A' }, { 6560, 'A' }, { 6640, 'A' }, { 6720, 'A' }, { 6800, 'A' }, { 6860, 'D' }, { 6910, 'R' }, { 6980, 'A' },
	{ 7650, 'A' },
	{ 7930, 'A' }, { 7970, 'A' }, { 8010, 'A' }, { 8050, 'A' }, { 8130, 'S' }, { 8210, 'A' },
	{ 8330, 'D' }, { 8390, 'D' }, { 8470, 'A' }, { 8610, 'U' }, { 8670, 'A' },
	{ 9410, 'A' },
};
const int FRAMES = 9610;

// A server as REON's: every name is it, and HTTP GETs get its files.
struct Server (mmu::MobileNet) {
	String[8] asked;    // the paths asked for, in order
	int       n_asked;
	String    dns_name;
	char[1024] request;
	int       request_len;
	char[1024] answer;
	int       answer_len;
	int       answer_at;
	char[2]   dns_id;
	bool      dns_pending;
}

fn bool Server.open(&self, int conn, bool udp, int bind_port) @dynamic {
	if (conn != mmu::MOBILE_DNS_CONN) {
		self.request_len = 0;
		self.answer_len = 0;
		self.answer_at = 0;
	}
	return true;
}
fn bool Server.listen(&self, int conn) @dynamic => false;
fn bool Server.accept(&self, int conn) @dynamic => false;
fn int Server.connect(&self, int conn, char[4] ip, int port) @dynamic => 1;
fn void Server.close(&self, int conn) @dynamic {}

fn int Server.send(&self, int conn, char[] data) @dynamic {
	if (conn == mmu::MOBILE_DNS_CONN) {
		self.dns_id = data[0:2];
		DString name;
		for (usz at = 12; data[at]; at += (usz)data[at] + 1) {
			if (name.len()) name.append('.');
			name.append((String)data[at + 1 : data[at]]);
		}
		self.dns_name = name.copy_str(tmem);
		self.dns_pending = true;
		return (int)data.len;
	}
	self.request[self.request_len : data.len] = data[..];
	self.request_len += (int)data.len;
	String req = (String)self.request[:self.request_len];
	if (!req.contains("\r\n\r\n")) return (int)data.len;
	// "GET /cgb/download?name=/A4/CGB-BMVJ/h0000.cgb HTTP/1.0"
	String path = req.tsplit(" ")[1];
	if (self.n_asked < self.asked.len) self.asked[self.n_asked++] = path.tcopy();
	char[] body;
	if (path.ends_with("/h0000.cgb")) body = &GREETING;
	if (path.ends_with("/RomList.cgb")) body = &ROM_LIST;
	String head = body.len
		? string::tformat("HTTP/1.0 200 OK\r\nContent-Length: %d\r\n\r\n", body.len)
		: "HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\n\r\n";
	self.answer[:head.len] = head[..];
	self.answer[head.len : body.len] = body[..];
	self.answer_len = (int)(head.len + body.len);
	return (int)data.len;
}

fn int Server.recv(&self, int conn, char[] buf) @dynamic {
	if (conn == mmu::MOBILE_DNS_CONN) {
		if (!self.dns_pending) return 0;
		self.dns_pending = false;
		// One answer, no question echoed: 127.0.0.1.
		char[] a = { self.dns_id[0], self.dns_id[1], 0x81, 0x80, 0, 0, 0, 1, 0, 0, 0, 0,
		             0, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 127, 0, 0, 1 };
		buf[:a.len] = a[..];
		return (int)a.len;
	}
	if (!self.answer_len) return 0;
	if (self.answer_at == self.answer_len) return -2; // done: the server closes
	int n = self.answer_len - self.answer_at;
	if (n > (int)buf.len) n = (int)buf.len;
	buf[:n] = self.answer[self.answer_at:n];
	self.answer_at += n;
	return n;
}

// The adapter's memory as Mobile Trainer leaves it (REON's: account g000000001,
// the ISP #9677).
fn void set_up(char[] config) {
	config[..] = 0;
	config[0:2] = "MA"[..];
	config[2] = 0x81;
	config[0x0C:10] = "g000000001"[..];
	String mail = "test@wer.dion.ne.jp";
	config[0x2C:mail.len] = mail[..];
	String smtp = "mail.wer.dion.ne.jp";
	config[0x4A:smtp.len] = smtp[..];
	String pop = "pop.wer.dion.ne.jp";
	config[0x5E:pop.len] = pop[..];
	char[3] number = { 0xA9, 0x67, 0x7F }; // #9677, then the end
	config[0x76:3] = number[..];
	String isp = "DION PDC/CDMAONE";
	config[0x7E:isp.len] = isp[..];
	config[0x8E:8] = 0xFF;
	config[0xA6:8] = 0xFF;
	ushort sum;
	foreach (c : config[:0xBE]) sum += c;
	config[0xBE] = (char)(sum >> 8);
	config[0xBF] = (char)sum;
}

fn void net_de_get_downloads() @test {
	char[]? rom = file::load_temp(ROM);
	if (catch rom) {
		io::printn("  (Net de Get not in resources/: the Mobile Adapter not tested with it)");
		return;
	}
	gameboy::GameBoy gb = gameboy::new(false, CGB);
	defer gb.destroy();
	gb.load_rom(rom);
	gb.mmu.cart.has_battery = false;
	Server* server = mem::new(Server);
	defer free(server);
	mmu::MobileAdapter* ma = mem::new(mmu::MobileAdapter);
	defer free(ma);
	set_up(&ma.config);
	ma.dns1 = { 10, 0, 0, 53 };
	ma.init(server, (uint)gb.mmu.model.clock_hz());
	mmu::Link l;
	gb.mmu.connect_mobile(&l, ma);

	bool online;
	for (int f = 0; f < FRAMES; f++) {
		char buttons;
		char dpad;
		foreach (p : PRESSES) {
			if (f < p.frame || f >= p.frame + 6) continue;
			switch (p.keys) {
				case 'A': buttons |= 1;
				case 'B': buttons |= 2;
				case 'S': buttons |= 8;
				case 'R': dpad |= 1;
				case 'U': dpad |= 4;
				case 'D': dpad |= 8;
				default: unreachable();
			}
		}
		gb.mmu.set_input(buttons, dpad);
		gb.run_frame();
		ma.poll(gb.mmu.rt_clock);
		if (ma.line == ONLINE) online = true;
	}
	test::@check(online, "logged in to the ISP");
	test::eq(server.dns_name, "gameboy.datacenter.ne.jp");
	test::eq(server.n_asked, 2);
	test::eq(server.asked[0], "/cgb/download?name=/A4/CGB-BMVJ/h0000.cgb");
	test::eq(server.asked[1], "/cgb/download?name=/A4/CGB-BMVJ/RomList.cgb");
	test::eq(ma.line, mmu::MobileLine.ONLINE);

	// The list on the screen: Mini Game 1 to 4.
	char[] rgb = mem::temp_array(char, gameboy::MAX_FRAME_RGB);
	char[12] colors = { 0xFF, 0xFF, 0xFF, 0xAA, 0xAA, 0xAA, 0x55, 0x55, 0x55, 0, 0, 0 };
	gameboy::FrameSize size = gb.frame_rgb(rgb, colors);
	char[] picture = rgb[:size.w * size.h * 3];
	String shots = env::tget_var("WER_MOBILE_SHOTS") ?? "";
	if (shots.len) {
		String head = string::tformat("P6\n%d %d\n255\n", size.w, size.h);
		file::save(shots.tconcat("/net-de-get-list.ppm"), head.tconcat((String)picture))!!;
	}
	uint crc = crc32::hash(picture);
	test::@check(crc == 0x65655f04, "the minigame list (CRC %08x)", crc);
	ma.close_all();
}
