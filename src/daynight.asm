; =============================================================================
; daynight.asm — time-of-day palette tint (docs/design/03 day/night, 07 §5.1).
;
; The overworld's four TERRAIN BG palettes (0..3: land/water/city/marsh) are
; re-shaded to the time of day by rewriting palette memory each time the clock
; crosses a bucket boundary. This is the cheapest colour effect on the platform:
; no VRAM tile writes, no OAM, no per-frame cost — a palette rewrite (docs/design
; 07 §1.3). Palette 4 (talk/HUD UI) and 5..7 (portraits) are never touched, so
; the status bar and dialogue stay readable at every hour.
;
; CGB ONLY. On DMG there is one 4-shade grey BGP and no per-palette colour, so a
; day/night TINT is inherently a colour-hardware feature (07 §1.3 / the dual-mode
; invariant); the DMG path is left neutral. UpdateDayNight early-returns on DMG,
; so nothing downstream ever fires there.
;
; Determinism: the shade is a pure function of wClockH — it never touches Rand,
; so spawn/loot/talk determinism and the whole integration suite are unperturbed.
; Morning and day use identity factors, so at CLOCK_START_HOUR (08:00 = morning)
; the tint reproduces BGPalette byte-for-byte and boot state is unchanged.
;
; Split, like the rest of the engine: the heavy work (ComputeTint: read BGPalette
; from its ROMX bank, scale 16 colours) runs in the LOGIC phase on a bucket
; change only; the VBlank push (PushDayNight) is a flat 32-byte copy to palette
; RAM. Lives in ROMX BANK[1] (ROM0 is full) — the default-mapped bank, mapped in
; every context these routines run from (overworld logic + VBlank), exactly like
; anim.asm / loot.asm.
; =============================================================================
INCLUDE "hardware.inc"
INCLUDE "include/constants.inc"

SECTION "DayNight Code", ROMX, BANK[1]

; -----------------------------------------------------------------------------
; InitDayNight: boot setup (call after InitHUD has set wClockH). Arm a forced
; re-tint on the first overworld frame; nothing is pushed yet.
; -----------------------------------------------------------------------------
InitDayNight::
    ld a, DN_INVALID
    ld [wDayBucket], a
    xor a, a
    ld [wTintPending], a
    ret

; -----------------------------------------------------------------------------
; UpdateDayNight: one overworld logic frame. When the clock has crossed into a
; new time-of-day bucket, recompute the tinted palettes and arm the VBlank push.
; CGB only; cheap (a few compares) when the bucket is unchanged.
; -----------------------------------------------------------------------------
UpdateDayNight::
    ldh a, [hIsCGB]
    and a, a
    ret z                       ; DMG: single grey BGP, no per-palette tint
    ld a, [wClockH]
    call DayBucket              ; -> A = DN_* for this hour
    ld hl, wDayBucket
    cp [hl]
    ret z                       ; same bucket -> nothing to do
    ld [hl], a                  ; remember it
    call ComputeTint            ; fill wTintPal from BGPalette * factors[bucket]
    ld a, 1
    ld [wTintPending], a
    ret

; -----------------------------------------------------------------------------
; PushDayNight: VBlank only (overworld). Stream the tinted terrain palettes into
; BG palette RAM when a re-tint is pending. Flat 32-byte copy; CGB double-speed
; leaves ample VBlank budget, so unlike PushHUD/PushAnim it needn't yield on a
; strip-blit frame (and a bucket change is not time-critical anyway).
; -----------------------------------------------------------------------------
PushDayNight::
    ld a, [wTintPending]
    and a, a
    ret z
    xor a, a
    ld [wTintPending], a
    ld a, BCPSF_AUTOINC         ; start at palette 0, colour 0, auto-increment
    ldh [rBCPS], a
    ld hl, wTintPal
    ld b, 32                    ; palettes 0..3 = 4 * 4 colours * 2 bytes
.push:
    ld a, [hl+]
    ldh [rBCPD], a
    dec b
    jr nz, .push
    ret

; -----------------------------------------------------------------------------
; DayBucket: A = hour (0..23) -> A = DN_* bucket. Boundaries match the dialogue
; clock (CTX_NIGHT >= 22 or < 5, MORNING 5..11, DAY 12..17, DUSK 18..21).
; -----------------------------------------------------------------------------
DayBucket:
    cp 5
    jr c, .night                ; 0..4
    cp 12
    jr c, .morning              ; 5..11
    cp 18
    jr c, .day                  ; 12..17
    cp 22
    jr c, .dusk                 ; 18..21
.night:                         ; 22..23 fall through here too
    ld a, DN_NIGHT
    ret
.morning:
    ld a, DN_MORNING
    ret
.day:
    ld a, DN_DAY
    ret
.dusk:
    ld a, DN_DUSK
    ret

; -----------------------------------------------------------------------------
; ComputeTint: A = DN_* bucket. Fill wTintPal with the four terrain palettes
; scaled by that bucket's per-channel factors. Source is wNeutralPal — a WRAM
; copy of BGPalette 0..3 that LoadPalettes cached at boot — so this stays entirely
; in BANK[1] with no bank switch (the ROM banking invariant: a BANK[1] routine
; must not map another bank while executing its own code).
; -----------------------------------------------------------------------------
ComputeTint:
    ; factor triple = TintFactors + bucket*3  (TintFactors is in BANK[1], mapped)
    ld l, a
    ld h, 0
    ld e, l                     ; de = bucket (x1) — copy BEFORE doubling
    ld d, h
    add hl, hl                  ; hl = bucket*2
    add hl, de                  ; hl = bucket*3
    ld de, TintFactors
    add hl, de
    ld a, [hl+]
    ld [wTintFR], a
    ld a, [hl+]
    ld [wTintFG], a
    ld a, [hl+]
    ld [wTintFB], a
    ; scale the 16 cached terrain colours into wTintPal
    ld hl, wNeutralPal
    ld de, wTintPal
    ld c, 16
.colour:
    ld a, [hl+]
    ld [wTintLo], a
    ld a, [hl+]
    ld [wTintHi], a
    push hl
    push de
    push bc
    call TintOne                ; wTintLo/Hi + factors -> wTintOut0/1
    pop bc
    pop de
    pop hl
    ld a, [wTintOut0]
    ld [de], a
    inc de
    ld a, [wTintOut1]
    ld [de], a
    inc de
    dec c
    jr nz, .colour
    ret

; -----------------------------------------------------------------------------
; TintOne: scale one BGR555 colour (wTintLo/Hi) by wTintF{R,G,B} into
; wTintOut0/1. Colours are little-endian: value = (B<<10)|(G<<5)|R, 5 bits each.
; All field math is srl/add (no rotate-wrap subtlety). Rare path; clarity first.
; -----------------------------------------------------------------------------
TintOne:
    ; --- unpack + scale R = lo & $1F ---
    ld a, [wTintLo]
    and $1F
    ld b, a
    ld a, [wTintFR]
    ld c, a
    call MulF3
    ld [wTintR], a
    ; --- G = (lo >> 5) | ((hi & 3) << 3) ---
    ld a, [wTintLo]
    srl a
    srl a
    srl a
    srl a
    srl a                       ; lo >> 5 -> G's low 3 bits (0..7)
    ld b, a
    ld a, [wTintHi]
    and 3
    add a, a
    add a, a
    add a, a                    ; (hi & 3) << 3 -> G's high 2 bits
    or b
    ld b, a
    ld a, [wTintFG]
    ld c, a
    call MulF3
    ld [wTintG], a
    ; --- B = (hi >> 2) & $1F ---
    ld a, [wTintHi]
    srl a
    srl a                       ; hi >> 2 (top bits already 0)
    ld b, a
    ld a, [wTintFB]
    ld c, a
    call MulF3
    ld [wTintBb], a
    ; --- repack lo' = R | ((G & 7) << 5) ---
    ld a, [wTintG]
    and 7
    add a, a
    add a, a
    add a, a
    add a, a
    add a, a                    ; << 5
    ld b, a
    ld a, [wTintR]
    or b
    ld [wTintOut0], a
    ; --- repack hi' = ((G >> 3) & 3) | (B << 2) ---
    ld a, [wTintG]
    srl a
    srl a
    srl a
    and 3
    ld b, a
    ld a, [wTintBb]
    add a, a
    add a, a                    ; << 2
    or b
    ld [wTintOut1], a
    ret

; -----------------------------------------------------------------------------
; MulF3: B = channel value (0..31), C = scale factor (0..8) -> A = (B*C) >> 3.
; A darkening/tinting multiply; factor 8 is identity ((v*8)>>3 == v). Product
; peaks at 31*8 = 248, so it stays in one byte. Clobbers A, C.
; -----------------------------------------------------------------------------
MulF3:
    xor a, a
    inc c
.loop:
    dec c
    jr z, .done
    add a, b
    jr .loop
.done:
    srl a
    srl a
    srl a
    ret

; -----------------------------------------------------------------------------
; TintFactors: per-bucket R,G,B scale (out = in*f >> 3, f in 0..8), indexed by
; DN_*. Morning/day are identity (bright, = the authored BGPalette); dusk warms
; and dims; night darkens and cools toward blue. One row per bucket, in DN_ order.
; -----------------------------------------------------------------------------
TintFactors:
    db 8, 8, 8                  ; DN_MORNING — identity
    db 8, 8, 8                  ; DN_DAY     — identity
    db 8, 6, 4                  ; DN_DUSK    — keep red, drop green/blue -> amber
    db 4, 5, 7                  ; DN_NIGHT   — darken all, keep blue highest -> cool
