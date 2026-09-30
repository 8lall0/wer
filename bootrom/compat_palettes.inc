; Compatibility palettes for monochrome games, as a real Game Boy Color
; picks them. Data from The Cutting Room Floor's notes on the Game Boy Color
; boot ROM (checksums, fourth letters, colours) and Pan Docs (the lookup
; rules), converted to this form; hardware facts, not code.

DEF PALETTE_COUNT EQU 33
DEF DEFAULT_SET EQU 43

; Palettes: 4 colours each, little-endian RGB555.
CompatPalettes:
    dw $7FFF, $42B5, $3DC8, $0000 ; 0
    dw $7FFF, $01DF, $0112, $0000 ; 1
    dw $7FFF, $7EEB, $001F, $7C00 ; 2
    dw $4FFF, $7ED2, $3A4C, $1CE0 ; 3
    dw $231F, $035F, $00F2, $0009 ; 4
    dw $7FFF, $421F, $1CF2, $0000 ; 5
    dw $03ED, $7FFF, $255F, $0000 ; 6
    dw $7FFF, $7FFF, $7E8C, $7C00 ; 7
    dw $7FFF, $32BF, $00D0, $0000 ; 8
    dw $036A, $021F, $03FF, $7FFF ; 9
    dw $7FFF, $03EF, $01D6, $0000 ; 10
    dw $7FFF, $03EA, $011F, $0000 ; 11
    dw $7FFF, $027F, $001F, $0000 ; 12
    dw $7FFF, $03FF, $001F, $0000 ; 13
    dw $7E74, $03FF, $0180, $0000 ; 14
    dw $299F, $001A, $000C, $0000 ; 15
    dw $7C00, $7FFF, $3FFF, $7E00 ; 16
    dw $67FF, $77AC, $1A13, $2D6B ; 17
    dw $7FFF, $7E8C, $7C00, $0000 ; 18
    dw $7ED6, $4BFF, $2175, $0000 ; 19
    dw $0000, $7FFF, $421F, $1CF2 ; 20
    dw $7FFF, $3FFF, $7E00, $001F ; 21
    dw $7FFF, $6E31, $454A, $0000 ; 22
    dw $7FFF, $1BEF, $0200, $0000 ; 23
    dw $7FFF, $03E0, $0206, $0120 ; 24
    dw $0000, $4200, $037F, $7FFF ; 25
    dw $03FF, $001F, $000C, $0000 ; 26
    dw $7FFF, $5294, $294A, $0000 ; 27
    dw $7FFF, $033F, $0193, $0000 ; 28
    dw $7FFF, $1BEF, $6180, $0000 ; 29
    dw $639F, $4279, $15B0, $04CB ; 30
    dw $53FF, $4A5F, $7E52, $0000 ; 31
    dw $7FFF, $03FF, $012F, $0000 ; 32

; Palette sets: BG, OBJ0, OBJ1 (indices into CompatPalettes), 3 bytes each.
CompatSets:
    db 0, 1, 1 ; 0
    db 0, 1, 2 ; 1
    db 3, 3, 3 ; 2
    db 3, 4, 5 ; 3
    db 6, 7, 8 ; 4
    db 9, 7, 5 ; 5
    db 10, 5, 5 ; 6
    db 11, 5, 5 ; 7
    db 11, 11, 2 ; 8
    db 12, 12, 12 ; 9
    db 12, 5, 5 ; 10
    db 12, 12, 2 ; 11
    db 13, 13, 13 ; 12
    db 13, 13, 2 ; 13
    db 14, 14, 14 ; 14
    db 14, 15, 15 ; 15
    db 14, 15, 16 ; 16
    db 17, 1, 18 ; 17
    db 19, 20, 20 ; 18
    db 18, 5, 18 ; 19
    db 18, 18, 5 ; 20
    db 18, 5, 21 ; 21
    db 22, 22, 4 ; 22
    db 22, 4, 4 ; 23
    db 22, 4, 2 ; 24
    db 22, 5, 22 ; 25
    db 22, 5, 5 ; 26
    db 22, 5, 8 ; 27
    db 23, 5, 5 ; 28
    db 23, 5, 18 ; 29
    db 8, 18, 18 ; 30
    db 8, 18, 23 ; 31
    db 5, 23, 5 ; 32
    db 5, 24, 18 ; 33
    db 8, 8, 8 ; 34
    db 8, 23, 23 ; 35
    db 8, 23, 18 ; 36
    db 25, 25, 25 ; 37
    db 18, 26, 23 ; 38
    db 0, 8, 18 ; 39
    db 27, 27, 27 ; 40
    db 28, 28, 28 ; 41
    db 29, 5, 29 ; 42
    db 29, 5, 5 ; 43
    db 29, 5, 18 ; 44

; Title checksum, fourth letter of the title (0: any), palette set.
; Entries with a letter are only used when the letter matches; searched first.
CompatLookup:
    db $0D, $45, 23 ; Pocket Bomberman (Europe)
    db $0D, $52, 13 ; Qix (World)
    db $18, $49, 43 ; Arcade Classic No. 2 - Centipede & Millipede (USA, Europe)
    db $18, $4B, 24 ; Donkey Kong Land (Japan)
    db $27, $42, 16 ; Hoshi no Kirby (Japan)
    db $27, $4E, 29 ; Magnetic Soccer (Europe)
    db $28, $41, 37 ; Arcade Classic No. 3 - Galaga & Galaxian (USA)
    db $28, $46, 28 ; Arcade Classic No. 1 - Asteroids & Missile Command (USA, Europe)
    db $46, $45, 18 ; Super Mario Land (World)
    db $46, $52, 38 ; Metroid II - Return of Samus (World)
    db $61, $41, 29 ; Magnetic Soccer (Europe)
    db $61, $45, 19 ; Pocket Monsters Ao (Japan)
    db $66, $45,  6 ; Game & Watch Gallery (Europe)
    db $66, $4C, 43 ; Arcade Classic No. 2 - Centipede & Millipede (USA, Europe)
    db $6A, $49,  7 ; Mario & Yoshi (Europe)
    db $6A, $4B, 24 ; Donkey Kong Land (Japan)
    db $A5, $41, 37 ; Arcade Classic No. 3 - Galaga & Galaxian (USA)
    db $A5, $52, 35 ; Battletoads in Ragnarok's World (Europe)
    db $B3, $42, 16 ; Hoshi no Kirby (Japan)
    db $B3, $52,  8 ; Tetris Attack (USA)
    db $B3, $55,  0 ; Moguranya (Japan)
    db $BF, $20, 26 ; Kid Icarus - Of Myths and Monsters (USA, Europe)
    db $BF, $43,  4 ; Soccer (Europe) (En,Fr,De)
    db $C6, $20, 43 ; Arcade Classic No. 2 - Centipede & Millipede (USA, Europe)
    db $C6, $41,  1 ; Game Boy Wars (Japan)
    db $D3, $49, 39 ; Wario Land II (USA, Europe)
    db $D3, $52, 25 ; Kaeru no Tame ni Kane wa Naru (Japan)
    db $F4, $20,  6 ; Game & Watch Gallery (Europe)
    db $F4, $2D, 44 ; Pac-In-Time (USA)
    db $00, $00, 43 ; Arcade Classic No. 2 - Centipede & Millipede (USA, Europe)
    db $01, $00, 31 ; Adventures of Lolo (Europe)
    db $0C, $00, 34 ; F-1 Race (World)
    db $10, $00, 31 ; Adventures of Lolo (Europe)
    db $14, $00, 32 ; Game Boy Camera Gold (USA)
    db $15, $00, 12 ; Pocket Monsters - Pikachu (Japan) (Rev 0A)
    db $16, $00, 34 ; F-1 Race (World)
    db $17, $00, 29 ; Magnetic Soccer (Europe)
    db $19, $00, 10 ; Donkey Kong (World)
    db $1D, $00, 15 ; Kirby no Pinball (Japan)
    db $29, $00, 31 ; Adventures of Lolo (Europe)
    db $34, $00,  6 ; Game & Watch Gallery (Europe)
    db $35, $00, 34 ; F-1 Race (World)
    db $36, $00,  5 ; Baseball (World)
    db $39, $00, 30 ; Chessmaster, The (Europe)
    db $3C, $00, 20 ; Dr. Mario (World)
    db $3D, $00,  7 ; Mario & Yoshi (Europe)
    db $3E, $00, 11 ; Yoshi no Cookie (Japan)
    db $3F, $00, 43 ; Arcade Classic No. 2 - Centipede & Millipede (USA, Europe)
    db $43, $00, 30 ; Chessmaster, The (Europe)
    db $49, $00, 16 ; Hoshi no Kirby (Japan)
    db $4B, $00, 28 ; Arcade Classic No. 1 - Asteroids & Missile Command (USA, Europe)
    db $4E, $00, 21 ; Wave Race (USA, Europe)
    db $52, $00, 31 ; Adventures of Lolo (Europe)
    db $58, $00, 40 ; X (Japan)
    db $59, $00,  1 ; Game Boy Wars (Japan)
    db $5C, $00, 16 ; Hoshi no Kirby (Japan)
    db $5D, $00, 31 ; Adventures of Lolo (Europe)
    db $67, $00, 34 ; F-1 Race (World)
    db $68, $00, 31 ; Adventures of Lolo (Europe)
    db $69, $00, 13 ; Qix (World)
    db $6B, $00, 24 ; Donkey Kong Land (Japan)
    db $6D, $00, 31 ; Adventures of Lolo (Europe)
    db $6F, $00, 41 ; Pocket Camera (Japan) (Rev A)
    db $70, $00, 33 ; Legend of Zelda, The - Link's Awakening (France)
    db $71, $00,  9 ; Balloon Kid (USA, Europe)
    db $75, $00, 34 ; F-1 Race (World)
    db $86, $00,  3 ; Donkey Kong Land (USA, Europe)
    db $88, $00, 14 ; Alleyway (World)
    db $8B, $00, 29 ; Magnetic Soccer (Europe)
    db $8C, $00,  2 ; Radar Mission (Japan)
    db $90, $00, 28 ; Arcade Classic No. 1 - Asteroids & Missile Command (USA, Europe)
    db $92, $00, 34 ; F-1 Race (World)
    db $95, $00,  8 ; Tetris Attack (USA)
    db $97, $00, 30 ; Chessmaster, The (Europe)
    db $99, $00, 34 ; F-1 Race (World)
    db $9A, $00, 28 ; Arcade Classic No. 1 - Asteroids & Missile Command (USA, Europe)
    db $9C, $00, 22 ; Pinocchio (Europe)
    db $9D, $00, 27 ; Killer Instinct (USA, Europe)
    db $A2, $00, 36 ; Boy and His Blob in the Rescue of Princess Blobette, A (Europe)
    db $A8, $00,  3 ; Donkey Kong Land (USA, Europe)
    db $AA, $00, 42 ; James Bond 007 (USA, Europe)
    db $B7, $00, 34 ; F-1 Race (World)
    db $BD, $00, 28 ; Arcade Classic No. 1 - Asteroids & Missile Command (USA, Europe)
    db $C9, $00, 17 ; Super Mario Land 2 - 6 Golden Coins (USA, Europe)
    db $CE, $00,  4 ; Soccer (Europe) (En,Fr,De)
    db $D1, $00,  4 ; Soccer (Europe) (En,Fr,De)
    db $DB, $00, 12 ; Pocket Monsters - Pikachu (Japan) (Rev 0A)
    db $E0, $00, 11 ; Yoshi no Cookie (Japan)
    db $E8, $00, 37 ; Arcade Classic No. 3 - Galaga & Galaxian (USA)
    db $F0, $00,  4 ; Soccer (Europe) (En,Fr,De)
    db $F2, $00, 13 ; Qix (World)
    db $F6, $00, 31 ; Adventures of Lolo (Europe)
    db $F7, $00, 36 ; Boy and His Blob in the Rescue of Princess Blobette, A (Europe)
    db $FF, $00,  9 ; Balloon Kid (USA, Europe)
CompatLookupEnd:

; Button combinations held during the logo (d-pad direction, plus A or B):
; Up, A+Up, B+Up, Left, A+Left, B+Left, Down, A+Down, B+Down, Right, A+Right, B+Right.
ManualSets:
    db 8, 8, 8 ; Up
    db 5, 23, 18 ; A + Up
    db 30, 8, 8 ; B + Up
    db 18, 5, 23 ; Left
    db 22, 5, 8 ; A + Left
    db 27, 27, 27 ; B + Left
    db 31, 31, 31 ; Down
    db 13, 13, 13 ; A + Down
    db 32, 18, 23 ; B + Down
    db 11, 11, 11 ; Right
    db 29, 5, 5 ; A + Right
    db 25, 25, 25 ; B + Right
