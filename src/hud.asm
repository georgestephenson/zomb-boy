; =============================================================================
; hud.asm — the always-on overworld status bar (docs/design/03: v0 meters —
; visible and draining, but not yet lethal).
;
;   [HP]100 [food]100 [energy]100 08:00      (exactly HUD_COLS = 20 cells)
;
; Display mechanics:
;   * The HUD is the hardware WINDOW. The window is NOT a sizable rectangle:
;     from (WX,WY) it renders to the BOTTOM-RIGHT of the screen, so a top bar
;     would need an LYC raster split to shut it off after 8 lines. A bottom
;     bar is free: WY = SCRN_Y-8 / WX = 7 overlays exactly the last 8 px and
;     never scrolls. It fetches from SCRN1 row 0 (the window always reads its
;     map from the top) — free, because the talk screen's layout starts at
;     row 1. Talk mode runs with the window OFF (BuildTalkScreen wipes the
;     row); ExitTalkScreen redraws it via DrawHUDRow.
;   * Composition happens in the logic phase (ComposeHUD -> wHUDText); the
;     VBlank push (PushHUD) is a 20-byte copy, skipped on any frame that
;     already blits a world strip so the DMG VBlank budget holds.
;   * Sprites render on top of the window, so EntScreenPos (entity.asm) culls
;     any sprite that would overlap the bottom band — entities in the hidden
;     bottom world row don't float over the HUD.
;   * The clock ticks one in-game minute per CLOCK_MINUTE_FRAMES overworld
;     frames; time pauses in talk/alert modes. Food/energy drain on power-of-2
;     minute boundaries (saturating at 0 — the repo's no-wrap rule).
; =============================================================================
INCLUDE "hardware.inc"
INCLUDE "include/constants.inc"

SECTION "HUD", ROM0

; -----------------------------------------------------------------------------
; InitHUD: boot-time setup (call with the LCD off, after ClearVRAM/ClearRAM).
; Meters full, clock at CLOCK_START_HOUR:00, row rendered straight into VRAM,
; window position registers set.
; -----------------------------------------------------------------------------
InitHUD::
    ld a, METER_MAX
    ld [wHP], a
    ld [wFood], a
    ld [wEnergy], a
    ld a, CLOCK_START_HOUR
    ld [wClockH], a
    xor a, a
    ld [wClockM], a
    ld [wClockFrame], a
    ld [wClockMinCount], a
    ld [wHUDDirty], a
    ld a, 7                    ; WX=7 is the leftmost window position
    ldh [rWX], a
    ld a, SCRN_Y - 8           ; start on scanline 136: the window runs from WY
    ldh [rWY], a               ; to the screen bottom, so this shows 8 lines
    call ComposeHUD
    ; fall through into the full draw

; -----------------------------------------------------------------------------
; DrawHUDRow: full redraw — bank-1 attributes + tiles for SCRN1 row 0.
; Call with the LCD off (boot) or inside VBlank (talk exit): ~40 writes.
; -----------------------------------------------------------------------------
DrawHUDRow::
    ldh a, [hIsCGB]            ; attribute pass is CGB-only (repo invariant:
    and a, a                   ; on DMG the rVBK write is a no-op and this
    jr z, HUDCopyTiles         ; would overwrite the tile row itself)
    ld a, 1
    ldh [rVBK], a
    ld hl, _SCRN1
    ld b, HUD_COLS
    ld a, PAL_BG_UI
.attr:
    ld [hl+], a
    dec b
    jr nz, .attr
    ; fall through (HUDCopyTiles resets rVBK to bank 0)

; HUDCopyTiles: push wHUDText into SCRN1 row 0 and clear the dirty flag.
HUDCopyTiles:
    xor a, a
    ld [wHUDDirty], a
    ldh [rVBK], a
    ld hl, wHUDText
    ld de, _SCRN1
    ld b, HUD_COLS
.copy:
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .copy
    ret

; -----------------------------------------------------------------------------
; PushHUD: VBlank only (overworld). Copies the composed row when dirty — but
; not on a frame that already blits a world strip: BlitStream + OAM DMA fill
; the DMG VBlank budget, and the HUD can always land a frame late.
; (Call BEFORE BlitStream: it consumes wStrKind.)
; -----------------------------------------------------------------------------
PushHUD::
    ld a, [wHUDDirty]
    and a, a
    ret z
    ld a, [wStrKind]
    and a, a
    ret nz
    jr HUDCopyTiles

; -----------------------------------------------------------------------------
; UpdateSurvival: one overworld logic frame — advance the clock; on a minute
; tick apply the drains and recompose the row (the clock changed anyway).
; -----------------------------------------------------------------------------
UpdateSurvival::
    ld hl, wClockFrame
    inc [hl]
    ld a, [hl]
    cp CLOCK_MINUTE_FRAMES
    ret c
    xor a, a
    ld [hl], a
    ; --- one in-game minute ---
    ld hl, wClockMinCount
    inc [hl]
    ld a, [wClockM]
    inc a
    cp 60
    jr c, .storeMin
    ld a, [wClockH]
    inc a
    cp 24
    jr c, .storeHour
    xor a, a
.storeHour:
    ld [wClockH], a
    xor a, a
.storeMin:
    ld [wClockM], a
    ; --- drains: every FOOD/ENERGY_DRAIN_MINS minutes, saturating at 0 ---
    ld a, [wClockMinCount]
    and FOOD_DRAIN_MINS - 1
    jr nz, .noFood
    ld a, [wFood]
    and a, a
    jr z, .noFood
    dec a
    ld [wFood], a
.noFood:
    ld a, [wInCar]
    and a
    jr nz, .noEnergy           ; driving spares your energy — the car burns fuel
    ld a, [wClockMinCount]
    and ENERGY_DRAIN_MINS - 1
    jr nz, .noEnergy
    ld a, [wEnergy]
    and a, a
    jr z, .noEnergy
    dec a
    ld [wEnergy], a
.noEnergy:
    ; swimming is exhausting: bleed an extra energy point every in-game minute
    ; (~16x the base rate), saturating at 0.
    ld a, [wSwimming]
    and a, a
    jr z, .compose
    ld a, [wEnergy]
    and a, a
    jr z, .compose
    dec a
    ld [wEnergy], a
.compose:
    call ComposeHUD
    ld a, 1
    ld [wHUDDirty], a
    ret

; -----------------------------------------------------------------------------
; ComposeHUD: render the current state into wHUDText as font tile ids.
; Field layout (20 cells): sym+3 digits+space, x3, then HH:MM.
; -----------------------------------------------------------------------------
ComposeHUD::
    ld hl, wHUDText
    ld a, TILE_HUD_HP
    ld [hl+], a
    ld a, [wHP]
    call Put3
    ld a, FONT_BASE            ; space
    ld [hl+], a
    ld a, TILE_HUD_FOOD
    ld [hl+], a
    ld a, [wFood]
    call Put3
    ld a, FONT_BASE
    ld [hl+], a
    ; third meter: energy on foot, fuel while driving (identical 1+3-cell width)
    ld a, [wInCar]
    and a
    jr z, .energy
    ld a, TILE_HUD_FUEL
    ld [hl+], a
    ld a, [wFuel]
    jr .meter3
.energy:
    ld a, TILE_HUD_ENERGY
    ld [hl+], a
    ld a, [wEnergy]
.meter3:
    call Put3
    ld a, FONT_BASE
    ld [hl+], a
    ld a, [wClockH]
    call Put2
    ld a, TILE_HUD_COLON
    ld [hl+], a
    ld a, [wClockM]
    ; fall through

; Put2: A (0..59) -> two digit cells at HL, leading zero kept ("08").
Put2:
    ld c, 0
.tens:
    cp 10
    jr c, .done
    sub 10
    inc c
    jr .tens
.done:
    ld e, a
    ld a, c
    add a, TILE_DIGIT0
    ld [hl+], a
    ld a, e
    add a, TILE_DIGIT0
    ld [hl+], a
    ret

; Put3: A (0..255) -> three cells at HL, right-aligned, leading spaces
; ("100", " 87", "  5"). D tracks whether a digit has been emitted yet, so
; interior zeros print ("100") while leading ones pad.
Put3:
    ld e, a                    ; running remainder
    ld d, 0
    ld c, 0                    ; hundreds
    ld a, e
.h100:
    cp 100
    jr c, .h100d
    sub 100
    inc c
    jr .h100
.h100d:
    ld e, a
    ld a, c
    call .digitOrPad
    ld c, 0                    ; tens
    ld a, e
.h10:
    cp 10
    jr c, .h10d
    sub 10
    inc c
    jr .h10
.h10d:
    ld e, a
    ld a, c
    call .digitOrPad
    ld a, e                    ; ones always print
    add a, TILE_DIGIT0
    ld [hl+], a
    ret
.digitOrPad:
    and a, a
    jr nz, .dig                ; nonzero digit: print it
    ld a, d
    and a, a
    ld a, 0                    ; digit value 0 (keep flags from the D test)
    jr nz, .dig                ; already printing: interior zero
    ld a, FONT_BASE            ; still leading: pad with a space
    ld [hl+], a
    ret
.dig:
    add a, TILE_DIGIT0
    ld [hl+], a
    ld d, 1
    ret
