; =============================================================================
; car.asm — the drivable car.
;
; One car spawns near the player start. Walk up to it, face it and press A to
; board (CheckCarToggle); press A again to get out. While driving:
;   * the car sprite takes over the player's fixed screen cell (slot 0);
;   * movement runs at double speed (player.asm uses CAR_STEP_SPEED);
;   * each tile burns one unit of FUEL, which replaces the energy meter in the
;     HUD (hud.asm) — the player's energy does not drain in the car;
;   * an empty tank means the car can't move (the fuel gate in TryStartStep).
;
; The car is a single world object (wCarWX/WY + wCarFacing), not an entity-pool
; member: there is only ever one, and boarding just flips wInCar rather than
; moving anything, so no view/streaming edge is disturbed. It reuses the shared
; entity helpers (EntScreenPos, StepGen, CheckZombieAt/NPCAt) via wEnt/wGen.
;
; The car is a 16x16 (2x2-tile) sprite drawn across OAM slots OAM_CAR..OAM_CAR+3
; (see DrawCar / DrawCar2x2), centred on its tile. Getting out leaves the car
; parked where you stopped and steps the PLAYER out onto an adjacent tile (armed
; via wCarEject, walked next frame by UpdatePlayer — the normal, seam-free path).
; =============================================================================
INCLUDE "hardware.inc"
INCLUDE "include/constants.inc"

SECTION "Car Code", ROM0

; -----------------------------------------------------------------------------
; InitCar: place the one car near the player start (CAR_SPAWN_DX/DY, nudged
; right to a clear 2x2 block — the InitZombies/InitNPCs scheme, widened for the
; car's footprint), on foot, tank full. Call after InitPlayer/InitMap and the
; other spawns. wCarWX/WY is the top-left tile of the 2x2 footprint.
; -----------------------------------------------------------------------------
InitCar::
    xor a, a
    ld [wInCar], a
    ld [wCarEject], a
    ; wGenX = playerWX + CAR_SPAWN_DX
    ld a, [wPlayerWX]
    ld [wGenX], a
    ld a, [wPlayerWX+1]
    ld [wGenX+1], a
    ld a, CAR_SPAWN_DX
    ld hl, wGenX
    call AddSByteAt16
    ; wGenY = playerWY + CAR_SPAWN_DY
    ld a, [wPlayerWY]
    ld [wGenY], a
    ld a, [wPlayerWY+1]
    ld [wGenY+1], a
    ld a, CAR_SPAWN_DY
    ld hl, wGenY
    call AddSByteAt16
    ; nudge right until the whole 2x2 footprint is passable (water is solid, so
    ; the car never parks in it — same bounded search as the other spawners).
    ; The candidate anchor is stashed in wCarWX/WY (also the final destination),
    ; since Is2x2Clear clobbers wGen and GenTileType clobbers every other scratch.
    ld b, 8
.place:
    ld a, [wGenX]
    ld [wCarWX], a
    ld a, [wGenX+1]
    ld [wCarWX+1], a
    ld a, [wGenY]
    ld [wCarWY], a
    ld a, [wGenY+1]
    ld [wCarWY+1], a
    call Is2x2Clear
    jr z, .placeOk
    ; restore the anchor, step one tile right, retry
    ld a, [wCarWX]
    ld [wGenX], a
    ld a, [wCarWX+1]
    ld [wGenX+1], a
    ld a, [wCarWY]
    ld [wGenY], a
    ld a, [wCarWY+1]
    ld [wGenY+1], a
    ld hl, wGenX
    call Inc16Ptr
    dec b
    jr nz, .place
.placeOk:
    ld a, EFACE_DOWN
    ld [wCarFacing], a
    ld a, FUEL_START
    ld [wFuel], a
    ret

; -----------------------------------------------------------------------------
; Is2x2Clear: Z if the 2x2 block whose top-left is (wGenX, wGenY) is all
; passable terrain (no solid tile — water counts as solid), NZ otherwise.
; Walks the four tiles by stepping wGen; on return wGen is back at the top-left.
; -----------------------------------------------------------------------------
Is2x2Clear::
    call GenTileType
    call IsSolid
    jr nz, .no0                 ; (0,0) solid — wGen already at anchor
    ld hl, wGenX
    call Inc16Ptr               ; -> (1,0)
    call GenTileType
    call IsSolid
    jr nz, .no1
    ld hl, wGenY
    call Inc16Ptr               ; -> (1,1)
    call GenTileType
    call IsSolid
    jr nz, .no2
    ld hl, wGenX
    call Dec16Ptr               ; -> (0,1)
    call GenTileType
    call IsSolid
    jr nz, .no3
    ld hl, wGenY
    call Dec16Ptr               ; -> (0,0): all clear
    xor a, a                    ; Z
    ret
.no3:                           ; wGen at (0,1) -> restore Y
    ld hl, wGenY
    call Dec16Ptr
    jr .no
.no2:                           ; wGen at (1,1) -> restore X and Y
    ld hl, wGenX
    call Dec16Ptr
    ld hl, wGenY
    call Dec16Ptr
    jr .no
.no1:                           ; wGen at (1,0) -> restore X
    ld hl, wGenX
    call Dec16Ptr
.no0:
.no:
    or a, 1                     ; NZ
    ret

; -----------------------------------------------------------------------------
; CheckCarToggle: overworld only. On an A press, board the car (if on foot and
; facing it) or get out (if driving). Consumes the A press on either action so
; CheckTalkStart doesn't also fire the same frame. Boarding leaves the player's
; logical tile untouched — the car simply becomes the driven sprite — so nothing
; scrolls or needs re-streaming.
; -----------------------------------------------------------------------------
CheckCarToggle::
    ld a, [wNewKeys]
    and PAD_A
    ret z
    ld a, [wInCar]
    and a
    jr nz, .exit
    ; --- on foot: board only if the tile we face holds the parked car ---
    ld a, [wPlayerWX]
    ld [wGenX], a
    ld a, [wPlayerWX+1]
    ld [wGenX+1], a
    ld a, [wPlayerWY]
    ld [wGenY], a
    ld a, [wPlayerWY+1]
    ld [wGenY+1], a
    ld a, [wFacing]
    call StepGen               ; wGen = tile in front of the player
    call CheckCarAt
    and a
    ret z                      ; not facing the car -> leave A for the talk check
    ld a, 1
    ld [wInCar], a
    xor a, a
    ld [wSwimming], a          ; you can't be swimming from the driver's seat
    ld [wSplashTimer], a
    ld [wCarEject], a          ; drop any stale get-out step
    jr .consumeA
.exit:
    call ExitCar               ; park where you stopped + eject the player
    ; fall through
.consumeA:
    call ComposeHUD            ; swap the energy/fuel readout in immediately
    ld a, 1
    ld [wHUDDirty], a
    ld a, [wNewKeys]
    res 4, a                   ; clear PAD_A (bit 4) so CheckTalkStart sees no press
    ld [wNewKeys], a
    ret

; -----------------------------------------------------------------------------
; ExitCar: leave the car. It stays parked exactly where you stopped
; (wCarWX/WY = the player's current tile) and the PLAYER steps out onto an
; adjacent passable, unoccupied tile (facing direction first, then a fixed
; sweep). The step is *armed* via wCarEject and walked next idle frame by
; UpdatePlayer, so it rides the normal walk + streaming path (no view seam). If
; hemmed in on all sides, the player stays on the car tile (re-board to leave).
; -----------------------------------------------------------------------------
ExitCar:
    xor a, a
    ld [wInCar], a
    ; the car keeps the tile the player just vacated
    ld a, [wPlayerWX]
    ld [wCarWX], a
    ld a, [wPlayerWX+1]
    ld [wCarWX+1], a
    ld a, [wPlayerWY]
    ld [wCarWY], a
    ld a, [wPlayerWY+1]
    ld [wCarWY+1], a
    ld a, [wFacing]
    ld [wCarFacing], a
    ; pick an ejection direction for the player: face dir first, then a sweep
    ld a, [wFacing]
    call TryEjectDir
    ret z
    ld a, EFACE_DOWN
    call TryEjectDir
    ret z
    ld a, EFACE_UP
    call TryEjectDir
    ret z
    ld a, EFACE_LEFT
    call TryEjectDir
    ret z
    ld a, EFACE_RIGHT
    call TryEjectDir
    ret z
    ; boxed in: no eject armed; the player stays on the parked car tile
    ret

; TryEjectDir: A = EFACE_* candidate. If player+step(dir) lands on a passable,
; unoccupied tile that is OUTSIDE the parked 2x2 footprint, arm the deferred
; player step-out that way (wCarEject = dir+1) and return Z; else NZ. Because the
; player sits at the footprint's top-left, a single step right or down still
; lands on the car (CheckCarAt rejects it) — so you climb out to the left/up/
; a clear perimeter tile. (Water is solid here, so you never eject into it.)
TryEjectDir:
    push af
    ld a, [wPlayerWX]
    ld [wGenX], a
    ld a, [wPlayerWX+1]
    ld [wGenX+1], a
    ld a, [wPlayerWY]
    ld [wGenY], a
    ld a, [wPlayerWY+1]
    ld [wGenY+1], a
    pop af
    push af
    call StepGen               ; wGen = tile one step in that direction
    call GenTileType
    call IsSolid
    jr nz, .no                 ; wall/tree/water -> not an exit tile
    call CheckZombieAt
    and a
    jr nz, .no
    call CheckNPCAt
    and a
    jr nz, .no
    call CheckCarAt            ; still on the parked 2x2 (right/down of anchor)?
    and a
    jr nz, .no
    pop af                     ; A = the accepted direction
    inc a                      ; store dir+1 (0 = "no eject")
    ld [wCarEject], a
    xor a, a                   ; Z = armed
    ret
.no:
    pop af
    or a, 1                    ; NZ = no good
    ret

; -----------------------------------------------------------------------------
; CheckCarAt: A = 1 if (wGenX, wGenY) is inside the car's 2x2 footprint, else 0.
; The footprint's top-left anchor is wCarWX/WY when parked, or the player's tile
; while driving (the car rides at the player), so zombies avoid all four tiles in
; either case and the on-foot player can't walk onto the parked car. Scans only
; the car/player vars (never wEnt), so player and zombie code both call it safely.
; The driving footprint is the car's OWN body, so the driver's movement checks
; the leading edge via CheckDriveEdge instead of this (it never blocks itself).
; -----------------------------------------------------------------------------
CheckCarAt::
    ld a, [wInCar]
    and a
    jr nz, .driving
    ; parked: anchor = wCarWX/WY
    ld hl, wGenX
    ld de, wCarWX
    call InSpan2
    jr nz, .free
    ld hl, wGenY
    ld de, wCarWY
    call InSpan2
    jr nz, .free
    jr .hit
.driving:
    ; driving: anchor = the player's tile
    ld hl, wGenX
    ld de, wPlayerWX
    call InSpan2
    jr nz, .free
    ld hl, wGenY
    ld de, wPlayerWY
    call InSpan2
    jr nz, .free
.hit:
    ld a, 1
    ret
.free:
    xor a, a
    ret

; -----------------------------------------------------------------------------
; InSpan2: HL -> a 16-bit LE value, DE -> a 16-bit LE anchor. Returns Z if the
; value is in {anchor, anchor+1} (one axis of the 2x2 footprint), NZ otherwise.
; Clobbers A, BC; advances HL and DE.
; -----------------------------------------------------------------------------
InSpan2:
    ld a, [de]
    ld c, a
    inc de
    ld a, [de]
    ld b, a                     ; BC = anchor
    ld a, [hl+]
    sub c                       ; A = value_lo - anchor_lo
    ld c, a                     ; C = diff low
    ld a, [hl]
    sbc b                       ; A = diff high (with borrow)
    or a
    jr nz, .no                  ; high difference nonzero -> out of span
    ld a, c
    cp 2                        ; low difference in {0,1} ?
    jr nc, .no
    xor a, a                    ; Z = in span
    ret
.no:
    or a, 1                     ; NZ = out of span
    ret

; -----------------------------------------------------------------------------
; GenPlayerStep: wGen = the player's tile stepped one in wStepDir. The driving
; car's footprint anchor is the player tile, so this is also the car's new
; top-left after the step commits.
; -----------------------------------------------------------------------------
GenPlayerStep::
    ld a, [wPlayerWX]
    ld [wGenX], a
    ld a, [wPlayerWX+1]
    ld [wGenX+1], a
    ld a, [wPlayerWY]
    ld [wGenY], a
    ld a, [wPlayerWY+1]
    ld [wGenY+1], a
    ld a, [wStepDir]
    jp StepGen                  ; tail call

; -----------------------------------------------------------------------------
; CheckDriveEdge: the car is a 2x2 anchored at the player's top-left tile. When
; driving one tile in wStepDir, the two tiles the footprint newly covers (its
; leading edge) must be clear. Returns Z if both are passable terrain (water is
; solid — a car can't float) and free of a zombie/NPC; NZ if either blocks. It
; never consults CheckCarAt (the car can't block its own body). Clobbers wGen.
;
; With the player at the top-left, the leading edge for each direction is:
;   RIGHT (px+2,py),(px+2,py+1)   LEFT (px-1,py),(px-1,py+1)
;   DOWN  (px,py+2),(px+1,py+2)   UP   (px,py-1),(px+1,py-1)
; so right/down step twice from the player (past the far side of the footprint)
; and the second tile offsets one along the perpendicular axis.
; -----------------------------------------------------------------------------
CheckDriveEdge::
    ; wGen = player + one step in wStepDir
    ld a, [wPlayerWX]
    ld [wGenX], a
    ld a, [wPlayerWX+1]
    ld [wGenX+1], a
    ld a, [wPlayerWY]
    ld [wGenY], a
    ld a, [wPlayerWY+1]
    ld [wGenY+1], a
    ld a, [wStepDir]
    call StepGen
    ; right/down need a second step to clear the far side of the 2x2
    ld a, [wStepDir]
    cp EFACE_RIGHT
    jr z, .second
    cp EFACE_DOWN
    jr z, .second
    jr .tile1
.second:
    ld a, [wStepDir]
    call StepGen
.tile1:
    call .checkGen
    ret nz
    ; tile2 = tile1 offset one along the perpendicular axis
    ld a, [wStepDir]
    cp EFACE_LEFT
    jr z, .perpY
    cp EFACE_RIGHT
    jr z, .perpY
    ld hl, wGenX                ; vertical travel -> perpendicular is X
    jr .perpInc
.perpY:
    ld hl, wGenY               ; horizontal travel -> perpendicular is Y
.perpInc:
    call Inc16Ptr
    ; fall through to check tile2
.checkGen:
    call GenTileType
    call IsSolid
    ret nz                      ; solid/water -> blocked
    call CheckZombieAt
    and a
    ret nz                      ; a zombie stands there -> blocked
    call CheckNPCAt
    and a
    ret                         ; Z = clear, NZ = an NPC blocks

; =============================================================================
; Rendering — the car is a 16x16 (2x2) sprite in slots OAM_CAR..OAM_CAR+3.
; =============================================================================
; DrawCar: draw the one car. Driving -> it takes the player's fixed screen cell
; (the on-foot player slot 0 is hidden in DrawEntities); parked and on-screen ->
; at its world position (culled like the other sprites via EntScreenPos); parked
; and off-screen -> hide all four slots. One call handles every case.
DrawCar::
    ld a, [wInCar]
    and a
    jr nz, .driving
    ; --- parked: world sprite, reuse EntScreenPos for culling + camera lag ---
    call ClearEnt
    ld a, [wCarWX]
    ld [wEnt + EO_WXLO], a
    ld a, [wCarWX+1]
    ld [wEnt + EO_WXHI], a
    ld a, [wCarWY]
    ld [wEnt + EO_WYLO], a
    ld a, [wCarWY+1]
    ld [wEnt + EO_WYHI], a
    call EntScreenPos             ; -> A=visible, wScrX/wScrY = 8x8 anchor
    and a
    jr z, .hide
    ld a, [wCarFacing]
    jr DrawCar2x2
.driving:
    ld a, SPR_X
    ld [wScrX], a
    ld a, SPR_Y
    ld [wScrY], a
    ld a, [wFacing]
    jr DrawCar2x2
.hide:
    xor a, a
    ld [wShadowOAM + (OAM_CAR + 0) * 4], a   ; Y = 0 -> off-screen
    ld [wShadowOAM + (OAM_CAR + 1) * 4], a
    ld [wShadowOAM + (OAM_CAR + 2) * 4], a
    ld [wShadowOAM + (OAM_CAR + 3) * 4], a
    ret

; DrawCar2x2: A = facing; wScrX/wScrY = the OAM position of the footprint's
; top-left tile. Paint the four quadrant tiles into OAM_CAR..OAM_CAR+3 aligned to
; the 2x2 world tiles (TL at the anchor, the others +8 px right/down), so the
; sprite sits exactly on the tiles it collides with. down/up are left-right
; symmetric (right column = X-flip of the stored left tile); side stores all four
; and X-flips the whole 16x16 for left. Quadrant order is TL, TR, BL, BR.
DrawCar2x2:
    call CarTATable               ; DE -> 4x(tile, attr) for this facing
    ld hl, wShadowOAM + OAM_CAR * 4
    ld b, 0                       ; quad index 0..3 (bit0 = right, bit1 = bottom)
.quad:
    ; --- Y = wScrY + (bottom ? 8 : 0) ---
    ld a, b
    and 2
    jr z, .yTop
    ld c, 8
    jr .yAdd
.yTop:
    ld c, 0
.yAdd:
    ld a, [wScrY]
    add a, c
    ld [hl+], a                   ; OAM Y
    ; --- X = wScrX + (right ? 8 : 0) ---
    ld a, b
    and 1
    jr z, .xLeft
    ld c, 8
    jr .xAdd
.xLeft:
    ld c, 0
.xAdd:
    ld a, [wScrX]
    add a, c
    ld [hl+], a                   ; OAM X
    ld a, [de]                    ; tile
    inc de
    ld [hl+], a
    ld a, [de]                    ; attr (OBJ pal 0, +/-X-flip)
    inc de
    ld [hl+], a
    inc b
    ld a, b
    cp 4
    jr nz, .quad
    ret

; CarTATable: A = facing -> DE = 4-entry (tile, attr) descriptor (TL, TR, BL, BR).
CarTATable:
    cp EFACE_UP
    jr z, .up
    cp EFACE_LEFT
    jr z, .left
    cp EFACE_RIGHT
    jr z, .right
    ld de, CarDownTA
    ret
.up:
    ld de, CarUpTA
    ret
.left:
    ld de, CarLeftTA
    ret
.right:
    ld de, CarRightTA
    ret

; down / up: symmetric, so TR/BR are the left tile with OAMF_XFLIP.
CarDownTA:
    db TILE_CAR_DOWN_T, 0
    db TILE_CAR_DOWN_T, OAMF_XFLIP
    db TILE_CAR_DOWN_B, 0
    db TILE_CAR_DOWN_B, OAMF_XFLIP
CarUpTA:
    db TILE_CAR_UP_T, 0
    db TILE_CAR_UP_T, OAMF_XFLIP
    db TILE_CAR_UP_B, 0
    db TILE_CAR_UP_B, OAMF_XFLIP
; side (right profile): four distinct quadrants, no flip.
CarRightTA:
    db TILE_CAR_SIDE_TL, 0
    db TILE_CAR_SIDE_TR, 0
    db TILE_CAR_SIDE_BL, 0
    db TILE_CAR_SIDE_BR, 0
; side facing left: X-flip the whole 16x16 — swap columns and mirror each tile.
CarLeftTA:
    db TILE_CAR_SIDE_TR, OAMF_XFLIP
    db TILE_CAR_SIDE_TL, OAMF_XFLIP
    db TILE_CAR_SIDE_BR, OAMF_XFLIP
    db TILE_CAR_SIDE_BL, OAMF_XFLIP
