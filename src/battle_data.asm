; =============================================================================
; battle_data.asm — weapon / skill / zombie-type tables (docs/design/04).
;
; Small, additive data rows: a new weapon, skill or zombie type is one more
; record here (and, for a zombie, a portrait + a ZombiePortraitTable entry) —
; the combat engine in battle.asm never changes. Each table is a list of `dw`
; pointers to fixed-layout records (offsets in constants.inc: WO_*/SO_*/ZO_*).
;
; ROMX BANK[1] — the default-mapped bank (shared with song + dialogue data),
; read only while battle.asm runs. The enemy-portrait load (battle.asm) switches
; to BANK[2] and restores bank 1, so these tables are always read with bank 1
; mapped.
; =============================================================================
INCLUDE "include/constants.inc"
INCLUDE "include/charmap.inc"

; FRAGMENT "Battle": merges into the battle engine's floating bank (battle.asm),
; so the engine reads these tables without a bank switch. (Was BANK[1], but that
; bank is full and the engine no longer lives there.)
SECTION FRAGMENT "Battle", ROMX

; --- Weapons (2 equipped in v0; the equip menu is LATER) ---------------------
; A fast/weak vs slow/strong pair — the crosshair supplies accuracy, so the
; trade-off here is damage vs crit potential.
WeaponTable::
    dw Wpn_Knife
    dw Wpn_Bat
Wpn_Knife:                          ; fast, low base, modest crit
    db 9                            ; WO_DMG
    db 6                            ; WO_CRIT (extra on a green lock)
    db 3                            ; WO_SPD
    dw WpnName_Knife                ; WO_NAME
Wpn_Bat:                            ; slow, heavy, big crit
    db 15                           ; WO_DMG
    db 12                           ; WO_CRIT
    db 1                            ; WO_SPD
    dw WpnName_Bat
WpnName_Knife: db "KNIFE", 0
WpnName_Bat:   db "BAT", 0

; --- Skills (2 equipped) -----------------------------------------------------
; One heal, one guaranteed hit — the defensive/offensive split from the design.
SkillTable::
    dw Skl_Bandage
    dw Skl_Aimed
Skl_Bandage:
    db SK_HEAL                      ; SO_KIND
    db 30                           ; SO_POWER (HP restored)
    db 3                            ; SO_CD (player turns)
    dw SklName_Bandage              ; SO_NAME
Skl_Aimed:
    db SK_AIMED
    db 10                           ; SO_POWER (crit-strength bonus)
    db 2
    dw SklName_Aimed
SklName_Bandage: db "BANDAGE", 0
SklName_Aimed:   db "AIMED", 0

; --- Zombie types ------------------------------------------------------------
; v0 ships RED (slow bruiser) and BLUE (fast, fragile). ZO_PORT indexes
; ZombiePortraitTable (portrait_data.asm). The other six design types are LATER
; rows — each just stats + art, no engine change.
ZombieTable::
    dw Zmb_Red
    dw Zmb_Blue
Zmb_Red:                            ; tanky, hits hard, slow
    db 44                           ; ZO_MAXHP
    db 11                           ; ZO_ATK
    db 6                            ; ZO_DEF
    db 3                            ; ZO_SPD
    db 0                            ; ZO_PORT (ZombiePortraitTable[0] = red)
    dw ZmbName_Red                  ; ZO_NAME
Zmb_Blue:                           ; quick, light, low defence
    db 30
    db 8
    db 2
    db 7
    db 1                            ; ZombiePortraitTable[1] = blue
    dw ZmbName_Blue
ZmbName_Red:  db "RED ZOMBIE", 0
ZmbName_Blue: db "BLUE ZOMBIE", 0
