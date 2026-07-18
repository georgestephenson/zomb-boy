; =============================================================================
; player.asm — player state, grid movement + collision, camera, sprite.
; The player is drawn at a fixed screen position; the world scrolls under it.
; =============================================================================
INCLUDE "hardware.inc"
INCLUDE "include/constants.inc"

SECTION "Player", ROM0

; Place the player at the origin, scanning to the first passable tile.
InitPlayer::
    xor a, a
    ld [wFacing], a
    ld [wWalkFrame], a
    ld [wFlip], a
    ld [wMoveCooldown], a
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
    ret z                       ; passable -> done
    ld hl, wPlayerWX
    call Inc16Ptr               ; step right (doesn't clobber B)
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
; UpdatePlayer: one grid step per MOVE_COOLDOWN while a direction is held, with
; tile collision. Sets wMoveDir (for streaming) only on a successful move.
; -----------------------------------------------------------------------------
UpdatePlayer::
    xor a, a
    ld [wMoveDir], a            ; default: didn't move
    ld a, [wMoveCooldown]
    and a, a
    jr z, .ready
    dec a
    ld [wMoveCooldown], a
    ret
.ready:
    ld a, [wCurKeys]
    ld e, a
    ; candidate target = current position (in wGenX/wGenY)
    ld a, [wPlayerWX]
    ld [wGenX], a
    ld a, [wPlayerWX+1]
    ld [wGenX+1], a
    ld a, [wPlayerWY]
    ld [wGenY], a
    ld a, [wPlayerWY+1]
    ld [wGenY+1], a
    bit 2, e                    ; UP
    jr z, .notUp
    xor a, a
    ld [wFlip], a
    ld a, 1
    ld [wFacing], a
    ld hl, wGenY
    call Dec16Ptr
    ld a, DIR_UP
    ld [wMoveDir], a
    jr .attempt
.notUp:
    bit 3, e                    ; DOWN
    jr z, .notDown
    xor a, a
    ld [wFlip], a
    ld [wFacing], a            ; facing down = 0
    ld hl, wGenY
    call Inc16Ptr
    ld a, DIR_DOWN
    ld [wMoveDir], a
    jr .attempt
.notDown:
    bit 1, e                    ; LEFT
    jr z, .notLeft
    ld a, 2
    ld [wFacing], a
    ld a, OAMF_XFLIP
    ld [wFlip], a
    ld hl, wGenX
    call Dec16Ptr
    ld a, DIR_LEFT
    ld [wMoveDir], a
    jr .attempt
.notLeft:
    bit 0, e                    ; RIGHT
    jr z, .none
    ld a, 2
    ld [wFacing], a
    xor a, a
    ld [wFlip], a
    ld hl, wGenX
    call Inc16Ptr
    ld a, DIR_RIGHT
    ld [wMoveDir], a
    jr .attempt
.none:
    xor a, a
    ld [wWalkFrame], a         ; idle -> standing frame
    ret
.attempt:
    call GenTileType
    call IsSolid
    jr z, .doMove
    ; blocked: keep the new facing, but don't move or stream
    xor a, a
    ld [wMoveDir], a
    ld [wWalkFrame], a
    ld a, MOVE_COOLDOWN
    ld [wMoveCooldown], a
    ret
.doMove:
    ld a, [wGenX]
    ld [wPlayerWX], a
    ld a, [wGenX+1]
    ld [wPlayerWX+1], a
    ld a, [wGenY]
    ld [wPlayerWY], a
    ld a, [wGenY+1]
    ld [wPlayerWY+1], a
    ld a, [wWalkFrame]
    xor a, 1                    ; alternate foot
    ld [wWalkFrame], a
    ld a, MOVE_COOLDOWN
    ld [wMoveCooldown], a
    ret

; -----------------------------------------------------------------------------
; DrawPlayerSprite: fixed screen position; tile = base[facing] + walk frame.
; -----------------------------------------------------------------------------
DrawPlayerSprite::
    ld a, SPR_Y
    ld [wShadowOAM + 0], a
    ld a, SPR_X
    ld [wShadowOAM + 1], a
    ld a, [wFacing]
    add a, a                    ; * 2 (two frames per facing)
    add a, TILE_PLAYER_BASE
    ld b, a
    ld a, [wWalkFrame]
    add a, b
    ld [wShadowOAM + 2], a
    ld a, [wFlip]
    ld [wShadowOAM + 3], a
    ret
