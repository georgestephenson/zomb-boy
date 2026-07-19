; =============================================================================
; talk.asm — the survivor dialogue screen (MODE_TALK).
;
; A Pokemon-battle-style full-screen conversation: the survivor speaks in
; generated sentences (dialogue.asm), you answer with one of four tones, their
; affinity shifts, and after TALK_ROUNDS replies the conversation resolves:
; fight / part ways / reward (docs/design/05 §4-§5).
;
; Screen mechanics:
;   * The UI lives on SCRN1 ($9C00); entering flips LCDC to BG9C00 with
;     SCX/SCY=0, so the world map on SCRN0 stays intact — exiting is just a
;     flip back + SetScroll. Font tiles sit at FONT_BASE (>=128), clear of the
;     terrain/OBJ ids.
;   * The screen is built once with the LCD OFF (inside VBlank; note WaitVBlank
;     would hang while it's off — the build runs straight through). Bank-1
;     attributes are written for every cell (repo invariant).
;   * All later VRAM writes go through a small queue (wTalkQ): logic enqueues
;     (typewriter reveal, menu, face changes), and DrainTalkQ empties it inside
;     VBlank — bounded, so the budget always holds.
;   * The whole text area is modelled by the wTalkText grid; the reveal walks
;     the grid into VRAM at wRevSpeed cells/frame. Dialogue reveals slow
;     (typewriter), menus fast; A skips ahead.
; =============================================================================
INCLUDE "hardware.inc"
INCLUDE "include/constants.inc"
INCLUDE "include/charmap.inc"       ; the card's "MOOD"/"BOND"/descriptor labels

SECTION "Talk", ROM0

; -----------------------------------------------------------------------------
; EnterTalk: A = NPC index. Called from CheckTalkStart (overworld logic phase).
; Sets up state, builds the screen, composes the greeting, flips the mode.
; -----------------------------------------------------------------------------
EnterTalk::
    ld [wTalkNPC], a
    ld de, wNPCs
    call CopyPoolIn            ; wEnt = the survivor, for the whole conversation
    ld a, [wEnt + EO_PERSONA]
    ld [wTalkPersona], a
    ld a, [wEnt + EO_AFFIN]
    call MoodFromAffin
    ld [wTalkMood], a
    ld a, [wEnt + EO_MET]      ; remember whether we've spoken before...
    ld [wTalkMet], a
    ld a, 1
    ld [wEnt + EO_MET], a      ; ...and that we have now
    ; they turn to face the player
    ld a, [wFacing]
    ld e, a
    ld d, 0
    ld hl, OppositeFace
    add hl, de
    ld a, [hl]
    ld [wEnt + EO_FACING], a
    ld a, [wTalkNPC]
    ld de, wNPCs
    call CopyPoolOut
    ; conversation state
    xor a, a
    ld [wTalkRound], a
    ld [wTalkCursor], a
    ld [wTalkQN], a
    ld [wTalkPhase], a         ; TPH_GREET
    ld a, TS_REVEAL
    ld [wTalkState], a
    ld a, OUTCOME_PART
    ld [wTalkOutcome], a
    ; the conversation's subject: one noun they'll keep coming back to.
    ; It also seeds the noun repeat-guard, so the first random noun differs.
    ld c, PO_NOUNS
    call GetPersonaField       ; HL = noun bank
    ld c, [hl]                 ; count
    call RandMod
    ld [wTalkSubject], a
    ld [wLastNoun], a
    ld a, $FF                  ; topic/question repeat-guards: nothing yet
    ld [wLastTopic], a
    ld [wLastQuest], a
    xor a, a
    ld [wCtxUsed], a           ; no context remarked on yet this conversation
    inc a
    ld [wTalkObs], a           ; turn 1 always tries an observation — the NPC
                               ; leads with what they can SEE about you
    ld a, $C5                  ; canary after the text grid — must survive
    ld [wTalkGuard], a
    ; finish any half-blitted world strip before leaving the overworld screen
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
    ldh [rLCDC], a             ; LCD off (safe: we're inside VBlank)
    call BuildTalkScreen
    call ShowPortrait          ; the persona's 56x56 BG portrait
    call EnqStatus             ; mood word/face + affinity meter into the queue...
    call DrainTalkQ            ; ...and paint them now (LCD still off)
    ; sprites: hide everything (the survivor is the BG portrait, not an OBJ)
    ld hl, wShadowOAM
    ld b, 160                  ; 40 sprites x 4 bytes, < 256
    xor a, a
.clrOAM:
    ld [hl+], a
    dec b
    jr nz, .clrOAM
    call DrawTalkSprites
    ld a, HIGH(wShadowOAM)
    call hOAMDMA               ; LCD is off: DMA any time
    xor a, a
    ldh [rSCX], a
    ldh [rSCY], a
    ; the greeting starts revealing on the first talk frame
    call ComposeGreeting
    ld a, REVEAL_SLOW
    ld [wRevSpeed], a
    ld a, MODE_TALK
    ld [wGameMode], a
    ld a, LCDCF_ON | LCDCF_BGON | LCDCF_OBJON | LCDCF_OBJ8 | LCDCF_BG8000 | LCDCF_BG9C00
    ldh [rLCDC], a
    ret

OppositeFace:                  ; player EFACE_* -> the facing that looks back
    db EFACE_UP, EFACE_DOWN, EFACE_RIGHT, EFACE_LEFT

; -----------------------------------------------------------------------------
; UpdateTalk: one logic frame of the conversation (fills the VRAM queue; the
; matching VBlank work is hOAMDMA + DrainTalkQ in main.asm).
; -----------------------------------------------------------------------------
UpdateTalk::
    call TalkReveal
    call DrawTalkSprites
    ld a, [wNewKeys]
    and PAD_B                  ; B leaves anytime (affinity keeps its progress)
    jp nz, ExitTalkScreen
    ld a, [wTalkState]
    cp TS_WAIT
    jr z, .wait
    cp TS_MENU
    jp z, .menu                ; (.wait grew: out of JR range)
    ; --- TS_REVEAL ---
    ld a, [wNewKeys]
    and PAD_A
    jr z, .noSkip
    ld a, REVEAL_FAST          ; impatient A: fast-forward the typewriter
    ld [wRevSpeed], a
.noSkip:
    ld a, [wRevPos]
    cp TALK_TEXT_MAX
    ret c
    call DrawWaitArrow         ; text fully out -> wait for A
    ld a, TS_WAIT
    ld [wTalkState], a
    ret

; --- TS_WAIT: A advances past the shown line. Round rhythm (per the design):
;     [greet/prompt] -> [observation?] -> [question] -> menu -> [reaction] ...
; Each NPC turn is 2-3 pages: their line, sometimes a remark about the world
; or your visible state, then always a question that hands you the menu.
.wait:
    ld a, [wNewKeys]
    and PAD_A
    ret z
    call ClearWaitArrow
    ld a, [wTalkPhase]
    cp TPH_OUTCOME
    jp z, TalkFinish
    cp TPH_REACT
    jr z, .afterReact
    cp TPH_QUEST
    jr z, .toMenu
    cp TPH_OBS
    jr z, .toQuest
    ; TPH_GREET / TPH_PROMPT: maybe one more remark before their question
    ld a, [wTalkObs]
    and a, a
    jr z, .toQuest
    xor a, a
    ld [wTalkObs], a           ; one observation page per NPC turn
    call ComposeObservation
    and a, a
    jr z, .toQuest             ; nothing fresh to remark on: ask away
    ld a, TPH_OBS
    ld [wTalkPhase], a
    jr .reveal
.toQuest:
    call ComposeQuestion       ; their question is the turn's last beat
    ld a, TPH_QUEST
    ld [wTalkPhase], a
    jr .reveal
.toMenu:
    call BuildMenu             ; question asked — your turn
    ld a, TS_MENU
    ld [wTalkState], a
    ret
.afterReact:
    ld a, [wTalkRound]
    cp TALK_ROUNDS
    jr c, .prompt
    ; three rounds answered: resolve where affinity landed
    call DecideOutcome
    call ComposeOutcome
    ld a, TPH_OUTCOME
    ld [wTalkPhase], a
    jr .reveal
.prompt:
    call ComposePrompt         ; they pick the conversation back up
    ld a, TPH_PROMPT
    ld [wTalkPhase], a
    call Rand                  ; later turns: a coin flip decides whether a
    and a, 1                   ; remark comes before the question — NPC turns
    ld [wTalkObs], a           ; run an unpredictable 2-3 pages
.reveal:
    ld a, REVEAL_SLOW
    ld [wRevSpeed], a
    ld a, TS_REVEAL
    ld [wTalkState], a
    ret

; --- TS_MENU: pick one of the four tones ---
.menu:
    ld a, [wNewKeys]
    ld b, a
    and PAD_LEFT | PAD_RIGHT
    jr z, .vert
    ld a, [wTalkCursor]
    xor a, 1
    ld [wTalkCursor], a
.vert:
    ld a, b
    and PAD_UP | PAD_DOWN
    jr z, .pick
    ld a, [wTalkCursor]
    xor a, 2
    ld [wTalkCursor], a
.pick:
    ld a, [wNewKeys]
    and PAD_A
    ret z
    ; apply the chosen tone: delta -> affinity (saturating) -> mood
    ld a, [wTalkCursor]
    ld e, a
    ld d, 0
    ld hl, wMenuTones
    add hl, de
    ld a, [hl]                 ; the TONE_* offered in that slot
    ld [wTalkTone], a          ; the reaction's tag answers this tone
    call ComputeDelta
    ld a, [wEnt + EO_AFFIN]
    call SatAddAffin
    ld [wEnt + EO_AFFIN], a
    call MoodFromAffin
    ld [wTalkMood], a
    call EnqStatus            ; the status card tracks the new mood/affinity
    ld a, [wTalkNPC]           ; persist immediately (survives early B-exit)
    ld de, wNPCs
    call CopyPoolOut
    ld a, [wTalkRound]
    inc a
    ld [wTalkRound], a
    ; their reaction line
    call DeltaBucket
    call ComposeReact
    ld a, REVEAL_SLOW
    ld [wRevSpeed], a
    ld a, TPH_REACT
    ld [wTalkPhase], a
    ld a, TS_REVEAL
    ld [wTalkState], a
    ret

; DecideOutcome: final affinity -> wTalkOutcome.
DecideOutcome:
    ld a, [wEnt + EO_AFFIN]
    cp AFFIN_REWARD
    jr nc, .reward
    cp AFFIN_FIGHT + 1
    jr c, .fight
    ld a, OUTCOME_PART
    jr .store
.reward:
    ld a, OUTCOME_REWARD
    jr .store
.fight:
    ld a, OUTCOME_FIGHT
.store:
    ld [wTalkOutcome], a
    ret

; TalkFinish: outcome line acknowledged. Leave; a FIGHT outcome plays the
; placeholder battle flash on the restored world screen (real combat LATER —
; the reward item is text-only until the inventory slice, too).
TalkFinish:
    call ExitTalkScreen
    ld a, [wTalkOutcome]
    cp OUTCOME_FIGHT
    ret nz
    jp BattleTransition

; -----------------------------------------------------------------------------
; ExitTalkScreen: back to the overworld — world map is still intact on SCRN0,
; so rebuild the sprites, then flip the map select + scroll inside VBlank.
; -----------------------------------------------------------------------------
ExitTalkScreen:
    ld a, MODE_OVERWORLD
    ld [wGameMode], a
    xor a, a
    ld [wTalkQN], a            ; drop any queued talk-screen writes
    call ComputeCamLag
    call DrawEntities
    call WaitVBlank
    ld a, HIGH(wShadowOAM)
    call hOAMDMA
    call DrawHUDRow            ; BuildTalkScreen wiped SCRN1 row 0 — restore the
                               ; window HUD (tiles + attrs) inside this VBlank
    ld a, LCDCF_ON | LCDCF_BGON | LCDCF_OBJON | LCDCF_OBJ8 | LCDCF_BG8000 | LCDCF_BG9800 | LCDCF_WINON | LCDCF_WIN9C00
    ldh [rLCDC], a
    call SetScroll
    ret

; =============================================================================
; Screen build (LCD off) + per-frame drawing
; =============================================================================
; BuildTalkScreen: whole SCRN1 = paper, the text box border, the name plate;
; bank-1 attributes = PAL_BG_UI for every cell.
BuildTalkScreen:
    xor a, a
    ldh [rVBK], a
    ld hl, _SCRN1
    ld bc, 32 * 32
    ld d, FONT_BASE            ; the space glyph = blank paper
.fill:
    ld a, d
    ld [hl+], a
    dec bc
    ld a, b
    or a, c
    jr nz, .fill
    ; dialogue box: a rounded panel frame (corners + edges)
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
    ; ...and side columns 0/19 on the rows between
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
    ; name banner (row 0, top-left)
    ld c, PO_NAME
    call GetPersonaField       ; HL = name string
    ld de, _SCRN1 + NAME_ROW * 32 + NAME_COL
    call .puts
    ; status card: a rounded panel frame (cols CARD_COL_L..CARD_COL_R,
    ; rows CARD_ROW_TOP..CARD_ROW_BOT)
    ld hl, _SCRN1 + CARD_ROW_TOP * 32 + CARD_COL_L
    ld a, TILE_PANEL_TL
    ld [hl+], a
    ld a, TILE_PANEL_T
    ld b, CARD_COL_R - CARD_COL_L - 1
.cardtop:
    ld [hl+], a
    dec b
    jr nz, .cardtop
    ld a, TILE_PANEL_TR
    ld [hl], a
    ld hl, _SCRN1 + CARD_ROW_BOT * 32 + CARD_COL_L
    ld a, TILE_PANEL_BL
    ld [hl+], a
    ld a, TILE_PANEL_B
    ld b, CARD_COL_R - CARD_COL_L - 1
.cardbot:
    ld [hl+], a
    dec b
    jr nz, .cardbot
    ld a, TILE_PANEL_BR
    ld [hl], a
    ld hl, _SCRN1 + (CARD_ROW_TOP + 1) * 32 + CARD_COL_L
    ld c, CARD_ROW_BOT - CARD_ROW_TOP - 1
.cardside:
    ld a, TILE_PANEL_L
    ld [hl], a                 ; left border
    ld de, CARD_COL_R - CARD_COL_L
    add hl, de
    ld a, TILE_PANEL_R
    ld [hl], a                 ; right border
    ld de, 32 - (CARD_COL_R - CARD_COL_L)
    add hl, de
    dec c
    jr nz, .cardside
    ; static labels ("MOOD" / "BOND"); the face, mood word and meter are dynamic
    ; (EnqStatus, driven from the running affinity)
    ld hl, LblMood
    ld de, _SCRN1 + STAT_MOOD_ROW * 32 + STAT_INNER_COL
    call .puts
    ld hl, LblBond
    ld de, _SCRN1 + STAT_BOND_ROW * 32 + STAT_INNER_COL
    call .puts
    jr .attrs
; .puts: copy a 0-terminated (charmap'd) string HL -> DE. Clobbers A, HL, DE.
.puts:
    ld a, [hl+]
    and a, a
    ret z
    ld [de], a
    inc de
    jr .puts
.attrs:
    ; attributes: the whole screen uses the UI palette. CGB only — on DMG the
    ; rVBK write is a no-op and this pass would overwrite the tile map itself.
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

FaceTable:                     ; index by MOOD_*
    db TILE_FACE_MAD, TILE_FACE_NEUT, TILE_FACE_HAPPY

; -----------------------------------------------------------------------------
; ShowPortrait: load wTalkPersona's 56x56 portrait (PortraitTable, generated in
; portrait_data.asm — every persona has one): palettes + tiles + the 7x7 BG
; block. The portrait bank is mapped only inside this routine; bank 1 (song +
; dialogue data) is restored before returning.
; Runs with the LCD off (called from EnterTalk after BuildTalkScreen), so it can
; touch VRAM/palettes freely. See portrait_data.asm for the descriptor layout.
; -----------------------------------------------------------------------------
ShowPortrait:
    ld a, BANK(PortraitTable)
    ld [rROMB0], a
    ld a, [wTalkPersona]
    add a, a                   ; * 2 (dw table)
    ld e, a
    ld d, 0
    ld hl, PortraitTable
    add hl, de
    ld a, [hl+]
    ld h, [hl]
    ld l, a                    ; HL = descriptor
    ; --- palettes: 24 bytes -> BG slots 5/6/7 (CGB only) ---
    ldh a, [hIsCGB]
    and a, a
    jr z, .tileids
    push hl
    ld a, BCPSF_AUTOINC | (PAL_BG_PORTRAIT * 8)
    ldh [rBCPS], a
    ld b, PORTRAIT_ATTR_OFF    ; 24 palette bytes
.pal:
    ld a, [hl+]
    ldh [rBCPD], a
    dec b
    jr nz, .pal
    pop hl
.tileids:
    ; --- 7x7 sequential tile ids into SCRN1 (bank 0) ---
    xor a, a
    ldh [rVBK], a
    push hl                    ; keep descriptor
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
    push de                    ; hl += 32 (next BG row)
    ld de, 32
    add hl, de
    pop de
    dec d
    jr nz, .trow
    pop hl                     ; descriptor
    push hl
    call DrawPortraitFrame     ; the photo frame ring (bank 0 tile ids, palette
    pop hl                     ; PAL_BG_UI already set by BuildTalkScreen)
    ; --- attributes: per-tile palette index (0..2) + PAL_BG_PORTRAIT (CGB only) ---
    push hl                    ; keep descriptor
    ld de, PORTRAIT_ATTR_OFF
    add hl, de                 ; HL = attr array (desc + 24)
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
    ld a, e                    ; de += 32 - COLS (next BG row)
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
    pop hl                     ; descriptor
    ld bc, PORTRAIT_TILE_OFF
    add hl, bc                 ; HL = tile data (desc + 73)
    xor a, a
    ldh [rVBK], a              ; tiles in bank 0
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
    ld a, 1                    ; back to the song + dialogue bank
    ld [rROMB0], a
    ret

; -----------------------------------------------------------------------------
; DrawPortraitFrame: paint the frame ring around the 7x7 photo (SCRN1, bank 0).
; The ring sits one cell out on every side; its cells already carry PAL_BG_UI
; from BuildTalkScreen, so only tile ids are written here. LCD off.
; -----------------------------------------------------------------------------
DrawPortraitFrame:
    ; top border row: TL, T x COLS, TR
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
    ; bottom border row: BL, B x COLS, BR
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
    ; the two side columns
    ld hl, _SCRN1 + PORTRAIT_ROW0 * 32 + (PORTRAIT_COL0 - 1)
    ld c, PORTRAIT_ROWS
.side:
    ld a, TILE_FRAME_L
    ld [hl], a
    push hl
    ld de, PORTRAIT_COLS + 1    ; step across to the right column
    add hl, de
    ld a, TILE_FRAME_R
    ld [hl], a
    pop hl
    ld de, 32
    add hl, de
    dec c
    jr nz, .side
    ret

; DrawTalkSprites: shadow OAM slot 1 = menu cursor. Slot 0 stays hidden: every
; persona shows its 56x56 BG portrait, never the small OBJ survivor. (All other
; slots were zeroed on entry and stay hidden.)
DrawTalkSprites:
    xor a, a
    ld [wShadowOAM], a         ; slot 0 Y = 0: off-screen
    ld a, [wTalkState]
    cp TS_MENU
    jr z, .cursor
    xor a, a                   ; no menu -> hide the cursor
    ld [wShadowOAM + 4], a
    ret
.cursor:
    ld a, [wTalkCursor]
    and 2                      ; (cursor>>1)*2 = row offset in BG rows
    add a, TXT_ROW0
    add a, a
    add a, a
    add a, a                   ; * 8 px
    add a, 16                  ; OAM Y offset
    ld [wShadowOAM + 4], a
    ld a, [wTalkCursor]
    and 1
    add a, a
    add a, a
    add a, a                   ; (cursor&1)*8 = column offset in BG cols
    add a, TXT_COL0 - 1 + MENU_LBL_COL0  ; cursor cell left of the label
    add a, a
    add a, a
    add a, a                   ; * 8 px
    add a, 8                   ; OAM X offset
    ld [wShadowOAM + 5], a
    ld a, TILE_CURSOR
    ld [wShadowOAM + 6], a
    ld a, 2                    ; OBJ palette 2 (amber)
    ld [wShadowOAM + 7], a
    ret

; -----------------------------------------------------------------------------
; EnqStatus: (re)paint the dynamic status card — mood face, the spelled-out
; relationship word, and the 8-cell affinity meter — from the running affinity
; (wEnt + EO_AFFIN) and mood (wTalkMood). Queues writes via TalkEnq, so it works
; both at build (drained immediately, LCD off) and mid-conversation. Under the
; TALKQ_CAP budget: 1 + 8 + 8 = 17 writes. Only B survives a TalkEnq call, so
; the loops stash their pointers/counters across it on the stack.
; -----------------------------------------------------------------------------
EnqStatus:
    ; --- mood face (MOOD row) ---
    ld a, [wTalkMood]
    ld hl, FaceTable
    add a, l
    ld l, a
    ld a, h
    adc a, 0
    ld h, a
    ld a, [hl]                 ; A = face tile
    ld hl, _SCRN1 + STAT_MOOD_ROW * 32 + STAT_FACE_COL
    call TalkEnq
    ; --- relationship word (DESC row), 8 cells ---
    ld a, [wEnt + EO_AFFIN]
    call DescIdx               ; A = descriptor index (0..4)
    add a, a
    add a, a
    add a, a                   ; * 8 (each entry is 8 chars)
    ld e, a
    ld d, 0
    ld hl, DescTable
    add hl, de                 ; HL = the 8-char word
    ld de, _SCRN1 + STAT_DESC_ROW * 32 + STAT_INNER_COL
    ld b, 8
.desc:
    ld a, [hl+]                ; A = char, advance src
    push hl                    ; save src
    push de                    ; save dest
    ld h, d
    ld l, e                    ; HL = dest for TalkEnq
    call TalkEnq               ; clobbers A,C,D,E,HL; preserves B
    pop de
    inc de                     ; next cell
    pop hl
    dec b
    jr nz, .desc
    ; --- affinity meter (BAR row), 8 cells of 8 px = affinity to the pixel ---
    ld a, [wEnt + EO_AFFIN]
    srl a
    srl a                      ; A = filled columns, 0..63 (affinity / 4)
    ld de, _SCRN1 + STAT_BAR_ROW * 32 + STAT_INNER_COL
    ld b, 8                    ; cells left
.bar:
    ld c, a                    ; C = columns remaining
    sub 8
    jr nc, .full               ; >= 8 columns -> a full cell
    ld a, c                    ; < 8: this cell is partly filled
    ld c, 0                    ; nothing left after it
    jr .emit
.full:
    ld c, a                    ; columns remaining after a full cell
    ld a, 8
.emit:
    add a, TILE_BAR_BASE       ; A = the gauge tile for this fill level
    push bc                    ; save cell counter (B) + remaining (C)
    push de                    ; save dest
    ld h, d
    ld l, e
    call TalkEnq
    pop de
    inc de
    pop bc
    ld a, c                    ; A = remaining columns for the next cell
    dec b
    jr nz, .bar
    ret

; DescIdx: A = affinity -> A = relationship descriptor index (0..4). Finer than
; MoodFromAffin's 3 buckets; display only, so it never feeds the dialogue banks.
DescIdx:
    cp AFFIN_HOSTILE           ; < 96
    jr c, .d0
    cp DESC_WARY_MIN           ; < 128
    jr c, .d1
    cp AFFIN_WARM              ; < 160
    jr c, .d2
    cp DESC_WARM_MIN           ; < 200
    jr c, .d3
    ld a, 4                    ; DEVOTED
    ret
.d0:
    xor a, a                   ; HOSTILE
    ret
.d1:
    ld a, 1                    ; WARY
    ret
.d2:
    ld a, 2                    ; NEUTRAL
    ret
.d3:
    ld a, 3                    ; WARM
    ret

; Fixed 8-char (space-padded) descriptor words, indexed by DescIdx. charmap'd.
DescTable:
    db "HOSTILE "
    db "WARY    "
    db "NEUTRAL "
    db "WARM    "
    db "DEVOTED "

LblMood: db "MOOD", 0
LblBond: db "BOND", 0

; DrawWaitArrow / ClearWaitArrow: the "press A" notch on the bottom border.
DrawWaitArrow:
    ld hl, _SCRN1 + BOX_ROW_BOT * 32 + TALK_ARROW_COL
    ld a, TILE_UIARROW
    jr TalkEnq
ClearWaitArrow:
    ld hl, _SCRN1 + BOX_ROW_BOT * 32 + TALK_ARROW_COL
    ld a, TILE_PANEL_B         ; restore the panel's bottom edge
    ; fall through
; -----------------------------------------------------------------------------
; TalkEnq: HL = VRAM address, A = tile — queue one write for the next VBlank.
; -----------------------------------------------------------------------------
TalkEnq:
    ld c, a
    ld a, [wTalkQN]
    cp TALKQ_CAP
    ret nc                     ; full: drop (callers stay under the cap)
    ld e, a
    inc a
    ld [wTalkQN], a
    ld a, e
    add a, a
    add a, e                   ; * 3
    ld e, a
    ld d, 0
    push hl
    ld hl, wTalkQ
    add hl, de
    pop de                     ; DE = the VRAM address
    ld [hl], d                 ; addrHi
    inc hl
    ld [hl], e                 ; addrLo
    inc hl
    ld [hl], c                 ; value
    ret

; -----------------------------------------------------------------------------
; DrainTalkQ: VBlank only — write every queued entry to VRAM and reset.
; Worst case TALKQ_CAP (16) writes: well inside the budget next to OAM DMA.
; -----------------------------------------------------------------------------
DrainTalkQ::
    ld a, [wTalkQN]
    and a, a
    ret z
    ld b, a
    xor a, a
    ld [wTalkQN], a
    ldh [rVBK], a              ; text tiles live in bank 0
    ld hl, wTalkQ
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

; -----------------------------------------------------------------------------
; TalkReveal: enqueue up to wRevSpeed cells of wTalkText into their SCRN1
; positions. Grid row r sits at BG row TXT_ROW0 + 2r, column TXT_COL0 + c.
; -----------------------------------------------------------------------------
TalkReveal:
    ld a, [wRevPos]
    cp TALK_TEXT_MAX
    ret nc
    ld a, [wRevSpeed]
    ld b, a
.cell:
    push bc
    ; HL = _SCRN1 + (TXT_ROW0 + row*2)*32 + TXT_COL0 + col
    ld a, [wRevRow]
    add a, a
    add a, TXT_ROW0
    ld l, a
    ld h, 0
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl                 ; * 32
    ld a, [wRevCol]
    add a, TXT_COL0
    ld e, a
    ld d, 0
    add hl, de
    ld de, _SCRN1
    add hl, de
    ; A = the grid cell
    ld a, [wRevPos]
    ld e, a
    ld d, 0
    push hl
    ld hl, wTalkText
    add hl, de
    ld a, [hl]
    pop hl
    call TalkEnq
    ; advance the walk
    ld a, [wRevPos]
    inc a
    ld [wRevPos], a
    ld a, [wRevCol]
    inc a
    cp TALK_COLS
    jr c, .colOk
    ld a, [wRevRow]
    inc a
    ld [wRevRow], a
    xor a, a
.colOk:
    ld [wRevCol], a
    pop bc
    ld a, [wRevPos]
    cp TALK_TEXT_MAX
    ret nc
    dec b
    jr nz, .cell
    ret

; -----------------------------------------------------------------------------
; BuildMenu: draw 4 DISTINCT random tones from the pool into wMenuTones —
; redrawing (bounded) until at least one is non-negative for this persona, so
; there's always a playable option — then paint their labels into the text
; grid (fast reveal repaints the whole area, wiping the previous line).
; -----------------------------------------------------------------------------
BuildMenu:
    ld a, MENU_TRIES
    ld [wMenuTries], a
.draw:
    ld a, $FF                  ; empty slots (never matches a tone id)
    ld hl, wMenuTones
    ld [hl+], a
    ld [hl+], a
    ld [hl+], a
    ld [hl], a
    ld c, 0                    ; slot being filled
.slot:
    call Rand                  ; clobbers B, HL; C survives
    and TONE_COUNT - 1
    ld e, a
    ld hl, wMenuTones          ; distinct: reject any id already drawn
    ld a, [hl+]
    cp e
    jr z, .slot
    ld a, [hl+]
    cp e
    jr z, .slot
    ld a, [hl+]
    cp e
    jr z, .slot
    ld a, [hl]
    cp e
    jr z, .slot
    ld b, 0
    ld hl, wMenuTones
    add hl, bc
    ld [hl], e
    inc c
    ld a, c
    cp 4
    jr c, .slot
    ; require one option the persona won't punish (delta >= 0)
    ld c, 0
.check:
    push bc
    ld b, 0
    ld hl, wMenuTones
    add hl, bc
    ld a, [hl]
    call ComputeDelta          ; -> wTalkDelta (scratch here; set anew on pick)
    pop bc
    ld a, [wTalkDelta]
    bit 7, a
    jr z, .accept              ; found a non-negative tone
    inc c
    ld a, c
    cp 4
    jr c, .check
    ld a, [wMenuTries]         ; all four negative: roll a fresh hand
    dec a
    ld [wMenuTries], a
    jr nz, .draw
.accept:
    ; paint the four labels into the grid
    call ResetCompose          ; grid = spaces, reveal rewound
    ld c, 0                    ; menu slot
.label:
    push bc
    ; DE (dest) = wTalkText + (slot>>1)*18 + MENU_LBL_COL0 + (slot&1)*8
    ld a, c
    and 1
    add a, a
    add a, a
    add a, a                   ; (slot&1)*8
    add a, MENU_LBL_COL0
    ld e, a
    ld a, c
    and 2                      ; (slot>>1)*2
    ld d, a
    add a, a
    add a, a
    add a, a                   ; *8
    add a, d                   ; *9 -> (slot>>1)*18
    add a, e
    ld e, a
    ld d, 0
    ld hl, wTalkText
    add hl, de
    ld d, h
    ld e, l                    ; DE = dest
    ; HL (src) = a random synonym for wMenuTones[slot], drawn from the bank
    ; keyed by tone AND the NPC's current mood — the same reply reads
    ; differently as the relationship shifts (NICE -> EASY / KIND / LOVE IT).
    ld a, c
    push de
    ld e, a
    ld d, 0
    ld hl, wMenuTones
    add hl, de
    ld b, [hl]                 ; B = the tone in this slot
    ld a, [wTalkMood]
    ld de, ToneLabelMoods
    call DerefTable            ; HL = this mood's 8-tone label table
    ld d, h
    ld e, l
    ld a, b
    call DerefTable            ; HL = the tone's synonym bank
    call PickPlain             ; HL = one synonym
    pop de
.copy:
    ld a, [hl+]
    and a, a
    jr z, .next
    ld [de], a
    inc de
    jr .copy
.next:
    pop bc
    inc c
    ld a, c
    cp 4
    jr c, .label
    ld a, REVEAL_FAST
    ld [wRevSpeed], a
    xor a, a
    ld [wTalkCursor], a
    ret
