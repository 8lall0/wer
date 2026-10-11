module wer;
import std::io, std::io::file, std::os::env;
import mmu, mobilenet, config;

// The Mobile Adapter GB on the link port (Menu > Link > Mobile Adapter,
// --link=mobile). Its memory (what Mobile Trainer sets up: the account, the
// ISP) is ~/.wer/mobile.bin; a REON server's config.bin works there too.
// wer.conf has the rest: mobile-dns (a REON server's DNS, without which only
// calls work), mobile-port, mobile-adapter, mobile-unmetered. Calls go to
// 12-digit numbers: another wer at that IP address, waiting for a call.
// WER_MOBILE_TRACE=1 prints each command and its reply.

const String MOBILE_FILE = "mobile.bin";

mmu::MobileAdapter mobile;
mobilenet::Sockets mobile_net;
mmu::Link mobile_cable;
mmu::MobileLine mobile_line;   // as last told
bool mobile_told;              // the game found it: said so
char[] mobile_file;            // the whole file as read (a config.bin is longer)

fn String mobile_path() {
	String conf = config::tpath();
	if (!conf.len) return "";
	return conf[:conf.len - config::FILE.len].tconcat(MOBILE_FILE);
}

fn void mobile_plug() {
	mobile.close_all();
	mobile = {};
	if (mobile_file.len) free(mobile_file.ptr);
	mobile_file = {};
	String path = mobile_path();
	if (path.len) {
		if (try data = file::load(mem, path)) mobile_file = data;
	}
	usz n = mobile_file.len < mmu::MOBILE_CONFIG_SIZE ? mobile_file.len : mmu::MOBILE_CONFIG_SIZE;
	mobile.config[:n] = mobile_file[:n];
	int port;
	if (cfg.mobile_dns.len) config::parse_address(cfg.mobile_dns, &mobile.dns1, &mobile.dns_port);
	if (cfg.mobile_dns2.len) config::parse_address(cfg.mobile_dns2, &mobile.dns2, &port);
	mobile.p2p_port = cfg.mobile_port;
	mobile.device = config::mobile_device(cfg.mobile_adapter);
	mobile.unmetered = cfg.mobile_unmetered;
	mobile.init(&mobile_net, (uint)gb.mmu.model.clock_hz());
	mobile.trace = (env::tget_var("WER_MOBILE_TRACE") ?? "") != "";
	gb.mmu.connect_mobile(&mobile_cable, &mobile);
	link_mode = MOBILE;
	mobile_line = HUNG_UP;
	mobile_told = false;
	notice.show(cfg.mobile_dns.len ? "Mobile Adapter connected" : "Mobile Adapter: no DNS set, only calls");
}

// The game restarted: the adapter too (its calls end).
fn void mobile_replug() {
	bool trace = mobile.trace;
	mobile.init(&mobile_net, mobile.hz);
	mobile.trace = trace;
	gb.mmu.connect_mobile(&mobile_cable, &mobile);
	mobile_line = HUNG_UP;
}

fn void mobile_unplug() {
	mobile.close_all();
	mobile_save();
}

// The adapter's memory, when the game changed it.
fn void mobile_save() {
	if (!mobile.config_changed) return;
	mobile.config_changed = false;
	String path = mobile_path();
	if (!path.len) return;
	if (mobile_file.len < mmu::MOBILE_CONFIG_SIZE) {
		if (mobile_file.len) free(mobile_file.ptr);
		mobile_file = mem::new_array(char, mmu::MOBILE_CONFIG_SIZE);
	}
	mobile_file[:mmu::MOBILE_CONFIG_SIZE] = mobile.config[..];
	config::make_dir(path);
	if (catch file::save(path, mobile_file)) notice.show("Could not save the Mobile Adapter's settings");
}

// After each frame: its time goes by, its memory is kept, and what the
// phone line does is told.
fn void mobile_poll() {
	mobile.poll(gb.mmu.rt_clock);
	mobile_save();
	if (mobile.active() && !mobile_told) {
		mobile_told = true;
		notice.show("Mobile Adapter: the game found it");
	}
	if (mobile.line == mobile_line) return;
	mobile_line = mobile.line;
	String number = (String)mobile.number[:mobile.number_len];
	switch (mobile.line) {
		case HUNG_UP:  notice.show("Mobile Adapter: hung up");
		case WAITING:
			String mine = mobilenet::own_number();
			notice.show(mine.len ? string::tformat("Waiting for a call: your number is %s", mine) : "Waiting for a call");
			if (mine.len) io::printfn("mobile: waiting for a call on port %d, number %s", mobile.p2p_port, mine);
		case CALLING:  notice.show(string::tformat("Calling %s", number));
		case ANSWERED: notice.show("Mobile Adapter: answered a call");
		case ISP:      notice.show(string::tformat("Mobile Adapter: called the ISP (%s)", number));
		case ONLINE:   notice.show("Mobile Adapter: online");
	}
}
