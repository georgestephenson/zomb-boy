#!/usr/bin/env python3
# =============================================================================
# import-tiles.py — read img/tiles.png back and rewrite the tile art (and any
# swapped palette colours) in src/gfx.asm in place.
#
# Only the pixel digits/bytes of each tile and the palette expressions that
# actually changed are rewritten; every comment, label and byte of spacing is
# preserved. Pixels painted with an existing palette colour update the 2bpp
# indices; a colour painted in a BRAND-NEW colour (uniformly over one palette
# slot) updates that BGPalette/OBJPalette entry instead. The round-trip is
# lossless: export then import is a no-op on gfx.asm, import then export a no-op
# on the PNG.
#
# Validation aborts (leaving gfx.asm untouched) on an inconsistent edit — a stray
# colour, a slot recoloured non-uniformly across tiles that share it, collapsing
# two palette colours into one, or a non-1bpp colour in a font glyph. See
# tools/tilepng.py for the exact rules and CLAUDE.md for the maintenance rule.
#
#   python3 tools/import-tiles.py
# =============================================================================
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tilepng  # noqa: E402


def main():
    counts, changed = tilepng.import_()
    names = [b[0] for b in tilepng.TILE_BLOCKS]
    for n, c in zip(names, counts):
        print(f"  {n:<14} {c:3d} tiles")
    if changed:
        print(f"palette colours updated ({len(changed)}):")
        for (kind, num), slot in changed:
            print(f"  {kind}{num} slot {slot}")
    else:
        print("no palette colours changed")
    print(f"updated {os.path.relpath(tilepng.GFX, tilepng.ROOT)} from "
          f"{os.path.relpath(tilepng.ATLAS, tilepng.ROOT)} ({sum(counts)} tiles)")


if __name__ == "__main__":
    main()
