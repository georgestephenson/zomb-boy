; =============================================================================
; world.asm — the endless procedural world.
;
;   * GenTileType : deterministic terrain from 16-bit world coords + seed,
;                   layered as water (ponds) / roads (grid) / scatter.
;   * InitMap     : fill the whole 32x32 BG map (tiles + CGB attributes).
;   * GenStrip    : after the player steps, generate the one incoming column or
;                   row into a WRAM buffer (heavy work, done outside VBlank).
;   * BlitStream  : push that buffer into VRAM during VBlank (tight + fast).
;
; The 32x32 BG map is a *circular buffer*: world tile (X,Y) always lives in map
; cell (X & 31, Y & 31). Moving one tile only invalidates the single incoming
; edge, so we regenerate just that column/row — this is what makes the world
; endless on a handheld (see docs/design/02-world-and-exploration.md).
; =============================================================================
INCLUDE "hardware.inc"
INCLUDE "include/constants.inc"

SECTION "World", ROM0

; -----------------------------------------------------------------------------
; GenTileType: pure function of (wGenX, wGenY) + WORLD_SEED -> A = tile type.
; -----------------------------------------------------------------------------
GenTileType::
    ; --- water: coarse (4x4-block) noise, makes ponds/lakes ---
    call SetHXY_coarse
    call Hash8
    cp WATER_THRESH
    jr c, .water
    ; --- roads: a 1-tile grid every 16 tiles through the origin ---
    ld a, [wGenX]
    and $0F
    jr z, .road
    ld a, [wGenY]
    and $0F
    jr z, .road
    ; --- scatter on land: per-tile fine noise ---
    call SetHXY_fine
    call Hash8
    cp 248
    jr nc, .wall
    cp 236
    jr nc, .tree
    cp 222
    jr nc, .brush
    ld a, TILE_GRASS
    ret
.brush:
    ld a, TILE_BRUSH
    ret
.tree:
    ld a, TILE_TREE
    ret
.wall:
    ld a, TILE_WALL
    ret
.water:
    ld a, TILE_WATER
    ret
.road:
    ld a, TILE_ROAD
    ret

; IsSolid: A = tile type -> Z if passable, NZ if solid. Preserves nothing much.
IsSolid::
    ld c, a
    ld b, 0
    ld hl, PassTable
    add hl, bc
    ld a, [hl]
    and a, a
    ret

; -----------------------------------------------------------------------------
; Hash8: 8-bit avalanche hash of (wHX, wHY) + seed -> A. Clobbers B,C,D,E,H.
; Mirror of test/model/worldgen_model.py:hash8 — keep them in lockstep.
; -----------------------------------------------------------------------------
Hash8:
    ld a, [wHX]                 ; xl
    ld b, a
    ld a, [wHX+1]               ; xh
    ld c, a
    ld a, [wHY]                 ; yl
    ld d, a
    ld a, [wHY+1]               ; yh
    ld e, a
    ld a, WORLD_SEED
    add a, b                    ; + xl
    xor a, d                    ; ^ yl
    ld h, a
    swap a
    add a, c                    ; + xh
    xor a, e                    ; ^ yh
    xor a, h
    ld h, a
    swap a
    add a, b                    ; + xl
    xor a, d                    ; ^ yl
    ret

; wHX/wHY = wGenX/wGenY (fine, per-tile).
SetHXY_fine:
    ld a, [wGenX]
    ld [wHX], a
    ld a, [wGenX+1]
    ld [wHX+1], a
    ld a, [wGenY]
    ld [wHY], a
    ld a, [wGenY+1]
    ld [wHY+1], a
    ret

; wHX/wHY = wGenX/wGenY >> 2 (coarse: 4x4 tiles share a value).
SetHXY_coarse:
    ld a, [wGenX+1]
    ld d, a
    ld a, [wGenX]
    ld e, a
    srl d
    rr e
    srl d
    rr e
    ld a, e
    ld [wHX], a
    ld a, d
    ld [wHX+1], a
    ld a, [wGenY+1]
    ld d, a
    ld a, [wGenY]
    ld e, a
    srl d
    rr e
    srl d
    rr e
    ld a, e
    ld [wHY], a
    ld a, d
    ld [wHY+1], a
    ret

; -----------------------------------------------------------------------------
; CalcMapAddr: HL = BG map address for the current (wGenX, wGenY).
;   addr = _SCRN0 + (wGenY & 31) * 32 + (wGenX & 31)
; -----------------------------------------------------------------------------
CalcMapAddr:
    ld a, [wGenY]
    and 31
    ld l, a
    ld h, 0
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl                  ; * 32
    ld a, [wGenX]
    and 31
    add a, l
    ld l, a
    ld a, h
    adc a, 0
    ld h, a                     ; + cellX
    ld bc, _SCRN0
    add hl, bc
    ret

; -----------------------------------------------------------------------------
; InitMap: generate the full 32x32 map around the current view. LCD off.
; Writes tile ids into VRAM bank 0 and CGB attributes into VRAM bank 1 (the
; latter is what was missing before — uninitialised attributes caused the stray
; white tiles in the top-left).
; -----------------------------------------------------------------------------
InitMap::
    ld a, [wViewTY]
    ld [wGenY], a
    ld a, [wViewTY+1]
    ld [wGenY+1], a
    ld c, 32                    ; row counter
.row:
    ld a, [wViewTX]
    ld [wGenX], a
    ld a, [wViewTX+1]
    ld [wGenX+1], a
    ld b, 32                    ; column counter
.col:
    push bc
    call GenTileType
    ld [wCurTile], a
    call CalcMapAddr            ; HL = cell address
    xor a, a
    ldh [rVBK], a              ; VRAM bank 0
    ld a, [wCurTile]
    ld [hl], a                  ; tile id
    ld a, 1
    ldh [rVBK], a              ; VRAM bank 1
    ld a, [wCurTile]
    ld c, a
    ld b, 0
    push hl
    ld hl, AttrTable
    add hl, bc
    ld a, [hl]
    pop hl
    ld [hl], a                  ; CGB attribute (palette select)
    pop bc
    ld hl, wGenX
    call Inc16Ptr               ; worldX++
    dec b
    jr nz, .col
    ld hl, wGenY
    call Inc16Ptr               ; worldY++
    dec c
    jr nz, .row
    xor a, a
    ldh [rVBK], a              ; leave bank 0 selected
    ret

; -----------------------------------------------------------------------------
; GenStrip: build the incoming edge (per wMoveDir) into wStrBuf, ready to blit.
; -----------------------------------------------------------------------------
GenStrip::
    ld a, [wMoveDir]
    cp DIR_RIGHT
    jr z, .right
    cp DIR_LEFT
    jr z, .left
    cp DIR_DOWN
    jr z, .down
    ; --- up: new top row = worldY viewTY, across the columns ---
    call GS_LoadView
    xor a, a
    ld [wStrIsCol], a
    ld a, VIEW_COLS
    ld [wStrLen], a
    jr .fill
.down:
    call GS_LoadView
    ld hl, wGenY
    ld a, VIEW_ROWS - 1
    call Add16Ptr               ; worldY = viewTY + bottom row
    xor a, a
    ld [wStrIsCol], a
    ld a, VIEW_COLS
    ld [wStrLen], a
    jr .fill
.left:
    call GS_LoadView            ; new left col = worldX viewTX
    ld a, 1
    ld [wStrIsCol], a
    ld a, VIEW_ROWS
    ld [wStrLen], a
    jr .fill
.right:
    call GS_LoadView
    ld hl, wGenX
    ld a, VIEW_COLS - 1
    call Add16Ptr               ; worldX = viewTX + right col
    ld a, 1
    ld [wStrIsCol], a
    ld a, VIEW_ROWS
    ld [wStrLen], a
    ; fall through
.fill:
    ld a, LOW(wStrBuf)
    ld [wBufPtr], a
    ld a, HIGH(wStrBuf)
    ld [wBufPtr+1], a
    ld a, [wStrLen]
    ld [wStrI], a
.loop:
    call GenTileType
    ld [wCurTile], a
    call CalcMapAddr            ; HL = VRAM address for this cell
    ld a, [wBufPtr]
    ld e, a
    ld a, [wBufPtr+1]
    ld d, a                     ; DE = buffer write pointer
    ld a, l
    ld [de], a
    inc de
    ld a, h
    ld [de], a
    inc de
    ld a, [wCurTile]
    ld [de], a                  ; tile id
    inc de
    ld c, a
    ld b, 0
    ld hl, AttrTable
    add hl, bc
    ld a, [hl]
    ld [de], a                  ; attribute
    inc de
    ld a, e
    ld [wBufPtr], a
    ld a, d
    ld [wBufPtr+1], a
    ; advance the varying axis
    ld a, [wStrIsCol]
    and a, a
    jr z, .incX
    ld hl, wGenY
    call Inc16Ptr
    jr .next
.incX:
    ld hl, wGenX
    call Inc16Ptr
.next:
    ld a, [wStrI]
    dec a
    ld [wStrI], a
    jr nz, .loop
    ld a, 1
    ld [wStrKind], a           ; mark buffer ready for BlitStream
    ret

; wGenX/wGenY = current view origin.
GS_LoadView:
    ld a, [wViewTX]
    ld [wGenX], a
    ld a, [wViewTX+1]
    ld [wGenX+1], a
    ld a, [wViewTY]
    ld [wGenY], a
    ld a, [wViewTY+1]
    ld [wGenY+1], a
    ret

; -----------------------------------------------------------------------------
; BlitStream: push the queued strip into VRAM. Call only during VBlank.
; Two passes so we flip VRAM banks once each, not per tile.
; -----------------------------------------------------------------------------
BlitStream::
    ld a, [wStrKind]
    and a, a
    ret z
    ; pass 1 — tile ids into bank 0
    xor a, a
    ldh [rVBK], a
    ld de, wStrBuf
    ld a, [wStrLen]
    ld b, a
.p1:
    ld a, [de]
    inc de
    ld l, a
    ld a, [de]
    inc de
    ld h, a
    ld a, [de]
    inc de                      ; tile
    ld [hl], a
    inc de                      ; skip attr
    dec b
    jr nz, .p1
    ; pass 2 — attributes into bank 1
    ld a, 1
    ldh [rVBK], a
    ld de, wStrBuf
    ld a, [wStrLen]
    ld b, a
.p2:
    ld a, [de]
    inc de
    ld l, a
    ld a, [de]
    inc de
    ld h, a
    inc de                      ; skip tile
    ld a, [de]
    inc de                      ; attr
    ld [hl], a
    dec b
    jr nz, .p2
    xor a, a
    ldh [rVBK], a              ; back to bank 0
    ld [wStrKind], a           ; clear pending
    ret

; -----------------------------------------------------------------------------
; Tables (index by tile type). Keep PassTable in sync with the model.
; -----------------------------------------------------------------------------
;                grass brush tree wall water road
PassTable:  db     0,    0,   1,   1,   1,    0    ; 1 = solid
AttrTable:  db     0,    0,   0,   0,   1,    0    ; CGB BG palette per tile
