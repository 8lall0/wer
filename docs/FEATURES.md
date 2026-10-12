# Features

What wer emulates, and how it does on the hardware test suites. How to use
it is in [USAGE.md](USAGE.md); the link cable and its accessories in
[ACCESSORIES.md](ACCESSORIES.md).

- **Models**: Game Boy (DMG, also the first CPU DMG 0), Game Boy Pocket,
  Super Game Boy and Super Game Boy 2, Game Boy Color in each chip revision
  (CPU CGB 0 to E), and a Game Boy Advance running Game Boy games (games that
  look for one find it: B set at start, its sound timing, its screen's
  colours, no infrared port). CGB-only games switch to the Game Boy Color automatically.
- **Palettes**: original Game Boy games in the DMG's green, a Pocket's grey,
  a darker "classic" green, plain greys, any of the SGB's 32 palettes, or
  colours of your own.
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
  (Tamagotchi 3, with its clock and the buzzer that calls you, approximated),
  and the unlicensed and bootleg boards (BBD, Hitek, GGB-81, Li Cheng,
  Sintax, SKOB LEE8, the NT boards, Pokemon Jade/Diamond's, Rocket Games, Vast Fame
  VF001, Yong Yong, New Game Boy Color HK, Liebao, Chong Wu, La Sa Ma, the
  SL, LB, GBCK003 and "GB HiCol" multi-game carts, Duz's Pokemon 2 in 1; known by their logo, header or, for the
  163 dumps in MAME's lists, their CRC); the Nintendo Power GB Memory
  cartridge (its menu and up to seven games, each with its own MBC and part
  of the 128 KiB of RAM; its map from the `.map` beside the `.gb`, or worked
  out from the menu's list of games, as [gbnp](https://github.com/orangeglo/gbnp)
  builds them); battery saves (`.sav`, with the clocks in the formats other
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
  browsers with a short code. Infrared too, between two Game Boys here, and
  Hudson's GB KISS LINK: GB KISS files (`.gbf`) and Nectaris GB's maps to
  and from files.
- **WorkBoy**: the keyboard Fabtek made for the Game Boy (never released),
  with its clock: the computer's keyboard types on it.
- **Mobile Adapter GB**: the Japanese phone adapter of Pocket Monsters
  Crystal, Mobile Trainer, Net de Get and the other Mobile System GB games,
  online again through a [REON](https://github.com/REONTeam/reon) server,
  and calls between two copies of wer.
- **Turbo File GB, Power Antenna, Bardigun reader, Full Changer**: ASCII's
  save drive for the RPG Tsukuru GB games, Telefang's and Bugsite's light,
  Barcode Taisen Bardigun's card reader and Zok Zok Heroes' toy that sends
  its 70 heroes by infrared.
- **Pokémon Pikachu 2** and **Pocket Sakura**: the pedometer pets' gifts
  over the Game Boy Color's infrared port, to Pokémon Gold and Silver (watts
  as a Mystery Gift) and to Sakura Taisen GB (items and points).
- **Game Boy Printer**: printouts (Game Boy Camera photos, Pokédex pages,
  ...) become PNG files next to the game.
- **4-Player Adapter** (DMG-07): four Game Boys in one window for F-1 Race,
  Wave Race, Yoshi's Cookie, Faceball 2000 and the other four-player games.
- **Barcode Boy**: the card reader of Battle Space and Monster Maker: Barcode
  Saga; cards are swiped by typing their 13-digit number.
- **Save states** (9 slots per game), **rewind** (hold R, the left shoulder
  or the touch screen's << to run the game backwards), **pause**, **frame
  advance** and **fast forward**.
- **Zipped games**: a `.zip` opens like the ROM inside it (the first `.gb`
  or `.gbc` in it), from the command line, the menu, or dropped on the
  window. Saves, states and patches go by the zip's name (`game.sav` for
  `game.zip`).
- **Patches**: translations and hacks in IPS, UPS or BPS, applied as the game
  loads (the ROM file stays as it is): put `game.ips`, `game.ups` or
  `game.bps` next to `game.gbc`, or name one with `--patch=FILE`. UPS and BPS
  patches say which ROM they are for, so a patch for another version of the
  game is refused instead of making a broken one.
- **Cheats**: Game Genie and GameShark codes, per game, in **Menu →
  Cheats** (or `--cheat=CODE`); kept next to the game's saves in
  `game.cht`, a code per line (a `#` in front switches it off).
- **Recording**: F11 starts and stops recording the game, its picture as an
  animated GIF and its sound as a WAV, next to the game (`--record=NAME`
  records a whole run, with `--headless` too). Every frame the game runs goes
  in, fast forward included, so recordings play at the game's own speed.
- **Movies** (tool-assisted play): **Menu → Movie** records your play from
  power-on or from where you are, button by button, into `game-movie-N.wer`
  next to the game, and plays it back exactly. While recording, rewinding
  or loading a save state goes back in the movie and records again from
  there; pause (P) and frame advance (N) play it a frame at a time. Open or
  drop a `.wer` file to watch it; take over while one plays to record on
  from that point. (Not with the link cable; tilt and the camera aren't
  recorded.)
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
