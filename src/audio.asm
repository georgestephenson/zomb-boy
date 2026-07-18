; =============================================================================
; audio.asm — music playback seam over the vendored hUGEDriver.
; -----------------------------------------------------------------------------
; The driver itself (vendor/hUGEDriver/hUGEDriver.asm) and the demo song
; (vendor/hUGEDriver/songs/song_demo.asm) are third-party, assembled separately
; and linked in (see the Makefile's AUDIO_OBJS). This module is the *game-side*
; wrapper: it keeps the driver's external symbols (hUGE_init / hUGE_dosound /
; song_demo) in one place and uses our project's pinned v4.12.0 hardware.inc
; names (rNR5x), so the rest of the game never touches driver internals.
;
;   InitSound   — power the APU on, full volume both sides, load the demo song.
;   UpdateSound — advance playback by one tick; call once per frame.
; =============================================================================
INCLUDE "hardware.inc"
INCLUDE "include/constants.inc"

SECTION "Audio", ROM0

; Turn the APU on and start the demo song. Call once, after the LCD/content is
; set up and before the main loop. hUGEDriver requires the APU enabled before
; hUGE_init, so we power it up first (this supersedes the boot-time InitAudio
; silence in video.asm).
InitSound::
    ld a, $80                       ; NR52: master enable (bit7). Must precede any
    ldh [rNR52], a                  ;       other APU writes — regs ignore writes off.
    ld a, $FF                       ; NR51: every channel routed to both L and R.
    ldh [rNR51], a
    ld a, $77                       ; NR50: max master volume, left and right.
    ldh [rNR50], a

    ld hl, song_demo                ; song descriptor (see songs/song_demo.asm)
    call hUGE_init
    ret

; Advance the music one tick. Must be called at a steady once-per-frame rate for
; correct tempo; the main loop is frame-locked by WaitVBlank, so calling it once
; per iteration (outside the VBlank window, to spare that tight budget) is exactly
; one call per frame. Clobbers a/bc/de/hl — fine at the top of the loop.
UpdateSound::
    jp hUGE_dosound                 ; tail-call: hUGE_dosound's ret returns for us
