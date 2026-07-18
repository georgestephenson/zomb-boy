; =============================================================================
; constants.inc — shared game constants (EQU only; safe to include anywhere).
; =============================================================================
IF !DEF(CONSTANTS_INC)
DEF CONSTANTS_INC EQU 1

; --- World generation -------------------------------------------------------
DEF WORLD_SEED     EQU $A5

; Biome ids (a coarse, domain-warped field selects one per region; each biome
; sets which features appear and how dense). Keep in lockstep with the biome()
; thresholds in worldgen_model.py.
DEF BIOME_CITY     EQU 0
DEF BIOME_PLAINS   EQU 1
DEF BIOME_FOREST   EQU 2
DEF BIOME_MARSH    EQU 3

; Per-biome water cutoffs on the shared (octaveA+octaveB)>>1 field (lower =
; wetter). Marsh is mostly water; plains/forest get only rare small ponds.
DEF WATER_MARSH    EQU 116
DEF WATER_FOREST   EQU 24
DEF WATER_PLAINS   EQU 20
; Per-biome 2x2-tree anchor cutoffs (hash >= this -> a tree). Lower = denser.
DEF TREE_FOREST    EQU 176
DEF TREE_MARSH     EQU 236
DEF TREE_PLAINS    EQU 248

; --- Tile type ids (also the VRAM tile index for background tiles) ----------
DEF TILE_GRASS     EQU 0
DEF TILE_BRUSH     EQU 1
DEF TILE_FLOWER    EQU 2
DEF TILE_DIRT      EQU 3
DEF TILE_WATER     EQU 4           ; solid
DEF TILE_ROAD      EQU 5
DEF TILE_WALL      EQU 6           ; solid
DEF TILE_FLOOR     EQU 7           ; house interior
DEF TILE_DOOR      EQU 8           ; house doorway (passable)
DEF TILE_MARSH     EQU 9           ; marsh ground
DEF TILE_TREE_TL   EQU 10          ; 2x2 tree quadrants (all solid)
DEF TILE_TREE_TR   EQU 11
DEF TILE_TREE_BL   EQU 12
DEF TILE_TREE_BR   EQU 13
; Player OBJ tiles: down A/B = 14/15, up = 16/17, side = 18/19
DEF TILE_PLAYER_BASE EQU 14

; --- Screen / camera --------------------------------------------------------
DEF VIEW_COLS      EQU 20          ; 160/8 visible tile columns
DEF VIEW_ROWS      EQU 18          ; 144/8 visible tile rows
DEF PLAYER_COL     EQU 9           ; player's fixed on-screen tile column
DEF PLAYER_ROW     EQU 9           ; ... and row (world scrolls under it)
DEF SPR_X          EQU PLAYER_COL * 8 + 8    ; OAM X (8px sprite offset)
DEF SPR_Y          EQU PLAYER_ROW * 8 + 16   ; OAM Y (16px sprite offset)

; Smooth stepping: a tile is walked over STEP_TOTAL sub-units (2 per pixel, so
; a 8px tile = 16 units), advancing STEP_SPEED per frame. 16 units / 1 = 16
; frames per tile -> a deliberate, weighty pace. The camera interpolates so the
; world slides smoothly rather than snapping a whole tile at a time.
DEF STEP_TOTAL     EQU 16
DEF STEP_SPEED     EQU 1
DEF TURN_DELAY     EQU 7           ; frames to "turn in place" before walking

; Tiles pushed to VRAM per VBlank. With the CPU in double-speed mode the VBlank
; window holds twice as many cycles, so a whole strip (<= VIEW_COLS = 20 quads,
; ~670 cycles over two passes) now fits in a single VBlank alongside OAM DMA.
; Blitting the full strip at once means the incoming edge lands the same frame
; the scroll updates (no seam) and no partial-strip state is ever visible.
DEF BLIT_CHUNK     EQU 20

; Player movement state (wPlayerState)
DEF PSTATE_IDLE    EQU 0
DEF PSTATE_TURN    EQU 1
DEF PSTATE_WALK    EQU 2

; --- Joypad bits produced by ReadInput (1 = pressed) ------------------------
DEF PAD_RIGHT      EQU %00000001
DEF PAD_LEFT       EQU %00000010
DEF PAD_UP         EQU %00000100
DEF PAD_DOWN       EQU %00001000
DEF PAD_A          EQU %00010000
DEF PAD_B          EQU %00100000
DEF PAD_SELECT     EQU %01000000
DEF PAD_START      EQU %10000000

; --- Movement direction codes (wMoveDir) ------------------------------------
DEF DIR_NONE       EQU 0
DEF DIR_RIGHT      EQU 1
DEF DIR_LEFT       EQU 2
DEF DIR_DOWN       EQU 3
DEF DIR_UP         EQU 4

; --- Entities (zombies) -----------------------------------------------------
DEF MAX_ZOMBIES    EQU 8
DEF ENT_SIZE       EQU 16          ; 16-byte stride (power of 2 -> cheap index)
; Entity field offsets within the 16-byte struct
DEF EO_ACTIVE      EQU 0
DEF EO_WXLO        EQU 1           ; world tile X (16-bit LE)
DEF EO_WXHI        EQU 2
DEF EO_WYLO        EQU 3           ; world tile Y (16-bit LE)
DEF EO_WYHI        EQU 4
DEF EO_FACING      EQU 5           ; EFACE_* (which way it looks / sees)
DEF EO_DIR         EQU 6           ; current move dir (EFACE_* or EDIR_IDLE)
DEF EO_STEPS       EQU 7           ; steps left in the current run
DEF EO_TIMER       EQU 8           ; frames until the next step
DEF EO_FRAME       EQU 9           ; walk-cycle frame (0/1)
DEF EO_ALERT       EQU 10          ; >0 = alerted, counting down to battle
DEF EO_SLIDE       EQU 11          ; sub-tile slide remaining (0..16, half-px)
DEF EO_SLIDEDIR    EQU 12          ; EFACE_* the slide is moving along

; Facing / direction enum (0..3); idle marker for EO_DIR
DEF EFACE_DOWN     EQU 0
DEF EFACE_UP       EQU 1
DEF EFACE_LEFT     EQU 2
DEF EFACE_RIGHT    EQU 3
DEF EDIR_IDLE      EQU $FF

DEF ZOMBIE_STEP_DELAY EQU 16       ; frames per shuffle step (also the smooth
                                   ; interpolation window; timer>>1 = 0..8 px)
DEF ZOMBIE_RUN_MIN EQU 1           ; min steps in a run
DEF ZOMBIE_RUN_MAX EQU 5           ; max steps in a run
DEF SIGHT_RANGE    EQU 5           ; tiles a zombie can see straight ahead
DEF ALERT_FRAMES   EQU 45          ; how long the "!" shows before the battle

; --- Sprite tiles (continue after the player's 14..19) ----------------------
DEF TILE_ZOMBIE_BASE EQU 20        ; down A/B=20/21, up=22/23, side=24/25
DEF TILE_BUBBLE    EQU 26          ; the "!" alert bubble

; --- OAM slot assignment (shadow OAM entry index) ---------------------------
DEF OAM_PLAYER     EQU 0
DEF OAM_ZOMBIE0    EQU 1           ; zombies use slots 1..MAX_ZOMBIES
DEF OAM_BUBBLE     EQU 9           ; the alert bubble

; --- Game mode --------------------------------------------------------------
DEF MODE_OVERWORLD EQU 0
DEF MODE_ALERT     EQU 1           ; "!" showing, about to battle
DEF MODE_TALK      EQU 2           ; survivor dialogue screen (talk.asm)

; --- Survivor NPCs (docs/design/05) -----------------------------------------
DEF MAX_NPCS       EQU 10          ; one of each persona, placed near the start
; Extra entity-struct fields (offsets 13..15 are unused by zombies)
DEF EO_PERSONA     EQU 13          ; PERSONA_* id
DEF EO_AFFIN      EQU 14           ; affinity 0..255 (128 = neutral), saturating
DEF EO_MET        EQU 15           ; nonzero once you've talked to them —
                                   ; return visits greet differently

DEF OAM_NPC0       EQU 10          ; NPCs use OAM slots 10..10+MAX_NPCS-1

; Survivor OBJ tiles (static: no walk cycle) + the menu cursor
DEF TILE_SURV_DOWN EQU 27          ; after the bubble (26)
DEF TILE_SURV_UP   EQU 28
DEF TILE_SURV_SIDE EQU 29          ; right profile; X-flip for left
DEF TILE_CURSOR    EQU 30

; Personas: index into dialogue_data.asm's PersonaTable
DEF PERSONA_POLICE   EQU 0
DEF PERSONA_SCIENTIST EQU 1
DEF PERSONA_CHEER    EQU 2
DEF PERSONA_MAID     EQU 3
DEF PERSONA_BIZ      EQU 4
DEF PERSONA_PREPPER  EQU 5
DEF PERSONA_MEDIC    EQU 6
DEF PERSONA_RAIDER   EQU 7
DEF PERSONA_PREACHER EQU 8
DEF PERSONA_FARMER   EQU 9
DEF PERSONA_COUNT    EQU 10
; Persona record layout (see dialogue_data.asm)
DEF PERSONA_SIZE   EQU 12
DEF PO_NAME        EQU 0           ; dw -> 0-terminated name string
DEF PO_TRAITS      EQU 2           ; 4 signed bytes: T0..T3 (see below)
DEF PO_NOUNS       EQU 6           ; dw -> noun bank
DEF PO_TOPICS      EQU 8           ; dw -> topic-template bank
DEF PO_PAL         EQU 10          ; OBJ palette (3..7; tints are shared —
                                   ; only 5 hardware palettes are free)
; Trait axes (signed -60..+60; + = the second-named pole):
;   T0 WARY<->TRUSTING  T1 GRIM<->HOPEFUL  T2 SELFISH<->GENEROUS  T3 JOKING<->SERIOUS
; NOTE: |dot(push, traits)| over any tone must stay <= 127 (8-bit math);
; test/model/dialogue_bounds.py checks this against the built ROM.

; --- Dialogue: reply tones, buckets, thresholds ------------------------------
; The tone POOL covers every trait axis in both directions; each menu offers a
; random 4 of these (BuildMenu guarantees at least one non-negative option).
DEF TONE_NICE      EQU 0
DEF TONE_FLIRT     EQU 1
DEF TONE_JOKE      EQU 2
DEF TONE_RUDE      EQU 3
DEF TONE_GUARDED   EQU 4
DEF TONE_CHEER     EQU 5
DEF TONE_GRIM      EQU 6
DEF TONE_DEMAND    EQU 7
DEF TONE_COUNT     EQU 8           ; power of 2: BuildMenu masks Rand with -1
DEF TONE_SIZE      EQU 6           ; tone record: 4 push bytes + base + pad
DEF MENU_TRIES     EQU 8           ; redraw budget for the non-negative rule

; Reaction buckets (index the react banks), from the per-round delta
DEF RB_LOVED       EQU 0           ; delta >= +6
DEF RB_LIKED       EQU 1           ; delta >= +1
DEF RB_MEH         EQU 2           ; delta == 0
DEF RB_DISLIKED    EQU 3           ; delta >= -5
DEF RB_HATED       EQU 4           ; delta <  -5

; Mood buckets (index opener/adjective banks), from running affinity
DEF MOOD_HOSTILE   EQU 0           ; affinity <  96
DEF MOOD_NEUTRAL   EQU 1           ; affinity < 160
DEF MOOD_WARM      EQU 2           ; affinity >= 160

DEF AFFIN_START    EQU 128
DEF AFFIN_HOSTILE  EQU 96
DEF AFFIN_WARM     EQU 160
; Conversation outcome thresholds (final affinity after TALK_ROUNDS replies)
DEF AFFIN_REWARD   EQU 148
DEF AFFIN_FIGHT    EQU 108
DEF TALK_ROUNDS    EQU 3

DEF OUTCOME_FIGHT  EQU 0
DEF OUTCOME_PART   EQU 1           ; "flight": neutral parting
DEF OUTCOME_REWARD EQU 2

; --- Talk screen (SCRN1) layout ---------------------------------------------
; Text area: 3 rows x 18 cols inside the bottom box (BG rows 12/14/16, col 1).
DEF TALK_COLS      EQU 18
DEF TALK_ROWS      EQU 3
DEF TALK_TEXT_MAX  EQU TALK_COLS * TALK_ROWS   ; 54-byte compose buffer
DEF TXT_COL0       EQU 1
DEF TXT_ROW0       EQU 12          ; text rows at 12/14/16 (stride 2 for air)
DEF BOX_ROW_TOP    EQU 10          ; solid border rows of the text box
                                   ; (row 11 stays blank: air above the text)
DEF BOX_ROW_BOT    EQU 17
DEF NAME_COL       EQU 1           ; name plate position
DEF NAME_ROW       EQU 1
DEF TALK_NPC_X     EQU 84          ; OAM position of the NPC on the talk screen
DEF TALK_NPC_Y     EQU 48
DEF TALK_ARROW_COL EQU 18          ; "press A" arrow cell (rightmost, last row)
; Menu: 2x2 grid inside the text area. Grid columns 1/9 hold the labels
; (grid col 0/8 = the cursor cell); grid rows are text rows 0 and 1.
DEF MENU_LBL_COL0  EQU 1
DEF MENU_LBL_COL1  EQU 9
DEF WORD_MAX       EQU 15          ; compose word scratch hard limit

; Talk state machine
DEF TS_REVEAL      EQU 0           ; typewriter running
DEF TS_WAIT       EQU 1            ; text done, waiting for A
DEF TS_MENU       EQU 2            ; 4-tone menu up
DEF TPH_GREET      EQU 0
DEF TPH_REACT      EQU 1
DEF TPH_OUTCOME    EQU 2
DEF TPH_PROMPT     EQU 3           ; the NPC's fresh line opening rounds 2+
DEF REVEAL_SLOW    EQU 2           ; cells revealed per frame (typewriter)
DEF REVEAL_FAST    EQU 12          ; menu draw / A-skip speed (must stay below
                                   ; TALKQ_CAP with room for an arrow write)
DEF TALKQ_CAP      EQU 16          ; VRAM write queue entries (3 bytes each)

; --- Font (BG tiles from id 128 = $8800; expanded from 1bpp at boot) ---------
DEF FONT_BASE      EQU 128
; Glyph order: space, A-Z, 0-9, . , ! ? ' -  then icons (below)
DEF TILE_FACE_HAPPY EQU FONT_BASE + 43
DEF TILE_FACE_NEUT  EQU FONT_BASE + 44
DEF TILE_FACE_MAD   EQU FONT_BASE + 45
DEF TILE_UIBOX      EQU FONT_BASE + 46   ; solid border tile
DEF TILE_UIARROW    EQU FONT_BASE + 47   ; "press A" indicator
DEF FONT_GLYPHS     EQU 48

; Dialogue string control codes (must stay below FONT_BASE; no glyph maps here)
DEF CTRL_END       EQU 0
DEF CTRL_NOUN      EQU 1           ; expand a random persona-noun into the word
DEF CTRL_ADJ       EQU 2           ; expand a mood-adjective likewise
DEF CTRL_SUBJ      EQU 3           ; expand the conversation's SUBJECT noun —
                                   ; picked once per conversation, so the NPC
                                   ; keeps talking about the same thing

; Trait-tinted adjectives: |T1| above this shifts the adjective bank one mood
; step (grim personas speak bleaker, hopeful ones warmer, at equal affinity).
DEF TINT_THRESH    EQU 17

DEF PAL_BG_UI      EQU 4           ; BG palette for the whole talk screen
                                   ; (0-3 belong to the biome terrain)

ENDC
