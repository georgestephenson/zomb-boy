; =============================================================================
; dialogue.asm — the procedural sentence generator + compatibility math
; (docs/design/05 §2-§3).
;
; Sentences are composed by expanding word banks (dialogue_data.asm) into the
; 3x18 text grid wTalkText. The composer is token-based: characters accumulate
; into wWordBuf and whole words are flushed to the grid with greedy wrapping,
; so a CTRL_NOUN/CTRL_ADJ slot glues into the surrounding token ("BADGE.").
;
; MEMORY SAFETY (the doc's named target): FlushWord bounds-checks every write —
; a word never splits across rows, never writes past column 17, and is DROPPED
; once the 3 rows are full. wTalkGuard sits right after the grid as a canary;
; test/model/dialogue_bounds.py proves shipped data never even hits the drop.
; =============================================================================
INCLUDE "hardware.inc"
INCLUDE "include/constants.inc"

SECTION "Dialogue", ROM0

; =============================================================================
; Compatibility math
; =============================================================================
; ComputeDelta: A = TONE_* -> wTalkDelta (signed), for wTalkPersona.
;   delta = clamp(dot(tone push, persona traits) >> 2, +/-16) + tone base
; Trait magnitudes are capped (|dot| <= 127, checked by the bounds model), so
; the accumulator fits in a signed byte.
ComputeDelta::
    ld c, a                    ; c = tone
    ld a, [wTalkPersona]
    call PersonaPtr            ; HL = persona record (clobbers DE)
    inc hl
    inc hl                     ; HL = traits (PO_TRAITS = 2)
    ld a, c
    add a, a
    ld e, a
    add a, a
    add a, e                   ; a = tone * TONE_SIZE (6)
    add a, LOW(ToneTable)
    ld e, a
    ld a, HIGH(ToneTable)
    adc a, 0
    ld d, a                    ; DE = tone record (4 pushes, base)
    ld b, 4
    ld c, 0                    ; c = signed accumulator
.axis:
    ld a, [de]                 ; push: -1 / 0 / +1
    inc de
    and a, a
    jr z, .next
    bit 7, a
    jr nz, .sub
    ld a, [hl]
    add a, c
    ld c, a
    jr .next
.sub:
    ld a, c
    sub [hl]
    ld c, a
.next:
    inc hl
    dec b
    jr nz, .axis
    sra c
    sra c                      ; >> 2, arithmetic
    ; clamp to +/-16: t = c+16 must land in 0..32
    ld a, c
    add a, 16
    bit 7, a
    jr z, .lowOk
    ld c, -16
    jr .base
.lowOk:
    cp 33
    jr c, .base
    ld c, 16
.base:
    ld a, [de]                 ; tone base (signed)
    add a, c
    ld [wTalkDelta], a
    ret

; DeltaBucket: wTalkDelta -> A = RB_* (which reaction bank fires).
DeltaBucket::
    ld a, [wTalkDelta]
    add a, 32                  ; bias signed [-22..18] into unsigned [10..50]
    cp 38                      ; >= +6
    jr nc, .loved
    cp 33                      ; >= +1
    jr nc, .liked
    cp 32                      ; == 0
    jr z, .meh
    cp 27                      ; >= -5
    jr nc, .disliked
    ld a, RB_HATED
    ret
.loved:
    ld a, RB_LOVED
    ret
.liked:
    ld a, RB_LIKED
    ret
.meh:
    ld a, RB_MEH
    ret
.disliked:
    ld a, RB_DISLIKED
    ret

; SatAddAffin: A = affinity -> A = affinity + wTalkDelta, SATURATED to 0..255
; (the repo's no-wrap rule; both ends covered by test_talk.py).
SatAddAffin::
    ld b, a
    ld a, [wTalkDelta]
    bit 7, a
    jr nz, .neg
    add a, b
    ret nc
    ld a, 255
    ret
.neg:
    add a, b                   ; negative-as-unsigned: carry set = no borrow
    ret c
    xor a, a
    ret

; MoodFromAffin: A = affinity -> A = MOOD_*.
MoodFromAffin::
    cp AFFIN_HOSTILE
    jr c, .hostile
    cp AFFIN_WARM
    jr c, .neutral
    ld a, MOOD_WARM
    ret
.neutral:
    ld a, MOOD_NEUTRAL
    ret
.hostile:
    ld a, MOOD_HOSTILE
    ret

; =============================================================================
; Sentence composition (into the wTalkText grid)
; =============================================================================
; ComposeGreeting: [opener by mood] [topic by persona] — the first line.
; Someone you've met before skips the hello and picks the thread back up
; (continuation openers): "STILL HERE? THE BUNKER IS SEALED."
ComposeGreeting::
    call ResetCompose
    ld a, [wTalkMet]
    and a, a
    jr z, .firstMeeting
    ld de, PromptMoods
    jr .open
.firstMeeting:
    ld de, OpenerMoods
.open:
    ld a, [wTalkMood]
    call DerefTable            ; HL = opener bank
    call PickPlain
    call EmitFrag
    jr EmitTopic

; ComposePrompt: [continuation by mood] [topic by persona] — the NPC's fresh
; line that opens every later round ("SO. THE LAB LOOKS ODD.").
ComposePrompt::
    call ResetCompose
    ld de, PromptMoods
    ld a, [wTalkMood]
    call DerefTable
    call PickPlain
    call EmitFrag
    jr EmitTopic

; ComposeReact: A = RB_* bucket -> [bucket quip] [tone tag]. The tag answers
; the SPECIFIC tone in wTalkTone (liked/disliked by the delta's sign), so the
; reply feels heard; a delta of exactly 0 gets the quip alone.
ComposeReact::
    push af
    call ResetCompose
    pop af
    ld de, ReactBanks
    call DerefTable
    call PickPlain
    call EmitFrag
    ld a, [wTalkDelta]
    and a, a
    ret z                      ; indifferent: no tag
    bit 7, a
    jr nz, .disliked
    ld de, ToneTagsLiked
    jr .tag
.disliked:
    ld de, ToneTagsDisliked
.tag:
    ld a, [wTalkTone]
    call DerefTable            ; HL = this tone's tag bank
    call PickPlain
    jp EmitFrag

EmitTopic:
    ld c, PO_TOPICS
    call GetPersonaField       ; HL = topic bank
    call PickTopicFrag
    jp EmitFrag

; ComposeQuestion: every NPC turn's last beat — they put a question to you and
; the reply menu answers it. Per-persona banks (PO_QUESTS), subject-threaded
; like the topics; wLastQuest keeps the same question from repeating rounds.
ComposeQuestion::
    call ResetCompose
    ld c, PO_QUESTS
    call GetPersonaField       ; HL = question bank
    call PickQuestFrag
    jp EmitFrag

; -----------------------------------------------------------------------------
; ComposeObservation: an optional mid-turn remark keyed to LIVE game state (the
; player's meters, their equipped weapon, the in-game clock). Returns A = 1 if
; a line was composed, A = 0 if every triggered context was already used this
; conversation (caller goes straight to the question).
; -----------------------------------------------------------------------------
ComposeObservation::
    call PickContext           ; A = CTX_* or CTX_NONE
    inc a                      ; CTX_NONE ($FF) -> 0
    ret z                      ; A = 0: nothing fresh to say
    dec a
    push af
    call ResetCompose
    pop af
    push af
    call CtxMask               ; A = 1 << ctx (clobbers C)
    ld hl, wCtxUsed
    or a, [hl]
    ld [hl], a                 ; one remark per context per conversation
    ; the remark comes from the TALKING persona's own bank — the raider
    ; menaces your pistol, the preacher tuts at it
    pop af
    push af
    ld c, PO_CTX
    call GetPersonaField       ; HL = this persona's 8-bank context table
    ld d, h
    ld e, l
    pop af
    call DerefTable            ; HL = the context's line bank
    call PickPlain
    call EmitFrag
    ld a, 1
    ret

; PickContext: scan live state in priority order (meters beat equipment beats
; the clock — the most personal thing they could notice wins) and return the
; first CTX_* not yet used this conversation, or CTX_NONE. The time-of-day
; buckets are mutually exclusive, so one of them almost always backstops.
PickContext:
    ld a, [wHP]
    cp CTX_LOW_METER
    jr nc, .fed
    ld a, CTX_HURT
    call CtxFresh
    ret c
.fed:
    ld a, [wFood]
    cp CTX_LOW_METER
    jr nc, .rested
    ld a, CTX_HUNGRY
    call CtxFresh
    ret c
.rested:
    ld a, [wEnergy]
    cp CTX_LOW_METER
    jr nc, .unarmed
    ld a, CTX_TIRED
    call CtxFresh
    ret c
.unarmed:
    ld a, [wPartyEquip + ESLOT_WEAPON1]
    ld b, a
    ld a, [wPartyEquip + ESLOT_WEAPON2]
    or a, b
    jr z, .clock
    ld a, CTX_WEAPON
    call CtxFresh
    ret c
.clock:
    ld a, [wClockH]
    cp 5
    jr c, .night               ; 0..4
    cp 12
    jr c, .morning             ; 5..11
    cp 18
    jr c, .day                 ; 12..17
    cp 22
    jr c, .dusk                ; 18..21
.night:
    ld a, CTX_NIGHT
    jr .time
.morning:
    ld a, CTX_MORNING
    jr .time
.day:
    ld a, CTX_DAY
    jr .time
.dusk:
    ld a, CTX_DUSK
.time:
    call CtxFresh
    ret c
    ld a, CTX_NONE
    ret

; CtxFresh: A = CTX_* -> carry set if its wCtxUsed bit is still clear.
; Preserves the id in A. Clobbers B, C.
CtxFresh:
    ld b, a
    call CtxMask               ; A = mask (clobbers C)
    ld c, a
    ld a, [wCtxUsed]
    and a, c                   ; also clears carry
    ld a, b
    ret nz                     ; NC: already remarked on this
    scf
    ret

; CtxMask: A = bit index 0..7 -> A = 1 << index. Clobbers C.
CtxMask:
    ld c, a
    ld a, 1
    inc c
.shift:
    dec c
    ret z
    add a, a
    jr .shift

; ComposeOutcome: wTalkOutcome -> the conversation's closing line.
ComposeOutcome::
    call ResetCompose
    ld de, OutcomeBanks
    ld a, [wTalkOutcome]
    call DerefTable
    call PickPlain
    jp EmitFrag

; ResetCompose: blank the grid to spaces, rewind compose + reveal cursors.
ResetCompose::
    ld hl, wTalkText
    ld b, TALK_TEXT_MAX
    ld a, FONT_BASE            ; the space glyph
.fill:
    ld [hl+], a
    dec b
    jr nz, .fill
    xor a, a
    ld [wTalkCol], a
    ld [wTalkRow], a
    ld [wWordLen], a
    ld [wRevPos], a
    ld [wRevCol], a
    ld [wRevRow], a
    ret

; -----------------------------------------------------------------------------
; EmitFrag: HL = fragment. Streams it through the word buffer: spaces flush,
; CTRL slots expand a bank pick into the current word, CTRL_END flushes + ends.
; -----------------------------------------------------------------------------
EmitFrag:
.loop:
    ld a, [hl+]
    and a, a                   ; CTRL_END
    jp z, FlushWord
    cp CTRL_NOUN
    jr z, .noun
    cp CTRL_ADJ
    jr z, .adj
    cp CTRL_SUBJ
    jr z, .subj
    cp CTRL_ITEM
    jr z, .item
    cp FONT_BASE               ; the space glyph separates tokens
    jr z, .space
    call AppendWordChar
    jr .loop
.space:
    push hl
    call FlushWord
    pop hl
    jr .loop
.noun:
    push hl
    call EmitNoun
    pop hl
    jr .loop
.adj:
    push hl
    call EmitAdj
    pop hl
    jr .loop
.subj:
    push hl
    call EmitSubject
    pop hl
    jr .loop
.item:
    push hl
    call EmitItem
    pop hl
    jr .loop

; EmitNoun / EmitSubject / EmitAdj: pick a word and append its characters to
; the current token (no flush — glue). The subject is the conversation's fixed
; noun (wTalkSubject, chosen at EnterTalk); nouns are fresh random picks.
EmitNoun:
    ld c, PO_NOUNS
    call GetPersonaField
    call PickNounFrag
    jr EmitWordChars
EmitSubject:
    ld c, PO_NOUNS
    call GetPersonaField       ; HL = noun bank
    ld a, [hl+]                ; skip the count
    ld d, h
    ld e, l
    ld a, [wTalkSubject]
    call DerefTable
    jr EmitWordChars
; The adjective bank is the mood shifted by the persona's GRIM<->HOPEFUL trait
; (docs/design/05 §3 "personality-weighting"): a grim soul at neutral affinity
; already speaks in the bleak bank, a hopeful one in the warm bank.
EmitAdj:
    ld a, [wTalkPersona]
    call PersonaPtr
    inc hl
    inc hl
    inc hl                     ; PO_TRAITS + 1 = T1
    ld b, [hl]
    ld a, [wTalkMood]
    ld c, a
    ld a, b
    add a, TINT_THRESH - 1     ; T1 <= -TINT_THRESH still negative after this
    bit 7, a
    jr nz, .bleaker
    bit 7, b                   ; small negative: no tint
    jr nz, .pick
    ld a, b
    cp TINT_THRESH
    jr c, .pick
    ld a, c                    ; sunny: one bank warmer (cap at MOOD_WARM)
    cp MOOD_WARM
    jr nc, .pick
    inc c
    jr .pick
.bleaker:
    ld a, c                    ; grim: one bank bleaker (floor at MOOD_HOSTILE)
    and a, a
    jr z, .pick
    dec c
.pick:
    ld de, AdjMoods
    ld a, c
    call DerefTable
    call PickPlain
    ; fall through
EmitWordChars:
    ld a, [hl+]
    cp FONT_BASE               ; any control byte ends the word
    ret c
    call AppendWordChar
    jr EmitWordChars

; EmitItem: glue the player's equipped weapon's name into the current token —
; the NPC comments on what you're ACTUALLY carrying. Item names are space-
; padded to ITEM_NAME_MAX (items.asm), so the copy stops at the first pad
; space. CTX_WEAPON only fires with a weapon equipped, but an authored line
; could use CTRL_ITEM anywhere, so bare hands still read as a word.
EmitItem:
    ld a, [wPartyEquip + ESLOT_WEAPON1]
    and a, a
    jr nz, .named
    ld a, [wPartyEquip + ESLOT_WEAPON2]
    and a, a
    jr nz, .named
    ld hl, FragBareHands
    jr .copy
.named:
    call GetItemName           ; HL = the padded name (clobbers DE)
.copy:
    ld a, [hl+]
    cp FONT_BASE + 1
    ret c                      ; terminator, ctrl byte or the pad space
    call AppendWordChar
    jr .copy

; AppendWordChar: A -> wWordBuf (silently truncates at WORD_MAX). Preserves HL.
AppendWordChar:
    push hl
    ld c, a                    ; c = the character
    ld a, [wWordLen]
    cp WORD_MAX
    jr nc, .full
    ld e, a
    ld d, 0
    ld hl, wWordBuf
    add hl, de
    ld [hl], c
    inc a
    ld [wWordLen], a
.full:
    pop hl
    ret

; -----------------------------------------------------------------------------
; FlushWord: place wWordBuf on the grid with greedy wrapping. Never splits a
; word, never writes past column 17 / row 2 — a word that doesn't fit anywhere
; is dropped. THE bounds check keeping wTalkText writes inside 54 bytes.
; -----------------------------------------------------------------------------
FlushWord:
    ld a, [wWordLen]
    and a, a
    ret z
    ld b, a                    ; b = word length (<= WORD_MAX = 15)
    ld a, [wTalkCol]
    and a, a
    jr z, .copy                ; fresh row: a word always fits
    add a, b
    inc a                      ; col + 1 (space) + len
    cp TALK_COLS + 1
    jr nc, .newline            ; would pass column 17 -> wrap
    ld a, [wTalkCol]           ; fits: consume the (prefilled) space cell
    inc a
    ld [wTalkCol], a
    jr .copy
.newline:
    xor a, a
    ld [wTalkCol], a
    ld a, [wTalkRow]
    inc a
    ld [wTalkRow], a
.copy:
    ld a, [wTalkRow]
    cp TALK_ROWS
    jr nc, .drop               ; out of rows -> drop (shipped data never hits
                               ; this: proven by dialogue_bounds.py)
    ; HL = wTalkText + row*18 + col   (index <= 53 by the checks above)
    ld e, a
    ld d, 0
    ld hl, RowOffTable
    add hl, de
    ld a, [hl]
    ld hl, wTalkCol
    add a, [hl]
    ld e, a
    ld d, 0
    ld hl, wTalkText
    add hl, de
    ld de, wWordBuf
.cl:
    ld a, [de]
    inc de
    ld [hl+], a
    dec b
    jr nz, .cl
    ; col += len
    ld a, [wTalkCol]
    ld b, a
    ld a, [wWordLen]
    add a, b
    ld [wTalkCol], a
.drop:
    xor a, a                   ; clear the word buffer either way
    ld [wWordLen], a
    ret

RowOffTable:
    db 0, 18, 36

; =============================================================================
; Bank picking / table plumbing
; =============================================================================
; DerefTable: DE = table of pointers, A = index -> HL = table[A].
; (Also used by talk.asm for the tone-label table.)
DerefTable::
    ld l, a
    ld h, 0
    add hl, hl
    add hl, de
    ld a, [hl+]
    ld h, [hl]
    ld l, a
    ret

; PickPlain: HL = bank (count, then pointers) -> HL = a random fragment.
; (Also used by talk.asm to pick a menu-label synonym.)
PickPlain::
    ld a, [hl+]
    ld c, a                    ; c = count
    ld d, h
    ld e, l                    ; de = pointer table
    call RandMod
    jr DerefTable

; PickNounFrag / PickTopicFrag: as PickPlain, but re-rolls one step forward if
; the pick equals the previous one (no "THE BADGE NEEDS A BADGE", no repeated
; small talk two rounds running).
PickNounFrag:
    ld a, [hl+]
    ld c, a
    ld d, h
    ld e, l
    call RandMod               ; a = idx (clobbers b, hl)
    ld b, a
    ld a, [wLastNoun]
    cp b
    jr nz, .keep
    ld a, c                    ; same as last time: advance, if there's room
    cp 2
    jr c, .keep
    inc b
    ld a, b
    cp c
    jr c, .keep
    ld b, 0                    ; wrapped past the end
.keep:
    ld a, b
    ld [wLastNoun], a
    jr DerefTable

PickTopicFrag:
    ld a, [hl+]
    ld c, a
    ld d, h
    ld e, l
    call RandMod
    ld b, a
    ld a, [wLastTopic]
    cp b
    jr nz, .keep
    ld a, c
    cp 2
    jr c, .keep
    inc b
    ld a, b
    cp c
    jr c, .keep
    ld b, 0
.keep:
    ld a, b
    ld [wLastTopic], a
    jr DerefTable

; PickQuestFrag: same re-roll guard for the question bank (wLastQuest) — the
; NPC never asks the same thing two rounds running.
PickQuestFrag:
    ld a, [hl+]
    ld c, a
    ld d, h
    ld e, l
    call RandMod
    ld b, a
    ld a, [wLastQuest]
    cp b
    jr nz, .keep
    ld a, c
    cp 2
    jr c, .keep
    inc b
    ld a, b
    cp c
    jr c, .keep
    ld b, 0
.keep:
    ld a, b
    ld [wLastQuest], a
    jr DerefTable

; RandMod: C = count (>= 1) -> A = uniform-ish 0..count-1. Clobbers B, HL.
; (Also used by talk.asm to pick the conversation subject.)
RandMod::
    call Rand
.mod:
    cp c
    ret c
    sub c
    jr .mod

; PersonaPtr: A = persona id -> HL = &PersonaTable[A * PERSONA_SIZE].
; PERSONA_SIZE is 16 and ids stay below 16, so the multiply is a swap.
; Clobbers DE.
PersonaPtr::
    swap a                     ; * 16 = PERSONA_SIZE
    ld l, a
    ld h, 0
    ld de, PersonaTable
    add hl, de
    ret

; GetPersonaField: C = PO_* offset of a `dw` field -> HL = the pointed-to data
; (name string / noun bank / topic bank) for wTalkPersona.
GetPersonaField::
    ld a, [wTalkPersona]
    call PersonaPtr
    ld b, 0
    add hl, bc
    ld a, [hl+]
    ld h, [hl]
    ld l, a
    ret
