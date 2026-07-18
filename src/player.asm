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
    ret z
    ld hl, wPlayerWX
    call Inc16Ptr
    dec b
    jr nz, .scan
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
    ld a, [wStepOffset]
    add a, STEP_SPEED
    ld [wStepOffset], a
    cp STEP_TOTAL
    jr c, .walkContinue        ; step still in progress
    ; step complete
    ld a, PSTATE_IDLE
    ld [wPlayerState], a
    xor a, a
    ld [wStepOffset], a
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
    ; target = current tile stepped one in the chosen direction (into wGen)
    ld a, [wPlayerWX]
    ld [wGenX], a
    ld a, [wPlayerWX+1]
    ld [wGenX+1], a
    ld a, [wPlayerWY]
    ld [wGenY], a
    ld a, [wPlayerWY+1]
    ld [wGenY+1], a
    ld a, [wStepDir]
    call StepGen               ; steps wGenX/wGenY (shared with entity code)
    call GenTileType
    call IsSolid
    jr nz, .blocked            ; solid terrain
    call CheckZombieAt         ; a zombie is standing there
    and a, a
    jr z, .ok
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
DirToMoveDir:
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
