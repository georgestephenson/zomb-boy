; =============================================================================
; loot.asm — world loot: dynamic pickups + breakable containers.
;
; Loot objects reuse the 16-byte entity struct (EO_ACTIVE / EO_WXLO..EO_WYHI,
; with the kind in EO_KIND) and the SAME dynamic spawn manager as the zombies
; and survivors (entity.asm's SetPool/CullFarPool/CountActivePool/FindFreeSlot/
; PickRingTile). So loot appears in a ring just outside the visible window as
; you explore, biome-flavoured (apples in forest, beans in city), and despawns
; once it strays too far behind — fresh every time, from the dynamic RNG.
;
; Two families:
;   * FOOD (apple/beans, non-solid): grabbed by walking onto them, or by pressing
;     A while facing them. They restore hunger straight into the food meter.
;   * CONTAINERS (crate/pot/chest, SOLID): block movement like the car; press A
;     facing one to break/open it. Crates & pots roll somewhat-rare loot (and the
;     ration pack — large food); chests roll the valuable/rare items. Gear drops
;     into the bag (items.asm AddItem); a ration is eaten on the spot.
; =============================================================================
INCLUDE "hardware.inc"
INCLUDE "include/constants.inc"
INCLUDE "include/charmap.inc"       ; toast strings assemble to font tile ids

SECTION "Loot Code", ROM0

; Starting loot offsets from the player spawn: FOOD ONLY (non-solid), so nothing
; blocks the boot walk paths the movement/collision tests drive through. A slot
; whose tile is solid is simply skipped (no far nudge — that could push loot past
; the cull radius and trip a respawn mid-test). Containers only ever appear via
; the dynamic ring spawn, out where you explore.
LootSpawnTable:
    db  3, -2, LOOT_APPLE
    db -4,  1, LOOT_BEANS
    db  2,  4, LOOT_APPLE
    db -3, -4, LOOT_BEANS
    db  5,  1, LOOT_APPLE
    db -5,  3, LOOT_BEANS
    db  1, -5, LOOT_APPLE
    db  4,  4, LOOT_BEANS
DEF LOOT_SEED_COUNT EQU 8

; -----------------------------------------------------------------------------
; InitLoot: clear the pool, seed the starting food, arm the respawn timer.
; -----------------------------------------------------------------------------
InitLoot::
    ld hl, wLoot
    ld b, MAX_LOOT * ENT_SIZE      ; 128 bytes < 256 -> 8-bit counter
    xor a, a
.clear:
    ld [hl+], a
    dec b
    jr nz, .clear
    ld a, LOOT_SPAWN_PERIOD
    ld [wLootSpawnTimer], a
    xor a, a
    ld [wPoolIdx], a               ; loop index (WRAM: survives Gen/Add calls)
.place:
    ; HL -> LootSpawnTable[idx * 3]; read dx, dy, kind into WRAM temps first
    ; (AddSByteAt16 / GenTileType clobber HL and most registers).
    ld a, [wPoolIdx]
    ld b, a
    add a, a
    add a, b                       ; idx * 3
    ld e, a
    ld d, 0
    ld hl, LootSpawnTable
    add hl, de
    ld a, [hl+]
    ld [wLootDX], a
    ld a, [hl+]
    ld [wLootDY], a
    ld a, [hl]
    ld [wLootKind], a
    ; wGen = player + (dx, dy)
    ld a, [wPlayerWX]
    ld [wGenX], a
    ld a, [wPlayerWX+1]
    ld [wGenX+1], a
    ld a, [wLootDX]
    ld hl, wGenX
    call AddSByteAt16
    ld a, [wPlayerWY]
    ld [wGenY], a
    ld a, [wPlayerWY+1]
    ld [wGenY+1], a
    ld a, [wLootDY]
    ld hl, wGenY
    call AddSByteAt16
    ; only place on passable ground; else skip this slot (no far nudge)
    call GenTileType
    call IsSolid
    jr nz, .next
    call ClearEnt
    ld a, 1
    ld [wEnt + EO_ACTIVE], a
    call EntFromGen
    ld a, [wLootKind]
    ld [wEnt + EO_KIND], a
    ld a, [wPoolIdx]
    ld de, wLoot
    call CopyPoolOut
.next:
    ld a, [wPoolIdx]
    inc a
    ld [wPoolIdx], a
    cp LOOT_SEED_COUNT
    jr c, .place
    ret

; -----------------------------------------------------------------------------
; UpdateLootSpawns: cull far loot, then (throttled) respawn toward LOOT_TARGET.
; Only touches the RNG when it actually spawns, so it's inert (and perturbs
; nothing) while the pool is at target near the spawn — same discipline as the
; entity manager, which is why the existing suite stays deterministic.
; -----------------------------------------------------------------------------
UpdateLootSpawns::
    ld hl, wLoot
    ld b, MAX_LOOT
    call SetPool
    call CullFarPool
    ld hl, wLootSpawnTimer
    dec [hl]
    ret nz
    ld a, LOOT_SPAWN_PERIOD
    ld [wLootSpawnTimer], a
    ld de, wLoot
    ld b, MAX_LOOT
    call CountActivePool
    cp LOOT_TARGET
    ret nc                         ; enough loot -> no spawn, no RNG consumed
    ; fall through to SpawnLoot

; SpawnLoot: place one loot object (kind chosen from the ring tile's biome) in a
; free pool slot on the spawn ring.
SpawnLoot:
    ld de, wLoot
    ld b, MAX_LOOT
    call FindFreeSlot
    ret nc
    ld [wPoolIdx], a               ; stash the free slot index
    call PickRingTile
    ret nc                         ; ring tile blocked -> skip this attempt
    call PickLootKind              ; A = LOOT_* from the tile's biome + a roll
    ld [wLootKind], a
    call ClearEnt
    ld a, 1
    ld [wEnt + EO_ACTIVE], a
    call EntFromGen                ; wEnt position <- wGen (the ring tile)
    ld a, [wLootKind]
    ld [wEnt + EO_KIND], a
    ld a, [wPoolIdx]
    ld de, wLoot
    jp CopyPoolOut                 ; write into the slot (tail call)

; PickLootKind: A = a LOOT_* kind for the tile in wGenX/wGenY. Forest tiles tend
; to grow apples, city tiles cans of beans; everywhere spills the odd container
; (crate/pot common, chest rare). Uses the dynamic RNG (Rand), NOT the terrain
; hash, so the same ground yields different loot each visit.
PickLootKind:
    ; sample the biome at the 2x2 block anchor (matches the terrain pass)
    ld a, [wGenX]
    and $FE
    ld [wBiX], a
    ld a, [wGenX+1]
    ld [wBiX+1], a
    ld a, [wGenY]
    and $FE
    ld [wBiY], a
    ld a, [wGenY+1]
    ld [wBiY+1], a
    call CalcBiome                 ; A = BIOME_*
    cp BIOME_FOREST
    jr z, .forest
    cp BIOME_CITY
    jr z, .city
    jr .container                  ; plains / marsh -> containers only
.forest:
    call Rand
    and 1
    jr z, .apple                   ; ~half of forest loot is apples
    jr .container
.city:
    call Rand
    and 1
    jr z, .beans                   ; ~half of city loot is beans
    ; fall through to container
.container:
    call Rand
    ld b, a
    and 7
    jr nz, .notChest
    ld a, LOOT_CHEST               ; ~1/8 -> treasure chest
    ret
.notChest:
    ld a, b
    and 1
    jr z, .crate
    ld a, LOOT_POT
    ret
.crate:
    ld a, LOOT_CRATE
    ret
.apple:
    ld a, LOOT_APPLE
    ret
.beans:
    ld a, LOOT_BEANS
    ret

; =============================================================================
; Interaction — grab food underfoot, open a faced container.
; =============================================================================
; CheckLoot: overworld helper (called each frame). Auto-collects a food pickup on
; the player's own tile, then — on a fresh A press — collects/opens whatever loot
; sits on the tile the player faces (consuming the press so talk doesn't fire).
CheckLoot::
    ld a, [wInCar]
    and a, a
    ret nz                         ; no scavenging from the driver's seat
    ; --- auto-collect food on the player's own tile ---
    call GenFromPlayerLoot
    call LootIndexAt
    and a, a
    jr z, .press
    dec a
    ld c, a                        ; c = loot index
    call LootKindOf                ; A = its kind
    cp LOOT_CRATE
    jr nc, .press                  ; a container needs A (don't auto-open it)
    ld a, c
    call CollectLoot               ; food underfoot -> grab it
.press:
    ld a, [wNewKeys]
    and PAD_A
    ret z
    ; --- A pressed: the tile the player faces ---
    call GenFromPlayerLoot
    ld a, [wFacing]
    call StepGen
    call LootIndexAt
    and a, a
    ret z
    dec a
    call CollectLoot
    ld hl, wNewKeys
    res 4, [hl]                    ; consume A (PAD_A = bit 4) — not a talk press
    ret

; GenFromPlayerLoot: wGenX/wGenY <- the player's world tile (local copy; the
; entity module's GenFromPlayer is file-local there).
GenFromPlayerLoot:
    ld a, [wPlayerWX]
    ld [wGenX], a
    ld a, [wPlayerWX+1]
    ld [wGenX+1], a
    ld a, [wPlayerWY]
    ld [wGenY], a
    ld a, [wPlayerWY+1]
    ld [wGenY+1], a
    ret

; CollectLoot: A = loot index. Apply its effect, free the slot, blip + HUD.
CollectLoot:
    ld [wPoolIdx], a
    ld de, wLoot
    call CopyPoolIn                ; wEnt <- loot[idx]
    ld a, [wEnt + EO_KIND]
    call GrantLoot                 ; apply the effect (may add food / bag items)
    xor a, a
    ld [wEnt + EO_ACTIVE], a       ; consume the object
    ld a, [wPoolIdx]
    ld de, wLoot
    call CopyPoolOut
    call ComposeHUD                ; food may have changed -> refresh the row
    ld a, 1
    ld [wHUDDirty], a
    jp PlaySplash                  ; a short pickup blip (tail call)

; GrantLoot: A = LOOT_* kind. Food goes to the meter; containers roll their table.
GrantLoot:
    cp LOOT_APPLE
    jr z, .apple
    cp LOOT_BEANS
    jr z, .beans
    cp LOOT_CHEST
    jr z, .chest
    ; crate / pot -> somewhat-rare table (with a chance of a ration pack)
    call Rand
    and 3
    jr nz, .crateGear
    ld a, RATION_FOOD              ; 1/4 -> ration pack (large food)
    call AddFood
    ld de, MsgRation
    jp ShowNotice
.crateGear:
    call Rand
    and 7
    ld hl, CrateGear
    jr .grantGear
.chest:
    call Rand
    and 7
    ld hl, ChestGear
.grantGear:
    ld e, a
    ld d, 0
    add hl, de
    ld a, [hl]                     ; item id
    push af                        ; keep it for the toast (AddItem clobbers regs)
    ld b, a
    ld c, 1                        ; one of it
    call AddItem                   ; into the bag
    pop af                         ; A = item id
    jp ShowNoticeItem              ; "GOT <name>"
.apple:
    ld a, APPLE_FOOD
    call AddFood
    ld de, MsgApple
    jp ShowNotice
.beans:
    ld a, BEANS_FOOD
    call AddFood
    ld de, MsgBeans
    jp ShowNotice

; Toast strings (charmap'd to font tile ids).
MsgApple:  db "ATE APPLE", 0
MsgBeans:  db "ATE BEANS", 0
MsgRation: db "ATE RATION", 0

; AddFood: A = amount. Saturating add to the food meter (caps at METER_MAX).
AddFood:
    ld b, a
    ld a, [wFood]
    add a, b
    jr c, .cap
    cp METER_MAX + 1
    jr c, .store
.cap:
    ld a, METER_MAX
.store:
    ld [wFood], a
    ret

; Container loot tables (indexed by Rand & 7). Crates/pots spill everyday gear;
; chests hold the valuable/rare picks.
CrateGear:
    db ITEM_BAT, ITEM_KNIFE, ITEM_VEST, ITEM_HELMET
    db ITEM_GRENADE, ITEM_MEDKIT, ITEM_WATCH, ITEM_BAT
ChestGear:
    db ITEM_PISTOL, ITEM_AMULET, ITEM_KEYCARD, ITEM_WATCH
    db ITEM_PISTOL, ITEM_AMULET, ITEM_MEDKIT, ITEM_GRENADE

; =============================================================================
; Occupancy / collision queries
; =============================================================================
; LootIndexAt: is an active loot object on tile (wGenX, wGenY)? A = index+1, or
; 0 if none. Scans wLoot directly (doesn't touch wEnt).
LootIndexAt::
    ld c, MAX_LOOT
    ld hl, wLoot
.loop:
    ld a, [hl]                     ; EO_ACTIVE
    and a, a
    jr z, .next
    push hl
    inc hl
    ld a, [wGenX]
    cp [hl]
    jr nz, .miss
    inc hl
    ld a, [wGenX+1]
    cp [hl]
    jr nz, .miss
    inc hl
    ld a, [wGenY]
    cp [hl]
    jr nz, .miss
    inc hl
    ld a, [wGenY+1]
    cp [hl]
    jr nz, .miss
    pop hl
    ld a, MAX_LOOT + 1
    sub c                          ; = index + 1
    ret
.miss:
    pop hl
.next:
    ld de, ENT_SIZE
    add hl, de
    dec c
    jr nz, .loop
    xor a, a
    ret

; CheckLootAt: A = 1 if any active loot occupies (wGenX, wGenY), else 0.
CheckLootAt::
    call LootIndexAt
    and a, a
    ret z
    ld a, 1
    ret

; CheckLootSolidAt: A = 1 if a SOLID loot object (crate/pot/chest) occupies
; (wGenX, wGenY), else 0. Food is non-solid, so you can walk onto it.
CheckLootSolidAt::
    call LootIndexAt
    and a, a
    ret z
    dec a
    ld c, a
    call LootKindOf
    cp LOOT_CRATE
    jr c, .soft                    ; apple / beans -> not solid
    ld a, 1
    ret
.soft:
    xor a, a
    ret

; LootKindOf: C = loot index -> A = its EO_KIND. Clobbers HL, DE.
LootKindOf:
    ld a, c
    ld l, a
    ld h, 0
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl                     ; index * 16
    ld de, wLoot + EO_KIND
    add hl, de
    ld a, [hl]
    ret

; =============================================================================
; Rendering — hide the loot slots, then draw each active, on-screen object.
; Mirrors DrawNPCs: EntScreenPos does the visibility + camera-lag math.
; =============================================================================
DrawLoot::
    ld hl, wShadowOAM + OAM_LOOT * 4
    ld b, MAX_LOOT
    xor a, a
.hide:
    ld [hl], a                     ; Y = 0 -> off-screen
    inc hl
    inc hl
    inc hl
    inc hl
    dec b
    jr nz, .hide
    xor a, a
    ld [wPoolIdx], a
.loop:
    ld a, [wPoolIdx]
    ld de, wLoot
    call EntAddr
    ld a, [hl]                     ; EO_ACTIVE: check in the pool so a free
    and a, a                       ; slot skips the 16-byte struct copy
    jr z, .next
    call CopyEntHL
    call EntScreenPos              ; -> A = visible, wScrX/wScrY set
    and a, a
    jr z, .next
    ; HL = shadow OAM slot = wShadowOAM + (OAM_LOOT + idx) * 4
    ld a, [wPoolIdx]
    add a, OAM_LOOT
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
    ; tile + attr from the kind (HL now at the tile byte)
    push hl
    ld a, [wEnt + EO_KIND]
    ld e, a
    ld d, 0
    ld hl, LootTile
    add hl, de
    ld b, [hl]                     ; tile id
    ld hl, LootPal
    add hl, de
    ld c, [hl]                     ; OAM attr (OBJ palette)
    pop hl
    ld a, b
    ld [hl+], a
    ld a, c
    ld [hl], a
.next:
    ld a, [wPoolIdx]
    inc a
    ld [wPoolIdx], a
    cp MAX_LOOT
    jr c, .loop
    ret

; Per-kind sprite tile + OBJ palette (indexed by LOOT_*). Loot shares the
; existing OBJ palettes (all 8 are already spoken for): apple on the player's
; red (0), beans/chest on the amber bubble (2), crate/pot on the zombie's brown
; (1). On DMG these collapse to the grey ramp, still legible by shape.
LootTile:
    db TILE_LOOT_APPLE, TILE_LOOT_BEANS, TILE_LOOT_CRATE, TILE_LOOT_POT, TILE_LOOT_CHEST
LootPal:
    db 0, 2, 1, 1, 2
