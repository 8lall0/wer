module config_test;

import config;
import std::core::test;

fn void defaults_are_the_classic_keys() @test
{
	config::Config c = config::defaults();
	defer c.free();
	test::eq("dmg", c.mode);
	test::eq(3, c.scale);
	test::eq("Z", c.keys[config::Button.A.ordinal]);
	test::eq("Right Shift", c.keys[config::Button.SELECT.ordinal]);
	test::eq("b", c.pads[config::Button.A.ordinal]);
}

fn void parse_overrides_and_skips_bad_lines() @test
{
	config::Config c = config::defaults();
	defer c.free();
	c.parse("# comment\n\n mode = cgb \nscale=2\nkey.start = Space\npad.b = x\n"
		"scale = 9\nbogus = 1\nno equals sign\nkey.turbo = T\n", "test");
	test::eq("cgb", c.mode);
	test::eq(2, c.scale);               // 9 is out of range: kept 2
	test::eq("Space", c.keys[config::Button.START.ordinal]);
	test::eq("x", c.pads[config::Button.B.ordinal]);
	test::eq("Z", c.keys[config::Button.A.ordinal]); // untouched
}

fn void text_round_trip() @test
{
	config::Config a = config::defaults();
	defer a.free();
	a.set("mode", "sgb2");
	a.set("palette", "3-C");
	a.set("key.left", "A");
	a.set("pad.start", "guide");

	config::Config b = config::defaults();
	defer b.free();
	b.parse(a.to_text(tmem), "round trip");
	test::eq("sgb2", b.mode);
	test::eq("3-C", b.palette);
	test::eq("A", b.keys[config::Button.LEFT.ordinal]);
	test::eq("guide", b.pads[config::Button.START.ordinal]);
}

fn void save_creates_directory_and_loads_back() @test
{
	String dir = "build/config_test";
	String p = string::tformat("%s/.wer/wer.conf", dir);
	config::Config a = config::defaults();
	defer a.free();
	a.set("mode", "cgb");
	a.set("key.b", "Left Ctrl");
	a.save_to(p)!!;

	config::Config b = config::load_from(p);
	defer b.free();
	test::eq("cgb", b.mode);
	test::eq("Left Ctrl", b.keys[config::Button.B.ordinal]);

	config::Config missing = config::load_from("build/no/such/wer.conf");
	defer missing.free();
	test::eq("dmg", missing.mode);  // no file: defaults
}

fn void hotkeys_and_filter_round_trip() @test
{
	config::Config a = config::defaults();
	defer a.free();
	test::eq("Tab", a.hot_keys[config::Hotkey.FAST.ordinal]);
	test::eq("leftshoulder", a.hot_pads[config::Hotkey.REWIND.ordinal]);
	test::eq("none", a.hot_pads[config::Hotkey.PAUSE.ordinal]);
	test::eq("F10", a.hot_keys[config::Hotkey.DEBUG.ordinal]);
	assert(a.set("key.rewind", "Backspace"));
	assert(a.set("key.debug", "F11"));
	assert(a.set("pad.pause", "start"));
	assert(a.set("filter", "lcd"));
	assert(!a.set("filter", "fuzzy"));
	config::Config b = config::defaults();
	defer b.free();
	b.parse(a.to_text(tmem), "round trip");
	test::eq("Backspace", b.hot_keys[config::Hotkey.REWIND.ordinal]);
	test::eq("F11", b.hot_keys[config::Hotkey.DEBUG.ordinal]);
	test::eq("start", b.hot_pads[config::Hotkey.PAUSE.ordinal]);
	test::eq("lcd", b.filter);
}

fn void dmg_palette_round_trip() @test
{
	config::Config a = config::defaults();
	defer a.free();
	test::eq("auto", a.dmg_palette);
	test::eq("", a.dmg_colors);
	assert(a.set("dmg-palette", "classic"));
	assert(a.set("dmg-palette", "4-h"));
	assert(!a.set("dmg-palette", "purple"));
	assert(a.set("dmg-colors", "#FFEEDD, aabbcc,778899,001122"));
	assert(!a.set("dmg-colors", "ffeedd,aabbcc,778899"));
	test::eq("4-h", a.dmg_palette);

	config::Config b = config::defaults();
	defer b.free();
	b.parse(a.to_text(tmem), "round trip");
	test::eq("4-h", b.dmg_palette);
	test::eq("#FFEEDD, aabbcc,778899,001122", b.dmg_colors);
}
