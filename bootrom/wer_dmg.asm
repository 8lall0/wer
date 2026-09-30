; wer DMG boot ROM: scrolls a WER logo down into the middle of the screen,
; plays the two-note chime and hands over to the cartridge with the
; registers the original leaves. 256 bytes, mapped at $0000-$00FF until the
; write to $FF50. No logo or header check.
;
; Build: scripts/build-bootroms.sh

DEF rNR11 EQU $FF11
DEF rNR12 EQU $FF12
DEF rNR13 EQU $FF13
DEF rNR14 EQU $FF14
DEF rNR50 EQU $FF24
DEF rNR51 EQU $FF25
DEF rNR52 EQU $FF26
DEF rLCDC EQU $FF40
DEF rSCY  EQU $FF42
DEF rLY   EQU $FF44
DEF rBGP  EQU $FF47
DEF rBANK EQU $FF50

DEF LOGO_TILES EQU $8300 ; tile $30 on (tiles 1-25 hold the header logo)
DEF LOGO_FIRST EQU $30
DEF LOGO_MAP   EQU $9906 ; row 8, column 6: 8x2 tiles, centred
DEF SCROLL_IN  EQU $60   ; the logo starts this many lines lower

SECTION "Boot", ROM0[$0000]
Start:
    ld sp, $FFFE

    ; VRAM holds garbage at power-on.
    xor a
    ld hl, $9FFF
.clear:
    ld [hld], a
    bit 7, h
    jr nz, .clear

    ; Sound on, channel 1 set up for the chime.
    ld a, $80
    ldh [rNR52], a
    ldh [rNR11], a      ; 50% duty
    ld a, $F3
    ldh [rNR12], a      ; loud, fading out
    ldh [rNR51], a
    ld a, $77
    ldh [rNR50], a

    ; Like the original: the cartridge's logo as tiles 1-24 and (R) as tile
    ; 25, left in VRAM for games (and test ROMs) that use them. Not shown.
    ld de, $0104
    ld hl, $8010
    ld c, $34
    call Unpack
    ld de, Registered
.registered:
    ld a, [de]
    inc de
    ld [hli], a
    inc hl
    ld a, e
    cp LOW(RegisteredEnd)
    jr nz, .registered

    ; Our logo, in the same format.
    ld de, Logo
    ld hl, LOGO_TILES
    ld c, LOW(LogoEnd)
    call Unpack

    ; Tile map: 8 tiles above the next 8.
    ld a, LOGO_FIRST
    ld hl, LOGO_MAP
    call MapRow
    ld l, LOW(LOGO_MAP + 32)
    call MapRow

    ld a, $FC           ; colours 1-3 black
    ldh [rBGP], a
    ld a, SCROLL_IN
    ldh [rSCY], a
    ld a, $91           ; LCD on, BG on, tiles at $8000
    ldh [rLCDC], a

    ; Scroll the logo up into place, a line per frame.
.scroll:
    call WaitFrame
    ldh a, [rSCY]
    dec a
    ldh [rSCY], a
    jr nz, .scroll

    ; Ba-ding!
    ld a, $83
    call Note
    ld b, 5
    call WaitFrames
    ld a, $C1
    call Note
    ld b, 60
    call WaitFrames
    jp Handoff

; Tile map row: 8 tiles from tile A on, at HL. A ends 8 higher.
MapRow:
    ld b, 8
.loop:
    ld [hli], a
    inc a
    dec b
    jr nz, .loop
    ret

; Logo data at DE up to (low byte) C: 2 bytes per 4x4-pixel tile, a nibble
; per row, each pixel doubled into an 8x8 tile at HL (colour 1: only the
; low bitplane).
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

; The top nibble of A as two rows of a tile at HL, each of its 4 pixels
; doubled. HL moves on by two rows (4 bytes).
DoubleRows:
    push bc
    push de             ; D builds the row
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
    ld [hli], a         ; low bitplane
    inc hl              ; (high bitplane stays 0)
    ld [hli], a
    inc hl
    pop de
    pop bc
    ret

; A note on channel 1: frequency low byte A, high bits 7.
Note:
    ldh [rNR13], a
    ld a, $87
    ldh [rNR14], a
    ret

WaitFrames:
    call WaitFrame
    dec b
    jr nz, WaitFrames
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

; WER, 32x8 pixels (bootrom/wer_logo_dmg.txt): a nibble per 4-pixel row,
; 2 bytes per 4x4 tile, the top row of tiles first.
Logo:
    INCLUDE "wer_logo_dmg.inc"
LogoEnd:

Registered:
    db $3C, $42, $B9, $A5, $B9, $A5, $42, $3C
RegisteredEnd:

; The registers a DMG leaves for the game, then unmap the boot ROM: the next
; instruction is the cartridge's at $0100.
SECTION "Handoff", ROM0[$00FE - 14]
Handoff:
    ld hl, $01B0
    push hl
    pop af              ; A = $01, F = Z H C
    ld bc, $0013
    ld de, $00D8
    ld hl, $014D
    ASSERT @ == $00FE
    ldh [rBANK], a
