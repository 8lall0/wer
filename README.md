# wer

<img src="resources/wer.svg" alt="" width="128" align="right">

A Game Boy, Super Game Boy and Game Boy Color emulator written in
[C3](https://c3-lang.org), with SDL3 for video, sound and input.

It aims at accuracy: the CPU, timer, PPU and APU are modelled at the level
the common hardware test suites check; results below.

**Play it in your browser:** https://8lall0.github.io/wer/ (bring your own
ROMs: they never leave the browser; touch controls on phones).

## Features

- **Models**: Game Boy (DMG, also the first CPU DMG 0), Game Boy Pocket,
  Super Game Boy and Super Game Boy 2, Game Boy Color in each chip revision
  (CPU CGB 0 to E), and a Game Boy Advance running Game Boy games (games that
  look for one find it: B set at start, its sound timing, its screen's
  colours, no infrared port). CGB-only games switch to the Game Boy Color automatically.
- **Super Game Boy**: game-controlled colours and borders, the 32 built-in
  palettes, the original SGB running about 2.4% fast like the real one.
- **Game Boy Color**: colour games, double speed, VRAM DMA, and original Game
  Boy games coloured the way a Game Boy Color does it (palettes picked from
  the title, or with a button combination during the boot logo).
- **Pixel-by-pixel PPU**: register changes in the middle of a line show up
  where they happen.
- **Cartridges**: MBC1 (including multicarts), MBC2, MBC3 with the real-time
  clock, MBC5 (with rumble), MBC7 (Kirby Tilt 'n' Tumble's accelerometer and
  EEPROM), the Game Boy Camera, MBC6 (Net de Get, with its flash chip), MMM01 multicarts, M161 (Mani's 4 in 1), the Wisdom Tree games' mapper, Sachen's MMC1 and MMC2, TPP1 (homebrew, with clock and rumble), HuC1 and HuC3 (with HuC3's clock), TAMA5
  (Tamagotchi 3, with its clock and the buzzer that calls you, approximated); battery saves (`.sav`, with the clocks in the formats other
  emulators use).
- **Game Boy Camera**: the camera sees through your webcam, the phone's
  front camera or the browser's camera (the system asks first; without a
  camera it sees noise). Photos are kept in the battery save.
- **Tilt and rumble**: tilt with a gamepad's left stick, I/J/K/L, or by
  tilting the phone (Android, and in a browser); rumble cartridges shake the
  gamepad, or vibrate the phone.
- **Own boot ROMs** for the DMG and the CGB, with the WER logo (sources in
  `bootrom/`); no Nintendo code. `--no-boot` starts games directly instead.
- **Link cable**: two Game Boys in one window, side by side (trade with
  yourself, Tetris versus with two gamepads), or two copies of wer over the
  network, in BGB's link protocol (so wer also links with BGB), or two
  browsers with a short code. Infrared too, between two Game Boys here.
- **Game Boy Printer**: printouts (Game Boy Camera photos, Pokédex pages,
  ...) become PNG files next to the game.
- **4-Player Adapter** (DMG-07): four Game Boys in one window for F-1 Race,
  Wave Race, Yoshi's Cookie, Faceball 2000 and the other four-player games.
- **Barcode Boy**: the card reader of Battle Space and Monster Maker: Barcode
  Saga; cards are swiped by typing their 13-digit number.
- **Save states** (9 slots per game), **rewind** (hold R, the left shoulder
  or the touch screen's << to run the game backwards), **pause**, **frame
  advance** and **fast forward**.
- **Cheats**: Game Genie and GameShark codes, per game, in **Menu →
  Cheats** (or `--cheat=CODE`); kept next to the game's saves in
  `game.cht`, a code per line (a `#` in front switches it off).
- **Debugger** (F10, desktop): registers, disassembly, breakpoints (with
  conditions) and watchpoints, stepping, memory, VRAM tiles, tile maps,
  objects and palettes, in a window of its own.
- **Gamepads** (any SDL3 gamepad), **key remapping**, **window scale** 1x-4x,
  a menu, a file dialog to open ROMs, and settings kept in `~/.wer/wer.conf`.

## Test results

| Suite | Result |
|---|---|
| [Mooneye Test Suite](https://github.com/Gekkio/mooneye-test-suite) | 112/112 (every test for DMG, DMG-0, Pocket, SGB, SGB2 and CGB) |
| [Mealybug Tearoom](https://github.com/mattcurrie/mealybug-tearoom-tests) | DMG 24/24, CGB 27/27 |
| [dmg-acid2](https://github.com/mattcurrie/dmg-acid2), [cgb-acid2](https://github.com/mattcurrie/cgb-acid2) | pixel-exact |
| Blargg `cpu_instrs`, `instr_timing`, `mem_timing`, `mem_timing-2`, `halt_bug`, `interrupt_time` | pass |
| Blargg `dmg_sound`, `cgb_sound` | 12/12, 12/12 |
| Blargg `oam_bug` | 8/8 (`7-timing_effect` prints more than its 8 KB text buffer: the harness empties it) |
| [SameSuite](https://github.com/LIJI32/SameSuite) | 78/78 (one on the Game Boy Advance model) |
| [Gambatte test suite](https://github.com/pokemon-speedrunning/gambatte-core) | 5225/5225 |
| [AGE test ROMs](https://github.com/c-sp/age-test-roms) | 119/119 on the revisions each test names (DMG, CGB-B, C, E) |
| [gbmicrotest](https://github.com/aappleby/GBMicrotest) | 480/482 (the other two are disabled in its own runner) |
| [Mooneye, wilbertpol's 2016 fork](https://github.com/wilbertpol/mooneye-gb) | 190/190 (CGB tests on a CGB-E) |
| cgb-acid-hell, bully, turtle-tests, scribbltests, little-things-gb firstwhite and tellinglys, Mooneye sprite_priority, strikethrough, [rtc3test](https://github.com/aaaaaa123456789/rtc3test), [MBC3 Tester](https://github.com/EricKirschenmann/MBC3-Tester-gb) | 31/31 |
| [SingleStepTests sm83](https://github.com/SingleStepTests/sm83) | every case, including bus timing |

## Building

Needs [c3c](https://github.com/c3lang/c3c) 0.8.x and SDL 3.2 or newer.

```sh
c3c build -O3        # build/wer
```

Windows x64, cross-compiled from Linux (needs curl and unzip, plus the
Windows SDK c3c fetches with `c3c fetch-sdk windows`):

```sh
c3c build windows -O3 --trust=full   # build/wer.exe
```

It downloads SDL's own Windows build into `deps/sdl3-windows/`;
`deps/sdl3-windows/lib/SDL3.dll` has to sit next to `wer.exe`. It also needs
llvm-rc for the icon, manifest and version information
(`resources/windows/`). `wer.exe` is a windowed program; started from a
terminal it prints there.

macOS on Apple silicon (macOS 11 or newer), cross-compiled from Linux (needs
clang, lld, cmake, plus the macOS SDK from `c3c fetch-sdk macos`):

```sh
c3c build macos -O3 --trust=full     # build/wer_macos
```

It builds SDL into `deps/sdl3-macos-aarch64/` and links it in, so the binary
needs nothing else. It is signed ad hoc only: macOS asks to confirm the first
start of a downloaded copy (right-click > Open, or
`xattr -d com.apple.quarantine wer_macos`).

Android (arm64, Android 5 or newer), with the Android SDK (platform 37,
build-tools 37.0.0, NDK 30.0.16248370) and a JDK 17 or 21 for Gradle:

```sh
scripts/build-android.sh            # build/wer-<version>-android-arm64.apk
```

It builds SDL as `libSDL3.so` and wer as `libmain.so`, and packages them with
`android/` (Gradle) and SDL's Java side. On a phone wer shows touch controls
around the picture (Back opens the menu), opens ROMs through Android's file
picker, and keeps settings, battery saves and save states in its own folder.

In a web browser (WebAssembly), with [Emscripten](https://emscripten.org)
(`scripts/build-web.sh` uses `~/emsdk` if `emcc` isn't on the PATH):

```sh
scripts/build-web.sh                 # build/web/: index.html, wer.js, wer.wasm
python3 -m http.server -d build/web  # then open http://localhost:8000
scripts/deploy-web.sh                # publish it on GitHub Pages (gh-pages)
```

It runs at full speed in the page; ROMs open through the page's button and
never leave the browser, and settings, battery saves and save states are kept
in its storage (IndexedDB). It uses Emscripten's own SDL3 port.

The desktop and Android builds use SDL 3.4.18 (`SDL_VERSION=x.y.z` picks another release).

Prebuilt Linux x86-64 binaries are on the
[releases page](https://github.com/8lall0/wer/releases).

## Running

```sh
wer game.gb                 # or start without a ROM and open one from the menu
wer --mode=cgb game.gbc
```

| Option | |
|---|---|
| `--mode=dmg\|mgb\|sgb\|sgb2\|cgb` | the model to emulate: `dmg` is a CPU DMG A/B/C (`dmg-0` the first DMGs), `mgb` a Game Boy Pocket, `cgb` a CPU CGB C (the others with `cgb-0`, `cgb-a`, `cgb-b`, `cgb-c`, `cgb-d`, `cgb-e`), `gba` a Game Boy Advance |
| `--palette=1-A` … `4-H` | SGB built-in palette (SGB modes) |
| `--blend=off\|simple\|accurate` | frame blending, like the LCD's slow response (games that flicker objects for transparency look right): `simple` mixes each frame half and half with the last, `accurate` is SameBoy's model of the LCD |
| `--colors=balanced` | CGB/SGB colour correction, as the real screens looked: `off` (raw colours), `balanced` (the default), `accurate`, `boost`, `reduce`, `low` (SameBoy's modes) |
| `--filter=off\|sharp\|smooth\|lcd\|scanlines` | how the pixels are drawn: `sharp` keeps them crisp and even at any size (full screen, a phone), `smooth` blurs them, `lcd` shows the dot grid of a Game Boy's screen, `scanlines` dark lines between rows (the last two from 3x up) |
| `--screenshot=FILE` | with `--frames=N`: save the window (menu included) as a PNG after N frames, then quit |
| `--scale=1..4` | window size, multiples of 160x144 |
| `--no-boot` | skip the boot ROM |
| `--link-rom=ROM` | a second Game Boy in the window, running ROM, joined by the link cable |
| `--link=four` | four Game Boys on the 4-Player Adapter, all running the game |
| `--link=barcode` | the Barcode Boy (Menu → Swipe card) |
| `--link=printer` | the Game Boy Printer on the link port |
| `--cheat=CODE` | a Game Genie (`ABC-DEF-GHI`) or GameShark (`01VVAAAA`) code, for this run |
| `--printer-log` | print every packet the printer gets and its answers |
| `--link=host` | wait for another wer (or BGB) to join over the network, on port 8765 |
| `--link=ADDRESS` | join one that waits there (`192.168.1.20`, or `host:port`) |
| `--sgb-log` | print the commands an SGB game sends |
| `--headless --frames=N` | no window: run N frames, write the last one to `wer-frame.ppm` |

Options given on the command line override `~/.wer/wer.conf` for that run.

### Controls

| | Keyboard | Gamepad |
|---|---|---|
| D-pad | arrow keys | d-pad or left stick |
| A / B | Z / X | right / bottom face button |
| Start / Select | Enter / Right Shift | Start / Back |
| Menu | Esc | Guide, or Back + Start |
| Open ROM | Ctrl+O | |
| Save state 1-9 | Shift+F1 … Shift+F9 | Menu |
| Load state 1-9 | F1 … F9 | Menu |
| Screenshot | F12 (`game-shot-N.png` next to the game) | |
| Pause | P | |
| Frame advance | N | |
| Debugger (desktop) | F10 | |
| Fast forward | hold Tab | hold right shoulder |
| Rewind | hold R | hold left shoulder |
| Tilt (MBC7 games) | I / J / K / L | left stick |
| Link cable, 2 players here: the other Game Boy | ` | second gamepad |

Every Game Boy button, and fast forward, rewind, pause, frame advance, the
screenshot key and the debugger's, can be rebound to a key or a gamepad button in
**Menu → Controls**; a hotkey whose key is bound to a Game Boy button gives
way to it. The menu also switches the model, SGB palette and scale; changes
are saved to `~/.wer/wer.conf`.

### Debugger

F10 opens the debugger in a second window (on a desktop): the CPU's
registers and flags, the code around PC, memory and the stack, the tiles in
VRAM (both banks on a Game Boy Color), the two tile maps (the screen and
the window outlined), the 40 objects and the palettes.
With its window in front:

| | |
|---|---|
| Space or F5 | pause / go on |
| S or F7 | run one instruction |
| O or F8 | step over a CALL or RST |
| C | run to the cursor |
| B or F9 | breakpoint at the cursor (it stops before that instruction runs) |
| Shift+B | breakpoint with a condition: `A=05`, `HL=C000`, `BANK=3` (a register, or the ROM bank) |
| W | watch an address for writes (it stops after the instruction); Shift+W: reads and writes |
| Up / Down, Home | move the cursor; back to PC |
| PgUp / PgDn | scroll memory (with Shift by $1000) |
| G, J | type an address (hex, Enter) to show in memory, in the code |
| Tab | memory, tiles, tile maps, objects and palettes |
| Esc or F10 | close it |

Breakpoints work with one Game Boy (not with two or four on the cable).

### Link cable

**Menu → Link** picks how the cable is plugged in (Left/Right to choose,
Enter to plug it in):

- **2 players here** asks for the second game (the same ROM is fine: its
  battery save becomes `game-2.sav`) and shows both Game Boys side by
  side. The keyboard, touch and the first gamepad play one of them (` swaps
  which), a second gamepad the other. Their infrared ports see each other
  too (the Game Boy Color's, and HuC1/HuC3 cartridges'): infrared needs
  both Game Boys here, its pulses are timed to the cycle.
- **4 players here** puts four copies of the game on the 4-Player Adapter,
  two by two in the window: gamepads 1-4 play players 1-4, the keyboard and
  touch player 1 (` moves them on to the next player). Players 2-4 keep
  their own battery saves (`game-2.sav` ...).
- **Barcode Boy** plugs in the card reader: **Swipe card...** in the menu
  asks for a card's 13-digit barcode number (printed under its bars).
- **Printer** plugs in the Game Boy Printer: each printout is saved as a
  PNG next to the game (`game-print-1.png`, `-2`, ...; in a browser it
  downloads).
- **Host** waits for the other side on port 8765; **Join** asks for the
  host's address (it is remembered). Each side runs its own game; a
  transfer's bytes cross the network when it happens, so a slow connection
  slows link play down, but nothing goes out of step.

In a browser, Host shows a short code (and a link with it) and Join asks
for it: the two browsers then talk directly (WebRTC; PeerJS's public server
only introduces them). Opening `…/?link=host` hosts straight away, and
`…/?link=CODE` joins. The connection is direct, with no relay server: networks
that keep their devices apart (guest or "isolated" Wi-Fi, some firewalls)
block it, and the page says so; a phone's hotspot usually works.

Battery saves and save states are stored next to the ROM, named after it
without its extension: `game.sav`, as other emulators name it, and
`game.ss1` … `game.ss9` for `game.gb`. (Saves from wer 0.10 and before,
`game.gb.sav` and `game.gb.ss1`, are renamed the first time the game is
opened.) A state belongs to the game and the model; it keeps loading in
later versions of wer, which take the parts of the machine they still have
and leave the new ones as they are.

## Source layout

```
src/cpu/       the SM83 CPU
src/ppu/       the picture: pixel FIFO, mode timing and interrupts
src/apu/       the sound (from SameBoy)
src/machine/   the Game Boy itself: bus (mmu), timer, joypad, SGB, save states,
               rewind, cheats, colour correction
src/bootrom/   wer's boot ROMs, generated by scripts/build-bootroms.sh
src/cart/      cartridges and their mappers, clocks and the Game Boy Camera
src/link/      the link port: cable, network play, Printer, 4-Player Adapter,
               Barcode Boy
src/frontend/  the program: main, settings, window, menus, filters, touch,
               tilt, webcam, screenshots
src/platform/  Android, Windows and web specifics
test/unit/     tests of each part
test/suites/   the test ROM suites' runners (the ROMs go in test/<suite>/)
```

## Tests

```sh
scripts/fetch-mooneye.sh      # and fetch-mealybug.sh, fetch-acid2.sh,
scripts/fetch-blargg.sh       #     fetch-sm83-tests.sh, fetch-samesuite.sh,
                              #     fetch-gambatte.sh, fetch-age.sh,
                              #     fetch-gbmicrotest.sh, fetch-wilbertpol.sh,
                              #     fetch-screens.sh
c3c test
./build/testrun --test-nocapture --test-filter mooneye   # a suite's report
WER_GAMBATTE=1 c3c test -O2 --test-nocapture --test-filter gambatte
```

The test ROM suites run on all CPU cores (`WER_THREADS=n` to change that;
`c3c test -O2` is about four times faster than the default unoptimized
build). The Gambatte suite runs only when asked (thousands of ROMs, under a
minute optimized); its passing checks are recorded in `test/suites/gambatte_pass.txt`.

`test/unit/fuzz_test.c3` throws random ROMs (every mapper, DMG, CGB and
SGB) and damaged save states at the emulator; run it with bounds checks on,
for as long as you like:

```sh
WER_FUZZ=5000 WER_FUZZ_LOG=1 c3c test -O1 --test-filter fuzz --test-nocapture
```

The test ROMs are not in the repository; each fetch script downloads its
suite into `test/` (SameSuite is built from source and needs RGBDS). Without
them, those tests pass with a note.

## Boot ROMs

`bootrom/` holds the sources of wer's DMG and CGB boot ROMs (RGBDS);
`scripts/build-bootroms.sh` rebuilds them into `src/bootrom/`. The CGB one's
compatibility palettes come from Pan Docs and The Cutting Room Floor's notes
on the Game Boy Color boot ROM.

## Development

Wer began as a hand-written project. Since then it has been developed together
with [Claude Code](https://claude.com/claude-code), which wrote the test
harnesses and a large part of the emulator (among others the pixel-by-pixel
PPU, Game Boy Color support, the APU accuracy work and the boot ROMs), under
the author's direction and review.

## License

[MIT](LICENSE).

The sound (`src/apu/`) is a port of [SameBoy](https://github.com/LIJI32/SameBoy)'s
APU and the pixel renderer follows SameBoy's; those parts also carry
SameBoy's MIT licence ([LICENSE-sameboy](LICENSE-sameboy)).

`src/cart/tama5.c3` and `src/cart/sachen.c3` follow [mGBA](https://mgba.io)'s TAMA5
and Sachen mappers and are under the
[Mozilla Public License 2.0](https://mozilla.org/MPL/2.0/) instead.
