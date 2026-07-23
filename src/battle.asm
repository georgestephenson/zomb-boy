; =============================================================================
; battle.asm — turn-based combat (MODE_BATTLE), docs/design/04.
;
; Built like the talk screen (talk.asm): a full-screen UI on SCRN1 ($9C00) with
; SCX/SCY=0, so the overworld map on SCRN0 is untouched and exit is a LCDC flip
; + SetScroll. The screen is composed once with the LCD OFF (inside VBlank; no
; WaitVBlank while it's off — no IRQ fires). All later VRAM writes ride a bounded
; queue (wBattleQ), drained in VBlank.
;
; One engine, two callers (the "same screen whether zombie or survivor"):
;   * EnterBattleZombie   — a zombie's line of sight (entity.asm UpdateAlert)
;   * EnterBattleSurvivor — a hostile-survivor talk outcome (talk.asm TalkFinish)
; They differ only in the enemy descriptor (portrait source + stat row).
;
; Turn loop: pick Fight/Party/Item/Flee -> (a weapon runs the red/amber/green
; CROSSHAIR minigame; a skill fires immediately) -> enemy turn -> repeat until
; someone drops or you flee. Player HP is the persistent survival meter (wHP);
; enemy HP + stats live in a scratch region cleared on entry (design 04 §6).
; =============================================================================
INCLUDE "hardware.inc"
INCLUDE "include/constants.inc"
INCLUDE "include/charmap.inc"

DEF PAINT_RATE   EQU 12         ; box cells revealed per frame (<= BATTLEQ_CAP)
DEF GRACE_FRAMES EQU 90         ; post-battle alert suppression (frames)

; The engine lives in ROMX BANK[1] — the default-mapped bank (shared with the
; dialogue/anim/loot code + battle_data) — because ROM0 is full. Every caller
; (main.asm's .battle branch, entity.asm UpdateAlert, talk.asm TalkFinish) runs
; with bank 1 mapped, and every ROM0 helper it calls (LoadPalettes, WaitVBlank,
; DrawEntities, …) restores bank 1 before returning, so no banked routine here
; ever switches away from its own code. The ONE exception — ShowEnemyPortrait,
; which maps BANK[2] inline — lives in its own ROM0 section below.
; ROM0 shims: the callers (main.asm .battle, entity.asm UpdateAlert, talk.asm
; TalkFinish) run with bank 1 mapped and must reach this floating bank, so the
; two entry points are thin ROM0 trampolines that map the battle bank, call in,
; and restore bank 1 for the caller. (You cannot map a bank and then execute the
; next instruction from the old one — hence a ROM0 trampoline.)
SECTION "Battle Entry", ROM0
; EnterBattleZombie: A = ZTYPE_*. The foe zombie's pool index must already be in
; wBattleFoe (set by the caller) so a win can despawn it.
EnterBattleZombie::
    push af                     ; save the ztype
    call CachePlayerCombat      ; caller has bank 1 mapped -> GetStat works here
    pop af
    ld e, a
    ld a, BANK(bEnterBattleZombie)
    ld [rROMB0], a
    ld a, e
    call bEnterBattleZombie
    ld a, 1
    ld [rROMB0], a
    ret
; EnterBattleSurvivor: A = PERSONA_* (a talk that ended in a fight).
EnterBattleSurvivor::
    push af
    call CachePlayerCombat
    pop af
    ld e, a
    ld a, BANK(bEnterBattleSurvivor)
    ld [rROMB0], a
    ld a, e
    call bEnterBattleSurvivor
    ld a, 1
    ld [rROMB0], a
    ret

; CachePlayerCombat: snapshot the player's real combat stats into WRAM (the engine
; runs in the battle bank where the BANK[1] stat tables aren't mapped). Runs from
; the ROM0 trampolines while the caller's bank 1 is still mapped, so GetStat reads
; the right tables. Clobbers A-E, HL.
CachePlayerCombat::
    ld a, [wPartyLevel]         ; member 0 (the player)
    ld [wPlyLevel], a
    ld a, STAT_STR
    call GetStat
    srl a
    srl a                       ; >> PLY_ATK_SHIFT
    ld [wPlyMelee], a
    ld a, STAT_DEX
    call GetStat
    srl a
    srl a
    ld [wPlyRanged], a
    ld a, STAT_IMM
    call GetStat
    srl a
    srl a                       ; >> PLY_DEF_SHIFT
    ld [wPlyDef], a
    ld a, STAT_ACC
    call GetStat
    srl a
    srl a
    srl a                       ; >> PLY_CRIT_SHIFT
    ld [wPlyCrit], a
    ret

; The engine itself lives in a floating ROMX bank (ROM0 and the default bank 1
; are both full). Its data (weapon/skill/zombie tables, at the end of this file)
; shares the bank, so the engine reads it without switching. Every ROM0 helper
; the engine calls either leaves rROMB0 alone (WaitVBlank, DrawEntities, …) or is
; a ROM0 wrapper that restores THIS bank (bLoadPalettes, ShowEnemyPortrait,
; BattleTransition) — so no banked routine here ever switches away from itself.
SECTION FRAGMENT "Battle", ROMX

bEnterBattleZombie:
    ld [wFoes + FO_TYPE], a      ; the spotter's ZTYPE (foe 0)
    call SetupZombieFoes         ; foe count + per-foe stats/tiers; mirrors foe 0
    ld a, EPK_ZOMBIE
    ld [wBattleEKind], a
    jr bEnterBattleScreen

bEnterBattleSurvivor:
    push af                     ; save the persona index
    ld a, EPK_PERSONA
    ld [wBattleEKind], a
    ld a, ZTYPE_RED
    call LoadZombieRow          ; borrow RED's stats (this clobbers wBattleEIdx)...
    pop af
    ld [wBattleEIdx], a         ; ...so set the persona's portrait index AFTER it
    ld a, $FF
    ld [wBattleFoe], a          ; there's no pool zombie to remove
    ld hl, NameSurvivor
    ld a, l
    ld [wEnemyName], a
    ld a, h
    ld [wEnemyName + 1], a
    call SetupSurvivorFoe       ; a single foe drawn as the persona portrait
    ; fall through
bEnterBattleScreen:
    call BattleTransition       ; the white-flash intro (LCD on, current screen)
    call ResetBattleState
    ; finish any half-blitted world strip before dropping the overworld screen
.flush:
    ld a, [wStrKind]
    and a, a
    jr z, .flushed
    call WaitVBlank
    call BlitStream
    jr .flush
.flushed:
    call WaitVBlank
    xor a, a
    ldh [rLCDC], a              ; LCD off (safe: inside VBlank)
    call BuildBattleScreen
    ld a, [wBattleEKind]
    cp EPK_PERSONA
    jr nz, .zombieArena
    ; survivor: the persona portrait + a single enemy HP bar (as slice 1)
    call ShowEnemyPortrait
    call EnqEnemyHP
    jr .playerHP
.zombieArena:
    ; zombies: load the scale atlas + tints, then paint the crowd (LCD still off)
    call LoadFoeAtlas
    call LoadFoePalettes
    xor a, a
    ld [wFoeFlip], a
    ld a, FOE_FLIP_FRAMES
    ld [wFoeFlipTimer], a
    ld a, 1
    ld [wArenaDirty], a
    call DrawArena
.playerHP:
    call InitCrosshair
    call EnqPlayerHP
    call DrainBattleQ           ; ...painted now, LCD still off
    ; sprites: clear all 40, then compose + fully paint the first menu
    ld hl, wShadowOAM
    ld b, 160
    xor a, a
.clrOAM:
    ld [hl+], a
    dec b
    jr nz, .clrOAM
    call ComposeMainMenu
.paint:
    call BattlePaintBox
    call DrainBattleQ
    ld a, [wBoxPos]
    cp BATTLE_BOX_CELLS
    jr c, .paint
    call DrawBattleSprites
    ld a, HIGH(wShadowOAM)
    call hOAMDMA
    xor a, a
    ldh [rSCX], a
    ldh [rSCY], a
    ld a, MODE_BATTLE
    ld [wGameMode], a
    ld a, LCDCF_ON | LCDCF_BGON | LCDCF_OBJON | LCDCF_OBJ8 | LCDCF_BG8000 | LCDCF_BG9C00
    ldh [rLCDC], a
    ret

NameSurvivor: db "SURVIVOR", 0

; ResetBattleState: clear the per-fight scratch (design 04 §6 — no stale fight
; leaks in). Leaves the enemy stats/name/portrait set by LoadZombieRow.
ResetBattleState:
    xor a, a
    ld [wBattleState], a        ; BS_MENU
    ld [wBattleMenu], a         ; BM_MAIN
    ld [wBattleCursor], a
    ld [wBattleOutcome], a      ; BO_ONGOING
    ld [wBattleQN], a
    ld [wCrossX], a
    ld [wCrossY], a
    ld [wCrossPhase], a
    ld [wBattleWeapon], a
    ld [wFoeFlip], a
    ld [wArenaDirty], a
    ld [wFoeTarget], a
    ld [wBattleXP + 0], a
    ld [wBattleXP + 1], a
    ld [wSkillCd + 0], a
    ld [wSkillCd + 1], a
    ld a, FOE_FLIP_FRAMES
    ld [wFoeFlipTimer], a
    ld a, BATTLE_BOX_CELLS
    ld [wBoxPos], a             ; box idle (nothing to paint yet)
    ld a, $C5
    ld [wBattleGuard], a        ; canary
    ret

; LoadZombieRow: A = ZTYPE_* -> copy the ZombieTable row into the wEnemy* scratch
; (HP starts full). Runs with bank 1 mapped (the default). Clobbers A-E,H,L.
LoadZombieRow:
    add a, a
    ld e, a
    ld d, 0
    ld hl, ZombieTable
    add hl, de
    ld a, [hl+]
    ld h, [hl]
    ld l, a                     ; HL = row
    ld a, [hl+]                 ; ZO_MAXHP
    ld [wEnemyMaxHP], a
    ld [wEnemyHP], a
    ld a, [hl+]                 ; ZO_ATK
    ld [wEnemyATK], a
    ld a, [hl+]                 ; ZO_DEF
    ld [wEnemyDEF], a
    inc hl                      ; skip ZO_SPD (unused in v0)
    ld a, [hl+]                 ; ZO_PORT
    ld [wBattleEIdx], a
    ld a, [hl+]                 ; ZO_NAME (dw)
    ld [wEnemyName], a
    ld a, [hl]
    ld [wEnemyName + 1], a
    ret

; =============================================================================
; Per-frame update (logic phase; the matching VBlank does hOAMDMA + DrainBattleQ)
; =============================================================================
UpdateBattle::
    call TickArenaAnim          ; walk-shuffle mirror (marks the arena dirty)
    call BattlePaintBox
    call DrawBattleSprites
    ld a, [wBattleState]
    cp BS_AIM
    jp z, .aim
    cp BS_MSG
    jp z, .msg
    cp BS_ENEMY
    jp z, BattleFoesTurn
    cp BS_END
    jp z, ExitBattle
    ; --- BS_MENU ---
    ld a, [wNewKeys]
    ld b, a
    and PAD_LEFT | PAD_RIGHT
    jr z, .vert
    ld a, [wBattleCursor]
    xor a, 1
    ld [wBattleCursor], a
.vert:
    ld a, b
    and PAD_UP | PAD_DOWN
    jr z, .back
    ld a, [wBattleCursor]
    xor a, 2
    ld [wBattleCursor], a
.back:
    ld a, b                     ; B backs out of the Fight submenu
    and PAD_B
    jr z, .confirm
    ld a, [wBattleMenu]
    and a, a
    ret z                       ; already on the main menu
    jp GotoMainMenu
.confirm:
    ld a, [wNewKeys]
    and PAD_A
    ret z
    ld a, [wBattleMenu]
    and a, a
    jr z, .mainMenu
    cp BM_ITEM
    jp z, PickItem              ; Item submenu: use a bag consumable
    jp PickFight                ; Fight submenu: weapon / skill
.mainMenu:
    ; main menu: 0 Fight, 1 Party, 2 Item, 3 Flee
    ld a, [wBattleCursor]
    and a, a
    jr z, .toFight
    cp 3
    jp z, TryFlee
    cp 2
    jp z, EnterItemMenu         ; Item: the real bag consumables
    jp ShowPartyLine            ; Party: the real roster (member 0)
.toFight:
    ld a, BM_FIGHT
    ld [wBattleMenu], a
    xor a, a
    ld [wBattleCursor], a
    jp ComposeFightMenu
; --- BS_MSG: a line is up; A advances to wBattleMsgNext ---
.msg:
    ld a, [wNewKeys]
    and PAD_A
    ret z
    ld a, [wBattleMsgNext]
    cp BS_MENU
    jp z, GotoMainMenu
    ld [wBattleState], a
    ret
; --- BS_AIM: the crosshair orbits the arena; A locks and hit-tests the foes.
; A is checked BEFORE the step so the lock uses exactly the crosshair the player
; sees (and so a test can pin the position, then press A). ---
.aim:
    ld a, [wNewKeys]
    and PAD_A
    jp nz, ResolveAimZombie
    call MoveCrosshair
    ret

; PickFight: A-press on the Fight submenu. Cursor 0/1 = weapon (aim), 2/3 = skill.
PickFight:
    ld a, [wBattleCursor]
    cp 2
    jr nc, .skill
    ; weapon: start the crosshair minigame at the orbit's start point
    ld [wBattleWeapon], a
    xor a, a
    ld [wCrossPhase], a
    call CrossPos
    ld hl, MsgFire
    call ComposeLine
    ld a, BS_AIM
    ld [wBattleState], a
    ret
.skill:
    sub 2
    jp UseSkill

; Aim resolution + the enemy turn now live with the multi-foe arena code at the
; end of the file (ResolveAimZombie / BattleFoesTurn) — one screen for one or
; many foes.

; TryFlee: chance-based escape; a failed attempt gives the enemy a free turn.
TryFlee:
    call Rand                   ; A = random byte
    cp FLEE_CHANCE
    jr nc, .fail
    ld a, BO_FLEE
    ld [wBattleOutcome], a
    ld hl, MsgFled
    ld a, BS_END
    ld [wBattleMsgNext], a
    jp SetMessage
.fail:
    ld hl, MsgNoFlee
    ld a, BS_ENEMY
    ld [wBattleMsgNext], a
    jp SetMessage

; UseSkill: A = skill index (0/1). Heals or fires a guaranteed hit; on cooldown
; it just reports NOT READY (no turn spent).
UseSkill:
    ld [wBattleWeapon], a       ; scratch: remember the index
    ld e, a
    ld d, 0
    ld hl, wSkillCd
    add hl, de
    ld a, [hl]
    and a, a
    jr z, .ready
    ld a, BS_MENU
    ld [wBattleMsgNext], a
    ld hl, MsgNotReady
    jp SetMessage
.ready:
    ld a, [wBattleWeapon]
    call SkillRecord            ; HL = record
    push hl
    ld de, SO_CD
    add hl, de
    ld c, [hl]                  ; SO_CD
    ld a, [wBattleWeapon]
    ld e, a
    ld d, 0
    ld hl, wSkillCd
    add hl, de
    ld [hl], c                  ; arm the cooldown
    pop hl
    ld a, [hl]                  ; SO_KIND
    push af
    ld de, SO_POWER
    add hl, de
    ld b, [hl]                  ; B = power
    pop af
    cp SK_HEAL
    jr z, .heal
    ; SK_AIMED — a guaranteed hit of crit strength on the lead living foe
    push bc                     ; B = power
    call FindTargetFoe          ; -> wFoeTarget (lead living foe)
    ld a, [wFoeTarget]
    call FoePtr
    ld de, FO_DEF
    add hl, de
    ld a, [hl]
    ld [wEnemyDEF], a           ; CalcPlayerDamage reads wEnemyDEF
    pop bc
    ld a, b                     ; base = skill power
    ld c, 0                     ; melee (STR-boosted)
    call CalcPlayerDamage       ; A = damage
    ld c, a
    ld a, [wFoeTarget]
    ld b, a
    ld a, c
    call HurtFoe                ; index B, damage A
    call RefillIfDead
    call BattleWon
    and a, a
    jr z, .aimAlive
    ld a, BO_WIN
    ld [wBattleOutcome], a
    ld hl, MsgWin
    ld a, BS_END
    ld [wBattleMsgNext], a
    jp SetMessage
.aimAlive:
    ld hl, MsgAimed
    ld a, BS_ENEMY
    ld [wBattleMsgNext], a
    jp SetMessage
.heal:
    ld a, [wHP]
    add a, b
    jr c, .cap
    cp METER_MAX + 1
    jr c, .setHP
.cap:
    ld a, METER_MAX
.setHP:
    ld [wHP], a
    call EnqPlayerHP
    ld hl, MsgHealed
    ld a, BS_ENEMY
    ld [wBattleMsgNext], a
    jp SetMessage

; GotoMainMenu: return control to the player. Ticks skill cooldowns (one per
; completed round), then rebuilds the main menu.
GotoMainMenu:
    ld hl, wSkillCd
    ld b, SKILL_COUNT
.cd:
    ld a, [hl]
    and a, a
    jr z, .next
    dec a
    ld [hl], a
.next:
    inc hl
    dec b
    jr nz, .cd
    xor a, a
    ld [wBattleMenu], a
    ld [wBattleCursor], a
    ld a, BS_MENU
    ld [wBattleState], a
    jp ComposeMainMenu

; =============================================================================
; Party / Item menus (the REAL party roster + bag)
; =============================================================================
; ShowPartyLine: the roster — just member 0 so far — as "ZOMB BOY LV n".
ShowPartyLine:
    call BoxClear
    ld hl, wBattleBox
    ld de, PlateHero
    call PlatePutStr
    ld a, [wPlyLevel]
    call PlatePutLevel
    xor a, a
    ld [wBoxPos], a
    ld a, BS_MSG
    ld [wBattleState], a
    ld a, BS_MENU
    ld [wBattleMsgNext], a
    ret

; EnterItemMenu: gather up to 4 bag consumables into wBattleItemMap and open the
; Item submenu; if the bag has none, just say so.
EnterItemMenu:
    ld hl, wBattleItemMap
    xor a, a
    ld [hl+], a
    ld [hl+], a
    ld [hl+], a
    ld [hl], a
    ld hl, wBag
    ld de, wBattleItemMap
    ld b, BAG_MAX
    ld c, 0                     ; consumables found
.scan:
    ld a, [hl]                  ; item id
    and a, a
    jr z, .next
    push hl
    push de
    call GetItemType            ; A = ITYPE_* (keeps BC; clobbers DE, HL)
    pop de
    pop hl
    cp ITYPE_CONSUMABLE
    jr nz, .next
    ld a, [hl]                  ; item id -> map[found]
    ld [de], a
    inc de
    inc c
    ld a, c
    cp 4
    jr z, .built
.next:
    inc hl
    inc hl                      ; next {id,count} stack
    dec b
    jr nz, .scan
.built:
    ld a, c
    and a, a
    jr z, .none
    call ComposeItemLabels
    ld a, BM_ITEM
    ld [wBattleMenu], a
    xor a, a
    ld [wBattleCursor], a
    ret
.none:
    ld hl, MsgNoItems
    ld a, BS_MENU
    ld [wBattleMsgNext], a
    jp SetMessage

; ComposeItemLabels: draw the (up to 4) mapped item names into the menu grid.
ComposeItemLabels:
    call BoxClear
    ld c, 0                     ; slot
.lp:
    push bc
    ld a, c
    ld e, a
    ld d, 0
    ld hl, wBattleItemMap
    add hl, de
    ld a, [hl]                  ; item id
    and a, a
    jr z, .blank
    call GetItemName            ; HL = padded name
    pop bc
    push bc
    call PutBoxLabel            ; C = slot, HL = string
.blank:
    pop bc
    inc c
    ld a, c
    cp 4
    jr c, .lp
    xor a, a
    ld [wBoxPos], a
    ret

; PickItem: A-press on the Item submenu -> use the mapped consumable.
PickItem:
    ld a, [wBattleCursor]
    ld e, a
    ld d, 0
    ld hl, wBattleItemMap
    add hl, de
    ld a, [hl]                  ; item id
    and a, a
    ret z                       ; empty slot -> ignore the press
    cp ITEM_MEDKIT
    jr z, .medkit
    cp ITEM_GRENADE
    jr z, .grenade
    ; other consumables have no combat effect yet
    ld hl, MsgNoItems
    ld a, BS_MENU
    ld [wBattleMsgNext], a
    jp SetMessage
.medkit:
    ld a, [wHP]
    add a, MEDKIT_HEAL
    jr c, .capHP
    cp METER_MAX + 1
    jr c, .setHP
.capHP:
    ld a, METER_MAX
.setHP:
    ld [wHP], a
    call EnqPlayerHP
    ld a, ITEM_MEDKIT
    call RemoveOneItem          ; consume it (ROM0)
    ld hl, MsgHealed
    ld a, BS_ENEMY
    ld [wBattleMsgNext], a
    jp SetMessage
.grenade:
    call GrenadeAllFoes         ; GRENADE_DMG to every living foe, then refill slots
    ld a, ITEM_GRENADE
    call RemoveOneItem
    call BattleWon
    and a, a
    jr z, .gAlive
    ld a, BO_WIN
    ld [wBattleOutcome], a
    ld hl, MsgWin
    ld a, BS_END
    ld [wBattleMsgNext], a
    jp SetMessage
.gAlive:
    ld hl, MsgGrenade
    ld a, BS_ENEMY
    ld [wBattleMsgNext], a
    jp SetMessage

; GrenadeAllFoes: deal GRENADE_DMG to every living foe, then pull reserves into
; any slot the blast emptied.
GrenadeAllFoes:
    ld c, 0                     ; index
.lp:
    ld a, [wFoeCount]
    cp c
    jr z, .refill
    ld a, c
    call FoePtr
    ld de, FO_HP
    add hl, de
    ld a, [hl]
    and a, a
    jr z, .next                 ; already dead
    sub GRENADE_DMG
    jr nc, .store
    xor a, a
.store:
    ld [hl], a
    and a, a
    jr nz, .next
    push bc                     ; a kill -> XP for its level
    ld a, c
    call FoePtr
    inc hl                      ; FO_LEVEL
    ld a, [hl]
    call AddKillXP
    pop bc
.next:
    inc c
    jr .lp
.refill:
    ld a, 1
    ld [wArenaDirty], a
    ; fall through to refill any emptied slots

; RefillAllDeadSlots: fill each dead on-screen slot from the reserve (until it
; runs out) — used after an area hit so the pack keeps coming.
RefillAllDeadSlots:
    ld c, 0
.lp:
    ld a, [wFoeCount]
    cp c
    ret z
    ld a, [wFoeReserve]
    and a, a
    ret z
    ld a, c
    call FoePtr
    ld de, FO_HP
    add hl, de
    ld a, [hl]
    and a, a
    jr nz, .next
    ld a, [wFoeReserve]
    dec a
    ld [wFoeReserve], a
    xor a, a
    ld [wSeedTier], a
    call SeedFoeSlot            ; C = index (preserved)
.next:
    inc c
    jr .lp

; =============================================================================
; Damage helpers
; =============================================================================
; CalcPlayerDamage: A = weapon base damage, C = ranged flag (0 melee / 1 ranged)
; -> A = clampmin1(base + offence - enemyDEF>>2), where offence is the player's
; melee (STR) or ranged (DEX) bonus cached at entry. Preserves DE and HL.
CalcPlayerDamage:
    ld b, a                     ; base
    ld a, c
    and a, a
    jr nz, .ranged
    ld a, [wPlyMelee]
    jr .bonus
.ranged:
    ld a, [wPlyRanged]
.bonus:
    add a, b                    ; base + offence
    jr nc, .noSat
    ld a, 255
.noSat:
    ld b, a
    ld a, [wEnemyDEF]
    srl a
    srl a                       ; DEF >> 2
    ld c, a
    ld a, b
    sub c
    jr nc, .ok
    xor a, a
.ok:
    and a, a
    ret nz
    inc a
    ret

; HurtPlayer: A = damage -> wHP saturating-sub; redraw bar; Z if HP == 0.
HurtPlayer:
    ld b, a
    ld a, [wHP]
    sub b
    jr nc, .ok
    xor a, a
.ok:
    ld [wHP], a
    call EnqPlayerHP
    ld a, [wHP]
    and a, a
    ret

; The crosshair now orbits the arena (MoveCrosshair) and hit-tests the drawn
; foes (HitTestCrosshair) instead of sweeping a red/amber/green bar — both at the
; end of the file with the arena code.

; =============================================================================
; Menu / message composition (into wBattleBox; revealed by BattlePaintBox)
; =============================================================================
ComposeMainMenu:
    call BoxClear
    ld hl, LblFight
    ld c, 0
    call PutBoxLabel
    ld hl, LblParty
    ld c, 1
    call PutBoxLabel
    ld hl, LblItem
    ld c, 2
    call PutBoxLabel
    ld hl, LblFlee
    ld c, 3
    call PutBoxLabel
    xor a, a
    ld [wBoxPos], a
    ret

ComposeFightMenu:
    call BoxClear
    ld a, 0
    call EquippedWeaponName     ; the player's REAL equipped weapon in slot 1
    ld c, 0
    call PutBoxLabel
    ld a, 1
    call EquippedWeaponName     ; ...and slot 2
    ld c, 1
    call PutBoxLabel
    ld a, 0
    call SkillName
    ld c, 2
    call PutBoxLabel
    ld a, 1
    call SkillName
    ld c, 3
    call PutBoxLabel
    xor a, a
    ld [wBoxPos], a
    ret

; ComposeLine: HL = string -> box row 0 = string (no state change).
ComposeLine:
    push hl
    call BoxClear
    pop hl
    ld de, wBattleBox
.copy:
    ld a, [hl+]
    and a, a
    jr z, .done
    ld [de], a
    inc de
    jr .copy
.done:
    xor a, a
    ld [wBoxPos], a
    ret

; SetMessage: HL = string -> ComposeLine + state BS_MSG.
SetMessage:
    call ComposeLine
    ld a, BS_MSG
    ld [wBattleState], a
    ret

; BoxClear: fill the paint buffer with the space glyph.
BoxClear:
    ld hl, wBattleBox
    ld b, BATTLE_BOX_CELLS
    ld a, FONT_BASE
.l:
    ld [hl+], a
    dec b
    jr nz, .l
    ret

; PutBoxLabel: C = slot (0..3), HL = 0-terminated string -> copy into wBattleBox
; at (slot>>1)*18 + MENU_LBL_COL0 + (slot&1)*8.
PutBoxLabel:
    push hl
    ld a, c
    and 1
    add a, a
    add a, a
    add a, a                    ; (slot&1)*8
    add a, MENU_LBL_COL0
    ld b, a                     ; column part
    ld a, c
    and 2
    ld d, a                     ; 0 or 2
    add a, a
    add a, a
    add a, a                    ; *8 -> 0 or 16
    add a, d                    ; *9 -> 0 or 18
    add a, b
    ld e, a
    ld d, 0
    ld hl, wBattleBox
    add hl, de
    ld d, h
    ld e, l                     ; DE = dest
    pop hl                      ; HL = string
.copy:
    ld a, [hl+]
    and a, a
    ret z
    ld [de], a
    inc de
    jr .copy

; SkillName: A = index -> HL = name string pointer.
SkillName:
    ld de, SkillTable
    call DerefPtrTable
    ld de, SO_NAME
    add hl, de
    ld a, [hl+]
    ld h, [hl]
    ld l, a
    ret

; EquippedWeaponName: A = weapon slot (0/1) -> HL = the equipped item's name, or
; "FISTS" if the slot is empty / holds a non-weapon. Uses the real party equip.
EquippedWeaponName:
    ld e, a
    ld d, 0
    ld hl, wPartyEquip          ; member 0's equip slots (0 = weapon 1, 1 = weapon 2)
    add hl, de
    ld a, [hl]
    and a, a
    jr z, .fists
    ld b, a                     ; item id
    ld c, a
    add a, a
    add a, c                    ; * WS_SIZE (3)
    ld e, a
    ld d, 0
    ld hl, WeaponStats
    add hl, de
    ld a, [hl]                  ; WS_DMG
    and a, a
    jr z, .fists                ; equipped, but not a weapon
    ld a, b
    jp GetItemName              ; ROM0 (always mapped): HL = padded item name
.fists:
    ld hl, FistsName
    ret

; WeaponStatsPtr: -> HL = the WeaponStats record for slot wBattleWeapon (the
; player's equipped weapon), or FistsStats if the slot is empty / non-weapon.
WeaponStatsPtr:
    ld a, [wBattleWeapon]
    ld e, a
    ld d, 0
    ld hl, wPartyEquip
    add hl, de
    ld a, [hl]                  ; equipped item id
    and a, a
    jr z, .fists
    ld c, a
    add a, a
    add a, c                    ; * WS_SIZE
    ld e, a
    ld d, 0
    ld hl, WeaponStats
    add hl, de
    ld a, [hl]                  ; WS_DMG
    and a, a
    ret nz                      ; a real weapon
.fists:
    ld hl, FistsStats
    ret

FistsName: db "FISTS", 0

; SkillRecord: A = index -> HL = SkillTable[A] record.
SkillRecord:
    ld de, SkillTable
; DerefPtrTable: A = index, DE = pointer-table base -> HL = record.
DerefPtrTable:
    add a, a
    ld l, a
    ld h, 0
    add hl, de
    ld a, [hl+]
    ld h, [hl]
    ld l, a
    ret

; =============================================================================
; VRAM write queue (identical shape to talk's; drained in VBlank)
; =============================================================================
; BattleEnq: HL = VRAM address, A = tile. Only B survives the call.
BattleEnq:
    ld c, a
    ld a, [wBattleQN]
    cp BATTLEQ_CAP
    ret nc                      ; full: drop (callers stay under the cap)
    ld e, a
    inc a
    ld [wBattleQN], a
    ld a, e
    add a, a
    add a, e                    ; * 3
    ld e, a
    ld d, 0
    push hl
    ld hl, wBattleQ
    add hl, de
    pop de                      ; DE = VRAM address
    ld [hl], d
    inc hl
    ld [hl], e
    inc hl
    ld [hl], c
    ret

DrainBattleQ::
    ld a, [wBattleQN]
    and a, a
    ret z
    ld b, a
    xor a, a
    ld [wBattleQN], a
    ldh [rVBK], a               ; tiles live in bank 0
    ld hl, wBattleQ
.write:
    ld a, [hl+]
    ld d, a
    ld a, [hl+]
    ld e, a
    ld a, [hl+]
    ld [de], a
    dec b
    jr nz, .write
    ret

; BattlePaintBox: reveal up to PAINT_RATE cells of wBattleBox into SCRN1 rows
; BOX_TXT_ROW0 / +2. Cell i: row = i/18, col = i%18.
BattlePaintBox:
    ld a, [wBoxPos]
    cp BATTLE_BOX_CELLS
    ret nc
    ld b, PAINT_RATE
.loop:
    ld a, [wBoxPos]
    cp BATTLE_BOX_CELLS
    ret nc
    push bc
    ld a, [wBoxPos]
    cp TALK_COLS                ; 18
    ld c, 0                     ; BG-row delta
    jr c, .r0
    ld c, 2
    sub TALK_COLS
.r0:
    ld e, a                     ; E = col (0..17)
    ld a, BOX_TXT_ROW0
    add a, c
    ld l, a
    ld h, 0
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl                  ; * 32
    ld a, e
    add a, BOX_TXT_COL0
    ld e, a
    ld d, 0
    add hl, de                  ; + col
    ld de, _SCRN1
    add hl, de
    ld a, [wBoxPos]
    ld e, a
    ld d, 0
    push hl
    ld hl, wBattleBox
    add hl, de
    ld a, [hl]                  ; A = cell value
    pop hl                      ; HL = VRAM dest
    call BattleEnq
    ld a, [wBoxPos]
    inc a
    ld [wBoxPos], a
    pop bc
    dec b
    jr nz, .loop
    ret

; =============================================================================
; Sprites: menu cursor (slot 0) + crosshair (slot 1)
; =============================================================================
DrawBattleSprites:
    ld a, [wBattleState]
    cp BS_MENU
    jr z, .cursor
    xor a, a
    ld [wShadowOAM + 0], a      ; hide the cursor
    jr .cross
.cursor:
    ld a, [wBattleCursor]
    and 2
    add a, BOX_TXT_ROW0
    add a, a
    add a, a
    add a, a                    ; * 8
    add a, 16                   ; OAM Y offset
    ld [wShadowOAM + 0], a
    ld a, [wBattleCursor]
    and 1
    add a, a
    add a, a
    add a, a                    ; (cursor&1)*8
    add a, BOX_TXT_COL0 - 1 + MENU_LBL_COL0
    add a, a
    add a, a
    add a, a                    ; * 8
    add a, 8                    ; OAM X offset
    ld [wShadowOAM + 1], a
    ld a, TILE_CURSOR
    ld [wShadowOAM + 2], a
    ld a, PAL_OBJ_CROSS
    ld [wShadowOAM + 3], a
.cross:
    ld a, [wBattleState]
    cp BS_AIM
    jr z, .drawcross
    xor a, a
    ld [wShadowOAM + 4], a      ; hide the crosshair
    ret
.drawcross:
    ld a, [wCrossY]
    add a, 16                   ; OAM Y offset (screen px -> OAM)
    ld [wShadowOAM + 4], a
    ld a, [wCrossX]
    add a, 8                    ; OAM X offset
    ld [wShadowOAM + 5], a
    ld a, TILE_CROSSHAIR
    ld [wShadowOAM + 6], a
    ld a, PAL_OBJ_CROSS
    ld [wShadowOAM + 7], a
    ret

; =============================================================================
; HP bars (8 cells of 8 sub-columns each = the bar to the pixel)
; =============================================================================
EnqEnemyHP:
    ld a, [wEnemyMaxHP]
    ld c, a
    ld a, [wEnemyHP]
    call BarSub
    ld de, _SCRN1 + EN_HP_ROW * 32 + BHP_BAR_COL
    jp BarEmit
EnqPlayerHP:
    ld c, METER_MAX
    ld a, [wHP]
    call BarSub
    ld de, _SCRN1 + PL_HP_ROW * 32 + BHP_BAR_COL
    jp BarEmit

; BarSub: A = hp, C = maxhp (>0) -> A = hp*64/maxhp (0..64).
BarSub:
    ld l, a
    ld h, 0
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl                  ; * 64
    ld b, 0
.div:
    ld a, l
    sub c
    ld e, a
    ld a, h
    sbc a, 0
    jr c, .done
    ld l, e
    ld h, a
    inc b
    jr .div
.done:
    ld a, b
    ret

; BarEmit: A = sub-columns (0..64), DE = SCRN1 dest of the first of 8 cells.
BarEmit:
    ld b, 8
.cell:
    ld c, a
    sub 8
    jr nc, .full
    ld a, c
    ld c, 0
    jr .emit
.full:
    ld c, a
    ld a, 8
.emit:
    add a, TILE_BAR_BASE
    push bc
    push de
    ld h, d
    ld l, e
    call BattleEnq
    pop de
    inc de
    pop bc
    ld a, c
    dec b
    jr nz, .cell
    ret

; =============================================================================
; Screen build (LCD off)
; =============================================================================
BuildBattleScreen:
    xor a, a
    ldh [rVBK], a
    ; paper
    ld hl, _SCRN1
    ld bc, 32 * 32
    ld d, FONT_BASE
.fill:
    ld a, d
    ld [hl+], a
    dec bc
    ld a, b
    or a, c
    jr nz, .fill
    ; player HP glyph (both screens); the enemy name plate + HP glyph belong to
    ; the single-enemy survivor screen — zombies show per-foe pips in the arena.
    ld a, TILE_HUD_HP
    ld [_SCRN1 + PL_HP_ROW * 32 + BHP_GLYPH_COL], a
    ld a, [wBattleEKind]
    cp EPK_PERSONA
    jr nz, .noPlate
    ld hl, wEnemyName
    ld a, [hl+]
    ld e, a
    ld d, [hl]                  ; DE = name string
    ld hl, _SCRN1 + EN_NAME_ROW * 32
    call PutsHL
    ld a, TILE_HUD_HP
    ld [_SCRN1 + EN_HP_ROW * 32 + BHP_GLYPH_COL], a
.noPlate:
    ; player name + level, on its own row just under the player HP bar
    call DrawPlayerPlate
    ; message box panel (rows BAT_BOX_TOP..BAT_BOX_BOT) — a short 5-row box
    ld hl, _SCRN1 + BAT_BOX_TOP * 32
    ld a, TILE_PANEL_TL
    ld [hl+], a
    ld a, TILE_PANEL_T
    ld b, VIEW_COLS - 2
.top:
    ld [hl+], a
    dec b
    jr nz, .top
    ld a, TILE_PANEL_TR
    ld [hl], a
    ld hl, _SCRN1 + BAT_BOX_BOT * 32
    ld a, TILE_PANEL_BL
    ld [hl+], a
    ld a, TILE_PANEL_B
    ld b, VIEW_COLS - 2
.bot:
    ld [hl+], a
    dec b
    jr nz, .bot
    ld a, TILE_PANEL_BR
    ld [hl], a
    ld hl, _SCRN1 + (BAT_BOX_TOP + 1) * 32
    ld c, BAT_BOX_BOT - BAT_BOX_TOP - 1
.sides:
    ld a, TILE_PANEL_L
    ld [hl], a
    ld de, VIEW_COLS - 1
    add hl, de
    ld a, TILE_PANEL_R
    ld [hl], a
    ld de, 32 - (VIEW_COLS - 1)
    add hl, de
    dec c
    jr nz, .sides
    ; enemy portrait frame — survivor only (zombies fill the arena band instead)
    ld a, [wBattleEKind]
    cp EPK_PERSONA
    jr nz, .noFrame
    call DrawEnemyFrame
.noFrame:
    ; attributes (CGB only — on DMG rVBK is a no-op and this would hit the map)
    ldh a, [hIsCGB]
    and a, a
    ret z
    ld a, 1
    ldh [rVBK], a
    ld hl, _SCRN1
    ld bc, 32 * 32
    ld d, PAL_BG_UI
.attr:
    ld a, d
    ld [hl+], a
    dec bc
    ld a, b
    or a, c
    jr nz, .attr
    xor a, a
    ldh [rVBK], a
    ret

; PutsHL: DE = 0-terminated (charmap'd) string, HL = dest. Clobbers A, DE, HL.
PutsHL:
    ld a, [de]
    and a, a
    ret z
    ld [hl+], a
    inc de
    jr PutsHL

; DrawEnemyFrame: the frame ring around the 7x7 enemy portrait (SCRN1, bank 0).
DrawEnemyFrame:
    ld hl, _SCRN1 + (PORTRAIT_ROW0 - 1) * 32 + (PORTRAIT_COL0 - 1)
    ld a, TILE_FRAME_TL
    ld [hl+], a
    ld a, TILE_FRAME_T
    ld b, PORTRAIT_COLS
.top:
    ld [hl+], a
    dec b
    jr nz, .top
    ld a, TILE_FRAME_TR
    ld [hl+], a
    ld hl, _SCRN1 + (PORTRAIT_ROW0 + PORTRAIT_ROWS) * 32 + (PORTRAIT_COL0 - 1)
    ld a, TILE_FRAME_BL
    ld [hl+], a
    ld a, TILE_FRAME_B
    ld b, PORTRAIT_COLS
.bot:
    ld [hl+], a
    dec b
    jr nz, .bot
    ld a, TILE_FRAME_BR
    ld [hl+], a
    ld hl, _SCRN1 + PORTRAIT_ROW0 * 32 + (PORTRAIT_COL0 - 1)
    ld c, PORTRAIT_ROWS
.side:
    ld a, TILE_FRAME_L
    ld [hl], a
    push hl
    ld de, PORTRAIT_COLS + 1
    add hl, de
    ld a, TILE_FRAME_R
    ld [hl], a
    pop hl
    ld de, 32
    add hl, de
    dec c
    jr nz, .side
    ret

; ShowEnemyPortrait: load a hostile SURVIVOR's 56x56 persona portrait, exactly
; like talk's ShowPortrait. Zombie foes are now drawn as the approaching-sprite
; arena (DrawArena) and never call this, so there is only the one table.
; PortraitTable is BANK[2]; bank 1 is restored before returning. This is the one
; battle routine that maps another bank INLINE, so it lives in ROM0 (always
; mapped) — a banked copy would unmap its own code the moment it switched.
SECTION "Battle Portrait", ROM0
ShowEnemyPortrait:
    ld a, BANK(PortraitTable)
    ld [rROMB0], a
    ld hl, PortraitTable
    ld a, [wBattleEIdx]
    add a, a
    ld e, a
    ld d, 0
    add hl, de
    ld a, [hl+]
    ld h, [hl]
    ld l, a                     ; HL = descriptor
    ; palettes: 24 bytes -> BG slots 5/6/7 (CGB only)
    ldh a, [hIsCGB]
    and a, a
    jr z, .tileids
    push hl
    ld a, BCPSF_AUTOINC | (PAL_BG_PORTRAIT * 8)
    ldh [rBCPS], a
    ld b, PORTRAIT_ATTR_OFF
.pal:
    ld a, [hl+]
    ldh [rBCPD], a
    dec b
    jr nz, .pal
    pop hl
.tileids:
    xor a, a
    ldh [rVBK], a
    push hl
    ld hl, _SCRN1 + PORTRAIT_ROW0 * 32 + PORTRAIT_COL0
    ld a, PORTRAIT_TILE_BASE
    ld d, PORTRAIT_ROWS
.trow:
    ld b, PORTRAIT_COLS
    push hl
.tcol:
    ld [hl+], a
    inc a
    dec b
    jr nz, .tcol
    pop hl
    push de
    ld de, 32
    add hl, de
    pop de
    dec d
    jr nz, .trow
    pop hl                      ; descriptor
    ; attributes: per-tile palette index + PAL_BG_PORTRAIT (CGB only)
    push hl
    ld de, PORTRAIT_ATTR_OFF
    add hl, de
    ldh a, [hIsCGB]
    and a, a
    jr z, .tiles
    ld a, 1
    ldh [rVBK], a
    ld de, _SCRN1 + PORTRAIT_ROW0 * 32 + PORTRAIT_COL0
    ld c, PORTRAIT_ROWS
.arow:
    ld b, PORTRAIT_COLS
.acol:
    ld a, [hl+]
    add a, PAL_BG_PORTRAIT
    ld [de], a
    inc de
    dec b
    jr nz, .acol
    ld a, e
    add a, 32 - PORTRAIT_COLS
    ld e, a
    ld a, d
    adc a, 0
    ld d, a
    dec c
    jr nz, .arow
    xor a, a
    ldh [rVBK], a
.tiles:
    pop hl                      ; descriptor
    ld bc, PORTRAIT_TILE_OFF
    add hl, bc
    xor a, a
    ldh [rVBK], a
    ld de, _VRAM + PORTRAIT_TILE_BASE * 16
    ld bc, PORTRAIT_NTILES * 16
.cp:
    ld a, [hl+]
    ld [de], a
    inc de
    dec bc
    ld a, b
    or a, c
    jr nz, .cp
    ld a, BANK(UpdateBattle)    ; restore the battle bank (our caller lives there)
    ld [rROMB0], a
    ret

SECTION FRAGMENT "Battle", ROMX          ; back to the banked engine
; =============================================================================
; Exit
; =============================================================================
; ExitBattle: on a win, despawn the foe zombie; then restore the overworld
; (still intact on SCRN0) with an LCDC flip, like ExitTalkScreen. LoadPalettes
; puts back the terrain palette we borrowed for the zone bar.
ExitBattle:
    ld a, [wBattleOutcome]
    cp BO_WIN
    jr nz, .noKill
    ld a, [wBattleFoe]
    cp $FF
    jr z, .noKill
    call CopyEntityIn
    xor a, a
    ld [wEnt + EO_ACTIVE], a
    ld a, [wBattleFoe]
    call CopyEntityOut
.noKill:
    ld a, GRACE_FRAMES
    ld [wAlertGrace], a
    ld a, MODE_OVERWORLD
    ld [wGameMode], a
    xor a, a
    ld [wBattleQN], a
    ; Rebuilding the overworld frame calls DrawEntities, which reaches DrawLoot in
    ; BANK[1] (Loot Code) — so it must run with bank 1 mapped, NOT this battle
    ; bank. Hand off to a ROM0 finisher that maps bank 1 first (a banked routine
    ; can't map bank 1 and keep executing its own code; ROM0 always can).
    jp ExitBattleFinish         ; tail call (ret there returns to main.asm .battle)

; =============================================================================
; ROM0 bank-switching helpers. These run at least partly with a bank OTHER than
; the battle bank mapped (LoadPalettes maps the gfx bank), which is only safe
; from ROM0 (always mapped); each restores the battle bank before returning to
; its banked caller.
; =============================================================================
SECTION "Battle Flash", ROM0

; ExitBattleFinish: rebuild the overworld frame after a battle (like
; ExitTalkScreen). ROM0 so it can map bank 1 — DrawEntities calls DrawLoot in
; BANK[1], which would run as garbage under the battle bank. Restores the terrain
; palettes (the zone bar borrowed BG slot 3), redraws sprites, flips LCDC back to
; SCRN0 + the HUD window, and re-applies scroll. The world map on SCRN0 was never
; touched, so this is the whole restore. Tail-called from ExitBattle: the ret
; returns to main.asm's .battle branch (bank 1 already mapped there).
ExitBattleFinish:
    ld a, 1                     ; DrawLoot lives in BANK[1] — map it before drawing
    ld [rROMB0], a
    ; grant the fight's XP on a win — bank 1 is mapped now, so AddPlayerXP's
    ; RecalcLevel can read the LevelXP table (it lives in BANK[1]).
    ld a, [wBattleOutcome]
    cp BO_WIN
    jr nz, .noXP
    ld a, [wBattleXP]
    ld c, a
    ld a, [wBattleXP + 1]
    ld b, a
    call AddPlayerXP
.noXP:
    call LoadPalettes
    call ComputeCamLag
    call DrawEntities
    call WaitVBlank
    ld a, HIGH(wShadowOAM)
    call hOAMDMA
    call DrawHUDRow
    ld a, LCDCF_ON | LCDCF_BGON | LCDCF_OBJON | LCDCF_OBJ8 | LCDCF_BG8000 | LCDCF_BG9800 | LCDCF_WINON | LCDCF_WIN9C00
    ldh [rLCDC], a
    call SetScroll
    ret

; BattleTransition: the white-flash intro (now the transition INTO battle). It
; calls LoadPalettes (maps the gfx bank) in a loop, so it must be ROM0.
BattleTransition::
    ld c, 4
.loop:
    call FlashWhite
    call WaitFewFrames
    call LoadPalettes
    call WaitFewFrames
    dec c
    jr nz, .loop
    call WaitHold
    ld a, BANK(UpdateBattle)     ; hand the battle bank back to bEnterBattleScreen
    ld [rROMB0], a
    ret

FlashWhite:
    ld a, BCPSF_AUTOINC
    ldh [rBCPS], a
    ld b, 8
.w:
    ld a, $FF
    ldh [rBCPD], a
    dec b
    jr nz, .w
    ret

WaitFewFrames:
    ld b, 4
.l:
    call WaitVBlank
    dec b
    jr nz, .l
    ret

WaitHold:
    ld b, 30
.l:
    call WaitVBlank
    dec b
    jr nz, .l
    ret

; =============================================================================
; Data (battle bank — read by the engine that shares this bank)
; =============================================================================
SECTION FRAGMENT "Battle", ROMX
LblFight:    db "FIGHT", 0
LblParty:    db "PARTY", 0
LblItem:     db "ITEM", 0
LblFlee:     db "FLEE", 0
MsgFire:     db "A TO FIRE", 0
MsgMiss:     db "MISSED", 0
MsgHit:      db "YOU HIT", 0
MsgCrit:     db "CRITICAL HIT", 0
MsgWin:      db "ENEMY DOWN", 0
MsgDied:     db "YOU FELL", 0
MsgEnemyHit: db "IT BITES YOU", 0
MsgFled:     db "GOT AWAY", 0
MsgNoFlee:   db "CANT ESCAPE", 0
MsgNoItems:  db "NO ITEMS YET", 0
MsgNotReady: db "NOT READY", 0
MsgHealed:   db "PATCHED UP", 0
MsgGrenade:  db "BOOM", 0
MsgAimed:    db "AIMED HIT", 0
MsgApproach: db "THEY CLOSE IN", 0

; =============================================================================
; slice 2 — the approaching-zombie arena (docs task): up to MAX_FOES zombies
; shuffle toward the player as scaled BG sprites, and a free-moving crosshair
; (circle / figure-eight) replaces the horizontal red/amber/green zone bar.
; =============================================================================
SECTION FRAGMENT "Battle", ROMX

; FoePtr: A = foe index -> HL = &wFoes[A]. Preserves BC (callers rely on it).
FoePtr:
    add a, a
    add a, a
    add a, a
    add a, a                    ; * FOE_STRUCT (16)
    ld l, a
    ld h, 0
    ld de, wFoes
    add hl, de
    ret

; ScaleStat: level-weight a base stat. C = base, B = per-level grow, D = level-1,
; E = jitter mask -> A = sat(base + (level-1)*grow + (Rand & mask)). Preserves
; nothing but reads only its args (Rand keeps C/D/E). Used to randomise foe stats.
ScaleStat:
    ld a, c                     ; acc = base
    ld c, d                     ; C = remaining level-1 iterations
.loop:
    ld l, a                     ; stash acc
    ld a, c
    and a, a
    jr z, .jit
    ld a, l
    add a, b                    ; acc += grow
    jr c, .max
    dec c
    jr .loop
.max:
    ld a, 255                   ; saturated; the jitter can only keep it at 255
    jr .addjit
.jit:
    ld a, l                     ; acc
.addjit:
    ld c, a                     ; C = acc (survives Rand)
    call Rand                   ; A = random (Rand preserves C/D/E)
    and e                       ; & jitter mask
    add a, c
    ret nc
    ld a, 255
    ret

; ScaleFoeStats: C = index. Reads FO_TYPE/FO_LEVEL, writes MAXHP/HP/ATK/DEF from
; ZombieTable[type] scaled + jittered by the level.
ScaleFoeStats:
    ld a, c
    ld [wSeedIdx], a
    call FoePtr
    ld a, [hl]                  ; FO_TYPE
    add a, a
    ld e, a
    ld d, 0
    ld hl, ZombieTable
    add hl, de
    ld a, [hl+]
    ld h, [hl]
    ld l, a                     ; HL = ZombieTable row
    ld a, [hl+]
    ld [wSeedHP], a             ; base MAXHP
    ld a, [hl+]
    ld [wSeedATK], a            ; base ATK
    ld a, [hl]
    ld [wSeedDEF], a            ; base DEF
    ld a, [wSeedIdx]
    call FoePtr
    inc hl                      ; FO_LEVEL
    ld a, [hl]
    dec a                       ; level - 1
    ld [wSeedLv1], a
    ; MAXHP
    ld a, [wSeedHP]
    ld c, a
    ld b, ZHP_GROW
    ld a, [wSeedLv1]
    ld d, a
    ld e, ZHP_JIT_MASK
    call ScaleStat
    ld [wSeedHP], a
    ; ATK
    ld a, [wSeedATK]
    ld c, a
    ld b, ZATK_GROW
    ld a, [wSeedLv1]
    ld d, a
    ld e, ZATK_JIT_MASK
    call ScaleStat
    ld [wSeedATK], a
    ; DEF
    ld a, [wSeedDEF]
    ld c, a
    ld b, ZDEF_GROW
    ld a, [wSeedLv1]
    ld d, a
    ld e, ZDEF_JIT_MASK
    call ScaleStat
    ld [wSeedDEF], a
    ; write MAXHP, HP=MAXHP, ATK, DEF
    ld a, [wSeedIdx]
    call FoePtr
    ld de, FO_MAXHP
    add hl, de
    ld a, [wSeedHP]
    ld [hl+], a                 ; MAXHP
    ld [hl+], a                 ; HP = MAXHP
    ld a, [wSeedATK]
    ld [hl+], a                 ; ATK
    ld a, [wSeedDEF]
    ld [hl], a                  ; DEF
    ret

; SeedFoeSlot: C = slot index, wSeedTier = start tier. Fills wFoes[C] with a
; fresh foe — random type + level (near the player's) + level-weighted random
; stats, plus a random lane and approach speed. Used both to build the initial
; pack and to pull a reserve zombie into an emptied slot. Preserves C.
SeedFoeSlot:
    ; FO_TYPE = Rand & 1
    call Rand
    and 1
    push af
    ld a, c
    call FoePtr
    pop af
    ld [hl], a                  ; FO_TYPE (0)
    ; FO_LEVEL = clamp(playerLevel + (Rand%(spread+1)) - 1, 1, MAX_LEVEL)
    call Rand
    and ZLVL_SPREAD
    ld e, a
    ld a, [wPlyLevel]
    add a, e
    dec a
    jr nz, .lnz
    inc a                       ; floor at 1
.lnz:
    cp MAX_LEVEL + 1
    jr c, .lcap
    ld a, MAX_LEVEL
.lcap:
    push af
    ld a, c
    call FoePtr
    inc hl                      ; FO_LEVEL (1)
    pop af
    ld [hl], a
    ; FO_TIER = wSeedTier
    ld a, c
    call FoePtr
    ld de, FO_TIER
    add hl, de
    ld a, [wSeedTier]
    ld [hl], a
    ; FO_SPD = FOE_SPD_MIN + (Rand & 3); FO_STEP = 0
    call Rand
    and 3
    add a, FOE_SPD_MIN
    push af
    ld a, c
    call FoePtr
    ld de, FO_SPD
    add hl, de
    pop af
    ld [hl+], a                 ; FO_SPD (7)
    xor a, a
    ld [hl], a                  ; FO_STEP (8) = 0
    ; FO_LANE = 2 + (Rand & 15) -> spread across; ComputeFoeBox clamps to screen
    call Rand
    and 15
    add a, 2
    push af
    ld a, c
    call FoePtr
    ld de, FO_LANE
    add hl, de
    pop af
    ld [hl], a                  ; FO_LANE (9)
    jp ScaleFoeStats            ; fills MAXHP/HP/ATK/DEF (tail; keeps C)

; SetupZombieFoes: build the encounter — a random visible count (FOE_MIN..MAX_FOES)
; plus a random reserve, each foe freshly seeded. Mirrors foe 0 into wEnemy*.
SetupZombieFoes:
    call Rand
    and 3
    cp 3
    jr nz, .cnt3                ; A in 0..2 (Rand%3, roughly)
    xor a, a
.cnt3:
    add a, FOE_MIN
    ld [wFoeCount], a
    call Rand
    and FOE_RESERVE_MAX
    ld [wFoeReserve], a
    ld a, [wFoeCount]
    ld b, a                     ; B = count bound
    ld c, 0                     ; C = index
.seed:
    push bc
    call Rand
    and 1                       ; start tier 0..1 (approach speed adds the rest)
    ld [wSeedTier], a
    pop bc
    push bc
    call SeedFoeSlot            ; C = index
    pop bc
    inc c
    ld a, c
    cp b
    jr c, .seed
    xor a, a
    ld [wFoeTarget], a
    jp MirrorFoe                ; A = 0 -> wEnemy* mirrors foe 0

; SetupSurvivorFoe: one foe built from the RED stats LoadZombieRow left in wEnemy*
; (a hostile survivor). Drawn as the persona portrait, always in melee.
SetupSurvivorFoe:
    ld a, 1
    ld [wFoeCount], a
    xor a, a
    ld [wFoeReserve], a
    ld [wFoeTarget], a
    ld hl, wFoes
    ld a, ZTYPE_RED
    ld [hl+], a                 ; FO_TYPE (0)
    ld a, [wPlyLevel]
    ld [hl+], a                 ; FO_LEVEL (1)
    ld a, [wEnemyMaxHP]
    ld [hl+], a                 ; FO_MAXHP (2)
    ld [hl+], a                 ; FO_HP (3) = MAXHP
    ld a, [wEnemyATK]
    ld [hl+], a                 ; FO_ATK (4)
    ld a, [wEnemyDEF]
    ld [hl+], a                 ; FO_DEF (5)
    ld a, FOE_TIER_MAX
    ld [hl], a                  ; FO_TIER (6) always melee
    ret

; MirrorFoe: A = index -> copy its MAXHP/HP/ATK/DEF into wEnemy* (the HP bar +
; integration tests read these). Clobbers A, DE, HL.
MirrorFoe:
    call FoePtr
    ld de, FO_MAXHP
    add hl, de
    ld a, [hl+]                 ; FO_MAXHP
    ld [wEnemyMaxHP], a
    ld a, [hl+]                 ; FO_HP
    ld [wEnemyHP], a
    ld a, [hl+]                 ; FO_ATK
    ld [wEnemyATK], a
    ld a, [hl]                  ; FO_DEF
    ld [wEnemyDEF], a
    ret

; FindTargetFoe: -> A = lowest-index living foe (the lead), $FF if none. Sets
; wFoeTarget when found. Used by the AIMED skill (guaranteed hit, no crosshair).
FindTargetFoe:
    ld a, [wFoeCount]
    ld c, a
    ld b, 0
.lp:
    ld a, b
    call FoePtr
    ld de, FO_HP
    add hl, de
    ld a, [hl]
    and a, a
    jr nz, .found
    inc b
    dec c
    jr nz, .lp
    ld a, $FF
    ret
.found:
    ld a, b
    ld [wFoeTarget], a
    ret

; ComputeFoeBox: A = index -> wFoeB{C,R,W,H,Head,Off}, the on-screen tile
; rectangle (and atlas offset) of the foe. Persona -> the fixed portrait block.
ComputeFoeBox:
    ld c, a                     ; C = index
    ld a, [wBattleEKind]
    cp EPK_PERSONA
    jr nz, .zombie
    ld a, PORTRAIT_COL0
    ld [wFoeBC], a
    ld a, PORTRAIT_ROW0
    ld [wFoeBR], a
    ld a, PORTRAIT_COLS
    ld [wFoeBW], a
    ld a, PORTRAIT_ROWS
    ld [wFoeBH], a
    ld a, 2
    ld [wFoeBHead], a
    xor a, a
    ld [wFoeBOff], a
    ret
.zombie:
    ld a, c
    call FoePtr
    ld de, FO_TIER
    add hl, de
    ld a, [hl]                  ; tier
    add a, a
    add a, a                    ; tier * 4 (BattleZombieTiers row stride)
    ld e, a
    ld d, 0
    ld hl, BattleZombieTiers
    add hl, de
    ld a, [hl+]                 ; wtiles
    ld [wFoeBW], a
    ld b, a                     ; B = wt
    ld a, [hl+]                 ; htiles
    ld [wFoeBH], a
    ld d, a                     ; D = ht
    ld a, [hl+]                 ; headrows
    ld [wFoeBHead], a
    ld a, [hl]                  ; tileoff
    ld [wFoeBOff], a
    ; rowBase = FOE_GROUND_ROW + 1 - ht (feet on the ground row)
    ld a, FOE_GROUND_ROW + 1
    sub d
    ld [wFoeBR], a
    ; colBase = clamp(foe.FO_LANE - wt/2, 0, VIEW_COLS - wt)
    ld a, c
    call FoePtr
    ld de, FO_LANE
    add hl, de
    ld a, [hl]                  ; the foe's random lane centre column
    ld e, a
    ld a, b                     ; wt
    srl a                       ; wt / 2
    ld d, a
    ld a, e
    sub d                       ; centre - wt/2
    jr nc, .cok
    xor a, a                    ; clamp low to 0
.cok:
    ld d, a                     ; D = candidate colBase
    ld a, VIEW_COLS
    sub b                       ; A = max colBase (VIEW_COLS - wt)
    cp d                        ; A - D
    jr c, .clampHi              ; A < D -> too far right, use max
    ld a, d                     ; else keep candidate
.clampHi:
    ld [wFoeBC], a
    ret

; =============================================================================
; VRAM setup (LCD off at entry; DrawArena runs in VBlank)
; =============================================================================
; LoadFoeAtlas: copy the scale atlas into the VRAM gap the portrait vacated.
LoadFoeAtlas:
    xor a, a
    ldh [rVBK], a
    ld hl, BattleZombieTiles
    ld de, _VRAM + FOE_ATLAS_BASE * 16
    ld bc, BattleZombieTilesEnd - BattleZombieTiles
.cp:
    ld a, [hl+]
    ld [de], a
    inc de
    dec bc
    ld a, b
    or a, c
    jr nz, .cp
    ret

; LoadFoePalettes: the two zombie tints -> BG slots 5/6 (CGB only; DMG uses rBGP).
LoadFoePalettes:
    ldh a, [hIsCGB]
    and a, a
    ret z
    ld a, BCPSF_AUTOINC | (PAL_BG_FOE0 * 8)
    ldh [rBCPS], a
    ld hl, FoePalettes
    ld b, 24                    ; 3 palettes (foes 5/6 + arena backdrop 7)
.l:
    ld a, [hl+]
    ldh [rBCPD], a
    dec b
    jr nz, .l
    ret

; InitCrosshair: pick a motion (circle/fig-8) and place it at phase 0.
InitCrosshair:
    call Rand
    and 1
    ld [wBattlePattern], a
    xor a, a
    ld [wCrossPhase], a
    ; fall through
; CrossPos: wCrossX/Y <- the current phase point of the chosen orbit path.
CrossPos:
    ld a, [wBattlePattern]
    and a, a
    ld hl, CrossPathCircle
    jr z, .have
    ld hl, CrossPathFig8
.have:
    ld a, [wCrossPhase]
    add a, a                    ; * 2 (db x, y)
    ld e, a
    ld d, 0
    add hl, de
    ld a, [hl+]
    ld [wCrossX], a
    ld a, [hl]
    ld [wCrossY], a
    ret

; MoveCrosshair: advance the orbit one step and reposition (BS_AIM, each frame).
MoveCrosshair::
    ld a, [wCrossPhase]
    add a, CROSS_PSTEP
    and CROSS_SINLEN - 1
    ld [wCrossPhase], a
    jr CrossPos

; =============================================================================
; Aim resolution: the locked crosshair hit-tests the on-screen foes.
; =============================================================================
; ResolveAimZombie: A locked. Hit a foe -> damage it (head = crit); miss -> the
; enemy turn. On the kill of the last foe -> win.
ResolveAimZombie::
    call HitTestCrosshair       ; A = ZONE_*; wFoeTarget set on a hit
    cp ZONE_MISS
    jp z, .miss
    push af                     ; save the zone
    ld a, [wFoeTarget]
    call FoePtr
    ld de, FO_DEF
    add hl, de
    ld a, [hl]
    ld [wEnemyDEF], a           ; CalcPlayerDamage reads wEnemyDEF
    call WeaponStatsPtr         ; HL = {WS_DMG, WS_CRIT, WS_FLAGS} (real equipped)
    ld c, 0                     ; C = ranged flag
    push hl
    inc hl
    inc hl                      ; WS_FLAGS
    bit WSF_RANGED, [hl]
    jr z, .melee
    ld c, 1
.melee:
    pop hl                      ; record
    ld a, [hl]                  ; WS_DMG
    call CalcPlayerDamage       ; A = base + offence - def (C = ranged); keeps HL, E
    ld e, a                     ; E = damage
    pop af                      ; zone
    push af
    cp ZONE_CRIT
    jr nz, .noCrit
    ; crit: + weapon crit + the player's Accuracy bonus
    inc hl                      ; WS_CRIT
    ld a, [hl]
    add a, e
    jr nc, .c1
    ld a, 255
.c1:
    ld e, a
    ld a, [wPlyCrit]
    add a, e
    jr nc, .c2
    ld a, 255
.c2:
    ld e, a
.noCrit:
    ld a, [wFoeTarget]
    ld b, a
    ld a, e
    call HurtFoe                ; index B, damage A
    call RefillIfDead           ; killed a foe -> pull a reserve in behind it
    call BattleWon              ; A = 1 iff all dead AND no reserves left
    and a, a
    jr nz, .win
    pop af                      ; zone -> message
    cp ZONE_CRIT
    ld hl, MsgCrit
    jr z, .msg
    ld hl, MsgHit
.msg:
    ld a, BS_ENEMY
    ld [wBattleMsgNext], a
    jp SetMessage
.win:
    pop af                      ; drop the zone
    ld a, BO_WIN
    ld [wBattleOutcome], a
    ld hl, MsgWin
    ld a, BS_END
    ld [wBattleMsgNext], a
    jp SetMessage
.miss:
    ld hl, MsgMiss
    ld a, BS_ENEMY
    ld [wBattleMsgNext], a
    jp SetMessage

; HitTestCrosshair: -> A = ZONE_* under the crosshair; wFoeTarget set on a hit.
HitTestCrosshair:
    ld a, [wFoeCount]
    ld c, a                     ; C = count
    ld b, 0                     ; B = index
.lp:
    ld a, b
    call FoePtr
    ld de, FO_HP
    add hl, de                  ; FO_HP
    ld a, [hl]
    and a, a
    jr z, .next                 ; dead slot
    ld a, b
    push bc
    call ComputeFoeBox
    call PointInBox             ; -> A = ZONE_*
    pop bc
    cp ZONE_MISS
    jr nz, .hit
.next:
    inc b
    dec c
    jr nz, .lp
    ld a, ZONE_MISS
    ret
.hit:
    ld d, a                     ; save zone
    ld a, b
    ld [wFoeTarget], a
    ld a, d
    ret

; PointInBox: crosshair centre vs wFoeB* -> A = ZONE_MISS/HIT/CRIT. Clobbers B-E.
PointInBox:
    ld a, [wCrossX]
    add a, 3
    ld b, a                     ; px
    ld a, [wCrossY]
    add a, 3
    ld c, a                     ; py
    ld a, [wFoeBC]
    add a, a
    add a, a
    add a, a
    ld d, a                     ; left px
    ld a, b
    cp d
    jr c, .out                  ; px < left
    ld a, [wFoeBW]
    add a, a
    add a, a
    add a, a
    add a, d                    ; right px
    ld e, a
    ld a, b
    cp e
    jr nc, .out                 ; px >= right
    ld a, [wFoeBR]
    add a, a
    add a, a
    add a, a
    ld d, a                     ; top px
    ld a, c
    cp d
    jr c, .out                  ; py < top
    ld a, [wFoeBH]
    add a, a
    add a, a
    add a, a
    add a, d                    ; bottom px
    ld e, a
    ld a, c
    cp e
    jr nc, .out                 ; py >= bottom
    ld a, [wFoeBHead]
    add a, a
    add a, a
    add a, a
    add a, d                    ; top + head*8 (D = top)
    ld e, a
    ld a, c
    cp e
    jr c, .crit                 ; py in the head band
    ld a, ZONE_HIT
    ret
.crit:
    ld a, ZONE_CRIT
    ret
.out:
    ld a, ZONE_MISS
    ret

; HurtFoe: B = index, A = damage -> saturating HP sub; mirror to wEnemy*; mark the
; arena dirty. (Death is HP == 0: the slot draws blank next repaint.)
HurtFoe:
    ld c, a                     ; C = damage
    ld a, b
    call FoePtr
    ld de, FO_HP
    add hl, de                  ; FO_HP
    ld a, [hl]
    sub c
    jr nc, .ok
    xor a, a
.ok:
    ld [hl], a
    and a, a
    jr nz, .live
    push bc                     ; a kill -> bank XP for the foe's level
    ld a, b
    call FoePtr
    inc hl                      ; FO_LEVEL
    ld a, [hl]
    call AddKillXP
    pop bc
.live:
    ld a, b
    ld [wFoeTarget], a
    call MirrorFoe
    ld a, 1
    ld [wArenaDirty], a
    ; fall through to refresh the enemy HP readout

; RefreshEnemyHP: redraw the enemy HP — the overall sum bar for a zombie pack, or
; the single foe's bar for a survivor.
RefreshEnemyHP:
    ld a, [wBattleEKind]
    cp EPK_PERSONA
    jp z, EnqEnemyHP            ; survivor: single foe bar via the queue
    ld a, 1
    ld [wArenaDirty], a         ; zombies: DrawArena redraws the sum bar + plate
    ret

; RefillIfDead: if the last-hit foe (wFoeTarget) just died and reserves remain,
; pull a fresh zombie into its slot at the back (tier 0) so the pack keeps coming.
RefillIfDead::
    ld a, [wFoeTarget]
    call FoePtr
    ld de, FO_HP
    add hl, de
    ld a, [hl]
    and a, a
    ret nz                      ; still alive
    ld a, [wFoeReserve]
    and a, a
    ret z                       ; none waiting
    dec a
    ld [wFoeReserve], a
    xor a, a
    ld [wSeedTier], a           ; the replacement starts far away (behind)
    ld a, [wFoeTarget]
    ld c, a
    call SeedFoeSlot            ; refill the emptied slot
    ld a, 1
    ld [wArenaDirty], a
    jp RefreshEnemyHP

; BattleWon: -> A = 1 iff every on-screen foe is dead AND no reserves remain.
BattleWon::
    ld a, [wFoeReserve]
    and a, a
    jp z, AllFoesDead
    xor a, a
    ret

; TickArenaAnim: advance the walk-shuffle. Every FOE_FLIP_FRAMES the whole crowd
; mirrors (reversed columns + XFLIP), reading as a shuffling gait. Zombie only.
TickArenaAnim::
    ld a, [wBattleEKind]
    cp EPK_PERSONA
    ret z
    ld hl, wFoeFlipTimer
    dec [hl]
    ret nz
    ld a, FOE_FLIP_FRAMES
    ld [hl], a
    ld a, [wFoeFlip]
    xor 1
    ld [wFoeFlip], a
    ld a, 1
    ld [wArenaDirty], a
    ret

; AddKillXP: A = a defeated foe's level -> wBattleXP += level * XP_PER_LEVEL
; (16-bit, saturating). Granted to the party on a win.
AddKillXP:
    ld e, a
    ld d, 0                     ; DE = level
    ld hl, 0
    ld b, XP_PER_LEVEL
.mul:
    add hl, de
    dec b
    jr nz, .mul                 ; HL = level * XP_PER_LEVEL
    ld a, [wBattleXP]
    add a, l
    ld [wBattleXP], a
    ld a, [wBattleXP + 1]
    adc h
    ld [wBattleXP + 1], a
    ret nc
    ld a, $FF
    ld [wBattleXP], a
    ld [wBattleXP + 1], a
    ret

; AllFoesDead: -> A = 1 if every foe HP == 0, else 0.
AllFoesDead::
    ld a, [wFoeCount]
    ld c, a
    ld b, 0
.lp:
    ld a, b
    call FoePtr
    ld de, FO_HP
    add hl, de                  ; FO_HP
    ld a, [hl]
    and a, a
    jr nz, .alive
    inc b
    dec c
    jr nz, .lp
    ld a, 1
    ret
.alive:
    xor a, a
    ret

; =============================================================================
; Enemy turn: each living foe either shuffles a tier closer or (in melee) bites.
; =============================================================================
BattleFoesTurn::
    xor a, a
    ld [wBiteAcc], a            ; accumulate bite damage in RAM (FoePtr clobbers DE)
    ld a, [wFoeCount]
    ld c, a                     ; C = count
    ld b, 0                     ; B = index
.lp:
    ld a, b
    call FoePtr                 ; HL = &foe (preserves BC)
    push hl                     ; save &foe
    ld de, FO_HP
    add hl, de                  ; FO_HP
    ld a, [hl]
    and a, a
    jr z, .skip                 ; dead
    ld a, [wBattleEKind]
    cp EPK_PERSONA
    jr z, .bite                 ; a survivor is always in melee
    pop hl
    push hl
    ld de, FO_TIER
    add hl, de
    ld a, [hl]
    cp FOE_TIER_MAX
    jr z, .bite
    ; not in melee yet: accumulate approach; advance a tier when it crosses the
    ; step threshold, so a higher-FO_SPD foe closes the distance faster.
    pop hl
    push hl
    ld de, FO_SPD
    add hl, de
    ld a, [hl]                  ; FO_SPD
    inc hl                      ; FO_STEP
    add a, [hl]                 ; STEP += SPD
    cp APPROACH_STEP
    jr c, .storeStep
    sub APPROACH_STEP
    ld [hl], a                  ; keep the remainder
    pop hl
    push hl
    ld de, FO_TIER
    add hl, de
    inc [hl]                    ; shuffle one tier closer
    jr .skip
.storeStep:
    ld [hl], a
    jr .skip
.bite:
    pop hl
    push hl
    ld de, FO_ATK
    add hl, de
    ld a, [hl]                  ; FO_ATK
    ; incoming = FO_ATK - wPlyDef (the player's Immunity), min 1
    ld e, a
    ld a, [wPlyDef]
    ld d, a
    ld a, e
    sub d
    jr nc, .nz
    xor a, a
.nz:
    and a, a
    jr nz, .add
    inc a                       ; min 1
.add:
    ld hl, wBiteAcc
    add a, [hl]
    jr nc, .noSat
    ld a, 255
.noSat:
    ld [wBiteAcc], a
.skip:
    pop hl
    inc b
    dec c
    jr nz, .lp
    ld a, 1
    ld [wArenaDirty], a         ; tiers advanced / a foe may have moved -> repaint
    ld a, [wBiteAcc]
    and a, a
    jr z, .noDmg
    call HurtPlayer             ; Z if the player is down
    jr nz, .alive
    ld a, BO_LOSE
    ld [wBattleOutcome], a
    ld hl, MsgDied
    ld a, BS_END
    ld [wBattleMsgNext], a
    jp SetMessage
.alive:
    ld hl, MsgEnemyHit
    ld a, BS_MENU
    ld [wBattleMsgNext], a
    jp SetMessage
.noDmg:
    ld hl, MsgApproach
    ld a, BS_MENU
    ld [wBattleMsgNext], a
    jp SetMessage

; =============================================================================
; Arena paint (VBlank). Clears the arena band and repaints living foes far->near
; so the nearer (bigger) ones occlude the rest. Only fires when wArenaDirty.
; =============================================================================
DrawArena::
    ld a, [wArenaDirty]
    and a, a
    ret z
    ld a, [wBattleEKind]
    cp EPK_PERSONA
    ret z                       ; a survivor keeps its portrait, not the arena
    xor a, a
    ld [wArenaDirty], a
    ldh [rVBK], a               ; bank 0 (tile ids)
    ; backdrop: sky rows (paper glyph -> index 0 = sky), then a ground band
    ld hl, _SCRN1 + FOE_ARENA_TOP * 32
    ld c, ARENA_GROUND_TOP - FOE_ARENA_TOP
    ld a, FONT_BASE
    call .fillRows
    ld hl, _SCRN1 + ARENA_GROUND_TOP * 32
    ld c, FOE_GROUND_ROW - ARENA_GROUND_TOP + 1
    ld a, TILE_ZONE_RED         ; solid ground tile (grass under PAL_BG_ARENA)
    call .fillRows
    ; attributes: the whole arena band uses the backdrop palette (CGB only), so a
    ; cleared cell and a foe's index-0 pixels both read as sky (no halo)
    ldh a, [hIsCGB]
    and a, a
    jr z, .foes
    ld a, 1
    ldh [rVBK], a
    ld hl, _SCRN1 + FOE_ARENA_TOP * 32
    ld c, FOE_GROUND_ROW - FOE_ARENA_TOP + 1
    ld a, PAL_BG_ARENA
    call .fillRows
    xor a, a
    ldh [rVBK], a
.foes:
    ld a, [wFoeCount]
    ld b, a
.pf:
    dec b                       ; index = count-1 .. 0 (draw the lead last, on top)
    ld a, b
    call FoePtr
    ld de, FO_HP
    add hl, de                  ; FO_HP
    ld a, [hl]
    and a, a
    jr z, .pafter               ; dead -> its slot stays blank
    ld a, b
    push bc
    call PaintFoe
    pop bc
.pafter:
    ld a, b
    and a, a
    jr nz, .pf
    xor a, a
    ldh [rVBK], a
    ; the enemy readouts sit outside the arena band (rows 0/1) — refresh them here
    ; too (direct writes, no queue pressure) since the foe set just changed.
    call DrawSumBarDirect       ; row 1: overall HP (sum of the pack)
    call DrawEnemyPlateDirect   ; row 0: the appearing types + their levels
    xor a, a
    ldh [rVBK], a
    ret
; .fillRows: HL = first cell, C = rows, A = value -> fill VIEW_COLS cells per row
; (advancing 32/row). A local helper for the backdrop; clobbers A-E, HL.
.fillRows:
    ld d, a
.fr_row:
    ld b, VIEW_COLS
    push hl
    ld a, d
.fr_col:
    ld [hl+], a
    dec b
    jr nz, .fr_col
    pop hl
    ld a, l
    add a, 32
    ld l, a
    ld a, h
    adc a, 0
    ld h, a
    dec c
    jr nz, .fr_row
    ret

; DrawSumBarDirect: the pack's overall HP bar (Σ hp / Σ maxhp) into SCRN1 row 1.
DrawSumBarDirect:
    xor a, a
    ld [wHpSum], a
    ld [wHpSum + 1], a
    ld [wHpMax], a
    ld [wHpMax + 1], a
    ld a, [wFoeCount]
    ld c, a
    ld b, 0
.lp:
    ld a, b
    call FoePtr
    ld de, FO_MAXHP
    add hl, de
    ld a, [hl+]                 ; MAXHP -> wHpMax
    push hl
    ld hl, wHpMax
    add a, [hl]
    ld [hl+], a
    ld a, 0
    adc a, [hl]
    ld [hl], a
    pop hl                      ; &FO_HP
    ld a, [hl]                  ; HP -> wHpSum
    push hl
    ld hl, wHpSum
    add a, [hl]
    ld [hl+], a
    ld a, 0
    adc a, [hl]
    ld [hl], a
    pop hl
    inc b
    dec c
    jr nz, .lp
    ld a, TILE_HUD_HP
    ld [_SCRN1 + EN_HP_ROW * 32 + BHP_GLYPH_COL], a
    call Sum64Div               ; A = 0..64
    ld hl, _SCRN1 + EN_HP_ROW * 32 + BHP_BAR_COL
    ; emit 8 cells (direct)
    ld b, 8
.cell:
    ld c, a
    sub 8
    jr nc, .full
    ld a, c
    ld c, 0
    jr .emit
.full:
    ld c, a
    ld a, 8
.emit:
    add a, TILE_BAR_BASE
    ld [hl+], a
    ld a, c
    dec b
    jr nz, .cell
    ret

; Sum64Div: -> A = min(64, wHpSum*64 / wHpMax); 0 if wHpMax == 0.
Sum64Div:
    ld a, [wHpSum]
    ld l, a
    ld a, [wHpSum + 1]
    ld h, a
    ld a, [wHpMax]
    ld c, a
    ld a, [wHpMax + 1]
    ld b, a                     ; BC = Σ maxhp
    or c
    jr nz, .ok
    xor a, a
    ret
.ok:
    ld d, 6
.shl:
    add hl, hl                  ; HL = Σ hp << 6
    dec d
    jr nz, .shl
    ld e, 0
.sub:
    ld a, l
    sub c
    ld l, a
    ld a, h
    sbc b
    ld h, a
    jr c, .done
    inc e
    ld a, e
    cp 64
    jr nc, .cap
    jr .sub
.cap:
    ld a, 64
    ret
.done:
    ld a, e
    ret

; FirstLivingLevel: A = ZTYPE_* -> A = the level of the first living foe of that
; type, or 0 if none present. Clobbers B, DE, HL (C = type, preserved by FoePtr).
FirstLivingLevel:
    ld c, a                     ; C = target type (survives FoePtr)
    ld b, 0
.lp:
    ld a, [wFoeCount]
    cp b
    jr z, .none
    ld a, b
    call FoePtr
    ld a, [hl]                  ; FO_TYPE
    cp c
    jr nz, .next
    push hl
    ld de, FO_HP
    add hl, de
    ld a, [hl]
    pop hl
    and a, a
    jr z, .next                 ; dead
    inc hl                      ; FO_LEVEL
    ld a, [hl]
    ret
.next:
    inc b
    jr .lp
.none:
    xor a, a
    ret

; DrawEnemyPlateDirect: SCRN1 row 0 = each distinct living type + its level, e.g.
; "RED LV3 BLUE LV2" (charmap'd font tiles).
DrawEnemyPlateDirect:
    ld hl, _SCRN1 + EN_NAME_ROW * 32
    ld b, VIEW_COLS
    ld a, FONT_BASE
.clr:
    ld [hl+], a
    dec b
    jr nz, .clr
    ld hl, _SCRN1 + EN_NAME_ROW * 32
    ld a, ZTYPE_RED
    push hl                     ; FirstLivingLevel clobbers HL (the write cursor)
    call FirstLivingLevel
    pop hl
    and a, a
    jr z, .blue
    push af
    ld de, PlateRed
    call PlatePutStr
    pop af
    call PlatePutLevel
    ld a, FONT_BASE             ; separator space
    ld [hl+], a
.blue:
    ld a, ZTYPE_BLUE
    push hl
    call FirstLivingLevel
    pop hl
    and a, a
    ret z
    push af
    ld de, PlateBlue
    call PlatePutStr
    pop af
    ; fall through to PlatePutLevel

; PlatePutLevel: HL = dest, A = level (1..99) -> writes " LV" + the decimal level.
PlatePutLevel:
    push af
    ld de, PlateLv
    call PlatePutStr
    pop af
    ld c, 0                     ; tens
.tens:
    cp 10
    jr c, .ones
    sub 10
    inc c
    jr .tens
.ones:
    ld b, a                     ; ones
    ld a, c
    and a, a
    jr z, .noTens
    add a, TILE_DIGIT0
    ld [hl+], a
.noTens:
    ld a, b
    add a, TILE_DIGIT0
    ld [hl+], a
    ret

; PlatePutStr: HL = dest, DE = charmap'd string -> copy until 0, advancing HL.
PlatePutStr:
    ld a, [de]
    and a, a
    ret z
    ld [hl+], a
    inc de
    jr PlatePutStr

PlateRed:  db "RED", 0
PlateBlue: db "BLUE", 0
PlateLv:   db " LV", 0
PlateHero: db "ZOMB BOY", 0

; DrawPlayerPlate: SCRN1 row PL_NAME_ROW = "ZOMB BOY LV n" (the player's real
; level, cached at entry). Direct writes (LCD off at build time).
DrawPlayerPlate:
    ld hl, _SCRN1 + PL_NAME_ROW * 32
    ld de, PlateHero
    call PlatePutStr
    ld a, [wPlyLevel]
    jp PlatePutLevel

; PaintFoe: A = foe index. Writes its scaled tile block into the tilemap (bank 0),
; the palette+flip attributes (bank 1, CGB), and a 1-cell HP pip above its head.
; The walk shuffle mirrors the block on wFoeFlip (reversed columns + XFLIP).
PaintFoe:
    push af                     ; index
    call FoePtr
    ld a, [hl]                  ; FO_TYPE
    and 1
    add a, PAL_BG_FOE0
    ld [wFoePalTmp], a          ; foe palette (5 or 6)
    pop af
    call ComputeFoeBox          ; wFoeB* + wFoeBOff

    ; --- tile ids (bank 0) ---
    xor a, a
    ldh [rVBK], a
    ld a, [wFoeBR]              ; dest = _SCRN1 + BR*32 + BC
    ld l, a
    ld h, 0
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl                  ; BR * 32
    ld a, [wFoeBC]
    ld e, a
    ld d, 0
    add hl, de
    ld de, _SCRN1
    add hl, de                  ; HL = top-left dest cell
    ld a, [wFoeBOff]
    add a, FOE_ATLAS_BASE
    ld c, a                     ; C = current source tile id (row-major)
    ld a, [wFoeBH]
    ld b, a                     ; B = rows left
.trow:
    push hl
    push bc
    ld a, [wFoeFlip]
    and a, a
    jr z, .fwd
    ; mirrored: fill columns right-to-left
    ld a, [wFoeBW]
    ld e, a
    dec a
    add a, l                    ; HL += (W-1) : write from the right end
    ld l, a
    ld a, h
    adc a, 0
    ld h, a
.mloop:
    ld a, c
    ld [hl-], a
    inc c
    dec e
    jr nz, .mloop
    jr .rowdone
.fwd:
    ld a, [wFoeBW]
    ld e, a
.floop:
    ld a, c
    ld [hl+], a
    inc c
    dec e
    jr nz, .floop
.rowdone:
    pop bc
    ld a, [wFoeBW]
    add a, c
    ld c, a                     ; advance source tile id one row
    pop hl
    ld de, 32
    add hl, de
    dec b
    jr nz, .trow

    ; --- attributes (bank 1, CGB) : palette (+ XFLIP when mirrored) ---
    ldh a, [hIsCGB]
    and a, a
    ret z                       ; DMG: no per-cell palette / flip
    ld a, 1
    ldh [rVBK], a
    ld a, [wFoePalTmp]
    ld c, a                     ; C = palette
    ld a, [wFoeFlip]
    and a, a
    jr z, .noflip
    ld a, c
    or OAMF_XFLIP               ; attr bit 5 = X flip (BG attr uses the same bit)
    ld c, a
.noflip:
    ld a, [wFoeBR]
    ld l, a
    ld h, 0
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl                  ; BR * 32
    ld a, [wFoeBC]
    ld e, a
    ld d, 0
    add hl, de
    ld de, _SCRN1
    add hl, de
    ld a, [wFoeBH]
    ld b, a
.arow:
    push hl
    ld a, [wFoeBW]
    ld e, a
.acol:
    ld [hl], c
    inc hl
    dec e
    jr nz, .acol
    pop hl
    ld de, 32
    add hl, de
    dec b
    jr nz, .arow
    xor a, a
    ldh [rVBK], a
    ret

; Slots 5/6/7. Index 0 of ALL THREE is the arena sky, so a partly-filled foe tile
; (or a cleared arena cell) blends into the backdrop with no halo. The arena
; (slot 7) also carries the ground colours for the horizon band.
FoePalettes:
    ; RED zombie (slot 5)
    dw (27 << 10) | (28 << 5) | 24   ; 0 sky
    dw ( 2 << 10) | ( 2 << 5) |  9   ; 1 dark red (outline)
    dw ( 6 << 10) | ( 7 << 5) | 21   ; 2 rotten red (flesh)
    dw (20 << 10) | (24 << 5) | 30   ; 3 pale (teeth/eye glint)
    ; BLUE zombie (slot 6)
    dw (27 << 10) | (28 << 5) | 24   ; 0 sky
    dw (10 << 10) | ( 3 << 5) |  3   ; 1 dark blue
    dw (20 << 10) | (14 << 5) |  8   ; 2 blue-grey flesh
    dw (26 << 10) | (26 << 5) | 28   ; 3 pale
ArenaPalette:                   ; slot 7: the backdrop (sky + ground band)
    dw (27 << 10) | (28 << 5) | 24   ; 0 sky (also every foe's index 0)
    dw ( 6 << 10) | (17 << 5) | 10   ; 1 grass
    dw ( 4 << 10) | (11 << 5) |  6   ; 2 grass shadow
    dw ( 2 << 10) | ( 4 << 5) |  3   ; 3 dark earth
