; =============================================================================
; battle_data.asm — weapon / skill / zombie-type tables (docs/design/04).
;
; Small, additive data rows: a new weapon, skill or zombie type is one more
; record here — the combat engine in battle.asm never changes. Each table is a
; list of `dw` pointers to fixed-layout records (offsets in constants.inc:
; WO_*/SO_*/ZO_*). Zombie foes are drawn as the shared approaching-sprite arena
; (battle_zombie_data.asm), tinted by type, so a type is just stats now.
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

; --- Weapons -----------------------------------------------------------------
; Battle stats keyed by ITEM_* (the Fight menu uses the player's REAL equipped
; weapons now). {WS_DMG, WS_CRIT, WS_FLAGS}; a zero WS_DMG means "not a weapon"
; (WeaponStatsPtr falls back to FISTS). Melee weapons scale off STR, WSF_RANGED
; ones off DEX — the player's stat bonus is added on top in battle.asm.
WeaponStats::
    db 0, 0, 0                      ; 0  ITEM_NONE
    db 15, 12, 0                    ; 1  BAT    — heavy melee, big crit
    db 11, 8, WSF_RANGED            ; 2  PISTOL — ranged (DEX)
    db 9, 6, 0                      ; 3  KNIFE  — fast melee
    db 0, 0, 0                      ; 4  VEST
    db 0, 0, 0                      ; 5  HELMET
    db 0, 0, 0                      ; 6  AMULET
    db 0, 0, 0                      ; 7  WATCH
    db 0, 0, 0                      ; 8  GRENADE (thrown from the Item menu)
    db 0, 0, 0                      ; 9  MEDKIT
    db 0, 0, 0                      ; 10 KEYCARD
FistsStats::
    db FISTS_DMG, FISTS_CRIT, 0     ; unarmed fallback

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
; v0 ships RED (slow bruiser) and BLUE (fast, fragile). ZO_PORT is vestigial (the
; portrait was scrapped for the arena sprites); the arena tints a foe by type via
; its BG palette. The other six design types are LATER rows — just stats.
ZombieTable::
    dw Zmb_Red
    dw Zmb_Blue
Zmb_Red:                            ; tanky, hits hard, slow
    db 44                           ; ZO_MAXHP
    db 11                           ; ZO_ATK
    db 6                            ; ZO_DEF
    db 3                            ; ZO_SPD
    db 0                            ; ZO_PORT (vestigial)
    dw ZmbName_Red                  ; ZO_NAME
Zmb_Blue:                           ; quick, light, low defence
    db 30
    db 8
    db 2
    db 7
    db 1                            ; ZO_PORT (vestigial)
    dw ZmbName_Blue
ZmbName_Red:  db "RED ZOMBIE", 0
ZmbName_Blue: db "BLUE ZOMBIE", 0
