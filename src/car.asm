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
; right to a passable tile — the InitZombies/InitNPCs scheme), on foot, tank
; full. Call after InitPlayer/InitMap and the other spawns.
; -----------------------------------------------------------------------------
InitCar::
    xor a, a
    ld [wInCar], a
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
    ; nudge right to a passable tile (water is solid, so the car never parks in
    ; it — same bounded search as the other spawners)
    ld b, 8
.passable:
    call GenTileType
    call IsSolid
    jr z, .placeOk
    ld hl, wGenX
    call Inc16Ptr
    dec b
    jr nz, .passable
.placeOk:
    ld a, [wGenX]
    ld [wCarWX], a
    ld a, [wGenX+1]
    ld [wCarWX+1], a
    ld a, [wGenY]
    ld [wCarWY], a
    ld a, [wGenY+1]
    ld [wCarWY+1], a
    ld a, EFACE_DOWN
    ld [wCarFacing], a
    ld a, FUEL_START
    ld [wFuel], a
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

; TryEjectDir: A = EFACE_* candidate. If player+step(dir) is passable terrain and
; free of a zombie/NPC, arm the deferred player step-out that way (wCarEject =
; dir+1) and return Z; else NZ. (Water is solid here, so the car never ejects you
; into the drink even though you *can* swim on foot.)
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
; CheckCarAt: A = 1 if the PARKED car occupies (wGenX, wGenY), else 0. Returns 0
; while driving — the car rides with the player then, and GenEqualsPlayer already
; keeps zombies off the player tile. Scans only the car vars (never wEnt), so the
; player and zombie movement code can both call it safely.
; -----------------------------------------------------------------------------
CheckCarAt::
    ld a, [wInCar]
    and a
    jr nz, .free
    ld a, [wGenX]
    ld hl, wCarWX
    cp [hl]
    jr nz, .free
    ld a, [wGenX+1]
    ld hl, wCarWX+1
    cp [hl]
    jr nz, .free
    ld a, [wGenY]
    ld hl, wCarWY
    cp [hl]
    jr nz, .free
    ld a, [wGenY+1]
    ld hl, wCarWY+1
    cp [hl]
    jr nz, .free
    ld a, 1
    ret
.free:
    xor a, a
    ret

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

; DrawCar2x2: A = facing; wScrX/wScrY = the 8x8 anchor OAM position. Paint the
; four quadrant tiles into OAM_CAR..OAM_CAR+3, centred on the anchor (each
; quadrant offset +/-4 px). down/up are left-right symmetric (right column =
; X-flip of the stored left tile); side stores all four and X-flips the whole
; 16x16 for left. Quadrant order is TL, TR, BL, BR.
DrawCar2x2:
    call CarTATable               ; DE -> 4x(tile, attr) for this facing
    ld hl, wShadowOAM + OAM_CAR * 4
    ld b, 0                       ; quad index 0..3 (bit0 = right, bit1 = bottom)
.quad:
    ; --- Y = wScrY + (bottom ? +4 : -4) ---
    ld a, b
    and 2
    jr z, .yUp
    ld c, 4
    jr .yAdd
.yUp:
    ld c, -4
.yAdd:
    ld a, [wScrY]
    add a, c
    ld [hl+], a                   ; OAM Y
    ; --- X = wScrX + (right ? +4 : -4) ---
    ld a, b
    and 1
    jr z, .xLeft
    ld c, 4
    jr .xAdd
.xLeft:
    ld c, -4
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
