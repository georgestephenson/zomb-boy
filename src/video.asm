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

; Zero all of WRAM ($C000-$DFFF). Real hardware / accurate emulators (mGBA) do
; NOT zero RAM at power-on, so anything that reads a variable before it's set
; would see garbage. Clearing once at boot removes that entire class of bug
; (e.g. an uninitialised wStrKind made BlitStream run over garbage and hang).
; `xor a` each iteration keeps the fill value 0 despite the counter test.
ClearRAM::
    ld hl, _RAM                 ; $C000
    ld bc, $2000                ; 8 KiB (WRAM0 + the mapped WRAMX bank)
.loop:
    xor a, a
    ld [hl+], a
    dec bc
    ld a, b
    or a, c
    jr nz, .loop
    ret

; Zero both VRAM banks ($8000-$9FFF x2). LCD must be off. Clears leftover tiles
; and the unused BG attribute map so nothing stale can ever be displayed.
ClearVRAM::
    ld a, 1
    ldh [rVBK], a               ; bank 1 (attributes / bank-1 tiles)
    call .bank
    xor a, a
    ldh [rVBK], a               ; bank 0 (tiles / map)
.bank:
    ld hl, _VRAM                ; $8000
    ld bc, $2000
.loop:
    xor a, a
    ld [hl+], a
    dec bc
    ld a, b
    or a, c
    jr nz, .loop
    ret

; Silence the APU. We have no audio yet; power-on APU state is undefined and can
; emit noise, so turn it fully off (a real sound driver will init it later).
InitAudio::
    xor a, a
    ldh [rNR52], a              ; APU off
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
; Scroll the BG to the camera. Base comes from the (snapped) view; wCamLagX/Y
; add the smooth sub-tile lag computed by ComputeCamLag. Sprites subtract the
; same lag, so background and sprites share one camera.
SetScroll::
    ld a, [wViewTX]
    and 31
    add a, a
    add a, a
    add a, a                    ; * 8
    ld hl, wCamLagX
    add a, [hl]
    ldh [rSCX], a
    ld a, [wViewTY]
    and 31
    add a, a
    add a, a
    add a, a
    ld hl, wCamLagY
    add a, [hl]
    ldh [rSCY], a
    ret
