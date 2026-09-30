; wer CGB boot ROM: the letters W, E and R drop in one after another and
; bounce, each in its own colour, on white; the chime; a fade to white; then
; the hand-over. For monochrome games it also does what a Game Boy Color's
; boot ROM does for them: picks colour palettes from the title (or from a
; button combination held during the logo), switches the CPU to DMG
; compatibility mode (KEY0) and sets DMG object priority (OPRI).
;
; Each letter has its own box of tiles (5 wide, 8 tall) whose tiles run down
; each column, so a column of the box is 128 consecutive bytes: moving the
; letter down by y pixels is copying its columns 2y bytes further on. The
; falling letters are drawn into WRAM and copied to VRAM by general-purpose
; DMA during VBlank.
;
; 2304 bytes, mapped at $0000-$00FF and $0200-$08FF (the cartridge header at
; $0100-$01FF stays visible) until the write to $FF50.
;
; Build: scripts/build-bootroms.sh

DEF rP1    EQU $FF00
DEF rNR11  EQU $FF11
DEF rNR12  EQU $FF12
DEF rNR13  EQU $FF13
DEF rNR14  EQU $FF14
DEF rNR50  EQU $FF24
DEF rNR51  EQU $FF25
DEF rNR52  EQU $FF26
DEF WAVE   EQU $FF30
DEF rLCDC  EQU $FF40
DEF rLY    EQU $FF44
DEF rBGP   EQU $FF47
DEF rOBP0  EQU $FF48
DEF rOBP1  EQU $FF49
DEF rKEY0  EQU $FF4C
DEF rVBK   EQU $FF4F
DEF rBANK  EQU $FF50
DEF rHDMA1 EQU $FF51
DEF rHDMA2 EQU $FF52
DEF rHDMA3 EQU $FF53
DEF rHDMA4 EQU $FF54
DEF rHDMA5 EQU $FF55
DEF rBCPS  EQU $FF68
DEF rBCPD  EQU $FF69
DEF rOCPS  EQU $FF6A
DEF rOCPD  EQU $FF6B
DEF rOPRI  EQU $FF6C

DEF hManual EQU $FF80 ; button combination picked (index + 1), 0 = none
DEF hFrame  EQU $FF81 ; animation frame
DEF hDirty  EQU $FF82 ; letters drawn in WRAM, to copy to VRAM (bit per letter)
DEF hLetter EQU $FF83 ; Draw: the letter
DEF hY      EQU $FF84 ; Draw: its height in the box

DEF LETTERS     EQU 3
DEF BOX_W       EQU 5                 ; tiles
DEF BOX_H       EQU 8                 ; tiles
DEF COLUMN      EQU BOX_H * 16        ; bytes per column of a box
DEF BOX_BYTES   EQU BOX_W * COLUMN    ; 640
DEF LETTER_ROWS EQU 24                ; pixels
DEF FIRST_TILE  EQU $40               ; tiles 1-25 hold the header logo
DEF BOX_MAP     EQU $9862             ; row 3, column 2: the 3 boxes side by side

DEF DROP_GAP    EQU 14                ; frames between two letters starting
DEF CHIME_FRAME EQU 2 * DROP_GAP + 10 ; the R lands
DEF ANIM_FRAMES EQU 110
DEF FADE_STEP   EQU 4                 ; frames per fade step
DEF HOLD_FRAMES EQU 10                ; blank screen before the game

SECTION "Low", ROM0[$0000]
Start:
    ld sp, $FFFE
    jp Main

; Small helpers live here, below the cartridge header.

; Logo data at DE up to (low byte) C: 2 bytes per 4x4-pixel tile, a nibble
; per row, each pixel doubled into an 8x8 tile at HL (low bitplane only).
Unpack:
    ld a, [de]
    call DoubleRows
    ld a, [de]
    swap a
    call DoubleRows
    inc de
    ld a, e
    cp c
    jr nz, Unpack
    ret

; The top nibble of A as two rows of a tile at HL, each pixel doubled.
DoubleRows:
    push bc
    push de
    ld c, a
    ld b, 4
.bit:
    sla c
    push af             ; keep the pixel in carry for its second copy
    rl d
    pop af
    rl d
    dec b
    jr nz, .bit
    ld a, d
    ld [hli], a
    inc hl
    ld [hli], a
    inc hl
    pop de
    pop bc
    ret

Registered:
    db $3C, $42, $B9, $A5, $B9, $A5, $42, $3C

; C = frequency low byte: a note on channel 1.
Note:
    ld a, c
    ldh [rNR13], a
    ld a, $87
    ldh [rNR14], a
    ret

; Until the next VBlank starts.
WaitFrame:
.out:
    ldh a, [rLY]
    cp 144
    jr z, .out
.in:
    ldh a, [rLY]
    cp 144
    jr nz, .in
    ret

; Zero BC bytes from HL.
ClearHL:
    xor a
    ld [hli], a
    dec bc
    ld a, b
    or c
    jr nz, ClearHL
    ret

; Every colour of the 8 BG palettes white.
WhitePalettes:
    ld a, $80           ; index 0, auto-increment
    ldh [rBCPS], a
    ld b, 32
.loop:
    ld a, $FF
    ldh [rBCPD], a
    ld a, $7F
    ldh [rBCPD], a
    dec b
    jr nz, .loop
    ret

; The letters drawn last frame go to VRAM (in VBlank, by general-purpose DMA).
CopyLetters:
    ld c, 0
.letter:
    ldh a, [hDirty]
    ld b, c
    inc b
.bit:
    rrca
    dec b
    jr nz, .bit
    jr nc, .next
    ld a, c             ; HL = LetterDMA + 4 * letter
    add a
    add a
    ld l, a
    ld h, 0
    ld de, LetterDMA
    add hl, de
    ld a, [hli]
    ldh [rHDMA1], a
    ld a, [hli]
    ldh [rHDMA2], a
    ld a, [hli]
    ldh [rHDMA3], a
    ld a, [hl]
    ldh [rHDMA4], a
    ld a, BOX_BYTES / 16 - 1
    ldh [rHDMA5], a     ; general purpose: done before the next instruction
.next:
    inc c
    ld a, c
    cp LETTERS
    jr nz, .letter
    xor a
    ldh [hDirty], a
    ret

; Colours 1-3 of BG palettes 1-3 = the letters' colours at fade step A.
LetterPalettes:
    ld l, a             ; HL = LetterColours + 6 * A
    add a
    add l
    add a
    ld l, a
    ld h, 0
    ld de, LetterColours
    add hl, de
    ld c, 1             ; palette
.palette:
    ld a, c
    add a
    add a
    add a
    add 2               ; colour 1
    or $80
    ldh [rBCPS], a
    ld a, [hli]
    ld e, a
    ld d, [hl]
    inc hl
    ld b, 3
.colour:
    ld a, e
    ldh [rBCPD], a
    ld a, d
    ldh [rBCPD], a
    dec b
    jr nz, .colour
    inc c
    ld a, c
    cp LETTERS + 1
    jr nz, .palette
    ret

; A = the registers a colour Game Boy leaves ($11), the rest set by Main;
; unmap the boot ROM, the next instruction is the cartridge's at $0100.
SECTION "Handoff", ROM0[$00FE]
Handoff:
    ldh [rBANK], a

SECTION "Main", ROM0[$0200]
Main:
    ; VRAM (both banks) holds garbage at power-on.
    ld a, 1
    ldh [rVBK], a
    ld hl, $8000
    ld bc, $2000
    call ClearHL
    xor a
    ldh [rVBK], a
    ld hl, $8000
    ld bc, $2000
    call ClearHL

    ; Wave RAM as a colour Game Boy leaves it: $00 $FF $00 $FF ...
    ld hl, WAVE
    ld c, 16
.wave:
    ld [hli], a
    cpl
    dec c
    jr nz, .wave

    ; Sound on, channel 1 set up for the chime.
    ld a, $80
    ldh [rNR52], a
    ldh [rNR11], a
    ld a, $F3
    ldh [rNR12], a
    ldh [rNR51], a
    ld a, $77
    ldh [rNR50], a

    xor a
    ldh [hManual], a
    ldh [hFrame], a
    ldh [hDirty], a

    ; Like the original: the cartridge's logo as tiles 1-24 and (R) as tile
    ; 25, left in VRAM for games (and test ROMs) that use them. Not shown.
    ld de, $0104
    ld hl, $8010
    ld c, $34
    call Unpack
    ld de, Registered
    ld b, 8
.registered:
    ld a, [de]
    inc de
    ld [hli], a
    inc hl
    dec b
    jr nz, .registered

    ; The boxes in the tile map (tiles running down each column) and, in
    ; bank 1, their palettes: letter n uses BG palette n + 1.
    ld hl, BOX_MAP
    ld a, FIRST_TILE
    ld c, BOX_H
.maprow:
    ld b, LETTERS * BOX_W
    push af
.mapcol:
    ld [hli], a
    add BOX_H
    dec b
    jr nz, .mapcol
    pop af
    inc a
    ld de, 32 - LETTERS * BOX_W
    add hl, de
    dec c
    jr nz, .maprow

    ld a, 1
    ldh [rVBK], a
    ld hl, BOX_MAP
    ld c, BOX_H
.attrrow:
    ld b, 0
.attrcol:
    ld a, b             ; palette = column / 5 + 1
    ld d, 0
.div:
    cp BOX_W
    jr c, .divdone
    sub BOX_W
    inc d
    jr .div
.divdone:
    ld a, d
    inc a
    ld [hli], a
    inc b
    ld a, b
    cp LETTERS * BOX_W
    jr nz, .attrcol
    ld de, 32 - LETTERS * BOX_W
    add hl, de
    dec c
    jr nz, .attrrow
    xor a
    ldh [rVBK], a

    ; Palettes: everything white, then the letters' colours.
    call WhitePalettes
    xor a
    call LetterPalettes
    ld a, $91           ; LCD on, BG on, tiles at $8000
    ldh [rLCDC], a

    ; The drop.
.anim:
    call WaitFrame
    call CopyLetters
    ld a, [$0143]
    bit 7, a
    call z, ReadCombination
    ldh a, [hFrame]
    cp CHIME_FRAME
    ld c, $83
    call z, Note
    ldh a, [hFrame]
    cp CHIME_FRAME + 5
    ld c, $C1
    call z, Note
    call DrawLetters
    ldh a, [hFrame]
    inc a
    ldh [hFrame], a
    cp ANIM_FRAMES
    jr nz, .anim

    ; Fade the letters to white.
    ld e, 1
.fade:
    ld b, FADE_STEP
.fadewait:
    call WaitFrame
    dec b
    jr nz, .fadewait
    ld a, e
    push de
    call LetterPalettes
    pop de
    inc e
    ld a, e
    cp 5
    jr nz, .fade

    ; No logo left in the tile maps (with the LCD off: VRAM is locked while
    ; it draws).
    call WaitFrame
    xor a
    ldh [rLCDC], a
    ld a, 1
    ldh [rVBK], a
    ld hl, $9800
    ld bc, $0800
    call ClearHL
    xor a
    ldh [rVBK], a
    ld hl, $9800
    ld bc, $0800
    call ClearHL
    ld a, $91
    ldh [rLCDC], a
    ld b, HOLD_FRAMES
.hold:
    call WaitFrame
    dec b
    jr nz, .hold

    ld a, [$0143]
    bit 7, a
    jr z, .monochrome

    ; A colour game: the header byte goes to KEY0.
    ldh [rKEY0], a
    ld bc, $0000
    ld de, $FF56
    ld hl, $1180
    push hl
    pop af              ; A = $11, F = Z
    ld hl, $000D
    jp Handoff

.monochrome:
    ; DMG compatibility mode. B = the title checksum (Nintendo games) or 0.
    call SetCompatPalettes
    ld a, $FC
    ldh [rBGP], a
    ld a, $FF
    ldh [rOBP0], a
    ldh [rOBP1], a
    ld a, $04
    ldh [rKEY0], a
    ld a, $01
    ldh [rOPRI], a
    ld c, $00
    ld de, $0008
    ld hl, $1180
    push hl
    pop af              ; A = $11, F = Z
    ld hl, $007C
    jp Handoff

; Draw every falling letter at its height for this frame into WRAM.
DrawLetters:
    ld c, 0
.letter:
    ld a, c             ; frame of this letter's drop = hFrame - c * DROP_GAP
    ld b, 0
.gap:
    or a
    jr z, .gapdone
    push af
    ld a, b
    add DROP_GAP
    ld b, a
    pop af
    dec a
    jr .gap
.gapdone:
    ldh a, [hFrame]
    sub b
    jr c, .next         ; not started
    cp DropEnd - Drop
    jr nc, .next        ; landed
    ld l, a
    ld h, 0
    ld de, Drop
    add hl, de
    ld a, [hl]
    ldh [hY], a
    ld a, c
    ldh [hLetter], a
    push bc
    call Draw
    pop bc
    ld b, c             ; mark it for CopyLetters
    inc b
    ld a, $80
.mark:
    rlca
    dec b
    jr nz, .mark
    ld b, a
    ldh a, [hDirty]
    or b
    ldh [hDirty], a
.next:
    inc c
    ld a, c
    cp LETTERS
    jr nz, .letter
    ret

; Letter hLetter at height hY in its WRAM box: clear the box, copy each of
; its 5 columns (24 bytes, a byte per row) into the low bitplane.
Draw:
    ldh a, [hLetter]    ; HL = the box in WRAM
    add a
    add a
    ld l, a
    ld h, 0
    ld de, LetterDMA
    add hl, de
    ld a, [hli]
    ld l, [hl]
    ld h, a
    push hl
    ld bc, BOX_BYTES
    call ClearHL
    pop hl
    ldh a, [hY]         ; HL += 2 * y
    add a
    ld e, a
    ld d, 0
    add hl, de
    ldh a, [hLetter]    ; the letter's columns: DE = data, first box column, count
    ld e, a
    add a
    add a
    ld e, a
    ld d, 0
    push hl
    ld hl, LetterInfo
    add hl, de
    ld e, [hl]
    inc hl
    ld d, [hl]
    inc hl
    ld a, [hli]         ; first column
    ld b, [hl]          ; count
    pop hl
    or a
    jr z, .placed
    push de
    ld de, COLUMN
.skip:
    add hl, de
    dec a
    jr nz, .skip
    pop de
.placed:
.column:
    push hl
    ld c, LETTER_ROWS
.row:
    ld a, [de]
    inc de
    ld [hli], a
    inc hl
    dec c
    jr nz, .row
    pop hl
    push de
    ld de, COLUMN
    add hl, de
    pop de
    dec b
    jr nz, .column
    ret

; Per letter: its WRAM box (source) and VRAM box (destination), big-endian.
LetterDMA:
    FOR N, LETTERS
        db HIGH($C000 + N * BOX_BYTES), LOW($C000 + N * BOX_BYTES)
        db HIGH($8000 + FIRST_TILE * 16 + N * BOX_BYTES) & $1F, LOW($8000 + FIRST_TILE * 16 + N * BOX_BYTES)
    ENDR

Drop:
    INCLUDE "drop.inc"

INCLUDE "letter_colours.inc"

ReadCombination:
    ld a, $20           ; the d-pad
    ldh [rP1], a
    ldh a, [rP1]
    ldh a, [rP1]
    cpl
    and $0F
    ld b, a
    ld a, $10           ; the buttons
    ldh [rP1], a
    ldh a, [rP1]
    ldh a, [rP1]
    cpl
    and $0F
    ld c, a
    ld a, $30
    ldh [rP1], a
    ld a, b
    ld b, 0             ; Up
    bit 2, a
    jr nz, .direction
    ld b, 3             ; Left
    bit 1, a
    jr nz, .direction
    ld b, 6             ; Down
    bit 3, a
    jr nz, .direction
    ld b, 9             ; Right
    bit 0, a
    ret z               ; no direction held
.direction:
    ld a, b
    bit 0, c            ; A
    jr z, .notA
    inc a
    jr .picked
.notA:
    bit 1, c            ; B
    jr z, .picked
    add 2
.picked:
    inc a
    ldh [hManual], a
    ret

; BG palette 0 and OBJ palettes 0 and 1 for a monochrome game.
; Returns B = the title checksum for Nintendo games, 0 for others.
SetCompatPalettes:
    ld b, 0
    ; Nintendo's licensee code: old $01, or old $33 and new "01".
    ld a, [$014B]
    cp $33
    jr nz, .old
    ld a, [$0144]
    cp '0'
    jr nz, .default
    ld a, [$0145]
    cp '1'
    jr nz, .default
    jr .checksum
.old:
    cp $01
    jr nz, .default
.checksum:
    ld hl, $0134
    ld c, 16
    xor a
.sum:
    add [hl]
    inc hl
    dec c
    jr nz, .sum
    ld b, a
    call LookupSet
    jr .picked
.default:
    ld a, DEFAULT_SET
.picked:
    ; A button combination overrides the title's choice.
    ld e, a
    ldh a, [hManual]
    or a
    jr z, .auto
    dec a
    ld hl, ManualSets
    jr .index
.auto:
    ld a, e
    ld hl, CompatSets
.index:
    ld e, a             ; HL += 3 * A
    add a
    add e
    ld e, a
    ld d, 0
    add hl, de

    call WaitFrame      ; palette RAM is locked while the LCD draws
    ld a, $80
    ldh [rBCPS], a
    ld c, LOW(rBCPD)
    ld a, [hli]
    call WritePalette
    ld a, $80
    ldh [rOCPS], a
    ld c, LOW(rOCPD)
    ld a, [hli]
    call WritePalette
    ld a, [hl]
    ; fall through: OBJ palette 1 follows OBJ palette 0

; Palette A of CompatPalettes to the data port [$FF00 + C] (8 bytes).
WritePalette:
    push hl
    add a               ; HL = CompatPalettes + 8 * A
    add a
    ld l, a
    ld h, 0
    add hl, hl
    ld de, CompatPalettes
    add hl, de
    ld d, 8
.byte:
    ld a, [hli]
    ldh [c], a
    dec d
    jr nz, .byte
    pop hl
    ret

; B = title checksum: A = the palette set for it. Entries with a fourth
; letter come first and only match with that letter; not found: default.
LookupSet:
    ld a, [$0137]
    ld d, a
    ld hl, CompatLookup
.entry:
    ld a, l
    cp LOW(CompatLookupEnd)
    jr nz, .check
    ld a, h
    cp HIGH(CompatLookupEnd)
    jr z, .notFound
.check:
    ld a, [hli]
    cp b
    jr nz, .next2
    ld a, [hli]
    or a
    jr z, .found        ; any letter
    cp d
    jr z, .found
    inc hl
    jr .entry
.next2:
    inc hl
    inc hl
    jr .entry
.found:
    ld a, [hl]
    ret
.notFound:
    ld a, DEFAULT_SET
    ret

INCLUDE "compat_palettes.inc"

; W, E, R: 40x24 pixels each (bootrom/wer_letters.png), 1 bit per pixel,
; 8-pixel columns of 24 bytes, left to right, blank columns left out.
INCLUDE "wer_letters.inc"

ASSERT @ <= $0900, "boot ROM too big"
