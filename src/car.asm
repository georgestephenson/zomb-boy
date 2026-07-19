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
    jr .consumeA
.exit:
    call ExitCar               ; park adjacent + clear wInCar
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
; ExitCar: leave the car. Park it on an adjacent passable, unoccupied tile
; (facing direction first, then a fixed sweep) so it ends up right next to where
; you stopped; if hemmed in on all sides, park on the player's own tile. The
; player stays put (no scroll). Sets wCarFacing to the travel direction.
; -----------------------------------------------------------------------------
ExitCar:
    xor a, a
    ld [wInCar], a
    ld a, [wFacing]
    ld [wCarFacing], a
    ld a, [wFacing]
    call TryParkDir
    ret z
    ld a, EFACE_DOWN
    call TryParkDir
    ret z
    ld a, EFACE_UP
    call TryParkDir
    ret z
    ld a, EFACE_LEFT
    call TryParkDir
    ret z
    ld a, EFACE_RIGHT
    call TryParkDir
    ret z
    ; boxed in: park under the player (you can just drive off again)
    ld a, [wPlayerWX]
    ld [wCarWX], a
    ld a, [wPlayerWX+1]
    ld [wCarWX+1], a
    ld a, [wPlayerWY]
    ld [wCarWY], a
    ld a, [wPlayerWY+1]
    ld [wCarWY+1], a
    ret

; TryParkDir: A = EFACE_* candidate. If player+step(dir) is passable terrain and
; free of a zombie/NPC, store it as the car position and return Z; else NZ.
TryParkDir:
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
    call StepGen
    call GenTileType
    call IsSolid
    jr nz, .no                 ; wall/tree/water -> not a parking spot
    call CheckZombieAt
    and a
    jr nz, .no
    call CheckNPCAt
    and a
    jr nz, .no
    ld a, [wGenX]
    ld [wCarWX], a
    ld a, [wGenX+1]
    ld [wCarWX+1], a
    ld a, [wGenY]
    ld [wCarWY], a
    ld a, [wGenY+1]
    ld [wCarWY+1], a
    xor a, a                   ; Z = parked
    ret
.no:
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
; Rendering
; =============================================================================
; DrawCarDriving: the car takes the player's fixed screen cell (slot 0) while
; driving, facing the way the player faces.
DrawCarDriving::
    ld hl, wShadowOAM              ; slot 0 (OAM_PLAYER)
    ld a, SPR_Y
    ld [hl+], a
    ld a, SPR_X
    ld [hl+], a
    ld a, [wFacing]
    call CarTileAttr              ; -> B=tile, C=attr
    ld a, b
    ld [hl+], a
    ld a, c
    ld [hl], a
    ret

; DrawParkedCar: draw the parked car (OAM_CAR slot) when on foot and on-screen;
; otherwise hide it. Reuses EntScreenPos via wEnt for identical culling, camera
; lag and HUD-band clipping to the other world sprites.
DrawParkedCar::
    ld a, [wInCar]
    and a
    jr nz, .hide                  ; driving -> the car is at slot 0, not here
    call ClearEnt
    ld a, [wCarWX]
    ld [wEnt + EO_WXLO], a
    ld a, [wCarWX+1]
    ld [wEnt + EO_WXHI], a
    ld a, [wCarWY]
    ld [wEnt + EO_WYLO], a
    ld a, [wCarWY+1]
    ld [wEnt + EO_WYHI], a
    call EntScreenPos             ; -> A=visible, wScrX/wScrY
    and a
    jr z, .hide
    ld hl, wShadowOAM + OAM_CAR * 4
    ld a, [wScrY]
    ld [hl+], a
    ld a, [wScrX]
    ld [hl+], a
    ld a, [wCarFacing]
    call CarTileAttr             ; -> B=tile, C=attr
    ld a, b
    ld [hl+], a
    ld a, c
    ld [hl], a
    ret
.hide:
    xor a, a
    ld [wShadowOAM + OAM_CAR * 4], a   ; Y = 0 -> off-screen
    ret

; CarTileAttr: A = facing -> B = tile id, C = OAM attr (OBJ palette 0; X-flip for
; left). down = base+0, up = base+1, side = base+2 (mirror for left).
CarTileAttr:
    cp EFACE_UP
    jr z, .up
    cp EFACE_LEFT
    jr z, .left
    cp EFACE_RIGHT
    jr z, .right
    ld b, TILE_CAR_BASE + 0       ; down
    ld c, 0
    ret
.up:
    ld b, TILE_CAR_BASE + 1
    ld c, 0
    ret
.left:
    ld b, TILE_CAR_BASE + 2
    ld c, OAMF_XFLIP
    ret
.right:
    ld b, TILE_CAR_BASE + 2
    ld c, 0
    ret
