#!/usr/bin/env python3
# =============================================================================
# export-tiles.py — render every 8x8 tile in src/gfx.asm into one PNG atlas
# (img/tiles.png) you can edit in any pixel editor.
#
# Each tile is drawn at native 1:1 (8x8 px) as four greys = the 2bpp colour
# indices; zoom with nearest-neighbour to edit. Tiles are packed 16 per row,
# each gfx.asm block (Tiles, then PersonaTiles) starting on a fresh row.
#
# Round-trips with import-tiles.py — export then import leaves gfx.asm
# byte-identical. See tools/tilepng.py for the shared logic and the exact tile
# set covered (and CLAUDE.md for the maintenance rule).
#
#   python3 tools/export-tiles.py
# =============================================================================
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tilepng  # noqa: E402


def main():
    counts = tilepng.export()
    names = [b[0] for b in tilepng.TILE_BLOCKS]
    _, grid_rows = tilepng.layout(counts)
    for n, c in zip(names, counts):
        print(f"  {n:<14} {c:3d} tiles")
    print(f"wrote {os.path.relpath(tilepng.ATLAS, tilepng.ROOT)}  "
          f"({sum(counts)} tiles, "
          f"{tilepng.COLS * tilepng.TILE}x{grid_rows * tilepng.TILE} px)")


if __name__ == "__main__":
    main()
