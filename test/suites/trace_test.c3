module trace_test;
import gameboy, mmu, cpu, ppu, std::io, std::io::file, std::os::env;
// A debugging aid, not a test: WER_TRACE_ROM=<rom> [WER_TRACE_CGB=1]
// [WER_TRACE_FRAMES=n] c3c test --test-filter trace_test --test-nocapture
// prints every IO access ("R/W reg=value ly <line> lc <dot>"), interrupt
// dispatch ("INT") and each line's mode 0 start ("M0"), in the format of an
// instrumented Gambatte build, to compare timings line by line.
fn void trace() @test {
	String? rom = env::tget_var("WER_TRACE_ROM");
	if (catch rom) return;
	bool cgb = @ok(env::tget_var("WER_TRACE_CGB"));
	int frames = 2;
	if (try f = env::tget_var("WER_TRACE_FRAMES").to_int()) frames = f;
	char[] data = file::load_temp(rom)!!;
	gameboy::GameBoy gb = gameboy::new(false, cgb ? mmu::Model.CGB : mmu::Model.DMG);
	defer gb.destroy();
	gb.load_rom(data);
	cpu::io_trace = true;
	ppu::trace_m0 = true;
	ulong t;
	while (t < 70224UL * (ulong)frames) {
		uint m = gb.step();
		t += gb.mmu.double_speed ? (ulong)m * 2 : (ulong)m * 4;
	}
	cpu::io_trace = false;
}
