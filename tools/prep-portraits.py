#!/usr/bin/env python3
# =============================================================================
# prep-portraits.py — img/portrait/source/*.png (112x112, AI output with
# anti-aliasing/blur artifacts) -> img/portrait/*.png (56x56, GBC-exact).
#
# The output images are precisely representable on Game Boy Color hardware:
# every colour is RGB555, and the 49 8x8 tiles can be covered by 3 palettes of
# 4 colours (BG slots 5/6/7 — the constraint ShowPortrait lives under, see
# gen-portraits.py). So the PNG in img/portrait *is* the in-game image; feeding
# it to gen-portraits.py is lossless remapping.
#
# Pipeline per image:
#   1. quantize the 112x112 to a small master palette (median cut + k-means
#      refine) — collapses the AA/noise back to the art's intended flat colours
#   2. downscale 2x by majority vote per 2x2 block — never invents blends
#   3. fit 3 palettes x 4 colours + a per-tile palette assignment by
#      alternating refinement (assign tiles -> refit palettes), best of
#      several deterministic restarts
#   4. snap palettes to RGB555 (expanded back to 8-bit the way the CGB LCD
#      does) and remap each tile through its palette
#
# Dev tool, host-only, needs Pillow. The ROM build never invokes it.
#
#   python3 tools/prep-portraits.py            # all sources
#   python3 tools/prep-portraits.py maid ...   # just these
# =============================================================================
import os
import sys
import random
from collections import Counter
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DIR = os.path.join(ROOT, "img", "portrait", "source")
OUT_DIR = os.path.join(ROOT, "img", "portrait")
SRC_SIZE = 112
OUT_SIZE = 56
TILES = 7                # 7x7 tiles of 8x8 px
NUM_PALS = 3             # BG palette slots 5/6/7
PAL_COLS = 4
MASTER_COLS = 16         # denoise target before the constrained fit
RESTARTS = 8
# perceptual-ish channel weights for squared distance
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


def kmeans_colors(hist, k, seed):
    """Weighted k-means over a {colour: count} histogram; returns <=k colours."""
    pts = list(hist.items())
    if len(pts) <= k:
        return [c for c, _ in pts]
    rng = random.Random(seed)
    # init: spread across luminance, then jitter the choice a little
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
    # collapse to the actual best member colour of each cluster (keeps colours
    # that exist in the art rather than mushy averages)
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
    """One restart: labels + palettes by alternating refinement."""
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
    for it in range(20):
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


def convert(name):
    im = Image.open(os.path.join(SRC_DIR, f"{name}.png")).convert("RGB")
    assert im.size == (SRC_SIZE, SRC_SIZE), f"{name}: expected 112x112, got {im.size}"

    # 1. denoise: quantize to a master palette, refined by weighted k-means
    q = im.quantize(colors=MASTER_COLS, method=Image.Quantize.MEDIANCUT).convert("RGB")
    hist = Counter(q.getdata())
    master = kmeans_colors(Counter(im.getdata()), min(MASTER_COLS, len(hist)), 0)
    src = im.load()
    mapped = [[master[nearest(src[x, y], master)] for x in range(SRC_SIZE)]
              for y in range(SRC_SIZE)]

    # 2. downscale 2x by majority vote (ties -> colour nearest the block mean)
    small = [[None] * OUT_SIZE for _ in range(OUT_SIZE)]
    for by in range(OUT_SIZE):
        for bx in range(OUT_SIZE):
            blk = [mapped[by * 2 + dy][bx * 2 + dx] for dy in range(2) for dx in range(2)]
            cnt = Counter(blk)
            top = cnt.most_common()
            best = top[0][1]
            cands = [c for c, k in top if k == best]
            if len(cands) == 1:
                small[by][bx] = cands[0]
            else:
                mean = tuple(sum(orig[ch] for orig in
                                 (src[bx * 2 + dx, by * 2 + dy]
                                  for dy in range(2) for dx in range(2))) / 4
                             for ch in range(3))
                small[by][bx] = cands[nearest(mean, cands)]

    # 3. constrained fit: 3 palettes x 4 colours, one palette per 8x8 tile
    tile_hists = []
    for ty in range(TILES):
        for tx in range(TILES):
            tile_hists.append(Counter(small[ty * 8 + y][tx * 8 + x]
                                      for y in range(8) for x in range(8)))
    best = min((fit_palettes(tile_hists, s) for s in range(RESTARTS)),
               key=lambda r: r[0])
    _, labels, pals = best

    # 4. snap to RGB555, remap every pixel through its tile's palette
    pals = [sorted({snap555(c) for c in pal}, key=lum, reverse=True) for pal in pals]
    out = Image.new("RGB", (OUT_SIZE, OUT_SIZE))
    po = out.load()
    for ty in range(TILES):
        pal = None
        for tx in range(TILES):
            pal = pals[labels[ty * TILES + tx]]
            for y in range(8):
                for x in range(8):
                    c = small[ty * 8 + y][tx * 8 + x]
                    po[tx * 8 + x, ty * 8 + y] = pal[nearest(c, pal)]

    out.save(os.path.join(OUT_DIR, f"{name}.png"), optimize=True)
    ncols = len({po[x, y] for y in range(OUT_SIZE) for x in range(OUT_SIZE)})
    print(f"{name:14s} colours={ncols:2d}  palettes="
          + "  ".join("[" + ",".join(f"#{c[0]:02x}{c[1]:02x}{c[2]:02x}" for c in p) + "]"
                      for p in pals))


def main():
    names = sys.argv[1:] or sorted(
        os.path.splitext(f)[0] for f in os.listdir(SRC_DIR) if f.endswith(".png"))
    for name in names:
        convert(name)


if __name__ == "__main__":
    main()
