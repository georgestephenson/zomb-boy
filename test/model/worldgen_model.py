#!/usr/bin/env python3
"""Host-side reference model of the ROM's tile generator (src/world.asm).

Mirrors GenTileType *byte for byte*. Purposes, per
docs/design/06-testing-and-memory-safety.md:

  * Layer-C differential testing: the headless integration tests
    (test/integration/test_streaming.py) compare the ROM's rendered tilemap
    against gen_tile_type() after walking across biomes. If this model and the
    asm diverge, those tests fail — that's the lockstep guard.
  * A no-emulator sanity check: is the terrain/biome mix what we intended, and
    is the player's start tile passable?

Generator design (keep in lockstep with src/world.asm — change both together):

  * Hash8 is a permutation-table value-noise hash (PERM). Five table lookups,
    seeded by (WORLD_SEED + salt). No directional (diagonal) bias.
  * A coarse, domain-warped BIOME field (~64-tile cells) carves the world into
    city / plains / forest / marsh. Each biome sets which features appear and
    how dense — so water clusters in marsh, roads+houses in city, trees in
    forest, instead of uniform noise everywhere.
  * Shared feature fields (water, 2x2 trees) are computed once and thresholded
    per biome. Roads (a meandering 16-grid) and houses are city-only.
"""

DEFAULT_SEED = 0xA5      # the "classic" seed (WORLD_SEED in constants.inc);
                         # SELECT+START on the title screen forces it in-game
WORLD_SEED = DEFAULT_SEED


def set_seed(seed: int) -> None:
    """Reseed the model. The integration harness calls this with the ROM's
    actual hWorldSeed so tilemap comparisons are seed-agnostic."""
    global WORLD_SEED
    WORLD_SEED = seed & 0xFF

# --- tile ids (also the VRAM tile index for background tiles) ---------------
TILE_GRASS, TILE_BRUSH, TILE_FLOWER, TILE_DIRT = 0, 1, 2, 3
TILE_WATER, TILE_ROAD, TILE_WALL, TILE_FLOOR = 4, 5, 6, 7
TILE_DOOR, TILE_MARSH = 8, 9
TILE_TREE_TL, TILE_TREE_TR, TILE_TREE_BL, TILE_TREE_BR = 10, 11, 12, 13
# Expansion-biome BG terrain tiles (ids 57..63; see constants.inc).
TILE_SAND, TILE_CACTUS, TILE_SNOW, TILE_ICE = 57, 58, 59, 60
TILE_GRAVE, TILE_WHEAT, TILE_FENCE = 61, 62, 63
SOLID = {TILE_WATER, TILE_WALL,
         TILE_TREE_TL, TILE_TREE_TR, TILE_TREE_BL, TILE_TREE_BR,
         TILE_CACTUS, TILE_ICE, TILE_GRAVE, TILE_FENCE}

# --- biome ids --------------------------------------------------------------
BIOME_CITY, BIOME_PLAINS, BIOME_FOREST, BIOME_MARSH = 0, 1, 2, 3
BIOME_RUINS, BIOME_FARM, BIOME_JUNGLE = 4, 5, 6
BIOME_GRAVEYARD, BIOME_DESERT, BIOME_MOUNTAINS, BIOME_TUNDRA = 7, 8, 9, 10

# --- per-biome tuning (must equal the constants.inc / world.asm literals) ----
WATER_MARSH, WATER_FOREST, WATER_PLAINS = 116, 24, 20
WATER_TUNDRA = 20
TREE_FOREST, TREE_MARSH, TREE_PLAINS = 176, 236, 248
TREE_JUNGLE, TREE_GRAVE, TREE_TUNDRA, TREE_MTN = 176, 250, 246, 240

U8 = 0xFF
U16 = 0xFFFF


def _load_perm():
    """Parse the 256-byte permutation from src/gen/perm.inc — the SAME file the
    ROM INCLUDEs (src/world.asm:PermTable). One source of truth, no copy."""
    import os
    import re
    path = os.path.join(os.path.dirname(__file__), "..", "..",
                        "src", "gen", "perm.inc")
    with open(path) as f:
        text = f.read()
    perm = [int(b, 16) for b in re.findall(r"\$([0-9A-Fa-f]{2})", text)]
    assert len(perm) == 256, f"perm.inc has {len(perm)} bytes, expected 256"
    return perm


PERM = _load_perm()


def hash8(x: int, y: int, salt: int) -> int:
    """Mirror of Hash8: perm-table value noise of (x16, y16) + seed + salt."""
    a = (WORLD_SEED + salt) & U8
    a = PERM[(a + (x & U8)) & U8]
    a = PERM[(a + ((x >> 8) & U8)) & U8]
    a = PERM[(a + (y & U8)) & U8]
    a = PERM[(a + ((y >> 8) & U8)) & U8]
    return a


def biome(x: int, y: int) -> int:
    """Mirror of CalcBiome: coarse domain-warped field on ~64-tile cells."""
    wx = (x + (hash8((x >> 3) & U16, (y >> 3) & U16, 60) & 15)) & U16
    wy = (y + (hash8((x >> 3) & U16, (y >> 3) & U16, 61) & 15)) & U16
    b = hash8((wx >> 6) & U16, (wy >> 6) & U16, 70)
    # 11 bands over the 0..255 field. City/ruins share the low end (they share
    # the road grid); forest/jungle keep the high-but-below-marsh band so the
    # classic seed's spawn (field value 195) stays FOREST as it always was — the
    # reproducible test world, and a feature-rich start; marsh holds the wet top
    # so its water still dominates the world's water (the clustering check).
    if b < 24:
        return BIOME_CITY
    if b < 44:
        return BIOME_RUINS
    if b < 76:
        return BIOME_PLAINS
    if b < 96:
        return BIOME_FARM
    if b < 118:
        return BIOME_DESERT
    if b < 138:
        return BIOME_MOUNTAINS
    if b < 156:
        return BIOME_TUNDRA
    if b < 174:
        return BIOME_GRAVEYARD
    if b < 194:
        return BIOME_JUNGLE
    if b < 212:
        return BIOME_FOREST
    return BIOME_MARSH


def water_field(x: int, y: int) -> int:
    """Mirror of WaterField: domain-warped two-octave coarse noise; lower=wetter."""
    wx = (x + (hash8((x >> 1) & U16, (y >> 1) & U16, 11) & 7)) & U16
    wy = (y + (hash8((x >> 1) & U16, (y >> 1) & U16, 47) & 7)) & U16
    a = hash8((wx >> 2) & U16, (wy >> 2) & U16, 3)
    b = hash8((wx >> 3) & U16, (wy >> 3) & U16, 5)
    return (a + b) >> 1


def tree_tile(x: int, y: int, thresh: int):
    """Mirror of TreeQuad: a 2x2 tree anchored on the block of (x,y), or None.
    All four cells of a block share the anchor hash, so a tree is never split."""
    if hash8((x >> 1) & U16, (y >> 1) & U16, 71) >= thresh:
        return TILE_TREE_TL + (y & 1) * 2 + (x & 1)
    return None


def road_here(x: int, y: int) -> bool:
    """Mirror of RoadHere. Avenues are full-length straight vertical lines (one
    per 16-wide band, column jittered 0..7 by the band index) — the connected
    backbone. Cross-streets are horizontal but JOG: a street's row is jittered
    per *avenue-interval*, so it steps up/down each time it crosses an avenue,
    producing bends and T-junctions. Crucially the jog happens exactly AT an
    avenue, and the full-length avenue bridges the two different-row segments —
    so every street segment has both ends on an avenue and the whole network
    stays connected. The ruins biome reuses this and cracks it."""
    k = (x >> 4) & U16
    jit_k = hash8(k, 0, 21) & 7
    xlow = x & 0x0F
    if xlow == jit_k:
        return True                                   # on the vertical avenue
    # which avenue-interval is x in? (the avenue at/left of x identifies it)
    kL = k if xlow > jit_k else (k - 1) & U16
    if (y & 0x0F) == (hash8(kL, (y >> 4) & U16, 22) & 7):
        return True                                   # on the jogging cross-street
    # dead-end spurs / cul-de-sacs: a short residential stub branching RIGHT off
    # this band's avenue, entirely within the band (so it only needs this band's
    # jitter). It touches the avenue at d==1, so it always connects; the far end
    # just stops (dead-end), or for a cul-de-sac widens to a 3-tall turnaround.
    if xlow > jit_k:
        h = hash8(k, (y >> 4) & U16, 23)
        if (h & 3) == 0:                              # ~1/4 of (avenue, row-band) slots
            sr = 3 + ((h >> 2) & 7)                   # spur row within the band (3..10)
            length = 2 + ((h >> 5) & 3)               # 2..5 tiles long
            cul = (h >> 7) & 1
            yl = y & 0x0F
            d = xlow - jit_k                          # tiles right of the avenue (>=1)
            if yl == sr and d <= length:
                return True                           # the spur itself
            if cul and d == length and (yl == sr - 1 or yl == sr + 1):
                return True                           # cul-de-sac turnaround head
    return False


def house_tile(x: int, y: int):
    """Mirror of HouseTile: one optional building per 16x16 chunk, or None."""
    cx, cy = (x >> 4) & U16, (y >> 4) & U16
    lx, ly = x & 15, y & 15
    if hash8(cx, cy, 137) < 128:          # ~50% of city chunks have a house
        return None
    # Footprint offset+size are kept EVEN so every edge lands on a 2x2 tree-block
    # boundary -> a tree block is wholly inside (all wall) or wholly outside (whole
    # tree) the house, never split in half. Bounds stay within the 0..15 chunk.
    w = 6 + 2 * (hash8(cx, cy, 138) & 1)   # 6 or 8
    h = 6 + 2 * (hash8(cx, cy, 139) & 1)   # 6 or 8
    ox = 2 + 2 * (hash8(cx, cy, 140) & 3)  # 2,4,6,8
    dx = (lx - ox) & U8
    if dx >= w:
        return None
    oy = 2 + 2 * (hash8(cx, cy, 141) & 3)  # 2,4,6,8
    dy = (ly - oy) & U8
    if dy >= h:
        return None
    if dx == 0 or dx == w - 1 or dy == 0 or dy == h - 1:   # perimeter wall
        if dy == h - 1 and dx == (w >> 1):                 # door at bottom-centre
            return TILE_DOOR
        return TILE_WALL
    return TILE_FLOOR


def _scatter(x, y):
    return hash8(x & U16, y & U16, 91)


# --- per-biome ground generators (each mirrors a Gen* routine in world.asm) --
# Trees/water are keyed on the *block* biome so a 2x2 feature never straddles a
# biome edge; each function is self-contained (its own trees/water/scatter).

def _gen_plains(x, y, f):
    t = tree_tile(x, y, TREE_PLAINS)
    if t is not None:
        return t
    if water_field(x, y) < WATER_PLAINS:
        return TILE_WATER
    if f >= 246:
        return TILE_FLOWER
    if f >= 232:
        return TILE_BRUSH
    return TILE_GRASS


def _gen_forest(x, y, f):
    t = tree_tile(x, y, TREE_FOREST)
    if t is not None:
        return t
    if water_field(x, y) < WATER_FOREST:
        return TILE_WATER
    if f >= 150:
        return TILE_BRUSH
    return TILE_GRASS


def _gen_marsh(x, y, f):
    t = tree_tile(x, y, TREE_MARSH)
    if t is not None:
        return t
    if water_field(x, y) < WATER_MARSH:
        return TILE_WATER
    if f >= 205:
        return TILE_BRUSH             # reeds
    return TILE_MARSH


def _gen_city(x, y, f):
    if road_here(x, y):
        return TILE_ROAD
    if f >= 250:
        return TILE_WALL              # rubble
    if f >= 230:
        return TILE_GRASS             # weed patch
    if f >= 215:
        return TILE_BRUSH
    return TILE_DIRT


def _gen_ruins(x, y, f):
    if road_here(x, y):
        if f >= 105:
            return TILE_ROAD          # ~59% of the street still holds
        if f >= 60:
            return TILE_WALL          # collapsed into rubble
        return TILE_DIRT              # cracked to bare dirt
    if f >= 240:
        return TILE_WALL              # scattered rubble
    if f >= 215:
        return TILE_BRUSH             # weeds through the cracks
    if f >= 140:
        return TILE_DIRT
    return TILE_GRASS


def _gen_farm(x, y, f):
    if (x & 7) == 0 and (y & 7) == 0:
        return TILE_FENCE            # corner post: never a gap, so a fence-line
                                     # gap always has a walkable field neighbour
    if (x & 7) == 0 or (y & 7) == 0:
        if (f & 3) == 0:
            return TILE_DIRT          # a gate/gap keeps fields crossable
        return TILE_FENCE
    if f >= 128:
        return TILE_WHEAT
    return TILE_DIRT                  # tilled soil


def _gen_jungle(x, y, f):
    t = tree_tile(x, y, TREE_JUNGLE)
    if t is not None:
        return t
    if f >= 90:
        return TILE_BRUSH             # heavy undergrowth / vines
    return TILE_GRASS


def _gen_graveyard(x, y, f):
    t = tree_tile(x, y, TREE_GRAVE)
    if t is not None:
        return t
    if f >= 235:
        return TILE_GRAVE
    if f >= 205:
        return TILE_BRUSH             # dead weeds
    return TILE_GRASS


def _gen_desert(x, y, f):
    if f >= 248:
        return TILE_WALL              # the odd rock/mesa
    if f >= 234:
        return TILE_CACTUS
    if f >= 216:
        return TILE_BRUSH             # dry scrub
    return TILE_SAND


def _gen_mountains(x, y, f):
    t = tree_tile(x, y, TREE_MTN)
    if t is not None:
        return t
    if f >= 210:
        return TILE_WALL              # rocky outcrop
    if f >= 150:
        return TILE_DIRT              # stony ground
    if f >= 90:
        return TILE_GRASS             # alpine meadow
    return TILE_DIRT


def _gen_tundra(x, y, f):
    t = tree_tile(x, y, TREE_TUNDRA)
    if t is not None:
        return t
    if water_field(x, y) < WATER_TUNDRA:
        return TILE_ICE               # frozen pond
    if f >= 240:
        return TILE_WALL              # boulder
    return TILE_SNOW


_BIOME_GEN = {
    BIOME_CITY: _gen_city, BIOME_PLAINS: _gen_plains, BIOME_FOREST: _gen_forest,
    BIOME_MARSH: _gen_marsh, BIOME_RUINS: _gen_ruins, BIOME_FARM: _gen_farm,
    BIOME_JUNGLE: _gen_jungle, BIOME_GRAVEYARD: _gen_graveyard,
    BIOME_DESERT: _gen_desert, BIOME_MOUNTAINS: _gen_mountains,
    BIOME_TUNDRA: _gen_tundra,
}


def gen_tile_type(x: int, y: int) -> int:
    """Mirror of GenTileType. x,y are 16-bit world tile coords.

    Multi-tile features are decided from a *consistent anchor* so they never get
    clipped: buildings gate on the 16x16 CHUNK's biome (whole footprint agrees),
    terrain/trees use the 2x2 BLOCK's biome, and trees are placed *before* water
    so a pond can't bite a quadrant out of a tree.
    """
    x &= U16
    y &= U16

    # 1) buildings — a tile shows a building iff it is inside a footprint AND its
    #    chunk's biome is city (a house) or graveyard (a church). Test the (cheap)
    #    footprint first so the costlier chunk-biome lookup only runs inside one.
    ht = house_tile(x, y)
    if ht is not None:
        cb = biome((x & ~15) & U16, (y & ~15) & U16)
        # A graveyard church always stands (no roads there). A city building
        # yields to any avenue the jittered street grid runs through it, so the
        # road network stays connected.
        if cb == BIOME_GRAVEYARD or (cb == BIOME_CITY and not road_here(x, y)):
            return ht

    # 2) terrain biome sampled at the 2x2 block anchor (imperceptibly coarser
    #    than per-cell at 64-tile biome scale, but keeps trees whole)
    bb = biome((x & ~1) & U16, (y & ~1) & U16)
    return _BIOME_GEN[bb](x, y, _scatter(x, y))


def find_start():
    """Mirror InitPlayer: from (0,0), step +X to the first passable tile."""
    x = 0
    for _ in range(64):
        if gen_tile_type(x, 0) not in SOLID:
            return x, 0
        x += 1
    return x, 0


def check_seed(seed: int) -> int:
    """The full statistical + invariant check at one seed (a 256x256 sample)."""
    set_seed(seed)
    names = {TILE_GRASS: "grass", TILE_BRUSH: "brush", TILE_FLOWER: "flower",
             TILE_DIRT: "dirt ", TILE_WATER: "water", TILE_ROAD: "road ",
             TILE_WALL: "wall ", TILE_FLOOR: "floor", TILE_DOOR: "door ",
             TILE_MARSH: "marsh", TILE_TREE_TL: "treeTL", TILE_TREE_TR: "treeTR",
             TILE_TREE_BL: "treeBL", TILE_TREE_BR: "treeBR",
             TILE_SAND: "sand ", TILE_CACTUS: "cactus", TILE_SNOW: "snow ",
             TILE_ICE: "ice  ", TILE_GRAVE: "grave", TILE_WHEAT: "wheat",
             TILE_FENCE: "fence"}
    bnames = {BIOME_CITY: "city", BIOME_PLAINS: "plains",
              BIOME_FOREST: "forest", BIOME_MARSH: "marsh",
              BIOME_RUINS: "ruins", BIOME_FARM: "farm", BIOME_JUNGLE: "jungle",
              BIOME_GRAVEYARD: "grave", BIOME_DESERT: "desert",
              BIOME_MOUNTAINS: "mtn", BIOME_TUNDRA: "tundra"}
    counts = {t: 0 for t in names}
    bcounts = {b: 0 for b in bnames}
    N = 256  # sample a 256x256 region
    for y in range(N):
        for x in range(N):
            counts[gen_tile_type(x, y)] += 1
            bcounts[biome(x, y)] += 1
    total = N * N

    print(f"Sampled {N}x{N} = {total} tiles, seed=0x{WORLD_SEED:02X}")
    print("  biomes: " + "  ".join(
        f"{bnames[b]} {100*bcounts[b]/total:.0f}%" for b in bnames))
    for t, n in counts.items():
        print(f"  {names[t]:6s} : {n:6d}  ({100*n/total:5.1f}%)")

    ok = True
    walkable = sum(counts[t] for t in counts if t not in SOLID)
    if walkable < total * 0.5:
        print("FAIL: less than half the world is walkable"); ok = False
    for t in (TILE_WATER, TILE_ROAD):
        if counts[t] == 0:
            print(f"FAIL: no {names[t].strip()} generated at all"); ok = False
    # water must actually cluster in marsh, not be uniform noise
    marsh_water = sum(1 for y in range(N) for x in range(N)
                      if biome(x, y) == BIOME_MARSH and gen_tile_type(x, y) == TILE_WATER)
    if counts[TILE_WATER] and marsh_water / counts[TILE_WATER] < 0.5:
        print("FAIL: most water is not in marsh (biome clustering broken)"); ok = False

    sx, sy = find_start()
    st = gen_tile_type(sx, sy)
    print(f"Start tile: ({sx},{sy}) -> {names[st].strip()}")
    if st in SOLID:
        print("FAIL: start tile is solid"); ok = False

    if any(gen_tile_type(5, 9) != gen_tile_type(5, 9) for _ in range(1000)):
        print("FAIL: generator not deterministic"); ok = False

    print("PASS: generator model checks passed" if ok else "FAILURES above")
    return 0 if ok else 1


def sweep(n: int = 48) -> int:
    """Exhaustive reliability check: the in-game seed is one byte, so EVERY
    possible world can be vetted. Per seed this runs cheaper invariants than
    check_seed (which does the full statistics at one seed): the boot spawn
    scan must land on a passable tile that isn't boxed in (>=1 walkable
    4-neighbour to actually step to), the spawn neighbourhood must not be
    degenerate (boxed in by solids), and the biome field must actually vary.
    """
    bad = []
    for seed in range(256):
        set_seed(seed)
        sx, sy = find_start()
        if gen_tile_type(sx, sy) in SOLID:
            bad.append((seed, "boot spawn scan found no passable tile"))
            continue
        # The player moves orthogonally, so a passable start tile is useless if
        # every 4-neighbour is solid (the farm fence-intersection trap): the
        # spawn must have somewhere to step.
        if all(gen_tile_type(sx + dx, sy + dy) in SOLID
               for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))):
            bad.append((seed, "spawn boxed in: all 4 neighbours solid"))
            continue
        total = n * n
        walkable = sum(1 for y in range(n) for x in range(n)
                       if gen_tile_type(x, y) not in SOLID)
        if walkable < total // 4:
            bad.append((seed, f"spawn area only {100*walkable//total}% walkable"))
        biomes = {biome(x * 48, y * 48) for x in range(12) for y in range(12)}
        if len(biomes) < 2:
            bad.append((seed, "biome field is constant over a 576-tile span"))
    set_seed(DEFAULT_SEED)
    if bad:
        for seed, why in bad:
            print(f"FAIL: seed 0x{seed:02X}: {why}")
        return 1
    print(f"PASS: all 256 seeds ok (spawn passable, >=25% walkable in the "
          f"{n}x{n} spawn area, biomes vary)")
    return 0


def main(argv) -> int:
    assert sorted(PERM) == list(range(256)), "PERM is not a permutation of 0..255"
    seed = DEFAULT_SEED
    do_sweep = True
    args = list(argv)
    while args:
        a = args.pop(0)
        if a == "--seed":                 # full check at one specific seed
            seed = int(args.pop(0), 0)
            do_sweep = False
        elif a == "--no-sweep":
            do_sweep = False
        else:
            print(f"usage: worldgen_model.py [--seed N] [--no-sweep]")
            return 2
    rc = check_seed(seed)
    if do_sweep:
        rc |= sweep()
    return rc


if __name__ == "__main__":
    import sys
    raise SystemExit(main(sys.argv[1:]))
