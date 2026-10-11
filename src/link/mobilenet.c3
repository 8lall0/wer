module mobilenet;
import std::net, std::net::tcp, std::net::udp, std::net::os;
import mmu;

// The Mobile Adapter's network (mmu::MobileNet): the computer's sockets,
// never blocking. A browser has none: there every call fails.

const int CONNS = 3;

struct Sockets (mmu::MobileNet) {
	Socket[CONNS] sock;
	bool[CONNS]   has;        // sock is open
	bool[CONNS]   udp;
	bool[CONNS]   listening;
	bool[CONNS]   connecting; // TCP: connect not through yet
	int[CONNS]    bind_port;
}

fn bool Sockets.open(&self, int conn, bool udp, int bind_port) @dynamic {
	self.close(conn);
	self.udp[conn] = udp;
	self.bind_port[conn] = bind_port;
	return !env::EMSCRIPTEN;
}

fn bool Sockets.listen(&self, int conn) @dynamic {
	$if env::EMSCRIPTEN:
		return false;
	$else
		TcpServerSocket? s = tcp::listen("0.0.0.0", self.bind_port[conn], 1, REUSEADDR);
		if (catch s) return false;
		self.sock[conn] = (Socket)s;
		self.has[conn] = true;
		self.listening[conn] = true;
		return true;
	$endif
}

fn bool Sockets.accept(&self, int conn) @dynamic {
	$if env::EMSCRIPTEN:
		return false;
	$else
		if (!self.listening[conn] || !ready(self.sock[conn].sock, net::PollSubscribe.ANY_READ)) return false;
		TcpServerSocket server = (TcpServerSocket)self.sock[conn];
		TcpSocket? s = tcp::accept(&server);
		if (catch s) return false;
		(void)self.sock[conn].close();
		self.sock[conn] = (Socket)s;
		self.listening[conn] = false;
		return true;
	$endif
}

fn int Sockets.connect(&self, int conn, char[4] ip, int port) @dynamic {
	$if env::EMSCRIPTEN:
		return -1;
	$else
		if (!self.has[conn]) {
			String host = string::tformat("%d.%d.%d.%d", ip[0], ip[1], ip[2], ip[3]);
			if (self.udp[conn]) {
				UdpSocket? s = udp::connect(host, port);
				if (catch s) return -1;
				self.sock[conn] = (Socket)s;
				self.has[conn] = true;
				return 1;
			}
			TcpSocket? s = tcp::connect_async(host, port);
			if (catch s) return -1;
			self.sock[conn] = (Socket)s;
			self.has[conn] = true;
			self.connecting[conn] = true;
		}
		if (!self.connecting[conn]) return 1;
		if (!ready(self.sock[conn].sock, net::PollSubscribe.ANY_WRITE)) return 0;
		CInt error;
		os::Socklen_t size = CInt::size;
		if (os::getsockopt(self.sock[conn].sock, os::SOL_SOCKET, os::SO_ERROR, &error, &size) != 0 || error) return -1;
		self.connecting[conn] = false;
		return 1;
	$endif
}

fn int Sockets.send(&self, int conn, char[] data) @dynamic {
	$if env::EMSCRIPTEN:
		return -1;
	$else
		if (!self.has[conn] || self.connecting[conn] || self.listening[conn]) return -1;
		if (!ready(self.sock[conn].sock, net::PollSubscribe.ANY_WRITE)) return 0;
		sz? n = self.sock[conn].write(data);
		if (catch n) return -1;
		return (int)n;
	$endif
}

fn int Sockets.recv(&self, int conn, char[] buf) @dynamic {
	$if env::EMSCRIPTEN:
		return -1;
	$else
		if (!self.has[conn] || self.connecting[conn] || self.listening[conn]) return -1;
		if (!ready(self.sock[conn].sock, net::PollSubscribe.ANY_READ)) return 0;
		sz? n = self.sock[conn].read(buf);
		if (catch n) return -1;
		if (n == 0 && !self.udp[conn]) return -2; // the other side closed
		return (int)n;
	$endif
}

fn void Sockets.close(&self, int conn) @dynamic {
	$if !env::EMSCRIPTEN:
		if (self.has[conn]) (void)self.sock[conn].close();
	$endif
	self.has[conn] = false;
	self.listening[conn] = false;
	self.connecting[conn] = false;
}

fn bool ready(NativeSocket s, net::PollSubscribe what) {
	$if env::EMSCRIPTEN:
		return false;
	$else
		net::Poll[1] p = { { .socket = s, .events = what } };
		ulong? n = net::poll_ms(&p, 0);
		return (n ?? 0) > 0;
	$endif
}

// This computer's address on its network as a phone number (192168001023
// for 192.168.1.23), for the other side to call; "" if it has none. No
// packet is sent: connecting a UDP socket only picks the way out.
fn String own_number() {
	$if env::EMSCRIPTEN:
		return "";
	$else
		UdpSocket? s = udp::connect("192.0.2.1", 9);
		if (catch s) return "";
		defer (void)s.close();
		InetAddress? a = s.local_address();
		if (catch a) return "";
		if (a.is_ipv6) return "";
		return string::tformat("%03d%03d%03d%03d", a.ipv4.a, a.ipv4.b, a.ipv4.c, a.ipv4.d);
	$endif
}
