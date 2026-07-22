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
    ld e, a
    ld a, BANK(bEnterBattleSurvivor)
    ld [rROMB0], a
    ld a, e
    call bEnterBattleSurvivor
    ld a, 1
    ld [rROMB0], a
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
    jp nz, PickFight            ; submenu: weapon / skill
    ; main menu: 0 Fight, 1 Party, 2 Item, 3 Flee
    ld a, [wBattleCursor]
    and a, a
    jr z, .toFight
    cp 3
    jp z, TryFlee
    ; Party (1) / Item (2): stubs until those slices land
    cp 1
    ld hl, MsgNoItems
    jr nz, .stub
    ld hl, MsgNoAllies
.stub:
    ld a, BS_MENU
    ld [wBattleMsgNext], a
    jp SetMessage
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
    ld a, b
    call CalcPlayerDamage       ; A = damage
    ld c, a
    ld a, [wFoeTarget]
    ld b, a
    ld a, c
    call HurtFoe                ; index B, damage A
    call AllFoesDead
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
; Damage helpers
; =============================================================================
; CalcPlayerDamage: A = base -> clampmin1(base + PLAYER_ATK>>2 - enemyDEF>>2).
; (The two `srl a`s are DMG_SHIFT=2; update both if that constant changes.)
CalcPlayerDamage:
    ld b, a
    ld a, PLAYER_ATK
    srl a
    srl a
    add a, b
    ld b, a
    ld a, [wEnemyDEF]
    srl a
    srl a
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
    call WeaponName
    ld c, 0
    call PutBoxLabel
    ld a, 1
    call WeaponName
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

; WeaponName / SkillName: A = index -> HL = name string pointer.
WeaponName:
    ld de, WeaponTable
    call DerefPtrTable
    ld de, WO_NAME
    add hl, de
    ld a, [hl+]
    ld h, [hl]
    ld l, a
    ret
SkillName:
    ld de, SkillTable
    call DerefPtrTable
    ld de, SO_NAME
    add hl, de
    ld a, [hl+]
    ld h, [hl]
    ld l, a
    ret

; WeaponRecord: -> HL = WeaponTable[wBattleWeapon] record.
WeaponRecord:
    ld a, [wBattleWeapon]
    ld de, WeaponTable
    jr DerefPtrTable
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
    ; message box panel (rows BOX_ROW_TOP..BOX_ROW_BOT) — like the talk box
    ld hl, _SCRN1 + BOX_ROW_TOP * 32
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
    ld hl, _SCRN1 + BOX_ROW_BOT * 32
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
    ld hl, _SCRN1 + (BOX_ROW_TOP + 1) * 32
    ld c, BOX_ROW_BOT - BOX_ROW_TOP - 1
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
MsgNoAllies: db "NO ALLIES YET", 0
MsgNoItems:  db "NO ITEMS YET", 0
MsgNotReady: db "NOT READY", 0
MsgHealed:   db "PATCHED UP", 0
MsgAimed:    db "AIMED HIT", 0
MsgApproach: db "THEY CLOSE IN", 0

; =============================================================================
; slice 2 — the approaching-zombie arena (docs task): up to MAX_FOES zombies
; shuffle toward the player as scaled BG sprites, and a free-moving crosshair
; (circle / figure-eight) replaces the horizontal red/amber/green zone bar.
; =============================================================================
SECTION FRAGMENT "Battle", ROMX

; Lane centre column per foe and the tier each starts at, so the crowd closes in
; from staggered depths (a faux-3D pack, not a rank). Index 0 leads.
FoeLaneCol:   db 10, 4, 15, 7
FoeStartTier: db 2, 1, 1, 0

; FoePtr: A = foe index -> HL = &wFoes[A]. Preserves BC (callers rely on it).
FoePtr:
    add a, a
    add a, a
    add a, a                    ; * FOE_STRUCT (8)
    ld l, a
    ld h, 0
    ld de, wFoes
    add hl, de
    ret

; FoeSeed: A = ZTYPE_*, HL = &foe (at FO_TYPE). Fills TYPE/MAXHP/HP/ATK/DEF from
; ZombieTable[A]; leaves HL at FO_TIER. Clobbers A-E, saved HL restored via stack.
FoeSeed:
    ld [hl], a                  ; FO_TYPE
    inc hl                      ; -> FO_MAXHP
    push hl
    add a, a
    ld e, a
    ld d, 0
    ld hl, ZombieTable
    add hl, de
    ld a, [hl+]
    ld h, [hl]
    ld l, a                     ; HL = row
    ld a, [hl+]                 ; ZO_MAXHP
    ld b, a
    ld a, [hl+]                 ; ZO_ATK
    ld c, a
    ld a, [hl]                  ; ZO_DEF
    ld d, a
    pop hl                      ; -> FO_MAXHP
    ld [hl], b                  ; MAXHP
    inc hl
    ld [hl], b                  ; HP = MAXHP
    inc hl
    ld [hl], c                  ; ATK
    inc hl
    ld [hl], d                  ; DEF
    inc hl                      ; -> FO_TIER
    ret

; SetupZombieFoes: wFoes[0].FO_TYPE holds the spotter's ZTYPE. Count nearby active
; pool zombies (>=1, capped MAX_FOES), seed each foe's stats/tier/type, and mirror
; foe 0 into the wEnemy* the HP-bar/tests read.
SetupZombieFoes:
    ld hl, wZombies + EO_ACTIVE
    ld de, ENT_SIZE
    ld b, MAX_ZOMBIES
    ld c, 0                     ; active count
.cnt:
    ld a, [hl]
    and a, a
    jr z, .cnext
    inc c
.cnext:
    add hl, de
    dec b
    jr nz, .cnt
    ld a, c
    and a, a
    jr nz, .have
    inc a                       ; at least the spotter
.have:
    cp MAX_FOES + 1
    jr c, .cap
    ld a, MAX_FOES
.cap:
    ld [wFoeCount], a
    ld c, a                     ; C = count (loop guard)
    ld b, 0                     ; B = index
.seed:
    ld a, b
    call FoePtr                 ; HL = &foe[B] (preserves BC)
    ld a, [wFoes + FO_TYPE]     ; foe 0's type is the unchanging base
    add a, b
    and 1                       ; type = (base + index) & 1
    push bc                     ; FoeSeed clobbers BC
    call FoeSeed                ; fills struct, HL -> FO_TIER
    pop bc
    push hl                     ; save the FO_TIER destination
    ld a, b
    ld e, a
    ld d, 0
    ld hl, FoeStartTier
    add hl, de
    ld a, [hl]                  ; start tier for this foe
    pop hl
    ld [hl], a                  ; FO_TIER
    inc b
    ld a, b
    cp c
    jr c, .seed
    xor a, a
    ld [wFoeTarget], a
    jp MirrorFoe                ; A = 0 -> wEnemy* mirrors foe 0 (tail call)

; SetupSurvivorFoe: one foe built from the RED stats LoadZombieRow left in wEnemy*
; (a hostile survivor). Drawn as the persona portrait, always in melee.
SetupSurvivorFoe:
    ld a, 1
    ld [wFoeCount], a
    xor a, a
    ld [wFoeTarget], a
    ld hl, wFoes
    ld a, ZTYPE_RED
    ld [hl+], a                 ; FO_TYPE (unused for tint; drawn as a portrait)
    ld a, [wEnemyMaxHP]
    ld [hl+], a                 ; FO_MAXHP
    ld [hl], a                  ; FO_HP = MAXHP
    inc hl
    ld a, [wEnemyATK]
    ld [hl+], a                 ; FO_ATK
    ld a, [wEnemyDEF]
    ld [hl+], a                 ; FO_DEF
    ld a, FOE_TIER_MAX
    ld [hl], a                  ; FO_TIER (always melee)
    ret

; MirrorFoe: A = index -> copy its MAXHP/HP/ATK/DEF into wEnemy* (the HP bar +
; integration tests read these). Clobbers A, DE, HL.
MirrorFoe:
    call FoePtr
    inc hl                      ; FO_MAXHP
    ld a, [hl+]
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
    inc hl
    inc hl                      ; FO_HP
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
    ; colBase = clamp(laneCol[index] - wt/2, 0, VIEW_COLS - wt)
    ld a, c
    ld e, a
    ld d, 0
    ld hl, FoeLaneCol
    add hl, de
    ld a, [hl]                  ; centre col
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
    ld b, 16                    ; 2 palettes x 4 colours x 2 bytes
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
    jr z, .miss
    push af                     ; save the zone
    ld a, [wFoeTarget]
    call FoePtr
    ld de, FO_DEF
    add hl, de
    ld a, [hl]
    ld [wEnemyDEF], a           ; CalcPlayerDamage reads wEnemyDEF
    call WeaponRecord           ; HL = record
    ld a, [hl]                  ; WO_DMG
    call CalcPlayerDamage       ; A = base damage
    ld c, a
    pop af                      ; zone
    push af
    cp ZONE_CRIT
    jr nz, .noCrit
    call WeaponRecord
    inc hl                      ; WO_CRIT
    ld a, [hl]
    add a, c
    jr nc, .cok
    ld a, 255
.cok:
    ld c, a
.noCrit:
    ld a, [wFoeTarget]
    ld b, a
    ld a, c
    call HurtFoe                ; index B, damage A
    call AllFoesDead
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
    inc hl
    inc hl                      ; FO_HP
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
    inc hl
    inc hl                      ; FO_HP
    ld a, [hl]
    sub c
    jr nc, .ok
    xor a, a
.ok:
    ld [hl], a
    ld a, b
    ld [wFoeTarget], a
    call MirrorFoe
    ld a, 1
    ld [wArenaDirty], a
    ; a survivor foe has a single enemy HP bar (no arena pips) — refresh it
    ld a, [wBattleEKind]
    cp EPK_PERSONA
    ret nz
    jp EnqEnemyHP

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

; AllFoesDead: -> A = 1 if every foe HP == 0, else 0.
AllFoesDead::
    ld a, [wFoeCount]
    ld c, a
    ld b, 0
.lp:
    ld a, b
    call FoePtr
    inc hl
    inc hl                      ; FO_HP
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
    inc hl
    inc hl                      ; FO_HP
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
    inc [hl]                    ; shuffle one size/step closer
    jr .skip
.bite:
    pop hl
    push hl
    ld de, FO_ATK
    add hl, de
    ld a, [hl]                  ; FO_ATK
    sub PLAYER_DEF >> 2         ; DMG_SHIFT = 2 (assemble-time constant)
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
    ld hl, _SCRN1 + FOE_ARENA_TOP * 32
    ld c, FOE_GROUND_ROW - FOE_ARENA_TOP + 1
.crow:
    ld b, VIEW_COLS
    push hl
    ld a, FONT_BASE             ; paper
.ccol:
    ld [hl+], a
    dec b
    jr nz, .ccol
    pop hl
    ld de, 32
    add hl, de
    dec c
    jr nz, .crow
    ld a, [wFoeCount]
    ld b, a
.pf:
    dec b                       ; index = count-1 .. 0 (draw the lead last, on top)
    ld a, b
    call FoePtr
    inc hl
    inc hl                      ; FO_HP
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
    ret

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
    ; HP pip level = HP * 8 / MAXHP (0..8) via the shared HP-bar helper >> 3
    inc hl                      ; FO_MAXHP
    ld a, [hl+]
    ld c, a                     ; C = MAXHP
    ld a, [hl]                  ; FO_HP
    call BarSub                 ; A = HP * 64 / MAXHP
    srl a
    srl a
    srl a                       ; >> 3 -> 0..8
    ld [wFoePipLvl], a
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
    jr z, .pip
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

.pip:
    ; HP pip: a 1-cell bar (TILE_BAR_BASE + level) in the row above the foe, at
    ; its centre column. Tile ids -> bank 0; the pip keeps the arena's UI palette.
    xor a, a
    ldh [rVBK], a
    ld a, [wFoeBR]             ; row above the block
    dec a
    ld l, a
    ld h, 0
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl                  ; (BR-1) * 32
    ld a, [wFoeBW]
    srl a                       ; W / 2
    ld d, 0
    ld e, a
    add hl, de
    ld a, [wFoeBC]
    ld e, a
    add hl, de                  ; + BC + W/2 (centre column)
    ld de, _SCRN1
    add hl, de
    ld a, [wFoePipLvl]
    add a, TILE_BAR_BASE
    ld [hl], a
    ; pip attribute -> the UI palette (CGB), so it reads as the grey meter tile
    ldh a, [hIsCGB]
    and a, a
    ret z
    ld a, 1
    ldh [rVBK], a
    ld a, PAL_BG_UI
    ld [hl], a
    xor a, a
    ldh [rVBK], a
    ret

FoePalettes:                    ; slots 5/6, index 0 = arena paper (no halo)
    ; RED zombie (slot 5)
    dw (26 << 10) | (30 << 5) | 31   ; 0 paper
    dw ( 2 << 10) | ( 2 << 5) |  9   ; 1 dark red (outline)
    dw ( 6 << 10) | ( 7 << 5) | 21   ; 2 rotten red (flesh)
    dw (20 << 10) | (24 << 5) | 30   ; 3 pale (teeth/eye glint)
    ; BLUE zombie (slot 6)
    dw (26 << 10) | (30 << 5) | 31   ; 0 paper
    dw (10 << 10) | ( 3 << 5) |  3   ; 1 dark blue
    dw (20 << 10) | (14 << 5) |  8   ; 2 blue-grey flesh
    dw (26 << 10) | (26 << 5) | 28   ; 3 pale
