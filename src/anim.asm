; =============================================================================
; anim.asm — ambient + reactive world animation (the "living world" layer).
;
; Everything here works by SWAPPING THE ART of a shared background tile in VRAM
; ($8000 + id*16) — never by touching the tile MAP ($9800) or adding OBJ sprites.
; That keeps it invisible to the streaming model (map cell ids are unchanged) and
; to the boot-hygiene poison tests (no map cell > 13, no OAM slot 33+ appears),
; and it costs no OAM budget. Because the art is shared, an effect animates every
; on-screen instance of that tile at once — a bumped tree reads as "a gust through
; the foliage", which is exactly the feel we want, and doors/brush are sparse
; enough that the shared-art caveat never shows.
;
; None of this consumes the dynamic RNG (Rand), so spawn/loot/talk determinism —
; and the whole integration suite — is unperturbed.
;
;   * Water shimmer : ambient, always cycling (a slow 3-frame ripple on TILE_WATER)
;   * Tree sway     : TILE_TREE_TL/TR wobble on a bump / A-press, and a periodic
;                     ambient breeze so foliage stirs even when you stand still
;   * Brush rustle  : TILE_BRUSH ripples for a moment as you walk through it
;   * Doors         : TILE_DOOR swaps to an open leaf while you're on the threshold
;                     (with a short linger so it visibly shuts behind you), reusing
;                     the car door "thunk" (PlayCarDoor) on each open/close
;
; UpdateAnim (logic phase) advances the timers and picks each group's current
; frame; PushAnim (VBlank) copies only the frames that changed into VRAM.
; =============================================================================
INCLUDE "hardware.inc"
INCLUDE "include/constants.inc"

; ROM0 is full, so this module lives in ROMX bank 1 — the DEFAULT-MAPPED bank
; (see the banking invariant in CLAUDE.md). It is mapped in every context these
; routines run: overworld logic (UpdateSound restores bank 1 before returning)
; and the overworld VBlank (nothing there switches banks). So ROM0 callers
; (main.asm / player.asm) reach it directly and it reaches ROM0 helpers
; (GenTileType / StepGen / PlayCarDoor) directly — exactly like dialogue.asm.
SECTION "Anim Code", ROMX, BANK[1]

; -----------------------------------------------------------------------------
; InitAnim: arm the free-running dividers; the rest is already 0 from ClearRAM.
; Frame == shown == 0 for every group, and the base art loaded by LoadTiles IS
; each group's frame 0, so no initial push is needed.
; -----------------------------------------------------------------------------
InitAnim::
    xor a, a
    ld [wAnimTick], a
    ld [wWaterFrame], a
    ld [wWaterShown], a
    ld [wTreeTimer], a
    ld [wTreeFrame], a
    ld [wTreeShown], a
    ld [wBrushTimer], a
    ld [wBrushFrame], a
    ld [wBrushShown], a
    ld [wOnDoor], a
    ld [wDoorLinger], a
    ld [wDoorFrame], a
    ld [wDoorShown], a
    ld a, WATER_ANIM_FRAMES
    ld [wWaterDiv], a
    ld a, BREEZE_PERIOD
    ld [wBreezeTimer], a
    ret

; -----------------------------------------------------------------------------
; Triggers (called from player.asm / main.asm). All just poke a WRAM timer.
; -----------------------------------------------------------------------------
; MaybeTreeBump: if wDestTile is a tree quadrant (10..13), start a sway.
MaybeTreeBump::
    ld a, [wDestTile]
    cp TILE_TREE_TL
    ret c                       ; < 10 -> not a tree
    cp TILE_TREE_BR + 1
    ret nc                      ; > 13 -> not a tree
    ; fall through
TriggerTreeSway::
    ld a, [wTreeTimer]
    and a, a
    ret nz                      ; already swaying -> let it play out, don't restack
                                ; (else holding INTO a tree would re-arm every frame
                                ; and freeze the canopy on sub-frame 0 = rest). When
                                ; it finishes, the next held bump starts a fresh
                                ; sway -> a continuous wobble while you push in.
    ld a, TREE_SWAY_DUR
    ld [wTreeTimer], a
    ret

TriggerBrushRustle::
    ld a, [wBrushTimer]
    and a, a
    ret nz                      ; same: don't re-arm mid-rustle (walking through a
                                ; brush run would otherwise freeze it on sub-frame 0)
    ld a, BRUSH_RUSTLE_DUR
    ld [wBrushTimer], a
    ret

; CheckTreeTouch: overworld helper — on a fresh A press, if the tile the player
; faces is a tree, sway it. (Bumping into one is handled in player.asm's step;
; this is the deliberate "press A at a tree" case.) The A press is left intact:
; a faced tree can't also be an NPC/car/loot, so nothing else contends for it.
CheckTreeTouch::
    ld a, [wInCar]
    and a, a
    ret nz
    ld a, [wNewKeys]
    and PAD_A
    ret z
    ld a, [wPlayerWX]
    ld [wGenX], a
    ld a, [wPlayerWX+1]
    ld [wGenX+1], a
    ld a, [wPlayerWY]
    ld [wGenY], a
    ld a, [wPlayerWY+1]
    ld [wGenY+1], a
    ld a, [wFacing]
    call StepGen                ; wGen = the faced tile
    call GenTileType
    cp TILE_TREE_TL
    ret c
    cp TILE_TREE_BR + 1
    ret nc
    jr TriggerTreeSway

; -----------------------------------------------------------------------------
; UpdateAnim: advance every group's timer and compute its current frame index.
; -----------------------------------------------------------------------------
UpdateAnim::
    ld hl, wAnimTick
    inc [hl]

    ; --- water shimmer: bump the 3-frame ripple every WATER_ANIM_FRAMES ---
    ld hl, wWaterDiv
    dec [hl]
    jr nz, .water_done
    ld a, WATER_ANIM_FRAMES
    ld [wWaterDiv], a
    ld a, [wWaterFrame]
    inc a
    cp 3
    jr c, .water_store
    xor a, a
.water_store:
    ld [wWaterFrame], a
.water_done:

    ; --- ambient breeze: kick a gentle sway on a slow timer ---
    ld hl, wBreezeTimer
    dec [hl]
    jr nz, .breeze_done
    ld a, BREEZE_PERIOD
    ld [wBreezeTimer], a
    ld a, [wTreeTimer]
    and a, a
    jr nz, .breeze_done         ; already swaying -> don't restack
    ld a, TREE_SWAY_DUR
    ld [wTreeTimer], a
.breeze_done:

    ; --- tree sway frame: index = (timer >> LOG) into TreeSwayPattern, rest at 0 ---
    ld a, [wTreeTimer]
    and a, a
    jr z, .tree_rest
    dec a
    ld [wTreeTimer], a
    and a, a
    jr z, .tree_rest
    REPT TREE_SWAY_LOG
    srl a                       ; / (1 << TREE_SWAY_LOG) -> index (0..TREE_PAT_LEN-1)
    ENDR
    cp TREE_PAT_LEN
    jr c, .tree_idx
    ld a, TREE_PAT_LEN - 1
.tree_idx:
    ld e, a
    ld d, 0
    ld hl, TreeSwayPattern
    add hl, de
    ld a, [hl]
    ld [wTreeFrame], a
    jr .brush
.tree_rest:
    xor a, a
    ld [wTreeFrame], a
.brush:

    ; --- brush rustle frame: same scheme on BrushRustlePattern ---
    ld a, [wBrushTimer]
    and a, a
    jr z, .brush_rest
    dec a
    ld [wBrushTimer], a
    and a, a
    jr z, .brush_rest
    REPT BRUSH_RUSTLE_LOG
    srl a                       ; / (1 << BRUSH_RUSTLE_LOG) -> pattern index
    ENDR
    cp BRUSH_PAT_LEN
    jr c, .brush_idx
    ld a, BRUSH_PAT_LEN - 1
.brush_idx:
    ld e, a
    ld d, 0
    ld hl, BrushRustlePattern
    add hl, de
    ld a, [hl]
    ld [wBrushFrame], a
    jr .door
.brush_rest:
    xor a, a
    ld [wBrushFrame], a
.door:
    ; fall through to UpdateDoor

; -----------------------------------------------------------------------------
; UpdateDoor: open the door tile while the player is on a doorway (wOnDoor), keep
; it open through a short linger after they step off, then shut it. Each open<->
; shut transition thunks the car door SFX (reused, as requested).
; -----------------------------------------------------------------------------
UpdateDoor:
    ld a, [wOnDoor]
    and a, a
    jr z, .off
    ld a, DOOR_LINGER
    ld [wDoorLinger], a         ; on the threshold -> hold it open
    ld a, 1
    jr .apply
.off:
    ld a, [wDoorLinger]
    and a, a
    jr z, .want_closed
    dec a
    ld [wDoorLinger], a
    ld a, 1                     ; still swinging shut -> stay open
    jr .apply
.want_closed:
    xor a, a
.apply:
    ld b, a
    ld a, [wDoorFrame]
    cp b
    ret z                       ; no state change
    ld a, b
    ld [wDoorFrame], a
    jp PlayCarDoor              ; open or shut -> the door thunk (tail call)

; -----------------------------------------------------------------------------
; PushAnim (VBlank): for each group whose frame changed since last push, copy its
; 16-byte tile art into VRAM. Runs after BlitStream (bank 0 already selected).
; -----------------------------------------------------------------------------
PushAnim::
    ld a, [wWaterFrame]
    ld hl, wWaterShown
    cp [hl]
    jr z, .brush
    ld [hl], a
    ld c, TILE_WATER
    ld hl, WaterFrames
    call LoadAndPush
.brush:
    ld a, [wBrushFrame]
    ld hl, wBrushShown
    cp [hl]
    jr z, .tree
    ld [hl], a
    ld c, TILE_BRUSH
    ld hl, BrushFrames
    call LoadAndPush
.tree:
    ld a, [wTreeFrame]
    ld hl, wTreeShown
    cp [hl]
    jr z, .door
    ld [hl], a
    ld c, TILE_TREE_TL
    ld hl, TreeTLFrames
    call LoadAndPush
    ld a, [wTreeShown]
    ld c, TILE_TREE_TR
    ld hl, TreeTRFrames
    call LoadAndPush
.door:
    ld a, [wDoorFrame]
    ld hl, wDoorShown
    cp [hl]
    ret z
    ld [hl], a
    ld c, TILE_DOOR
    ld hl, DoorFrames
    ; fall through to LoadAndPush (tail)

; LoadAndPush: A = frame index, HL = frame pointer table (dw ptrs), C = tile id.
; Resolves the frame's art pointer and copies it to VRAM tile C.
LoadAndPush:
    add a, a                    ; index * 2 (dw table)
    ld e, a
    ld d, 0
    add hl, de
    ld a, [hl+]
    ld h, [hl]
    ld l, a                     ; HL = frame art (16 bytes)
    ld a, c                     ; A = tile id
    ; fall through to PushTileArt

; PushTileArt: A = tile id (0..15), HL = 16-byte art -> copy to $8000 + id*16.
PushTileArt:
    ld c, a
    swap c                      ; c = id * 16 (valid for id < 16)
    ld e, c
    ld d, $80                   ; DE = $8000 + id*16 (id*16 < 256 -> one page)
    ld b, 16
.copy:
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .copy
    ret

; -----------------------------------------------------------------------------
; Frame index patterns (indexed by timer >> 2 as the sway/rustle counts down, so
; the last entry plays first). Values are frame ids into the *Frames tables.
; -----------------------------------------------------------------------------
TreeSwayPattern:    db 0, 1, 2, 1, 2, 0     ; TREE_PAT_LEN entries
BrushRustlePattern: db 0, 1, 2, 1, 2        ; BRUSH_PAT_LEN entries

; Per-group frame pointer tables (frame 0 mirrors the base art in gfx.asm).
WaterFrames:  dw WaterF0, WaterF1, WaterF2
BrushFrames:  dw BrushF0, BrushF1, BrushF2
TreeTLFrames: dw TreeTL0, TreeTL1, TreeTL2
TreeTRFrames: dw TreeTR0, TreeTR1, TreeTR2
DoorFrames:   dw DoorClosed, DoorOpen

; =============================================================================
; Tile art (2bpp; each digit = a colour index 0..3 for one pixel, per gfx.asm).
; Frame 0 of each animated group is byte-identical to its tile in gfx.asm's Tiles
; table so the resting look never shifts.
; =============================================================================
; --- water (TILE_WATER, BG pal 1): drifting ripple sparkles ---
WaterF0:
    dw `00000000
    dw `10001000
    dw `00000001
    dw `00100010
    dw `00000000
    dw `01000100
    dw `00010000
    dw `00000000
WaterF1:
    dw `00000000
    dw `00100010
    dw `10000000
    dw `00001000
    dw `10000000
    dw `00010001
    dw `00000100
    dw `00000000
WaterF2:
    dw `00000000
    dw `00010001
    dw `01000000
    dw `00000100
    dw `01000000
    dw `00100010
    dw `00000010
    dw `00000000

; --- brush / long grass (TILE_BRUSH, BG pal 0): blades bending L/R ---
BrushF0:
    dw `01000100
    dw `10101010
    dw `01000100
    dw `00010001
    dw `01000100
    dw `10101010
    dw `00010001
    dw `01000100
BrushF1:
    dw `00100010
    dw `01010101
    dw `00100010
    dw `00001000
    dw `00100010
    dw `01010101
    dw `00001000
    dw `00100010
BrushF2:
    dw `10001000
    dw `01010100
    dw `10001000
    dw `00100010
    dw `10001000
    dw `01010100
    dw `00100010
    dw `10001000

; --- tree canopy: TILE_TREE_TL | TILE_TREE_TR are two halves of ONE 16x8 image,
; so each sway frame must be the base shifted as a single 16-wide unit — the pixel
; leaving one tile's edge has to ENTER the other's, or a 1px gap opens at the seam
; while swaying. F1 = whole canopy 1px right, F2 = 1px left (test_anim guards this).
TreeTL0:
    dw `00000333
    dw `00033311
    dw `00331111
    dw `00311011
    dw `03311101
    dw `03110110
    dw `03111101
    dw `03111111
TreeTL1:
    dw `00000033
    dw `00003331
    dw `00033111
    dw `00031101
    dw `00331110
    dw `00311011
    dw `00311110
    dw `00311111
TreeTL2:
    dw `00003333
    dw `00333111
    dw `03311111
    dw `03110111
    dw `33111011
    dw `31101101
    dw `31111011
    dw `31111111

; --- tree canopy top-right (TILE_TREE_TR, BG pal 0) ---
TreeTR0:
    dw `33300000
    dw `11333000
    dw `11113300
    dw `11111300
    dw `11111330
    dw `11111130
    dw `11111130
    dw `11111130
TreeTR1:
    dw `33330000
    dw `11133300
    dw `11111330
    dw `11111130
    dw `11111133
    dw `01111113
    dw `11111113
    dw `11111113
TreeTR2:
    dw `33000000
    dw `13330000
    dw `11133000
    dw `11113000
    dw `11113300
    dw `11111300
    dw `11111300
    dw `11111300

; --- door (TILE_DOOR, BG pal 2): closed leaf vs swung-open doorway ---
DoorClosed:
    dw `33333333
    dw `32222223
    dw `32222223
    dw `32222223
    dw `32222223
    dw `32222223
    dw `32222223
    dw `33333333
DoorOpen:
    dw `33333333
    dw `33000023
    dw `33000023
    dw `33000023
    dw `33000023
    dw `33000023
    dw `33000023
    dw `33333333
