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

DEF MOVE_COOLDOWN  EQU 6           ; frames between grid steps

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

ENDC
