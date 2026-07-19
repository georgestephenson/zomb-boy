; =============================================================================
; npc.asm — survivor NPCs: spawning, world rendering, talk trigger.
;
; Survivors (docs/design/05) stand still in the world — no AI. Walk up, face
; one and press A to open the dialogue screen (talk.asm). They reuse the
; 16-byte entity struct with EO_PERSONA / EO_AFFIN in the spare fields;
; affinity lives here so the relationship persists between conversations.
; =============================================================================
INCLUDE "hardware.inc"
INCLUDE "include/constants.inc"

SECTION "NPC Code", ROM0

; Spawn offsets (signed dx,dy in tiles) from the player's start, one per
; persona, all distinct from ZombieSpawnTable so nobody stacks at boot.
; NPC 0 stands one tile BELOW the start — the guaranteed easy first encounter
; (test_talk.py bumps into it), placed off the walk-right corridor the boot
; hygiene test drives through.
NPCSpawnTable:
    db  0,  1
    db -5, -2
    db  0,  6
    db  7,  4
    db -3, -8
    db  9, -5
    db -8,  7
    db 13,  2
    db  5, 10
    db -2, 12

; -----------------------------------------------------------------------------
; InitNPCs: clear the pool, then place one survivor per persona near the
; player start (offset from NPCSpawnTable, nudged right to a passable tile —
; same scheme as InitZombies).
; -----------------------------------------------------------------------------
InitNPCs::
    ld hl, wNPCs
    ld b, MAX_NPCS * ENT_SIZE      ; 80 bytes < 256 -> 8-bit counter
    xor a, a
.clear:
    ld [hl+], a
    dec b
    jr nz, .clear
    ld [wNPCIdx], a            ; a = 0
.place:
    ; DE = &NPCSpawnTable[idx*2]
    ld a, [wNPCIdx]
    add a, a
    ld e, a
    ld d, 0
    ld hl, NPCSpawnTable
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
    ; nudge to a passable tile (up to 8 tiles right — the biome world is
    ; denser with solids than the old scatter was)
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
    ld a, EFACE_DOWN
    ld [wEnt + EO_FACING], a
    ld a, [wNPCIdx]
    ld [wEnt + EO_PERSONA], a  ; one persona per spawn slot
    ld a, AFFIN_START
    ld [wEnt + EO_AFFIN], a
    ld a, [wNPCIdx]
    ld de, wNPCs
    call CopyPoolOut
    ld a, [wNPCIdx]
    inc a
    ld [wNPCIdx], a
    cp MAX_NPCS
    jp c, .place               ; loop body is >127 bytes, needs JP
    ret

; -----------------------------------------------------------------------------
; SpawnNPC: the survivor half of the dynamic spawn manager (entity.asm
; UpdateSpawns calls this when the survivor pool is below NPC_SPAWN_TARGET).
; Places one survivor with a RANDOM persona in a free NPC slot on the spawn ring.
; A fresh survivor is someone you haven't met, so affinity starts neutral and
; EO_MET stays 0 (ClearEnt zeroed it) — the first hello is a stranger's.
; -----------------------------------------------------------------------------
SpawnNPC::
    ld de, wNPCs
    ld b, MAX_NPCS
    call FindFreeSlot
    ret nc
    ld [wPoolIdx], a           ; stash the free slot index
    call PickRingTile
    ret nc                     ; ring tile blocked -> skip this attempt
    call ClearEnt
    ld a, 1
    ld [wEnt + EO_ACTIVE], a
    call EntFromGen            ; wEnt position <- wGen (the ring tile)
    ld a, EFACE_DOWN
    ld [wEnt + EO_FACING], a
    call Rand
    and 15
    cp PERSONA_COUNT
    jr c, .persok
    sub PERSONA_COUNT          ; fold 10..15 down into 0..5
.persok:
    ld [wEnt + EO_PERSONA], a
    ld a, AFFIN_START
    ld [wEnt + EO_AFFIN], a
    ld a, [wPoolIdx]
    ld de, wNPCs
    jp CopyPoolOut             ; write into the slot (tail call)

; -----------------------------------------------------------------------------
; CheckNPCAt: is an active NPC on tile (wGenX, wGenY)? A = index+1, or 0 if
; free. Scans wNPCs directly (doesn't touch wEnt), so it's safe from player
; and zombie movement code alike.
; -----------------------------------------------------------------------------
CheckNPCAt::
    ld c, MAX_NPCS
    ld hl, wNPCs               ; hl -> EO_ACTIVE of entity 0
.loop:
    ld a, [hl]                 ; EO_ACTIVE
    and a, a
    jr z, .next
    push hl
    inc hl                     ; EO_WXLO
    ld a, [wGenX]
    cp [hl]
    jr nz, .miss
    inc hl                     ; EO_WXHI
    ld a, [wGenX+1]
    cp [hl]
    jr nz, .miss
    inc hl                     ; EO_WYLO
    ld a, [wGenY]
    cp [hl]
    jr nz, .miss
    inc hl                     ; EO_WYHI
    ld a, [wGenY+1]
    cp [hl]
    jr nz, .miss
    pop hl
    ld a, MAX_NPCS + 1
    sub c                      ; = index + 1 (c counts down from MAX)
    ret
.miss:
    pop hl
.next:
    ld de, ENT_SIZE
    add hl, de
    dec c
    jr nz, .loop
    xor a, a                   ; free
    ret

; -----------------------------------------------------------------------------
; CheckTalkStart: overworld only — if A was just pressed and a survivor stands
; on the tile the player faces, open the conversation (switches to MODE_TALK).
; -----------------------------------------------------------------------------
CheckTalkStart::
    ld a, [wInCar]
    and a
    ret nz                     ; no chatting from the driver's seat
    ld a, [wNewKeys]
    and PAD_A
    ret z
    ; wGen = the tile in front of the player
    ld a, [wPlayerWX]
    ld [wGenX], a
    ld a, [wPlayerWX+1]
    ld [wGenX+1], a
    ld a, [wPlayerWY]
    ld [wGenY], a
    ld a, [wPlayerWY+1]
    ld [wGenY+1], a
    ld a, [wFacing]
    call StepGen
    call CheckNPCAt
    and a, a
    ret z
    dec a                      ; index of the survivor we're facing
    jp EnterTalk               ; talk.asm takes over (tail call)

; =============================================================================
; Rendering (overworld): hide the NPC slots, then draw each active on-screen
; survivor — the same pattern as DrawZombies.
; =============================================================================
DrawNPCs::
    ld hl, wShadowOAM + OAM_NPC0 * 4
    ld b, MAX_NPCS
    xor a, a
.hide:
    ld [hl], a                 ; Y = 0 -> off-screen
    inc hl
    inc hl
    inc hl
    inc hl
    dec b
    jr nz, .hide
    xor a, a
    ld [wNPCIdx], a
.loop:
    ld a, [wNPCIdx]
    ld de, wNPCs
    call EntAddr
    ld a, [hl]                 ; EO_ACTIVE: check in the pool so a free slot
    and a, a                   ; (most of them, once the far ones cull) skips
    jr z, .next                ; the 16-byte struct copy entirely
    call CopyEntHL
    call EntScreenPos          ; -> A=visible, wScrX/wScrY set
    and a, a
    jr z, .next
    ; HL = shadow OAM slot = wShadowOAM + (OAM_NPC0 + idx)*4
    ld a, [wNPCIdx]
    add a, OAM_NPC0
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
    call NPCTileAttr           ; -> B=tile, C=attr
    ld a, b
    ld [hl+], a
    ld a, c
    ld [hl], a
.next:
    ld a, [wNPCIdx]
    inc a
    ld [wNPCIdx], a
    cp MAX_NPCS
    jr c, .loop
    ret

; NPCTileAttr: B = tile id, C = OAM attribute for wEnt. Each persona has its
; own 3-tile world sprite (gfx.asm PersonaTiles): tile = TILE_PSURV_BASE +
; persona*3 + dir (0 down / 1 up / 2 side). The OBJ palette comes from the
; persona record (PO_PAL, 3..7) — with more personas than free hardware
; palettes, tints are shared by design. Preserves HL: DrawNPCs holds its
; shadow-OAM write pointer there (regression: the record lookup once
; clobbered it and NPCs drew as ghost grass tiles).
NPCTileAttr::
    push hl
    ld a, [wEnt + EO_PERSONA]
    call PersonaPtr            ; clobbers DE and HL
    ld de, PO_PAL
    add hl, de
    ld c, [hl]
    pop hl
    ld a, [wEnt + EO_PERSONA]
    ld b, a
    add a, a
    add a, b                   ; persona * 3
    add a, TILE_PSURV_BASE
    ld b, a                    ; B = this persona's "down" tile
    ld a, [wEnt + EO_FACING]
    cp EFACE_UP
    jr z, .up
    cp EFACE_LEFT
    jr z, .left
    cp EFACE_RIGHT
    jr z, .right
    ret                        ; down
.up:
    inc b
    ret
.left:
    ld a, c
    or OAMF_XFLIP
    ld c, a
    ; fall through
.right:
    inc b
    inc b
    ret
