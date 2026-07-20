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
; InitCar: place the one car and set it on foot with a full tank. Call after
; InitPlayer/InitMap and the other spawns. wCarWX/WY is the top-left tile of the
; 2x2 footprint.
;
; It first hunts (CAR_SPAWN_TRIES random anchors) for a clear 2x2 spot that sits
; ON/beside a road, away from the start (CAR_MIN_DIST+), and NOT inside a house —
; a car belongs on a road. Roads are 2 tiles wide now, so a footprint straddling
; an avenue/street is a natural fit. The random probes come from the dynamic
; RNG, saved/restored around the search so it doesn't perturb the spawn stream
; (every dynamic-spawn test stays byte-identical). If nothing turns up (e.g. a
; forest spawn with no road nearby), it falls back to the classic near-player
; nudge-right placement.
; -----------------------------------------------------------------------------
InitCar::
    xor a, a
    ld [wInCar], a
    ld [wCarEject], a
    ld [wCarBoard], a
    ld [wBoarding], a
    ; --- save the dynamic RNG so the road hunt is invisible to it ---
    ld a, [wRngState]
    ld [wCarRngSave], a
    ld a, [wRngState+1]
    ld [wCarRngSave+1], a
    ld a, CAR_SPAWN_TRIES
    ld [wCarTries], a
.try:
    call PickCarAnchor              ; wGenX/WY = a random anchor away from spawn
    call CarSpotOK                  ; Z if clear, on/next to a road, no house
    jr z, .found
    ld a, [wCarTries]
    dec a
    ld [wCarTries], a
    jr nz, .try
    ; --- no road spot found: fall back to the near-player clear placement ---
    call PlaceCarNearPlayer         ; leaves the anchor in wGenX/WY
.found:
    ld a, [wGenX]
    ld [wCarWX], a
    ld a, [wGenX+1]
    ld [wCarWX+1], a
    ld a, [wGenY]
    ld [wCarWY], a
    ld a, [wGenY+1]
    ld [wCarWY+1], a
    ; restore the RNG stream the dynamic spawns will run from
    ld a, [wCarRngSave]
    ld [wRngState], a
    ld a, [wCarRngSave+1]
    ld [wRngState+1], a
    ld a, EFACE_DOWN
    ld [wCarFacing], a
    ld a, FUEL_START
    ld [wFuel], a
    ret

; -----------------------------------------------------------------------------
; PickCarAnchor: wGenX/WY = the player's tile offset by a random amount away from
; the start. One axis (chosen at random) is the "primary": magnitude CAR_MIN_DIST
; .. CAR_MIN_DIST+CAR_DIST_MASK, random sign; the other is a free -16..+15 spread.
; So the anchor is never right on top of the player. Consumes two Rand bytes.
; -----------------------------------------------------------------------------
PickCarAnchor:
    call GenFromPlayer              ; wGen = player tile
    call Rand
    ld e, a                         ; E = random bits (survives Rand/AddSByteAt16)
    and CAR_DIST_MASK
    add a, CAR_MIN_DIST             ; primary magnitude
    bit 7, e
    jr z, .primPos
    cpl
    inc a                           ; negate -> signed negative offset
.primPos:
    ld c, a                         ; C = signed primary offset
    call Rand
    and 31
    sub 16                          ; secondary offset -16..+15
    ld d, a                         ; D = signed secondary offset
    bit 6, e
    jr nz, .yPrimary
    ; x is the far axis
    ld a, c
    ld hl, wGenX
    call AddSByteAt16
    ld a, d
    ld hl, wGenY
    jp AddSByteAt16                 ; tail call
.yPrimary:
    ld a, c
    ld hl, wGenY
    call AddSByteAt16
    ld a, d
    ld hl, wGenX
    jp AddSByteAt16                 ; tail call

; -----------------------------------------------------------------------------
; CarSpotOK: wGenX/WY = the 2x2 footprint's top-left. Z if it is a good car spot:
; all four tiles passable, none a house interior (floor/door), and at least one a
; road tile (so the car sits on/beside a road). Walks the 2x2 by stepping wGen
; and leaves it back at the anchor. Uses wCarScan (bit0 = a road tile was seen).
; -----------------------------------------------------------------------------
CarSpotOK:
    xor a, a
    ld [wCarScan], a
    call .cell                      ; (0,0)
    ret nz                          ; wGen already at the anchor
    ld hl, wGenX
    call Inc16Ptr                   ; -> (1,0)
    call .cell
    jr nz, .no1
    ld hl, wGenY
    call Inc16Ptr                   ; -> (1,1)
    call .cell
    jr nz, .no2
    ld hl, wGenX
    call Dec16Ptr                   ; -> (0,1)
    call .cell
    jr nz, .no3
    ld hl, wGenY
    call Dec16Ptr                   ; -> (0,0): footprint fully classified
    ld a, [wCarScan]
    and 1
    jr z, .no                       ; no road tile touched -> reject
    xor a, a                        ; Z = accept
    ret
.no3:                               ; wGen at (0,1) -> restore Y
    ld hl, wGenY
    call Dec16Ptr
    jr .no
.no2:                               ; wGen at (1,1) -> restore X and Y
    ld hl, wGenX
    call Dec16Ptr
    ld hl, wGenY
    call Dec16Ptr
    jr .no
.no1:                               ; wGen at (1,0) -> restore X
    ld hl, wGenX
    call Dec16Ptr
.no:
    or a, 1                         ; NZ = reject
    ret
; .cell: classify the tile at wGen. Z (spot still OK) if it is passable and not a
; house interior; NZ if it disqualifies the spot. Flags a road in wCarScan bit0.
; GenTileType preserves wGenX/WY, so the 2x2 walk above is safe.
.cell:
    call GenTileType                ; A = tile id
    cp TILE_ROAD
    jr nz, .notRoad
    ld a, [wCarScan]
    or 1
    ld [wCarScan], a
    xor a, a                        ; road: passable and welcome -> Z
    ret
.notRoad:
    cp TILE_FLOOR
    jr z, .bad                      ; inside a house -> reject the spot
    cp TILE_DOOR
    jr z, .bad
    jp IsSolid                      ; else Z iff passable (tail call)
.bad:
    or a, 1                         ; NZ
    ret

; -----------------------------------------------------------------------------
; PlaceCarNearPlayer: the classic fallback. Start at player + CAR_SPAWN_DX/DY and
; nudge right until the whole 2x2 footprint is passable (water is solid, so the
; car never parks in it). Leaves the chosen anchor in wGenX/WY for the caller.
; -----------------------------------------------------------------------------
PlaceCarNearPlayer:
    ld a, [wPlayerWX]
    ld [wGenX], a
    ld a, [wPlayerWX+1]
    ld [wGenX+1], a
    ld a, CAR_SPAWN_DX
    ld hl, wGenX
    call AddSByteAt16
    ld a, [wPlayerWY]
    ld [wGenY], a
    ld a, [wPlayerWY+1]
    ld [wGenY+1], a
    ld a, CAR_SPAWN_DY
    ld hl, wGenY
    call AddSByteAt16
    ld b, 8
.place:
    call Is2x2Clear                 ; preserves wGen (walks and restores it)
    ret z
    ld hl, wGenX
    call Inc16Ptr                   ; step one tile right, retry
    dec b
    jr nz, .place
    ret                             ; boxed in: use the last candidate anyway

; -----------------------------------------------------------------------------
; Is2x2Clear: Z if the 2x2 block whose top-left is (wGenX, wGenY) is all
; passable terrain (no solid tile — water counts as solid), NZ otherwise.
; Walks the four tiles by stepping wGen; on return wGen is back at the top-left.
; -----------------------------------------------------------------------------
Is2x2Clear::
    call GenSolid
    jr nz, .no0                 ; (0,0) solid — wGen already at anchor
    ld hl, wGenX
    call Inc16Ptr               ; -> (1,0)
    call GenSolid
    jr nz, .no1
    ld hl, wGenY
    call Inc16Ptr               ; -> (1,1)
    call GenSolid
    jr nz, .no2
    ld hl, wGenX
    call Dec16Ptr               ; -> (0,1)
    call GenSolid
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
; CheckCarToggle: overworld only. On an A press, start boarding the car (if on
; foot and facing it) or get out (if driving). Consumes the A press on either
; action so CheckTalkStart doesn't also fire the same frame.
;
; Boarding does NOT flip wInCar here — it *arms* a walk-onto-the-car step
; (wCarBoard). The player then walks one tile into the car, and wInCar flips only
; when that step finishes (UpdatePlayer, which also thuds the door and swaps the
; HUD). So the car never jumps to the player: it stays put, you walk into it, and
; it only moves once you drive it.
; -----------------------------------------------------------------------------
CheckCarToggle::
    ld a, [wNewKeys]
    and PAD_A
    ret z
    ld a, [wInCar]
    and a
    jr nz, .exit
    ld a, [wBoarding]
    and a
    ret nz                     ; already walking into the car -> ignore
    ; --- on foot: board only if the tile we face holds the car ---
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
    ld a, [wFacing]
    inc a                      ; arm the walk-in step (dir+1); UpdatePlayer runs it
    ld [wCarBoard], a
    jr .consumeA
.exit:
    call ExitCar               ; car stays put; eject the player onto open ground
    call PlayCarDoor           ; door thud on the way out
    call ComposeHUD            ; the energy readout returns immediately
    ld a, 1
    ld [wHUDDirty], a
.consumeA:
    ld a, [wNewKeys]
    res 4, a                   ; clear PAD_A (bit 4) so CheckTalkStart sees no press
    ld [wNewKeys], a
    ret

; -----------------------------------------------------------------------------
; StartBoardStep: A = EFACE_* facing (the armed wCarBoard direction, minus 1).
; Walk the player one tile ONTO the car in that direction — a normal on-foot walk
; step (wInCar stays 0, so the camera follows smoothly and the world streams),
; except it is *allowed* to step onto the car (that's the point). wBoarding is set
; so the walk's completion (player.asm) flips wInCar on. If the faced tile isn't
; actually the car, or is blocked, it aborts back to idle. Called from
; UpdatePlayer's idle path.
; -----------------------------------------------------------------------------
StartBoardStep::
    ld [wStepDir], a
    ld [wFacing], a
    call GenPlayerStep         ; wGen = player + step = the tile we walk onto
    call CheckCarAt
    and a
    jr z, .abort               ; not the car anymore (player turned/moved) -> bail
    call GenSolid
    jr nz, .abort              ; the car parks on passable ground; guard anyway
    call CheckZombieAt
    and a
    jr nz, .abort
    call CheckNPCAt
    and a
    jr nz, .abort
    ; commit the on-foot step onto the car tile
    ld a, [wGenX]
    ld [wPlayerWX], a
    ld a, [wGenX+1]
    ld [wPlayerWX+1], a
    ld a, [wGenY]
    ld [wPlayerWY], a
    ld a, [wGenY+1]
    ld [wPlayerWY+1], a
    ld a, 1
    ld [wBoarding], a          ; finish -> flip wInCar on (see player.asm .walking)
    ; kick the incoming-edge stream and the walk animation (as a foot step)
    ld a, [wStepDir]
    call DirToMoveDir
    ld [wMoveDir], a
    ld a, PSTATE_WALK
    ld [wPlayerState], a
    xor a, a
    ld [wStepOffset], a
    ld a, [wWalkFrame]
    xor a, 1
    ld [wWalkFrame], a
    ret
.abort:
    ld a, PSTATE_IDLE
    ld [wPlayerState], a
    xor a, a
    ld [wWalkFrame], a
    ret

; -----------------------------------------------------------------------------
; ExitCar: leave the car. The car stays exactly where it is (wCarWX/WY, already
; the 2x2 anchor — the car is a real world object, not attached to the player)
; and the PLAYER steps out of the footprint onto an adjacent passable, unoccupied
; tile (facing direction first, then a fixed sweep). The step is *armed* via
; wCarEject and walked next idle frame by UpdatePlayer, so it rides the normal
; walk + streaming path (no view seam). If hemmed in on all sides, the player
; stays on the car (re-board to leave).
; -----------------------------------------------------------------------------
ExitCar:
    xor a, a
    ld [wInCar], a
    call ClearSmoke            ; kill lingering puffs + hide their OAM slots (no smoke
                               ; on foot: DrawExhaust only runs from the driving branch)
    ld a, [wFacing]
    ld [wCarFacing], a         ; the parked car keeps the heading you left on
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
; unoccupied tile that is OUTSIDE the car's 2x2 footprint, arm the deferred player
; step-out that way (wCarEject = dir+1) and return Z; else NZ. The player sits on
; one of the car's tiles (their boarding seat), so a step that stays on the car is
; rejected (CheckCarAt) and you climb out toward open ground. (Water is solid
; here, so you never eject into it.)
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
    call GenSolid
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
; The footprint's top-left anchor is always wCarWX/WY — the car is a real world
; object that stays put when parked and moves as a unit while driven (both its
; anchor and the player advance together each drive step). So zombies and the
; on-foot player treat all four tiles as solid in every state. Scans only the car
; vars (never wEnt), so player and zombie code both call it safely. The driver is
; the exception (a car can't block its own body): driving movement checks the
; leading edge via CheckDriveEdge instead of this.
; -----------------------------------------------------------------------------
CheckCarAt::
    ld hl, wGenX
    ld de, wCarWX
    call InSpan2
    jr nz, .free
    ld hl, wGenY
    ld de, wCarWY
    call InSpan2
    jr nz, .free
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
; CheckDriveEdge: the car is a 2x2 anchored at wCarWX/WY (its top-left). When
; driving one tile in wStepDir, the two tiles the footprint newly covers (its
; leading edge) must be clear. Returns Z if both are passable terrain (water is
; solid — a car can't float) and free of a zombie/NPC; NZ if either blocks. It
; never consults CheckCarAt (the car can't block its own body). Clobbers wGen.
;
; With the anchor (cx,cy) at the top-left, the leading edge for each direction is:
;   RIGHT (cx+2,cy),(cx+2,cy+1)   LEFT (cx-1,cy),(cx-1,cy+1)
;   DOWN  (cx,cy+2),(cx+1,cy+2)   UP   (cx,cy-1),(cx+1,cy-1)
; so right/down step twice from the anchor (past the far side of the footprint)
; and the second tile offsets one along the perpendicular axis.
; -----------------------------------------------------------------------------
CheckDriveEdge::
    ; wGen = car anchor + one step in wStepDir
    ld a, [wCarWX]
    ld [wGenX], a
    ld a, [wCarWX+1]
    ld [wGenX+1], a
    ld a, [wCarWY]
    ld [wGenY], a
    ld a, [wCarWY+1]
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
    call GenSolid
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
; DrawCar: draw the one car. Driving -> the car is camera-locked around the
; player's fixed cell, offset by the boarding seat so it sits on its own tiles
; (the on-foot player slot 0 is hidden in DrawEntities), plus an occasional
; one-pixel engine-rumble wobble on Y (CarRumbleY); parked and on-screen ->
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
    jp DrawCar2x2                  ; parked: no exhaust — plain tail call (on-foot path)
.driving:
    ; the driver sits at wPlayerWX/WY, a tile inside the footprint; the car's
    ; top-left is that many tiles up/left of the player cell (seat = player - car,
    ; each axis 0 or 1). Camera-locked (no lag) like the player it replaces.
    ; seatX*8 = (wPlayerWX - wCarWX) << 3
    ld a, [wCarWX]
    ld b, a
    ld a, [wPlayerWX]
    sub b                         ; A = seatX (0 or 1)
    add a, a
    add a, a
    add a, a                      ; * 8
    ld b, a
    ld a, SPR_X
    sub b
    ld [wScrX], a
    ld a, [wCarWY]
    ld b, a
    ld a, [wPlayerWY]
    sub b                         ; A = seatY (0 or 1)
    add a, a
    add a, a
    add a, a
    ld b, a
    ld a, SPR_Y
    sub b
    ld c, a                       ; C = camera-locked base Y
    call CarRumbleY               ; A = engine wobble (-1/0/+1), advances wCarRumble
    add a, c
    ld [wScrY], a
    ; stash the on-screen top-left so EmitSmokeBurst can anchor the tailpipe on the
    ; car (it is camera-locked, so this is a stable screen cell while driving)
    ld a, [wScrX]
    ld [wCarScrX], a
    ld a, [wScrY]
    ld [wCarScrY], a
    ld a, [wFacing]
    call DrawCar2x2               ; paint the 2x2 body...
    jp DrawExhaust                ; ...then the exhaust particles (driving only); tail call
.hide:
    xor a, a
    ld [wShadowOAM + (OAM_CAR + 0) * 4], a   ; Y = 0 -> off-screen
    ld [wShadowOAM + (OAM_CAR + 1) * 4], a
    ld [wShadowOAM + (OAM_CAR + 2) * 4], a
    ld [wShadowOAM + (OAM_CAR + 3) * 4], a
    ret

; -----------------------------------------------------------------------------
; CarRumbleY: advance the engine-rumble counter (wCarRumble) and return, in A, a
; signed OAM-Y offset for the driving car sprite: -1/+1 (a one-pixel wobble) for
; the first RUMBLE_ON frames of each RUMBLE_PERIOD-frame window, then 0. It is a
; plain frame counter (never touches Rand) and only DrawCar's driving path calls
; it, so the wobble runs solely while driving and perturbs nothing else. The
; alternating sign comes from the counter's low bit, so the burst reads as a fast
; up/down shudder rather than a one-way nudge.
; -----------------------------------------------------------------------------
CarRumbleY:
    ld a, [wCarRumble]
    inc a
    ld [wCarRumble], a
    and RUMBLE_PERIOD - 1         ; phase within the cycle (PERIOD is a power of 2)
    cp RUMBLE_ON
    jr nc, .still                 ; past the shudder window -> hold steady
    ld a, [wCarRumble]
    and 1                         ; alternate each frame across the burst
    jr z, .up
    ld a, 1                       ; +1 = one pixel down
    ret
.up:
    ld a, -1                      ; -1 = one pixel up
    ret
.still:
    xor a, a
    ret

; The exhaust-smoke particle system (EmitSmokeBurst / DrawExhaust / ClearSmoke)
; lives in its own ROMX BANK[1] section at the end of this file — see "Smoke Code".

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

; =============================================================================
; Smoke Code — the exhaust particle system. ROMX BANK[1] (the always-mapped
; default bank, like loot.asm/anim.asm) so ROM0 stays lean; every entry point runs
; from the overworld loop (bank 1 mapped) and only calls ROM0 or bank-1 symbols.
;
; When the car starts rolling or turns, EmitSmokeBurst spawns SMOKE_BURST puffs at
; the tailpipe, each with a velocity pulled from SmokeFan (a fixed table of
; backward + lateral-spread vectors) indexed by a free-running counter — so
; successive bursts fan out in varied, non-axis-aligned directions with NO Rand
; (worldgen/spawn determinism is untouched, exactly like anim.asm). Each puff then
; drifts by its own velocity for SMOKE_LIFE frames, stepping through the 4-frame
; dither strip (dense -> sparse) as it ages, and despawns. DrawExhaust runs the
; whole pool each driving frame; ClearSmoke wipes it when you leave the car.
; =============================================================================
SECTION "Smoke Code", ROMX, BANK[1]

; -----------------------------------------------------------------------------
; EmitSmokeBurst: spawn a fan of SMOKE_BURST puffs at the car's tailpipe. Called
; from the driving-step commit (player.asm). Deterministic (SmokeFan + a counter,
; never Rand). No-op for any puff if the pool is already full.
; -----------------------------------------------------------------------------
EmitSmokeBurst::
    ; --- tailpipe = car centre pushed one tile "behind" (opposite facing) ---
    ld a, [wFacing]
    call SmokeDirPtr              ; DE -> (Bx, By) signed behind unit
    ld a, [de]                    ; Bx
    call SmokeMul8                ; A = Bx * 8 (signed)
    ld hl, wCarScrX
    add a, [hl]
    add a, 4
    ld [wSmokeEX], a              ; tailpipe screen X
    inc de                        ; -> By
    ld a, [de]
    call SmokeMul8
    ld hl, wCarScrY
    add a, [hl]
    add a, 4
    ld [wSmokeEY], a              ; tailpipe screen Y
    ; --- fan out SMOKE_BURST particles ---
    ld b, SMOKE_BURST
.loop:
    push bc
    ; fan entry = SmokeFan[wSmokeEmit & (SMOKE_FAN_N-1)]; bump the counter
    ld a, [wSmokeEmit]
    ld c, a
    inc a
    ld [wSmokeEmit], a
    ld a, c
    and SMOKE_FAN_N - 1
    add a, a                      ; *2 (2 bytes/entry)
    ld hl, SmokeFan
    add a, l
    ld l, a
    jr nc, .nc
    inc h
.nc:
    ld a, [hl+]                   ; b = backward magnitude
    ld c, a
    ld a, [hl]                    ; p = lateral spread (signed)
    ld d, a
    call EmitOne                  ; C = b, D = p
    pop bc
    dec b
    jr nz, .loop
    ret

; -----------------------------------------------------------------------------
; EmitOne: fill one free pool slot with a puff at (wSmokeEX, wSmokeEY). C = the
; car-relative backward magnitude, D = the lateral spread (signed). The screen
; velocity is those two mapped through the heading. No-op if the pool is full.
; -----------------------------------------------------------------------------
EmitOne:
    call FindFreeSmoke            ; HL -> free slot's SP_LIFE; carry = pool full
    ret c
    ld a, SMOKE_LIFE
    ld [hl+], a                   ; SP_LIFE ; hl -> SP_VX
    ld a, [wFacing]
    cp EFACE_LEFT
    jr z, .horizL
    cp EFACE_RIGHT
    jr z, .horizR
    ; vertical travel: vx = spread ; vy = (down ? -back : +back)
    ld a, d
    ld [hl+], a                   ; SP_VX = spread ; hl -> SP_VY
    ld a, [wFacing]
    cp EFACE_DOWN
    ld a, c                       ; back
    jr nz, .vy                    ; UP -> +back
    cpl
    inc a                         ; DOWN -> -back
.vy:
    ld [hl+], a                   ; SP_VY ; hl -> SP_X
    jr .pos
.horizL:                          ; LEFT: vx = +back ; vy = spread
    ld a, c
    ld [hl+], a                   ; SP_VX
    ld a, d
    ld [hl+], a                   ; SP_VY
    jr .pos
.horizR:                          ; RIGHT: vx = -back ; vy = spread
    ld a, c
    cpl
    inc a
    ld [hl+], a                   ; SP_VX = -back
    ld a, d
    ld [hl+], a                   ; SP_VY
.pos:
    ld a, [wSmokeEX]
    ld [hl+], a                   ; SP_X
    ld a, [wSmokeEY]
    ld [hl], a                    ; SP_Y
    ret

; FindFreeSmoke: HL -> the first pool slot whose SP_LIFE is 0. Carry set (and HL
; past the pool) if every slot is active.
FindFreeSmoke:
    ld hl, wSmoke
    ld b, MAX_SMOKE
.scan:
    ld a, [hl]                    ; SP_LIFE
    and a
    jr z, .found
    ld a, l
    add a, SMOKE_STRIDE
    ld l, a
    jr nc, .nc
    inc h
.nc:
    dec b
    jr nz, .scan
    scf                           ; none free
    ret
.found:
    or a                          ; clear carry (A was 0 from the SP_LIFE read)
    ret

; SmokeMul8: A in {0, +1, -1} (a signed unit) -> A * 8. Clobbers nothing else.
SmokeMul8:
    and a
    ret z
    bit 7, a
    jr nz, .neg
    ld a, 8
    ret
.neg:
    ld a, -8
    ret

; -----------------------------------------------------------------------------
; DrawExhaust: advance every live puff (drift by its velocity, age its tile) into
; OAM_SMOKE.., and hide the slots of dead ones. Tail-called from DrawCar's driving
; branch ONLY, so on foot the pool is untouched (ClearSmoke hid the slots on exit).
; Struct order LIFE,VX,VY,X,Y lets one [hl+] pass read each velocity just before
; the position it updates.
; -----------------------------------------------------------------------------
DrawExhaust::
    ld hl, wSmoke
    ld de, wShadowOAM + OAM_SMOKE * 4
.loop:
    ld a, [hl]                    ; SP_LIFE
    and a
    jr z, .dead
    dec a
    ld [hl+], a                   ; life-- ; hl -> SP_VX ; A = new life (0..15)
    ; tile = base + (age >> 2), age = (SMOKE_LIFE-1) - newlife
    ld b, a
    ld a, SMOKE_LIFE - 1
    sub b
    srl a
    srl a
    add a, TILE_SMOKE_BASE
    ld c, a                       ; C = tile id
    ld a, [hl+]                   ; VX ; hl -> SP_VY
    ld b, a                       ; B = VX
    ld a, [hl+]                   ; VY ; hl -> SP_X
    push af                       ; save VY
    ld a, [hl]                    ; X
    add a, b                      ; X += VX (signed add works unsigned)
    ld [hl+], a                   ; store X ; hl -> SP_Y
    ld b, a                       ; B = new X
    pop af                        ; A = VY
    push bc                       ; save B = new X, C = tile
    ld b, a                       ; B = VY
    ld a, [hl]                    ; Y
    add a, b                      ; Y += VY
    ld [hl+], a                   ; store Y ; hl -> next slot
    pop bc                        ; B = new X, C = tile
    ; --- write OAM: Y, X, tile, attr ---
    ld [de], a                    ; OAM Y = new Y
    inc de
    ld a, b
    ld [de], a                    ; OAM X = new X
    inc de
    ld a, c
    ld [de], a                    ; OAM tile
    inc de
    ld a, 6                       ; attr = OBJ palette 6 (charcoal)
    ld [de], a
    inc de
    jr .next
.dead:
    xor a
    ld [de], a                    ; OAM Y = 0 -> hidden
    inc de
    inc de
    inc de
    inc de
    ld a, l
    add a, SMOKE_STRIDE
    ld l, a
    jr nc, .next
    inc h
.next:
    ld a, l
    cp LOW(wSmoke + MAX_SMOKE * SMOKE_STRIDE)
    jr nz, .loop
    ld a, h
    cp HIGH(wSmoke + MAX_SMOKE * SMOKE_STRIDE)
    jr nz, .loop
    ret

; -----------------------------------------------------------------------------
; ClearSmoke: free every particle and hide the OAM slots. Called by ExitCar so no
; puff lingers once you are on foot (DrawExhaust won't run to clear them).
; -----------------------------------------------------------------------------
ClearSmoke::
    ld hl, wShadowOAM + OAM_SMOKE * 4
    ld c, MAX_SMOKE
.hide:
    xor a
    ld [hl], a                    ; OAM Y = 0
    ld a, l
    add a, 4
    ld l, a
    jr nc, .hn
    inc h
.hn:
    dec c
    jr nz, .hide
    ld hl, wSmoke
    ld c, MAX_SMOKE * SMOKE_STRIDE
    xor a
.zero:
    ld [hl+], a                   ; SP_LIFE (and the rest) = 0 -> free
    dec c
    jr nz, .zero
    ret

; SmokeDirPtr: A = facing -> DE = a 2-byte signed unit vector from the car toward
; its tail (opposite the heading) — the tailpipe/emit direction.
SmokeDirPtr:
    cp EFACE_UP
    jr z, .up
    cp EFACE_LEFT
    jr z, .left
    cp EFACE_RIGHT
    jr z, .right
    ld de, SmokeDirDown
    ret
.up:
    ld de, SmokeDirUp
    ret
.left:
    ld de, SmokeDirLeft
    ret
.right:
    ld de, SmokeDirRight
    ret
SmokeDirDown:  db 0, -1             ; driving down  -> tail points up-screen
SmokeDirUp:    db 0, 1              ; driving up    -> tail points down-screen
SmokeDirLeft:  db 1, 0              ; driving left  -> tail points right
SmokeDirRight: db -1, 0             ; driving right -> tail points left

; SmokeFan: car-relative velocity fan (backward magnitude, lateral spread). A puff
; trails "backward" (mapped to screen by heading in EmitOne) while the signed
; spread fans it sideways, so the burst spreads into a cone of diagonal drifts
; rather than a single straight line. Cycled by wSmokeEmit; SMOKE_FAN_N entries.
SmokeFan:
    db 1, -1
    db 1,  1
    db 2,  0
    db 1,  0
    db 2, -1
    db 2,  1
    db 1, -1
    db 1,  1
