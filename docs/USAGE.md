# Using wer

The command line, the controls, the debugger and where saves go. The link
cable's accessories have their own page, [ACCESSORIES.md](ACCESSORIES.md).

## Command line

```sh
wer game.gb                 # or start without a ROM and open one from the menu
wer --mode=cgb game.gbc
```

| Option | |
|---|---|
| `--mode=dmg\|mgb\|sgb\|sgb2\|cgb` | the model to emulate: `dmg` is a CPU DMG A/B/C (`dmg-0` the first DMGs), `mgb` a Game Boy Pocket, `cgb` a CPU CGB E, the last revision (the others with `cgb-0`, `cgb-a`, `cgb-b`, `cgb-c`, `cgb-d`), `gba` a Game Boy Advance |
| `--palette=classic` | the screen's colours: in the DMG and Pocket modes `auto` (green, a Pocket's grey: the default), `dmg`, `classic`, `pocket`, `grey`, an SGB palette `1-A` … `4-H`, or your own four, lightest first (`--palette=e0f8d0,88c070,346856,081820`); in the SGB modes an SGB palette |
| `--blend=off\|simple\|accurate` | frame blending, like the LCD's slow response (games that flicker objects for transparency look right): `simple` mixes each frame half and half with the last, `accurate` is SameBoy's model of the LCD |
| `--colors=balanced` | CGB/SGB colour correction, as the real screens looked: `off` (raw colours), `balanced` (the default), `accurate`, `boost`, `reduce`, `low` (SameBoy's modes) |
| `--filter=off\|sharp\|smooth\|lcd\|scanlines` | how the pixels are drawn: `sharp` keeps them crisp and even at any size (full screen, a phone), `smooth` blurs them, `lcd` shows the dot grid of a Game Boy's screen, `scanlines` dark lines between rows (the last two from 3x up) |
| `--screenshot=FILE` | with `--frames=N`: save the window (menu included) as a PNG after N frames, then quit |
| `--input=400:down,460:a` | press buttons at given frames (counted from the game's start): `a`, `b`, `start`, `select`, `up`, `down`, `left`, `right`, joined by `+` (`900:a+b`), held 6 frames or `*N` (`600:right*30`); with `--frames` and `--screenshot` or `--headless`, a game played the same way every time. An item can also work the device on `--link`, as its menu line does: `card=DIGITS` (Barcode Boy, Bardigun reader), `wave=1-70` (Full Changer), `watts=0-999` (Pikachu 2), `gift=0-53` (Pocket Sakura), e.g. `11020:card=4900363432103` |
| `--scale=1..4` | window size, multiples of 160x144 |
| `--no-boot` | skip the boot ROM |
| `--link-rom=ROM` | a second Game Boy in the window, running ROM, joined by the link cable |
| `--link=four` | four Game Boys on the 4-Player Adapter, all running the game |
| `--link=barcode` | the Barcode Boy (Menu → Swipe card) |
| `--link=kiss` | the GB KISS LINK (GB KISS files and Nectaris GB's maps: Menu → File, Map) |
| `--link=workboy` | the WorkBoy keyboard (for the WorkBoy program) |
| `--link=mobile` | the Mobile Adapter GB (desktop and phone) |
| `--link=turbo`, `antenna`, `bardigun`, `changer`, `pikachu`, `sakura` | the Turbo File GB, Power Antenna, Bardigun reader, Full Changer, Pokémon Pikachu 2, Pocket Sakura |
| `--link=printer` | the Game Boy Printer on the link port |
| `--record=NAME` | record the run: `NAME.gif` (the picture) and `NAME.wav` (the sound), until wer quits; with `--headless --frames=N --input=...` a recording made without a window |
| `--movie=FILE` | play a movie (`.wer`) from its start; with `--headless`, to its end unless `--frames` says otherwise |
| `--record-movie=FILE` | record a movie of the run from power-on (with `--input`, and `--headless` too) |
| `--patch=FILE` | apply an IPS, UPS or BPS patch to the game (instead of the one next to it, if any) |
| `--cheat=CODE` | a Game Genie (`ABC-DEF-GHI`) or GameShark (`01VVAAAA`) code, for this run |
| `--printer-log` | print every packet the printer gets and its answers |
| `--link=host` | wait for another wer (or BGB) to join over the network, on port 8765 |
| `--link=ADDRESS` | join one that waits there (`192.168.1.20`, or `host:port`) |
| `--sgb-log` | print the commands an SGB game sends |
| `--headless --frames=N` | no window: run N frames, write the last one to `wer-frame.ppm`; `--link` works there too (notices print to the terminal) |

Options given on the command line override `~/.wer/wer.conf` for that run.

## Controls

| | Keyboard | Gamepad |
|---|---|---|
| D-pad | arrow keys | d-pad or left stick |
| A / B | Z / X | right / bottom face button |
| Start / Select | Enter / Right Shift | Start / Back |
| Menu | Esc | Guide, or Back + Start |
| Open ROM | Ctrl+O, or drop the file on the window | |
| Save state 1-9 | Shift+F1 … Shift+F9 | Menu |
| Load state 1-9 | F1 … F9 | Menu |
| Screenshot | F12 (`game-shot-N.png` next to the game) | |
| Record (start / stop) | F11 (`game-rec-N.gif` and `.wav` next to the game) | |
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
way to it. The menu also switches the model, the palette and scale; changes
are saved to `~/.wer/wer.conf` (your own DMG colours as `dmg-colors =
e0f8d0,88c070,346856,081820` there, then `Custom` in the menu).

## Debugger

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

## Saves and states

Battery saves and save states are stored next to the ROM, named after it
without its extension: `game.sav`, as other emulators name it, and
`game.ss1` … `game.ss9` for `game.gb`. (Saves from wer 0.10 and before,
`game.gb.sav` and `game.gb.ss1`, are renamed the first time the game is
opened.) A state belongs to the game and the model; it keeps loading in
later versions of wer, which take the parts of the machine they still have
and leave the new ones as they are.
