# Bootleg boards known to hhugboy, described

What the hhugboy emulator (tzlion and contributors, https://github.com/tzlion/hhugboy)
knows about some boards wer lacks, and how it recognises bootleg games, written down as
hardware behaviour, with no code, to implement in wer independently.

Licences of the sources read:

| hhugboy file | Licence | Here |
|---|---|---|
| `MbcUnlSkobLee8.cpp/.h` (taizou, 2024) | CC0, and GPL-2 as part of hhugboy | may be ported directly; described anyway |
| `MbcUnlLbMulti.cpp` (taizou, 2016) | CC0 + GPL-2 | described |
| `MbcNin5_LogoSwitch.cpp` (NewRisingSun, 2020) | CC0 + GPL-2 | described |
| `MbcUnlPoke2in1.cpp` (taizou, VBA lineage) | GPL-2 only | described only |
| `CartDetection.cpp` (taizou, VBA lineage) | GPL-2 only | only facts taken (signatures) |
| `AbstractMbc.h` (`switchOrder`) | GPL-2 only | only its bit numbering taken |

## 1. SKOB "LEE8" PCB (Sango 5, Final Fantasy X and Digimon D-3 bootlegs, ...)

An MBC5 with two additions, both on the switchable ROM bank:

- **Bank number shuffle.** The value written to `$2000-$2FFF` is kept as
  "the requested bank", then its bits are permuted before MBC5 sees it. The
  permutation depends on a mode (3 bits), set by writes to addresses with
  `addr & $F003 == $5001` (i.e. `$5001`, `$5005`, ... `$5FFD`), value bits 0-2.
  Setting the mode immediately re-applies the last requested bank.
  - mode 0: no shuffle;
  - modes 5 and 7 (7 is the power-on default): source bits, for destination
    bits 0 to 7 (bit 0 = least significant): 1, 0, 3, 2, 7, 5, 4, 6
    (hhugboy lists it from the most significant bit: {1,3,2,0,5,4,7,6});
  - other modes: unknown (treat as no shuffle).
- **XOR on ROM data.** Every byte read from `$4000-$7FFF` is XORed with one of
  four values, picked by the low 2 bits of the bank number *after* the
  shuffle. The four values are written at `$7000-$7FFF`, the value index
  being address bits 0-1; such a write takes effect at once (re-pick by the
  current bank) and goes no further (not to MBC5). Power-on values: $55,
  $AA, $F0, $0F; but no XOR is applied until the first bank write.
- Everything else is MBC5 (RAM, its banks).

Recognised by: the byte sum of the 48 bytes at `$0184` (a second logo,
"Yiutoudz") being 4932, unless the dump is "fixed" (decrypted): such games
keep their own bank number as the last byte of each bank, so `$7FFF` = 1 and
`$BFFF` = 2 mean a plain MBC5 dump.

## 2. Logo switching (MBC5 bootlegs)

Some bootlegs keep their own logo at `$0184` and pass Nintendo's boot ROM check
anyway: the board counts ROM reads and, while the boot ROM runs, moves reads
up by `$80` (address bit 7 set). On a DMG the boot ROM reads the logo 48
times, all moved, so it compares the hidden copy at `$0184`. A write to WRAM
(which only the CGB boot ROM does before reading the logo) or 48 reads skip
that phase; a second 48 reads pass unmoved, after which only reads of the
logo area (`$0104-$0133`) are moved. A read of `$0100` (the game starting)
turns all of this off for good.
**wer doesn't need this**: its own boot ROMs don't check the logo, and the
games don't read it after boot.

## 3. "LB" multi-game carts

Same protocol as the SL multi-game carts MAME documents (wer: `SLMULTI`):
commands at `$5xxx`, arguments at `$7xxx`; `$AA` ROM base, `$BB` RAM, `$55`
size and mode (bits 5-6 both set: MBC1 games), bit 7 a reset. hhugboy adds
two observations, both already true of wer's `SLMULTI`: the first base write
is followed by a stray second write to `$7xxx` (ignored: a command takes
one argument), and after `$55` the configuration is locked. In MBC1 mode,
bank writes to `$3000-$3FFF` behave like `$2000-$2FFF`, and 0 means 1.

Recognised by: title "POKEMON_GLDAAUJ" in a 4 MiB ROM (SL 36 in 1, with
Pokemon Gold), or "TIMER MONSTER" in an 8 or 16 MiB ROM (Vast Fame 18 in 1,
12 in 1 Silver).

## 4. Rocket Games, Smartcom

Recognised by: the byte sum of the 48 bytes at `$0104` being 2756 (Rocket
Games) or 4850 (Smartcom). (MAME's board; wer: `ROCKET`.)

## 5. "Pokemon 2 in 1" (Duz's Pokemon, Duz's SGB Pack)

Fan-made compilations (not commercial bootlegs), whose board behaviour
hhugboy defines:

- `$0000-$1FFF`: RAM enable when bits 1 and 3 are both set; bits 6-7 both set
  also arm the game switch below.
- `$2000-$3FFF`: ROM bank, 7 bits, 0 means 1, plus a base (below), for
  `$4000-$7FFF`.
- `$4000-$5FFF`: RAM bank, 2 bits (only with more than 8 KiB of RAM).
- Game switch: while armed and not yet done, a write to `$A100` picks the
  game: value 1: base 2 (banks), $C0: keep the menu and lock, anything else:
  base 66. The base also moves `$0000-$7FFF` (32 KiB) to that bank, and
  later bank writes add it.
- RAM at `$A000-$BFFF` is written whether enabled or not.

Recognised by: title "POKEMON RED" with ROM size code 6, or "SGBPACK".

## 6. More second-logo signatures

hhugboy sums the 48 bytes at `$0184`; wer (after mGBA) takes their CRC, so a
logo variant with a different CRC goes unrecognised. Sums hhugboy knows that
wer's CRCs may not cover:

| Sum at `$0184` | Logo | Board |
|---|---|---|
| 4048 | "GK.RX" (Gaoke/Hitek x Ruanxin) | HITEK |
| 4639 | BBD | BBD, unless fixed (`$7FFF`=1 and `$BFFF`=2) |
| 3334 | "S-GBC" (SKOB's Pocket Monsters Crystal, by BBD) | BBD, same check |
| 5092 | Fiver Firm (e'Fighter Hot and later BBD fighters) | BBD, same check |
| 4876 | "Niutoude" (Li Cheng) | LI_CHENG |
| 4125, 4138 | Sintax "Kwichvu", a variant (Harry Potter) | SINTAX, unless `$7FFF` is 0 or 1 |
| 4932 | "Yiutoudz" | SKOB LEE8, see 1 |
| 4844, 6127, 4406 | V.Fame, SOUL (Falchion), DIGI (italic) | VF001 |
| 2692 | "DIGI." | GGB81 |

wer keeps the CRCs and tries these sums when none matches (`hhugboy_mbc`).
