; =============================================================================
; gfx.asm — tile graphics and CGB palettes.
; Backtick literals: each digit is a 2bpp colour index (0-3) for one pixel.
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
; --- 2: tree (BG pal 0, solid) ---
    dw `00222000
    dw `02233220
    dw `22333322
    dw `23333332
    dw `22333322
    dw `02233220
    dw `00033000
    dw `00033000
; --- 3: wall / rock (BG pal 0, solid) ---
    dw `22222222
    dw `23232323
    dw `22222222
    dw `32323232
    dw `22222222
    dw `23232323
    dw `22222222
    dw `32323232
; --- 4: water (BG pal 1, solid) ---
    dw `00000000
    dw `10001000
    dw `00000001
    dw `00100010
    dw `00000000
    dw `01000100
    dw `00010000
    dw `00000000
; --- 5: road (BG pal 0, passable) ---
    dw `22222222
    dw `21222212
    dw `22222222
    dw `22122122
    dw `22222222
    dw `21222212
    dw `22222222
    dw `22122122
; Character sprites: colour 1 = black (outline + eyes), 2 = face, 3 = body.
; --- 6: player down A (OBJ pal 0; face skin, body red) ---
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
; --- 7: player down B ---
    dw `00111100
    dw `01333310
    dw `01222210
    dw `01212110
    dw `01222210
    dw `01111110
    dw `13333331
    dw `00133100
; --- 8: player up A (back of head; no eyes) ---
    dw `00111100
    dw `01333310
    dw `01222210
    dw `01222210
    dw `01222210
    dw `13111131
    dw `11333311
    dw `01311310
; --- 9: player up B ---
    dw `00111100
    dw `01333310
    dw `01222210
    dw `01222210
    dw `01222210
    dw `01111110
    dw `13333331
    dw `00133100
; --- 10: player side A (right profile: narrow head, cap brim juts fwd;
;         one eye. Flip X for left — brim always leads the walk) ---
    dw `00111000
    dw `01333100
    dw `01333331
    dw `01212100
    dw `01222100
    dw `13111131
    dw `11333311
    dw `01311310
; --- 11: player side B ---
    dw `00111000
    dw `01333100
    dw `01333331
    dw `01212100
    dw `01222100
    dw `01111110
    dw `13333331
    dw `00133100
; --- 12: zombie down A (OBJ pal 1; hunched, face green, body brown) ---
    dw `00000000
    dw `00111100
    dw `01333310
    dw `01212110
    dw `01222210
    dw `13111131
    dw `11333311
    dw `01311310
; --- 13: zombie down B ---
    dw `00000000
    dw `00111100
    dw `01333310
    dw `01212110
    dw `01222210
    dw `01111110
    dw `13333331
    dw `00133100
; --- 14: zombie up A (no eyes) ---
    dw `00000000
    dw `00111100
    dw `01333310
    dw `01222210
    dw `01222210
    dw `13111131
    dw `11333311
    dw `01311310
; --- 15: zombie up B ---
    dw `00000000
    dw `00111100
    dw `01333310
    dw `01222210
    dw `01222210
    dw `01111110
    dw `13333331
    dw `00133100
; --- 16: zombie side A (hunched right profile, one eye; flip X for left) ---
    dw `00000000
    dw `00111000
    dw `01333100
    dw `01333331
    dw `01212100
    dw `13111131
    dw `11333311
    dw `01311310
; --- 17: zombie side B ---
    dw `00000000
    dw `00111000
    dw `01333100
    dw `01333331
    dw `01212100
    dw `01111110
    dw `13333331
    dw `00133100
; --- 18: "!" alert bubble (OBJ pal 2) ---
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
    dw (10 << 10) | (22 << 5) | 12   ; 1 mid green  (brush)
    dw (15 << 10) | (14 << 5) | 13   ; 2 grey       (wall/road)
    dw ( 4 << 10) | ( 6 << 5) |  3   ; 3 dark       (outline/foliage)
    ; palette 1 — water
    dw (28 << 10) | (24 << 5) | 10   ; 0 light blue
    dw (26 << 10) | (16 << 5) |  4   ; 1 mid blue
    dw (18 << 10) | (10 << 5) |  2   ; 2 deep blue
    dw (31 << 10) | (31 << 5) | 28   ; 3 foam
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
