; =============================================================================
; video.asm — VBlank sync, OAM DMA, palette/tile loading, scroll.
; =============================================================================
INCLUDE "hardware.inc"
INCLUDE "include/constants.inc"

; --- VBlank interrupt handler (fixed vector) --------------------------------
SECTION "VBlank IRQ", ROM0[$0040]
    push af
    ld a, 1
    ldh [hVBlankFlag], a
    pop af
    reti

SECTION "Video", ROM0

; Spin until the PPU reaches VBlank by polling LY (used before IRQs are on).
WaitVBlankLY::
    ldh a, [rLY]
    cp SCRN_Y
    jr c, WaitVBlankLY
    ret

; Wait for the VBlank interrupt (IRQs must be enabled). Returns at VBlank start.
WaitVBlank::
    xor a, a
    ldh [hVBlankFlag], a
.wait:
    halt
    ldh a, [hVBlankFlag]
    and a, a
    jr z, .wait
    ret

; Copy tile graphics into VRAM ($8000). LCD should be off.
LoadTiles::
    ld hl, Tiles
    ld de, _VRAM
    ld bc, TilesEnd - Tiles
.copy:
    ld a, [hl+]
    ld [de], a
    inc de
    dec bc
    ld a, b
    or a, c
    jr nz, .copy
    ret

; Load CGB BG palettes (BGPalette..End) and OBJ palette 0 (OBJPalette..End).
LoadPalettes::
    ld a, BCPSF_AUTOINC
    ldh [rBCPS], a
    ld hl, BGPalette
    ld b, BGPaletteEnd - BGPalette
.bg:
    ld a, [hl+]
    ldh [rBCPD], a
    dec b
    jr nz, .bg
    ld a, OCPSF_AUTOINC
    ldh [rOCPS], a
    ld hl, OBJPalette
    ld b, OBJPaletteEnd - OBJPalette
.obj:
    ld a, [hl+]
    ldh [rOCPD], a
    dec b
    jr nz, .obj
    ret

; Zero shadow OAM (all sprites off-screen).
ClearShadowOAM::
    ld hl, wShadowOAM
    ld bc, wShadowOAM_End - wShadowOAM
    xor a, a
.loop:
    ld [hl+], a
    dec bc
    ld a, b
    or a, c
    jr nz, .loop
    ret

; Install the OAM DMA trampoline into HRAM (DMA must be kicked from HRAM).
CopyDMARoutine::
    ld hl, DMARoutine
    ld c, LOW(hOAMDMA)
    ld b, DMARoutineEnd - DMARoutine
.copy:
    ld a, [hl+]
    ldh [c], a
    inc c
    dec b
    jr nz, .copy
    ret

; Template copied to HRAM. Call as: ld a, HIGH(wShadowOAM) : call hOAMDMA
DMARoutine:
    ldh [rDMA], a
    ld a, 40
.wait:
    dec a
    jr nz, .wait
    ret
DMARoutineEnd:

; Set BG scroll from the current view. Because the 32x32 BG map is a circular
; buffer, the world tile at wViewTX lives in BG column (wViewTX & 31), so the
; scroll is just that cell's pixel offset.
SetScroll::
    ld a, [wViewTX]
    and 31
    add a, a
    add a, a
    add a, a                    ; * 8
    ldh [rSCX], a
    ld a, [wViewTY]
    and 31
    add a, a
    add a, a
    add a, a
    ldh [rSCY], a
    ret
