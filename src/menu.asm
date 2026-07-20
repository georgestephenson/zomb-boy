; =============================================================================
; menu.asm — the Pokemon-style START/pause menu (MODE_MENU).
;
; START in the overworld opens a full-screen menu on SCRN1 (the same layer the
; talk screen uses; the world map on SCRN0 is left intact so closing is a cheap
; LCDC flip + SetScroll). The game is *paused* while it's up: the menu is its
; own main-loop branch, so UpdateSurvival never runs and the clock/meters freeze.
;
; Root options (RootLabels): PARTY EQUIP BAG STATUS SAVE OPTIONS EXIT.
;   PARTY   — up to four members; slot 0 is the player, "ZOMB BOY".
;   EQUIP   — two weapons + armour + a charm per member (picker from the bag).
;   BAG     — the inventory (weapons, consumables, key items), a scrolling list.
;   STATUS  — the player avatar + HP/food/energy/time + position vs the spawn.
;   SAVE    — write a battery-backed save to cart RAM (MBC5+RAM, see items.asm).
;   OPTIONS — game config (music on/off; the rest TBC).
;   EXIT    — soft-reset back to the title screen.
;
; Screen mechanics mirror talk.asm: each panel is built with the LCD OFF inside
; VBlank (WaitVBlank first; the build then runs straight through), and the window
; HUD is off while the menu owns SCRN1 — ExitMenu restores it via DrawHUDRow.
; Panels are rebuilt whole on every navigation (RebuildMenu); the cursor OBJ is
; the only thing that moves between rebuilds.
; =============================================================================
INCLUDE "hardware.inc"
INCLUDE "include/constants.inc"
INCLUDE "include/charmap.inc"

SECTION "Menu", ROM0

; -----------------------------------------------------------------------------
; EnterMenu: open the pause menu from the overworld (START). Flush any pending
; world strip, build the root panel with the LCD off, then flip to SCRN1.
; -----------------------------------------------------------------------------
EnterMenu::
.flush:
    ld a, [wStrKind]
    and a, a
    jr z, .flushed
    call WaitVBlank
    call BlitStream
    jr .flush
.flushed:
    ld a, MSCR_ROOT
    ld [wMenuScreen], a
    call WaitVBlank
    xor a, a
    ldh [rLCDC], a             ; LCD off (inside VBlank)
    call BuildRoot
    call DrawMenuSprites
    ld a, HIGH(wShadowOAM)
    call hOAMDMA               ; LCD off: DMA any time
    xor a, a
    ldh [rSCX], a
    ldh [rSCY], a
    ld a, MODE_MENU
    ld [wGameMode], a
    jp MenuLCDOn

; -----------------------------------------------------------------------------
; ExitMenu: back to the overworld — SCRN0 still holds the world map, so repaint
; the sprites and flip the map select + window back on inside VBlank (like
; ExitTalkScreen). BuildRoot wiped SCRN1 row 0, so DrawHUDRow restores the bar.
; -----------------------------------------------------------------------------
ExitMenu:
    ld a, MODE_OVERWORLD
    ld [wGameMode], a
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

MenuLCDOn:
    ld a, LCDCF_ON | LCDCF_BGON | LCDCF_OBJON | LCDCF_OBJ8 | LCDCF_BG8000 | LCDCF_BG9C00
    ldh [rLCDC], a
    ret

; -----------------------------------------------------------------------------
; UpdateMenu: one logic frame. Position the cursor, then dispatch to the active
; panel's handler. Panels resolve navigation by rebuilding via Goto* helpers.
; -----------------------------------------------------------------------------
UpdateMenu::
    call DrawMenuCursor
    ld a, [wMenuScreen]
    cp MSCR_ROOT
    jp z, UpdRoot
    cp MSCR_EQUIP
    jp z, UpdEquip
    cp MSCR_PICK
    jp z, UpdPick
    cp MSCR_BAG
    jp z, UpdBag
    cp MSCR_OPTIONS
    jp z, UpdOptions
    cp MSCR_STATUS
    jp z, UpdStatus
    ; PARTY / SAVE are view-only: A or B returns to the root list.
    ld a, [wNewKeys]
    and PAD_A | PAD_B
    ret z
    jp GotoRoot

; STATUS: A/B returns to the root; LEFT/RIGHT flips between the two pages.
UpdStatus:
    ld a, [wNewKeys]
    and PAD_A | PAD_B
    jp nz, GotoRoot
    ld a, [wNewKeys]
    and PAD_LEFT | PAD_RIGHT
    ret z
    ld a, [wStatusPage]
    xor 1                      ; two pages -> toggle
    ld [wStatusPage], a
    jp RebuildMenu

; =============================================================================
; Root list
; =============================================================================
UpdRoot:
    ld a, [wNewKeys]
    and PAD_B | PAD_START
    jp nz, ExitMenu            ; B / START close the menu
    ld a, [wNewKeys]
    bit 2, a                   ; up
    jr z, .noUp
    ld a, [wRootCursor]
    and a, a
    jr z, .noUp
    dec a
    ld [wRootCursor], a
.noUp:
    ld a, [wNewKeys]
    bit 3, a                   ; down
    jr z, .noDown
    ld a, [wRootCursor]
    inc a
    cp ROOT_COUNT
    jr nc, .noDown
    ld [wRootCursor], a
.noDown:
    ld a, [wNewKeys]
    and PAD_A
    ret z
    ld a, [wRootCursor]
    cp 0
    jp z, GotoParty
    cp 1
    jp z, GotoEquip
    cp 2
    jp z, GotoBag
    cp 3
    jp z, GotoStatus
    cp 4
    jr z, .save
    cp 5
    jp z, GotoOptions
    ; 6 = EXIT -> soft-reset to the title screen
    di
    jp Start
.save:
    call DoSave
    ld a, 1
    ld [wSaveDone], a
    jp GotoSave

; =============================================================================
; Equip (member 0 for now) + the item picker
; =============================================================================
UpdEquip:
    ld a, [wNewKeys]
    and PAD_B
    jp nz, GotoRoot
    ld a, [wNewKeys]
    bit 2, a
    jr z, .noUp
    ld a, [wMenuCursor]
    and a, a
    jr z, .noUp
    dec a
    ld [wMenuCursor], a
.noUp:
    ld a, [wNewKeys]
    bit 3, a
    jr z, .noDown
    ld a, [wMenuCursor]
    inc a
    cp EQUIP_SLOTS
    jr nc, .noDown
    ld [wMenuCursor], a
.noDown:
    ld a, [wNewKeys]
    and PAD_A
    ret z
    ld a, [wMenuCursor]
    ld [wPickSlot], a
    jp GotoPick

UpdPick:
    call MenuListMove
    ld a, [wNewKeys]
    and PAD_B
    jp nz, GotoEquip
    ld a, [wNewKeys]
    and PAD_A
    ret z
    ; equip wPickMap[wListCur] into member*EQUIP_SLOTS + slot
    ld a, [wListCur]
    ld e, a
    ld d, 0
    ld hl, wPickMap
    add hl, de
    ld a, [hl]                 ; chosen item id (0 = unequip)
    ld b, a
    ld a, [wPickMember]
    add a, a
    add a, a                   ; * EQUIP_SLOTS (4)
    ld c, a
    ld a, [wPickSlot]
    add a, c
    ld e, a
    ld d, 0
    ld hl, wPartyEquip
    add hl, de
    ld a, b
    ld [hl], a
    jp GotoEquip

; =============================================================================
; Bag (scrolling list, view-only)
; =============================================================================
UpdBag:
    call MenuListMove
    ld a, [wNewKeys]
    and PAD_B
    ret z
    jp GotoRoot

; =============================================================================
; Options
; =============================================================================
UpdOptions:
    ld a, [wNewKeys]
    and PAD_B
    jp nz, GotoRoot
    ld a, [wNewKeys]
    and PAD_A | PAD_LEFT | PAD_RIGHT
    ret z
    ; toggle music. wOptMusic gates UpdateSound in the main loop; unrouting the
    ; channels (NR51=0) silences the held notes while it's gated off (the driver
    ; owns NR50/the volume, so muting there wouldn't stick). Re-routing on resume;
    ; the driver re-owns the channels on its next tick.
    ld a, [wOptMusic]
    xor 1
    ld [wOptMusic], a
    and a, a
    jr z, .mute
    ld a, $FF                  ; every channel routed to both speakers again
    jr .setRoute
.mute:
    xor a, a                   ; unroute all channels -> silence
.setRoute:
    ldh [rNR51], a
    jp GotoOptions             ; rebuild to refresh the ON/OFF text

; =============================================================================
; Generic scrolling-list cursor (BAG, equip picker). Uses wListN/Cur/Top.
; =============================================================================
MenuListMove:
    ld a, [wNewKeys]
    bit 2, a                   ; up
    jr z, .noUp
    ld a, [wListCur]
    and a, a
    jr z, .noUp
    dec a
    ld [wListCur], a
    ld a, [wListTop]           ; scroll up if the cursor went above the window
    ld b, a
    ld a, [wListCur]
    cp b
    jr nc, .noUp
    ld [wListTop], a
.noUp:
    ld a, [wNewKeys]
    bit 3, a                   ; down
    jr z, .noDown
    ld a, [wListCur]
    inc a
    ld b, a
    ld a, [wListN]
    cp b
    jr c, .noDown              ; N < cur+1: at the bottom
    jr z, .noDown              ; N == cur+1: at the bottom
    ld a, b
    ld [wListCur], a
    ld a, [wListTop]           ; scroll down if the cursor left the window
    add a, MENU_LIST_ROWS
    ld b, a
    ld a, [wListCur]
    cp b
    jr c, .noDown              ; still visible
    ld a, [wListCur]
    sub MENU_LIST_ROWS - 1
    ld [wListTop], a
.noDown:
    ret

; =============================================================================
; Screen transitions — set wMenuScreen (+ list/cursor state), then rebuild.
; =============================================================================
GotoRoot:
    ld a, MSCR_ROOT
    ld [wMenuScreen], a
    jp RebuildMenu
GotoParty:
    ld a, MSCR_PARTY
    ld [wMenuScreen], a
    jp RebuildMenu
GotoEquip:
    xor a, a
    ld [wMenuCursor], a
    ld [wPickMember], a
    ld a, MSCR_EQUIP
    ld [wMenuScreen], a
    jp RebuildMenu
GotoPick:
    call BuildPickList
    ld a, MSCR_PICK
    ld [wMenuScreen], a
    jp RebuildMenu
GotoBag:
    call BuildBagList
    ld a, MSCR_BAG
    ld [wMenuScreen], a
    jp RebuildMenu
GotoStatus:
    xor a, a
    ld [wStatusPage], a        ; always open on the vitals page
    ld a, MSCR_STATUS
    ld [wMenuScreen], a
    jp RebuildMenu
GotoOptions:
    ld a, MSCR_OPTIONS
    ld [wMenuScreen], a
    jp RebuildMenu
GotoSave:
    ld a, MSCR_SAVE
    ld [wMenuScreen], a
    jp RebuildMenu

; RebuildMenu: repaint the active panel with the LCD off, refresh sprites, DMA,
; and turn the LCD back on. Runs entirely within one WaitVBlank window's worth
; of setup (the build is bounded), same discipline as EnterTalk.
RebuildMenu:
    call WaitVBlank
    xor a, a
    ldh [rLCDC], a
    call BuildCurrent
    call DrawMenuSprites
    ld a, HIGH(wShadowOAM)
    call hOAMDMA
    jp MenuLCDOn

BuildCurrent:
    ld a, [wMenuScreen]
    cp MSCR_PARTY
    jp z, BuildParty
    cp MSCR_EQUIP
    jp z, BuildEquip
    cp MSCR_PICK
    jp z, BuildPick
    cp MSCR_BAG
    jp z, BuildBag
    cp MSCR_STATUS
    jp z, BuildStatus
    cp MSCR_OPTIONS
    jp z, BuildOptions
    cp MSCR_SAVE
    jp z, BuildSave
    jp BuildRoot

; =============================================================================
; Sprites: the cursor (OBJ slot 0) + the status avatar (slot 1).
; =============================================================================
DrawMenuSprites:
    ld hl, wShadowOAM          ; hide all 40 sprites first
    ld b, 160
    xor a, a
.clr:
    ld [hl+], a
    dec b
    jr nz, .clr
    call DrawMenuCursor
    ld a, [wMenuScreen]
    cp MSCR_STATUS
    ret nz
    ld a, [wStatusPage]
    and a, a
    ret nz                     ; stats page: hide the avatar (keeps its column clear)
    ; player avatar (down sprite) on the status screen
    ld a, STATUS_AVATAR_Y
    ld [wShadowOAM + OAM_MENU_AVATAR * 4 + 0], a
    ld a, STATUS_AVATAR_X
    ld [wShadowOAM + OAM_MENU_AVATAR * 4 + 1], a
    ld a, TILE_PLAYER_BASE
    ld [wShadowOAM + OAM_MENU_AVATAR * 4 + 2], a
    xor a, a                   ; OBJ palette 0 (the player's)
    ld [wShadowOAM + OAM_MENU_AVATAR * 4 + 3], a
    ret

; DrawMenuCursor: place the arrow OBJ next to the active item, or hide it on the
; screens that have no cursor. Cursor column is one left of the list column.
DrawMenuCursor:
    ld a, [wMenuScreen]
    cp MSCR_ROOT
    jr z, .root
    cp MSCR_EQUIP
    jr z, .equip
    cp MSCR_OPTIONS
    jr z, .opt
    cp MSCR_BAG
    jr z, .list
    cp MSCR_PICK
    jr z, .list
    xor a, a                   ; no cursor on this screen
    ld [wShadowOAM + OAM_MENU_CURSOR * 4], a
    ret
.root:
    ld a, [wRootCursor]
    add a, MENU_BODY_ROW
    jr SetCursorAt
.equip:
    ld a, [wMenuCursor]
    add a, MENU_BODY_ROW + 2
    jr SetCursorAt
.opt:
    ld a, [wMenuCursor]
    add a, MENU_BODY_ROW
    jr SetCursorAt
.list:
    ld a, [wListCur]
    ld b, a
    ld a, [wListTop]
    ld c, a
    ld a, b
    sub c                      ; row within the visible window
    add a, MENU_BODY_ROW
    ; fall through

; SetCursorAt: A = BG row -> place the cursor OBJ (slot 0) at that row, column
; MENU_LIST_COL - 1. Uses the talk cursor tile + amber OBJ palette 2.
SetCursorAt:
    add a, a
    add a, a
    add a, a                   ; * 8 px
    add a, 16                  ; OAM Y bias
    ld [wShadowOAM + OAM_MENU_CURSOR * 4 + 0], a
    ld a, (MENU_LIST_COL - 1) * 8 + 8
    ld [wShadowOAM + OAM_MENU_CURSOR * 4 + 1], a
    ld a, TILE_CURSOR
    ld [wShadowOAM + OAM_MENU_CURSOR * 4 + 2], a
    ld a, 2
    ld [wShadowOAM + OAM_MENU_CURSOR * 4 + 3], a
    ret

; =============================================================================
; Panel builders (LCD off). Each starts from a cleared, framed base + header.
; =============================================================================
BuildRoot:
    ld hl, HdrMenu
    call BuildBase
    ld c, 0
.loop:
    push bc
    ld a, c
    add a, MENU_BODY_ROW
    call RowAddr
    ld d, h
    ld e, l
    ld a, c
    add a, a                   ; * 2 (dw table)
    ld l, a
    ld h, 0
    ld bc, RootLabels
    add hl, bc
    ld a, [hl+]
    ld h, [hl]
    ld l, a
    call MPutsDE
    pop bc
    inc c
    ld a, c
    cp ROOT_COUNT
    jr c, .loop
    ret

BuildParty:
    ld hl, HdrParty
    call BuildBase
    call RecalcLevel           ; keep member 0's level current for display
    ld c, 0
.loop:
    push bc
    ld a, c
    add a, a                   ; two rows per member (air between)
    add a, MENU_BODY_ROW
    call RowAddr
    ld d, h
    ld e, l
    ld a, [wPartyCount]
    ld b, a
    ld a, c
    cp b
    jr nc, .empty
    ld hl, NameZomb            ; only member 0 exists so far
    call MPutsDE
    ld hl, LblLV               ; "  LV " + level
    call MPutsDE
    pop bc                     ; recover the member index (c)
    push bc
    ld a, c
    push de                    ; keep the value cell across the table index
    ld e, a
    ld d, 0
    ld hl, wPartyLevel         ; member c's level (only 0 populated so far)
    add hl, de
    ld a, [hl]
    pop de
    call PutNumDE
    jr .next
.empty:
    ld hl, NameEmpty
    call MPutsDE
.next:
    pop bc
    inc c
    ld a, c
    cp MAX_PARTY
    jr c, .loop
    ret

BuildEquip:
    ld hl, HdrEquip
    call BuildBase
    ld a, MENU_BODY_ROW
    call RowAddr
    ld d, h
    ld e, l
    ld hl, NameZomb
    call MPutsDE
    ld c, 0
.loop:
    push bc
    ld a, c
    add a, MENU_BODY_ROW + 2
    call RowAddr
    ld d, h
    ld e, l
    ld a, c
    add a, a
    ld l, a
    ld h, 0
    ld bc, EquipLabels
    add hl, bc
    ld a, [hl+]
    ld h, [hl]
    ld l, a
    call MPutsDE               ; slot label; DE advanced
    pop bc
    push bc
    push de                    ; save the value dest across GetItemName
    ld a, c
    ld e, a
    ld d, 0
    ld hl, wPartyEquip         ; member 0: slot index == c
    add hl, de
    ld a, [hl]
    call GetItemName
    pop de
    call MPutsDE
    pop bc
    inc c
    ld a, c
    cp EQUIP_SLOTS
    jr c, .loop
    ret

BuildBag:
    ld hl, HdrBag
    call BuildBase
    ld a, [wListN]
    and a, a
    jr z, .empty
    ld a, [wListTop]
    ld c, a                    ; bag index
    ld b, 0                    ; screen row offset
.row:
    ld a, b
    cp MENU_LIST_ROWS
    ret z
    ld a, c
    ld hl, wListN
    cp [hl]
    ret nc
    push bc
    ld a, c
    add a, a
    ld e, a
    ld d, 0
    ld hl, wBag
    add hl, de
    ld a, [hl+]
    ld [wMenuId], a
    ld a, [hl]
    ld [wMenuCount], a
    ld a, b
    add a, MENU_BODY_ROW
    call RowAddr
    push hl                    ; save dest across GetItemName
    ld a, [wMenuId]
    call GetItemName
    pop de
    call MPutsDE
    ld a, FONT_BASE            ; space
    ld [de], a
    inc de
    ld a, [wMenuCount]
    call PutNumDE
    pop bc
    inc c
    inc b
    jr .row
.empty:
    ld a, MENU_BODY_ROW
    call RowAddr
    ld d, h
    ld e, l
    ld hl, TxtEmpty
    call MPutsDE
    ret

BuildPick:
    ld hl, HdrEquip
    call BuildBase
    ld a, [wListTop]
    ld c, a
    ld b, 0
.row:
    ld a, b
    cp MENU_LIST_ROWS
    ret z
    ld a, c
    ld hl, wListN
    cp [hl]
    ret nc
    push bc
    ld a, c
    ld e, a
    ld d, 0
    ld hl, wPickMap
    add hl, de
    ld a, [hl]
    ld [wMenuId], a
    ld a, b
    add a, MENU_BODY_ROW
    call RowAddr
    push hl
    ld a, [wMenuId]
    call GetItemName
    pop de
    call MPutsDE
    pop bc
    inc c
    inc b
    jr .row

; STATUS is two pages (LEFT/RIGHT flips wStatusPage): page 0 = vitals (level, XP,
; the survival meters, clock, position), page 1 = the six stat points.
BuildStatus:
    ld hl, HdrStatus
    call BuildBase
    call RecalcLevel           ; XP may have changed (battles); refresh the level
    ld a, MENU_BODY_ROW        ; the name plate heads both pages
    call RowAddr
    ld d, h
    ld e, l
    ld hl, NameZomb
    call MPutsDE
    ld a, [wStatusPage]
    and a, a
    jp nz, BuildStatusStats
    ; ---- page 0: level / experience ----
    ld a, MENU_BODY_ROW + 1
    ld hl, LblStatLevel
    call StatLine
    ld a, [wPartyLevel]
    call PutNumDE
    ld a, MENU_BODY_ROW + 2
    ld hl, LblStatEXP
    call StatLine
    ld a, [wPartyXP]
    ld l, a
    ld a, [wPartyXP+1]
    ld h, a
    call PutNum16DE
    ld a, MENU_BODY_ROW + 3
    ld hl, LblStatNext
    call StatLine
    push de                    ; XPToNext clobbers DE (the value cell)
    call XPToNext              ; HL = XP remaining, carry set at MAX_LEVEL
    pop de
    jr c, .maxed
    call PutNum16DE
    jr .meters
.maxed:
    ld hl, TxtMax
    call MPutsDE
.meters:
    ; HP / FOOD / ENERGY meters
    ld a, MENU_BODY_ROW + 5
    ld hl, LblStatHP
    call StatLine
    ld a, [wHP]
    call PutNumDE
    ld a, MENU_BODY_ROW + 6
    ld hl, LblStatFood
    call StatLine
    ld a, [wFood]
    call PutNumDE
    ld a, MENU_BODY_ROW + 7
    ld hl, LblStatEnergy
    call StatLine
    ld a, [wEnergy]
    call PutNumDE
    ; time HH:MM
    ld a, MENU_BODY_ROW + 8
    ld hl, LblStatTime
    call StatLine
    ld a, [wClockH]
    call Put2DE
    ld a, TILE_HUD_COLON
    ld [de], a
    inc de
    ld a, [wClockM]
    call Put2DE
    ; position relative to the spawn tile (signed; magnitude capped at 255)
    ld a, MENU_BODY_ROW + 10
    ld hl, LblStatPX
    call StatLine
    ld a, [wPlayerWX]
    ld l, a
    ld a, [wPlayerWX+1]
    ld h, a
    ld a, [wSpawnWX]
    ld c, a
    ld a, [wSpawnWX+1]
    ld b, a
    call Sub16
    call PutSignedDE
    ld a, MENU_BODY_ROW + 11
    ld hl, LblStatPY
    call StatLine
    ld a, [wPlayerWY]
    ld l, a
    ld a, [wPlayerWY+1]
    ld h, a
    ld a, [wSpawnWY]
    ld c, a
    ld a, [wSpawnWY+1]
    ld b, a
    call Sub16
    call PutSignedDE
    jp StatusPageHint

; ---- page 1: the six stat points (Strength .. Speed) ----
BuildStatusStats:
    ld a, MENU_BODY_ROW + 1
    ld hl, LblStr
    ld c, STAT_STR
    call StatRow
    ld a, MENU_BODY_ROW + 2
    ld hl, LblDex
    ld c, STAT_DEX
    call StatRow
    ld a, MENU_BODY_ROW + 3
    ld hl, LblEnd
    ld c, STAT_END
    call StatRow
    ld a, MENU_BODY_ROW + 4
    ld hl, LblImm
    ld c, STAT_IMM
    call StatRow
    ld a, MENU_BODY_ROW + 5
    ld hl, LblAcc
    ld c, STAT_ACC
    call StatRow
    ld a, MENU_BODY_ROW + 6
    ld hl, LblSpd
    ld c, STAT_SPD
    call StatRow
    ; fall through to the page hint

; StatusPageHint: draw the "L-R PAGE n" footer with the 1-based page number.
StatusPageHint:
    ld a, MENU_BODY_ROW + 13
    ld hl, LblPageHint
    call StatLine
    ld a, [wStatusPage]
    inc a
    jp PutNumDE

; StatRow: A = BG row, HL = label, C = STAT_* -> draw the label then its value.
StatRow:
    call StatLine              ; DE = value cell (BC preserved)
    push de
    ld a, c
    call GetStat               ; A = the stat value (clobbers DE)
    pop de
    jp PutNumDE

BuildOptions:
    ld hl, HdrOptions
    call BuildBase
    ld a, MENU_BODY_ROW
    ld hl, LblMusic
    call StatLine
    ld a, [wOptMusic]
    and a, a
    jr z, .off
    ld hl, TxtOn
    jr .put
.off:
    ld hl, TxtOff
.put:
    call MPutsDE
    ld a, MENU_BODY_ROW + 3
    call RowAddr
    ld d, h
    ld e, l
    ld hl, TxtOptHint
    call MPutsDE
    ret

BuildSave:
    ld hl, HdrSave
    call BuildBase
    ld a, MENU_BODY_ROW + 1
    call RowAddr
    ld d, h
    ld e, l
    ld hl, TxtSaved
    call MPutsDE
    ld a, MENU_BODY_ROW + 3
    call RowAddr
    ld d, h
    ld e, l
    ld hl, TxtSavePrompt
    call MPutsDE
    ret

; =============================================================================
; List construction helpers
; =============================================================================
; BuildBagList: wListN = number of non-empty bag stacks (the bag stays compacted
; so they're contiguous from the front). Resets the cursor/scroll.
BuildBagList:
    ld hl, wBag
    ld b, BAG_MAX
    ld c, 0
.loop:
    ld a, [hl]
    and a, a
    jr z, .done
    inc c
    inc hl
    inc hl
    dec b
    jr nz, .loop
.done:
    ld a, c
    ld [wListN], a
    xor a, a
    ld [wListCur], a
    ld [wListTop], a
    ret

; BuildPickList: fill wPickMap for the current equip slot — row 0 = ITEM_NONE
; (unequip), then every bag item whose category matches the slot. Sets wListN.
BuildPickList:
    ld a, [wPickSlot]
    ld e, a
    ld d, 0
    ld hl, EquipSlotType
    add hl, de
    ld a, [hl]
    ld [wAllowType], a
    ld hl, wPickMap
    xor a, a
    ld [hl+], a                ; map[0] = ITEM_NONE
    ld c, 1                    ; entries so far
    ld b, 0                    ; bag index
.scan:
    ld a, b
    add a, a
    ld e, a
    ld d, 0
    push hl
    ld hl, wBag
    add hl, de
    ld a, [hl]                 ; bag[b] item id
    pop hl
    and a, a
    jr z, .done                ; first empty slot ends the compacted bag
    push hl
    push af                    ; save id
    ld e, a
    ld d, 0
    ld hl, ItemType
    add hl, de
    ld a, [hl]                 ; category
    ld e, a
    pop af                     ; id back in A
    pop hl                     ; map pointer
    ld d, a                    ; D = id
    ld a, [wAllowType]
    cp e
    jr nz, .next
    ld a, d
    ld [hl+], a                ; append the id
    inc c
.next:
    inc b
    ld a, b
    cp BAG_MAX
    jr c, .scan
.done:
    ld a, c
    ld [wListN], a
    xor a, a
    ld [wListCur], a
    ld [wListTop], a
    ret

; =============================================================================
; Battery-backed save (MBC5+RAM, -m 0x1B). Copies live state into cart RAM with
; a magic + checksum, bracketed by the RAM enable/disable writes.
; =============================================================================
DoSave:
    ld a, $0A
    ld [rRAMG], a              ; enable cart RAM
    xor a, a
    ld [rRAMB], a              ; RAM bank 0
    ld a, $5A                  ; "Z"
    ld [sMagic], a
    ld a, $42                  ; "B"
    ld [sMagic+1], a
    ld a, 2                    ; save v2: adds party level + XP
    ld [sVersion], a
    ldh a, [hWorldSeed]
    ld [sSeed], a
    ; player + spawn coords are 8 contiguous WRAM bytes -> sPlayerWX..sSpawnWY
    ld hl, wPlayerWX
    ld de, sPlayerWX
    ld b, 8
    call SaveCopy
    ld a, [wHP]
    ld [sHP], a
    ld a, [wFood]
    ld [sFood], a
    ld a, [wEnergy]
    ld [sEnergy], a
    ld a, [wFuel]
    ld [sFuel], a
    ld a, [wClockH]
    ld [sClockH], a
    ld a, [wClockM]
    ld [sClockM], a
    ld a, [wPartyCount]
    ld [sPartyCount], a
    ld hl, wPartyEquip
    ld de, sPartyEquip
    ld b, MAX_PARTY * EQUIP_SLOTS
    call SaveCopy
    ld hl, wPartyLevel
    ld de, sPartyLevel
    ld b, MAX_PARTY
    call SaveCopy
    ld hl, wPartyXP
    ld de, sPartyXP
    ld b, MAX_PARTY * 2
    call SaveCopy
    ld hl, wBag
    ld de, sBag
    ld b, BAG_MAX * 2
    call SaveCopy
    ld a, [wOptMusic]
    ld [sOptMusic], a
    ; checksum: 8-bit sum of the whole block (magic .. sOptMusic)
    ld hl, sMagic
    ld bc, sChecksum - sMagic
    ld d, 0
.sum:
    ld a, [hl+]
    add a, d
    ld d, a
    dec bc
    ld a, b
    or a, c
    jr nz, .sum
    ld a, d
    ld [sChecksum], a
    xor a, a
    ld [rRAMG], a              ; disable cart RAM (protect it)
    ret

; SaveCopy: copy B bytes HL (WRAM) -> DE (SRAM). B < 256.
SaveCopy:
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, SaveCopy
    ret

; =============================================================================
; Drawing primitives
; =============================================================================
; BuildBase: HL = header string. Clear + frame SCRN1, draw the header on row 1.
BuildBase:
    push hl
    call MClear
    ld a, MENU_HDR_ROW
    call RowAddr
    ld d, h
    ld e, l
    pop hl
    call MPutsDE
    ret

; MClear: fill SCRN1 with paper, draw the outer panel frame, set PAL_BG_UI attrs
; over the whole map (CGB only). LCD must be off.
MClear:
    xor a, a
    ldh [rVBK], a
    ld hl, _SCRN1
    ld bc, 32 * 32
    ld d, FONT_BASE            ; space glyph = blank paper
.fill:
    ld a, d
    ld [hl+], a
    dec bc
    ld a, b
    or a, c
    jr nz, .fill
    ; top border row
    ld hl, _SCRN1
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
    ; bottom border row
    ld hl, _SCRN1 + (VIEW_ROWS - 1) * 32
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
    ; side columns
    ld hl, _SCRN1 + 32
    ld c, VIEW_ROWS - 2
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
    ; attributes (CGB only, else the rVBK write hits the tile map)
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

; RowAddr: A = BG row -> HL = _SCRN1 + row*32 + MENU_LIST_COL. Clobbers DE.
RowAddr:
    ld l, a
    ld h, 0
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl                 ; * 32
    ld de, _SCRN1 + MENU_LIST_COL
    add hl, de
    ret

; StatLine: A = row, HL = label -> draw the label, leave DE just past it (for a
; value). Clobbers A, BC-safe (only A/DE/HL touched).
StatLine:
    push hl
    call RowAddr
    ld d, h
    ld e, l
    pop hl
    call MPutsDE
    ret

; MPutsDE: copy a 0-terminated (charmap'd) string HL -> DE; DE ends past the last
; char (terminator not written). Clobbers A, advances HL/DE.
MPutsDE:
    ld a, [hl+]
    and a, a
    ret z
    ld [de], a
    inc de
    jr MPutsDE

; PutNumDE: A = 0..255 -> decimal at DE (no leading zeros, at least one digit).
; Clobbers A, B, C, L; advances DE.
PutNumDE:
    ld c, a
    ld b, 0                    ; B = have-printed flag
    ld a, c                    ; hundreds
    ld l, $FF
.h100:
    inc l
    sub 100
    jr nc, .h100
    add a, 100
    ld c, a
    ld a, l
    call .digit
    ld a, c                    ; tens
    ld l, $FF
.h10:
    inc l
    sub 10
    jr nc, .h10
    add a, 10
    ld c, a
    ld a, l
    call .digit
    ld a, c                    ; ones (always printed)
    ld b, 1
    ; fall through
.digit:
    and a, a
    jr nz, .pr
    ld a, b
    and a, a
    ret z                      ; leading zero: skip (nothing emitted, B still 0)
    xor a, a                   ; interior/forced zero -> print '0'
.pr:
    ld b, 1
    add a, TILE_DIGIT0
    ld [de], a
    inc de
    ret

; PutNum16DE: HL = 0..65535 -> decimal at DE (no leading zeros, at least one
; digit). Digits are divided out LSB-first onto the stack, then emitted MSB-first.
; Clobbers A, B, HL; advances DE.
PutNum16DE:
    ld b, 0                    ; digit count
.div:
    call Div10HL               ; HL /= 10, A = remainder (0..9)
    push af                    ; stash the digit
    inc b
    ld a, h
    or a, l
    jr nz, .div                ; more significant digits remain
.emit:
    pop af                     ; digits come back MSB-first (last pushed = highest)
    add a, TILE_DIGIT0
    ld [de], a
    inc de
    dec b
    jr nz, .emit
    ret

; Div10HL: HL = HL / 10, A = HL mod 10. Classic restoring bit division (16 bits,
; remainder in A). Clobbers B.
Div10HL:
    xor a, a                   ; remainder
    ld b, 16
.bit:
    add hl, hl                 ; shift the dividend up, MSB -> carry
    rla                        ; carry -> remainder LSB
    cp 10
    jr c, .noSub
    sub 10
    inc l                      ; set this quotient bit (L bit0 is free post-shift)
.noSub:
    dec b
    jr nz, .bit
    ret

; Put2DE: A = 0..99 -> exactly two digits at DE (leading zero kept). Clobbers
; A, B, C; advances DE.
Put2DE:
    ld c, 0
.tens:
    cp 10
    jr c, .done
    sub 10
    inc c
    jr .tens
.done:
    ld b, a
    ld a, c
    add a, TILE_DIGIT0
    ld [de], a
    inc de
    ld a, b
    add a, TILE_DIGIT0
    ld [de], a
    inc de
    ret

; Sub16: HL = HL - BC (16-bit).
Sub16:
    ld a, l
    sub c
    ld l, a
    ld a, h
    sbc b
    ld h, a
    ret

; PutSignedDE: HL = signed 16-bit delta -> a sign cell (space for >=0, '-' for
; <0) then the magnitude (capped at 255) at DE. Clobbers A, B, C, L; advances DE.
PutSignedDE:
    bit 7, h
    jr z, .pos
    ld a, FONT_BASE + 42       ; '-'
    ld [de], a
    inc de
    xor a, a                   ; HL = -HL
    sub l
    ld l, a
    ld a, 0
    sbc h
    ld h, a
    jr .mag
.pos:
    ld a, FONT_BASE            ; space (no '+' glyph exists)
    ld [de], a
    inc de
.mag:
    ld a, h
    and a, a
    jr z, .small
    ld a, 255                  ; magnitude too big for 3 digits: cap
    jr .put
.small:
    ld a, l
.put:
    jp PutNumDE

; =============================================================================
; Static data
; =============================================================================
; Local layout constants (SCRN1 pixel positions for the status avatar OBJ).
DEF STATUS_AVATAR_X EQU 15 * 8 + 8
DEF STATUS_AVATAR_Y EQU MENU_BODY_ROW * 8 + 16

; Equip slot -> accepted item category (index by ESLOT_*).
EquipSlotType:
    db ITYPE_WEAPON, ITYPE_WEAPON, ITYPE_ARMOR, ITYPE_ACCESSORY

RootLabels:
    dw LblParty, LblEquip, LblBag, LblStatus, LblSave, LblOptions, LblExit
LblParty:   db "PARTY", 0
LblEquip:   db "EQUIP", 0
LblBag:     db "BAG", 0
LblStatus:  db "STATUS", 0
LblSave:    db "SAVE", 0
LblOptions: db "OPTIONS", 0
LblExit:    db "EXIT", 0

EquipLabels:
    dw LblWeapon, LblWeapon, LblArmor, LblCharm
LblWeapon:  db "WEAPON ", 0
LblArmor:   db "ARMOR  ", 0
LblCharm:   db "CHARM  ", 0

HdrMenu:    db "MENU", 0
HdrParty:   db "PARTY", 0
HdrEquip:   db "EQUIP", 0
HdrBag:     db "BAG", 0
HdrStatus:  db "STATUS", 0
HdrOptions: db "OPTIONS", 0
HdrSave:    db "SAVE", 0

NameZomb:   db "ZOMB BOY", 0
NameEmpty:  db "--------", 0
LblLV:      db "  LV ", 0

LblStatHP:     db "HP     ", 0
LblStatFood:   db "FOOD   ", 0
LblStatEnergy: db "ENERGY ", 0
LblStatTime:   db "TIME   ", 0
LblStatPX:     db "DIST X ", 0
LblStatPY:     db "DIST Y ", 0
LblStatLevel:  db "LEVEL  ", 0
LblStatEXP:    db "EXP    ", 0
LblStatNext:   db "NEXT   ", 0
TxtMax:        db "MAX", 0

; Stat labels are padded to 10 chars so their values line up in one column.
LblStr:     db "STRENGTH  ", 0
LblDex:     db "DEXTERITY ", 0
LblEnd:     db "ENDURANCE ", 0
LblImm:     db "IMMUNITY  ", 0
LblAcc:     db "ACCURACY  ", 0
LblSpd:     db "SPEED     ", 0
LblPageHint: db "L-R PAGE ", 0

LblMusic:   db "MUSIC  ", 0
TxtOn:      db "ON ", 0
TxtOff:     db "OFF", 0
TxtOptHint: db "MORE TBC", 0

TxtEmpty:      db "EMPTY", 0
TxtSaved:      db "GAME SAVED!", 0
TxtSavePrompt: db "PRESS B", 0
