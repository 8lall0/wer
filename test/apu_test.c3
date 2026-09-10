module apu_test;

import apu, mmu;
import std::core::test;

fn apu::Apu* fresh() {
	apu::Apu* a = mem::new(apu::Apu);
	a.init();
	a.set_ring(mem::new_array(short, 4096));
	a.power = true;
	return a;
}

fn void drop(apu::Apu* a) {
	free(a.ring.ptr);
	free(a);
}

fn void power_off_zeros_channel_registers() @test
{
	apu::Apu* a = fresh();
	defer drop(a);

	a.write(0xFF12, 0xF0); // CH1 envelope -> DAC on
	a.write(0xFF14, 0x80); // trigger CH1
	test::@check(a.ch1.enabled, "CH1 running");

	a.write(0xFF26, 0x00); // power off
	test::@check(!a.ch1.enabled, "power off disables channels");
	test::eq((char)0x00, a.read(0xFF12) & 0xFF); // ... hmm read mask; check raw
	test::eq((char)0x00, a.ch1.nr2);
	test::@check(!a.power, "power flag cleared");
}

fn void read_masks_applied() @test
{
	apu::Apu* a = fresh();
	defer drop(a);

	// NR13 (write-only) always reads 0xFF.
	a.write(0xFF13, 0x55);
	test::eq((char)0xFF, a.read(0xFF13));

	// NR11 low 6 bits are write-only (length); duty bits read back.
	a.write(0xFF11, 0xC0); // duty 3, length 0
	test::eq((char)0xFF, a.read(0xFF11)); // 0xC0 | 0x3F mask

	// NR52: bits 0-3 = channel status, bits 4-6 read 1, bit 7 = power.
	test::@check((a.read(0xFF26) & 0x80) != 0, "NR52 power bit");
	test::@check((a.read(0xFF26) & 0x70) == 0x70, "NR52 unused bits read 1");
}

fn void trigger_enables_and_dac_gates() @test
{
	apu::Apu* a = fresh();
	defer drop(a);

	// DAC off (envelope upper 5 bits zero) -> trigger does not enable.
	a.write(0xFF17, 0x00);
	a.write(0xFF19, 0x80);
	test::@check(!a.ch2.enabled, "no DAC -> channel stays off");

	a.write(0xFF17, 0x80); // volume 8, DAC on
	a.write(0xFF19, 0x80);
	test::@check(a.ch2.enabled, "DAC on + trigger -> enabled");
	test::@check((a.read(0xFF26) & 0x02) != 0, "NR52 shows CH2 active");
}

fn void length_counter_disables_channel() @test
{
	apu::Apu* a = fresh();
	defer drop(a);

	a.write(0xFF21, 0xF0);       // CH4 DAC on
	a.write(0xFF20, 0x3F);       // length load 0x3F -> length = 1
	a.write(0xFF23, 0xC0);       // trigger + length enable
	test::@check(a.ch4.enabled, "CH4 running");

	// One length clock (frame sequencer step 0) should expire it.
	a.ch4.clock_length();
	test::@check(!a.ch4.enabled, "length expired -> channel off");
}

fn void envelope_decreases_volume() @test
{
	apu::Apu* a = fresh();
	defer drop(a);

	a.write(0xFF12, 0x83); // vol 8, decrease, period 3
	a.write(0xFF14, 0x80); // trigger
	test::eq((char)8, a.ch1.env.volume);

	for (int i = 0; i < 3; i++) a.ch1.env.clock();
	test::eq((char)7, a.ch1.env.volume);
}

fn void wave_ram_readable_writable() @test
{
	apu::Apu* a = fresh();
	defer drop(a);
	a.write(0xFF30, 0xAB);
	a.write(0xFF3F, 0xCD);
	test::eq((char)0xAB, a.read(0xFF30));
	test::eq((char)0xCD, a.read(0xFF3F));
}

fn void square_produces_alternating_output() @test
{
	apu::Apu* a = fresh();
	defer drop(a);

	a.write(0xFF11, 0x80);  // duty 2 (50%)
	a.write(0xFF12, 0xF0);  // volume 15
	a.write(0xFF13, 0xF8);
	a.write(0xFF14, 0x87);  // freq 0x7F8 -> timer period 32 T

	bool saw_high;
	bool saw_low;
	for (int i = 0; i < 64; i++) {
		char o = a.ch1.output();
		if (o == 15) saw_high = true;
		if (o == 0) saw_low = true;
		a.ch1.step(16);
	}
	test::@check(saw_high && saw_low, "square wave toggles between 0 and volume");
}

fn void routes_through_mmu() @test
{
	mmu::Mmu m;
	m.apu.power = true;
	m.set(0xFF25, 0xF3); // NR51 panning
	test::eq((char)0xF3, m.apu.nr51);
	test::eq((char)0xF3, m.get(0xFF25));

	m.set(0xFF1A, 0x80); // CH3 DAC on
	m.set(0xFF1E, 0x80); // trigger CH3
	test::@check(m.apu.ch3.enabled, "CH3 triggered via MMU");
}

fn void tick_generates_samples() @test
{
	apu::Apu* a = fresh();
	defer drop(a);

	a.write(0xFF25, 0xFF); // full panning
	a.write(0xFF24, 0x77); // full master volume
	a.write(0xFF11, 0x80);
	a.write(0xFF12, 0xF0);
	a.write(0xFF14, 0x87);

	// One frame worth of T-cycles (with its 8 frame-sequencer steps).
	a.tick(70224, 8);

	short[2048] buf;
	uint n = a.drain(&buf);
	// 70224 T * 48000 / 4194304 ~= 803.6 stereo frames = ~1607 s16 samples
	test::@check(n >= 1560 && n <= 1650, "~1607 s16 samples per video frame");

	bool nonzero;
	for (uint i = 0; i < n; i++) if (buf[i] != 0) nonzero = true;
	test::@check(nonzero, "audio output is not silent");
}
