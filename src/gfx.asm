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
; --- 6: player down A (OBJ pal 0) ---
    dw `00111100
    dw `01111110
    dw `01311310
    dw `01111110
    dw `01111110
    dw `00111100
    dw `01100000
    dw `00000110
; --- 7: player down B ---
    dw `00111100
    dw `01111110
    dw `01311310
    dw `01111110
    dw `01111110
    dw `00111100
    dw `00000110
    dw `01100000
; --- 8: player up A ---
    dw `00111100
    dw `01111110
    dw `01111110
    dw `01111110
    dw `01111110
    dw `00111100
    dw `01100000
    dw `00000110
; --- 9: player up B ---
    dw `00111100
    dw `01111110
    dw `01111110
    dw `01111110
    dw `01111110
    dw `00111100
    dw `00000110
    dw `01100000
; --- 10: player side A (facing right; flip X for left) ---
    dw `00111100
    dw `01111130
    dw `01111110
    dw `01111110
    dw `00111100
    dw `01110000
    dw `00011000
    dw `00000110
; --- 11: player side B ---
    dw `00111100
    dw `01111130
    dw `01111110
    dw `01111110
    dw `00111100
    dw `00011000
    dw `01100000
    dw `00000110
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
    dw ( 0 << 10) | ( 0 << 5) |  0   ; 0 transparent (ignored for OBJ)
    dw ( 6 << 10) | ( 8 << 5) | 31   ; 1 red (body)
    dw ( 3 << 10) | ( 3 << 5) | 20   ; 2 dark red (shading)
    dw (31 << 10) | (31 << 5) | 31   ; 3 white (highlight)
OBJPaletteEnd::
