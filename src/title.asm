; =============================================================================
; title.asm — full-screen CGB title background (MODE: pre-gameplay only).
;
; ShowTitle paints the 160x144 image generated in title_data.asm (see
; tools/gen-title.py) straight onto SCRN0 with SCX/SCY = 0. The scene needs ~1
; tile per screen of dedup, so it spans BOTH VRAM banks (359 tiles): tile ids
; 0..255 live in bank 0, 256.. re-based to 0 in bank 1, and each cell's
; attribute byte carries the bank bit (plus palette + H/V flip).
;
; This is CGB-only: it uses per-tile BG palettes and the second VRAM bank, which
; DMG lacks. main.asm gates on hIsCGB and keeps the classic text title
; (DrawTitle) for DMG. The title owns all of VRAM before gameplay; after START
; main.asm reloads the game tiles (LoadTiles/LoadFont) and palettes, then InitMap
; rewrites the whole tile+attribute map, so nothing here needs cleanup.
;
; Runs with the LCD OFF (called from boot before the title loop), so it may
; touch VRAM and palette RAM freely. The title data bank (BANK[3]) is mapped
; here and the default bank 1 (song + dialogue) is restored before returning.
; =============================================================================
INCLUDE "hardware.inc"
INCLUDE "include/constants.inc"

SECTION "Title", ROM0

ShowTitle::
    ld a, BANK(TitleTiles)
    ld [rROMB0], a

    ; --- 8 BG palettes (64 bytes) into slots 0..7, from slot 0 ---
    ld a, BCPSF_AUTOINC
    ldh [rBCPS], a
    ld hl, TitlePalettes
    ld b, 8 * 4 * 2                  ; 8 palettes x 4 colours x 2 bytes
.pal:
    ld a, [hl+]
    ldh [rBCPD], a
    dec b
    jr nz, .pal

    ; --- tile data: bank 0 (ids 0..255), then bank 1 (ids 256..) ---
    ld hl, TitleTiles
    xor a, a
    ldh [rVBK], a                   ; VRAM bank 0
    ld de, _VRAM
    ld bc, TITLE_BANK0_BYTES
    call .copy
    ld a, 1
    ldh [rVBK], a                   ; VRAM bank 1
    ld de, _VRAM                    ; bank 1 tiles start at $8000 too
    ld bc, TITLE_BANK1_BYTES
    call .copy

    ; --- tile ids -> SCRN0 (bank 0), 20 wide x 18 tall on a 32-wide map ---
    xor a, a
    ldh [rVBK], a
    ld hl, TitleMap
    ld de, _SCRN0
    call .blit20x18

    ; --- attributes -> SCRN0 (bank 1) ---
    ld a, 1
    ldh [rVBK], a
    ld hl, TitleAttrs
    ld de, _SCRN0
    call .blit20x18
    xor a, a
    ldh [rVBK], a

    ld a, 1                         ; restore the default song + dialogue bank
    ld [rROMB0], a
    ret

; Copy BC bytes HL -> DE (BC may exceed 255).
.copy:
    ld a, [hl+]
    ld [de], a
    inc de
    dec bc
    ld a, b
    or a, c
    jr nz, .copy
    ret

; Copy an 18-row x 20-col block HL -> DE on a 32-wide tile map (DE += 32/row).
.blit20x18:
    ld c, 18
.row:
    ld b, 20
    push de
.col:
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .col
    pop de
    ld a, e                         ; de += 32 (next map row)
    add a, 32
    ld e, a
    ld a, d
    adc a, 0
    ld d, a
    dec c
    jr nz, .row
    ret
