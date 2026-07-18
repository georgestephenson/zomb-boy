; =============================================================================
; entity.asm — zombies: spawning, wandering AI, line-of-sight, rendering.
;
; Zombies shuffle in multi-step "runs": pick a random direction + run length,
; walk it (terrain-collision aware, slower than the player), pause, re-pick.
; If a zombie's facing lines up with the player within SIGHT_RANGE and nothing
; solid blocks the line, it raises a "!" (alert) and a battle begins.
;
; Each zombie is a 16-byte struct (fields EO_* in constants.inc). We copy the
; struct being processed into wEnt so field access is by fixed address.
; =============================================================================
INCLUDE "hardware.inc"
INCLUDE "include/constants.inc"

SECTION "Entity Code", ROM0

; Spawn offsets (signed dx,dy in tiles) from the player's start.
ZombieSpawnTable:
    db  3,  2
    db  6, -3
    db -4,  5
    db  8,  8
    db -6, -6
    db  2, -7
    db 10,  1
    db -9,  3

; -----------------------------------------------------------------------------
; InitZombies: clear the pool, then place MAX_ZOMBIES near the player start.
; -----------------------------------------------------------------------------
InitZombies::
    ld hl, wZombies
    ld b, MAX_ZOMBIES * ENT_SIZE   ; 128 bytes < 256 -> 8-bit counter (see note
    xor a, a                       ; in ClearShadowOAM about not clobbering A)
.clear:
    ld [hl+], a
    dec b
    jr nz, .clear
    ld [wZombIdx], a           ; a = 0
.place:
    ; index of the spawn entry -> DE = &ZombieSpawnTable[idx*2]
    ld a, [wZombIdx]
    add a, a
    ld e, a
    ld d, 0
    ld hl, ZombieSpawnTable
    add hl, de
    ; wGenX = playerWX + dx
    ld a, [wPlayerWX]
    ld [wGenX], a
    ld a, [wPlayerWX+1]
    ld [wGenX+1], a
    ld a, [hl+]                ; dx (signed)
    push hl
    ld hl, wGenX
    call AddSByteAt16
    pop hl
    ; wGenY = playerWY + dy
    ld a, [wPlayerWY]
    ld [wGenY], a
    ld a, [wPlayerWY+1]
    ld [wGenY+1], a
    ld a, [hl]                 ; dy (signed)
    ld hl, wGenY
    call AddSByteAt16
    ; nudge to a passable tile (up to 4 tiles right)
    ld b, 4
.passable:
    call GenTileType
    call IsSolid
    jr z, .placeOk
    ld hl, wGenX
    call Inc16Ptr
    dec b
    jr nz, .passable
.placeOk:
    ; build the entity in wEnt
    call ClearEnt
    ld a, 1
    ld [wEnt + EO_ACTIVE], a
    ld a, [wGenX]
    ld [wEnt + EO_WXLO], a
    ld a, [wGenX+1]
    ld [wEnt + EO_WXHI], a
    ld a, [wGenY]
    ld [wEnt + EO_WYLO], a
    ld a, [wGenY+1]
    ld [wEnt + EO_WYHI], a
    call Rand
    and %00000011
    ld [wEnt + EO_FACING], a   ; random initial facing
    ld a, EDIR_IDLE
    ld [wEnt + EO_DIR], a
    ld a, [wZombIdx]
    add a, a
    add a, a                    ; stagger timers so they don't move in lockstep
    ld [wEnt + EO_TIMER], a
    ld a, [wZombIdx]
    call CopyEntityOut
    ld a, [wZombIdx]
    inc a
    ld [wZombIdx], a
    cp MAX_ZOMBIES
    jp c, .place                ; loop body is >127 bytes, needs JP
    ret

; -----------------------------------------------------------------------------
; UpdateZombies: run AI + LOS for every active zombie (overworld mode only).
; On the first detection, switches to MODE_ALERT and stops.
; -----------------------------------------------------------------------------
UpdateZombies::
    xor a, a
    ld [wZombIdx], a
.loop:
    ld a, [wZombIdx]
    call CopyEntityIn
    ld a, [wEnt + EO_ACTIVE]
    and a, a
    jr z, .next
    call UpdateZombieAI
    call CheckLOS
    and a, a
    jr nz, .detected
    ld a, [wZombIdx]
    call CopyEntityOut
.next:
    ld a, [wZombIdx]
    inc a
    ld [wZombIdx], a
    cp MAX_ZOMBIES
    jr c, .loop
    ret
.detected:
    ld a, MODE_ALERT
    ld [wGameMode], a
    ld a, [wZombIdx]
    ld [wAlertZombie], a
    ld a, ALERT_FRAMES
    ld [wEnt + EO_ALERT], a
    ld a, EDIR_IDLE
    ld [wEnt + EO_DIR], a
    xor a, a
    ld [wEnt + EO_STEPS], a
    ld a, [wZombIdx]
    call CopyEntityOut
    ret

; -----------------------------------------------------------------------------
; UpdateZombieAI: one tick of wandering for wEnt.
; -----------------------------------------------------------------------------
UpdateZombieAI:
    ; ease the visual slide toward 0 every frame, independent of AI state, so
    ; state changes (blocked, going idle, direction change) never snap the sprite
    ld a, [wEnt + EO_SLIDE]
    and a, a
    jr z, .noSlide
    dec a
    ld [wEnt + EO_SLIDE], a
.noSlide:
    ld a, [wEnt + EO_TIMER]
    and a, a
    jr z, .act
    dec a
    ld [wEnt + EO_TIMER], a
    ret
.act:
    ld a, ZOMBIE_STEP_DELAY
    ld [wEnt + EO_TIMER], a
    ld a, [wEnt + EO_STEPS]
    and a, a
    jr nz, .doStep
    ; --- pick a new plan ---
    call Rand
    ld d, a                     ; keep a copy of the random byte
    and %00000011
    jr nz, .movePlan            ; 3/4: move, 1/4: pause
    ld a, EDIR_IDLE
    ld [wEnt + EO_DIR], a
    ld a, d
    and %00000011
    add a, 2                    ; pause 2..5 ticks
    ld [wEnt + EO_STEPS], a
    ret
.movePlan:
    ld a, d
    and %00000011               ; direction 0..3
    ld [wEnt + EO_DIR], a
    ld [wEnt + EO_FACING], a
    call Rand
    and %00000111
    add a, ZOMBIE_RUN_MIN
    cp ZOMBIE_RUN_MAX + 1
    jr c, .runOk
    ld a, ZOMBIE_RUN_MAX
.runOk:
    ld [wEnt + EO_STEPS], a
    ; fall through and take the first step now
.doStep:
    ld a, [wEnt + EO_DIR]
    cp EDIR_IDLE
    jr z, .idleTick
    ld [wEnt + EO_FACING], a
    ; target = pos stepped one tile in DIR (into wGenX/wGenY)
    call GenFromEnt
    ld a, [wEnt + EO_DIR]
    call StepGen
    call GenTileType
    call IsSolid
    jr nz, .blocked
    call GenEqualsPlayer        ; don't walk onto the player
    jr z, .blocked
    call CheckZombieAt          ; don't stack on another zombie
    and a, a
    jr nz, .blocked
    call EntFromGen             ; commit new position
    ; start the visual slide from the tile it just left
    ld a, [wEnt + EO_DIR]
    ld [wEnt + EO_SLIDEDIR], a
    ld a, ZOMBIE_STEP_DELAY
    ld [wEnt + EO_SLIDE], a
    ld a, [wEnt + EO_FRAME]
    xor a, 1
    ld [wEnt + EO_FRAME], a
    ld a, [wEnt + EO_STEPS]
    dec a
    ld [wEnt + EO_STEPS], a
    ret
.blocked:
    ; Didn't actually move, so clear DIR to idle: otherwise the sprite step
    ; interpolation would slide an unmoved zombie 8px sideways (a visible lurch).
    ; EO_FACING keeps the attempted direction, so it still faces the obstacle.
    ld a, EDIR_IDLE
    ld [wEnt + EO_DIR], a
    xor a, a
    ld [wEnt + EO_STEPS], a     ; end the run, re-pick next tick
    ret
.idleTick:
    ld a, [wEnt + EO_STEPS]
    dec a
    ld [wEnt + EO_STEPS], a
    ret

; -----------------------------------------------------------------------------
; CheckLOS: does wEnt see the player straight ahead (unobstructed)?
; Returns A = 1 if yes, 0 if no. Alignment check is cheap; the occlusion walk
; (Gen calls) only runs when the player is actually in line.
; -----------------------------------------------------------------------------
CheckLOS:
    ld a, [wEnt + EO_FACING]
    cp EFACE_LEFT
    jr z, .horiz
    cp EFACE_RIGHT
    jr z, .horiz
    ; vertical (down / up): need same column
    call SameCol
    jr nz, .no
    call PYmEY                  ; HL = playerY - entY
    ld a, [wEnt + EO_FACING]
    cp EFACE_UP
    jr nz, .dist                ; down: distance is playerY - entY
    call Neg16HL                ; up: distance is entY - playerY
    jr .dist
.horiz:
    call SameRow
    jr nz, .no
    call PXmEX                  ; HL = playerX - entX
    ld a, [wEnt + EO_FACING]
    cp EFACE_LEFT
    jr nz, .dist
    call Neg16HL
.dist:
    ld a, h
    and a, a
    jr nz, .no                  ; negative (behind) or far
    ld a, l
    and a, a
    jr z, .no                   ; same tile
    cp SIGHT_RANGE + 1
    jr nc, .no                  ; out of range
    ; occlusion: walk (dist-1) tiles from the zombie toward the player
    call GenFromEnt
    ld a, l
    dec a
    jr z, .yes                  ; adjacent -> visible
    ld [wLosCount], a
.occl:
    ld a, [wEnt + EO_FACING]
    call StepGen
    call GenTileType
    call IsSolid
    jr nz, .no                  ; something solid blocks the line
    ld a, [wLosCount]
    dec a
    ld [wLosCount], a
    jr nz, .occl
.yes:
    ld a, 1
    ret
.no:
    xor a, a
    ret

; -----------------------------------------------------------------------------
; UpdateAlert: count down the "!" on the alerting zombie; when it expires, run
; the (placeholder) battle and return to the overworld.
; -----------------------------------------------------------------------------
UpdateAlert::
    ld a, [wAlertZombie]
    call CopyEntityIn
    ld a, [wEnt + EO_ALERT]
    dec a
    ld [wEnt + EO_ALERT], a
    jr z, .battle
    ld a, [wAlertZombie]
    call CopyEntityOut
    ret
.battle:
    xor a, a
    ld [wEnt + EO_ACTIVE], a    ; placeholder: zombie is "defeated" and removed
    ld a, [wAlertZombie]
    call CopyEntityOut
    call BattleTransition       ; TODO: real combat replaces this flash
    ld a, MODE_OVERWORLD
    ld [wGameMode], a
    ret

; =============================================================================
; Rendering
; =============================================================================
; DrawEntities: player sprite (slot 0) + all visible zombies (+ bubble).
DrawEntities::
    call DrawPlayerSprite
    call DrawZombies
    ret

; DrawZombies: hide the entity sprite slots, then draw each active + on-screen
; zombie (and the "!" bubble for an alerting one).
DrawZombies::
    call HideEntitySprites
    xor a, a
    ld [wZombIdx], a
.loop:
    ld a, [wZombIdx]
    call CopyEntityIn
    ld a, [wEnt + EO_ACTIVE]
    and a, a
    jr z, .next
    call EntScreenPos           ; -> A=visible, wScrX/wScrY set
    and a, a
    jr z, .next
    ; HL = shadow OAM slot for this zombie = wShadowOAM + (1+idx)*4
    ld a, [wZombIdx]
    inc a
    add a, a
    add a, a
    ld c, a
    ld a, LOW(wShadowOAM)
    add a, c
    ld l, a
    ld a, HIGH(wShadowOAM)
    adc a, 0
    ld h, a
    ld a, [wScrY]
    ld [hl+], a
    ld a, [wScrX]
    ld [hl+], a
    call ZombieTileAttr         ; -> B=tile, C=attr
    ld a, b
    ld [hl+], a
    ld a, c
    ld [hl], a
    ; alerting? draw the bubble above the head
    ld a, [wEnt + EO_ALERT]
    and a, a
    jr z, .next
    call DrawBubble
.next:
    ld a, [wZombIdx]
    inc a
    ld [wZombIdx], a
    cp MAX_ZOMBIES
    jr c, .loop
    ret

; Set Y=0 (off-screen) on the zombie + bubble slots.
HideEntitySprites:
    ld hl, wShadowOAM + OAM_ZOMBIE0 * 4
    ld b, MAX_ZOMBIES + 1       ; zombies + bubble slot
    xor a, a
.loop:
    ld [hl], a
    inc hl
    inc hl
    inc hl
    inc hl
    dec b
    jr nz, .loop
    ret

; EntScreenPos: A = 1 if wEnt is within the visible window; sets wScrX/wScrY
; (OAM coords). Uses diff = entity - view; on-screen iff high byte 0 and low
; byte < VIEW_COLS/ROWS.
EntScreenPos:
    ld a, [wEnt + EO_WXLO]
    ld e, a
    ld a, [wEnt + EO_WXHI]
    ld d, a
    ld a, [wViewTX]
    ld c, a
    ld a, [wViewTX+1]
    ld b, a
    ld a, e
    sub c
    ld l, a                     ; diffX low
    ld a, d
    sbc b
    jp nz, .off
    ld a, l
    cp VIEW_COLS
    jp nc, .off
    add a, a
    add a, a
    add a, a
    add a, 8
    ld [wScrX], a
    ld a, [wEnt + EO_WYLO]
    ld e, a
    ld a, [wEnt + EO_WYHI]
    ld d, a
    ld a, [wViewTY]
    ld c, a
    ld a, [wViewTY+1]
    ld b, a
    ld a, e
    sub c
    ld l, a
    ld a, d
    sbc b
    jp nz, .off
    ld a, l
    cp VIEW_ROWS
    jp nc, .off
    add a, a
    add a, a
    add a, a
    add a, 16
    ld [wScrY], a
    ; --- smooth step slide: explicit offset set only when the zombie moved ---
    ld a, [wEnt + EO_SLIDE]
    and a, a
    jr z, .done                 ; not sliding -> sit on the tile
    srl a                       ; remaining px = slide/2 (0..8)
    ld e, a
    ld a, [wEnt + EO_SLIDEDIR]
    cp EFACE_RIGHT
    jr z, .ir
    cp EFACE_LEFT
    jr z, .il
    cp EFACE_DOWN
    jr z, .id
    ld a, [wScrY]               ; up
    add a, e
    ld [wScrY], a
    jr .done
.id:
    ld a, [wScrY]
    sub e
    ld [wScrY], a
    jr .done
.il:
    ld a, [wScrX]
    add a, e
    ld [wScrX], a
    jr .done
.ir:
    ld a, [wScrX]
    sub e
    ld [wScrX], a
.done:
    ; subtract the shared camera lag so the sprite tracks the scrolling BG
    ld a, [wScrX]
    ld hl, wCamLagX
    sub [hl]
    ld [wScrX], a
    ld a, [wScrY]
    ld hl, wCamLagY
    sub [hl]
    ld [wScrY], a
    ld a, 1
    ret
.off:
    xor a, a
    ret

; ZombieTileAttr: B = tile id, C = OAM attribute (OBJ pal 1, X-flip for left).
ZombieTileAttr:
    ld a, [wEnt + EO_FACING]
    cp EFACE_UP
    jr z, .up
    cp EFACE_LEFT
    jr z, .left
    cp EFACE_RIGHT
    jr z, .right
    ; down
    ld d, 0
    ld c, 1
    jr .fin
.up:
    ld d, 2
    ld c, 1
    jr .fin
.left:
    ld d, 4
    ld c, OAMF_XFLIP | 1
    jr .fin
.right:
    ld d, 4
    ld c, 1
.fin:
    ld a, [wEnt + EO_FRAME]
    add a, d
    add a, TILE_ZOMBIE_BASE
    ld b, a
    ret

; DrawBubble: put the "!" in the bubble slot, just above the zombie.
DrawBubble:
    ld hl, wShadowOAM + OAM_BUBBLE * 4
    ld a, [wScrY]
    sub 8
    ld [hl+], a
    ld a, [wScrX]
    ld [hl+], a
    ld a, TILE_BUBBLE
    ld [hl+], a
    ld a, 2                     ; OBJ palette 2
    ld [hl], a
    ret

; =============================================================================
; Small helpers
; =============================================================================
; CopyEntityIn / CopyEntityOut: A = index. Copies between wZombies[idx] and wEnt.
CopyEntityIn::
    call EntAddr                ; A=idx -> HL = &wZombies[idx] (clobbers DE)
    ld de, wEnt                 ; copy entity -> wEnt
    ld b, ENT_SIZE
.loop:
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .loop
    ret
CopyEntityOut::
    call EntAddr                ; A=idx -> HL = &wZombies[idx] (clobbers DE)
    ld de, wEnt                 ; copy wEnt -> entity  (DE=src, HL=dst)
    ld b, ENT_SIZE
.loop:
    ld a, [de]
    ld [hl+], a
    inc de
    dec b
    jr nz, .loop
    ret

; EntAddr: A = index -> HL = wZombies + index * 16.
EntAddr:
    ld l, a
    ld h, 0
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl                  ; * 16
    ld de, wZombies
    add hl, de
    ret

ClearEnt:
    ld hl, wEnt
    ld b, ENT_SIZE
    xor a, a
.loop:
    ld [hl+], a
    dec b
    jr nz, .loop
    ret

; wGen <- wEnt position, and back.
GenFromEnt:
    ld a, [wEnt + EO_WXLO]
    ld [wGenX], a
    ld a, [wEnt + EO_WXHI]
    ld [wGenX+1], a
    ld a, [wEnt + EO_WYLO]
    ld [wGenY], a
    ld a, [wEnt + EO_WYHI]
    ld [wGenY+1], a
    ret
EntFromGen:
    ld a, [wGenX]
    ld [wEnt + EO_WXLO], a
    ld a, [wGenX+1]
    ld [wEnt + EO_WXHI], a
    ld a, [wGenY]
    ld [wEnt + EO_WYLO], a
    ld a, [wGenY+1]
    ld [wEnt + EO_WYHI], a
    ret

; StepGen: A = direction (EFACE_*). Step wGenX/wGenY one tile that way.
StepGen::
    cp EFACE_DOWN
    jr z, .down
    cp EFACE_UP
    jr z, .up
    cp EFACE_LEFT
    jr z, .left
    ld hl, wGenX               ; right
    jp Inc16Ptr
.left:
    ld hl, wGenX
    jp Dec16Ptr
.up:
    ld hl, wGenY
    jp Dec16Ptr
.down:
    ld hl, wGenY
    jp Inc16Ptr

; CheckZombieAt: is an active zombie occupying tile (wGenX, wGenY)?
; Returns A = 1 if yes, 0 if no. Scans wZombies directly (doesn't touch wEnt),
; so it's safe to call from both player and zombie movement.
CheckZombieAt::
    ld c, MAX_ZOMBIES
    ld hl, wZombies             ; hl -> EO_ACTIVE of entity 0
.loop:
    ld a, [hl]                  ; EO_ACTIVE
    and a, a
    jr z, .next
    push hl
    inc hl                      ; EO_WXLO
    ld a, [wGenX]
    cp [hl]
    jr nz, .miss
    inc hl                      ; EO_WXHI
    ld a, [wGenX+1]
    cp [hl]
    jr nz, .miss
    inc hl                      ; EO_WYLO
    ld a, [wGenY]
    cp [hl]
    jr nz, .miss
    inc hl                      ; EO_WYHI
    ld a, [wGenY+1]
    cp [hl]
    jr nz, .miss
    pop hl
    ld a, 1                     ; occupied
    ret
.miss:
    pop hl
.next:
    ld de, ENT_SIZE
    add hl, de
    dec c
    jr nz, .loop
    xor a, a                    ; free
    ret

; GenEqualsPlayer: Z if (wGenX,wGenY) == player position.
GenEqualsPlayer:
    ld a, [wGenX]
    ld hl, wPlayerWX
    cp [hl]
    ret nz
    ld a, [wGenX+1]
    ld hl, wPlayerWX+1
    cp [hl]
    ret nz
    ld a, [wGenY]
    ld hl, wPlayerWY
    cp [hl]
    ret nz
    ld a, [wGenY+1]
    ld hl, wPlayerWY+1
    cp [hl]
    ret

; SameCol / SameRow: Z if wEnt shares the player's X / Y.
SameCol:
    ld a, [wEnt + EO_WXLO]
    ld hl, wPlayerWX
    cp [hl]
    ret nz
    ld a, [wEnt + EO_WXHI]
    ld hl, wPlayerWX+1
    cp [hl]
    ret
SameRow:
    ld a, [wEnt + EO_WYLO]
    ld hl, wPlayerWY
    cp [hl]
    ret nz
    ld a, [wEnt + EO_WYHI]
    ld hl, wPlayerWY+1
    cp [hl]
    ret

; PXmEX / PYmEY: HL = player coord - entity coord (16-bit signed).
PXmEX:
    ld a, [wPlayerWX]
    ld e, a
    ld a, [wPlayerWX+1]
    ld d, a
    ld a, [wEnt + EO_WXLO]
    ld c, a
    ld a, [wEnt + EO_WXHI]
    ld b, a
    jr Sub16DE_BC
PYmEY:
    ld a, [wPlayerWY]
    ld e, a
    ld a, [wPlayerWY+1]
    ld d, a
    ld a, [wEnt + EO_WYLO]
    ld c, a
    ld a, [wEnt + EO_WYHI]
    ld b, a
    ; fall through
Sub16DE_BC:
    ld a, e
    sub c
    ld l, a
    ld a, d
    sbc b
    ld h, a
    ret

; Neg16HL: HL = 0 - HL.
Neg16HL:
    xor a, a
    sub l
    ld l, a
    sbc a, a
    sub h
    ld h, a
    ret

; AddSByteAt16: HL -> 16-bit LE var; A = signed byte to add.
AddSByteAt16:
    ld c, a                     ; save byte
    add a, [hl]
    ld [hl+], a                 ; low += byte; carry set for high
    ld a, 0
    adc a, 0
    ld b, a                     ; B = carry from low
    ld a, c
    and $80
    jr z, .pos
    ld a, $FF                   ; sign-extend negative
    jr .addHigh
.pos:
    xor a, a
.addHigh:
    add a, b
    add a, [hl]
    ld [hl], a
    ret
