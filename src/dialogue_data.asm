; =============================================================================
; dialogue_data.asm — the grammar's word banks + persona records (ROMX bank 1;
; the 32K ROM-only cart maps it flat, no banking needed).
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

; BANK[1]: the default-mapped ROMX bank (with the song data, which the linker
; must also place here — bank 2's portraits leave it no room anyway). Code only
; ever banks away from 1 transiently (ShowPortrait), restoring it on return.
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
    dw NameScientist
    db -20, 20, 0, 40          ; guarded, curious-hopeful, serious
    dw NounsScientist
    dw TopicsScientist
    db 4, 0
    dw NameCheer
    db 30, 50, 10, -50         ; trusting, hopeful, joking
    dw NounsCheer
    dw TopicsCheer
    db 5, 0
    dw NameMaid
    db 10, -30, 56, 20         ; weary but deeply generous
    dw NounsMaid
    dw TopicsMaid
    db 6, 0
    dw NameBiz
    db -30, 30, -40, 10        ; bullish, selfish; respects a hard bargain
    dw NounsBiz
    dw TopicsBiz
    db 7, 0
    dw NamePrepper
    db -50, -20, -30, 30       ; paranoid hoarder; approves of suspicion
    dw NounsPrepper
    dw TopicsPrepper
    db 6, 0
    dw NameMedic
    db 30, 40, 50, 10          ; open-hearted healer; hates demands
    dw NounsMedic
    dw TopicsMedic
    db 4, 0
    dw NameRaider
    db -40, -40, -50, -30      ; cruel humour; respects savagery
    dw NounsRaider
    dw TopicsRaider
    db 6, 0
    dw NamePreacher
    db 40, 50, 30, 40          ; fervent hope; scandalised by rudeness
    dw NounsPreacher
    dw TopicsPreacher
    db 3, 0
    dw NameFarmer
    db 20, 10, 40, 30          ; steady, stoic, generous
    dw NounsFarmer
    dw TopicsFarmer
    db 7, 0

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

ToneLabels::
    dw LblNice, LblFlirt, LblJoke, LblRude
    dw LblGuarded, LblCheer, LblGrim, LblDemand
LblNice:    db "NICE", CTRL_END
LblFlirt:   db "FLIRT", CTRL_END
LblJoke:    db "JOKE", CTRL_END
LblRude:    db "RUDE", CTRL_END
LblGuarded: db "GUARDED", CTRL_END
LblCheer:   db "CHEER", CTRL_END
LblGrim:    db "GRIM", CTRL_END
LblDemand:  db "DEMAND", CTRL_END

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
    db 4
    dw .f0, .f1, .f2, .f3
.f0: db "ANYWAY.", CTRL_END
.f1: db "TCH.", CTRL_END
.f2: db "STILL HERE?", CTRL_END
.f3: db "MOVING ON.", CTRL_END
PromptNeutral:
    db 4
    dw .f0, .f1, .f2, .f3
.f0: db "SO.", CTRL_END
.f1: db "ANYWAY.", CTRL_END
.f2: db "YOU KNOW,", CTRL_END
.f3: db "LISTEN.", CTRL_END
PromptWarm:
    db 4
    dw .f0, .f1, .f2, .f3
.f0: db "OH! ALSO,", CTRL_END
.f1: db "AND GET THIS.", CTRL_END
.f2: db "YOU KNOW WHAT?", CTRL_END
.f3: db "BY THE WAY,", CTRL_END

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
    db 3
    dw .f0, .f1, .f2
.f0: db "OH! I LOVE THAT!", CTRL_END
.f1: db "HA! WONDERFUL!", CTRL_END
.f2: db "YES! EXACTLY!", CTRL_END
ReactLiked:
    db 3
    dw .f0, .f1, .f2
.f0: db "HEH. NOT BAD.", CTRL_END
.f1: db "GOOD ANSWER.", CTRL_END
.f2: db "FAIR ENOUGH.", CTRL_END
ReactMeh:
    db 3
    dw .f0, .f1, .f2
.f0: db "HM. OKAY.", CTRL_END
.f1: db "IF YOU SAY SO.", CTRL_END
.f2: db "SURE. ANYWAY.", CTRL_END
ReactDisliked:
    db 3
    dw .f0, .f1, .f2
.f0: db "EXCUSE ME?", CTRL_END
.f1: db "THAT'S NOT FUNNY.", CTRL_END
.f2: db "HMPH.", CTRL_END
ReactHated:
    db 3
    dw .f0, .f1, .f2
.f0: db "HOW DARE YOU!", CTRL_END
.f1: db "WATCH IT, PAL.", CTRL_END
.f2: db "UNBELIEVABLE!", CTRL_END

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
; Per-persona noun banks + topic templates.
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
    db 4
    dw .f0, .f1, .f2, .f3
.f0: db "THE ", CTRL_SUBJ, " IS ", CTRL_ADJ, " TODAY.", CTRL_END
.f1: db "STAY BEHIND THE ", CTRL_SUBJ, ".", CTRL_END
.f2: db "I LOST MY ", CTRL_NOUN, " AGAIN.", CTRL_END
.f3: db "MY ", CTRL_SUBJ, " KEEPS US SAFE.", CTRL_END

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
    db 4
    dw .f0, .f1, .f2, .f3
.f0: db "MY ", CTRL_SUBJ, " LOOKS ", CTRL_ADJ, ".", CTRL_END
.f1: db "THE ", CTRL_SUBJ, " NEEDS A ", CTRL_NOUN, ".", CTRL_END
.f2: db "DON'T TOUCH MY ", CTRL_SUBJ, ".", CTRL_END
.f3: db "SCIENCE IS ", CTRL_ADJ, ".", CTRL_END

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
    db 4
    dw .f0, .f1, .f2, .f3
.f0: db "THE ", CTRL_SUBJ, " IS SO ", CTRL_ADJ, "!", CTRL_END
.f1: db "GIMME A Z-O-M-B!", CTRL_END
.f2: db "MY ", CTRL_SUBJ, " NEEDS ", CTRL_ADJ, " VIBES!", CTRL_END
.f3: db "PRACTICE WAS ", CTRL_ADJ, "!", CTRL_END

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
    db 4
    dw .f0, .f1, .f2, .f3
.f0: db "THE ", CTRL_SUBJ, " WON'T CLEAN ITSELF.", CTRL_END
.f1: db "I JUST POLISHED THE ", CTRL_SUBJ, ".", CTRL_END
.f2: db "SO MUCH ", CTRL_ADJ, " DUST.", CTRL_END
.f3: db "I DUST. I MOP. I ENDURE.", CTRL_END

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
    db 4
    dw .f0, .f1, .f2, .f3
.f0: db "THE ", CTRL_SUBJ, " LOOKS ", CTRL_ADJ, ".", CTRL_END
.f1: db "SYNERGY. THE ", CTRL_SUBJ, ". YES.", CTRL_END
.f2: db "MY ", CTRL_NOUN, " IS OVERDUE.", CTRL_END
.f3: db "BUY LOW. SELL ", CTRL_ADJ, ".", CTRL_END

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
    db 4
    dw .f0, .f1, .f2, .f3
.f0: db "THE ", CTRL_SUBJ, " IS SEALED.", CTRL_END
.f1: db "I COUNTED MY ", CTRL_SUBJ, " TWICE.", CTRL_END
.f2: db "THE END WAS ", CTRL_ADJ, " ANYWAY.", CTRL_END
.f3: db "MY ", CTRL_SUBJ, " OUTLASTS US ALL.", CTRL_END

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
    db 4
    dw .f0, .f1, .f2, .f3
.f0: db "THE ", CTRL_SUBJ, " RAN OUT AGAIN.", CTRL_END
.f1: db "HOLD STILL. THIS LOOKS ", CTRL_ADJ, ".", CTRL_END
.f2: db "I SAVED SIX WITH ONE ", CTRL_SUBJ, ".", CTRL_END
.f3: db "YOUR ", CTRL_NOUN, " READS ", CTRL_ADJ, ".", CTRL_END

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
    db 4
    dw .f0, .f1, .f2, .f3
.f0: db "THIS IS MY ", CTRL_SUBJ, ".", CTRL_END
.f1: db "THE ", CTRL_SUBJ, " LOOKS ", CTRL_ADJ, ".", CTRL_END
.f2: db "PAY THE ", CTRL_NOUN, " OR ELSE.", CTRL_END
.f3: db "NICE ", CTRL_SUBJ, ". SHAME IF IT BROKE.", CTRL_END

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
    db 4
    dw .f0, .f1, .f2, .f3
.f0: db "THE ", CTRL_SUBJ, " NEEDS YOU.", CTRL_END
.f1: db "I PREACH TO THE ", CTRL_SUBJ, ".", CTRL_END
.f2: db "THE END TIMES LOOK ", CTRL_ADJ, ".", CTRL_END
.f3: db "SING! THE ", CTRL_SUBJ, " LISTENS.", CTRL_END

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
    db 4
    dw .f0, .f1, .f2, .f3
.f0: db "THE ", CTRL_SUBJ, " WON'T WAIT.", CTRL_END
.f1: db "CROWS GOT THE ", CTRL_NOUN, ".", CTRL_END
.f2: db "THE ", CTRL_SUBJ, " LOOKS ", CTRL_ADJ, ".", CTRL_END
.f3: db "RAIN SOON. I CAN TELL.", CTRL_END
