; =============================================================================
; constants.inc — shared game constants (EQU only; safe to include anywhere).
; =============================================================================
IF !DEF(CONSTANTS_INC)
DEF CONSTANTS_INC EQU 1

; --- World generation -------------------------------------------------------
; The "classic" seed. The actual seed lives in hWorldSeed, captured on the
; title screen from the START-press timing; SELECT+START forces this value so
; tests and the reference model stay deterministic (worldgen_model.py default).
DEF WORLD_SEED     EQU $A5

; Biome ids (a coarse, domain-warped field selects one per region; each biome
; sets which features appear and how dense). Keep in lockstep with the biome()
; thresholds in worldgen_model.py.
DEF BIOME_CITY     EQU 0
DEF BIOME_PLAINS   EQU 1
DEF BIOME_FOREST   EQU 2
DEF BIOME_MARSH    EQU 3
; Expansion biomes (each carves a band out of the same domain-warped field;
; keep the thresholds in lockstep with CalcBiome / worldgen_model.py:biome()).
DEF BIOME_RUINS     EQU 4          ; broken-up city: cracked roads + rubble
DEF BIOME_FARM      EQU 5          ; regular fenced fields of tall wheat
DEF BIOME_JUNGLE    EQU 6          ; dense trees + heavy undergrowth
DEF BIOME_GRAVEYARD EQU 7          ; headstones + a church, extra zombies
DEF BIOME_DESERT    EQU 8          ; sand + cactus
DEF BIOME_MOUNTAINS EQU 9          ; rocky ground + boulders
DEF BIOME_TUNDRA    EQU 10         ; snow + frozen ponds (ice)
DEF BIOME_COUNT     EQU 11

; Per-biome water cutoffs on the shared (octaveA+octaveB)>>1 field (lower =
; wetter). Marsh is mostly water; plains/forest get only rare small ponds.
DEF WATER_MARSH    EQU 116
DEF WATER_FOREST   EQU 24
DEF WATER_PLAINS   EQU 20
DEF WATER_TUNDRA   EQU 20          ; frozen ponds (rendered as solid ICE, not water)
; Per-biome 2x2-tree anchor cutoffs (hash >= this -> a tree). Lower = denser.
DEF TREE_FOREST    EQU 176
DEF TREE_MARSH     EQU 236
DEF TREE_PLAINS    EQU 248
DEF TREE_JUNGLE    EQU 176         ; as dense as forest, but far brushier ground
DEF TREE_GRAVE     EQU 250         ; the odd dead tree among the stones
DEF TREE_TUNDRA    EQU 246         ; sparse frozen pines
DEF TREE_MTN       EQU 240         ; sparse hardy pines on the slopes

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
; Expansion-biome BG terrain tiles. These live at ids 57..63 (NOT 14..) because
; 14..56 are OBJ/UI tiles; the new art is appended to the Tiles table after the
; splash sprite so LoadTiles streams it into the free VRAM gap between the UI
; tiles (..56) and the portrait block (64+). PassTable/AttrTable (world.asm)
; carry entries for these ids; the boot-hygiene BG-tile poison test allows them.
DEF TILE_SAND      EQU 57          ; desert ground (passable)
DEF TILE_CACTUS    EQU 58          ; desert (solid)
DEF TILE_SNOW      EQU 59          ; tundra ground (passable)
DEF TILE_ICE       EQU 60          ; tundra frozen pond (solid; slip is LATER)
DEF TILE_GRAVE     EQU 61          ; graveyard headstone (solid)
DEF TILE_WHEAT     EQU 62          ; farm tall wheat (passable)
DEF TILE_FENCE     EQU 63          ; farm fence (solid)
; Player OBJ tiles: down A/B = 14/15, up = 16/17, side = 18/19
DEF TILE_PLAYER_BASE EQU 14
; Swimming: only the head + shoulders show above the waterline, so these are
; single-frame per direction (bottom rows transparent -> the water BG shows
; through). Ids 53..56 sit in the gap between the UI tiles (..52) and the
; portrait block (64+), so nothing downstream shifts.
DEF TILE_SWIM_BASE EQU 53          ; down = 53, up = 54, side = 55 (X-flip left)
DEF TILE_SPLASH    EQU 56          ; the enter/leave-water splash burst
DEF SWIM_SPLASH_FRAMES EQU 18      ; how long the splash sprite lingers

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
DEF ALERT_FRAMES   EQU 30          ; how long the "!" holds before the zombie charges
DEF CHASE_MAX_FRAMES EQU 200       ; watchdog: force the battle if the charge stalls
                                   ; (e.g. an entity parked on the terrain-clear line)

; --- Dynamic spawning / despawning (entity.asm UpdateSpawns) -----------------
; Zombies and survivors are spawned in a ring just OUTSIDE the visible window as
; the player explores, and destroyed once they stray too far behind. Spawn
; positions come from the dynamic LFSR (Rand), NOT the terrain hash, so every
; encounter is fresh — walking back over the same ground never reproduces the
; same one — and the fixed-size pools keep the count (and memory) bounded. A
; just-spawned entity is always > SIGHT_RANGE away, so it can never alert the
; instant it appears. Distances are Chebyshev: max(|dx|, |dy|) in tiles.
DEF ENT_SPAWN_DIST    EQU 12       ; ring radius of a fresh spawn (just off-screen)
DEF ENT_CULL_DIST     EQU 15       ; despawn once this far from the player
DEF ZOMB_SPAWN_PERIOD EQU 26       ; frames between zombie respawn attempts
DEF ZOMB_SPAWN_TARGET EQU 6        ; keep about this many zombies around you (pool
                                   ; cap stays MAX_ZOMBIES; this is the refill goal)
DEF NPC_SPAWN_PERIOD  EQU 150      ; survivors respawn slowly — they're rare finds
DEF NPC_SPAWN_TARGET  EQU 2        ; ... and only a couple linger around you (their
                                   ; rewards are big, so they should be hard to find)

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
DEF OAM_SPLASH     EQU 20          ; the water splash (first free slot after NPCs)
DEF OAM_CAR        EQU 21          ; the car's 2x2 world sprite (car.asm): four OBJ
                                   ; slots 21..24 (TL, TR, BL, BR), parked or driven

; The menu cursor (survivor world sprites are per-persona now: TILE_PSURV_BASE,
; defined below with the font ids since they load after the font glyphs)
DEF TILE_CURSOR    EQU 27          ; after the bubble (26)

; Portrait frame BG tiles (extend the Tiles table after the cursor; gfx.asm).
; Only used on the talk screen, around the 56x56 photo.
DEF TILE_FRAME_TL  EQU 28          ; corners
DEF TILE_FRAME_TR  EQU 29
DEF TILE_FRAME_BL  EQU 30
DEF TILE_FRAME_BR  EQU 31
DEF TILE_FRAME_T   EQU 32          ; edges
DEF TILE_FRAME_B   EQU 33
DEF TILE_FRAME_L   EQU 34
DEF TILE_FRAME_R   EQU 35

; Affinity meter bar cells (also in the Tiles table): a gauge segment with grey
; top/bottom rails and the left N of 8 columns filled with ink. TILE_BAR_BASE+n
; = n columns filled (n = 0..8), so an 8-cell bar shows affinity to the pixel.
DEF TILE_BAR_BASE  EQU 36           ; ids 36..44 (fill 0..8 columns)

; UI panel frame (also in the Tiles table): a light rounded window border for the
; status card and dialogue box, so they read as framed panels not solid blocks.
DEF TILE_PANEL_TL  EQU 45           ; corners
DEF TILE_PANEL_TR  EQU 46
DEF TILE_PANEL_BL  EQU 47
DEF TILE_PANEL_BR  EQU 48
DEF TILE_PANEL_T   EQU 49           ; edges
DEF TILE_PANEL_B   EQU 50
DEF TILE_PANEL_L   EQU 51
DEF TILE_PANEL_R   EQU 52

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
DEF PERSONA_SIZE   EQU 16          ; power of 2: PersonaPtr is a single swap
DEF PO_NAME        EQU 0           ; dw -> 0-terminated name string
DEF PO_TRAITS      EQU 2           ; 4 signed bytes: T0..T3 (see below)
DEF PO_NOUNS       EQU 6           ; dw -> noun bank
DEF PO_TOPICS      EQU 8           ; dw -> topic-template bank
DEF PO_PAL         EQU 10          ; OBJ palette (3..7; tints are shared —
                                   ; only 5 hardware palettes are free)
DEF PO_QUESTS      EQU 12          ; dw -> question bank (the turn's last beat)
DEF PO_CTX         EQU 14          ; dw -> table of 8 context banks (CTX_* id
                                   ; -> this persona's IN-VOICE observations)
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
DEF NAME_COL       EQU 1           ; name plate position — top-left corner, so
DEF NAME_ROW       EQU 0            ; a long name can't collide with the framed
                                   ; portrait on the right (rows 1..9)

; Survivor status card: a boxed panel under the name (left of the portrait) that
; spells out the relationship — a mood face + word, and an 8-cell affinity meter.
DEF CARD_COL_L     EQU 0           ; box border columns (inner content = 1..8)
DEF CARD_COL_R     EQU 9
DEF CARD_ROW_TOP   EQU 1           ; box border rows (inner content = 2..8)
DEF CARD_ROW_BOT   EQU 9
DEF STAT_MOOD_ROW  EQU 2           ; "MOOD" label + face
DEF STAT_FACE_COL  EQU 6
DEF STAT_DESC_ROW  EQU 3           ; the mood word (8 cells, cols 1..8)
DEF STAT_BOND_ROW  EQU 5           ; "BOND" label
DEF STAT_BAR_ROW   EQU 6           ; the affinity meter (8 cells, cols 1..8)
DEF STAT_INNER_COL EQU 1
; Display-only relationship descriptors (finer than the 3 MOOD_* buckets that
; drive dialogue). Thresholds on affinity; words are padded to 8 chars.
DEF DESC_WARY_MIN  EQU 128
DEF DESC_WARM_MIN  EQU 200

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
DEF TPH_OBS        EQU 4           ; optional mid-turn remark about the world /
                                   ; the player's visible state (dialogue.asm
                                   ; ComposeObservation)
DEF TPH_QUEST      EQU 5           ; the question that hands you the menu —
                                   ; every NPC turn ends by asking something
DEF REVEAL_SLOW    EQU 2           ; cells revealed per frame (typewriter)
DEF REVEAL_FAST    EQU 12          ; menu draw / A-skip speed (must stay below
                                   ; TALKQ_CAP with room for an arrow write)
DEF TALKQ_CAP      EQU 32          ; VRAM write queue entries (3 bytes each) —
                                   ; holds a full status-card redraw (face +
                                   ; 8-cell word + 8-cell meter) in one frame

; --- Font (BG tiles from id 128 = $8800; expanded from 1bpp at boot) ---------
DEF FONT_BASE      EQU 128
; Glyph order: space, A-Z, 0-9, . , ! ? ' -  then icons (below)
DEF TILE_FACE_HAPPY EQU FONT_BASE + 43
DEF TILE_FACE_NEUT  EQU FONT_BASE + 44
DEF TILE_FACE_MAD   EQU FONT_BASE + 45
DEF TILE_UIBOX      EQU FONT_BASE + 46   ; solid border tile
DEF TILE_UIARROW    EQU FONT_BASE + 47   ; "press A" indicator
DEF TILE_HUD_COLON  EQU FONT_BASE + 48   ; clock separator (no charmap entry:
DEF TILE_HUD_HP     EQU FONT_BASE + 49   ;  the HUD composes tile ids at
DEF TILE_HUD_FOOD   EQU FONT_BASE + 50   ;  runtime, not from strings)
DEF TILE_HUD_ENERGY EQU FONT_BASE + 51
DEF TILE_HUD_FUEL   EQU FONT_BASE + 52   ; gas pump (shown in place of energy while driving)
DEF FONT_GLYPHS     EQU 53
DEF TILE_DIGIT0     EQU FONT_BASE + 27   ; '0' (digits are contiguous 0-9)

; Per-persona survivor world sprites (gfx.asm PersonaTiles, loaded right after
; the font): 3 tiles per persona — down, up, side (X-flip for left). Ids
; 181..210; OBJs can reach them (the OAM tile byte spans all of $8000-$8FFF).
DEF TILE_PSURV_BASE EQU FONT_BASE + FONT_GLYPHS

; Dialogue string control codes (must stay below FONT_BASE; no glyph maps here)
DEF CTRL_END       EQU 0
DEF CTRL_NOUN      EQU 1           ; expand a random persona-noun into the word
DEF CTRL_ADJ       EQU 2           ; expand a mood-adjective likewise
DEF CTRL_SUBJ      EQU 3           ; expand the conversation's SUBJECT noun —
                                   ; picked once per conversation, so the NPC
                                   ; keeps talking about the same thing
DEF CTRL_ITEM      EQU 4           ; expand the name of the player's equipped
                                   ; weapon ("IS THAT A PISTOL?") — the NPC
                                   ; reads your actual inventory

; --- Context observations (dialogue.asm PickContext / ComposeObservation) ----
; The NPC may open a mid-turn remark keyed to LIVE game state: your meters,
; your equipment, the in-game clock. Ids index CtxBanks (dialogue_data.asm);
; the priority scan runs in this order, and wCtxUsed (a bitmask of ids) stops
; the same remark firing twice in one conversation.
DEF CTX_HURT       EQU 0           ; wHP     < CTX_LOW_METER
DEF CTX_HUNGRY     EQU 1           ; wFood   < CTX_LOW_METER
DEF CTX_TIRED      EQU 2           ; wEnergy < CTX_LOW_METER
DEF CTX_WEAPON     EQU 3           ; a weapon is equipped (CTRL_ITEM names it)
DEF CTX_NIGHT      EQU 4           ; wClockH >= 22 or < 5
DEF CTX_MORNING    EQU 5           ; wClockH 5..11
DEF CTX_DUSK       EQU 6           ; wClockH 18..21
DEF CTX_DAY        EQU 7           ; wClockH 12..17
DEF CTX_COUNT      EQU 8
DEF CTX_NONE       EQU $FF         ; PickContext: nothing fresh to remark on
DEF CTX_LOW_METER  EQU 40          ; a meter under this is worth a comment

; --- HUD / survival meters (docs/design/03; v0: visible + draining, non-lethal)
; The HUD is the hardware window over the BOTTOM 8 px (the window always runs
; to the screen's bottom-right corner), sourced from SCRN1 row 0 — free
; because the talk screen's layout starts at row 1. See hud.asm.
DEF HUD_COLS       EQU VIEW_COLS   ; one full text row
DEF METER_MAX      EQU 100         ; meters are 0..100, saturating (no wrap)
DEF CLOCK_MINUTE_FRAMES EQU 10     ; frames per in-game minute (day = 4 real min)
DEF CLOCK_START_HOUR EQU 8         ; the run starts in the morning
; Drain periods in in-game minutes. POWERS OF 2 ONLY: the tick masks a
; free-running minute counter with (N-1).
DEF FOOD_DRAIN_MINS   EQU 8        ; food 100 -> 0 in ~13 in-game hours
DEF ENERGY_DRAIN_MINS EQU 16       ; energy drains at half that rate

; HUD toast: on a pickup we briefly overwrite the status row with a short message
; ("ATE APPLE", "GOT PISTOL") for this many frames, WITHOUT pausing the game, then
; the meters return. ComposeHUD yields while a toast is up; TickNotice counts down.
DEF NOTICE_FRAMES  EQU 90          ; ~1.5s at 60 fps

; Trait-tinted adjectives: |T1| above this shifts the adjective bank one mood
; step (grim personas speak bleaker, hopeful ones warmer, at equal affinity).
DEF TINT_THRESH    EQU 17

; --- World animation (anim.asm) ---------------------------------------------
; Shared-tile-art swaps that make the world feel alive. The sway/rustle patterns
; hold each sub-frame for (1 << *_LOG) frames — the index is timer >> *_LOG — and
; *_DUR is sized so the whole pattern plays exactly once: DUR = PAT_LEN << LOG.
; *_LOG is the single speed knob: raise it to make a motion slower (LOG 4 = 16
; frames per sub-frame, a slow, gentle sway; LOG 3 = 8 = twice as fast). Keep each
; *_PAT_LEN in sync with the pattern tables in anim.asm.
DEF WATER_ANIM_FRAMES EQU 22       ; frames between water shimmer sub-frames
DEF BREEZE_PERIOD     EQU 210      ; frames between ambient tree-sway gusts
DEF TREE_SWAY_LOG     EQU 4        ; canopy holds each sway frame 1<<4 = 16 frames
DEF TREE_PAT_LEN      EQU 6        ; TreeSwayPattern length
DEF TREE_SWAY_DUR     EQU TREE_PAT_LEN << TREE_SWAY_LOG   ; 96 — one full sway
DEF BRUSH_RUSTLE_LOG  EQU 4        ; brush holds each rustle frame 16 frames too
DEF BRUSH_PAT_LEN     EQU 5        ; BrushRustlePattern length
DEF BRUSH_RUSTLE_DUR  EQU BRUSH_PAT_LEN << BRUSH_RUSTLE_LOG   ; 80
DEF DOOR_LINGER       EQU 16       ; frames a door stays open after you step off

DEF PAL_BG_UI      EQU 4           ; BG palette for the whole talk screen
                                   ; (0-3 belong to the biome terrain)

; --- Survivor portraits (talk.asm ShowPortrait + generated portrait_data.asm) -
; A 56x56 portrait is a 7x7 BG-tile block on the talk screen (49 tiles is far
; past the 40-OBJ limit, so it can only be background). Its tiles occupy a
; reserved VRAM window clear of terrain/OBJ (0..30) and font (128+); its three
; colour palettes take the free BG slots 5/6/7. Descriptor layout is documented
; in portrait_data.asm and read by ShowPortrait.
DEF PORTRAIT_COLS  EQU 7
DEF PORTRAIT_ROWS  EQU 7
DEF PORTRAIT_NTILES EQU PORTRAIT_COLS * PORTRAIT_ROWS   ; 49
DEF PORTRAIT_TILE_BASE EQU 64      ; first VRAM tile id (64..112, before FONT_BASE)
DEF PORTRAIT_COL0  EQU 12          ; top-left BG cell: photo cols 12..18, rows
DEF PORTRAIT_ROW0  EQU 2           ; 2..8 — a framed photo on the upper right.
                                   ; Its frame ring occupies rows 1..9, cols
                                   ; 11..19; col 10 is the gap to the status card.
DEF PAL_BG_PORTRAIT EQU 5          ; portrait uses BG palettes 5/6/7
DEF NUM_PORTRAIT_PALS EQU 3
DEF PORTRAIT_ATTR_OFF EQU NUM_PORTRAIT_PALS * 8         ; 24: palettes -> attr map
DEF PORTRAIT_TILE_OFF EQU PORTRAIT_ATTR_OFF + PORTRAIT_NTILES  ; 73: -> tile data

; --- Drivable car (car.asm) -------------------------------------------------
; One car spawns near the player start. Board it with A while adjacent and
; facing it; it drives at double speed and burns FUEL (which takes over the
; energy slot in the HUD) instead of the player's energy. Getting out parks the
; car where you stopped and steps the PLAYER onto an adjacent tile.
; The car is a 16x16 (2x2-tile) sprite: 8 world-sprite tiles (ids 211..218)
; appended to PersonaTiles in gfx.asm, so LoadTiles streams them into VRAM right
; after the personas. down/up are left-right symmetric (2 tiles each, X-flip the
; right column); side needs 4 tiles (the whole 16x16 X-flips for left).
DEF TILE_CAR_BASE    EQU TILE_PSURV_BASE + PERSONA_COUNT * 3
DEF TILE_CAR_DOWN_T  EQU TILE_CAR_BASE + 0   ; down: top / bottom half (left tile;
DEF TILE_CAR_DOWN_B  EQU TILE_CAR_BASE + 1   ;   right tile = X-flip of it)
DEF TILE_CAR_UP_T    EQU TILE_CAR_BASE + 2   ; up: top / bottom half (left tile)
DEF TILE_CAR_UP_B    EQU TILE_CAR_BASE + 3
DEF TILE_CAR_SIDE_TL EQU TILE_CAR_BASE + 4   ; side (right profile): the 4 quadrants
DEF TILE_CAR_SIDE_TR EQU TILE_CAR_BASE + 5
DEF TILE_CAR_SIDE_BL EQU TILE_CAR_BASE + 6
DEF TILE_CAR_SIDE_BR EQU TILE_CAR_BASE + 7

; World-loot sprites — 5 tiles appended to PersonaTiles after the car's 8, so
; LoadTiles streams them into VRAM right after the car (ids 219..223).
DEF TILE_LOOT_BASE  EQU TILE_CAR_BASE + 8
DEF TILE_LOOT_APPLE EQU TILE_LOOT_BASE + 0
DEF TILE_LOOT_BEANS EQU TILE_LOOT_BASE + 1
DEF TILE_LOOT_CRATE EQU TILE_LOOT_BASE + 2
DEF TILE_LOOT_POT   EQU TILE_LOOT_BASE + 3
DEF TILE_LOOT_CHEST EQU TILE_LOOT_BASE + 4
; --- World loot (loot.asm): dynamic pickups + breakable containers ----------
; Loot objects reuse the 16-byte entity struct (kind in EO_KIND) and the same
; spawn manager as the entities: they appear in a ring just outside the view,
; biome-flavoured (apples in forest, beans in city), and despawn once far. Food
; is non-solid and grabbed by walking over it OR pressing A facing it; crates,
; pots and chests are SOLID and opened with A while facing them, rolling their
; loot into the bag (or, for a ration pack, straight into the food meter).
DEF LOOT_APPLE     EQU 0            ; forest food: small hunger  (non-solid)
DEF LOOT_BEANS     EQU 1            ; city food:   medium hunger (non-solid)
DEF LOOT_CRATE     EQU 2            ; breakable: somewhat-rare loot (solid)
DEF LOOT_POT       EQU 3            ; breakable: somewhat-rare loot (solid)
DEF LOOT_CHEST     EQU 4            ; treasure:  valuable/rare loot (solid)
DEF LOOT_COUNT     EQU 5
DEF EO_KIND        EQU 5            ; loot kind, in the entity struct's EO_FACING slot
DEF MAX_LOOT       EQU 8            ; pool cap (the memory bound)
DEF LOOT_TARGET    EQU 3            ; keep about this many loot objects around you
DEF LOOT_SPAWN_PERIOD EQU 40        ; frames between loot respawn attempts
; Hunger restored on pickup (added to wFood, saturating at METER_MAX)
DEF APPLE_FOOD     EQU 10           ; small
DEF BEANS_FOOD     EQU 25           ; medium
DEF RATION_FOOD    EQU 50           ; large (ration pack, from a crate/pot)
DEF OAM_LOOT       EQU 25           ; loot OBJ slots 25..25+MAX_LOOT-1 (after the car)

DEF CAR_STEP_SPEED EQU 2           ; step sub-units/frame while driving (2x STEP_SPEED)
; Engine rumble: while driving, the 2x2 car sprite occasionally jitters one pixel
; up/down for a couple of frames — a purely cosmetic OAM-Y wobble (no world/tile
; change, no Rand). A short shudder plays for the first RUMBLE_ON frames of each
; RUMBLE_PERIOD-frame window, then holds still; both counts are frame-locked (a
; free-running frame counter, wCarRumble), so determinism is untouched.
; RUMBLE_PERIOD must be a power of 2 (masked, not divided).
DEF RUMBLE_PERIOD  EQU 64          ; frames per rumble cycle (~1s at 60fps)
DEF RUMBLE_ON      EQU 6           ; frames of shudder at the start of each cycle
DEF CAR_SPAWN_DX   EQU 0           ; FALLBACK spawn offset from the player start (tiles)
DEF CAR_SPAWN_DY   EQU 3
DEF FUEL_START     EQU METER_MAX   ; a full tank at spawn (0..METER_MAX, saturating)
; Car spawn search (InitCar): the car looks for a clear 2x2 spot ON/next to a
; road, away from the start and not inside a house, before falling back to the
; near-player CAR_SPAWN_DX/DY placement. The primary axis lands CAR_MIN_DIST..
; CAR_MIN_DIST+CAR_DIST_MASK tiles out ("not near the start point").
DEF CAR_MIN_DIST    EQU 6          ; nearest a road-spawn can land (Chebyshev)
DEF CAR_DIST_MASK   EQU 15         ; primary-axis spread (magnitude 6..21)
DEF CAR_SPAWN_TRIES EQU 48         ; random anchors tried before the fallback

; --- Start menu (menu.asm, Pokemon-style pause menu) ------------------------
; START in the overworld opens a full-screen menu on SCRN1 (like the talk
; screen). The game is paused: the menu is its own main-loop branch, so the
; survival clock/meters (which only tick in the overworld branch) freeze while
; it's up. B / EXIT closes it; each option opens a sub-screen (B backs out).
DEF MODE_MENU      EQU 3

; Sub-screen ids (wMenuScreen). MSCR_ROOT is the option list; the rest are the
; individual panels. Order of the root list is fixed (see RootLabels).
DEF MSCR_ROOT      EQU 0
DEF MSCR_PARTY     EQU 1
DEF MSCR_EQUIP     EQU 2
DEF MSCR_PICK      EQU 3           ; equip item picker (from EQUIP)
DEF MSCR_BAG       EQU 4
DEF MSCR_STATUS    EQU 5
DEF MSCR_OPTIONS   EQU 6
DEF MSCR_SAVE      EQU 7
DEF ROOT_COUNT     EQU 7           ; PARTY EQUIP BAG STATUS SAVE OPTIONS EXIT
DEF OPT_COUNT      EQU 2           ; OPTIONS rows: MUSIC, SFX (both on/off toggles)

; Menu layout on SCRN1: a full-screen panel; a header on row 1; content from
; MENU_BODY_ROW down. The cursor OBJ sits one column left of a list item.
DEF MENU_HDR_ROW   EQU 1
DEF MENU_BODY_ROW  EQU 3           ; first list/content row
DEF MENU_LIST_COL  EQU 3           ; list items start here (col 2 = cursor cell)
DEF MENU_LIST_ROWS EQU 12          ; visible rows in a scrolling list (rows 3..14)

; --- Party ------------------------------------------------------------------
DEF MAX_PARTY      EQU 4           ; up to four members; slot 0 is the player
DEF EQUIP_SLOTS    EQU 4           ; per member: weapon, weapon, armour, charm
DEF ESLOT_WEAPON1  EQU 0
DEF ESLOT_WEAPON2  EQU 1
DEF ESLOT_ARMOR    EQU 2
DEF ESLOT_ACCESSORY EQU 3

; --- Party levels / experience (items.asm) ----------------------------------
; Every member starts at LEVEL 1 with 0 XP and climbs to MAX_LEVEL. Each level
; costs exponentially more XP than the last (LevelXP cumulative table, indexed
; by level). Battles (LATER) grant XP via AddPlayerXP; RecalcLevel re-derives the
; level from the running XP total. Six stat points scale with the level (a base
; per stat + a per-level growth); they'll drive combat once it lands.
DEF START_LEVEL    EQU 1
DEF MAX_LEVEL      EQU 99
DEF STAT_COUNT     EQU 6
; Stat ids (index StatBase / StatGrow and the STATUS stats page).
DEF STAT_STR       EQU 0           ; Strength  — melee power / melee defence
DEF STAT_DEX       EQU 1           ; Dexterity — ranged weapon power
DEF STAT_END       EQU 2           ; Endurance — number of HP
DEF STAT_IMM       EQU 3           ; Immunity  — defence against zombies
DEF STAT_ACC       EQU 4           ; Accuracy  — hit / critical rate
DEF STAT_SPD       EQU 5           ; Speed     — evasion / turn order

; --- Items / inventory ------------------------------------------------------
; Item type (category). Equip slots accept specific categories; the bag holds
; everything. Ids index the parallel ItemType/ItemName tables (items.asm).
DEF ITYPE_NONE     EQU 0
DEF ITYPE_WEAPON   EQU 1
DEF ITYPE_ARMOR    EQU 2
DEF ITYPE_ACCESSORY EQU 3
DEF ITYPE_CONSUMABLE EQU 4
DEF ITYPE_KEY      EQU 5

DEF ITEM_NONE      EQU 0           ; empty slot / "nothing equipped"
DEF ITEM_BAT       EQU 1
DEF ITEM_PISTOL    EQU 2
DEF ITEM_KNIFE     EQU 3
DEF ITEM_VEST      EQU 4
DEF ITEM_HELMET    EQU 5
DEF ITEM_AMULET    EQU 6
DEF ITEM_WATCH     EQU 7
DEF ITEM_GRENADE   EQU 8
DEF ITEM_MEDKIT    EQU 9
DEF ITEM_KEYCARD   EQU 10
DEF ITEM_COUNT     EQU 11
DEF ITEM_NAME_MAX  EQU 8           ; item names are padded to this; keeps lists
                                   ; aligned and clear of the panel's right border

; Inventory: a bag of up to BAG_MAX stacks, each {item id, count}. 0 = empty.
DEF BAG_MAX        EQU 20
DEF BAG_STACK_MAX  EQU 99          ; per-stack count cap (saturating)

; Menu cursor OBJ (reuses the talk cursor tile + amber OBJ palette 2)
DEF OAM_MENU_CURSOR EQU 0          ; menu clears OAM, so slot 0 is free
DEF OAM_MENU_AVATAR EQU 1          ; the player avatar on the status screen

; --- Music tracks (audio.asm MusicTracks) -----------------------------------
; Each screen/context requests a track id; PlayMusic maps it to a song
; descriptor. There is one real song asset so far (the vendored demo), so EVERY
; slot currently points at it as a PLACEHOLDER — see the big TODO on MusicTracks.
; The ids below are the contract the game code uses; wiring real music is just a
; matter of swapping the table entries (and giving each song its own ROM bank).
DEF TRK_TITLE      EQU 0           ; title screen theme
DEF TRK_WORLD_0    EQU 1           ; overworld: city / ruins (urban)
DEF TRK_WORLD_1    EQU 2           ; overworld: plains / farm (open, pastoral)
DEF TRK_WORLD_2    EQU 3           ; overworld: forest / jungle (green, wild)
DEF TRK_WORLD_3    EQU 4           ; overworld: marsh (wet, uneasy)
DEF TRK_WORLD_4    EQU 5           ; overworld: graveyard (eerie)
DEF TRK_WORLD_5    EQU 6           ; overworld: desert (arid)
DEF TRK_WORLD_6    EQU 7           ; overworld: mountains (high, sparse)
DEF TRK_WORLD_7    EQU 8           ; overworld: tundra (cold)
DEF TRK_WORLD_COUNT EQU 8          ; eight world tracks (one per biome group)
; Per-persona dialogue themes: track = TRK_TALK_0 + persona id (0..PERSONA_COUNT-1)
DEF TRK_TALK_0     EQU TRK_WORLD_0 + TRK_WORLD_COUNT   ; = 9
DEF TRK_COUNT      EQU TRK_TALK_0 + PERSONA_COUNT      ; title + 8 world + N talk

; --- Sound effects (audio.asm SFXTable / PlaySFX) ---------------------------
; Short one-shot blips: each entry is a set of channel-1 (pulse) register
; writes, triggered instantly. The music driver re-owns the channel on its next
; tick, so an SFX is a brief attack over the music (the same channel-borrowing
; trick as PlaySplash). Ids index SFXTable.
DEF SFX_BUMP       EQU 0           ; walked into a wall / solid object (Pokemon-style)
DEF SFX_MOVE       EQU 1           ; menu / dialogue cursor moved
DEF SFX_CONFIRM    EQU 2           ; selected a menu / dialogue option (A)
DEF SFX_CANCEL     EQU 3           ; backed out (B) — reserved, see MenuSFX
DEF SFX_OPEN       EQU 4           ; opened the pause menu
DEF SFX_CLOSE      EQU 5           ; closed the pause menu
DEF SFX_EAT        EQU 6           ; ate a consumable (apple / beans / ration)
DEF SFX_PICKUP     EQU 7           ; collected gear into the bag
DEF SFX_COUNT      EQU 8
; While the player holds a direction into a wall the bump SFX repeats on this
; cadence (frames) instead of every frame; a fresh bump (counter at 0) is instant.
DEF BUMP_COOLDOWN  EQU 20

ENDC
