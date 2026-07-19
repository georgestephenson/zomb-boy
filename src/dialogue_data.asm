; =============================================================================
; dialogue_data.asm — the grammar's word banks + persona records (ROMX,
; pinned BANK[1] — the default-mapped bank, so talk mode reads it freely).
;
; A *bank* is `db count` followed by `count` pointers to fragments. A fragment
; is charmap'd text (assembles straight to font tile ids), may embed CTRL_NOUN
; / CTRL_ADJ slot bytes, and ends with CTRL_END. The composer (dialogue.asm)
; splits fragments into words on the space glyph; slots glue into the current
; word, so "THE ", CTRL_NOUN, "." renders as one token like "BADGE.".
;
; AUTHORING RULES (enforced against the built ROM by
; test/model/dialogue_bounds.py — run it after ANY change here):
;   * only charmap'd characters (A-Z 0-9 . , ! ? ' -) + CTRL codes;
;   * nouns/adjectives are single words (hyphenate, never a space);
;   * every fully-expanded token <= WORD_MAX (15) incl. glued punctuation;
;   * every composed line (opener/react + worst topic) must wrap into 3x18;
;   * |dot(tone push, persona traits)| <= 127 (8-bit math in ComputeDelta).
;
; Slot vocabulary: CTRL_SUBJ is the conversation's fixed subject noun (gives
; the NPC a thing they're actually talking about); CTRL_NOUN is a fresh random
; noun (variety); CTRL_ADJ a mood-tinted adjective. Mix ~half SUBJ topics per
; persona so conversations circle a subject without droning.
; =============================================================================
INCLUDE "include/constants.inc"
INCLUDE "include/charmap.inc"

; BANK[1]: the default-mapped ROMX bank. This data owns it outright (the song
; data outgrew the shared arrangement and lives in its own bank now — see
; audio.asm). Code only ever banks away from 1 transiently (ShowPortrait,
; InitSound/UpdateSound), restoring it on return.
SECTION "Dialogue Data", ROMX, BANK[1]

; -----------------------------------------------------------------------------
; Personas. Trait axes (signed, + = second pole):
;   T0 WARY<->TRUSTING   T1 GRIM<->HOPEFUL   T2 SELFISH<->GENEROUS
;   T3 JOKING<->SERIOUS
; Tuned so each persona has a winning tone (3 perfect replies >= AFFIN_REWARD):
;   police/scientist/maid: NICE   cheerleader: anything warm   businessman: RUDE
; -----------------------------------------------------------------------------
PersonaTable::
    dw NamePolice              ; PO_NAME
    db -40, 10, 20, 50         ; PO_TRAITS: wary, dutiful, protective, serious
    dw NounsPolice             ; PO_NOUNS
    dw TopicsPolice            ; PO_TOPICS
    db 3, 0                    ; PO_PAL (= 3 + persona id), pad
    dw QuestsPolice            ; PO_QUESTS
    dw CtxPolice               ; PO_CTX (in-voice observation banks)
    dw NameScientist
    db -20, 20, 0, 40          ; guarded, curious-hopeful, serious
    dw NounsScientist
    dw TopicsScientist
    db 4, 0
    dw QuestsScientist
    dw CtxScientist
    dw NameCheer
    db 30, 50, 10, -50         ; trusting, hopeful, joking
    dw NounsCheer
    dw TopicsCheer
    db 5, 0
    dw QuestsCheer
    dw CtxCheer
    dw NameMaid
    db 10, -30, 56, 20         ; weary but deeply generous
    dw NounsMaid
    dw TopicsMaid
    db 6, 0
    dw QuestsMaid
    dw CtxMaid
    dw NameBiz
    db -30, 30, -40, 10        ; bullish, selfish; respects a hard bargain
    dw NounsBiz
    dw TopicsBiz
    db 7, 0
    dw QuestsBiz
    dw CtxBiz
    dw NamePrepper
    db -50, -20, -30, 30       ; paranoid hoarder; approves of suspicion
    dw NounsPrepper
    dw TopicsPrepper
    db 6, 0
    dw QuestsPrepper
    dw CtxPrepper
    dw NameMedic
    db 30, 40, 50, 10          ; open-hearted healer; hates demands
    dw NounsMedic
    dw TopicsMedic
    db 4, 0
    dw QuestsMedic
    dw CtxMedic
    dw NameRaider
    db -40, -40, -50, -30      ; cruel humour; respects savagery
    dw NounsRaider
    dw TopicsRaider
    db 6, 0
    dw QuestsRaider
    dw CtxRaider
    dw NamePreacher
    db 40, 50, 30, 40          ; fervent hope; scandalised by rudeness
    dw NounsPreacher
    dw TopicsPreacher
    db 3, 0
    dw QuestsPreacher
    dw CtxPreacher
    dw NameFarmer
    db 20, 10, 40, 30          ; steady, stoic, generous
    dw NounsFarmer
    dw TopicsFarmer
    db 7, 0
    dw QuestsFarmer
    dw CtxFarmer

NamePolice:    db "POLICEMAN", CTRL_END
NameScientist: db "SCIENTIST", CTRL_END
NameCheer:     db "CHEERLEADER", CTRL_END
NameMaid:      db "MAID", CTRL_END
NameBiz:       db "BUSINESSMAN", CTRL_END
NamePrepper:   db "PREPPER", CTRL_END
NameMedic:     db "MEDIC", CTRL_END
NameRaider:    db "RAIDER", CTRL_END
NamePreacher:  db "PREACHER", CTRL_END
NameFarmer:    db "FARMER", CTRL_END

; -----------------------------------------------------------------------------
; Reply tones: 4 push bytes (one per trait axis, -1/0/+1), signed base, pad.
; delta = clamp(dot(push, traits) >> 2, +/-16) + base   (dialogue.asm)
; The pool covers every axis both ways; a menu shows a random 4 (talk.asm).
; Labels must be <= 7 chars (menu grid cells) — bounds model enforces.
; -----------------------------------------------------------------------------
ToneTable::
    db  0,  1,  1,  0,   2, 0  ; NICE    — warmth reads as hope + generosity
    db  1,  0,  0, -1,   0, 0  ; FLIRT   — needs their trust and their humour
    db  0,  0,  0, -1,   0, 0  ; JOKE    — lands only on the joking-natured
    db -1,  0, -1,  0,  -6, 0  ; RUDE    — provokes; the selfish respect it
    db -1,  0,  0,  1,   0, 0  ; GUARDED — careful words; the wary approve
    db  0,  1,  0, -1,   1, 0  ; CHEER   — sunny pep; grim souls wince
    db  0, -1,  0,  1,  -1, 0  ; GRIM    — bleak agreement; bonds with the weary
    db  0,  0, -1,  0,  -2, 0  ; DEMAND  — ask for stuff; the selfish get it

; Menu labels are CONTEXT-SENSITIVE: keyed by tone AND the NPC's current mood,
; with two synonyms each (BuildMenu picks one at random). Soothing a hostile
; NPC reads as EASY; agreeing with a warm one reads as LOVE IT — the same
; mechanical tone, phrased for the moment. Labels must be <= 7 chars
; (LABEL_MAX, a menu cell) — the bounds model enforces it.
ToneLabelMoods::
    dw LabelsHostile, LabelsNeutral, LabelsWarm
LabelsHostile:
    dw LhNice, LhFlirt, LhJoke, LhRude
    dw LhGuard, LhCheer, LhGrim, LhDemand
LabelsNeutral:
    dw LnNice, LnFlirt, LnJoke, LnRude
    dw LnGuard, LnCheer, LnGrim, LnDemand
LabelsWarm:
    dw LwNice, LwFlirt, LwJoke, LwRude
    dw LwGuard, LwCheer, LwGrim, LwDemand

LhNice:   db 2
          dw .f0, .f1
.f0:      db "EASY", CTRL_END
.f1:      db "SOOTHE", CTRL_END
LhFlirt:  db 2
          dw .f0, .f1
.f0:      db "CHARM", CTRL_END
.f1:      db "WINK", CTRL_END
LhJoke:   db 2
          dw .f0, .f1
.f0:      db "DEFLECT", CTRL_END
.f1:      db "QUIP", CTRL_END
LhRude:   db 2
          dw .f0, .f1
.f0:      db "SNAP", CTRL_END
.f1:      db "SCOFF", CTRL_END
LhGuard:  db 2
          dw .f0, .f1
.f0:      db "CAREFUL", CTRL_END
.f1:      db "WARY", CTRL_END
LhCheer:  db 2
          dw .f0, .f1
.f0:      db "RALLY", CTRL_END
.f1:      db "UPLIFT", CTRL_END
LhGrim:   db 2
          dw .f0, .f1
.f0:      db "AGREE", CTRL_END
.f1:      db "BLEAK", CTRL_END
LhDemand: db 2
          dw .f0, .f1
.f0:      db "PRESS", CTRL_END
.f1:      db "EXTORT", CTRL_END

LnNice:   db 2
          dw .f0, .f1
.f0:      db "NICE", CTRL_END
.f1:      db "KIND", CTRL_END
LnFlirt:  db 2
          dw .f0, .f1
.f0:      db "FLIRT", CTRL_END
.f1:      db "TEASE", CTRL_END
LnJoke:   db 2
          dw .f0, .f1
.f0:      db "JOKE", CTRL_END
.f1:      db "JEST", CTRL_END
LnRude:   db 2
          dw .f0, .f1
.f0:      db "RUDE", CTRL_END
.f1:      db "MOCK", CTRL_END
LnGuard:  db 2
          dw .f0, .f1
.f0:      db "GUARDED", CTRL_END
.f1:      db "HEDGE", CTRL_END
LnCheer:  db 2
          dw .f0, .f1
.f0:      db "CHEER", CTRL_END
.f1:      db "PEP", CTRL_END
LnGrim:   db 2
          dw .f0, .f1
.f0:      db "GRIM", CTRL_END
.f1:      db "SIGH", CTRL_END
LnDemand: db 2
          dw .f0, .f1
.f0:      db "DEMAND", CTRL_END
.f1:      db "ASK", CTRL_END

LwNice:   db 2
          dw .f0, .f1
.f0:      db "LOVE IT", CTRL_END
.f1:      db "AGREED", CTRL_END
LwFlirt:  db 2
          dw .f0, .f1
.f0:      db "SWOON", CTRL_END
.f1:      db "DARLING", CTRL_END
LwJoke:   db 2
          dw .f0, .f1
.f0:      db "BANTER", CTRL_END
.f1:      db "RIFF", CTRL_END
LwRude:   db 2
          dw .f0, .f1
.f0:      db "NEEDLE", CTRL_END
.f1:      db "JAB", CTRL_END
LwGuard:  db 2
          dw .f0, .f1
.f0:      db "DEMUR", CTRL_END
.f1:      db "MODEST", CTRL_END
LwCheer:  db 2
          dw .f0, .f1
.f0:      db "HOORAY", CTRL_END
.f1:      db "BEAM", CTRL_END
LwGrim:   db 2
          dw .f0, .f1
.f0:      db "SOBER", CTRL_END
.f1:      db "LAMENT", CTRL_END
LwDemand: db 2
          dw .f0, .f1
.f0:      db "BEG", CTRL_END
.f1:      db "REQUEST", CTRL_END

; -----------------------------------------------------------------------------
; Mood-keyed banks (index by MOOD_*): how they open, and how their world looks.
; -----------------------------------------------------------------------------
OpenerMoods::
    dw OpenHostile, OpenNeutral, OpenWarm
OpenHostile:
    db 4
    dw .f0, .f1, .f2, .f3
.f0: db "GO AWAY.", CTRL_END
.f1: db "YOU AGAIN.", CTRL_END
.f2: db "WHAT NOW?", CTRL_END
.f3: db "UGH.", CTRL_END
OpenNeutral:
    db 4
    dw .f0, .f1, .f2, .f3
.f0: db "OH. HELLO.", CTRL_END
.f1: db "HEY THERE.", CTRL_END
.f2: db "HMM. YES?", CTRL_END
.f3: db "A LIVE ONE!", CTRL_END
OpenWarm:
    db 4
    dw .f0, .f1, .f2, .f3
.f0: db "WELL HELLO!", CTRL_END
.f1: db "MY FRIEND!", CTRL_END
.f2: db "GREAT TO SEE YOU!", CTRL_END
.f3: db "YOU MADE IT!", CTRL_END

; Continuation openers: the NPC's fresh line that starts rounds 2+ ("NPC
; sentence -> your reply -> their reaction", every round).
PromptMoods::
    dw PromptHostile, PromptNeutral, PromptWarm
PromptHostile:
    db 5
    dw .f0, .f1, .f2, .f3, .f4
.f0: db "ANYWAY.", CTRL_END
.f1: db "TCH.", CTRL_END
.f2: db "STILL HERE?", CTRL_END
.f3: db "MOVING ON.", CTRL_END
.f4: db "WHAT ELSE.", CTRL_END
PromptNeutral:
    db 5
    dw .f0, .f1, .f2, .f3, .f4
.f0: db "SO.", CTRL_END
.f1: db "ANYWAY.", CTRL_END
.f2: db "YOU KNOW,", CTRL_END
.f3: db "LISTEN.", CTRL_END
.f4: db "HM.", CTRL_END
PromptWarm:
    db 5
    dw .f0, .f1, .f2, .f3, .f4
.f0: db "OH! ALSO,", CTRL_END
.f1: db "AND GET THIS.", CTRL_END
.f2: db "YOU KNOW WHAT?", CTRL_END
.f3: db "BY THE WAY,", CTRL_END
.f4: db "ONE MORE THING.", CTRL_END

AdjMoods::
    dw AdjHostile, AdjNeutral, AdjWarm
AdjHostile:
    db 4
    dw .f0, .f1, .f2, .f3
.f0: db "AWFUL", CTRL_END
.f1: db "RUINED", CTRL_END
.f2: db "HOPELESS", CTRL_END
.f3: db "GRIM", CTRL_END
AdjNeutral:
    db 4
    dw .f0, .f1, .f2, .f3
.f0: db "ODD", CTRL_END
.f1: db "FINE", CTRL_END
.f2: db "SO-SO", CTRL_END
.f3: db "CURIOUS", CTRL_END
AdjWarm:
    db 4
    dw .f0, .f1, .f2, .f3
.f0: db "GREAT", CTRL_END
.f1: db "SHINY", CTRL_END
.f2: db "PERFECT", CTRL_END
.f3: db "LOVELY", CTRL_END

; -----------------------------------------------------------------------------
; Reaction banks (index by RB_* from the reply's delta).
; -----------------------------------------------------------------------------
ReactBanks::
    dw ReactLoved, ReactLiked, ReactMeh, ReactDisliked, ReactHated
ReactLoved:
    db 4
    dw .f0, .f1, .f2, .f3
.f0: db "OH! I LOVE THAT!", CTRL_END
.f1: db "HA! WONDERFUL!", CTRL_END
.f2: db "YES! EXACTLY!", CTRL_END
.f3: db "NOW YOU'RE TALKING!", CTRL_END
ReactLiked:
    db 4
    dw .f0, .f1, .f2, .f3
.f0: db "HEH. NOT BAD.", CTRL_END
.f1: db "GOOD ANSWER.", CTRL_END
.f2: db "FAIR ENOUGH.", CTRL_END
.f3: db "I'LL ALLOW IT.", CTRL_END
ReactMeh:
    db 4
    dw .f0, .f1, .f2, .f3
.f0: db "HM. OKAY.", CTRL_END
.f1: db "IF YOU SAY SO.", CTRL_END
.f2: db "SURE. ANYWAY.", CTRL_END
.f3: db "MM.", CTRL_END
ReactDisliked:
    db 4
    dw .f0, .f1, .f2, .f3
.f0: db "EXCUSE ME?", CTRL_END
.f1: db "THAT'S NOT FUNNY.", CTRL_END
.f2: db "HMPH.", CTRL_END
.f3: db "WOW. OKAY.", CTRL_END
ReactHated:
    db 4
    dw .f0, .f1, .f2, .f3
.f0: db "HOW DARE YOU!", CTRL_END
.f1: db "WATCH IT, PAL.", CTRL_END
.f2: db "UNBELIEVABLE!", CTRL_END
.f3: db "GET AWAY FROM ME.", CTRL_END

; -----------------------------------------------------------------------------
; Tone tags: a second beat appended to the reaction that answers the SPECIFIC
; tone you used (indexed by TONE_*; liked when delta > 0, disliked when < 0).
; "OH! I LOVE THAT! YOU'RE TROUBLE." lands very differently from
; "OH! I LOVE THAT! BLUNT. GOOD." — this is what makes replies feel heard.
; -----------------------------------------------------------------------------
ToneTagsLiked::
    dw TagNiceL, TagFlirtL, TagJokeL, TagRudeL
    dw TagGuardL, TagCheerL, TagGrimL, TagDemandL
ToneTagsDisliked::
    dw TagNiceD, TagFlirtD, TagJokeD, TagRudeD
    dw TagGuardD, TagCheerD, TagGrimD, TagDemandD

TagNiceL:
    db 2
    dw .f0, .f1
.f0: db "SWEET OF YOU.", CTRL_END
.f1: db "KIND SOUL.", CTRL_END
TagNiceD:
    db 2
    dw .f0, .f1
.f0: db "TOO SOFT.", CTRL_END
.f1: db "SAVE THE PITY.", CTRL_END
TagFlirtL:
    db 2
    dw .f0, .f1
.f0: db "YOU'RE TROUBLE.", CTRL_END
.f1: db "OH, STOP IT.", CTRL_END
TagFlirtD:
    db 2
    dw .f0, .f1
.f0: db "NOT A CHANCE.", CTRL_END
.f1: db "HOW FORWARD.", CTRL_END
TagJokeL:
    db 2
    dw .f0, .f1
.f0: db "GOOD ONE.", CTRL_END
.f1: db "HA. AGAIN.", CTRL_END
TagJokeD:
    db 2
    dw .f0, .f1
.f0: db "NOT FUNNY.", CTRL_END
.f1: db "SO CHILDISH.", CTRL_END
TagRudeL:
    db 2
    dw .f0, .f1
.f0: db "STRAIGHT TALK.", CTRL_END
.f1: db "BLUNT. GOOD.", CTRL_END
TagRudeD:
    db 2
    dw .f0, .f1
.f0: db "CHARMING.", CTRL_END
.f1: db "MANNERS.", CTRL_END
TagGuardL:
    db 2
    dw .f0, .f1
.f0: db "SMART. CAREFUL.", CTRL_END
.f1: db "WISE.", CTRL_END
TagGuardD:
    db 2
    dw .f0, .f1
.f0: db "SO TENSE.", CTRL_END
.f1: db "RELAX A LITTLE.", CTRL_END
TagCheerL:
    db 2
    dw .f0, .f1
.f0: db "THAT'S PEP!", CTRL_END
.f1: db "SUNSHINE!", CTRL_END
TagCheerD:
    db 2
    dw .f0, .f1
.f0: db "TOO CHIPPER.", CTRL_END
.f1: db "EASE UP.", CTRL_END
TagGrimL:
    db 2
    dw .f0, .f1
.f0: db "TRUTH.", CTRL_END
.f1: db "SO IT GOES.", CTRL_END
TagGrimD:
    db 2
    dw .f0, .f1
.f0: db "SO BLEAK.", CTRL_END
.f1: db "LIGHTEN UP.", CTRL_END
TagDemandL:
    db 2
    dw .f0, .f1
.f0: db "A DEALMAKER.", CTRL_END
.f1: db "BOLD ASK.", CTRL_END
TagDemandD:
    db 2
    dw .f0, .f1
.f0: db "THE NERVE.", CTRL_END
.f1: db "EARN IT.", CTRL_END

; -----------------------------------------------------------------------------
; Outcome banks (index by OUTCOME_*): the conversation's final line.
; -----------------------------------------------------------------------------
OutcomeBanks::
    dw OutFight, OutPart, OutReward
OutFight:
    db 2
    dw .f0, .f1
.f0: db "THAT'S IT. PUT 'EM UP!", CTRL_END
.f1: db "YOU ASKED FOR THIS!", CTRL_END
OutPart:
    db 2
    dw .f0, .f1
.f0: db "WELL. STAY SAFE OUT THERE.", CTRL_END
.f1: db "SEE YOU AROUND, DRIFTER.", CTRL_END
OutReward:
    db 2
    dw .f0, .f1
.f0: db "YOU'RE ALRIGHT. TAKE THIS!", CTRL_END
.f1: db "FOR YOU, FRIEND. TAKE THIS!", CTRL_END

; -----------------------------------------------------------------------------
; Context observation banks: PER-PERSONA and in-voice. Each persona record's
; PO_CTX points at a table of 8 banks (index by CTX_*) — the same live-state
; trigger lands completely differently depending on who's talking: the raider
; menaces your pistol, the preacher tuts at it, the medic wants it away from
; the cots. dialogue.asm PickContext decides WHICH context fires (priority +
; wCtxUsed); the talking persona decides HOW it's said.
; AUTHORING RULES: lines stand alone on a page (must fit 3x18); every
; CTX_WEAPON line must carry CTRL_ITEM (the tests and the model rely on the
; remark naming the actual item).
; -----------------------------------------------------------------------------
CtxPolice:
    dw .hurt, .hungry, .tired, .weapon, .night, .morning, .dusk, .day
.hurt:
    db 2
    dw .h0, .h1
.h0: db "YOU'RE HURT. FILE A REPORT.", CTRL_END
.h1: db "THAT'S A CODE THREE WOUND.", CTRL_END
.hungry:
    db 2
    dw .g0, .g1
.g0: db "YOU LOOK HUNGRY. STAY LEGAL.", CTRL_END
.g1: db "STARVING IS NO EXCUSE TO LOOT.", CTRL_END
.tired:
    db 2
    dw .t0, .t1
.t0: db "NO SLEEPING ON MY BEAT.", CTRL_END
.t1: db "YOU'RE SWAYING, CITIZEN.", CTRL_END
.weapon:
    db 2
    dw .w0, .w1
.w0: db "PERMIT FOR THAT ", CTRL_ITEM, "?", CTRL_END
.w1: db "KEEP THE ", CTRL_ITEM, " HOLSTERED.", CTRL_END
.night:
    db 2
    dw .n0, .n1
.n0: db "CURFEW STARTED AT DARK.", CTRL_END
.n1: db "NOTHING GOOD WALKS AT NIGHT.", CTRL_END
.morning:
    db 2
    dw .m0, .m1
.m0: db "EARLY SHIFT, CITIZEN?", CTRL_END
.m1: db "MORNING PATROL. ALL QUIET.", CTRL_END
.dusk:
    db 2
    dw .d0, .d1
.d0: db "CURFEW SOON. HEAD HOME.", CTRL_END
.d1: db "SUN'S GOING DOWN. MOVE ALONG.", CTRL_END
.day:
    db 2
    dw .y0, .y1
.y0: db "ALL QUIET ON MY WATCH.", CTRL_END
.y1: db "MIDDAY. NOTHING TO REPORT.", CTRL_END

CtxScientist:
    dw .hurt, .hungry, .tired, .weapon, .night, .morning, .dusk, .day
.hurt:
    db 2
    dw .h0, .h1
.h0: db "FASCINATING WOUND. DOES IT HURT?", CTRL_END
.h1: db "YOU'RE LEAKING. NOTED.", CTRL_END
.hungry:
    db 2
    dw .g0, .g1
.g0: db "YOUR GLUCOSE IS CLEARLY LOW.", CTRL_END
.g1: db "SUBJECT SHOWS SIGNS OF HUNGER.", CTRL_END
.tired:
    db 2
    dw .t0, .t1
.t0: db "YOUR BLINK RATE HAS DOUBLED.", CTRL_END
.t1: db "SLEEP DEBT SKEWS MY DATA.", CTRL_END
.weapon:
    db 2
    dw .w0, .w1
.w0: db "A ", CTRL_ITEM, ". CRUDE BUT EFFECTIVE.", CTRL_END
.w1: db "IS THAT ", CTRL_ITEM, " CALIBRATED?", CTRL_END
.night:
    db 2
    dw .n0, .n1
.n0: db "THEY GROW ACTIVE AFTER DARK.", CTRL_END
.n1: db "NOCTURNAL PATTERNS. INTERESTING.", CTRL_END
.morning:
    db 2
    dw .m0, .m1
.m0: db "MORNING LIGHT. GOOD READINGS.", CTRL_END
.m1: db "I WAS UP ALL NIGHT TESTING.", CTRL_END
.dusk:
    db 2
    dw .d0, .d1
.d0: db "DUSK. SPECIMENS STIR SOON.", CTRL_END
.d1: db "LIGHT IS FADING. SO IS MY GRANT.", CTRL_END
.day:
    db 2
    dw .y0, .y1
.y0: db "PEAK SUN. PEAK DATA.", CTRL_END
.y1: db "CONDITIONS ARE STABLE TODAY.", CTRL_END

CtxCheer:
    dw .hurt, .hungry, .tired, .weapon, .night, .morning, .dusk, .day
.hurt:
    db 2
    dw .h0, .h1
.h0: db "OUCH! WALK IT OFF, CHAMP!", CTRL_END
.h1: db "BLOOD? THAT'S SO NOT CUTE.", CTRL_END
.hungry:
    db 2
    dw .g0, .g1
.g0: db "YOU NEED A SNACK, STAT!", CTRL_END
.g1: db "HUNGRY? THAT'S NO PEP AT ALL!", CTRL_END
.tired:
    db 2
    dw .t0, .t1
.t0: db "WAKE UP! GIVE ME ENERGY!", CTRL_END
.t1: db "NO NAPS! WE'VE GOT SPIRIT!", CTRL_END
.weapon:
    db 2
    dw .w0, .w1
.w0: db "A ", CTRL_ITEM, "? SO FIERCE!", CTRL_END
.w1: db "SWING THAT ", CTRL_ITEM, " LIKE YOU MEAN IT!", CTRL_END
.night:
    db 2
    dw .n0, .n1
.n0: db "NIGHT GAMES ARE THE BEST!", CTRL_END
.n1: db "SO DARK! SPOOKY VIBES!", CTRL_END
.morning:
    db 2
    dw .m0, .m1
.m0: db "RISE AND SHINE, TEAM!", CTRL_END
.m1: db "MORNING PRACTICE! LET'S GO!", CTRL_END
.dusk:
    db 2
    dw .d0, .d1
.d0: db "SUNSET SPARKLES! LOVE IT!", CTRL_END
.d1: db "GOLDEN HOUR, GO TEAM!", CTRL_END
.day:
    db 2
    dw .y0, .y1
.y0: db "PERFECT DAY FOR A ROUTINE!", CTRL_END
.y1: db "SUN'S OUT! POMS OUT!", CTRL_END

CtxMaid:
    dw .hurt, .hungry, .tired, .weapon, .night, .morning, .dusk, .day
.hurt:
    db 2
    dw .h0, .h1
.h0: db "YOU'RE DRIPPING ON THE FLOOR.", CTRL_END
.h1: db "I'LL FETCH A CLEAN CLOTH.", CTRL_END
.hungry:
    db 2
    dw .g0, .g1
.g0: db "I HEAR YOUR STOMACH FROM HERE.", CTRL_END
.g1: db "I WOULD OFFER TEA AND BISCUITS.", CTRL_END
.tired:
    db 2
    dw .t0, .t1
.t0: db "YOU LOOK READY TO DROP, DEAR.", CTRL_END
.t1: db "SHALL I TURN DOWN A BED?", CTRL_END
.weapon:
    db 2
    dw .w0, .w1
.w0: db "MIND THE ", CTRL_ITEM, " ON MY FLOORS.", CTRL_END
.w1: db "LEAVE THE ", CTRL_ITEM, " ON THE RACK.", CTRL_END
.night:
    db 2
    dw .n0, .n1
.n0: db "GUESTS ARRIVE SO LATE NOW.", CTRL_END
.n1: db "I STILL SWEEP AFTER DARK.", CTRL_END
.morning:
    db 2
    dw .m0, .m1
.m0: db "UP WITH THE LARKS, ARE WE?", CTRL_END
.m1: db "MORNING. MIND THE WET FLOOR.", CTRL_END
.dusk:
    db 2
    dw .d0, .d1
.d0: db "I LIGHT THE LAMPS AT DUSK.", CTRL_END
.d1: db "EVENING ALREADY. MORE CHORES.", CTRL_END
.day:
    db 2
    dw .y0, .y1
.y0: db "A FINE DAY FOR AIRING LINENS.", CTRL_END
.y1: db "DUST DANCES IN THE NOON SUN.", CTRL_END

CtxBiz:
    dw .hurt, .hungry, .tired, .weapon, .night, .morning, .dusk, .day
.hurt:
    db 2
    dw .h0, .h1
.h0: db "YOU'RE BLEEDING ON MY SUIT.", CTRL_END
.h1: db "MEDICAL BILLS. BAD MARGINS.", CTRL_END
.hungry:
    db 2
    dw .g0, .g1
.g0: db "HUNGER IS BAD FOR OUTPUT.", CTRL_END
.g1: db "I SKIP LUNCH. POWER MOVE.", CTRL_END
.tired:
    db 2
    dw .t0, .t1
.t0: db "SLEEP IS FOR THE ACQUIRED.", CTRL_END
.t1: db "YOU'RE BURNING OUT. LIABILITY.", CTRL_END
.weapon:
    db 2
    dw .w0, .w1
.w0: db "IS THAT ", CTRL_ITEM, " A COMPANY ASSET?", CTRL_END
.w1: db "NICE ", CTRL_ITEM, ". LET'S TALK TERMS.", CTRL_END
.night:
    db 2
    dw .n0, .n1
.n0: db "MARKETS NEVER SLEEP. NOR DO I.", CTRL_END
.n1: db "NIGHT SHIFT. NO OVERTIME PAY.", CTRL_END
.morning:
    db 2
    dw .m0, .m1
.m0: db "EARLY BIRD GETS THE MERGER.", CTRL_END
.m1: db "COFFEE FIRST. THEN DEALS.", CTRL_END
.dusk:
    db 2
    dw .d0, .d1
.d0: db "CLOSING BELL SOON.", CTRL_END
.d1: db "END OF QUARTER. END OF DAY.", CTRL_END
.day:
    db 2
    dw .y0, .y1
.y0: db "PRIME BUSINESS HOURS.", CTRL_END
.y1: db "LUNCH MEETING RAN LONG.", CTRL_END

CtxPrepper:
    dw .hurt, .hungry, .tired, .weapon, .night, .morning, .dusk, .day
.hurt:
    db 2
    dw .h0, .h1
.h0: db "BLOOD DRAWS THEM. COVER IT.", CTRL_END
.h1: db "WOUNDS GO BAD FAST OUT HERE.", CTRL_END
.hungry:
    db 2
    dw .g0, .g1
.g0: db "SHOULD HAVE STOCKED UP LIKE ME.", CTRL_END
.g1: db "HUNGER MAKES YOU SLOPPY.", CTRL_END
.tired:
    db 2
    dw .t0, .t1
.t0: db "SLEEP IS WHEN THEY GET YOU.", CTRL_END
.t1: db "I NAP IN SHIFTS. YOU SHOULD.", CTRL_END
.weapon:
    db 2
    dw .w0, .w1
.w0: db "A ", CTRL_ITEM, ". SMART. TRUST NOTHING.", CTRL_END
.w1: db "I'VE GOT SIX LIKE THAT ", CTRL_ITEM, ".", CTRL_END
.night:
    db 2
    dw .n0, .n1
.n0: db "NIGHT. THEY'RE OUT THERE. LISTEN.", CTRL_END
.n1: db "STAY LOW AFTER DARK.", CTRL_END
.morning:
    db 2
    dw .m0, .m1
.m0: db "DAWN. FIRST PERIMETER CHECK.", CTRL_END
.m1: db "MADE IT THROUGH ANOTHER NIGHT.", CTRL_END
.dusk:
    db 2
    dw .d0, .d1
.d0: db "LOCK UP BEFORE FULL DARK.", CTRL_END
.d1: db "DUSK. START COUNTING EXITS.", CTRL_END
.day:
    db 2
    dw .y0, .y1
.y0: db "TOO EXPOSED IN DAYLIGHT.", CTRL_END
.y1: db "CLEAR SKIES. DRONE WEATHER.", CTRL_END

CtxMedic:
    dw .hurt, .hungry, .tired, .weapon, .night, .morning, .dusk, .day
.hurt:
    db 2
    dw .h0, .h1
.h0: db "SIT DOWN. LET ME SEE THAT.", CTRL_END
.h1: db "THAT NEEDS STITCHES. NOW.", CTRL_END
.hungry:
    db 2
    dw .g0, .g1
.g0: db "MALNOURISHED. EAT SOMETHING.", CTRL_END
.g1: db "YOUR BLOOD SUGAR IS CRASHING.", CTRL_END
.tired:
    db 2
    dw .t0, .t1
.t0: db "EXHAUSTION KILLS SLOWLY.", CTRL_END
.t1: db "PUPILS SLUGGISH. YOU NEED REST.", CTRL_END
.weapon:
    db 2
    dw .w0, .w1
.w0: db "A ", CTRL_ITEM, "? I STITCH WHAT THOSE DO.", CTRL_END
.w1: db "KEEP THE ", CTRL_ITEM, " OFF MY COTS.", CTRL_END
.night:
    db 2
    dw .n0, .n1
.n0: db "NIGHT SHIFT AGAIN. ALWAYS IS.", CTRL_END
.n1: db "BITES COME IN AFTER DARK.", CTRL_END
.morning:
    db 2
    dw .m0, .m1
.m0: db "MORNING ROUNDS. YOU'RE FIRST.", CTRL_END
.m1: db "SLEPT AT THE CLINIC AGAIN.", CTRL_END
.dusk:
    db 2
    dw .d0, .d1
.d0: db "DUSK. TRIAGE FILLS UP SOON.", CTRL_END
.d1: db "LAST LIGHT. STOCK THE GAUZE.", CTRL_END
.day:
    db 2
    dw .y0, .y1
.y0: db "QUIET WARD TODAY. GOOD.", CTRL_END
.y1: db "SUN HELPS THE HEALING.", CTRL_END

CtxRaider:
    dw .hurt, .hungry, .tired, .weapon, .night, .morning, .dusk, .day
.hurt:
    db 2
    dw .h0, .h1
.h0: db "YOU'RE LEAKING. EASY PICKINGS.", CTRL_END
.h1: db "WOUNDED PREY. MY FAVORITE.", CTRL_END
.hungry:
    db 2
    dw .g0, .g1
.g0: db "HUNGRY? SHOULD HAVE PAID UP.", CTRL_END
.g1: db "I ATE YESTERDAY. TOUGH LUCK.", CTRL_END
.tired:
    db 2
    dw .t0, .t1
.t0: db "SLEEP HERE, WAKE UP POORER.", CTRL_END
.t1: db "YAWN AGAIN. SEE WHAT HAPPENS.", CTRL_END
.weapon:
    db 2
    dw .w0, .w1
.w0: db "DROP THE ", CTRL_ITEM, " AND WALK.", CTRL_END
.w1: db "CUTE ", CTRL_ITEM, ". I'VE HAD BIGGER.", CTRL_END
.night:
    db 2
    dw .n0, .n1
.n0: db "NIGHT IS MINE. YOU'RE BORROWING IT.", CTRL_END
.n1: db "DARK OUT. SCREAM ALL YOU WANT.", CTRL_END
.morning:
    db 2
    dw .m0, .m1
.m0: db "UP EARLY TO GET ROBBED?", CTRL_END
.m1: db "MORNING SHIFT PAYS DOUBLE.", CTRL_END
.dusk:
    db 2
    dw .d0, .d1
.d0: db "TOLL DOUBLES AFTER SUNDOWN.", CTRL_END
.d1: db "GETTING DARK. GETTING PRICEY.", CTRL_END
.day:
    db 2
    dw .y0, .y1
.y0: db "BROAD DAYLIGHT? BOLD OF YOU.", CTRL_END
.y1: db "SUN'S UP. RATES ARE TOO.", CTRL_END

CtxPreacher:
    dw .hurt, .hungry, .tired, .weapon, .night, .morning, .dusk, .day
.hurt:
    db 2
    dw .h0, .h1
.h0: db "YOUR BLOOD CRIES OUT. BE HEALED!", CTRL_END
.h1: db "SUFFERING TESTS THE FAITHFUL.", CTRL_END
.hungry:
    db 2
    dw .g0, .g1
.g0: db "FASTING, OR JUST STARVING?", CTRL_END
.g1: db "NONE GO HUNGRY AT MY TABLE.", CTRL_END
.tired:
    db 2
    dw .t0, .t1
.t0: db "REST, AS THE SEVENTH DAY ASKS.", CTRL_END
.t1: db "WEARY SOULS STUMBLE INTO SIN.", CTRL_END
.weapon:
    db 2
    dw .w0, .w1
.w0: db "PUT THE ", CTRL_ITEM, " AWAY, CHILD.", CTRL_END
.w1: db "A ", CTRL_ITEM, " WON'T SAVE YOUR SOUL.", CTRL_END
.night:
    db 2
    dw .n0, .n1
.n0: db "THE DARK TESTS US ALL.", CTRL_END
.n1: db "EVEN NIGHT ENDS. HAVE FAITH.", CTRL_END
.morning:
    db 2
    dw .m0, .m1
.m0: db "A NEW DAY. A NEW MERCY.", CTRL_END
.m1: db "DAWN IS A SMALL RESURRECTION.", CTRL_END
.dusk:
    db 2
    dw .d0, .d1
.d0: db "EVENSONG SOON. JOIN US.", CTRL_END
.d1: db "THE LIGHT FADES. PRAY FASTER.", CTRL_END
.day:
    db 2
    dw .y0, .y1
.y0: db "THE SUN SHINES ON THE SAVED.", CTRL_END
.y1: db "GLORIOUS NOON! CAN YOU FEEL IT?", CTRL_END

CtxFarmer:
    dw .hurt, .hungry, .tired, .weapon, .night, .morning, .dusk, .day
.hurt:
    db 2
    dw .h0, .h1
.h0: db "THAT CUT WILL FESTER. TEND IT.", CTRL_END
.h1: db "SEEN WORSE FROM A THRESHER.", CTRL_END
.hungry:
    db 2
    dw .g0, .g1
.g0: db "SKIN AND BONES. EAT A SPUD.", CTRL_END
.g1: db "NOBODY STARVES ON MY LAND.", CTRL_END
.tired:
    db 2
    dw .t0, .t1
.t0: db "YOU SLEEP LESS THAN MY ROOSTER.", CTRL_END
.t1: db "REST WHEN THE SUN DOES.", CTRL_END
.weapon:
    db 2
    dw .w0, .w1
.w0: db "THAT ", CTRL_ITEM, " WON'T PLOW A FIELD.", CTRL_END
.w1: db "WE USE A ", CTRL_ITEM, " ON VARMINTS.", CTRL_END
.night:
    db 2
    dw .n0, .n1
.n0: db "OWLS ARE OUT. SO ARE WORSE.", CTRL_END
.n1: db "NIGHT MEANS BARN DOORS SHUT.", CTRL_END
.morning:
    db 2
    dw .m0, .m1
.m0: db "BEEN UP SINCE FOUR. YOU?", CTRL_END
.m1: db "DEW IS STILL ON THE FIELDS.", CTRL_END
.dusk:
    db 2
    dw .d0, .d1
.d0: db "SUNDOWN. COWS HEAD IN.", CTRL_END
.d1: db "RED SKY TONIGHT. GOOD SIGN.", CTRL_END
.day:
    db 2
    dw .y0, .y1
.y0: db "GOOD GROWING SUN TODAY.", CTRL_END
.y1: db "HAY WON'T CUT ITSELF.", CTRL_END

; CTRL_ITEM's safety net when no weapon is equipped (an authored line could
; use the slot anywhere; CTX_WEAPON itself only fires armed).
FragBareHands::
    db "FISTS", CTRL_END

; -----------------------------------------------------------------------------
; Per-persona noun banks + topic templates + questions.
; -----------------------------------------------------------------------------
NounsPolice:
    db 6
    dw .f0, .f1, .f2, .f3, .f4, .f5
.f0: db "BADGE", CTRL_END
.f1: db "CURFEW", CTRL_END
.f2: db "DONUT", CTRL_END
.f3: db "PATROL", CTRL_END
.f4: db "RADIO", CTRL_END
.f5: db "LAW", CTRL_END
TopicsPolice:
    db 6
    dw .f0, .f1, .f2, .f3, .f4, .f5
.f0: db "THE ", CTRL_SUBJ, " IS ", CTRL_ADJ, " TODAY.", CTRL_END
.f1: db "STAY BEHIND THE ", CTRL_SUBJ, ".", CTRL_END
.f2: db "I LOST MY ", CTRL_NOUN, " AGAIN.", CTRL_END
.f3: db "MY ", CTRL_SUBJ, " KEEPS US SAFE.", CTRL_END
.f4: db "SOMEONE STOLE THE ", CTRL_NOUN, ".", CTRL_END
.f5: db "TEN-FOUR.", CTRL_END
QuestsPolice:
    db 4
    dw .f0, .f1, .f2, .f3
.f0: db "IS THE ", CTRL_SUBJ, " SECURE?", CTRL_END
.f1: db "SEEN ANY LOOTERS TONIGHT?", CTRL_END
.f2: db "YOU STAYING OUT OF TROUBLE?", CTRL_END
.f3: db "WHO SENT YOU OUT HERE?", CTRL_END

NounsScientist:
    db 6
    dw .f0, .f1, .f2, .f3, .f4, .f5
.f0: db "SAMPLE", CTRL_END
.f1: db "DATA", CTRL_END
.f2: db "LAB", CTRL_END
.f3: db "THEORY", CTRL_END
.f4: db "FORMULA", CTRL_END
.f5: db "SPORES", CTRL_END
TopicsScientist:
    db 6
    dw .f0, .f1, .f2, .f3, .f4, .f5
.f0: db "MY ", CTRL_SUBJ, " LOOKS ", CTRL_ADJ, ".", CTRL_END
.f1: db "THE ", CTRL_SUBJ, " NEEDS A ", CTRL_NOUN, ".", CTRL_END
.f2: db "DON'T TOUCH MY ", CTRL_SUBJ, ".", CTRL_END
.f3: db "SCIENCE IS ", CTRL_ADJ, ".", CTRL_END
.f4: db "MY ", CTRL_ADJ, " ", CTRL_NOUN, " GREW LEGS.", CTRL_END
.f5: db "FASCINATING.", CTRL_END
QuestsScientist:
    db 4
    dw .f0, .f1, .f2, .f3
.f0: db "CARE TO SEE MY ", CTRL_SUBJ, "?", CTRL_END
.f1: db "GOT A SPARE ", CTRL_NOUN, "?", CTRL_END
.f2: db "DOES SCIENCE EXCITE YOU?", CTRL_END
.f3: db "IS MY ", CTRL_SUBJ, " LEAKING AGAIN?", CTRL_END

NounsCheer:
    db 6
    dw .f0, .f1, .f2, .f3, .f4, .f5
.f0: db "SQUAD", CTRL_END
.f1: db "POM-POMS", CTRL_END
.f2: db "ROUTINE", CTRL_END
.f3: db "TRYOUTS", CTRL_END
.f4: db "PEP", CTRL_END
.f5: db "MEGAPHONE", CTRL_END
TopicsCheer:
    db 6
    dw .f0, .f1, .f2, .f3, .f4, .f5
.f0: db "THE ", CTRL_SUBJ, " IS SO ", CTRL_ADJ, "!", CTRL_END
.f1: db "GIMME A Z-O-M-B!", CTRL_END
.f2: db "MY ", CTRL_SUBJ, " NEEDS ", CTRL_ADJ, " VIBES!", CTRL_END
.f3: db "PRACTICE WAS ", CTRL_ADJ, "!", CTRL_END
.f4: db "TWO FOUR SIX EIGHT!", CTRL_END
.f5: db "THE ", CTRL_NOUN, " NEEDS A NEW CHANT.", CTRL_END
QuestsCheer:
    db 4
    dw .f0, .f1, .f2, .f3
.f0: db "GOT ANY TEAM SPIRIT?", CTRL_END
.f1: db "WANNA JOIN THE ", CTRL_SUBJ, "?", CTRL_END
.f2: db "READY? OKAY?", CTRL_END
.f3: db "ISN'T IT ALL SO ", CTRL_ADJ, "?", CTRL_END

NounsMaid:
    db 6
    dw .f0, .f1, .f2, .f3, .f4, .f5
.f0: db "DUSTER", CTRL_END
.f1: db "LINENS", CTRL_END
.f2: db "MANOR", CTRL_END
.f3: db "TEACUPS", CTRL_END
.f4: db "SILVER", CTRL_END
.f5: db "FLOORS", CTRL_END
TopicsMaid:
    db 6
    dw .f0, .f1, .f2, .f3, .f4, .f5
.f0: db "THE ", CTRL_SUBJ, " WON'T CLEAN ITSELF.", CTRL_END
.f1: db "I JUST POLISHED THE ", CTRL_SUBJ, ".", CTRL_END
.f2: db "SO MUCH ", CTRL_ADJ, " DUST.", CTRL_END
.f3: db "I DUST. I MOP. I ENDURE.", CTRL_END
.f4: db "COBWEBS IN THE ", CTRL_NOUN, " AGAIN.", CTRL_END
.f5: db "SIGH.", CTRL_END
QuestsMaid:
    db 4
    dw .f0, .f1, .f2, .f3
.f0: db "DID YOU WIPE YOUR FEET?", CTRL_END
.f1: db "SEEN MY ", CTRL_SUBJ, "?", CTRL_END
.f2: db "DOES THIS LOOK CLEAN TO YOU?", CTRL_END
.f3: db "MORE TEA, DEAR?", CTRL_END

NounsBiz:
    db 6
    dw .f0, .f1, .f2, .f3, .f4, .f5
.f0: db "MERGER", CTRL_END
.f1: db "BRIEFCASE", CTRL_END
.f2: db "PROFITS", CTRL_END
.f3: db "MEETING", CTRL_END
.f4: db "MARKET", CTRL_END
.f5: db "MEMO", CTRL_END
TopicsBiz:
    db 6
    dw .f0, .f1, .f2, .f3, .f4, .f5
.f0: db "THE ", CTRL_SUBJ, " LOOKS ", CTRL_ADJ, ".", CTRL_END
.f1: db "SYNERGY. THE ", CTRL_SUBJ, ". YES.", CTRL_END
.f2: db "MY ", CTRL_NOUN, " IS OVERDUE.", CTRL_END
.f3: db "BUY LOW. SELL ", CTRL_ADJ, ".", CTRL_END
.f4: db "TIME IS MONEY. YOU OWE ME BOTH.", CTRL_END
.f5: db "THE ", CTRL_SUBJ, "? PENDING.", CTRL_END
QuestsBiz:
    db 4
    dw .f0, .f1, .f2, .f3
.f0: db "GOT A MINUTE FOR THE ", CTRL_SUBJ, "?", CTRL_END
.f1: db "ARE YOU BUYING OR SELLING?", CTRL_END
.f2: db "WHERE IS MY ", CTRL_NOUN, "?", CTRL_END
.f3: db "CAN WE CIRCLE BACK LATER?", CTRL_END

NounsPrepper:
    db 6
    dw .f0, .f1, .f2, .f3, .f4, .f5
.f0: db "BUNKER", CTRL_END
.f1: db "CANS", CTRL_END
.f2: db "STOCKPILE", CTRL_END
.f3: db "RATIONS", CTRL_END
.f4: db "TINFOIL", CTRL_END
.f5: db "GENERATOR", CTRL_END
TopicsPrepper:
    db 6
    dw .f0, .f1, .f2, .f3, .f4, .f5
.f0: db "THE ", CTRL_SUBJ, " IS SEALED.", CTRL_END
.f1: db "I COUNTED MY ", CTRL_SUBJ, " TWICE.", CTRL_END
.f2: db "THE END WAS ", CTRL_ADJ, " ANYWAY.", CTRL_END
.f3: db "MY ", CTRL_SUBJ, " OUTLASTS US ALL.", CTRL_END
.f4: db "TRUST NO ONE. NOT THE ", CTRL_NOUN, ".", CTRL_END
.f5: db "THEY'RE LISTENING.", CTRL_END
QuestsPrepper:
    db 4
    dw .f0, .f1, .f2, .f3
.f0: db "WHO TOLD YOU ABOUT THE ", CTRL_SUBJ, "?", CTRL_END
.f1: db "DID ANYONE FOLLOW YOU?", CTRL_END
.f2: db "HOW MANY CANS DO YOU OWN?", CTRL_END
.f3: db "YOU HEAR THAT TOO, RIGHT?", CTRL_END

NounsMedic:
    db 6
    dw .f0, .f1, .f2, .f3, .f4, .f5
.f0: db "BANDAGES", CTRL_END
.f1: db "CLINIC", CTRL_END
.f2: db "VITALS", CTRL_END
.f3: db "PLASMA", CTRL_END
.f4: db "SPLINT", CTRL_END
.f5: db "GAUZE", CTRL_END
TopicsMedic:
    db 6
    dw .f0, .f1, .f2, .f3, .f4, .f5
.f0: db "THE ", CTRL_SUBJ, " RAN OUT AGAIN.", CTRL_END
.f1: db "HOLD STILL. THIS LOOKS ", CTRL_ADJ, ".", CTRL_END
.f2: db "I SAVED SIX WITH ONE ", CTRL_SUBJ, ".", CTRL_END
.f3: db "YOUR ", CTRL_NOUN, " READS ", CTRL_ADJ, ".", CTRL_END
.f4: db "SAY AAH.", CTRL_END
.f5: db "CLEAN WATER. THAT'S THE DREAM.", CTRL_END
QuestsMedic:
    db 4
    dw .f0, .f1, .f2, .f3
.f0: db "WHERE DOES IT HURT?", CTRL_END
.f1: db "ANY DIZZINESS? BLURRED SIGHT?", CTRL_END
.f2: db "HAVE YOU SEEN MY ", CTRL_SUBJ, "?", CTRL_END
.f3: db "WHEN DID YOU LAST SLEEP?", CTRL_END

NounsRaider:
    db 6
    dw .f0, .f1, .f2, .f3, .f4, .f5
.f0: db "LOOT", CTRL_END
.f1: db "TURF", CTRL_END
.f2: db "CROWBAR", CTRL_END
.f3: db "STASH", CTRL_END
.f4: db "TOLL", CTRL_END
.f5: db "SCRAPS", CTRL_END
TopicsRaider:
    db 6
    dw .f0, .f1, .f2, .f3, .f4, .f5
.f0: db "THIS IS MY ", CTRL_SUBJ, ".", CTRL_END
.f1: db "THE ", CTRL_SUBJ, " LOOKS ", CTRL_ADJ, ".", CTRL_END
.f2: db "PAY THE ", CTRL_NOUN, " OR ELSE.", CTRL_END
.f3: db "NICE ", CTRL_SUBJ, ". SHAME IF IT BROKE.", CTRL_END
.f4: db "I BITE HARDER THAN THEY DO.", CTRL_END
.f5: db "HAND IT OVER. ALL OF IT.", CTRL_END
QuestsRaider:
    db 4
    dw .f0, .f1, .f2, .f3
.f0: db "WHAT'S IN THE BAG?", CTRL_END
.f1: db "YOU GOT A DEATH WISH?", CTRL_END
.f2: db "WANT TO KEEP YOUR ", CTRL_NOUN, "?", CTRL_END
.f3: db "WHO'S GONNA STOP ME? YOU?", CTRL_END

NounsPreacher:
    db 6
    dw .f0, .f1, .f2, .f3, .f4, .f5
.f0: db "FLOCK", CTRL_END
.f1: db "CHAPEL", CTRL_END
.f2: db "SERMON", CTRL_END
.f3: db "HYMNS", CTRL_END
.f4: db "GOSPEL", CTRL_END
.f5: db "BELLS", CTRL_END
TopicsPreacher:
    db 6
    dw .f0, .f1, .f2, .f3, .f4, .f5
.f0: db "THE ", CTRL_SUBJ, " NEEDS YOU.", CTRL_END
.f1: db "I PREACH TO THE ", CTRL_SUBJ, ".", CTRL_END
.f2: db "THE END TIMES LOOK ", CTRL_ADJ, ".", CTRL_END
.f3: db "SING! THE ", CTRL_SUBJ, " LISTENS.", CTRL_END
.f4: db "REPENT! THE ", CTRL_NOUN, " DEMANDS IT!", CTRL_END
.f5: db "HALLELUJAH.", CTRL_END
QuestsPreacher:
    db 4
    dw .f0, .f1, .f2, .f3
.f0: db "HAVE YOU HEARD THE GOOD WORD?", CTRL_END
.f1: db "WILL YOU JOIN THE ", CTRL_SUBJ, "?", CTRL_END
.f2: db "DO YOU EVER PRAY, CHILD?", CTRL_END
.f3: db "IS YOUR SOUL ", CTRL_ADJ, "?", CTRL_END

NounsFarmer:
    db 6
    dw .f0, .f1, .f2, .f3, .f4, .f5
.f0: db "HARVEST", CTRL_END
.f1: db "TRACTOR", CTRL_END
.f2: db "FENCES", CTRL_END
.f3: db "CROWS", CTRL_END
.f4: db "SILO", CTRL_END
.f5: db "SEEDS", CTRL_END
TopicsFarmer:
    db 6
    dw .f0, .f1, .f2, .f3, .f4, .f5
.f0: db "THE ", CTRL_SUBJ, " WON'T WAIT.", CTRL_END
.f1: db "CROWS GOT THE ", CTRL_NOUN, ".", CTRL_END
.f2: db "THE ", CTRL_SUBJ, " LOOKS ", CTRL_ADJ, ".", CTRL_END
.f3: db "RAIN SOON. I CAN TELL.", CTRL_END
.f4: db "DIRT DON'T LIE.", CTRL_END
.f5: db "THE ", CTRL_SUBJ, " FEEDS US ALL.", CTRL_END
QuestsFarmer:
    db 4
    dw .f0, .f1, .f2, .f3
.f0: db "RAIN COMING, YOU THINK?", CTRL_END
.f1: db "EVER WORKED A ", CTRL_NOUN, "?", CTRL_END
.f2: db "YOU EAT TODAY?", CTRL_END
.f3: db "SEEN CROWS ON THE ", CTRL_SUBJ, "?", CTRL_END
