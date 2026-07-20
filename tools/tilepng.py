#!/usr/bin/env python3
# =============================================================================
# tilepng.py — shared logic for the tile export/import round-trip tools.
#
# The game's 8x8 tile ART lives in src/gfx.asm as RGBDS backtick `dw` literals:
# one digit (0-3) per pixel = a 2bpp colour INDEX. The index is palette-
# independent — the actual on-screen colour is chosen per tile at runtime via the
# CGB palettes — so a tile is really an 8x8 grid of indices. Two labelled blocks
# hold every such tile, in id order:
#     Tiles::        ... TilesEnd::         BG world + player/zombie/UI sprites
#     PersonaTiles:: ... PersonaTilesEnd::  survivor personas + car + loot
#
# tools/export-tiles.py renders those tiles into one PNG atlas (img/tiles.png);
# tools/import-tiles.py reads the atlas back and rewrites the `dw` lines.
#
# The round-trip is IDEMPOTENT in both directions:
#   * import edits ONLY the 8 backtick digits of each tile row and leaves every
#     comment, label, blank line and byte of spacing untouched — gfx.asm is used
#     as its own structural template, so export|import is a no-op on gfx.asm;
#   * export writes the four canonical greys below and import snaps each pixel to
#     the nearest of them, so import|export is a no-op on the PNG.
#
# NOT covered (a different format / not tiles, intentionally out of scope): the
# 1bpp `Font1bpp` glyphs and the CGB colour palettes (BGPalette / OBJPalette).
#
# MAINTENANCE: adding tiles WITHIN an existing block needs no change here — just
# re-run export-tiles.py. Adding a NEW block of backtick tile art (a fresh
# `Foo::` / `FooEnd::` label pair) means appending it to TILE_BLOCKS below, so
# the tools keep covering every tile. See CLAUDE.md ("Adding things").
#
# Dev tool, host-only, needs Pillow. The ROM build never invokes it.
# =============================================================================
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GFX = os.path.join(ROOT, "src", "gfx.asm")
ATLAS = os.path.join(ROOT, "img", "tiles.png")

# (start label, end label) of every backtick-`dw` tile-art block, in the order
# they appear in gfx.asm. The atlas lays the blocks out in THIS order.
TILE_BLOCKS = [
    ("Tiles", "TilesEnd"),
    ("PersonaTiles", "PersonaTilesEnd"),
]

COLS = 16   # tiles per atlas row; each block starts on a fresh row
TILE = 8    # px per tile edge

# 2bpp index 0..3 -> canonical grey (light..dark). Index 0 reads lightest so the
# atlas resembles the in-game art (palette 0's index 0 is the pale grass/skin
# colour). This is purely a VIEWING convention — the stored quantity is the
# index; import snaps each pixel to the nearest of these greys to recover it.
GREYS = [(255, 255, 255), (170, 170, 170), (85, 85, 85), (0, 0, 0)]

_ROW_RE = re.compile(r"^(\s*dw\s+`)([0-3]{8})(.*)$")
_LABEL_RE = re.compile(r"^(\w+)::")


def _labels():
    starts = {b[0] for b in TILE_BLOCKS}
    ends = {b[1] for b in TILE_BLOCKS}
    return starts, ends


def load_lines():
    with open(GFX, "r") as f:
        # keepends=False; we re-join with "\n". gfx.asm uses LF and ends in one.
        return f.read().split("\n")


def parse_tiles(lines):
    """Return {block_name: [tile, ...]} where tile = [row0..row7] and each row is
    a list of 8 ints (0-3), in source order (== atlas order)."""
    starts, ends = _labels()
    rows = {b[0]: [] for b in TILE_BLOCKS}
    cur = None
    for ln in lines:
        lbl = _LABEL_RE.match(ln)
        if lbl:
            name = lbl.group(1)
            if name in starts:
                cur = name
            elif name in ends:
                cur = None
            continue
        if cur is not None:
            m = _ROW_RE.match(ln)
            if m:
                rows[cur].append([int(ch) for ch in m.group(2)])
    blocks = {}
    for name, rlist in rows.items():
        if not rlist:
            raise SystemExit(f"tilepng: found no `dw` tile rows in block {name}::"
                             f" — is it still in {os.path.relpath(GFX, ROOT)}?")
        if len(rlist) % 8:
            raise SystemExit(f"tilepng: block {name}:: has {len(rlist)} rows,"
                             f" not a multiple of 8")
        blocks[name] = [rlist[i:i + 8] for i in range(0, len(rlist), 8)]
    return blocks


def rewrite_tiles(lines, new_blocks):
    """Return new gfx.asm text with each block's backtick `dw` digits replaced by
    new_blocks[name] (same shape parse_tiles returns). Everything else is byte-
    for-byte preserved — only the 8 digits between the backtick and end of each
    tile row change."""
    starts, ends = _labels()
    flat = {n: [row for tile in tiles for row in tile]
            for n, tiles in new_blocks.items()}
    idx = {n: 0 for n in flat}
    cur = None
    out = []
    for ln in lines:
        lbl = _LABEL_RE.match(ln)
        if lbl:
            name = lbl.group(1)
            if name in starts:
                cur = name
            elif name in ends:
                cur = None
            out.append(ln)
            continue
        if cur is not None:
            m = _ROW_RE.match(ln)
            if m:
                row = flat[cur][idx[cur]]
                idx[cur] += 1
                out.append(m.group(1) + "".join(str(v) for v in row) + m.group(3))
                continue
        out.append(ln)
    for n in flat:
        if idx[n] != len(flat[n]):
            raise SystemExit(f"tilepng: block {n}:: consumed {idx[n]} of "
                             f"{len(flat[n])} rows — layout mismatch")
    return "\n".join(out)


def layout(counts):
    """Deterministic atlas geometry from per-block tile counts (order == TILE_BLOCKS).
    Returns (placements, grid_rows); placement = (block_idx, tile_idx, col, row)."""
    placements = []
    row0 = 0
    for bi, cnt in enumerate(counts):
        for ti in range(cnt):
            placements.append((bi, ti, ti % COLS, row0 + ti // COLS))
        row0 += (cnt + COLS - 1) // COLS
    return placements, row0


def _nearest_index(rgb):
    g = (rgb[0] + rgb[1] + rgb[2]) / 3.0
    return min(range(4), key=lambda i: abs(g - GREYS[i][0]))


def export(gfx=None, atlas=None):
    """gfx.asm -> PNG atlas. Returns per-block tile counts."""
    from PIL import Image
    lines = load_lines() if gfx is None else open(gfx).read().split("\n")
    atlas = atlas or ATLAS
    blocks = parse_tiles(lines)
    names = [b[0] for b in TILE_BLOCKS]
    per = [blocks[n] for n in names]
    counts = [len(t) for t in per]
    placements, grid_rows = layout(counts)
    img = Image.new("RGB", (COLS * TILE, grid_rows * TILE), GREYS[0])
    px = img.load()
    for bi, ti, c, r in placements:
        tile = per[bi][ti]
        for y in range(TILE):
            for x in range(TILE):
                px[c * TILE + x, r * TILE + y] = GREYS[tile[y][x]]
    os.makedirs(os.path.dirname(atlas), exist_ok=True)
    img.save(atlas)
    return counts


def import_(gfx=None, atlas=None):
    """PNG atlas -> gfx.asm (rewritten in place). Returns per-block tile counts."""
    from PIL import Image
    gfx = gfx or GFX
    atlas = atlas or ATLAS
    lines = open(gfx).read().split("\n")
    blocks = parse_tiles(lines)
    names = [b[0] for b in TILE_BLOCKS]
    counts = [len(blocks[n]) for n in names]
    placements, grid_rows = layout(counts)

    img = Image.open(atlas).convert("RGB")
    exp = (COLS * TILE, grid_rows * TILE)
    if img.size != exp:
        raise SystemExit(
            f"tilepng: atlas is {img.size[0]}x{img.size[1]} but gfx.asm has "
            f"{sum(counts)} tiles (expected {exp[0]}x{exp[1]}). Re-run "
            f"export-tiles.py after adding tiles, or check TILE_BLOCKS.")
    px = img.load()
    new = {names[i]: [[[0] * TILE for _ in range(TILE)] for _ in range(counts[i])]
           for i in range(len(names))}
    for bi, ti, c, r in placements:
        tile = new[names[bi]][ti]
        for y in range(TILE):
            for x in range(TILE):
                tile[y][x] = _nearest_index(px[c * TILE + x, r * TILE + y])
    out = rewrite_tiles(lines, new)
    with open(gfx, "w") as f:
        f.write(out)
    return counts
