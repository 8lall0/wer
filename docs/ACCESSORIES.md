# The link cable and accessories

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
- **GB KISS LINK** is Hudson's infrared modem (HC-749), with wer as the PC
  it was plugged into. In Nectaris GB's **GB KISS** menu, "send to PC"
  (パソコンニオクル) saves the map as `game-map-1.bin`, `-2`, ... next to the
  game (512 bytes, the game's own format), and "receive from PC"
  (パソコンカラモラウ) gives the game the map picked on the menu's **Map** line
  (the newest at first). Any GB KISS game's **GB KISS menu** trades files
  (`.gbf`, such as the programs on [gbkiss.org](https://gbkiss.org/)) with
  it too: one the menu sends (送信) is saved as `game-kiss-1.gbf`, `-2`, ...;
  when the menu receives (Start, or 受信) it gets the file picked on the
  **File** line: a `.gbf` opened or dropped on the window, or one received
  before.
- **WorkBoy** plugs in the WorkBoy keyboard, for the WorkBoy program (its
  cartridge, not included). Once the program talks to it, the computer's
  keyboard types on the WorkBoy: letters, digits and signs as typed, F1-F9
  its nine tools (clock, temperature, money, calculator, date, conversion,
  records, world time, phone book), the arrows, Enter, Backspace and Esc;
  **Shift+Esc** opens wer's menu (a gamepad's menu button too). At its
  first start the program asks for the home city: N and P go through the
  cities, S picks one. Its clock
  is the computer's local time, set ahead or back as the program sets it
  (kept in `wer.conf` as `workboy-clock`). On a phone its keyboard comes up.
- **Mobile Adapter** plugs in the Mobile Adapter GB (not in a browser: it
  needs sockets). Its memory, which Mobile Trainer fills in (the account,
  the ISP's number), is `~/.wer/mobile.bin`; the `config.bin` a REON
  server gives its users works there as it is. The game calls the ISP
  and logs in by itself; Nintendo's servers are long gone, so the names
  it looks up go to the DNS servers in `wer.conf`: `mobile-dns =
  ADDRESS[:PORT]` (and `mobile-dns2`), those of a REON server. Without
  them only calls work. A call to a 12-digit number reaches another wer at
  that IP address (`127000000001` for 127.0.0.1), waiting for a call in
  its game, on port 1027 (`mobile-port`); the waiting side's notice shows
  its own number. Also in `wer.conf`: `mobile-adapter = blue | yellow |
  red` (which phone network's adapter, blue by default) and
  `mobile-unmetered = yes` (a flat-rate plan: Crystal then lifts its daily
  battle time limit). `WER_MOBILE_TRACE=1` prints each command the game
  sends it.
- **Turbo File GB** plugs in ASCII's save drive (with its memory card
  in), for RPG Tsukuru GB and RPG Tsukuru GB2: what the games save there
  is `~/.wer/turbo-file.bin`, one drive for every game, as the real one.
- **Power Antenna** plugs in the light of Keitai Denjuu Telefang (and
  Bugsite's Bug Sensor): it shows as a red dot at the picture's top right
  while the game lights it.
- **Bardigun reader** plugs in Barcode Taisen Bardigun's card reader:
  **Swipe card...** in the menu asks for the card's 13-digit barcode, as
  for the Barcode Boy.
- **Full Changer** is Zok Zok Heroes' toy: the menu's **Character** line
  picks one of the 70 Cosmic Characters, and Enter on it waves the toy;
  the game must be waiting for it.
- **Pikachu 2** is the Pokémon Pikachu 2 for Pokémon Gold and Silver: on
  the game's Mystery Gift screen (main menu, once the girl in Goldenrod's
  department store has unlocked it), Enter on the menu's **Watts** line
  sends that many watts and the game gets the pet's gift for them (Berry
  at 100, Great Ball at 300 ... Rare Candy at 999), with no five-a-day
  limit. The exchange follows the games' Mystery Gift protocol (from the
  pret disassemblies); any region's game works.
- **Pocket Sakura** is the pet of Sakura Taisen GB: in the game's title
  menu, page right to 通信, then ポケットサクラ and はい; while it waits
  (受信待ちです), Enter on the menu's **Gift** line sends it: one of the
  game's 22 items (it comes into the Romandō shop) or a points bonus (1000
  to 65535; the game gives each once). Sakura Taisen GB shares Pokémon's infrared code;
  the pet's message was worked out from the game itself. Which gifts the
  real pet sends, and when, isn't known, so you pick.
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
