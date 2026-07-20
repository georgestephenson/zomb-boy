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
    ld de, wZombies
    call EntAddr
    ld a, [hl]                  ; EO_ACTIVE: check in the pool, so a free slot
    and a, a                    ; skips the 16-byte struct copy entirely
    jr z, .next
    call CopyEntHL
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
    ld [wEnt + EO_ALERT], a      ; hold the "!" for this many frames, then charge
    ld a, EDIR_IDLE
    ld [wEnt + EO_DIR], a
    xor a, a
    ld [wEnt + EO_STEPS], a
    ld [wEnt + EO_SLIDE], a      ; drop any residual wander slide
    ld [wEnt + EO_TIMER], a      ; first charge step fires the moment the "!" ends
    ld a, CHASE_MAX_FRAMES
    ld [wChaseTimer], a          ; arm the stall watchdog
    ; EO_FACING already points straight at the player (that's how LOS resolved),
    ; so the charge just walks that direction until it reaches the player's tile.
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
    ; Bits 0-1 decide move/pause, so they're biased by the branch (nonzero on
    ; the move path, zero on the pause path); everything after must draw from
    ; bits 2-3 or direction 0 (EFACE_DOWN) can never come up.
    call Rand
    ld d, a                     ; keep a copy of the random byte
    and %00000011
    jr nz, .movePlan            ; 3/4: move, 1/4: pause
    ld a, EDIR_IDLE
    ld [wEnt + EO_DIR], a
    ld a, d
    rrca
    rrca
    and %00000011
    add a, 2                    ; pause 2..5 ticks
    ld [wEnt + EO_STEPS], a
    ret
.movePlan:
    ld a, d
    rrca
    rrca
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
    call CheckNPCAt             ; nor shuffle onto a survivor
    and a, a
    jr nz, .blocked
    call CheckCarAt             ; nor onto the parked car
    and a, a
    jr nz, .blocked
    call CheckLootSolidAt       ; nor into a crate/pot/chest
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
    ld a, [wSwimming]
    and a, a
    jr z, .look
    xor a, a                    ; player is in the water: hidden, no detection
    ret
.look:
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

; =============================================================================
; Rendering
; =============================================================================
; DrawEntities: slot 0 = player (hidden while driving); then zombies (+ bubble),
; NPCs, and the car (its own 2x2 block OAM_CAR.., at the player cell when driving
; or its world position when parked — DrawCar handles both).
DrawEntities::
    ld a, [wInCar]
    and a
    jr nz, .driving
    call DrawPlayerSprite
    jr .rest
.driving:
    xor a, a
    ld [wShadowOAM + OAM_PLAYER * 4], a   ; hide the on-foot player; DrawCar owns the cell
.rest:
    call DrawSplash             ; hides its slot when not swimming (always, in a car)
    call DrawZombies
    call DrawNPCs
    call DrawLoot               ; world pickups + containers (OAM_LOOT..)
    call DrawCar                ; the 2x2 car (OAM_CAR..+3): driving or parked
    ret

; DrawZombies: hide the entity sprite slots, then draw each active + on-screen
; zombie (and the "!" bubble for an alerting one).
DrawZombies::
    call HideEntitySprites
    xor a, a
    ld [wZombIdx], a
.loop:
    ld a, [wZombIdx]
    ld de, wZombies
    call EntAddr
    ld a, [hl]                  ; EO_ACTIVE: skip the copy for a free slot
    and a, a
    jr z, .next
    call CopyEntHL
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
; byte < VIEW_COLS/ROWS. Shared with npc.asm (works off wEnt).
EntScreenPos::
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
    ; clip at the HUD band: the window overlays the bottom 8 px (scanlines
    ; SCRN_Y-8..) and sprites render on top of it, so hide any sprite whose
    ; 8-px box would reach it: screen top = OAM Y - 16, so overlap starts at
    ; OAM Y - 16 + 7 >= SCRN_Y - 8, i.e. OAM Y >= 145
    cp SCRN_Y - 8 + 16 - 7
    jr nc, .off
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
; The pool-generic versions (CopyPoolIn/Out, DE = pool base) are shared with the
; survivor NPCs (npc.asm) — same struct, different pool.
; The copies are unrolled: they run ~30x per overworld frame (update + draw
; loops over three pools), so the loop counter/branch was pure overhead.
CopyEntityIn::
    ld de, wZombies
CopyPoolIn::
    call EntAddr                ; A=idx, DE=base -> HL = &pool[idx]
    ; fall through: copy the struct at HL into wEnt
CopyEntHL::                     ; HL -> a pool struct (callers that already have
    ld de, wEnt                 ; the address skip the EntAddr re-derivation)
    REPT ENT_SIZE
    ld a, [hl+]
    ld [de], a
    inc de
    ENDR
    ret
CopyEntityOut::
    ld de, wZombies
CopyPoolOut::
    call EntAddr                ; A=idx, DE=base -> HL = &pool[idx]
    ld de, wEnt                 ; copy wEnt -> entity  (DE=src, HL=dst)
    REPT ENT_SIZE
    ld a, [de]
    ld [hl+], a
    inc de
    ENDR
    ret

; EntAddr: A = index, DE = pool base -> HL = base + index * 16. Preserves DE.
EntAddr::
    ld l, a
    ld h, 0
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl                  ; * 16
    add hl, de
    ret

ClearEnt::
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
EntFromGen::
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

; SameCol / SameRow: Z if wEnt shares the player's SEEN X / Y. LOS uses the tile
; the player has fully arrived on (wSeen), not the logical one — so the encounter
; fires when the step finishes, not the frame it starts (see wSeen in ram.asm).
SameCol:
    ld a, [wEnt + EO_WXLO]
    ld hl, wSeenWX
    cp [hl]
    ret nz
    ld a, [wEnt + EO_WXHI]
    ld hl, wSeenWX+1
    cp [hl]
    ret
SameRow:
    ld a, [wEnt + EO_WYLO]
    ld hl, wSeenWY
    cp [hl]
    ret nz
    ld a, [wEnt + EO_WYHI]
    ld hl, wSeenWY+1
    cp [hl]
    ret

; PXmEX / PYmEY: HL = player SEEN coord - entity coord (16-bit signed).
PXmEX:
    ld a, [wSeenWX]
    ld e, a
    ld a, [wSeenWX+1]
    ld d, a
    ld a, [wEnt + EO_WXLO]
    ld c, a
    ld a, [wEnt + EO_WXHI]
    ld b, a
    jr Sub16DE_BC
PYmEY:
    ld a, [wSeenWY]
    ld e, a
    ld a, [wSeenWY+1]
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
AddSByteAt16::
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

; =============================================================================
; Dynamic spawn manager — random encounters that despawn behind you.
;
; Each overworld frame UpdateSpawns culls any zombie/survivor more than
; ENT_CULL_DIST tiles from the player (freeing its pool slot), then — on a
; throttled timer — respawns one in a ring just outside the visible window if the
; pool is below its target. Spawn positions come from the dynamic LFSR (Rand),
; NOT the terrain hash, so revisiting the same ground never reproduces the same
; encounter. RNG is only touched when a spawn actually happens, so while the
; pools are full the manager is inert and perturbs nothing (the boot cluster and
; every near-spawn test see identical behaviour).
; =============================================================================

; InitSpawns: arm the respawn timers (call once at boot, after the pools fill).
InitSpawns::
    ld a, ZOMB_SPAWN_PERIOD
    ld [wZombSpawnTimer], a
    ld a, NPC_SPAWN_PERIOD
    ld [wNPCSpawnTimer], a
    ret

; UpdateSpawns: cull far entities, then maybe respawn. Overworld only.
UpdateSpawns::
    ld hl, wZombies             ; cull far zombies
    ld b, MAX_ZOMBIES
    call SetPool
    call CullFarPool
    ld hl, wNPCs                ; cull far survivors
    ld b, MAX_NPCS
    call SetPool
    call CullFarPool
    ; --- throttled zombie respawn ---
    ld hl, wZombSpawnTimer
    dec [hl]
    jr nz, .npc
    ld a, ZOMB_SPAWN_PERIOD
    ld [wZombSpawnTimer], a
    ld de, wZombies
    ld b, MAX_ZOMBIES
    call CountActivePool
    cp ZOMB_SPAWN_TARGET
    jr nc, .npc                 ; at target -> no spawn, no RNG consumed
    call SpawnZombie
.npc:
    ; --- throttled survivor respawn ---
    ld hl, wNPCSpawnTimer
    dec [hl]
    ret nz
    ld a, NPC_SPAWN_PERIOD
    ld [wNPCSpawnTimer], a
    ld de, wNPCs
    ld b, MAX_NPCS
    call CountActivePool
    cp NPC_SPAWN_TARGET
    ret nc                      ; enough survivors -> no spawn, no RNG consumed
    jp SpawnNPC                 ; npc.asm builds the survivor (tail call)

; SetPool: HL = base, B = count -> stash for CullFarPool.
SetPool::
    ld a, l
    ld [wPoolBase], a
    ld a, h
    ld [wPoolBase+1], a
    ld a, b
    ld [wPoolCount], a
    ret

; CullFarPool: deactivate every active entity in the pool (wPoolBase/wPoolCount)
; whose Chebyshev distance from the player exceeds ENT_CULL_DIST. Scans the
; structs IN PLACE — it reads only EO_ACTIVE + the coords and writes only
; EO_ACTIVE on a cull. (This runs over all three pools every overworld frame;
; the old wEnt round-trip copied ~26 structs a frame just to measure distances.)
CullFarPool::
    ld a, [wPoolBase]
    ld l, a
    ld a, [wPoolBase+1]
    ld h, a
    ld a, [wPoolCount]
    ld c, a
.loop:
    ld a, [hl]                  ; EO_ACTIVE
    and a, a
    jr z, .next
    push hl
    inc hl                      ; EO_WXLO
    ld a, [wPlayerWX]
    sub [hl]
    ld e, a
    inc hl                      ; EO_WXHI
    ld a, [wPlayerWX+1]
    sbc [hl]
    ld d, a                     ; DE = playerX - entX (signed)
    call CullMagDE
    jr nz, .cull
    inc hl                      ; EO_WYLO
    ld a, [wPlayerWY]
    sub [hl]
    ld e, a
    inc hl                      ; EO_WYHI
    ld a, [wPlayerWY+1]
    sbc [hl]
    ld d, a                     ; DE = playerY - entY (signed)
    call CullMagDE
    jr nz, .cull
    pop hl
    jr .next
.cull:
    pop hl
    xor a, a
    ld [hl], a                  ; despawn: free the slot in place
.next:
    ld a, l
    add a, ENT_SIZE
    ld l, a
    jr nc, .nc
    inc h
.nc:
    dec c
    jr nz, .loop
    ret

; CullMagDE: DE = signed 16-bit delta -> NZ if |DE| > ENT_CULL_DIST, Z if near.
; Preserves BC, HL.
CullMagDE:
    bit 7, d
    jr z, .pos
    xor a, a                    ; DE = -DE
    sub e
    ld e, a
    sbc a, a
    sub d
    ld d, a
.pos:
    ld a, d
    and a, a
    ret nz                      ; |delta| >= 256 tiles -> far
    ld a, e
    cp ENT_CULL_DIST + 1
    jr nc, .far
    xor a, a                    ; Z: within the cull radius
    ret
.far:
    or a, 1                     ; NZ: too far
    ret

; CountActivePool: DE = base, B = count -> A = number of active entities.
CountActivePool::
    ld l, e
    ld h, d
    ld c, 0
.loop:
    ld a, [hl]
    and a, a
    jr z, .skip
    inc c
.skip:
    ld a, l
    add a, ENT_SIZE
    ld l, a
    jr nc, .nc
    inc h
.nc:
    dec b
    jr nz, .loop
    ld a, c
    ret

; FindFreeSlot: DE = base, B = count. If a slot has EO_ACTIVE == 0, returns CY
; set and A = its index; else NC. Scans EO_ACTIVE directly (no wEnt copy).
FindFreeSlot::
    ld l, e
    ld h, d
    ld c, 0
.loop:
    ld a, [hl]
    and a, a
    jr z, .found
    ld a, l
    add a, ENT_SIZE
    ld l, a
    jr nc, .nc
    inc h
.nc:
    inc c
    ld a, c
    cp b
    jr c, .loop
    or a, a                     ; no free slot -> clear carry
    ret
.found:
    ld a, c
    scf
    ret

; GenFromPlayer: seed wGenX/wGenY with the player's world tile.
GenFromPlayer:
    ld a, [wPlayerWX]
    ld [wGenX], a
    ld a, [wPlayerWX+1]
    ld [wGenX+1], a
    ld a, [wPlayerWY]
    ld [wGenY], a
    ld a, [wPlayerWY+1]
    ld [wGenY+1], a
    ret

; PickRingTile: pick a random tile on the ENT_SPAWN_DIST ring around the player
; (one of the four sides, offset -8..+7 along it — so one axis is always DIST
; tiles out, i.e. off-screen). CY + wGenX/wGenY = the tile if it's passable and
; unoccupied; else NC (caller skips this attempt, tries again next period).
PickRingTile::
    call GenFromPlayer
    call Rand
    and 3
    ld e, a                     ; side 0..3
    call Rand
    and 15
    sub 8                       ; perpendicular offset -8..+7 (signed byte)
    ld d, a
    ld a, e
    and a, a
    jr z, .top
    dec a
    jr z, .bot
    dec a
    jr z, .left
    ; right: dx = +DIST, dy = perp
    ld a, ENT_SPAWN_DIST
    ld hl, wGenX
    call AddSByteAt16
    ld a, d
    ld hl, wGenY
    call AddSByteAt16
    jr .validate
.top:                           ; dy = -DIST, dx = perp
    ld a, 256 - ENT_SPAWN_DIST
    ld hl, wGenY
    call AddSByteAt16
    ld a, d
    ld hl, wGenX
    call AddSByteAt16
    jr .validate
.bot:                           ; dy = +DIST, dx = perp
    ld a, ENT_SPAWN_DIST
    ld hl, wGenY
    call AddSByteAt16
    ld a, d
    ld hl, wGenX
    call AddSByteAt16
    jr .validate
.left:                          ; dx = -DIST, dy = perp
    ld a, 256 - ENT_SPAWN_DIST
    ld hl, wGenX
    call AddSByteAt16
    ld a, d
    ld hl, wGenY
    call AddSByteAt16
.validate:
    call GenTileType
    call IsSolid                ; water is solid too -> never spawn in the water
    jr nz, .fail
    call CheckZombieAt
    and a, a
    jr nz, .fail
    call CheckNPCAt
    and a, a
    jr nz, .fail
    call CheckCarAt
    and a, a
    jr nz, .fail
    call CheckLootAt            ; don't spawn on top of existing loot
    and a, a
    jr nz, .fail
    scf
    ret
.fail:
    or a, a                     ; clear carry
    ret

; SpawnZombie: place one wandering zombie in a free pool slot on the ring.
SpawnZombie:
    ld de, wZombies
    ld b, MAX_ZOMBIES
    call FindFreeSlot
    ret nc
    ld [wPoolIdx], a            ; stash the free slot index
    call PickRingTile
    ret nc                      ; ring tile blocked -> skip this attempt
    call ClearEnt
    ld a, 1
    ld [wEnt + EO_ACTIVE], a
    call EntFromGen             ; wEnt position <- wGen (the ring tile)
    call Rand
    and 3
    ld [wEnt + EO_FACING], a    ; random initial facing
    ld a, EDIR_IDLE
    ld [wEnt + EO_DIR], a
    ld a, [wPoolIdx]
    ld de, wZombies
    jp CopyPoolOut             ; write into the slot (tail call)

; =============================================================================
; Alert / charge sequence (MODE_ALERT)
; -----------------------------------------------------------------------------
; Lives in ROMX bank 1 (the always-mapped default bank) to keep the near-full
; fixed ROM0 bank in budget. It only runs from the main overworld loop's alert
; branch, where bank 1 is mapped (UpdateSound restores it every frame), and every
; routine it calls is either exported ROM0 (GenTileType/IsSolid/CopyEntity*/...)
; or ROM0 (BattleTransition) — both reachable regardless of the mapped ROMX bank.
; =============================================================================
SECTION "Alert Code", ROMX, BANK[1]

; -----------------------------------------------------------------------------
; UpdateAlert: the spotted-zombie sequence. Nothing else runs while this mode is
; active — the player, the other zombies, the survivors and the spawner are all
; frozen (their updaters only run in the overworld branch) — so this handler owns
; the screen:
;   phase 1  hold the "!" bubble for EO_ALERT frames (the classic spotted beat),
;   phase 2  CHARGE: step straight at the player along the sight direction
;            (EO_FACING, which LOS already aimed at them) at the shuffle cadence,
;            animating the slide; when the tile ahead is the player's, fight.
; A watchdog (wChaseTimer) forces the battle if the charge ever stalls, so a
; stray entity parked on the (terrain-clear) sight line can't soft-lock it.
; -----------------------------------------------------------------------------
UpdateAlert::
    ld a, [wAlertZombie]
    call CopyEntityIn
    ; ease the visual step slide toward 0 each frame (UpdateZombieAI, which does
    ; this during normal wandering, isn't called in alert mode)
    ld a, [wEnt + EO_SLIDE]
    and a, a
    jr z, .noSlide
    dec a
    ld [wEnt + EO_SLIDE], a
.noSlide:
    ; --- phase 1: hold the "!" ---
    ld a, [wEnt + EO_ALERT]
    and a, a
    jr z, .chase
    dec a
    ld [wEnt + EO_ALERT], a
    jr .save
.chase:
    ; --- phase 2: charge the player ---
    ld hl, wChaseTimer
    dec [hl]
    jr z, .battle               ; watchdog: charge stalled -> just fight
    ld a, [wEnt + EO_TIMER]     ; throttle steps to the shuffle cadence (= slide window)
    and a, a
    jr z, .step
    dec a
    ld [wEnt + EO_TIMER], a
    jr .save
.step:
    ld a, ZOMBIE_STEP_DELAY
    ld [wEnt + EO_TIMER], a
    ; target = the tile one step ahead, along the sight direction
    call GenFromEnt
    ld a, [wEnt + EO_FACING]
    call StepGen
    call GenEqualsPlayer        ; ahead IS the player -> we're adjacent: fight
    jr z, .battle
    call GenTileType            ; else advance onto it if clear (the LOS line was
    call IsSolid                ; terrain-clear, but an entity could be parked on it)
    jr nz, .save
    call CheckZombieAt
    and a, a
    jr nz, .save
    call CheckNPCAt
    and a, a
    jr nz, .save
    call CheckCarAt             ; a charging zombie still can't overlap the car...
    and a, a
    jr nz, .save
    call CheckLootSolidAt       ; ...nor a crate/pot/chest (watchdog ends a stall)
    and a, a
    jr nz, .save
    call EntFromGen             ; commit the step toward the player
    ld a, [wEnt + EO_FACING]
    ld [wEnt + EO_SLIDEDIR], a
    ld a, ZOMBIE_STEP_DELAY
    ld [wEnt + EO_SLIDE], a
    ld a, [wEnt + EO_FRAME]
    xor a, 1
    ld [wEnt + EO_FRAME], a
.save:
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
