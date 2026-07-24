#!/usr/bin/env python3
"""gen-battle-zombies.py — the faux-3D approaching-zombie scale atlas (battle.asm).

The battle screen (docs/design/04) shows up to MAX_FOES zombies shuffling toward
the player, growing through a handful of discrete SIZE TIERS as they close in.
Four big zombies can't be OBJ sprites (28x56 px is ~28 hardware sprites each, far
past the 40-OAM / 10-per-line limit), so they're drawn as BACKGROUND tiles — the
same trick the scrapped enemy portrait used (a 7x7 BG block). One base silhouette
is nearest-neighbour downscaled to every tier, so all four zombies (and both
types, tinted by BG palette) share ONE resident atlas.

Output: src/battle_zombie_data.asm (committed), read by battle.asm:
  * BattleZombieTiles::  the tiers' 8x8 tiles concatenated (2bpp), copied into
    VRAM at FOE_ATLAS_BASE on battle entry.
  * BattleZombieTiers::  one 4-byte row per tier {wtiles, htiles, headrows,
    tileoff} — the block geometry the renderer places into the tilemap, plus the
    head band (top headrows tiles) that a crosshair hit reads as a CRITICAL.

Pixel indices are BG palette slots: 0 = paper (matches the arena background so a
partly-filled tile has no halo), 1 = dark outline, 2 = rotten flesh, 3 = teeth /
eye glint. Re-run after any art change; the atlas MUST stay <= FOE_ATLAS_TILES
(the free VRAM gap the portrait vacated) — the tool asserts it.
"""
import math
import os

# Tier sizes in TILES (w, h). Feet-anchored on a common ground line, so a tier
# reads as "nearer" purely by being bigger. Kept to 6 tiers (not the 7 in the
# brief) so the whole atlas fits the 64-tile VRAM gap the enemy portrait freed:
# 1+2+6+8+15+28 = 60 tiles. headrows = the top band counted as the head (crit).
TIERS = [
    # (wtiles, htiles, headrows)   px size
    (1, 1, 1),   # 8x8   — a distant shuffler
    (1, 2, 1),   # 8x16
    (2, 3, 1),   # 16x24
    (2, 4, 1),   # 16x32
    (3, 5, 2),   # 24x40
    (4, 7, 2),   # 32x56  — right in your face
]
FOE_ATLAS_TILES = 64          # free VRAM ids 64..127 (portrait block + gap)

# Crosshair orbit paths, precomputed so battle.asm needs no runtime trig (SM83
# has no multiply). Screen-px (x, y) per phase step. MUST match constants.inc:
# CROSS_CX/CY/RX/RY and CROSS_SINLEN.
CROSS_CX, CROSS_CY = 76, 34
CROSS_RX, CROSS_RY = 52, 24
CROSS_SINLEN = 64

OUT = os.path.join(os.path.dirname(__file__), "..", "src", "battle_zombie_data.asm")

# --- the base silhouette, authored at the largest tier (32 wide x 56 tall) ----
# A hunched, arms-out zombie. Built from filled primitives so it downscales
# cleanly; every smaller tier is a nearest-neighbour sample of this one image.
BW, BH = 32, 56


def _blank():
    return [[0] * BW for _ in range(BH)]


def _rect(img, x0, y0, x1, y1, c):
    for y in range(max(0, y0), min(BH, y1 + 1)):
        for x in range(max(0, x0), min(BW, x1 + 1)):
            img[y][x] = c


def _ellipse(img, cx, cy, rx, ry, c):
    for y in range(BH):
        for x in range(BW):
            dx = (x - cx) / rx
            dy = (y - cy) / ry
            if dx * dx + dy * dy <= 1.0:
                img[y][x] = c


def _outline(img):
    """Ring index-1 (dark) around every filled (non-0) region."""
    ring = [row[:] for row in img]
    for y in range(BH):
        for x in range(BW):
            if img[y][x] != 0:
                continue
            near = False
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    yy, xx = y + dy, x + dx
                    if 0 <= yy < BH and 0 <= xx < BW and img[yy][xx] not in (0, 1):
                        near = True
            if near:
                ring[y][x] = 1
    return ring


def base_image():
    img = _blank()
    # torso (rotten flesh) — a lumpy trunk, leaning
    _ellipse(img, 16, 30, 10, 13, 2)
    _rect(img, 8, 22, 24, 40, 2)
    # legs — a mid-stride stance so the horizontal walk-flip actually reads as
    # steps: one leg planted + forward (long, foot low and out to one side), the
    # other lifted + trailing (shorter, foot raised and out the other side).
    # Mirroring the whole sprite swaps the two -> the opposite step of the cycle.
    _rect(img, 9, 39, 14, 55, 2)      # forward leg — planted, full length
    _rect(img, 5, 53, 15, 55, 2)      # forward foot — juts forward-left, low
    _rect(img, 18, 39, 23, 48, 2)     # trailing thigh — stops higher (knee up)
    _rect(img, 19, 46, 24, 51, 2)     # trailing shin — kicked back
    _rect(img, 20, 49, 27, 51, 2)     # trailing foot — juts back-right, raised
    # arms reaching out for you
    _rect(img, 1, 24, 8, 30, 2)       # left arm
    _rect(img, 0, 22, 4, 34, 2)       # left hand/claw
    _rect(img, 24, 24, 31, 30, 2)     # right arm
    _rect(img, 27, 22, 31, 34, 2)     # right hand/claw
    # head
    _ellipse(img, 16, 10, 8, 10, 2)
    _rect(img, 9, 8, 23, 16, 2)
    # a torn seam / ribs (dark) so the flip reads as a shuffle
    _rect(img, 15, 24, 17, 39, 1)
    # outline the whole thing
    img = _outline(img)
    # facial features on top of the outline: sunken eyes + a jagged grin
    _rect(img, 11, 8, 13, 11, 1)      # left eye socket
    _rect(img, 19, 8, 21, 11, 1)      # right eye socket
    img[9][12] = 3                    # eye glints
    img[9][20] = 3
    _rect(img, 12, 14, 20, 15, 1)     # mouth line
    img[14][13] = 3                   # teeth
    img[14][16] = 3
    img[14][19] = 3
    return img


def downscale(img, w_px, h_px):
    """Nearest-neighbour resample of the base image to w_px x h_px."""
    out = [[0] * w_px for _ in range(h_px)]
    for y in range(h_px):
        sy = min(BH - 1, y * BH // h_px)
        for x in range(w_px):
            sx = min(BW - 1, x * BW // w_px)
            out[y][x] = img[sy][sx]
    return out


def to_2bpp(pix, wt, ht):
    """pix = ht*8 x wt*8 index grid -> tiles in row-major (tile) order, each a
    list of 16 bytes (RGBDS 2bpp: per row lo-plane then hi-plane)."""
    tiles = []
    for trow in range(ht):
        for tcol in range(wt):
            data = []
            for r in range(8):
                lo = hi = 0
                for c in range(8):
                    p = pix[trow * 8 + r][tcol * 8 + c]
                    lo = (lo << 1) | (p & 1)
                    hi = (hi << 1) | ((p >> 1) & 1)
                data += [lo, hi]
            tiles.append(data)
    return tiles


def main():
    base = base_image()
    all_tiles = []
    meta = []               # (wt, ht, headrows, tileoff)
    off = 0
    for (wt, ht, head) in TIERS:
        pix = downscale(base, wt * 8, ht * 8)
        tiles = to_2bpp(pix, wt, ht)
        meta.append((wt, ht, head, off))
        all_tiles += tiles
        off += wt * ht
    assert off <= FOE_ATLAS_TILES, f"atlas {off} tiles > {FOE_ATLAS_TILES} VRAM gap"

    with open(os.path.normpath(OUT), "w") as f:
        f.write("; =============================================================================\n")
        f.write("; battle_zombie_data.asm — GENERATED by tools/gen-battle-zombies.py.\n")
        f.write("; The faux-3D approaching-zombie scale atlas: one base silhouette downscaled\n")
        f.write("; to every size tier, drawn as BG tiles on the battle screen (battle.asm).\n")
        f.write(";\n")
        f.write(f"; {off} tiles total (<= {FOE_ATLAS_TILES}, the VRAM gap the enemy portrait vacated).\n")
        f.write("; Pixel indices are BG palette slots: 0 paper, 1 outline, 2 flesh, 3 glint.\n")
        f.write("; Do not hand-edit; re-run the tool after any art change.\n")
        f.write("; =============================================================================\n")
        f.write('INCLUDE "include/constants.inc"\n\n')
        f.write("; FRAGMENT \"Battle\": shares the engine's floating bank, read without a switch.\n")
        f.write('SECTION FRAGMENT "Battle", ROMX\n\n')
        f.write("; BattleZombieTiers[tier] = {wtiles, htiles, headrows, tileoff}. tileoff is the\n")
        f.write("; tier's first tile as an offset from FOE_ATLAS_BASE (its VRAM id).\n")
        f.write("BattleZombieTiers::\n")
        for (wt, ht, head, o) in meta:
            f.write(f"    db {wt}, {ht}, {head}, {o}\n")
        f.write("\n")
        f.write(f"; {off} tiles (16 bytes each), tiers T0..T{len(TIERS)-1} concatenated.\n")
        f.write("BattleZombieTiles::\n")
        ti = 0
        for (wt, ht, head, o) in meta:
            f.write(f"    ; --- tier {TIERS.index((wt, ht, head))}: {wt}x{ht} tiles ---\n")
            for _ in range(wt * ht):
                row = ", ".join(f"${b:02X}" for b in all_tiles[ti])
                f.write(f"    db {row}\n")
                ti += 1
        f.write("BattleZombieTilesEnd::\n\n")
        # crosshair orbit paths (screen x, y per phase)
        f.write("; Crosshair orbit paths (screen px x, y per phase step) — battle.asm indexes\n")
        f.write("; these directly so it needs no runtime trig. CROSS_SINLEN entries each.\n")
        _emit_path(f, "CrossPathCircle", circle_path())
        f.write("\n")
        _emit_path(f, "CrossPathFig8", fig8_path())
    print(f"wrote {os.path.normpath(OUT)}  ({off} tiles, {off*16} bytes)")


def _clampx(v):
    return max(0, min(159, int(round(v))))


def _clampy(v):
    return max(0, min(143, int(round(v))))


def circle_path():
    pts = []
    for i in range(CROSS_SINLEN):
        t = 2 * math.pi * i / CROSS_SINLEN
        pts.append((_clampx(CROSS_CX + CROSS_RX * math.cos(t)),
                    _clampy(CROSS_CY + CROSS_RY * math.sin(t))))
    return pts


def fig8_path():
    pts = []
    for i in range(CROSS_SINLEN):
        t = 2 * math.pi * i / CROSS_SINLEN
        pts.append((_clampx(CROSS_CX + CROSS_RX * math.sin(t)),
                    _clampy(CROSS_CY + CROSS_RY * math.sin(2 * t))))
    return pts


def _emit_path(f, label, pts):
    f.write(f"{label}::\n")
    for (x, y) in pts:
        f.write(f"    db {x}, {y}\n")


if __name__ == "__main__":
    main()
