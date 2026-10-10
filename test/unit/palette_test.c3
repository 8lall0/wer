module palette_test;

import display;
import std::core::test;

fn void colors_parse_and_print() @test
{
	char[12] c;
	assert(display::parse_colors("e0f8d0,88c070,346856,081820", &c));
	test::@check(c == display::PALETTE, "the DMG green");
	assert(display::parse_colors("#9BBC0F, #8bac0f, #306230, #0F380F", &c));
	test::@check(c == display::PALETTE_CLASSIC, "with # and spaces, any case");
	test::eq("9bbc0f,8bac0f,306230,0f380f", display::colors_text(c));

	char[12] before = c;
	foreach (bad : (String[]){ "", "e0f8d0,88c070,346856", "e0f8d0,88c070,346856,081820,ffffff",
		"e0f8d,88c070,346856,081820", "e0f8d00,88c070,346856,081820", "e0f8dg,88c070,346856,081820", ",,," }) {
		test::@check(!display::parse_colors(bad, &c), "refused");
	}
	test::@check(c == before, "untouched when refused");
}

fn void dmg_palettes_by_name() @test
{
	test::eq(0, display::dmg_palette_index("auto"));
	test::eq(display::DMG_SGB_FIRST, display::dmg_palette_index("1-A"));
	test::eq(display::DMG_CUSTOM - 1, display::dmg_palette_index("4-h"));
	test::eq(display::DMG_CUSTOM, display::dmg_palette_index("custom"));
	test::eq(-1, display::dmg_palette_index("5-A"));
	for (int i = 0; i < display::DMG_PALETTE_COUNT; i++) {
		test::eq(i, display::dmg_palette_index(display::dmg_palette_name(i)));
		test::@check(display::dmg_palette_label(i).len <= 7, "fits the menu at 1x");
	}
}

fn void dmg_palette_colors() @test
{
	char[12] custom = display::PALETTE_GREY;
	test::@check(display::dmg_palette_rgb(0, false, custom) == display::PALETTE, "auto: green on a DMG");
	test::@check(display::dmg_palette_rgb(0, true, custom) == display::PALETTE_MGB, "auto: grey on a Pocket");
	test::@check(display::dmg_palette_rgb(display::dmg_palette_index("classic"), true, custom) == display::PALETTE_CLASSIC, "classic");
	test::@check(display::dmg_palette_rgb(display::DMG_CUSTOM, false, custom) == display::PALETTE_GREY, "custom");
	char[12] sgb;
	display::palette_rgb("2-C", &sgb);
	test::@check(display::dmg_palette_rgb(display::dmg_palette_index("2-C"), false, custom) == sgb, "an SGB palette");
}
