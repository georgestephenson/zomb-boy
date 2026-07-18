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
TilesEnd::

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
    ; palette 2 — alert bubble
    dw ( 0 << 10) | ( 0 << 5) |  0   ; 0 transparent
    dw ( 4 << 10) | (30 << 5) | 31   ; 1 yellow
    dw ( 2 << 10) | ( 8 << 5) | 20   ; 2 amber
    dw (31 << 10) | (31 << 5) | 31   ; 3 white
OBJPaletteEnd::
