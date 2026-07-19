#!/usr/bin/env python3
# =============================================================================
# gen-title.py — img/source/title.png (1024x1024 AI pixel-art) -> a GBC-exact
# 160x144 full-screen title background, emitted as src/title_data.asm.
#
# This is the full-screen analogue of gen/prep-portraits.py. A GBC background
# is a 20x18 grid of 8x8 tiles; every tile picks ONE of 8 BG palettes (4 colours
# each), and the tile *pixels* are palette-independent 2bpp indices. So the job
# is three constraints at once:
#   1. resize/crop 1024x1024 -> 160x144 and denoise the AI dithering back to
#      flat colours (this art is essentially a red/green duotone),
#   2. fit 8 palettes x 4 colours with ONE palette per 8x8 tile (the hardware
#      rule — same alternating-refinement solver as prep-portraits, NUM_PALS=8),
#   3. dedup tiles: identical 2bpp index patterns (under H/V flip) share one
#      VRAM tile; the per-cell palette + flip flags live in the attribute map.
#      Every palette is sorted lightest..darkest so a flat region hits the same
#      index in every palette and dedups across palettes (and DMG grayscale
#      stays coherent, like the portraits).
#
# The title owns VRAM only before gameplay (InitMap reloads the game tiles
# after START). A detailed scene barely dedups (~1 tile/screen), so it spans
# BOTH VRAM banks: tiles 0..255 -> bank 0, 256.. -> bank 1 (the CGB attribute
# byte's bit 3 selects the bank). 20x18 = 360 cells, so 512 tiles is the hard
# ceiling the tool asserts.
#
# Dev tool, host-only, needs Pillow. The ROM build never invokes it. Writes
# img/title.png (what the hardware shows) so the conversion can be eyeballed.
#
#   python3 tools/gen-title.py
# =============================================================================
import os
import random
from collections import Counter
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "img", "source", "title.png")
OUT = os.path.join(ROOT, "src", "title_data.asm")
PREVIEW = os.path.join(ROOT, "img", "title.png")

W, H = 160, 144           # Game Boy screen
TW, TH = W // 8, H // 8   # 20 x 18 tiles
NUM_PALS = 8              # all 8 BG palette slots (the title owns them)
PAL_COLS = 4
MASTER_COLS = 24          # denoise target before the constrained fit
RESTARTS = 10
BANK_TILES = 256          # tiles per VRAM bank (8-bit tile id)
MAX_TILES = 2 * BANK_TILES # both VRAM banks (title owns all of VRAM)

# Crop: scale to 160 wide (=> 160 tall), then keep 144 rows. The art is a
# centred square; trim more sky off the top than grass off the bottom so the
# "PRESS START" band stays clear of the edge.
CROP_TOP = 10

# perceptual-ish channel weights for squared colour distance
WR, WG, WB = 2, 4, 3


def dist2(a, b):
    return (WR * (a[0] - b[0]) ** 2 + WG * (a[1] - b[1]) ** 2
            + WB * (a[2] - b[2]) ** 2)


def lum(c):
    return 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]


def nearest(c, pal):
    return min(range(len(pal)), key=lambda i: dist2(c, pal[i]))


def snap555(c):
    """Quantize to RGB555, then expand 5->8 bits like the CGB (v<<3 | v>>2)."""
    out = []
    for v in c:
        v5 = (v * 31 + 127) // 255
        out.append((v5 << 3) | (v5 >> 2))
    return tuple(out)


def to_bgr555(c):
    r, g, b = (c[0] >> 3), (c[1] >> 3), (c[2] >> 3)
    return (b << 10) | (g << 5) | r


def kmeans_colors(hist, k, seed):
    """Weighted k-means over a {colour: count} histogram; returns <=k colours."""
    pts = list(hist.items())
    if len(pts) <= k:
        return [c for c, _ in pts]
    rng = random.Random(seed)
    order = sorted(range(len(pts)), key=lambda i: lum(pts[i][0]))
    cents = []
    for j in range(k):
        i = order[(len(pts) - 1) * j // (k - 1)]
        if seed:
            i = order[max(0, min(len(pts) - 1,
                                 (len(pts) - 1) * j // (k - 1) + rng.randint(-2, 2)))]
        cents.append(pts[i][0])
    for _ in range(24):
        groups = [[] for _ in range(k)]
        for c, n in pts:
            groups[nearest(c, cents)].append((c, n))
        new = []
        for g, old in zip(groups, cents):
            if not g:
                new.append(old)
                continue
            tot = sum(n for _, n in g)
            new.append(tuple(sum(c[ch] * n for c, n in g) / tot for ch in range(3)))
        if new == cents:
            break
        cents = new
    out = []
    groups = [[] for _ in range(k)]
    for c, n in pts:
        groups[nearest(c, cents)].append((c, n))
    for g in groups:
        if g:
            out.append(max(g, key=lambda cn: cn[1])[0])
    return out


def remap_error(tile_hist, pal):
    return sum(n * dist2(c, pal[nearest(c, pal)]) for c, n in tile_hist.items())


def fit_palettes(tile_hists, seed):
    """One restart: per-tile palette labels + NUM_PALS palettes by alternating
    refinement (assign tiles -> refit palettes)."""
    rng = random.Random(seed)
    n = len(tile_hists)
    if seed == 0:
        means = []
        for h in tile_hists:
            tot = sum(h.values())
            means.append(tuple(sum(c[ch] * cnt for c, cnt in h.items()) / tot
                               for ch in range(3)))
        order = sorted(range(n), key=lambda i: lum(means[i]))
        labels = [0] * n
        for rank, i in enumerate(order):
            labels[i] = rank * NUM_PALS // n
    else:
        labels = [rng.randrange(NUM_PALS) for _ in range(n)]

    pals = [[(0, 0, 0)] * PAL_COLS] * NUM_PALS
    for _ in range(24):
        for p in range(NUM_PALS):
            hist = Counter()
            for i in range(n):
                if labels[i] == p:
                    hist.update(tile_hists[i])
            if hist:
                pals[p] = kmeans_colors(hist, PAL_COLS, seed)
        new = [min(range(NUM_PALS), key=lambda p: remap_error(tile_hists[i], pals[p]))
               for i in range(n)]
        if new == labels:
            break
        labels = new
    err = sum(remap_error(tile_hists[i], pals[labels[i]]) for i in range(n))
    return err, labels, pals


def load_small():
    """Resize + crop the source to 160x144 and denoise to a master palette."""
    im = Image.open(SRC).convert("RGB")
    assert im.size == (1024, 1024), f"expected 1024x1024, got {im.size}"
    im = im.resize((W, W), Image.LANCZOS).crop((0, CROP_TOP, W, CROP_TOP + H))

    master = kmeans_colors(Counter(im.getdata()), MASTER_COLS, 0)
    px = im.load()
    return [[master[nearest(px[x, y], master)] for x in range(W)] for y in range(H)]


def orient(idx, fx, fy):
    """Return the 64 2bpp indices of tile `idx` flipped per fx/fy."""
    out = []
    for y in range(8):
        sy = 7 - y if fy else y
        for x in range(8):
            sx = 7 - x if fx else x
            out.append(idx[sy * 8 + sx])
    return tuple(out)


def build():
    small = load_small()

    # constrained fit: 8 palettes x 4 colours, one palette per 8x8 tile
    tile_hists = []
    for ty in range(TH):
        for tx in range(TW):
            tile_hists.append(Counter(small[ty * 8 + y][tx * 8 + x]
                                      for y in range(8) for x in range(8)))
    err, labels, pals = min((fit_palettes(tile_hists, s) for s in range(RESTARTS)),
                            key=lambda r: r[0])

    # snap to RGB555, sort each palette lightest..darkest, pad to 4
    fixed = []
    for pal in pals:
        cols = sorted({snap555(c) for c in pal}, key=lum, reverse=True)
        while len(cols) < 4:
            cols.append(cols[-1] if cols else (0, 0, 0))
        fixed.append(cols[:4])
    pals = fixed

    # per-tile 2bpp indices through the tile's palette; dedup under H/V flip
    tiles = []                 # unique tile index-patterns (canonical)
    seen = {}                  # pattern (any orientation) -> (tile_id, fx, fy)
    cell_tile = [0] * (TW * TH)
    cell_pal = [0] * (TW * TH)
    cell_fx = [0] * (TW * TH)
    cell_fy = [0] * (TW * TH)
    for ci in range(TW * TH):
        ty, tx = divmod(ci, TW)
        p = labels[ci]
        pal = pals[p]
        idx = tuple(nearest(small[ty * 8 + y][tx * 8 + x], pal)
                    for y in range(8) for x in range(8))
        if idx in seen:
            tid, fx, fy = seen[idx]
        else:
            tid = len(tiles)
            tiles.append(idx)
            fx = fy = 0
            # register all four orientations so later cells can flip to match
            for ffy in (0, 1):
                for ffx in (0, 1):
                    seen.setdefault(orient(idx, ffx, ffy), (tid, ffx, ffy))
        cell_tile[ci], cell_pal[ci] = tid, p
        cell_fx[ci], cell_fy[ci] = fx, fy

    assert len(tiles) <= MAX_TILES, \
        f"{len(tiles)} tiles > {MAX_TILES} (both VRAM banks); denoise harder"

    # preview PNG (what the hardware will show)
    prev = Image.new("RGB", (W, H))
    pp = prev.load()
    for ci in range(TW * TH):
        ty, tx = divmod(ci, TW)
        idx = orient(tiles[cell_tile[ci]], cell_fx[ci], cell_fy[ci])
        pal = pals[cell_pal[ci]]
        for y in range(8):
            for x in range(8):
                pp[tx * 8 + x, ty * 8 + y] = pal[idx[y * 8 + x]]
    prev.save(PREVIEW)

    return pals, tiles, cell_tile, cell_pal, cell_fx, cell_fy, err


def emit(pals, tiles, cell_tile, cell_pal, cell_fx, cell_fy):
    with open(OUT, "w") as f:
        f.write("; ===========================================================================\n")
        f.write("; title_data.asm — GENERATED by tools/gen-title.py. DO NOT EDIT.\n")
        f.write(";\n")
        f.write("; 160x144 GBC title background (see title.asm ShowTitle):\n")
        f.write(f";   TitlePalettes  8 BG palettes x 4 colours (BGR555)   = 64 bytes\n")
        f.write(f";   TitleTiles     {len(tiles)} tiles x 16 bytes 2bpp\n")
        f.write(f";   TitleMap       {TW}x{TH} tile ids                       = {TW*TH} bytes\n")
        f.write(f";   TitleAttrs     {TW}x{TH} attrs (pal | xflip | yflip)    = {TW*TH} bytes\n")
        f.write("; ===========================================================================\n")
        f.write('INCLUDE "include/constants.inc"\n\n')
        f.write("; BANK[3]: mapped only while the title screen is up (title.asm), which\n")
        f.write("; restores the default bank 1 before gameplay starts.\n")
        f.write('SECTION "TitleData", ROMX, BANK[3]\n\n')

        b0 = min(len(tiles), BANK_TILES)      # tiles in VRAM bank 0
        b1 = max(0, len(tiles) - BANK_TILES)  # tiles in VRAM bank 1
        f.write(f"DEF TITLE_TILE_COUNT EQU {len(tiles)}\n")
        f.write(f"DEF TITLE_BANK0_BYTES EQU {b0 * 16}\n")
        f.write(f"DEF TITLE_BANK1_BYTES EQU {b1 * 16}\n")
        f.write("EXPORT TITLE_TILE_COUNT, TITLE_BANK0_BYTES, TITLE_BANK1_BYTES\n\n")

        f.write("TitlePalettes::\n")
        for p, pal in enumerate(pals):
            vals = ", ".join(f"${to_bgr555(c):04X}" for c in pal)
            f.write(f"    dw {vals}\n")
        f.write("\n")

        f.write("TitleTiles::\n")
        for i, idx in enumerate(tiles):
            f.write(f"    ; tile {i}\n")
            for y in range(8):
                row = "".join(str(idx[y * 8 + x]) for x in range(8))
                f.write(f"    dw `{row}\n")
        f.write("\n")

        f.write("; tile id is the LOW byte (tiles 256.. live in VRAM bank 1 at the\n")
        f.write("; same 0-based id; the attr bit-3 below selects the bank).\n")
        f.write("TitleMap::\n")
        for ty in range(TH):
            row = [v & 0xFF for v in cell_tile[ty * TW:(ty + 1) * TW]]
            f.write("    db " + ", ".join(str(v) for v in row) + "\n")
        f.write("\n")

        f.write("; attr byte (CGB layout): palette bits 0-2, VRAM bank bit 3,\n")
        f.write("; X-flip bit 5, Y-flip bit 6\n")
        f.write("TitleAttrs::\n")
        for ty in range(TH):
            vals = []
            for tx in range(TW):
                ci = ty * TW + tx
                bank = 1 if cell_tile[ci] >= BANK_TILES else 0
                a = (cell_pal[ci] | (bank << 3)
                     | (cell_fx[ci] << 5) | (cell_fy[ci] << 6))
                vals.append(f"${a:02X}")
            f.write("    db " + ", ".join(vals) + "\n")


def main():
    pals, tiles, cell_tile, cell_pal, cell_fx, cell_fy, err = build()
    emit(pals, tiles, cell_tile, cell_pal, cell_fx, cell_fy)
    ncols = len({c for pal in pals for c in pal})
    print(f"tiles={len(tiles):3d}/{MAX_TILES}  colours={ncols}  fit_err={err:.0f}")
    print(f"wrote {OUT}  ({os.path.getsize(OUT)} bytes)")
    print(f"preview {PREVIEW}")


if __name__ == "__main__":
    main()
