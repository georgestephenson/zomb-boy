#!/usr/bin/env python3
# =============================================================================
# gen-portraits.py — convert img/portrait/*.png into src/portrait_data.asm.
#
# Each portrait is a 56x56 image = a 7x7 grid of Game Boy tiles, shown as a
# BACKGROUND block on the survivor talk screen (talk.asm). 49 tiles is far past
# the 40-sprite OAM limit, so a portrait can only be BG tiles, not OBJs.
#
# A CGB BG palette holds 4 colours; we spend the three free BG palette slots
# (5/6/7 — 0..3 are terrain, 4 is the UI) to give each portrait up to 12
# colours. Images from tools/prep-portraits.py already satisfy that constraint
# and are converted losslessly (exact_portrait); anything else falls back to a
# lossy fit: tiles are clustered by mean colour into <=3 groups, each group
# quantised to 4 colours. Every palette is sorted lightest..darkest so that a
# pixel's 2bpp index tracks brightness in EVERY palette — that keeps the DMG
# grayscale fallback (single rBGP, attributes ignored) coherent too.
#
# This is a dev tool (like the test/model reference scripts): run it by hand
# after adding/updating art; the generated src/portrait_data.asm is committed.
# Needs Pillow (host-only) — the ROM build itself never invokes it.
#
#   python3 tools/gen-portraits.py
# =============================================================================
import os
from PIL import Image

# persona id (constants.inc PERSONA_*) -> img/portrait/<name>.png.
# Every persona MUST have art: talk.asm has no small-sprite fallback.
PERSONA_ART = {
    0: "policeman",   # PERSONA_POLICE
    1: "scientist",   # PERSONA_SCIENTIST
    2: "cheerleader", # PERSONA_CHEER
    3: "maid",        # PERSONA_MAID
    4: "businessman", # PERSONA_BIZ
    5: "prepper",     # PERSONA_PREPPER
    6: "medic",       # PERSONA_MEDIC
    7: "raider",      # PERSONA_RAIDER
    8: "preacher",    # PERSONA_PREACHER
    9: "farmer",      # PERSONA_FARMER
}
PERSONA_COUNT = 10

# zombie type id (constants.inc ZTYPE_*) -> img/portrait/<name>.png. Shown as the
# enemy portrait on the battle screen (battle.asm) via the SAME descriptor format
# and VRAM path as a persona portrait. Only the types with art are listed; the
# other design types (Green/Fire/Poison/Speeder/Giant/Behemoth) are LATER.
ZOMBIE_ART = {
    0: "red",   # ZTYPE_RED
    1: "blue",  # ZTYPE_BLUE
}

NUM_PALS = 3          # BG palette slots 5/6/7
TILES = 7             # 7x7 tiles = 56x56 px
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "src", "portrait_data.asm")


def lum(c):
    return 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]


def dist2(a, b):
    return (a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2


def to_bgr555(c):
    r, g, b = (c[0] >> 3), (c[1] >> 3), (c[2] >> 3)
    return (b << 10) | (g << 5) | r


def quantize4(pixels):
    """Reduce a list of RGB pixels to <=4 representative colours, then pad to 4.
    Returns 4 colours sorted lightest..darkest."""
    im = Image.new("RGB", (len(pixels), 1))
    im.putdata(pixels)
    q = im.quantize(colors=4, method=Image.Quantize.MEDIANCUT)
    pal = q.getpalette()
    used = sorted(set(q.tobytes()))
    cols = [tuple(pal[i * 3:i * 3 + 3]) for i in used]
    while len(cols) < 4:
        cols.append(cols[-1])
    cols.sort(key=lum, reverse=True)   # index 0 = lightest, 3 = darkest
    return cols[:4]


def kmeans_tiles(tile_means, k, iters=16):
    """Cluster the 49 tile mean-colours into k groups; return a label per tile."""
    pts = tile_means
    # spread the initial centroids across the luminance range
    order = sorted(range(len(pts)), key=lambda i: lum(pts[i]))
    cents = [pts[order[int((len(pts) - 1) * j / max(1, k - 1))]] for j in range(k)]
    labels = [0] * len(pts)
    for _ in range(iters):
        for i, p in enumerate(pts):
            labels[i] = min(range(k), key=lambda c: dist2(p, cents[c]))
        for c in range(k):
            grp = [pts[i] for i in range(len(pts)) if labels[i] == c]
            if grp:
                cents[c] = tuple(sum(v) / len(grp) for v in zip(*grp))
    return labels


def exact_portrait(tiles):
    """If the image already satisfies the hardware constraint (each tile <=4
    colours, tiles coverable by <=3 four-colour palettes — what
    prep-portraits.py emits), recover palettes/labels losslessly. Returns None
    if the image needs the lossy fit instead."""
    tile_cols = [set(t) for t in tiles]
    if any(len(c) > 4 for c in tile_cols):
        return None
    # best-fit greedy: merge each tile into the group whose union grows least
    groups = []                      # [set(colours), [tile indices]]
    for i in sorted(range(len(tiles)), key=lambda i: -len(tile_cols[i])):
        best = None
        for g in groups:
            u = g[0] | tile_cols[i]
            if len(u) <= 4 and (best is None or len(u) < len(best[1])):
                best = (g, u)
        if best:
            best[0][0] = best[1]
            best[0][1].append(i)
        else:
            groups.append([set(tile_cols[i]), [i]])
    if len(groups) > NUM_PALS:
        return None
    while len(groups) < NUM_PALS:
        groups.append([set(), []])

    pals, labels = [], [0] * len(tiles)
    for gi, (cols, members) in enumerate(groups):
        pal = sorted(cols, key=lum, reverse=True) or [(0, 0, 0)]
        while len(pal) < 4:
            pal.append(pal[-1])
        pals.append(pal)
        for i in members:
            labels[i] = gi
    tile_idx = [[pals[labels[i]].index(px) for px in t]
                for i, t in enumerate(tiles)]
    return pals, labels, tile_idx


def build_portrait(name):
    im = Image.open(os.path.join(ROOT, "img", "portrait", f"{name}.png")).convert("RGB")
    w, h = im.size
    assert (w, h) == (TILES * 8, TILES * 8), f"{name}: expected 56x56, got {w}x{h}"

    # split into 49 tiles (row-major), each a list of 64 RGB pixels
    tiles = []
    for ty in range(TILES):
        for tx in range(TILES):
            px = [im.getpixel((tx * 8 + x, ty * 8 + y))
                  for y in range(8) for x in range(8)]
            tiles.append(px)

    exact = exact_portrait(tiles)
    if exact:
        return exact
    print(f"note: {name}.png is not GBC-exact; using lossy palette fit "
          f"(run tools/prep-portraits.py?)")
    means = [tuple(sum(v) / 64 for v in zip(*t)) for t in tiles]
    labels = kmeans_tiles(means, NUM_PALS)

    # one 4-colour palette per used group
    pals = []
    for c in range(NUM_PALS):
        grp_px = [p for i, t in enumerate(tiles) if labels[i] == c for p in t]
        pals.append(quantize4(grp_px) if grp_px else [(0, 0, 0)] * 4)

    # remap each tile's pixels to the nearest colour in its group's palette
    tile_idx = []   # per tile: 64 indices 0..3
    for i, t in enumerate(tiles):
        pal = pals[labels[i]]
        tile_idx.append([min(range(4), key=lambda k: dist2(px, pal[k])) for px in t])

    return pals, labels, tile_idx


def emit(f, name, pals, labels, tile_idx):
    f.write(f"Portrait_{name}:\n")
    f.write(f"    ; {NUM_PALS} BG palettes (BGR555), lightest..darkest -> slots 5/6/7\n")
    for p, pal in enumerate(pals):
        vals = " ".join(f"${to_bgr555(c):04X}" for c in pal)
        f.write(f"    dw {vals.replace(' ', ', ')}\n")
    f.write("    ; per-tile palette index (0..2), row-major 7x7\n")
    for r in range(TILES):
        row = labels[r * TILES:(r + 1) * TILES]
        f.write("    db " + ", ".join(str(v) for v in row) + "\n")
    f.write("    ; tile data: 49 tiles x 8 rows, 2bpp\n")
    for i, idx in enumerate(tile_idx):
        f.write(f"    ; tile {i}\n")
        for y in range(8):
            row = "".join(str(idx[y * 8 + x]) for x in range(8))
            f.write(f"    dw `{row}\n")


def main():
    missing = [i for i in range(PERSONA_COUNT) if i not in PERSONA_ART]
    assert not missing, f"personas without art (no fallback exists): {missing}"
    ZOMBIE_COUNT = len(ZOMBIE_ART)
    zmissing = [i for i in range(ZOMBIE_COUNT) if i not in ZOMBIE_ART]
    assert not zmissing, f"zombie types without art (no fallback exists): {zmissing}"
    names = sorted(set(PERSONA_ART.values()) | set(ZOMBIE_ART.values()))
    portraits = {n: build_portrait(n) for n in names}
    with open(OUT, "w") as f:
        f.write("; =============================================================================\n")
        f.write("; portrait_data.asm — GENERATED by tools/gen-portraits.py. DO NOT EDIT.\n")
        f.write(";\n")
        f.write("; 56x56 survivor portraits for the talk screen, as 7x7 BG tile blocks.\n")
        f.write("; Descriptor layout (see talk.asm ShowPortrait):\n")
        f.write(";   +0   3 BG palettes x 4 colours (BGR555)        = 24 bytes\n")
        f.write(";   +24  49-byte per-tile palette index (0..2)     = 49 bytes\n")
        f.write(";   +73  49 tiles x 16 bytes 2bpp tile data        = 784 bytes\n")
        f.write("; =============================================================================\n")
        f.write('INCLUDE "include/constants.inc"\n\n')
        f.write('; BANK[2]: mapped only inside ShowPortrait (talk.asm), which restores\n')
        f.write('; the default bank 1 (song + dialogue data) before returning.\n')
        f.write('SECTION "PortraitData", ROMX, BANK[2]\n\n')
        f.write("; PortraitTable[persona] -> descriptor (every persona has art).\n")
        f.write("PortraitTable::\n")
        for i in range(PERSONA_COUNT):
            f.write(f"    dw Portrait_{PERSONA_ART[i]}\n")
        f.write("\n")
        f.write("; ZombiePortraitTable[ztype] -> descriptor (battle.asm enemy art).\n")
        f.write("ZombiePortraitTable::\n")
        for i in range(ZOMBIE_COUNT):
            f.write(f"    dw Portrait_{ZOMBIE_ART[i]}\n")
        f.write("\n")
        for name, (pals, labels, tile_idx) in portraits.items():
            emit(f, name, pals, labels, tile_idx)
            f.write("\n")
    print(f"wrote {OUT}  ({os.path.getsize(OUT)} bytes)")


if __name__ == "__main__":
    main()
