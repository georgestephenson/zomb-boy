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
    ; Reserve the cartridge header ($0104-$014F) so the linker never places code
    ; here — rgbfix fills it with the logo/title/checksums.
    ds $0150 - @

SECTION "Main", ROM0[$0150]
Start:
    ld sp, $FFFE                    ; explicit stack top (don't trust the boot ROM)

    ; --- detect console, stash in HRAM (ClearRAM below only wipes WRAM) --------
    ; Probe the VRAM-bank register: on CGB it's writable, so bank 0 reads back
    ; with bit0 = 0; on DMG rVBK is unmapped and reads $FF (bit0 = 1). (The boot
    ; ROM's A = $11/$01 handoff also works on hardware, but this probe is robust
    ; regardless of how we were launched.) Everything CGB-only is gated on the
    ; flag so the ROM also runs on an original Game Boy, in grayscale.
    xor a, a
    ldh [rVBK], a
    ldh a, [rVBK]
    and 1                           ; 0 = CGB, 1 = DMG
    xor 1                           ; -> 1 = CGB, 0 = DMG
    ldh [hIsCGB], a
    and a
    jr z, .noSpeed                  ; DMG: skip double-speed (STOP would hang it)

    ; --- CGB double-speed CPU ---------------------------------------------
    ; The biome generator does a lot of hashing per tile; at normal speed the
    ; full-map InitMap at boot and the per-step GenStrip are heavy. Double speed
    ; halves all CPU-bound work (boot generation *and* the VBlank blit budget).
    ; Interrupts are still disabled here (`di` at $0100), which STOP requires.
    ldh a, [rKEY1]
    bit 7, a                        ; already running double-speed?
    jr nz, .noSpeed
    ld a, $30
    ldh [rP1], a                    ; deselect joypad lines (required before STOP)
    ld a, 1
    ldh [rKEY1], a                  ; arm the speed switch
    stop                            ; performs the switch, then resumes
.noSpeed:

    call WaitVBlankLY               ; safe point to turn the LCD off
    xor a, a
    ldh [rLCDC], a

    ; --- boot hygiene: power-on RAM/VRAM/APU/bank state is undefined on real
    ;     hardware (mGBA), so put everything in a known state before we start.
    call ClearRAM                   ; zero WRAM  (nothing may rely on zeroed RAM)
    call ClearVRAM                  ; zero both VRAM banks
    call InitAudio                  ; silence the APU during setup (InitSound powers it on)
    ld a, 1
    ldh [rSVBK], a                  ; map WRAM bank 1 at $D000
    xor a, a
    ldh [rVBK], a                   ; VRAM bank 0 for rendering

    ; --- content setup ---
    call LoadTiles
    call CopyDMARoutine
    call LoadPalettes

    call InitPlayer                 ; choose a passable start tile
    call UpdateView                 ; derive the camera from the player
    call InitMap                    ; generate the initial 32x32 map + attrs

    ; seed the RNG (must be non-zero) and spawn wandering zombies.
    ; wGameMode / wStrKind etc. are already 0 from ClearRAM.
    ld a, $AC
    ld [wRngState], a
    ld a, $E1
    ld [wRngState+1], a
    call InitZombies

    call InitSound                  ; power on the APU + start the demo song

    call DrawEntities
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
    call UpdateSound                ; advance music one tick (once/frame, pre-VBlank)
    call ReadInput
    ld a, [wGameMode]
    and a, a                        ; MODE_OVERWORLD == 0
    jr nz, .alert
    ; --- overworld ---
    call UpdatePlayer
    call UpdateView
    ld a, [wMoveDir]
    and a, a
    call nz, GenStrip               ; build incoming column/row (outside VBlank)
    call UpdateZombies              ; wander + line-of-sight (may trigger alert)
    jr .draw
.alert:
    call UpdateAlert                ; "!" countdown -> placeholder battle
.draw:
    call ComputeCamLag              ; shared sub-tile camera offset (BG + sprites)
    call DrawEntities

    call WaitVBlank
    ; --- VBlank window ---
    ld a, HIGH(wShadowOAM)
    call hOAMDMA
    call SetScroll
    call BlitStream                 ; push the queued strip into VRAM
    jr MainLoop
