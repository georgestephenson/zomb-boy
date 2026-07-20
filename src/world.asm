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
;
; A coarse, domain-warped BIOME field selects a region type; each biome then
; assembles its own features from a few shared noise fields:
;   * city   : houses + a meandering road grid over bare dirt (no water/trees).
;   * marsh  : lots of water, some reeds/trees, murky ground (no roads/houses).
;   * forest : dense 2x2 trees + brush, the odd pond (no roads/houses).
;   * plains : open grass, sparse trees, flowers, rare pond.
; Mirror of worldgen_model.py:gen_tile_type; keep byte-for-byte in lockstep (the
; streaming integration test diffs the two). Clobbers A,B,C,D,H,L; tile in A.
; -----------------------------------------------------------------------------
; Multi-tile features are decided from a *consistent anchor* so they never get
; clipped: houses gate on the 16x16 CHUNK biome (whole footprint agrees), and
; terrain/trees use the 2x2 BLOCK biome. Trees are placed *before* water so a
; pond can't bite a quadrant out of a tree.
GenTileType::
    ; --- houses: a tile is a house iff it is inside a footprint AND its chunk's
    ;     biome is city. Test the (cheap) footprint first and only pay for the
    ;     chunk-biome lookup for the few tiles actually inside a building. ---
    call HouseTile
    cp $FF
    jr z, .terrain              ; not in any footprint
    ld e, a                     ; stash house tile (HouseTile/CalcBiome preserve E)
    ld a, [wGenX]
    and $F0
    ld [wBiX], a
    ld a, [wGenX+1]
    ld [wBiX+1], a
    ld a, [wGenY]
    and $F0
    ld [wBiY], a
    ld a, [wGenY+1]
    ld [wBiY+1], a
    call CalcBiome              ; chunk-anchor biome (wGen & $FFF0)
    cp BIOME_GRAVEYARD          ; graveyards get a lone church (same wall/door art);
    jr z, .houseStands          ;   no roads there, so it always stands
    cp BIOME_CITY
    jr nz, .terrain
    ; A city building yields to any avenue the (jittered) street grid runs through
    ; it, so streets stay whole and the network stays connected (E is preserved
    ; across RoadHere via Hash8). Otherwise the building stands.
    call RoadHere
    jr z, .terrain              ; on a street -> let GenCity draw the road
.houseStands:
    ld a, e                     ; the building stands
    ret
.terrain:
    ; --- terrain biome at the block anchor (wGen & $FFFE): 2x2 trees stay whole ---
    ld a, [wGenX]
    and $FE
    ld [wBiX], a
    ld a, [wGenX+1]
    ld [wBiX+1], a
    ld a, [wGenY]
    and $FE
    ld [wBiY], a
    ld a, [wGenY+1]
    ld [wBiY+1], a
    call CalcBiome              ; A = block biome
    cp BIOME_CITY
    jp z, GenCity
    cp BIOME_MARSH
    jp z, GenMarsh
    cp BIOME_FOREST
    jp z, GenForest
    cp BIOME_RUINS
    jp z, GenRuins
    cp BIOME_FARM
    jp z, GenFarm
    cp BIOME_JUNGLE
    jp z, GenJungle
    cp BIOME_GRAVEYARD
    jp z, GenGraveyard
    cp BIOME_DESERT
    jp z, GenDesert
    cp BIOME_MOUNTAINS
    jp z, GenMountains
    cp BIOME_TUNDRA
    jp z, GenTundra
    ; fall through: plains
GenPlains:
    ld e, TREE_PLAINS
    call TreeQuad
    cp $FF
    ret nz                      ; whole 2x2 tree quadrant
    call WaterField
    cp WATER_PLAINS
    jr c, .water
    call ScatterHash
    cp 246
    jr nc, .flower
    cp 232
    jr nc, .brush
    ld a, TILE_GRASS
    ret
.flower:
    ld a, TILE_FLOWER
    ret
.brush:
    ld a, TILE_BRUSH
    ret
.water:
    ld a, TILE_WATER
    ret

GenForest:
    ld e, TREE_FOREST
    call TreeQuad
    cp $FF
    ret nz
    call WaterField
    cp WATER_FOREST
    jr c, .water
    call ScatterHash
    cp 150
    jr nc, .brush
    ld a, TILE_GRASS
    ret
.brush:
    ld a, TILE_BRUSH
    ret
.water:
    ld a, TILE_WATER
    ret

GenMarsh:
    ld e, TREE_MARSH
    call TreeQuad
    cp $FF
    ret nz
    call WaterField
    cp WATER_MARSH
    jr c, .water
    call ScatterHash
    cp 205
    jr nc, .brush               ; reeds
    ld a, TILE_MARSH
    ret
.brush:
    ld a, TILE_BRUSH
    ret
.water:
    ld a, TILE_WATER
    ret

GenCity:                        ; house already handled in GenTileType
    call RoadHere
    jr z, .road
    call ScatterHash
    cp 250
    jr nc, .wall                ; rubble
    cp 230
    jr nc, .grass               ; weed patch
    cp 215
    jr nc, .brush
    ld a, TILE_DIRT
    ret
.road:
    ld a, TILE_ROAD
    ret
.wall:
    ld a, TILE_WALL
    ret
.grass:
    ld a, TILE_GRASS
    ret
.brush:
    ld a, TILE_BRUSH
    ret

; --- Ruins: the same street grid as the city, but cracked and rubble-strewn ---
GenRuins:
    call RoadHere
    jr z, .onRoad
    call ScatterHash
    cp 240
    jr nc, .wall                ; scattered rubble
    cp 215
    jr nc, .brush               ; weeds through the cracks
    cp 140
    jr nc, .dirt
    ld a, TILE_GRASS            ; ground reclaimed by nature
    ret
.onRoad:
    call ScatterHash
    cp 105
    jr nc, .road                ; ~59% of the street still holds
    cp 60
    jr nc, .wall                ; collapsed into rubble
    ld a, TILE_DIRT             ; cracked to bare dirt
    ret
.road:
    ld a, TILE_ROAD
    ret
.wall:
    ld a, TILE_WALL
    ret
.brush:
    ld a, TILE_BRUSH
    ret
.dirt:
    ld a, TILE_DIRT
    ret

; --- Farm: a regular 8-tile grid of fenced fields full of tall wheat ---
GenFarm:
    ld a, [wGenX]
    and 7
    jr z, .fenceLine
    ld a, [wGenY]
    and 7
    jr z, .fenceLine
    call ScatterHash            ; field interior
    cp 128
    jr nc, .wheat
    ld a, TILE_DIRT             ; tilled soil
    ret
.fenceLine:
    call ScatterHash
    and 3
    jr z, .gap                  ; 1-in-4 cells is a gate/gap -> fields stay crossable
    ld a, TILE_FENCE
    ret
.gap:
    ld a, TILE_DIRT
    ret
.wheat:
    ld a, TILE_WHEAT
    ret

; --- Jungle: forest-dense trees over near-continuous undergrowth ---
GenJungle:
    ld e, TREE_JUNGLE
    call TreeQuad
    cp $FF
    ret nz                      ; a 2x2 tree quadrant
    call ScatterHash
    cp 90
    jr nc, .brush               ; heavy undergrowth / vines
    ld a, TILE_GRASS
    ret
.brush:
    ld a, TILE_BRUSH
    ret

; --- Graveyard: grass, scattered headstones, the odd dead tree (church above) ---
GenGraveyard:
    ld e, TREE_GRAVE
    call TreeQuad
    cp $FF
    ret nz
    call ScatterHash
    cp 235
    jr nc, .grave
    cp 205
    jr nc, .brush               ; dead weeds
    ld a, TILE_GRASS
    ret
.grave:
    ld a, TILE_GRAVE
    ret
.brush:
    ld a, TILE_BRUSH
    ret

; --- Desert: sand, cactus, the occasional rock; no water, no trees ---
GenDesert:
    call ScatterHash
    cp 248
    jr nc, .rock                ; the odd rock/mesa
    cp 234
    jr nc, .cactus
    cp 216
    jr nc, .brush               ; dry scrub
    ld a, TILE_SAND
    ret
.rock:
    ld a, TILE_WALL
    ret
.cactus:
    ld a, TILE_CACTUS
    ret
.brush:
    ld a, TILE_BRUSH
    ret

; --- Mountains: stony ground with rocky outcrops and sparse pines ---
GenMountains:
    ld e, TREE_MTN
    call TreeQuad
    cp $FF
    ret nz
    call ScatterHash
    cp 210
    jr nc, .rock                ; rocky outcrop
    cp 150
    jr nc, .dirt                ; stony ground
    cp 90
    jr nc, .grass               ; alpine meadow
    ld a, TILE_DIRT
    ret
.rock:
    ld a, TILE_WALL
    ret
.dirt:
    ld a, TILE_DIRT
    ret
.grass:
    ld a, TILE_GRASS
    ret

; --- Tundra: snow, frozen ponds (solid ice), boulders, sparse frozen pines ---
GenTundra:
    ld e, TREE_TUNDRA
    call TreeQuad
    cp $FF
    ret nz
    call WaterField
    cp WATER_TUNDRA
    jr c, .ice                  ; a frozen pond (rare, like plains water)
    call ScatterHash
    cp 240
    jr nc, .rock
    ld a, TILE_SNOW
    ret
.ice:
    ld a, TILE_ICE
    ret
.rock:
    ld a, TILE_WALL
    ret

; -----------------------------------------------------------------------------
; CalcBiome: A = BIOME_* for the anchor in (wBiX, wBiY). A coarse (~64-tile)
; value-noise field, domain-warped so region borders are organic not square.
; The caller floors the coords to a feature anchor (chunk for houses, 2x2 block
; for terrain) so multi-tile features see one consistent biome.
;
; Memoized: the result is pure in (anchor, seed), and consecutive tiles share
; anchors (2x2 blocks / 16x16 chunks), so a 1-entry cache answers about half of
; all calls during strip generation / InitMap without touching Hash8. The seed
; only changes across a boot, and ClearRAM zeroes wBioCacheOK there, so the
; cache can never serve a stale world. Preserves D,E (GenTileType relies on E).
; -----------------------------------------------------------------------------
CalcBiome::
    ld a, [wBioCacheOK]
    and a, a
    jr z, .miss
    ld hl, wBioCacheX
    ld a, [wBiX]
    cp [hl]
    jr nz, .miss
    inc hl
    ld a, [wBiX+1]
    cp [hl]
    jr nz, .miss
    inc hl
    ld a, [wBiY]
    cp [hl]
    jr nz, .miss
    inc hl
    ld a, [wBiY+1]
    cp [hl]
    jr nz, .miss
    ld a, [wBioCacheVal]
    ret
.miss:
    ld hl, wBioCacheX
    ld a, [wBiX]
    ld [hl+], a
    ld a, [wBiX+1]
    ld [hl+], a
    ld a, [wBiY]
    ld [hl+], a
    ld a, [wBiY+1]
    ld [hl], a
    ld a, 1
    ld [wBioCacheOK], a
    call LoadHfromBi
    call ShiftH
    call ShiftH
    call ShiftH                 ; wH = wBi >> 3 (warp sample point)
    ld b, 60
    call Hash8
    and 15
    ld c, a
    ld a, [wBiX]
    add a, c
    ld [wWX], a
    ld a, [wBiX+1]
    adc a, 0
    ld [wWX+1], a
    ld b, 61                    ; (wH unchanged)
    call Hash8
    and 15
    ld c, a
    ld a, [wBiY]
    add a, c
    ld [wWY], a
    ld a, [wBiY+1]
    adc a, 0
    ld [wWY+1], a
    call LoadHfromW
    call ShiftH
    call ShiftH
    call ShiftH
    call ShiftH
    call ShiftH
    call ShiftH                 ; wH = wW >> 6 (64-tile biome cells)
    ld b, 70
    call Hash8
    ; Slice the 0..255 field into 11 bands. City/ruins sit at the low end (they
    ; share the road grid); forest/jungle keep the high-but-below-marsh band so
    ; the classic seed's spawn (field value 195) stays FOREST as it always was
    ; — the reproducible test world, and a feature-rich start; marsh keeps the
    ; wet top end so its water still dominates the world's water (the model's
    ; clustering check). Mirror: worldgen_model.py:biome().
    cp 24
    jr c, .city
    cp 44
    jr c, .ruins
    cp 76
    jr c, .plains
    cp 96
    jr c, .farm
    cp 118
    jr c, .desert
    cp 138
    jr c, .mtn
    cp 156
    jr c, .tundra
    cp 174
    jr c, .grave
    cp 194
    jr c, .jungle
    cp 212
    jr c, .forest
    ld a, BIOME_MARSH
    jr .store
.city:
    ld a, BIOME_CITY
    jr .store
.ruins:
    ld a, BIOME_RUINS
    jr .store
.plains:
    ld a, BIOME_PLAINS
    jr .store
.farm:
    ld a, BIOME_FARM
    jr .store
.forest:
    ld a, BIOME_FOREST
    jr .store
.jungle:
    ld a, BIOME_JUNGLE
    jr .store
.grave:
    ld a, BIOME_GRAVEYARD
    jr .store
.desert:
    ld a, BIOME_DESERT
    jr .store
.mtn:
    ld a, BIOME_MOUNTAINS
    jr .store
.tundra:
    ld a, BIOME_TUNDRA
    ; fall through
.store:
    ld [wBioCacheVal], a        ; fill the memo entry (key stored at .miss)
    ret

; -----------------------------------------------------------------------------
; WaterField: A = (octaveA + octaveB) >> 1 of the domain-warped 2-octave coarse
; noise (lower = wetter). Each biome thresholds this differently.
; -----------------------------------------------------------------------------
WaterField:
    call LoadHfromGen
    call ShiftH                 ; wH = wGen >> 1
    ld b, 11
    call Hash8
    and 7
    ld c, a
    ld a, [wGenX]
    add a, c
    ld [wWX], a
    ld a, [wGenX+1]
    adc a, 0
    ld [wWX+1], a
    ld b, 47
    call Hash8
    and 7
    ld c, a
    ld a, [wGenY]
    add a, c
    ld [wWY], a
    ld a, [wGenY+1]
    adc a, 0
    ld [wWY+1], a
    call LoadHfromW
    call ShiftH
    call ShiftH                 ; wH = wW >> 2
    ld b, 3
    call Hash8
    ld d, a                     ; octave A (Hash8 preserves D)
    call ShiftH                 ; wH = wW >> 3
    ld b, 5
    call Hash8                  ; octave B
    add a, d
    rra                         ; (A + B) >> 1
    ret

; -----------------------------------------------------------------------------
; TreeQuad: E = anchor threshold (lower = denser). If the 2x2 block containing
; (wGenX, wGenY) is a tree, A = its quadrant tile (TILE_TREE_TL..BR); else $FF.
; -----------------------------------------------------------------------------
TreeQuad:
    call LoadHfromGen
    call ShiftH                 ; wH = wGen >> 1 (2x2 anchor cell)
    ld b, 71
    call Hash8
    cp e
    jr c, .none                 ; hash < threshold -> no tree
    ld a, [wGenX]
    and 1                       ; quadrant X (0/1)
    ld c, a
    ld a, [wGenY]
    and 1                       ; quadrant Y
    add a, a                    ; qy * 2
    add a, c                    ; + qx
    add a, TILE_TREE_TL
    ret
.none:
    ld a, $FF
    ret

; -----------------------------------------------------------------------------
; RoadHere: Z set if (wGenX, wGenY) is a road cell.
;
; Avenues are full-length straight VERTICAL lines — one per 16-wide band, its
; column jittered 0..7 by the band index alone — the connected backbone. Cross-
; streets are HORIZONTAL but JOG: a street's row is jittered per avenue-INTERVAL
; (the band of the avenue at/left of x), so it steps up/down each time it crosses
; an avenue → bends and T-junctions. The jog lands exactly ON an avenue, and the
; full-length avenue bridges the two different-row segments, so every street
; segment has both ends on an avenue and the whole network stays connected.
; Finally, some bands sprout a short dead-end/cul-de-sac SPUR branching right off
; their avenue (entirely within the band, touching the avenue so it connects).
; Mirror: worldgen_model.py:road_here. The ruins biome reuses this and cracks it.
; Uses wHDX as a 1-byte scratch (free here — HouseTile's result is already in E).
; -----------------------------------------------------------------------------
RoadHere:
    ; --- avenue: band k = x>>4, jittered column jit_k = hash(k,0,21) & 7 ---
    call LoadHfromGen
    xor a, a
    ld [wHY], a
    ld [wHY+1], a               ; wHY = 0 (jitter keyed on the band index only)
    call ShiftH
    call ShiftH
    call ShiftH
    call ShiftH                 ; wHX = wGenX >> 4 = k, wHY = 0
    ld b, 21
    call Hash8
    and 7                       ; jit_k
    ld c, a
    ld a, [wGenX]
    and $0F                     ; xlow
    cp c
    ret z                       ; on the avenue -> road (Z set)
    jr nc, .eligible            ; xlow > jit_k -> kL = k, spur-eligible
    ; xlow < jit_k -> interval kL = k-1 (16-bit decrement of wHX), no spur
    ld a, [wHX]
    sub 1
    ld [wHX], a
    ld a, [wHX+1]
    sbc 0
    ld [wHX+1], a
    call .loadWHYshifted        ; wHY = y >> 4
    jr .street
.eligible:                      ; A = xlow, C = jit_k, wHX = k, wHY = 0
    sub c
    ld [wHDX], a                ; d = xlow - jit_k (>= 1), saved
    call .loadWHYshifted        ; wHY = y >> 4 (wHX = k intact)
    ; --- spur presence/shape: h = hash(k, y>>4, 23) ---
    ld b, 23
    call Hash8
    ld d, a                     ; D = h (Hash8 preserves D thereafter)
    and 3
    jr nz, .street              ; spur not present in this band -> just the street
    ld a, d
    srl a
    srl a
    and 7
    add a, 3
    ld c, a                     ; C = sr = 3 + ((h>>2)&7)
    ld a, d
    swap a
    srl a
    and 3
    add a, 2
    ld b, a                     ; B = length = 2 + ((h>>5)&3)
    ld a, [wGenY]
    and $0F                     ; ylow
    cp c
    jr nz, .spurHead            ; not the spur's own row -> maybe its cul-de-sac head
    ld a, [wHDX]               ; d
    cp b
    jr z, .isRoad               ; d == length (tip)
    jr c, .isRoad               ; d <  length (along the spur)
    jr .street                  ; d >  length -> past the dead-end
.spurHead:
    ld a, d
    and $80                     ; cul-de-sac bit (h>>7)
    jr z, .street               ; plain dead-end, no turnaround head
    ld a, [wHDX]               ; d
    cp b
    jr nz, .street              ; head only at the tip (d == length)
    ld a, [wGenY]
    and $0F                     ; ylow
    inc a
    cp c
    jr z, .isRoad               ; ylow + 1 == sr  (head cell above)
    dec a
    dec a
    cp c
    jr z, .isRoad               ; ylow - 1 == sr  (head cell below)
    jr .street
.isRoad:
    xor a, a                    ; Z set -> road
    ret
.street:
    ; --- cross-street row jitter jit_s = hash(kL, y>>4, 22) & 7 ---
    ld b, 22
    call Hash8
    and 7                       ; jit_s
    ld c, a
    ld a, [wGenY]
    and $0F                     ; ylow
    cp c
    ret                         ; Z iff on the (jogging) cross-street
; wHY = wGenY >> 4, shifted alone so wHX is left untouched.
.loadWHYshifted:
    ld a, [wGenY]
    ld [wHY], a
    ld a, [wGenY+1]
    ld [wHY+1], a
    REPT 4
    ld hl, wHY+1
    srl [hl]
    dec hl
    rr [hl]
    ENDR
    ret

; -----------------------------------------------------------------------------
; HouseTile: one optional building per 16x16 chunk. A = wall/floor/door tile if
; (wGenX, wGenY) is inside this chunk's house, else $FF. Perimeter -> wall (with
; a door at bottom-centre), interior -> floor. The bbox is inset 3..6 tiles so
; it never touches the road grid on the chunk borders.
; -----------------------------------------------------------------------------
HouseTile:
    call LoadHfromGen
    call ShiftH
    call ShiftH
    call ShiftH
    call ShiftH                 ; wH = (wGenX>>4, wGenY>>4) = chunk coords
    ld b, 137
    call Hash8
    cp 128
    jp c, .none                 ; ~half of city chunks have no house
    ; Footprint offset+size are EVEN so edges land on 2x2 tree-block boundaries
    ; -> a tree is never split by a house wall (whole-in or whole-out).
    ld b, 138
    call Hash8
    and 1
    add a, a
    add a, 6
    ld [wHW], a                 ; width 6 or 8
    ld b, 139
    call Hash8
    and 1
    add a, a
    add a, 6
    ld [wHH], a                 ; height 6 or 8
    ld b, 140
    call Hash8
    and 3
    add a, a
    add a, 2                    ; ox = 2,4,6,8
    ld c, a
    ld a, [wGenX]
    and 15                      ; lx
    sub c                       ; dx = lx - ox
    jp c, .none                 ; lx < ox
    ld [wHDX], a
    ld hl, wHW
    cp [hl]
    jp nc, .none                ; dx >= w
    ld b, 141
    call Hash8
    and 3
    add a, a
    add a, 2                    ; oy = 2,4,6,8
    ld c, a
    ld a, [wGenY]
    and 15                      ; ly
    sub c                       ; dy = ly - oy
    jp c, .none                 ; ly < oy
    ld [wHDY], a
    ld hl, wHH
    cp [hl]
    jp nc, .none                ; dy >= h
    ; inside the bbox: perimeter -> wall/door, interior -> floor
    ld a, [wHDX]
    and a, a
    jr z, .edge                 ; dx == 0
    ld a, [wHW]
    dec a
    ld hl, wHDX
    cp [hl]
    jr z, .edge                 ; dx == w-1
    ld a, [wHDY]
    and a, a
    jr z, .edge                 ; dy == 0
    ld a, [wHH]
    dec a
    ld hl, wHDY
    cp [hl]
    jr z, .edge                 ; dy == h-1
    ld a, TILE_FLOOR
    ret
.edge:
    ld a, [wHH]
    dec a
    ld hl, wHDY
    cp [hl]
    jr nz, .wall                ; not the bottom wall
    ld a, [wHW]
    srl a                       ; w >> 1
    ld hl, wHDX
    cp [hl]
    jr nz, .wall
    ld a, TILE_DOOR             ; bottom-centre doorway
    ret
.wall:
    ld a, TILE_WALL
    ret
.none:
    ld a, $FF
    ret

; ScatterHash: A = per-tile fine noise hash(wGenX, wGenY, 91).
ScatterHash:
    call LoadHfromGen
    ld b, 91
    jp Hash8                    ; tail call

; IsSolid: A = tile type -> Z if passable, NZ if solid. Preserves nothing much.
IsSolid::
    ld c, a
    ld b, 0
    ld hl, PassTable
    add hl, bc
    ld a, [hl]
    and a, a
    ret

; GenSolid: generate the tile at wGenX/wGenY and test it in one go — Z if
; passable, NZ if solid (A = the tile type, from IsSolid's lookup path). The
; (GenTileType -> IsSolid) pair every collision/spawn check used to inline.
GenSolid::
    call GenTileType
    jp IsSolid                  ; tail call

; -----------------------------------------------------------------------------
; Hash8: permutation-table value-noise hash. Reads wHX/wHY (16-bit LE, already
; coord-transformed by the caller) and a salt in B; returns the hash in A.
;   a = seed + salt
;   a = perm[(a + xl) & $FF] ; a = perm[(a + xh) & $FF]
;   a = perm[(a + yl) & $FF] ; a = perm[(a + yh) & $FF]
; PermTable is 256-byte aligned, so an index is just the low byte of HL.
; Clobbers A,C,L; preserves B,D,E. Mirror of worldgen_model.py:hash8.
; -----------------------------------------------------------------------------
Hash8:
    ldh a, [hWorldSeed]
    add a, b                    ; seed + salt
    ld h, HIGH(PermTable)
    ld c, a
    ld a, [wHX]                 ; + xl
    add a, c
    ld l, a
    ld a, [hl]
    ld c, a
    ld a, [wHX+1]               ; + xh
    add a, c
    ld l, a
    ld a, [hl]
    ld c, a
    ld a, [wHY]                 ; + yl
    add a, c
    ld l, a
    ld a, [hl]
    ld c, a
    ld a, [wHY+1]               ; + yh
    add a, c
    ld l, a
    ld a, [hl]
    ret

; wHX/wHY = wGenX/wGenY.
LoadHfromGen:
    ld a, [wGenX]
    ld [wHX], a
    ld a, [wGenX+1]
    ld [wHX+1], a
    ld a, [wGenY]
    ld [wHY], a
    ld a, [wGenY+1]
    ld [wHY+1], a
    ret

; wHX/wHY = wBiX/wBiY (the biome-sample anchor).
LoadHfromBi:
    ld a, [wBiX]
    ld [wHX], a
    ld a, [wBiX+1]
    ld [wHX+1], a
    ld a, [wBiY]
    ld [wHY], a
    ld a, [wBiY+1]
    ld [wHY+1], a
    ret

; wHX/wHY = wWX/wWY (the domain-warped coords).
LoadHfromW:
    ld a, [wWX]
    ld [wHX], a
    ld a, [wWX+1]
    ld [wHX+1], a
    ld a, [wWY]
    ld [wHY], a
    ld a, [wWY+1]
    ld [wHY+1], a
    ret

; ShiftH: wHX >>= 1 and wHY >>= 1 (logical, 16-bit LE). Clobbers HL (this is
; the hot inner helper of every noise field — called up to ~18x per generated
; tile, so it shifts in place instead of bouncing each byte through A).
ShiftH:
    ld hl, wHX+1
    srl [hl]
    dec hl
    rr [hl]
    ld hl, wHY+1
    srl [hl]
    dec hl
    rr [hl]
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
    ldh a, [hIsCGB]
    and a, a
    jr z, .noAttr               ; DMG has no attribute plane (bank 1) — skip it
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
    xor a, a
    ldh [rVBK], a              ; back to bank 0
.noAttr:
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
    xor a, a
    ld [wStrDone], a           ; nothing blitted yet
    inc a
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
; BlitStream: push up to BLIT_CHUNK quads of the queued strip into VRAM. Call
; once per VBlank; a whole strip is spread across a few VBlanks (see BLIT_CHUNK).
; Two passes over the chunk so VRAM banks flip once each, not per tile.
; -----------------------------------------------------------------------------
BlitStream::
    ld a, [wStrKind]
    and a, a
    ret z
    ; chunk = min(wStrLen - wStrDone, BLIT_CHUNK)
    ld a, [wStrLen]
    ld b, a
    ld a, [wStrDone]
    ld c, a                     ; c = done
    ld a, b
    sub c                       ; a = remaining (> 0 while kind set)
    cp BLIT_CHUNK
    jr c, .haveCount
    ld a, BLIT_CHUNK
.haveCount:
    ld d, a                     ; d = chunk count (preserved across passes)
    ; HL = wStrBuf + done*4  (done*4 <= 80, fits one byte)
    ld a, c
    add a, a
    add a, a
    ld c, a
    ld b, 0                     ; BC = done*4
    ld hl, wStrBuf
    add hl, bc
    ; pass 1 — tile ids into bank 0
    xor a, a
    ldh [rVBK], a
    push hl                     ; save chunk start for pass 2
    ld e, d                     ; e = loop counter
.p1:
    ld a, [hl+]                 ; addr low
    ld c, a
    ld a, [hl+]                 ; addr high
    ld b, a                     ; BC = VRAM address
    ld a, [hl+]                 ; tile
    ld [bc], a
    inc hl                      ; skip attr
    dec e
    jr nz, .p1
    pop hl                      ; chunk start
    ; pass 2 — attributes into bank 1 (CGB only; DMG has no attribute plane)
    ldh a, [hIsCGB]
    and a, a
    jr z, .noAttr
    ld a, 1
    ldh [rVBK], a
    ld e, d
.p2:
    ld a, [hl+]                 ; addr low
    ld c, a
    ld a, [hl+]                 ; addr high
    ld b, a
    inc hl                      ; skip tile
    ld a, [hl+]                 ; attr
    ld [bc], a
    dec e
    jr nz, .p2
    xor a, a
    ldh [rVBK], a              ; back to bank 0
.noAttr:
    ; done += chunk; clear pending when the whole strip is out
    ld a, [wStrDone]
    add a, d
    ld [wStrDone], a
    ld hl, wStrLen
    cp [hl]
    ret c                       ; more to blit next VBlank
    xor a, a
    ld [wStrKind], a
    ret

; -----------------------------------------------------------------------------
; Tables (index by tile type). Keep PassTable in sync with the model.
; -----------------------------------------------------------------------------
; Indexed by tile id. Ids 0..13 are the original terrain; 14..56 are OBJ/UI
; tiles that never appear as a BG map cell (filler here); 57..63 are the
; expansion-biome terrain (sand cactus snow ice grave wheat fence). Keep in
; sync with the model (worldgen_model.py) and PassTable in lockstep.
;              grass brush flowr dirt water road wall floor door marsh  TL TR BL BR
PassTable:  db   0,   0,    0,   0,   1,   0,   1,   0,   0,   0,   1, 1, 1, 1  ; 0..13 (1=solid)
            ds  43, 0                                                          ; 14..56 (OBJ/UI, never BG)
;              sand cactus snow ice grave wheat fence
            db   0,   1,    0,   1,   1,    0,    1                            ; 57..63
AttrTable:  db   0,   0,    0,   2,   1,   2,   2,   2,   2,   3,   0, 0, 0, 0  ; 0..13 BG palette
            ds  43, 0                                                          ; 14..56 filler
;              sand cactus snow ice grave wheat fence
            db   2,   0,    1,   1,   2,    0,    2                            ; 57..63

; -----------------------------------------------------------------------------
; PermTable: the 256-byte permutation that drives the value-noise hash (Hash8).
; The bytes live in src/gen/perm.inc — the single source shared with the Python
; reference model (worldgen_model.py parses the same file). Kept 256-byte aligned
; so a table index is just the low byte of HL.
; -----------------------------------------------------------------------------
SECTION "PermTable", ROM0, ALIGN[8]
PermTable:
    INCLUDE "gen/perm.inc"
