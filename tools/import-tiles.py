#!/usr/bin/env python3
# =============================================================================
# import-tiles.py — read img/tiles.png back and rewrite the tile art in
# src/gfx.asm in place.
#
# Only the 8 backtick digits of each tile row are replaced; every comment,
# label, palette and byte of spacing in gfx.asm is preserved. Each pixel is
# snapped to the nearest of the four canonical greys export-tiles.py wrote, so
# the round-trip is lossless: export then import is a no-op on gfx.asm, and
# import then export is a no-op on the PNG.
#
# The atlas must have exactly as many tiles as gfx.asm expects; if you added
# tiles, run export-tiles.py first (or after editing the PNG geometry, check
# TILE_BLOCKS in tools/tilepng.py). See CLAUDE.md for the maintenance rule.
#
#   python3 tools/import-tiles.py
# =============================================================================
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tilepng  # noqa: E402


def main():
    counts = tilepng.import_()
    names = [b[0] for b in tilepng.TILE_BLOCKS]
    for n, c in zip(names, counts):
        print(f"  {n:<14} {c:3d} tiles")
    print(f"updated {os.path.relpath(tilepng.GFX, tilepng.ROOT)} from "
          f"{os.path.relpath(tilepng.ATLAS, tilepng.ROOT)} ({sum(counts)} tiles)")


if __name__ == "__main__":
    main()
