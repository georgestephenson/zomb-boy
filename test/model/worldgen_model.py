#!/usr/bin/env python3
"""Host-side reference model of the ROM's tile generator.

This mirrors GenTileType in src/main.asm *byte for byte* (same 8-bit ops, same
thresholds). It serves two purposes described in
docs/design/06-testing-and-memory-safety.md:

  * Layer C differential testing — later, a headless emulator run will compare
    the ROM's generated map against this model over random coordinates.
  * A fast sanity check we can run today (no emulator needed): is the terrain
    distribution what we intended, and is the player's start tile passable?

Keep this in lockstep with the assembly. If GenTileType changes, change this.
"""

WORLD_SEED = 0xA5
WORLD_W = 32
WORLD_H = 32

TILE_GRASS, TILE_BRUSH, TILE_TREE, TILE_WALL = 0, 1, 2, 3
FIRST_SOLID = TILE_TREE  # tiles >= this block movement

U8 = 0xFF


def swap_nibbles(a: int) -> int:
    return ((a << 4) | (a >> 4)) & U8


def gen_tile_type(x: int, y: int) -> int:
    """Exact replica of GenTileType (B=x, C=y -> A)."""
    a = (x + WORLD_SEED) & U8      # add a, WORLD_SEED
    d = a                          # ld d, a
    a = (y + d) & U8               # ld a,c : add a,d
    a ^= d                         # xor a, d
    d = a                          # ld d, a
    a = swap_nibbles(a)            # swap a
    a ^= d                         # xor a, d
    a = (a + x) & U8               # add a, b
    a ^= y                         # xor a, c
    # thresholds
    if a < 200:
        return TILE_GRASS
    if a < 232:
        return TILE_BRUSH
    if a < 248:
        return TILE_TREE
    return TILE_WALL


def find_start(tx=WORLD_W // 2, ty=WORLD_H // 2):
    """Mirror InitPlayer: from centre, step right until a passable tile."""
    x = tx
    for _ in range(WORLD_W):  # bounded, like the ROM
        if gen_tile_type(x, ty) < FIRST_SOLID:
            return x, ty
        x = x + 1 if x + 1 < WORLD_W else 1
    return x, ty


def main() -> int:
    counts = {TILE_GRASS: 0, TILE_BRUSH: 0, TILE_TREE: 0, TILE_WALL: 0}
    for y in range(WORLD_H):
        for x in range(WORLD_W):
            counts[gen_tile_type(x, y)] += 1
    total = WORLD_W * WORLD_H

    names = {TILE_GRASS: "grass", TILE_BRUSH: "brush",
             TILE_TREE: "tree ", TILE_WALL: "wall "}
    print(f"World: {WORLD_W}x{WORLD_H} = {total} tiles, seed=0x{WORLD_SEED:02X}")
    for t, n in counts.items():
        print(f"  {names[t]} : {n:4d}  ({100*n/total:5.1f}%)")

    ok = True

    # 1. Mostly-open world: grass should dominate and solids stay a minority.
    passable = counts[TILE_GRASS] + counts[TILE_BRUSH]
    solid = counts[TILE_TREE] + counts[TILE_WALL]
    if passable < solid:
        print("FAIL: world is more solid than passable"); ok = False
    if counts[TILE_GRASS] < total * 0.5:
        print("FAIL: grass is less than half the world"); ok = False

    # 2. Player must start on a passable tile.
    sx, sy = find_start()
    st = gen_tile_type(sx, sy)
    print(f"Start tile: ({sx},{sy}) -> {names[st].strip()}")
    if st >= FIRST_SOLID:
        print("FAIL: start tile is solid"); ok = False

    # 3. Determinism: same coords twice -> same tile.
    if any(gen_tile_type(3, 7) != gen_tile_type(3, 7) for _ in range(1000)):
        print("FAIL: generator not deterministic"); ok = False

    print("PASS: generator model checks passed" if ok else "FAILURES above")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
