; =============================================================================
; gfx.asm — tile graphics and CGB palettes.
; Backtick literals: each digit is a 2bpp colour index (0-3) for one pixel.
; Tile ids are defined in constants.inc; this table must stay in that order
; (id == VRAM tile index). BG tiles 0..13, then sprites 14..26.
; =============================================================================
INCLUDE "include/constants.inc"

SECTION "GfxData", ROM0

Tiles::
; --- 0: grass (BG pal 0, passable) ---
    dw `00000000
    dw `00000100
    dw `00000000
    dw `00100000
    dw `00000000
    dw `00000010
    dw `01000000
    dw `00000000
; --- 1: brush (BG pal 0, passable) ---
    dw `01000100
    dw `10101010
    dw `01000100
    dw `00010001
    dw `01000100
    dw `10101010
    dw `00010001
    dw `01000100
; --- 2: flower (BG pal 0, passable) — little blossoms on grass ---
    dw `01000010
    dw `13100131
    dw `01000010
    dw `00000000
    dw `00010000
    dw `00131000
    dw `00010000
    dw `00000000
; --- 3: dirt (BG pal 2, passable) — bare city ground, faint speckle ---
    dw `00010000
    dw `00000010
    dw `01000000
    dw `00000100
    dw `00100000
    dw `00000001
    dw `00010000
    dw `01000000
; --- 4: water (BG pal 1, solid) ---
    dw `00000000
    dw `10001000
    dw `00000001
    dw `00100010
    dw `00000000
    dw `01000100
    dw `00010000
    dw `00000000
; --- 5: road (BG pal 2, passable) ---
    dw `22222222
    dw `21222212
    dw `22222222
    dw `22122122
    dw `22222222
    dw `21222212
    dw `22222222
    dw `22122122
; --- 6: wall / rock (BG pal 2, solid) ---
    dw `22222222
    dw `23232323
    dw `22222222
    dw `32323232
    dw `22222222
    dw `23232323
    dw `22222222
    dw `32323232
; --- 7: floor (BG pal 2, passable) — house interior planks ---
    dw `11111111
    dw `11111111
    dw `22222222
    dw `11111111
    dw `11111111
    dw `22222222
    dw `11111111
    dw `11111111
; --- 8: door (BG pal 2, passable) — dark doorway in the wall ---
    dw `33333333
    dw `32222223
    dw `32222223
    dw `32222223
    dw `32222223
    dw `32222223
    dw `32222223
    dw `33333333
; --- 9: marsh ground (BG pal 3, passable) — murky, mottled ---
    dw `00000000
    dw `00100200
    dw `00000000
    dw `02001000
    dw `00000000
    dw `00010020
    dw `00000000
    dw `00200001
; --- 10: tree top-left (BG pal 0, solid) ---
    dw `00000333
    dw `00033311
    dw `00331111
    dw `00311011
    dw `03311101
    dw `03110110
    dw `03111101
    dw `03111111
; --- 11: tree top-right (BG pal 0, solid) ---
    dw `33300000
    dw `11333000
    dw `11113300
    dw `11111300
    dw `11111330
    dw `11111130
    dw `11111130
    dw `11111130
; --- 12: tree bottom-left (BG pal 0, solid) ---
    dw `03111111
    dw `03311111
    dw `00311111
    dw `00331133
    dw `00033333
    dw `00000333
    dw `00000033
    dw `00000033
; --- 13: tree bottom-right (BG pal 0, solid) ---
    dw `11111130
    dw `11111330
    dw `11111300
    dw `33113300
    dw `33333000
    dw `33300000
    dw `33000000
    dw `33000000
; Character sprites: colour 1 = black (outline + eyes), 2 = face, 3 = body.
; --- 14: player down A (OBJ pal 0; face skin, body red) ---
    dw `00111100
    dw `01333310
    dw `01222210
    dw `01212110
    dw `01222210
    dw `13111131
    dw `11333311
    dw `01311310
; Walk cycle: A = arms out (row5) + feet apart (row7);
;             B = arms swung down (hands drop to row6) + feet together.
; --- 15: player down B ---
    dw `00111100
    dw `01333310
    dw `01222210
    dw `01212110
    dw `01222210
    dw `01111110
    dw `13333331
    dw `00133100
; --- 16: player up A (back of head; no eyes) ---
    dw `00111100
    dw `01333310
    dw `01222210
    dw `01222210
    dw `01222210
    dw `13111131
    dw `11333311
    dw `01311310
; --- 17: player up B ---
    dw `00111100
    dw `01333310
    dw `01222210
    dw `01222210
    dw `01222210
    dw `01111110
    dw `13333331
    dw `00133100
; --- 18: player side A (right profile: narrow head, cap brim juts fwd;
;         one eye. Flip X for left — brim always leads the walk) ---
    dw `00111000
    dw `01333100
    dw `01333331
    dw `01212100
    dw `01222100
    dw `13111131
    dw `11333311
    dw `01311310
; --- 19: player side B ---
    dw `00111000
    dw `01333100
    dw `01333331
    dw `01212100
    dw `01222100
    dw `01111110
    dw `13333331
    dw `00133100
; --- 20: zombie down A (OBJ pal 1; hunched, face green, body brown) ---
    dw `00000000
    dw `00111100
    dw `01333310
    dw `01212110
    dw `01222210
    dw `13111131
    dw `11333311
    dw `01311310
; --- 21: zombie down B ---
    dw `00000000
    dw `00111100
    dw `01333310
    dw `01212110
    dw `01222210
    dw `01111110
    dw `13333331
    dw `00133100
; --- 22: zombie up A (no eyes) ---
    dw `00000000
    dw `00111100
    dw `01333310
    dw `01222210
    dw `01222210
    dw `13111131
    dw `11333311
    dw `01311310
; --- 23: zombie up B ---
    dw `00000000
    dw `00111100
    dw `01333310
    dw `01222210
    dw `01222210
    dw `01111110
    dw `13333331
    dw `00133100
; --- 24: zombie side A (hunched right profile, one eye; flip X for left) ---
    dw `00000000
    dw `00111000
    dw `01333100
    dw `01333331
    dw `01212100
    dw `13111131
    dw `11333311
    dw `01311310
; --- 25: zombie side B ---
    dw `00000000
    dw `00111000
    dw `01333100
    dw `01333331
    dw `01212100
    dw `01111110
    dw `13333331
    dw `00133100
; --- 26: "!" alert bubble (OBJ pal 2) ---
    dw `00011000
    dw `00111100
    dw `00111100
    dw `00011000
    dw `00011000
    dw `00000000
    dw `00011000
    dw `00011000
; Survivor NPC (static, no walk cycle). Colour 1 = outline/eyes, 2 = face,
; 3 = hair+outfit — tinted per persona via OBJ palettes 3..7.
; --- 27: survivor down (hair framing the face) ---
    dw `00333300
    dw `03333330
    dw `03222230
    dw `03212130
    dw `01222210
    dw `13333331
    dw `01333310
    dw `00133100
; --- 28: survivor up (back of head) ---
    dw `00333300
    dw `03333330
    dw `03333330
    dw `03333330
    dw `01333310
    dw `13333331
    dw `01333310
    dw `00133100
; --- 29: survivor side (right profile; flip X for left) ---
    dw `00333300
    dw `03333330
    dw `03332220
    dw `03332120
    dw `03332220
    dw `13333331
    dw `01333310
    dw `00133100
; --- 30: menu cursor (right-pointing triangle; OBJ pal 2 amber) ---
    dw `00000000
    dw `00200000
    dw `00220000
    dw `00222000
    dw `00222200
    dw `00222000
    dw `00220000
    dw `00200000
TilesEnd::

; -----------------------------------------------------------------------------
; Font + UI glyphs, 1bpp (one byte per row; LoadFont expands to 2bpp colour 0/3
; at $8800 = tile FONT_BASE). Order must match charmap.inc:
;   space, A-Z, 0-9, . , ! ? ' -  then faces / box / arrow (TILE_* ids).
; -----------------------------------------------------------------------------
Font1bpp::
    db $00,$00,$00,$00,$00,$00,$00,$00  ; space
    db $38,$6C,$C6,$C6,$FE,$C6,$C6,$00  ; A
    db $FC,$66,$66,$7C,$66,$66,$FC,$00  ; B
    db $3C,$66,$C0,$C0,$C0,$66,$3C,$00  ; C
    db $F8,$6C,$66,$66,$66,$6C,$F8,$00  ; D
    db $FE,$62,$68,$78,$68,$62,$FE,$00  ; E
    db $FE,$62,$68,$78,$68,$60,$F0,$00  ; F
    db $3C,$66,$C0,$C0,$CE,$66,$3E,$00  ; G
    db $C6,$C6,$C6,$FE,$C6,$C6,$C6,$00  ; H
    db $3C,$18,$18,$18,$18,$18,$3C,$00  ; I
    db $1E,$0C,$0C,$0C,$CC,$CC,$78,$00  ; J
    db $E6,$66,$6C,$78,$6C,$66,$E6,$00  ; K
    db $F0,$60,$60,$60,$62,$66,$FE,$00  ; L
    db $C6,$EE,$FE,$FE,$D6,$C6,$C6,$00  ; M
    db $C6,$E6,$F6,$DE,$CE,$C6,$C6,$00  ; N
    db $38,$6C,$C6,$C6,$C6,$6C,$38,$00  ; O
    db $FC,$66,$66,$7C,$60,$60,$F0,$00  ; P
    db $38,$6C,$C6,$C6,$DA,$CC,$76,$00  ; Q
    db $FC,$66,$66,$7C,$6C,$66,$E6,$00  ; R
    db $3C,$66,$60,$38,$0C,$66,$3C,$00  ; S
    db $7E,$5A,$18,$18,$18,$18,$3C,$00  ; T
    db $C6,$C6,$C6,$C6,$C6,$C6,$7C,$00  ; U
    db $C6,$C6,$C6,$C6,$C6,$6C,$38,$00  ; V
    db $C6,$C6,$C6,$D6,$FE,$EE,$C6,$00  ; W
    db $C6,$6C,$38,$38,$6C,$C6,$C6,$00  ; X
    db $66,$66,$66,$3C,$18,$18,$3C,$00  ; Y
    db $FE,$C6,$8C,$18,$32,$66,$FE,$00  ; Z
    db $7C,$C6,$CE,$DE,$F6,$E6,$7C,$00  ; 0
    db $18,$38,$18,$18,$18,$18,$7E,$00  ; 1
    db $7C,$C6,$06,$1C,$70,$C6,$FE,$00  ; 2
    db $7C,$C6,$06,$3C,$06,$C6,$7C,$00  ; 3
    db $1C,$3C,$6C,$CC,$FE,$0C,$1E,$00  ; 4
    db $FE,$C0,$FC,$06,$06,$C6,$7C,$00  ; 5
    db $38,$60,$C0,$FC,$C6,$C6,$7C,$00  ; 6
    db $FE,$C6,$0C,$18,$30,$30,$30,$00  ; 7
    db $7C,$C6,$C6,$7C,$C6,$C6,$7C,$00  ; 8
    db $7C,$C6,$C6,$7E,$06,$0C,$78,$00  ; 9
    db $00,$00,$00,$00,$00,$30,$30,$00  ; .
    db $00,$00,$00,$00,$00,$30,$30,$60  ; ,
    db $30,$30,$30,$30,$30,$00,$30,$00  ; !
    db $7C,$C6,$0C,$18,$18,$00,$18,$00  ; ?
    db $30,$30,$60,$00,$00,$00,$00,$00  ; '
    db $00,$00,$00,$7C,$00,$00,$00,$00  ; -
    db $00,$66,$66,$00,$C6,$7C,$00,$00  ; face: happy (smile)
    db $00,$66,$66,$00,$00,$7C,$00,$00  ; face: neutral (flat)
    db $00,$66,$66,$00,$7C,$C6,$00,$00  ; face: mad (frown)
    db $FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF  ; solid box border
    db $00,$00,$7E,$7E,$3C,$18,$00,$00  ; "press A" down-arrow
    db $00,$00,$30,$30,$00,$30,$30,$00  ; HUD: clock colon
    db $00,$00,$AC,$AA,$EC,$A8,$A8,$00  ; HUD: "HP" ligature (3x5 H + P)
    db $10,$38,$7C,$FE,$FE,$FE,$7C,$00  ; HUD: food (apple)
    db $0E,$1C,$38,$7C,$18,$30,$60,$40  ; HUD: energy (lightning bolt)
Font1bppEnd::

; CGB palettes: 4 colours each, BGR555, `dw` = little-endian (matches rBCPD).
; value = (B<<10)|(G<<5)|R, each channel 0-31.
BGPalette::
    ; palette 0 — land
    dw (12 << 10) | (29 << 5) | 21   ; 0 pale green (grass)
    dw (10 << 10) | (22 << 5) | 12   ; 1 mid green  (brush/foliage)
    dw (15 << 10) | (14 << 5) | 13   ; 2 grey
    dw ( 4 << 10) | ( 6 << 5) |  3   ; 3 dark       (outline/trunk)
    ; palette 1 — water
    dw (28 << 10) | (24 << 5) | 10   ; 0 light blue
    dw (26 << 10) | (16 << 5) |  4   ; 1 mid blue
    dw (18 << 10) | (10 << 5) |  2   ; 2 deep blue
    dw (31 << 10) | (31 << 5) | 28   ; 3 foam
    ; palette 2 — city (roads/walls/floors/dirt)
    dw (14 << 10) | (19 << 5) | 22   ; 0 tan/khaki ground
    dw (16 << 10) | (16 << 5) | 16   ; 1 mid grey
    dw (10 << 10) | ( 9 << 5) |  9   ; 2 dark grey
    dw ( 4 << 10) | ( 3 << 5) |  3   ; 3 near-black
    ; palette 3 — marsh (murky ground/reeds)
    dw ( 8 << 10) | (14 << 5) | 11   ; 0 olive murk
    dw ( 6 << 10) | (11 << 5) |  7   ; 1 dark green
    dw ( 4 << 10) | ( 9 << 5) | 12   ; 2 brown
    dw ( 3 << 10) | ( 5 << 5) |  3   ; 3 dark
    ; palette 4 — talk screen UI (font expands to colours 0/3: paper/ink)
    dw (26 << 10) | (30 << 5) | 31   ; 0 warm paper
    dw (20 << 10) | (20 << 5) | 22   ; 1 light grey (unused shade)
    dw (12 << 10) | (11 << 5) | 12   ; 2 mid grey (unused shade)
    dw ( 8 << 10) | ( 4 << 5) |  3   ; 3 ink (near-black navy)
BGPaletteEnd::

OBJPalette::
    ; palette 0 — player
    dw ( 0 << 10) | ( 0 << 5) |  0   ; 0 transparent (ignored for OBJ)
    dw ( 0 << 10) | ( 0 << 5) |  0   ; 1 black (outline + eyes)
    dw (18 << 10) | (24 << 5) | 31   ; 2 skin (face)
    dw ( 4 << 10) | ( 4 << 5) | 28   ; 3 red (body)
    ; palette 1 — zombie
    dw ( 0 << 10) | ( 0 << 5) |  0   ; 0 transparent
    dw ( 0 << 10) | ( 0 << 5) |  0   ; 1 black (outline + eyes)
    dw ( 8 << 10) | (24 << 5) |  9   ; 2 green (face)
    dw ( 3 << 10) | ( 7 << 5) | 12   ; 3 dark brown (body)
    ; palette 2 — alert bubble (also the talk menu cursor, colour 2 amber)
    dw ( 0 << 10) | ( 0 << 5) |  0   ; 0 transparent
    dw ( 4 << 10) | (30 << 5) | 31   ; 1 yellow
    dw ( 2 << 10) | ( 8 << 5) | 20   ; 2 amber
    dw (31 << 10) | (31 << 5) | 31   ; 3 white
    ; palettes 3..7 — survivor personas (PO_PAL): outline/skin shared, body tint
    ; varies. Order matches PERSONA_* ids: police, scientist, cheer, maid, biz.
    dw ( 0 << 10) | ( 0 << 5) |  0   ; 3.0 transparent
    dw ( 0 << 10) | ( 0 << 5) |  0   ; 3.1 black outline
    dw (18 << 10) | (24 << 5) | 31   ; 3.2 skin
    dw (22 << 10) | ( 8 << 5) |  5   ; 3.3 police navy
    dw ( 0 << 10) | ( 0 << 5) |  0   ; 4.0 transparent
    dw ( 0 << 10) | ( 0 << 5) |  0   ; 4.1 black outline
    dw (18 << 10) | (24 << 5) | 31   ; 4.2 skin
    dw (28 << 10) | (28 << 5) | 28   ; 4.3 scientist lab-coat white
    dw ( 0 << 10) | ( 0 << 5) |  0   ; 5.0 transparent
    dw ( 0 << 10) | ( 0 << 5) |  0   ; 5.1 black outline
    dw (18 << 10) | (24 << 5) | 31   ; 5.2 skin
    dw (24 << 10) | (13 << 5) | 31   ; 5.3 cheerleader pink
    dw ( 0 << 10) | ( 0 << 5) |  0   ; 6.0 transparent
    dw ( 0 << 10) | ( 0 << 5) |  0   ; 6.1 black outline
    dw (18 << 10) | (24 << 5) | 31   ; 6.2 skin
    dw (12 << 10) | (10 << 5) | 10   ; 6.3 maid charcoal
    dw ( 0 << 10) | ( 0 << 5) |  0   ; 7.0 transparent
    dw ( 0 << 10) | ( 0 << 5) |  0   ; 7.1 black outline
    dw (18 << 10) | (24 << 5) | 31   ; 7.2 skin
    dw ( 5 << 10) | (12 << 5) | 18   ; 7.3 businessman brown
OBJPaletteEnd::
