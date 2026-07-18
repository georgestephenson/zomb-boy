; =============================================================================
; Zomb Boy — main.asm  (v0.1 vertical slice)
; -----------------------------------------------------------------------------
; A controllable survivor walking a procedurally-generated world:
;   * deterministic tile generator (hash noise) -> grass / brush / tree / wall
;   * grid movement with tile collision + hard world-edge barriers
;   * camera that follows the player, clamped to the world bounds
;
; This is the foundation described in docs/design/02-world-and-exploration.md.
; Infinite chunk streaming, save diffs, and zombies build on top of it next.
;
; Structure note: kept in one file while the slice stabilises; will split into
; src/ modules (input.asm, world.asm, player.asm, ...) once it's solid.
; =============================================================================

INCLUDE "hardware.inc"

; -----------------------------------------------------------------------------
; Game constants
; -----------------------------------------------------------------------------
DEF WORLD_SEED      EQU $A5        ; fixed seed for v0 (later: chosen per save)

DEF WORLD_W_TILES   EQU 32         ; world is one 32x32 tile arena for now
DEF WORLD_H_TILES   EQU 32         ; (256x256 px). Streaming makes this endless.
DEF TILE_PX         EQU 8

; Tile type ids — also the VRAM tile indices for the background.
DEF TILE_GRASS      EQU 0
DEF TILE_BRUSH      EQU 1
DEF TILE_TREE       EQU 2          ; solid
DEF TILE_WALL       EQU 3          ; solid
DEF TILE_PLAYER     EQU 4          ; OBJ tile (not used in the BG map)

DEF FIRST_SOLID_TILE EQU TILE_TREE ; tiles >= this id block movement

; Camera centring offsets (screen is 160x144; keep player near centre).
DEF CAM_CENTER_X    EQU 76         ; 160/2 - 4 (sprite half-width)
DEF CAM_CENTER_Y    EQU 68         ; 144/2 - 4
DEF CAM_MAX_X       EQU 256 - SCRN_X ; 96
DEF CAM_MAX_Y       EQU 256 - SCRN_Y ; 112

DEF MOVE_COOLDOWN   EQU 6          ; frames between grid steps while held

; Our own joypad bit layout (1 = pressed), produced by ReadInput.
DEF PAD_RIGHT       EQU %00000001
DEF PAD_LEFT        EQU %00000010
DEF PAD_UP          EQU %00000100
DEF PAD_DOWN        EQU %00001000
DEF PAD_A           EQU %00010000
DEF PAD_B           EQU %00100000
DEF PAD_SELECT      EQU %01000000
DEF PAD_START       EQU %10000000

; =============================================================================
; RAM layout
; =============================================================================
; Shadow OAM must be 256-byte aligned: OAM DMA takes the high byte of the
; source address, so the low byte must be $00.
SECTION "Shadow OAM", WRAM0, ALIGN[8]
wShadowOAM:         ds 40 * 4       ; 40 sprites x 4 bytes (Y, X, tile, attr)
wShadowOAM_End:

SECTION "Game State", WRAM0
wPlayerTX:          ds 1            ; player tile X (0..WORLD_W_TILES-1)
wPlayerTY:          ds 1            ; player tile Y
wCamX:              ds 1            ; camera scroll X (pixels)
wCamY:              ds 1            ; camera scroll Y (pixels)
wCurKeys:           ds 1            ; currently-held keys (1=pressed)
wNewKeys:           ds 1            ; keys pressed *this* frame (edge)
wPrevKeys:          ds 1            ; previous frame's held keys
wMoveCooldown:      ds 1            ; frames until next grid step allowed

SECTION "HRAM", HRAM
hVBlankFlag:        ds 1            ; set by the VBlank IRQ, cleared by WaitVBlank
hOAMDMA:            ds 16           ; OAM DMA trampoline, copied here at boot

; =============================================================================
; Interrupt vectors
; =============================================================================
SECTION "VBlank IRQ", ROM0[$0040]
    push af
    ld a, 1
    ldh [hVBlankFlag], a
    pop af
    reti

; =============================================================================
; Entry point
; =============================================================================
SECTION "EntryPoint", ROM0[$0100]
    di
    jp Start

SECTION "Main", ROM0[$0150]
Start:
    call WaitVBlankLY               ; safe point to turn the LCD off
    xor a, a
    ldh [rLCDC], a                  ; LCD off

    call LoadTiles                  ; graphics -> VRAM
    call GenerateMap                ; deterministic terrain -> BG map
    call LoadPalettes               ; CGB BG + OBJ palettes
    call ClearShadowOAM
    call CopyDMARoutine             ; install OAM DMA trampoline in HRAM

    call InitPlayer                 ; pick a passable start tile
    call UpdateCamera               ; derive scroll from player position
    call DrawPlayerSprite           ; player -> shadow OAM

    ; First scroll values, then LCD on: BG + OBJ, tiles @ $8000, map @ $9800.
    ld a, [wCamX]
    ldh [rSCX], a
    ld a, [wCamY]
    ldh [rSCY], a
    ld a, LCDCF_ON | LCDCF_BGON | LCDCF_OBJON | LCDCF_OBJ8 | LCDCF_BG8000 | LCDCF_BG9800
    ldh [rLCDC], a

    ; Enable VBlank interrupt only.
    ld a, IEF_VBLANK
    ldh [rIE], a
    xor a, a
    ldh [rIF], a
    ei

; -----------------------------------------------------------------------------
; Main loop: logic runs after each VBlank; graphics are pushed at VBlank start.
; -----------------------------------------------------------------------------
MainLoop:
    call WaitVBlank                 ; returns right at VBlank start
    ; --- VBlank-safe graphics work ---
    ld a, HIGH(wShadowOAM)
    call hOAMDMA                    ; copy shadow OAM -> OAM
    ld a, [wCamX]
    ldh [rSCX], a
    ld a, [wCamY]
    ldh [rSCY], a
    ; --- game logic ---
    call ReadInput
    call UpdatePlayer
    call UpdateCamera
    call DrawPlayerSprite
    jr MainLoop

; =============================================================================
; VBlank helpers
; =============================================================================
; Spin until the PPU reaches VBlank by polling LY (used before IRQs are on).
WaitVBlankLY:
    ldh a, [rLY]
    cp SCRN_Y
    jr c, WaitVBlankLY
    ret

; Wait for the VBlank interrupt (IRQs must be enabled).
WaitVBlank:
    xor a, a
    ldh [hVBlankFlag], a
.wait:
    halt
    ldh a, [hVBlankFlag]
    and a, a
    jr z, .wait
    ret

; =============================================================================
; Deterministic tile generator
; -----------------------------------------------------------------------------
; GenTileType: pure function of (tile X, tile Y) + WORLD_SEED.
;   in : B = tile X, C = tile Y
;   out: A = tile type (TILE_GRASS / BRUSH / TREE / WALL)
;   clobbers: D
; Integer hash with a bit of avalanche, then thresholded into terrain weights.
; Same inputs always yield the same tile — this is what makes terrain free to
; store (we regenerate it) per docs/design/01-technical-feasibility.md.
; =============================================================================
GenTileType:
    ld a, b
    add a, WORLD_SEED
    ld d, a                         ; d = x + seed
    ld a, c
    add a, d
    xor a, d                        ; mix x and y
    ld d, a
    swap a
    xor a, d                        ; avalanche high/low nibbles
    add a, b
    xor a, c                        ; final hashed byte in A
    ; --- map hash byte -> terrain (mostly grass) ---
    cp 200
    jr c, .grass                    ; ~78% grass
    cp 232
    jr c, .brush                    ; ~12% brush
    cp 248
    jr c, .tree                     ; ~6% tree (solid)
    ld a, TILE_WALL                 ; ~4% wall (solid)
    ret
.grass:
    ld a, TILE_GRASS
    ret
.brush:
    ld a, TILE_BRUSH
    ret
.tree:
    ld a, TILE_TREE
    ret

; =============================================================================
; Generate the 32x32 background map into VRAM ($9800). LCD must be off.
; The BG map is 32x32 tiles, exactly our world size, so it maps 1:1.
; =============================================================================
GenerateMap:
    ld hl, _SCRN0                   ; $9800
    ld c, 0                         ; c = tile Y (row)
.rowLoop:
    ld b, 0                         ; b = tile X (col)
.colLoop:
    push bc
    call GenTileType                ; A = tile type for (B,C)
    pop bc
    ld [hl+], a
    inc b
    ld a, b
    cp WORLD_W_TILES
    jr nz, .colLoop
    inc c
    ld a, c
    cp WORLD_H_TILES
    jr nz, .rowLoop
    ret

; =============================================================================
; Player init: start near the middle, scan for a passable tile.
; =============================================================================
InitPlayer:
    ld a, WORLD_W_TILES / 2
    ld [wPlayerTX], a
    ld a, WORLD_H_TILES / 2
    ld [wPlayerTY], a
.findPassable:
    ld a, [wPlayerTX]
    ld b, a
    ld a, [wPlayerTY]
    ld c, a
    call GenTileType
    cp FIRST_SOLID_TILE
    ret c                           ; passable (type < FIRST_SOLID_TILE) -> done
    ; solid: step one tile right and retry (bounded by world width)
    ld a, [wPlayerTX]
    inc a
    cp WORLD_W_TILES
    jr c, .store
    ld a, 1                         ; wrapped: just settle at tile 1
.store:
    ld [wPlayerTX], a
    jr .findPassable

; =============================================================================
; Camera: centre on the player, clamped to the world so we never scroll past
; the arena edge (this doubles as the visual world barrier for now).
; =============================================================================
UpdateCamera:
    ; camX = clamp(playerTX*8 - CAM_CENTER_X, 0, CAM_MAX_X)
    ld a, [wPlayerTX]
    add a, a
    add a, a
    add a, a                        ; *8
    ld b, CAM_CENTER_X
    ld c, CAM_MAX_X
    call ClampCam
    ld [wCamX], a
    ; camY = clamp(playerTY*8 - CAM_CENTER_Y, 0, CAM_MAX_Y)
    ld a, [wPlayerTY]
    add a, a
    add a, a
    add a, a
    ld b, CAM_CENTER_Y
    ld c, CAM_MAX_Y
    call ClampCam
    ld [wCamY], a
    ret

; ClampCam: A = clamp(A - B, 0, C).  in: A=px, B=center, C=max. out: A.
ClampCam:
    sub a, b
    jr nc, .checkHi                 ; if A>=B, result non-negative
    xor a, a                        ; underflow -> 0
    ret
.checkHi:
    cp c
    ret c                           ; A < max -> keep
    ld a, c                         ; clamp to max
    ret

; =============================================================================
; Input: fills wCurKeys / wNewKeys / wPrevKeys. Bit set = pressed.
; Layout: PAD_RIGHT/LEFT/UP/DOWN/A/B/SELECT/START (our own, see constants).
; =============================================================================
ReadInput:
    ; --- buttons (A,B,Select,Start) into high nibble ---
    ld a, P1F_GET_BTN
    ldh [rP1], a
    ldh a, [rP1]
    ldh a, [rP1]                    ; read twice to debounce
    and $0F
    swap a
    ld b, a
    ; --- d-pad (Right,Left,Up,Down) into low nibble ---
    ld a, P1F_GET_DPAD
    ldh [rP1], a
    ldh a, [rP1]
    ldh a, [rP1]
    ldh a, [rP1]
    ldh a, [rP1]
    and $0F
    or b                            ; combined; 0 = pressed here
    cpl                             ; invert -> 1 = pressed
    ld b, a                         ; b = current keys
    ; release the pad
    ld a, P1F_GET_NONE
    ldh [rP1], a
    ; edge detect: new = current AND NOT prev
    ld a, [wPrevKeys]
    cpl
    and b
    ld [wNewKeys], a
    ld a, b
    ld [wCurKeys], a
    ld [wPrevKeys], a
    ret

; =============================================================================
; Player update: grid movement with a per-step cooldown while a direction is
; held, tile collision, and world-edge barriers.
; =============================================================================
UpdatePlayer:
    ; tick cooldown down to zero
    ld a, [wMoveCooldown]
    and a, a
    jr z, .canMove
    dec a
    ld [wMoveCooldown], a
    ret
.canMove:
    ld a, [wCurKeys]
    ld e, a                         ; e = held keys
    ; candidate target starts at current tile
    ld a, [wPlayerTX]
    ld b, a                         ; b = target TX
    ld a, [wPlayerTY]
    ld c, a                         ; c = target TY
    ; --- pick one direction (priority: up,down,left,right) ---
    bit 2, e                        ; PAD_UP
    jr z, .notUp
    ld a, c
    and a, a
    ret z                           ; at top edge -> barrier, no move
    dec c
    jr .tryMove
.notUp:
    bit 3, e                        ; PAD_DOWN
    jr z, .notDown
    ld a, c
    cp WORLD_H_TILES - 1
    ret z                           ; bottom edge
    inc c
    jr .tryMove
.notDown:
    bit 1, e                        ; PAD_LEFT
    jr z, .notLeft
    ld a, b
    and a, a
    ret z                           ; left edge
    dec b
    jr .tryMove
.notLeft:
    bit 0, e                        ; PAD_RIGHT
    ret z                           ; no direction held
    ld a, b
    cp WORLD_W_TILES - 1
    ret z                           ; right edge
    inc b
    ; fall through
.tryMove:
    ; B,C = target tile. Blocked if terrain there is solid.
    push bc
    call GenTileType
    pop bc
    cp FIRST_SOLID_TILE
    ret nc                          ; solid -> blocked, no move
    ; commit move
    ld a, b
    ld [wPlayerTX], a
    ld a, c
    ld [wPlayerTY], a
    ld a, MOVE_COOLDOWN
    ld [wMoveCooldown], a
    ret

; =============================================================================
; Player sprite -> shadow OAM entry 0.
;   screenX = playerTX*8 - camX + OAM_X_OFS(8)
;   screenY = playerTY*8 - camY + OAM_Y_OFS(16)
; =============================================================================
DrawPlayerSprite:
    ; Y
    ld a, [wPlayerTY]
    add a, a
    add a, a
    add a, a                        ; *8
    ld b, a
    ld a, [wCamY]
    ld c, a
    ld a, b
    sub a, c
    add a, 16                       ; OAM Y offset
    ld [wShadowOAM + 0], a
    ; X
    ld a, [wPlayerTX]
    add a, a
    add a, a
    add a, a
    ld b, a
    ld a, [wCamX]
    ld c, a
    ld a, b
    sub a, c
    add a, 8                        ; OAM X offset
    ld [wShadowOAM + 1], a
    ; tile + attributes
    ld a, TILE_PLAYER
    ld [wShadowOAM + 2], a
    xor a, a                        ; attr: OBJ palette 0, no flip
    ld [wShadowOAM + 3], a
    ret

; =============================================================================
; Init helpers
; =============================================================================
LoadTiles:
    ld hl, Tiles
    ld de, _VRAM                    ; $8000
    ld bc, TilesEnd - Tiles
.copy:
    ld a, [hl+]
    ld [de], a
    inc de
    dec bc
    ld a, b
    or a, c
    jr nz, .copy
    ret

LoadPalettes:
    ; BG palette 0
    ld a, BCPSF_AUTOINC
    ldh [rBCPS], a
    ld hl, BGPalette
    ld b, BGPaletteEnd - BGPalette
.bg:
    ld a, [hl+]
    ldh [rBCPD], a
    dec b
    jr nz, .bg
    ; OBJ palette 0
    ld a, OCPSF_AUTOINC
    ldh [rOCPS], a
    ld hl, OBJPalette
    ld b, OBJPaletteEnd - OBJPalette
.obj:
    ld a, [hl+]
    ldh [rOCPD], a
    dec b
    jr nz, .obj
    ret

; Clear shadow OAM: set every sprite's Y to 0 (off-screen), rest 0.
ClearShadowOAM:
    ld hl, wShadowOAM
    ld bc, wShadowOAM_End - wShadowOAM
    xor a, a
.loop:
    ld [hl+], a
    dec bc
    ld a, b
    or a, c
    jr nz, .loop
    xor a, a                        ; (a already 0, keep explicit)
    ret

; Copy the OAM DMA trampoline into HRAM (DMA must be kicked from HRAM because
; the CPU can only touch HRAM while the DMA is running).
CopyDMARoutine:
    ld hl, DMARoutine
    ld c, LOW(hOAMDMA)
    ld b, DMARoutineEnd - DMARoutine
.copy:
    ld a, [hl+]
    ldh [c], a
    inc c
    dec b
    jr nz, .copy
    ret

; Template copied to HRAM. Call as: ld a, HIGH(wShadowOAM) : call hOAMDMA
DMARoutine:
    ldh [rDMA], a
    ld a, 40
.wait:
    dec a
    jr nz, .wait
    ret
DMARoutineEnd:

; =============================================================================
; Graphics data
; =============================================================================
SECTION "GfxData", ROM0

; Backtick literals: each digit is a 2bpp colour index (0-3) for one pixel.
Tiles:
; --- tile 0: grass (passable) ---
    dw `00000000
    dw `00000100
    dw `00000000
    dw `00100000
    dw `00000000
    dw `00000010
    dw `01000000
    dw `00000000
; --- tile 1: brush (passable, denser texture) ---
    dw `01000100
    dw `10101010
    dw `01000100
    dw `00010001
    dw `01000100
    dw `10101010
    dw `00010001
    dw `01000100
; --- tile 2: tree (solid) ---
    dw `00222000
    dw `02233220
    dw `22333322
    dw `23333332
    dw `22333322
    dw `02233220
    dw `00033000
    dw `00033000
; --- tile 3: wall (solid) ---
    dw `22222222
    dw `23232323
    dw `22222222
    dw `32323232
    dw `22222222
    dw `23232323
    dw `22222222
    dw `32323232
; --- tile 4: player (OBJ; colour 0 = transparent) ---
    dw `00111100
    dw `01133110
    dw `01313310
    dw `01111110
    dw `00122100
    dw `01122110
    dw `01100110
    dw `01100110
TilesEnd:

; CGB palettes: 4 colours each, BGR555, `dw` = little-endian (matches rBCPD).
; value = (B<<10)|(G<<5)|R, each channel 0-31.
BGPalette:
    dw (12 << 10) | (29 << 5) | 21   ; 0 pale green (grass)
    dw (10 << 10) | (22 << 5) | 12   ; 1 mid green  (brush)
    dw (15 << 10) | (14 << 5) | 13   ; 2 grey       (wall/tree mass)
    dw ( 4 << 10) | ( 6 << 5) |  3   ; 3 dark       (outline/foliage)
BGPaletteEnd:

OBJPalette:
    dw ( 0 << 10) | ( 0 << 5) |  0   ; 0 transparent (ignored for OBJ)
    dw ( 6 << 10) | ( 8 << 5) | 31   ; 1 red (body)
    dw ( 3 << 10) | ( 3 << 5) | 20   ; 2 dark red (shading)
    dw (31 << 10) | (31 << 5) | 31   ; 3 white (highlight)
OBJPaletteEnd:
