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
    ld a, $FF                  ; topic repeat-guard: nothing picked yet
    ld [wLastTopic], a
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
    ; sprites: hide everything, then the survivor "portrait"
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
    jr z, .menu
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
;     [greet/prompt sentence] -> menu -> [reaction] -> [prompt sentence] -> ...
.wait:
    ld a, [wNewKeys]
    and PAD_A
    ret z
    call ClearWaitArrow
    ld a, [wTalkPhase]
    cp TPH_OUTCOME
    jr z, .finish
    cp TPH_REACT
    jr z, .afterReact
    ; TPH_GREET / TPH_PROMPT: their line is out — your turn
    call BuildMenu
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
.reveal:
    ld a, REVEAL_SLOW
    ld [wRevSpeed], a
    ld a, TS_REVEAL
    ld [wTalkState], a
    ret
.finish:
    jp TalkFinish

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
    call UpdateFace            ; the name-plate face tracks the mood
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
    ld a, LCDCF_ON | LCDCF_BGON | LCDCF_OBJON | LCDCF_OBJ8 | LCDCF_BG8000 | LCDCF_BG9800
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
    ; text box: solid top/bottom rows...
    ld hl, _SCRN1 + BOX_ROW_TOP * 32
    ld b, VIEW_COLS
    ld a, TILE_UIBOX
.top:
    ld [hl+], a
    dec b
    jr nz, .top
    ld hl, _SCRN1 + BOX_ROW_BOT * 32
    ld b, VIEW_COLS
.bot:
    ld [hl+], a
    dec b
    jr nz, .bot
    ; ...and side columns 0/19 on the rows between
    ld hl, _SCRN1 + (BOX_ROW_TOP + 1) * 32
    ld c, BOX_ROW_BOT - BOX_ROW_TOP - 1
.sides:
    ld [hl], a
    ld de, VIEW_COLS - 1
    add hl, de
    ld [hl], a
    ld de, 32 - (VIEW_COLS - 1)
    add hl, de
    dec c
    jr nz, .sides
    ; name plate + mood face
    ld c, PO_NAME
    call GetPersonaField       ; HL = name string
    ld de, _SCRN1 + NAME_ROW * 32 + NAME_COL
.name:
    ld a, [hl+]
    and a, a
    jr z, .face
    ld [de], a
    inc de
    jr .name
.face:
    inc de                     ; one-cell gap
    ld a, [wTalkMood]
    ld hl, FaceTable
    add a, l
    ld l, a
    ld a, h
    adc a, 0
    ld h, a
    ld a, [hl]
    ld [de], a
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

; DrawTalkSprites: shadow OAM slot 0 = the survivor, slot 1 = menu cursor.
; (All other slots were zeroed on entry and stay hidden.)
DrawTalkSprites:
    ld a, [wTalkPersona]
    call PersonaPtr            ; palette comes from the record (PO_PAL)
    ld de, PO_PAL
    add hl, de
    ld b, [hl]
    ld hl, wShadowOAM
    ld a, TALK_NPC_Y
    ld [hl+], a
    ld a, TALK_NPC_X
    ld [hl+], a
    ld a, TILE_SURV_DOWN       ; faces the camera
    ld [hl+], a
    ld a, b
    ld [hl+], a
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

; UpdateFace: re-enqueue the name-plate mood face (mood may have shifted).
UpdateFace:
    ld c, PO_NAME
    call GetPersonaField       ; HL = name (walk it to find the face cell)
    ld b, NAME_COL
.len:
    ld a, [hl+]
    and a, a
    jr z, .got
    inc b
    jr .len
.got:
    inc b                      ; the gap cell; face sits after it
    ld a, [wTalkMood]
    ld hl, FaceTable
    add a, l
    ld l, a
    ld a, h
    adc a, 0
    ld h, a
    ld c, [hl]                 ; c = face tile
    ld l, b
    ld h, 0
    ld de, _SCRN1 + NAME_ROW * 32
    add hl, de
    ld a, c
    jr TalkEnq

; DrawWaitArrow / ClearWaitArrow: the "press A" notch on the bottom border.
DrawWaitArrow:
    ld hl, _SCRN1 + BOX_ROW_BOT * 32 + TALK_ARROW_COL
    ld a, TILE_UIARROW
    jr TalkEnq
ClearWaitArrow:
    ld hl, _SCRN1 + BOX_ROW_BOT * 32 + TALK_ARROW_COL
    ld a, TILE_UIBOX
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
    ; HL (src) = ToneLabels[wMenuTones[slot]]
    ld a, c
    push de
    ld e, a
    ld d, 0
    ld hl, wMenuTones
    add hl, de
    ld a, [hl]
    ld de, ToneLabels
    call DerefTable
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
