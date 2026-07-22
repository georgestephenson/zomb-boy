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
    call LoadZombieRow          ; type -> cache stats + name + portrait idx
    ld a, EPK_ZOMBIE
    ld [wBattleEKind], a
    jr bEnterBattleScreen

bEnterBattleSurvivor:
    ld [wBattleEIdx], a
    ld a, EPK_PERSONA
    ld [wBattleEKind], a
    ld a, ZTYPE_RED
    call LoadZombieRow          ; borrow RED's stats...
    ld a, $FF
    ld [wBattleFoe], a          ; ...but there's no pool zombie to remove
    ld hl, NameSurvivor
    ld a, l
    ld [wEnemyName], a
    ld a, h
    ld [wEnemyName + 1], a
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
    call ShowEnemyPortrait
    call EnqEnemyHP             ; both HP bars into the queue...
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
    ld [wCrossDir], a
    ld [wBattleWeapon], a
    ld [wSkillCd + 0], a
    ld [wSkillCd + 1], a
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
    call BattlePaintBox
    call DrawBattleSprites
    ld a, [wBattleState]
    cp BS_AIM
    jp z, .aim
    cp BS_MSG
    jp z, .msg
    cp BS_ENEMY
    jp z, EnemyTurn
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
; --- BS_AIM: sweep the crosshair; A locks and resolves ---
.aim:
    call SweepCrosshair
    ld a, [wNewKeys]
    and PAD_A
    ret z
    jp ResolveAim

; PickFight: A-press on the Fight submenu. Cursor 0/1 = weapon (aim), 2/3 = skill.
PickFight:
    ld a, [wBattleCursor]
    cp 2
    jr nc, .skill
    ; weapon: start the crosshair minigame
    ld [wBattleWeapon], a
    xor a, a
    ld [wCrossX], a
    ld [wCrossDir], a
    ld hl, MsgFire
    call ComposeLine
    ld a, BS_AIM
    ld [wBattleState], a
    ret
.skill:
    sub 2
    jp UseSkill

; ResolveAim: the crosshair is locked. Zone -> damage -> enemy (or win).
ResolveAim:
    call CrossZone
    ld b, a                     ; B = zone
    cp ZONE_MISS
    jr z, .miss
    call WeaponRecord           ; HL = weapon record
    ld a, [hl]                  ; WO_DMG
    push hl
    push bc
    call CalcPlayerDamage       ; A = formula damage (clobbers B,C)
    pop bc                      ; B = zone
    pop hl                      ; HL = record
    ld c, a                     ; C = damage
    ld a, b
    cp ZONE_CRIT
    jr nz, .msgpick
    inc hl                      ; WO_CRIT
    ld a, [hl]
    add a, c                    ; crit bonus, clamped to 255
    jr nc, .critok
    ld a, 255
.critok:
    ld c, a
.msgpick:
    ld a, b
    cp ZONE_CRIT
    ld hl, MsgCrit
    jr z, .apply
    ld hl, MsgHit
.apply:
    push hl                     ; save the hit message
    ld a, c
    call HurtEnemy              ; Z if the enemy is down
    pop hl
    jr nz, .enemyTurn
    ; enemy defeated -> win (override the message)
    ld a, BO_WIN
    ld [wBattleOutcome], a
    ld hl, MsgWin
    ld a, BS_END
    ld [wBattleMsgNext], a
    jp SetMessage
.enemyTurn:
    ld a, BS_ENEMY
    ld [wBattleMsgNext], a
    jp SetMessage
.miss:
    ld hl, MsgMiss
    ld a, BS_ENEMY
    ld [wBattleMsgNext], a
    jp SetMessage

; EnemyTurn: the enemy attacks (transient state; sets BS_MSG immediately).
EnemyTurn:
    ld a, [wEnemyATK]
    ld b, a
    ld a, PLAYER_DEF
    srl a
    srl a                       ; PLAYER_DEF >> DMG_SHIFT (=2)
    ld c, a
    ld a, b
    sub c
    jr nc, .ok
    xor a, a
.ok:
    and a, a
    jr nz, .go
    inc a                       ; min 1
.go:
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
    ; SK_AIMED — guaranteed hit of crit strength
    ld a, b
    call CalcPlayerDamage
    call HurtEnemy
    jr nz, .aimAlive
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

; HurtEnemy: A = damage -> enemy HP saturating-sub; redraw bar; Z if HP == 0.
HurtEnemy:
    ld b, a
    ld a, [wEnemyHP]
    sub b
    jr nc, .ok
    xor a, a
.ok:
    ld [wEnemyHP], a
    call EnqEnemyHP
    ld a, [wEnemyHP]
    and a, a
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

; =============================================================================
; Crosshair minigame
; =============================================================================
; SweepCrosshair: bounce wCrossX between 0 and CROSS_MAX at CROSS_SPEED px/frame.
SweepCrosshair:
    ld a, [wCrossDir]
    and a, a
    jr nz, .minus
    ld a, [wCrossX]
    add a, CROSS_SPEED
    cp CROSS_MAX
    jr c, .store
    ld a, CROSS_MAX
    ld [wCrossX], a
    ld a, 1
    ld [wCrossDir], a
    ret
.minus:
    ld a, [wCrossX]
    sub CROSS_SPEED
    jr c, .zero
    ld [wCrossX], a
    ret
.zero:
    xor a, a
    ld [wCrossX], a
    ld [wCrossDir], a
    ret
.store:
    ld [wCrossX], a
    ret

; CrossZone: -> A = ZONE_* for the current wCrossX (matches the ZoneBar layout).
CrossZone:
    ld a, [wCrossX]
    sub CROSS_CENTRE
    jr nc, .pos
    cpl
    inc a                       ; A = |x - centre|
.pos:
    cp GREEN_HALF
    jr c, .crit
    cp AMBER_HALF
    jr c, .hit
    ld a, ZONE_MISS
    ret
.crit:
    ld a, ZONE_CRIT
    ret
.hit:
    ld a, ZONE_HIT
    ret

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
    ld a, CROSS_OAM_Y
    ld [wShadowOAM + 4], a
    ld a, [wCrossX]
    add a, CROSS_OAM_X0
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
    ; enemy name plate (row 0)
    ld hl, wEnemyName
    ld a, [hl+]
    ld e, a
    ld d, [hl]                  ; DE = name string
    ld hl, _SCRN1 + EN_NAME_ROW * 32
    call PutsHL
    ; HP glyphs
    ld a, TILE_HUD_HP
    ld [_SCRN1 + EN_HP_ROW * 32 + BHP_GLYPH_COL], a
    ld [_SCRN1 + PL_HP_ROW * 32 + BHP_GLYPH_COL], a
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
    ; enemy portrait frame + zone bar
    call DrawEnemyFrame
    ld hl, _SCRN1 + ZONE_ROW * 32 + ZONE_COL0
    ld de, ZoneBarTiles
    ld b, ZONE_CELLS
.zone:
    ld a, [de]
    ld [hl+], a
    inc de
    dec b
    jr nz, .zone
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
    ld hl, _SCRN1 + ZONE_ROW * 32 + ZONE_COL0
    ld a, PAL_BG_ZONE
    ld b, ZONE_CELLS
.zattr:
    ld [hl+], a
    dec b
    jr nz, .zattr
    xor a, a
    ldh [rVBK], a
    ; zone bar palette -> slot PAL_BG_ZONE
    ld a, BCPSF_AUTOINC | (PAL_BG_ZONE * 8)
    ldh [rBCPS], a
    ld hl, ZonePalette
    ld b, 8
.zpal:
    ld a, [hl+]
    ldh [rBCPD], a
    dec b
    jr nz, .zpal
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

; ShowEnemyPortrait: load the enemy's 56x56 portrait exactly like talk's
; ShowPortrait, choosing ZombiePortraitTable or PortraitTable by wBattleEKind.
; Both tables share BANK[2]; bank 1 is restored before returning. This is the one
; battle routine that maps another bank INLINE, so it lives in ROM0 (always
; mapped) — a banked copy would unmap its own code the moment it switched.
SECTION "Battle Portrait", ROM0
ShowEnemyPortrait:
    ld a, BANK(ZombiePortraitTable)
    ld [rROMB0], a
    ld a, [wBattleEKind]
    and a, a
    jr nz, .persona
    ld hl, ZombiePortraitTable
    jr .idx
.persona:
    ld hl, PortraitTable
.idx:
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
; Target bar: 16 cells, symmetric — red edges (miss), amber band (hit), a tiny
; green centre (crit). Matches CrossZone's GREEN_HALF/AMBER_HALF thresholds.
ZoneBarTiles:
    db TILE_ZONE_RED,   TILE_ZONE_RED,   TILE_ZONE_RED,   TILE_ZONE_AMBER
    db TILE_ZONE_AMBER, TILE_ZONE_AMBER, TILE_ZONE_AMBER, TILE_ZONE_GREEN
    db TILE_ZONE_GREEN, TILE_ZONE_AMBER, TILE_ZONE_AMBER, TILE_ZONE_AMBER
    db TILE_ZONE_AMBER, TILE_ZONE_RED,   TILE_ZONE_RED,   TILE_ZONE_RED

ZonePalette:                    ; slot PAL_BG_ZONE: {rail, red, amber, green}
    dw ( 4 << 10) | ( 4 << 5) |  4
    dw ( 4 << 10) | ( 4 << 5) | 28
    dw ( 2 << 10) | (18 << 5) | 31
    dw ( 4 << 10) | (28 << 5) |  6

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
