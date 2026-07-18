#!/usr/bin/env python3
"""Host-side reference model of the ROM's tile generator (src/world.asm).

Mirrors GenTileType / Hash8 *byte for byte* (same 8-bit ops, same thresholds,
same layering: water -> roads -> scatter). Purposes, per
docs/design/06-testing-and-memory-safety.md:

  * Layer-C differential testing seed (a headless emulator can later compare the
    ROM's map against this).
  * A no-emulator sanity check today: is the terrain mix what we intended, and
    is the player's start tile passable?

Keep in lockstep with src/world.asm. If the generator changes, change this too.
"""

WORLD_SEED = 0xA5
WATER_THRESH = 34

TILE_GRASS, TILE_BRUSH, TILE_TREE, TILE_WALL, TILE_WATER, TILE_ROAD = range(6)
SOLID = {TILE_TREE, TILE_WALL, TILE_WATER}

U8 = 0xFF
U16 = 0xFFFF


def swap_nibbles(a: int) -> int:
    return ((a << 4) | (a >> 4)) & U8


def hash8(x: int, y: int) -> int:
    """Mirror of Hash8: 8-bit avalanche of (xl,xh,yl,yh) + seed."""
    xl, xh = x & U8, (x >> 8) & U8
    yl, yh = y & U8, (y >> 8) & U8
    a = WORLD_SEED
    a = (a + xl) & U8
    a ^= yl
    h = a
    a = swap_nibbles(a)
    a = (a + xh) & U8
    a ^= yh
    a ^= h
    h = a
    a = swap_nibbles(a)
    a = (a + xl) & U8
    a ^= yl
    return a


def gen_tile_type(x: int, y: int) -> int:
    """Mirror of GenTileType. x,y are 16-bit world tile coords."""
    x &= U16
    y &= U16
    # water: coarse (>>2) noise
    if hash8((x >> 2) & U16, (y >> 2) & U16) < WATER_THRESH:
        return TILE_WATER
    # roads: 1-tile grid every 16 tiles
    if (x & 0x0F) == 0 or (y & 0x0F) == 0:
        return TILE_ROAD
    # scatter
    f = hash8(x, y)
    if f >= 248:
        return TILE_WALL
    if f >= 236:
        return TILE_TREE
    if f >= 222:
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


def main() -> int:
    names = {TILE_GRASS: "grass", TILE_BRUSH: "brush", TILE_TREE: "tree ",
             TILE_WALL: "wall ", TILE_WATER: "water", TILE_ROAD: "road "}
    counts = {t: 0 for t in names}
    N = 256  # sample a 256x256 region
    for y in range(N):
        for x in range(N):
            counts[gen_tile_type(x, y)] += 1
    total = N * N

    print(f"Sampled {N}x{N} = {total} tiles, seed=0x{WORLD_SEED:02X}")
    for t, n in counts.items():
        print(f"  {names[t]} : {n:6d}  ({100*n/total:5.1f}%)")

    ok = True
    passable = sum(counts[t] for t in (TILE_GRASS, TILE_BRUSH, TILE_ROAD))
    if passable < total * 0.5:
        print("FAIL: less than half the world is walkable"); ok = False
    for t in (TILE_WATER, TILE_ROAD):
        if counts[t] == 0:
            print(f"FAIL: no {names[t].strip()} generated at all"); ok = False

    sx, sy = find_start()
    st = gen_tile_type(sx, sy)
    print(f"Start tile: ({sx},{sy}) -> {names[st].strip()}")
    if st in SOLID:
        print("FAIL: start tile is solid"); ok = False

    if any(gen_tile_type(5, 9) != gen_tile_type(5, 9) for _ in range(1000)):
        print("FAIL: generator not deterministic"); ok = False

    print("PASS: generator model checks passed" if ok else "FAILURES above")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
