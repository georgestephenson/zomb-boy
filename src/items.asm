; =============================================================================
; items.asm — the item database + inventory helpers (menu.asm data slice).
;
; Every item has an id (ITEM_* in constants.inc), a category (ITYPE_*), and a
; charmap'd display name. Two parallel tables keep indexing a plain `id`:
;   ItemType  — one byte per id (the category)
;   ItemNames — one dw per id (pointer to a 0-terminated, space-padded name)
; Names are padded to ITEM_NAME_MAX so list columns line up.
; =============================================================================
INCLUDE "hardware.inc"
INCLUDE "include/constants.inc"
INCLUDE "include/charmap.inc"

SECTION "Items", ROM0

; Category per item id (indexed by ITEM_*). Keep in lockstep with ItemNames.
ItemType::
    db ITYPE_NONE       ; 0  ITEM_NONE
    db ITYPE_WEAPON     ; 1  BAT
    db ITYPE_WEAPON     ; 2  PISTOL
    db ITYPE_WEAPON     ; 3  KNIFE
    db ITYPE_ARMOR      ; 4  VEST
    db ITYPE_ARMOR      ; 5  HELMET
    db ITYPE_ACCESSORY  ; 6  AMULET
    db ITYPE_ACCESSORY  ; 7  WATCH
    db ITYPE_CONSUMABLE ; 8  GRENADE
    db ITYPE_CONSUMABLE ; 9  MEDKIT
    db ITYPE_KEY        ; 10 KEYCARD

; Name pointers (indexed by ITEM_*). Names are space-padded to ITEM_NAME_MAX
; (8) chars so bag/equip columns align, then 0-terminated.
ItemNames::
    dw NmNone, NmBat, NmPistol, NmKnife, NmVest, NmHelmet
    dw NmAmulet, NmWatch, NmGrenade, NmMedkit, NmKeycard

NmNone::    db "--------", 0
NmBat::     db "BAT     ", 0
NmPistol::  db "PISTOL  ", 0
NmKnife::   db "KNIFE   ", 0
NmVest::    db "VEST    ", 0
NmHelmet::  db "HELMET  ", 0
NmAmulet::  db "AMULET  ", 0
NmWatch::   db "WATCH   ", 0
NmGrenade:: db "GRENADE ", 0
NmMedkit::  db "MEDKIT  ", 0
NmKeycard:: db "KEYCARD ", 0

; -----------------------------------------------------------------------------
; GetItemType: A = item id -> A = its ITYPE_*. Clobbers HL, E.
; -----------------------------------------------------------------------------
GetItemType::
    ld e, a
    ld d, 0
    ld hl, ItemType
    add hl, de
    ld a, [hl]
    ret

; -----------------------------------------------------------------------------
; GetItemName: A = item id -> HL = its 0-terminated name string. Clobbers DE, A.
; -----------------------------------------------------------------------------
GetItemName::
    add a, a                   ; * 2 (dw table)
    ld e, a
    ld d, 0
    ld hl, ItemNames
    add hl, de
    ld a, [hl+]
    ld h, [hl]
    ld l, a
    ret

; -----------------------------------------------------------------------------
; InitInventory: boot-time party + bag + options defaults (call from Start).
; The party is just the player (Zomb Boy) with nothing equipped; the bag holds
; a small starting kit so every menu screen has something to show.
; -----------------------------------------------------------------------------
InitInventory::
    ld a, 1
    ld [wPartyCount], a         ; just the player to start
    ld [wOptMusic], a           ; music on by default (ClearRAM zeroed it)
    ld [wOptSfx], a             ; sound effects on by default (A is still 1 here)
    xor a, a
    ld [wSaveDone], a
    ; clear every equip slot (nothing equipped)
    ld hl, wPartyEquip
    ld b, MAX_PARTY * EQUIP_SLOTS
.clrEquip:
    ld [hl+], a
    dec b
    jr nz, .clrEquip
    ; every member starts LEVEL 1 with 0 XP (A is still 0 here)
    ld hl, wPartyXP
    ld b, MAX_PARTY * 2
.clrXP:
    ld [hl+], a
    dec b
    jr nz, .clrXP
    ld hl, wPartyLevel
    ld b, MAX_PARTY
    ld a, START_LEVEL
.setLvl:
    ld [hl+], a
    dec b
    jr nz, .setLvl
    xor a, a
    ; clear the bag
    ld hl, wBag
    ld b, BAG_MAX * 2
.clrBag:
    ld [hl+], a
    dec b
    jr nz, .clrBag
    ; starting kit: (item id, count) pairs, terminated by ITEM_NONE
    ld hl, StartKit
.kit:
    ld a, [hl+]
    and a, a
    ret z                       ; ITEM_NONE terminator
    ld b, a                     ; item id
    ld a, [hl+]
    ld c, a                     ; count
    push hl                     ; AddItem clobbers HL (bag pointer)
    call AddItem
    pop hl
    jr .kit

; Starting inventory: {id, count} pairs, 0-terminated.
StartKit:
    db ITEM_BAT, 1
    db ITEM_PISTOL, 1
    db ITEM_VEST, 1
    db ITEM_HELMET, 1
    db ITEM_AMULET, 1
    db ITEM_GRENADE, 3
    db ITEM_MEDKIT, 2
    db ITEM_KEYCARD, 1
    db ITEM_NONE                ; terminator

; -----------------------------------------------------------------------------
; AddItem: add C of item id B to the bag (saturating per stack at BAG_STACK_MAX).
; Stacks by id; on a full bag with no existing stack the item is dropped.
; Clobbers A, DE, HL (preserves B/C for the caller's loop use is NOT guaranteed).
; -----------------------------------------------------------------------------
AddItem::
    ; find an existing stack of B
    ld hl, wBag
    ld d, BAG_MAX
.find:
    ld a, [hl]
    cp b
    jr z, .have
    inc hl
    inc hl
    dec d
    jr nz, .find
    ; no existing stack: find the first empty slot
    ld hl, wBag
    ld d, BAG_MAX
.empty:
    ld a, [hl]
    and a, a
    jr z, .newSlot
    inc hl
    inc hl
    dec d
    jr nz, .empty
    ret                         ; bag full, no matching stack: drop it
.newSlot:
    ld a, b
    ld [hl+], a                 ; write the id, HL -> count cell
    xor a, a
    ld [hl], a                  ; count starts 0, .have adds C below
    jr .addCount
.have:
    inc hl                      ; HL -> count cell
.addCount:
    ld a, [hl]
    add a, c
    jr c, .cap                  ; overflowed a byte -> cap
    cp BAG_STACK_MAX + 1
    jr c, .store
.cap:
    ld a, BAG_STACK_MAX
.store:
    ld [hl], a
    ret

; -----------------------------------------------------------------------------
; RemoveOneItem: remove one unit of item id A from the bag. If the stack hits
; zero it's cleared and the bag compacted so lists stay gap-free. Clobbers all.
; -----------------------------------------------------------------------------
RemoveOneItem::
    ld b, a
    ld hl, wBag
    ld d, BAG_MAX
.find:
    ld a, [hl]
    cp b
    jr z, .found
    inc hl
    inc hl
    dec d
    jr nz, .find
    ret                         ; not present
.found:
    inc hl                      ; HL -> count
    ld a, [hl]
    dec a
    ld [hl], a
    ret nz                      ; stack still non-empty
    dec hl                      ; HL -> id cell; empty the stack
    xor a, a
    ld [hl], a
    inc hl
    ld [hl], a
    ; fall through to compact the bag (close the gap)
; CompactBag: slide non-empty stacks forward, zero the freed tail. Slot-counted
; (no address arithmetic) so it's safe wherever wBag lands. Clobbers all.
CompactBag:
    ld hl, wBag
    ld de, wBag
    ld c, BAG_MAX               ; slots left to scan
    ld b, 0                     ; slots written so far
.scan:
    ld a, [hl]
    and a, a
    jr z, .skip                 ; empty stack: skip (don't copy)
    ld a, [hl+]
    ld [de], a
    inc de
    ld a, [hl+]
    ld [de], a
    inc de
    inc b
    dec c
    jr nz, .scan
    jr .pad
.skip:
    inc hl
    inc hl
    dec c
    jr nz, .scan
.pad:
    ; zero the (BAG_MAX - b) trailing stacks (2 bytes each) from DE
    ld a, BAG_MAX
    sub b
    ret z
    add a, a                    ; * 2 bytes
    ld b, a
    xor a, a
.padLoop:
    ld [de], a
    inc de
    dec b
    jr nz, .padLoop
    ret

; =============================================================================
; Party levels / experience (the player is member 0). Levels run 1..MAX_LEVEL;
; each costs exponentially more XP than the last (LevelXP is the cumulative
; threshold table, indexed by the level you're climbing FROM). Battles grant XP
; (LATER) via AddPlayerXP; RecalcLevel re-derives the level from the XP total.
; =============================================================================
; AddPlayerXP: add BC (16-bit) experience to member 0, saturating at $FFFF, then
; re-derive the level. Call this from combat once battles land. Clobbers all.
AddPlayerXP::
    ld a, [wPartyXP]
    add a, c
    ld c, a
    ld a, [wPartyXP+1]
    adc b
    ld b, a
    jr c, .cap                 ; > $FFFF -> pin the total
    ld a, c
    ld [wPartyXP], a
    ld a, b
    ld [wPartyXP+1], a
    jr RecalcLevel
.cap:
    ld a, $FF
    ld [wPartyXP], a
    ld [wPartyXP+1], a
    ; fall through to RecalcLevel

; RecalcLevel: raise member 0's level while its XP meets the next threshold.
; Idempotent (safe to call from a display build). Clobbers A, BC, DE, HL.
RecalcLevel::
    ld a, [wPartyXP]
    ld e, a
    ld a, [wPartyXP+1]
    ld d, a                    ; DE = current XP
    ld a, [wPartyLevel]
    ld c, a                    ; C = level
.loop:
    ld a, c
    cp MAX_LEVEL
    jr nc, .done               ; already capped
    dec a                      ; entry index = (level-1); index 0 = reach level 2
    add a, a                   ; * 2 (dw table)
    ld l, a
    ld h, 0
    push de
    ld de, LevelXP
    add hl, de
    pop de
    ld a, [hl+]
    ld h, [hl]
    ld l, a                    ; HL = XP needed to reach level+1
    ld a, e
    sub l
    ld a, d
    sbc h
    jr c, .done                ; XP < threshold: stay
    inc c                      ; level up and check the next threshold
    jr .loop
.done:
    ld a, c
    ld [wPartyLevel], a
    ret

; XPToNext: -> HL = XP still needed for member 0's next level (0 at MAX_LEVEL),
; and carry SET if already at MAX_LEVEL (no next). Clobbers A, BC, DE, HL.
XPToNext::
    ld a, [wPartyLevel]
    cp MAX_LEVEL
    jr nc, .maxed
    dec a
    add a, a
    ld l, a
    ld h, 0
    ld de, LevelXP
    add hl, de
    ld a, [hl+]
    ld h, [hl]
    ld l, a                    ; HL = threshold to reach level+1
    ld a, [wPartyXP]
    ld c, a
    ld a, [wPartyXP+1]
    ld b, a                    ; BC = XP
    ld a, l
    sub c
    ld l, a
    ld a, h
    sbc b
    ld h, a                    ; HL = threshold - XP
    and a, a                   ; clear carry
    ret
.maxed:
    ld hl, 0
    scf
    ret

; GetStat: A = STAT_* -> A = member 0's value for it, saturating at 255.
; A stat is StatBase[id] + (level-1)*StatGrow[id]. Clobbers BC, DE, HL.
GetStat::
    ld e, a
    ld d, 0
    ld hl, StatBase
    add hl, de
    ld c, [hl]                 ; C = base value
    ld hl, StatGrow
    add hl, de
    ld b, [hl]                 ; B = per-level growth
    ld a, [wPartyLevel]
    dec a                      ; levels above 1
    jr z, .done                ; level 1: value is just the base
    ld e, a                    ; E = growth iterations
.loop:
    ld a, c
    add a, b
    jr c, .sat                 ; overflowed a byte -> saturate
    ld c, a
    dec e
    jr nz, .loop
.done:
    ld a, c
    ret
.sat:
    ld a, 255
    ret

; The progression tables live in ROMX bank 1 (the always-mapped default bank,
; same one the dialogue data uses) to keep the fixed ROM0 bank from overflowing.
; RecalcLevel/GetStat only read them from the overworld/menu, where bank 1 is
; mapped, so a plain read reaches them with no bank switch.
SECTION "Party Data", ROMX, BANK[1]

; StatBase / StatGrow: member 0's level-1 stat points and per-level growth,
; indexed by STAT_* (Strength, Dexterity, Endurance, Immunity, Accuracy, Speed).
StatBase:
    db 6, 4, 8, 5, 5, 6
StatGrow:
    db 1, 1, 2, 1, 1, 1

; LevelXP: cumulative experience needed to REACH each level, indexed by
; (level-1) — entry 0 = XP for level 2, entry 97 = XP for level 99. Exponential
; (~1.06x per step, from a base of 5), capped so the whole climb fits 16 bits.
; Generated; keep monotonic if regenerated.
LevelXP:
    dw 5, 10, 16, 22, 28, 35, 42, 50
    dw 58, 66, 75, 84, 94, 105, 116, 128
    dw 141, 154, 168, 183, 199, 216, 234, 253
    dw 273, 294, 317, 341, 367, 394, 423, 453
    dw 485, 519, 555, 593, 634, 677, 723, 772
    dw 823, 878, 936, 997, 1062, 1131, 1204, 1281
    dw 1363, 1450, 1542, 1640, 1743, 1853, 1969, 2092
    dw 2223, 2361, 2508, 2664, 2829, 3004, 3189, 3385
    dw 3593, 3814, 4048, 4296, 4559, 4838, 5133, 5446
    dw 5778, 6130, 6503, 6898, 7317, 7761, 8232, 8731
    dw 9260, 9821, 10415, 11045, 11713, 12421, 13171, 13966
    dw 14809, 15703, 16650, 17654, 18718, 19846, 21042, 22310
    dw 23654, 25078
