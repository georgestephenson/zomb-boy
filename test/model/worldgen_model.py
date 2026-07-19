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
SOLID = {TILE_WATER, TILE_WALL,
         TILE_TREE_TL, TILE_TREE_TR, TILE_TREE_BL, TILE_TREE_BR}

# --- biome ids --------------------------------------------------------------
BIOME_CITY, BIOME_PLAINS, BIOME_FOREST, BIOME_MARSH = 0, 1, 2, 3

# --- per-biome tuning (must equal the constants.inc / world.asm literals) ----
WATER_MARSH, WATER_FOREST, WATER_PLAINS = 116, 24, 20
TREE_FOREST, TREE_MARSH, TREE_PLAINS = 176, 236, 248

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
    if b < 64:
        return BIOME_CITY       # ~25%
    if b < 160:
        return BIOME_PLAINS     # ~37%
    if b < 212:
        return BIOME_FOREST     # ~20%
    return BIOME_MARSH          # ~17%


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


# Per-biome feature thresholds keyed by biome id (None = biome has no such
# feature). Trees/water are decided from the *block* biome so a 2x2 tree never
# straddles a biome edge; city has neither.
_TREE_THRESH = {BIOME_FOREST: TREE_FOREST, BIOME_MARSH: TREE_MARSH,
                BIOME_PLAINS: TREE_PLAINS}
_WATER_THRESH = {BIOME_FOREST: WATER_FOREST, BIOME_MARSH: WATER_MARSH,
                 BIOME_PLAINS: WATER_PLAINS}


def road_here(x: int, y: int) -> bool:
    """Mirror of RoadHere: a 16-tile grid whose lines wobble by a small offset."""
    if ((x + (hash8(0, (y >> 3) & U16, 21) & 3)) & 0x0F) == 0:
        return True
    if ((y + (hash8((x >> 3) & U16, 0, 22) & 3)) & 0x0F) == 0:
        return True
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


def gen_tile_type(x: int, y: int) -> int:
    """Mirror of GenTileType. x,y are 16-bit world tile coords.

    Multi-tile features are decided from a *consistent anchor* so they never get
    clipped: houses gate on the 16x16 CHUNK's biome (whole footprint agrees),
    terrain/trees use the 2x2 BLOCK's biome, and trees are placed *before* water
    so a pond can't bite a quadrant out of a tree.
    """
    x &= U16
    y &= U16

    # 1) houses — a tile shows a house iff it is inside a footprint AND its
    #    chunk's biome is city. Test the (cheap) footprint first so the costlier
    #    chunk-biome lookup only runs for the ~3% of tiles inside a building.
    ht = house_tile(x, y)
    if ht is not None and biome((x & ~15) & U16, (y & ~15) & U16) == BIOME_CITY:
        return ht

    # 2) terrain biome sampled at the 2x2 block anchor (imperceptibly coarser
    #    than per-cell at 64-tile biome scale, but keeps trees whole)
    bb = biome((x & ~1) & U16, (y & ~1) & U16)

    if bb == BIOME_CITY:
        if road_here(x, y):
            return TILE_ROAD
        f = _scatter(x, y)
        if f >= 250:
            return TILE_WALL          # rubble
        if f >= 230:
            return TILE_GRASS         # weed patch
        if f >= 215:
            return TILE_BRUSH
        return TILE_DIRT

    # 3) trees (before water), then water — both keyed on the block biome
    t = tree_tile(x, y, _TREE_THRESH[bb])
    if t is not None:
        return t
    if water_field(x, y) < _WATER_THRESH[bb]:
        return TILE_WATER

    # 4) per-biome ground scatter
    f = _scatter(x, y)
    if bb == BIOME_MARSH:
        if f >= 205:
            return TILE_BRUSH         # reeds
        return TILE_MARSH
    if bb == BIOME_FOREST:
        if f >= 150:
            return TILE_BRUSH
        return TILE_GRASS
    if f >= 246:
        return TILE_FLOWER
    if f >= 232:
        return TILE_BRUSH
    return TILE_GRASS


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
             TILE_TREE_BL: "treeBL", TILE_TREE_BR: "treeBR"}
    bnames = {BIOME_CITY: "city", BIOME_PLAINS: "plains",
              BIOME_FOREST: "forest", BIOME_MARSH: "marsh"}
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
    scan must land on a passable tile, the spawn neighbourhood must not be
    degenerate (boxed in by solids), and the biome field must actually vary.
    """
    bad = []
    for seed in range(256):
        set_seed(seed)
        sx, sy = find_start()
        if gen_tile_type(sx, sy) in SOLID:
            bad.append((seed, "boot spawn scan found no passable tile"))
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
