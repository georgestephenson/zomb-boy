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
; (10) chars so bag/equip columns align, then 0-terminated.
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
    xor a, a
    ld [wSaveDone], a
    ; clear every equip slot (nothing equipped)
    ld hl, wPartyEquip
    ld b, MAX_PARTY * EQUIP_SLOTS
.clrEquip:
    ld [hl+], a
    dec b
    jr nz, .clrEquip
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
