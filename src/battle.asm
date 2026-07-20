; =============================================================================
; battle.asm — PLACEHOLDER battle transition.
;
; Real combat (docs/design/04) isn't built yet. For now, spotting the player
; triggers a short screen flash and the zombie despawns, so the full
; detect -> "!" -> battle -> resume loop is real and testable. When combat
; lands, BattleTransition becomes the entry into the battle mode/UI.
; =============================================================================
INCLUDE "hardware.inc"
INCLUDE "include/constants.inc"

SECTION "Battle", ROM0

BattleTransition::
    ld c, 4                     ; number of flashes
.loop:
    call FlashWhite
    call WaitFewFrames
    call LoadPalettes           ; restore the real palettes
    call WaitFewFrames
    dec c
    jr nz, .loop
    call WaitHold
    ; LoadPalettes above restored the NEUTRAL (daytime) BG palettes. If a
    ; day/night tint was in effect, invalidate the applied bucket so the overworld
    ; loop's UpdateDayNight re-shades on the next frame — otherwise the world stays
    ; daytime after combat until the clock next crosses a bucket boundary. Just a
    ; WRAM write (no bank needed); harmless on DMG, where UpdateDayNight no-ops.
    ld a, DN_INVALID
    ld [wDayBucket], a
    ret

; Overwrite BG palette 0 with white to flash the scene.
FlashWhite:
    ld a, BCPSF_AUTOINC
    ldh [rBCPS], a
    ld b, 8                     ; 4 colours x 2 bytes
.w:
    ld a, $FF
    ldh [rBCPD], a
    dec b
    jr nz, .w
    ret

WaitFewFrames:
    ld b, 4
.l:
    call WaitVBlank
    dec b
    jr nz, .l
    ret

WaitHold:
    ld b, 30
.l:
    call WaitVBlank
    dec b
    jr nz, .l
    ret
