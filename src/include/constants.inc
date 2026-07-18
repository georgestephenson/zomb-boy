; =============================================================================
; constants.inc — shared game constants (EQU only; safe to include anywhere).
; =============================================================================
IF !DEF(CONSTANTS_INC)
DEF CONSTANTS_INC EQU 1

; --- World generation -------------------------------------------------------
DEF WORLD_SEED     EQU $A5
DEF WATER_THRESH   EQU 34          ; coarse-hash < this -> water (~13%)

; --- Tile type ids (also the VRAM tile index for background tiles) ----------
DEF TILE_GRASS     EQU 0
DEF TILE_BRUSH     EQU 1
DEF TILE_TREE      EQU 2           ; solid
DEF TILE_WALL      EQU 3           ; solid
DEF TILE_WATER     EQU 4           ; solid
DEF TILE_ROAD      EQU 5
; Player OBJ tiles: down A/B = 6/7, up = 8/9, side = 10/11
DEF TILE_PLAYER_BASE EQU 6

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

; Tiles pushed to VRAM per VBlank. A strip's blit is spread across several
; VBlanks because the incoming edge only slides fully into view over STEP_TOTAL
; frames — keeps VBlank work well under budget (no VRAM corruption on hardware).
DEF BLIT_CHUNK     EQU 6

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

; --- Sprite tiles (continue after the player's 6..11) -----------------------
DEF TILE_ZOMBIE_BASE EQU 12        ; down A/B=12/13, up=14/15, side=16/17
DEF TILE_BUBBLE    EQU 18          ; the "!" alert bubble

; --- OAM slot assignment (shadow OAM entry index) ---------------------------
DEF OAM_PLAYER     EQU 0
DEF OAM_ZOMBIE0    EQU 1           ; zombies use slots 1..MAX_ZOMBIES
DEF OAM_BUBBLE     EQU 9           ; the alert bubble

; --- Game mode --------------------------------------------------------------
DEF MODE_OVERWORLD EQU 0
DEF MODE_ALERT     EQU 1           ; "!" showing, about to battle

ENDC
