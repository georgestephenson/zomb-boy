; =============================================================================
; Zomb Boy — main.asm  (v0.2: endless world)
; -----------------------------------------------------------------------------
; Entry point, boot init, and the main loop. Systems live in sibling modules:
;   world.asm   terrain generation + BG streaming
;   player.asm  movement, collision, camera, sprite
;   video.asm   VBlank, OAM DMA, palettes, scroll
;   input.asm   joypad
;   gfx.asm     tile + palette data
;   ram.asm     WRAM/HRAM variables
; =============================================================================
INCLUDE "hardware.inc"
INCLUDE "include/constants.inc"

SECTION "EntryPoint", ROM0[$0100]
    di
    jp Start

SECTION "Main", ROM0[$0150]
Start:
    call WaitVBlankLY               ; safe point to turn the LCD off
    xor a, a
    ldh [rLCDC], a

    call LoadTiles
    call ClearShadowOAM
    call CopyDMARoutine
    call LoadPalettes

    call InitPlayer                 ; choose a passable start tile
    call UpdateView                 ; derive the camera from the player
    call InitMap                    ; generate the initial 32x32 map + attrs

    xor a, a
    ldh [rVBK], a                   ; ensure VRAM bank 0 for normal rendering
    call DrawPlayerSprite
    ld a, HIGH(wShadowOAM)
    call hOAMDMA                    ; clean OAM before the first visible frame
    call SetScroll

    ld a, LCDCF_ON | LCDCF_BGON | LCDCF_OBJON | LCDCF_OBJ8 | LCDCF_BG8000 | LCDCF_BG9800
    ldh [rLCDC], a

    ld a, IEF_VBLANK
    ldh [rIE], a
    xor a, a
    ldh [rIF], a
    ei

; -----------------------------------------------------------------------------
; Main loop. Logic runs first (generating any incoming strip into WRAM), then
; we wait for VBlank and push OAM + scroll + the strip to VRAM in one shot, so
; the new edge appears the same frame the camera scrolls — no seam, no latency.
; -----------------------------------------------------------------------------
MainLoop:
    call ReadInput
    call UpdatePlayer
    call UpdateView
    ld a, [wMoveDir]
    and a, a
    call nz, GenStrip               ; build incoming column/row (outside VBlank)
    call DrawPlayerSprite

    call WaitVBlank
    ; --- VBlank window ---
    ld a, HIGH(wShadowOAM)
    call hOAMDMA
    call SetScroll
    call BlitStream                 ; push the queued strip into VRAM
    jr MainLoop
