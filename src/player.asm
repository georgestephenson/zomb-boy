; =============================================================================
; player.asm — player state, weighty grid movement, camera, sprite.
;
; Movement is a small state machine (idle / turning / walking) that gives the
; movement "weight":
;   * pressing a new direction first *turns* in place (TURN_DELAY frames) before
;     you start walking — you can't instantly reverse;
;   * a step is animated smoothly over STEP_TOTAL sub-units (the camera
;     interpolates, so the world slides rather than snapping a whole tile);
;   * holding a direction chains steps into a continuous walk.
;
; The logical tile updates at the *start* of a step (so collision / streaming /
; line-of-sight all use the new tile); the camera then slides to catch up.
; =============================================================================
INCLUDE "hardware.inc"
INCLUDE "include/constants.inc"

SECTION "Player", ROM0

; Place the player at the origin, scanning to the first passable tile.
InitPlayer::
    xor a, a
    ld [wFacing], a            ; EFACE_DOWN
    ld [wWalkFrame], a
    ld [wPlayerState], a       ; PSTATE_IDLE
    ld [wStepOffset], a
    ld [wStepDir], a
    ld [wTurnTimer], a
    ld [wMoveDir], a
    ld [wPlayerWX], a
    ld [wPlayerWX+1], a
    ld [wPlayerWY], a
    ld [wPlayerWY+1], a
    ld [wSwimming], a           ; start on dry land (InitPlayer scans to a passable
    ld [wSplashTimer], a        ; tile, and water is solid, so never in water)
    ld b, 64                    ; bounded search
.scan:
    ld a, [wPlayerWX]
    ld [wGenX], a
    ld a, [wPlayerWX+1]
    ld [wGenX+1], a
    ld a, [wPlayerWY]
    ld [wGenY], a
    ld a, [wPlayerWY+1]
    ld [wGenY+1], a
    call GenTileType
    call IsSolid
    jr z, .found
    ld hl, wPlayerWX
    call Inc16Ptr
    dec b
    jr nz, .scan
.found:
    ; record the spawn tile so the status screen can show position relative to it
    ld a, [wPlayerWX]
    ld [wSpawnWX], a
    ld a, [wPlayerWX+1]
    ld [wSpawnWX+1], a
    ld a, [wPlayerWY]
    ld [wSpawnWY], a
    ld a, [wPlayerWY+1]
    ld [wSpawnWY+1], a
    ret

; View follows the player, centred (no clamp — the world is endless).
UpdateView::
    ld a, [wPlayerWX]
    sub PLAYER_COL
    ld [wViewTX], a
    ld a, [wPlayerWX+1]
    sbc a, 0
    ld [wViewTX+1], a
    ld a, [wPlayerWY]
    sub PLAYER_ROW
    ld [wViewTY], a
    ld a, [wPlayerWY+1]
    sbc a, 0
    ld [wViewTY+1], a
    ret

; -----------------------------------------------------------------------------
; UpdatePlayer: advance the movement state machine one frame.
; -----------------------------------------------------------------------------
UpdatePlayer::
    xor a, a
    ld [wMoveDir], a           ; default: no step started this frame (no stream)
    ld a, [wPlayerState]
    cp PSTATE_WALK
    jp z, .walking
    cp PSTATE_TURN
    jp z, .turning

; --- IDLE ---
.idle:
    ; walking into a car? take the armed step ONTO it (wCarBoard = EFACE_*+1, set
    ; by CheckCarToggle). StartBoardStep flips to driving when the step finishes.
    ld a, [wCarBoard]
    and a
    jr z, .noBoard
    ld b, a
    xor a, a
    ld [wCarBoard], a          ; consume it
    ld a, b
    dec a                      ; dir+1 -> EFACE_*
    jp StartBoardStep
.noBoard:
    ; just got out of the car? step out one tile in the armed direction, using
    ; the normal walk + streaming path (wCarEject = EFACE_*+1, set by ExitCar).
    ld a, [wCarEject]
    and a
    jr z, .noEject
    ld b, a
    xor a, a
    ld [wCarEject], a          ; consume it
    ld a, b
    dec a                      ; dir+1 -> EFACE_*
    jp TryStartStep            ; on foot now -> commits the step + flags the stream
.noEject:
    call ReadHeldDir           ; A = EFACE_* or $FF
    cp $FF
    ret z
    ld b, a
    ld a, [wFacing]
    cp b
    jr z, .idleWalk            ; already facing that way -> walk
    ld a, b                    ; else turn first
    ld [wFacing], a
    ld a, PSTATE_TURN
    ld [wPlayerState], a
    ld a, TURN_DELAY
    ld [wTurnTimer], a
    ret
.idleWalk:
    ld a, b
    jp TryStartStep

; --- TURNING ---
.turning:
    ld a, [wTurnTimer]
    dec a
    ld [wTurnTimer], a
    jr z, .turnReady
    ; still turning — allow re-facing to a different held direction
    call ReadHeldDir
    cp $FF
    ret z
    ld b, a
    ld a, [wFacing]
    cp b
    ret z
    ld a, b
    ld [wFacing], a
    ld a, TURN_DELAY
    ld [wTurnTimer], a
    ret
.turnReady:
    call ReadHeldDir
    cp $FF
    jr z, .toIdle              ; released during the turn
    ld b, a
    ld a, [wFacing]
    cp b
    jr z, .turnWalk
    ld a, b                    ; new direction pressed -> re-turn
    ld [wFacing], a
    ld a, TURN_DELAY
    ld [wTurnTimer], a
    ret
.turnWalk:
    ld a, b
    jp TryStartStep
.toIdle:
    ld a, PSTATE_IDLE
    ld [wPlayerState], a
    xor a, a
    ld [wWalkFrame], a
    ret

; --- WALKING (animating a step) ---
.walking:
    ld b, STEP_SPEED           ; a car covers a tile in half the frames (2x pace)
    ld a, [wInCar]
    and a
    jr z, .walkSpeed
    ld b, CAR_STEP_SPEED
.walkSpeed:
    ld a, [wStepOffset]
    add a, b
    ld [wStepOffset], a
    cp STEP_TOTAL
    jr c, .walkContinue        ; step still in progress
    ; step complete
    ld a, PSTATE_IDLE
    ld [wPlayerState], a
    xor a, a
    ld [wStepOffset], a
    ; finished walking into the car? get in now — the door shuts and the HUD swaps
    ; energy for fuel. wInCar flips only here, so the car never jumped on boarding.
    ld a, [wBoarding]
    and a
    jr z, .stepDone
    xor a, a
    ld [wBoarding], a
    ld [wSwimming], a          ; no swimming from the driver's seat
    ld [wSplashTimer], a
    ld [wCarEject], a          ; no stale get-out step
    ld [wWalkFrame], a
    ld a, 1
    ld [wInCar], a
    call PlayCarDoor           ; the door thud (audio.asm)
    call ComposeHUD
    ld a, 1
    ld [wHUDDirty], a
    ret
.stepDone:
    call ReadHeldDir
    cp $FF
    jr z, .walkStop
    ld b, a
    ld a, [wFacing]
    cp b
    jr z, .walkChain           ; same dir held -> next step immediately
    ld a, b                    ; different dir -> turn
    ld [wFacing], a
    ld a, PSTATE_TURN
    ld [wPlayerState], a
    ld a, TURN_DELAY
    ld [wTurnTimer], a
    ret
.walkChain:
    ld a, b
    jp TryStartStep
.walkStop:
    xor a, a
    ld [wWalkFrame], a
    ret
.walkContinue:
    ret

; -----------------------------------------------------------------------------
; TryStartStep: A = EFACE_* direction. If the target tile is passable, commit
; the logical move, kick off the smooth step, and flag streaming; else stay put.
; -----------------------------------------------------------------------------
TryStartStep:
    ld [wStepDir], a
    ld [wFacing], a
    ld a, [wInCar]
    and a
    jr nz, .driving
    ; --- on foot: check the single destination tile ---
    call GenPlayerStep         ; wGen = player + one step (dir); shared with entity
    call GenTileType
    ld [wDestTile], a          ; remember it: drives the swim/splash test at .ok
    call IsSolid
    jr z, .notSolid            ; passable terrain
    ; solid tile. On foot the player swims, so water is the one walkable "solid".
    ld a, [wDestTile]
    cp TILE_WATER
    jr nz, .blocked            ; genuinely solid (wall / tree)
.notSolid:
    call CheckZombieAt         ; a zombie is standing there
    and a, a
    jr nz, .blocked
    call CheckNPCAt            ; a survivor is standing there (talk instead)
    and a, a
    jr nz, .blocked
    call CheckCarAt            ; the parked 2x2 car — board it with A, don't walk on
    and a, a
    jr nz, .blocked
    jr .ok
.driving:
    ; --- driving: an empty tank strands you; else the car's 2x2 leading edge (the
    ;     two tiles it newly covers) must be clear. Water blocks — a car can't float.
    ld a, [wFuel]
    and a
    jr z, .blocked
    call CheckDriveEdge        ; Z if both leading footprint tiles are clear
    jr nz, .blocked
    call GenPlayerStep         ; wGen = the new top-left anchor, for the commit
    jr .ok
.blocked:
    ; bump — stay idle, keep facing
    ld a, PSTATE_IDLE
    ld [wPlayerState], a
    xor a, a
    ld [wWalkFrame], a
    ret
.ok:
    ld a, [wGenX]
    ld [wPlayerWX], a
    ld a, [wGenX+1]
    ld [wPlayerWX+1], a
    ld a, [wGenY]
    ld [wPlayerWY], a
    ld a, [wGenY+1]
    ld [wPlayerWY+1], a
    ; --- driving: the car is a world object that moves as a unit, so advance its
    ;     2x2 anchor in lockstep with the player (the seat offset stays constant);
    ;     no swim state; burn one unit of fuel per tile and refresh the HUD fuel
    ;     readout (the tank was already checked non-empty above) ---
    ld a, [wInCar]
    and a
    jr z, .footStep
    ld a, [wCarWX]
    ld [wGenX], a
    ld a, [wCarWX+1]
    ld [wGenX+1], a
    ld a, [wCarWY]
    ld [wGenY], a
    ld a, [wCarWY+1]
    ld [wGenY+1], a
    ld a, [wStepDir]
    call StepGen               ; step the car TL one tile the same way
    ld a, [wGenX]
    ld [wCarWX], a
    ld a, [wGenX+1]
    ld [wCarWX+1], a
    ld a, [wGenY]
    ld [wCarWY], a
    ld a, [wGenY+1]
    ld [wCarWY+1], a
    ld a, [wFuel]
    dec a
    ld [wFuel], a
    call ComposeHUD
    ld a, 1
    ld [wHUDDirty], a
    jr .swimDone
.footStep:
    ; --- swim state: crossing the land/water boundary splashes (sound + sprite) ---
    ld a, [wDestTile]
    cp TILE_WATER
    ld b, 0                     ; b = new swim state (cp above set the flags)
    jr nz, .swimSet
    ld b, 1
.swimSet:
    ld a, [wSwimming]
    cp b
    jr z, .swimDone            ; no boundary crossed this step
    ld a, b
    ld [wSwimming], a
    call TriggerSplash
.swimDone:
    ; trigger the incoming-edge stream for this direction
    ld a, [wStepDir]
    call DirToMoveDir
    ld [wMoveDir], a
    ; begin the animated step
    ld a, PSTATE_WALK
    ld [wPlayerState], a
    xor a, a
    ld [wStepOffset], a
    ld a, [wWalkFrame]
    xor a, 1                    ; alternate foot each tile
    ld [wWalkFrame], a
    ret

; ComputeCamLag: set wCamLagX/wCamLagY = the signed pixel offset the camera is
; lagging behind the (snapped) logical view while mid-step. 0 when not walking.
; SetScroll adds this to the BG scroll; sprite drawing subtracts it — that keeps
; sprites and background locked to one smooth camera.
ComputeCamLag::
    xor a, a
    ld [wCamLagX], a
    ld [wCamLagY], a
    ld a, [wPlayerState]
    cp PSTATE_WALK
    ret nz
    ld a, [wStepOffset]
    ld e, a
    ld a, STEP_TOTAL
    sub e
    srl a                       ; remaining px = (STEP_TOTAL - offset)/2 (0..8)
    ld e, a
    ld a, [wStepDir]
    cp EFACE_RIGHT
    jr z, .right
    cp EFACE_LEFT
    jr z, .left
    cp EFACE_DOWN
    jr z, .down
    ld a, e                     ; up:    SCY = base + remaining
    ld [wCamLagY], a
    ret
.down:                          ; down:  SCY = base - remaining
    ld a, e
    cpl
    inc a
    ld [wCamLagY], a
    ret
.left:                          ; left:  SCX = base + remaining
    ld a, e
    ld [wCamLagX], a
    ret
.right:                         ; right: SCX = base - remaining
    ld a, e
    cpl
    inc a
    ld [wCamLagX], a
    ret

; ReadHeldDir: A = a single held direction (priority up,down,left,right) as
; EFACE_*, or $FF if none held.
ReadHeldDir:
    ld a, [wCurKeys]
    bit 2, a                    ; PAD_UP
    jr z, .nu
    ld a, EFACE_UP
    ret
.nu:
    bit 3, a                    ; PAD_DOWN
    jr z, .nd
    ld a, EFACE_DOWN
    ret
.nd:
    bit 1, a                    ; PAD_LEFT
    jr z, .nl
    ld a, EFACE_LEFT
    ret
.nl:
    bit 0, a                    ; PAD_RIGHT
    jr z, .none
    ld a, EFACE_RIGHT
    ret
.none:
    ld a, $FF
    ret

; DirToMoveDir: A = EFACE_* -> DIR_* (the streaming direction code).
DirToMoveDir::
    ld e, a
    ld d, 0
    ld hl, DirMap
    add hl, de
    ld a, [hl]
    ret
DirMap:
    db DIR_DOWN, DIR_UP, DIR_LEFT, DIR_RIGHT   ; index by EFACE_*

; -----------------------------------------------------------------------------
; DrawPlayerSprite: fixed screen position; tile from facing + walk frame.
; -----------------------------------------------------------------------------
DrawPlayerSprite::
    ld a, SPR_Y
    ld [wShadowOAM + 0], a
    ld a, SPR_X
    ld [wShadowOAM + 1], a
    ld a, [wSwimming]
    and a, a
    jr nz, .swim               ; submerged: head-and-shoulders tiles, no walk cycle
    ld a, [wFacing]
    cp EFACE_UP
    jr z, .up
    cp EFACE_LEFT
    jr z, .left
    cp EFACE_RIGHT
    jr z, .right
    ld d, 0                     ; down
    ld c, 0
    jr .fin
.up:
    ld d, 2
    ld c, 0
    jr .fin
.left:
    ld d, 4
    ld c, OAMF_XFLIP
    jr .fin
.right:
    ld d, 4
    ld c, 0
.fin:
    ld a, [wWalkFrame]
    add a, d
    add a, TILE_PLAYER_BASE
    ld [wShadowOAM + 2], a
    ld a, c
    ld [wShadowOAM + 3], a
    ret
; --- swimming: one tile per facing (down/up/side), palette 0 like on land ---
.swim:
    ld a, [wFacing]
    cp EFACE_UP
    jr z, .swimUp
    cp EFACE_LEFT
    jr z, .swimLeft
    cp EFACE_RIGHT
    jr z, .swimRight
    ld a, TILE_SWIM_BASE + 0    ; down
    ld c, 0
    jr .swimFin
.swimUp:
    ld a, TILE_SWIM_BASE + 1
    ld c, 0
    jr .swimFin
.swimLeft:
    ld a, TILE_SWIM_BASE + 2
    ld c, OAMF_XFLIP
    jr .swimFin
.swimRight:
    ld a, TILE_SWIM_BASE + 2
    ld c, 0
.swimFin:
    ld [wShadowOAM + 2], a
    ld a, c
    ld [wShadowOAM + 3], a
    ret

; -----------------------------------------------------------------------------
; TriggerSplash: kick the enter/leave-water feedback — a short noise-channel
; blip (audio.asm) plus the splash sprite for SWIM_SPLASH_FRAMES frames.
; -----------------------------------------------------------------------------
TriggerSplash:
    ld a, SWIM_SPLASH_FRAMES
    ld [wSplashTimer], a
    jp PlaySplash              ; tail-call: its ret returns for us

; -----------------------------------------------------------------------------
; DrawSplash: overlay the splash burst on the player while the timer runs, then
; hide the slot. Called from DrawEntities each overworld frame.
; -----------------------------------------------------------------------------
DrawSplash::
    ld hl, wShadowOAM + OAM_SPLASH * 4
    ld a, [wSplashTimer]
    and a, a
    jr z, .hide
    dec a
    ld [wSplashTimer], a
    ld a, SPR_Y                ; sits on the player (fixed screen position)
    ld [hl+], a
    ld a, SPR_X
    ld [hl+], a
    ld a, TILE_SPLASH
    ld [hl+], a
    ld a, 2                    ; OBJ palette 2 (white spray, like the bubble)
    ld [hl], a
    ret
.hide:
    xor a, a
    ld [hl], a                 ; Y = 0 -> off-screen
    ret
