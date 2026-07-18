; =============================================================================
; Zomb Boy — main.asm
; -----------------------------------------------------------------------------
; v0 boot skeleton. This does the bare minimum to prove the pinned toolchain
; builds a *valid, bootable* GBC ROM: init the CGB, load a tile, paint the
; background with a zombie-green palette, and idle.
;
; Everything here is placeholder — the real engine (world streaming, combat,
; etc.) is described in docs/design/. This file exists so the build pipeline is
; tested from day one rather than after the code grows large.
; =============================================================================

INCLUDE "hardware.inc"

; -----------------------------------------------------------------------------
; Cartridge entry point. The boot ROM jumps here ($0100). We have 4 bytes
; before the header block ($0104-$014F), which rgbfix fills in.
; -----------------------------------------------------------------------------
SECTION "EntryPoint", ROM0[$0100]
    di
    jp Start

; -----------------------------------------------------------------------------
; Main program (placed after the $0150 header region).
; -----------------------------------------------------------------------------
SECTION "Main", ROM0[$0150]
Start:
    ; --- Wait for VBlank so we can safely turn the LCD off --------------------
.waitVBlank:
    ldh a, [rLY]
    cp SCRN_Y                 ; 144 = first VBlank scanline
    jr c, .waitVBlank

    ; --- LCD off -------------------------------------------------------------
    xor a, a
    ldh [rLCDC], a

    ; --- Copy tile graphics into VRAM ($8000) --------------------------------
    ld hl, Tiles
    ld de, _VRAM              ; $8000
    ld bc, TilesEnd - Tiles
    call MemCopy

    ; --- Paint the background tilemap ($9800) with a checkerboard ------------
    ; 32x32 = 1024 entries; alternating tile 0 / tile 1 per column via a toggle.
    ld hl, _SCRN0             ; $9800
    ld bc, SCRN_VX_B * SCRN_VY_B   ; 32 * 32
    ld d, 0                   ; d = current tile index (toggles 0/1)
.fillMap:
    ld a, d
    ld [hl+], a
    xor a, 1                  ; toggle 0 <-> 1
    ld d, a
    dec bc
    ld a, b
    or a, c
    jr nz, .fillMap

    ; --- Set CGB background palette 0 ----------------------------------------
    ; rBCPS: bit7 = auto-increment index after each write.
    ld a, BCPSF_AUTOINC       ; auto-increment, start at index 0
    ldh [rBCPS], a
    ld hl, BGPalette
    ld b, BGPaletteEnd - BGPalette
.loadPal:
    ld a, [hl+]
    ldh [rBCPD], a
    dec b
    jr nz, .loadPal

    ; --- LCD on: BG enabled, tiles @ $8000, map @ $9800 ----------------------
    ld a, LCDCF_ON | LCDCF_BGON | LCDCF_BG8000 | LCDCF_BG9800
    ldh [rLCDC], a

    ; --- Idle ----------------------------------------------------------------
.loop:
    halt                      ; sleep until an interrupt (none enabled -> low power)
    jr .loop

; -----------------------------------------------------------------------------
; MemCopy: copy BC bytes from HL to DE.
; Clobbers A, BC, DE, HL. BC must be > 0.
; -----------------------------------------------------------------------------
MemCopy:
    ld a, [hl+]
    ld [de], a
    inc de
    dec bc
    ld a, b
    or a, c
    jr nz, MemCopy
    ret

; =============================================================================
; Data
; =============================================================================
SECTION "GfxData", ROM0

; Two 8x8 tiles, 2bpp (16 bytes each).
; Tile 0: solid color 0 (open ground).
; Tile 1: a bordered block using colors 1/2/3 (rubble marker) so the
;         checkerboard is visibly distinct.
Tiles:
    ; tile 0 — all color 0
    ds 16, $00
    ; tile 1 — border pattern (rows of alternating hi/lo bitplanes)
    db $FF,$FF, $81,$81, $81,$81, $81,$81
    db $81,$81, $81,$81, $81,$81, $FF,$FF
TilesEnd:

; CGB palette 0: 4 colors, BGR555 (value = (B<<10)|(G<<5)|R, each 0-31).
; `dw` stores little-endian, which is exactly what rBCPD expects.
; A zombie-green ramp: pale sickly -> mid -> dark -> near-black.
BGPalette:
    dw (14 << 10) | (28 << 5) | 18   ; color 0 — pale sickly green
    dw ( 8 << 10) | (20 << 5) | 10   ; color 1 — mid green
    dw ( 3 << 10) | (10 << 5) |  4   ; color 2 — dark green
    dw ( 1 << 10) | ( 2 << 5) |  1   ; color 3 — near black
BGPaletteEnd:
