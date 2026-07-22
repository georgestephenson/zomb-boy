#!/usr/bin/env python3
# =============================================================================
# tilepng.py — shared logic for the tile export/import round-trip tools.
#
# The game's 8x8 tile ART lives in src/gfx.asm. Two kinds of art blocks:
#   * 2bpp backtick `dw` blocks — one `dw` line per row, one digit (0-3) per
#     pixel = a 2bpp colour INDEX into a 4-colour palette chosen per tile at
#     runtime:
#         Tiles::        ... TilesEnd::         BG world + player/zombie/UI
#         PersonaTiles:: ... PersonaTilesEnd::  survivor personas + car + loot
#   * a 1bpp `db` block — one `db` line per whole glyph (8 bytes = 8 rows), one
#     bit per pixel (paper/ink), expanded at boot to colours 0/3 of the talk-UI
#     palette:
#         Font1bpp::     ... Font1bppEnd::      font + HUD glyphs
# and the CGB colour palettes themselves (BGR555 `dw`):
#         BGPalette::    ... BGPaletteEnd::     5 BG palettes  x 4 colours
#         OBJPalette::   ... OBJPaletteEnd::    8 OBJ palettes x 4 colours
#
# export-tiles.py renders every tile into one PNG atlas (img/tiles.png), each
# tile drawn in COLOUR through the palette it is shown with in-game (its
# "primary palette", see TILE_PALETTES). import-tiles.py reads the atlas back and
# rewrites gfx.asm. OBJ palette index 0 is the hardware-transparent colour, so
# those pixels are stored as PNG transparency (alpha 0) — that also keeps the
# inverse unambiguous, since OBJ index 0 and 1 are both RGB black.
#
# The round-trip is IDEMPOTENT both ways: import rewrites ONLY the pixel digits /
# bytes of each tile row and ONLY the palette-colour expressions that actually
# changed (every comment, label and blank line preserved), and export writes the
# exact CGB expansion of each stored BGR555 colour and compares back in 5-bit
# space — so export|import is a no-op on gfx.asm and import|export is a no-op on
# the PNG.
#
# EDITING THE PNG — two independent things you can change:
#   * PIXELS: repaint a pixel with a colour ALREADY in that tile's palette (or
#     erase an OBJ pixel to transparency). Import recovers the new 2bpp indices.
#   * PALETTE COLOURS ("colour swap"): repaint every pixel of one palette colour
#     to a BRAND-NEW colour. Import detects that a whole palette slot changed and
#     rewrites the BGPalette/OBJPalette entry instead of the tiles.
# Rearranging EXISTING palette colours reads as pixel edits (indices change);
# introducing a NEW colour reads as a palette swap (a slot's colour changes).
#
# VALIDATION (a colour swap must stay consistent — tiles SHARE palettes):
#   * every opaque pixel must be one of its palette's colours (old, or the one
#     new colour that replaced a slot) — a stray colour is an error;
#   * a new colour may replace only ONE slot, and only across positions that
#     shared one old index, uniformly for every tile using that palette;
#   * a palette's colours must stay distinct (you cannot collapse two slots);
#   * font glyphs are 1bpp — only the UI palette's paper (slot 0) and ink
#     (slot 3) may appear in them.
# Any violation aborts the import with a message; gfx.asm is left untouched.
#
# NOT round-tripped: BG palettes 5-7 (portrait art, generated separately) and
# any palette with no tile in these blocks.
#
# MAINTENANCE (see CLAUDE.md): adding art WITHIN an existing block just needs a
# re-export, BUT you must extend TILE_PALETTES for the new tiles (the tool has to
# know each tile's palette to colour it). A NEW backtick/1bpp art block needs a
# TILE_BLOCKS + TILE_PALETTES entry; a NEW palette needs a PALETTE_BLOCKS entry.
# Keep the TILE_PALETTES assignments in step with world.asm's AttrTable (BG
# tiles), the draw code's OBJ palettes, and dialogue_data.asm's PO_PAL (personas).
#
# Dev tool, host-only, needs Pillow. The ROM build never invokes it.
# =============================================================================
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GFX = os.path.join(ROOT, "src", "gfx.asm")
ATLAS = os.path.join(ROOT, "img", "tiles.png")

# Art blocks: (start label, end label, kind). "2bpp" = backtick `dw`, one line
# per row; "1bpp" = `db`, one line per glyph (8 bytes = 8 rows). Atlas order ==
# this order.
TILE_BLOCKS = [
    ("Tiles", "TilesEnd", "2bpp"),
    ("PersonaTiles", "PersonaTilesEnd", "2bpp"),
    ("Font1bpp", "Font1bppEnd", "1bpp"),
]

# Palette blocks: (start, end, kind). Kind tags OBJ so index 0 = transparent.
PALETTE_BLOCKS = [
    ("BGPalette", "BGPaletteEnd", "BG"),
    ("OBJPalette", "OBJPaletteEnd", "OBJ"),
]

# --- per-tile primary palette: block name -> [palette-key per tile] ------------
# key = ("BG", n) or ("OBJ", n). Exactly one entry per tile, in order. BG tiles
# 0-13 mirror world.asm AttrTable; sprites use the OBJ palette their draw code
# selects; UI frame/bar/panel + the whole font use PAL_BG_UI (BG 4).
_TILES_PAL = (
    [("BG", 0)] * 3          # 0 grass, 1 brush, 2 flower
    + [("BG", 2)]            # 3 dirt
    + [("BG", 1)]            # 4 water
    + [("BG", 2)] * 4        # 5 road, 6 wall, 7 floor, 8 door
    + [("BG", 3)]            # 9 marsh
    + [("BG", 0)] * 4        # 10-13 tree quadrants
    + [("OBJ", 0)] * 6       # 14-19 player (down/up/side A/B)
    + [("OBJ", 1)] * 6       # 20-25 zombie
    + [("OBJ", 2)] * 2       # 26 alert bubble, 27 menu cursor
    + [("BG", 4)] * 8        # 28-35 portrait frame (PAL_BG_UI)
    + [("BG", 4)] * 9        # 36-44 affinity bar 0/8..8/8
    + [("BG", 4)] * 8        # 45-52 UI panel frame
    + [("OBJ", 0)] * 3       # 53-55 swim (player OBJ palette)
    + [("OBJ", 2)]           # 56 splash burst
    + [("BG", 2)]            # 57 sand (desert)
    + [("BG", 0)]            # 58 cactus
    + [("BG", 1)]            # 59 snow (tundra)
    + [("BG", 1)]            # 60 ice
    + [("BG", 2)]            # 61 grave
    + [("BG", 0)]            # 62 wheat
    + [("BG", 2)]            # 63 fence
)

# personas: 3 tiles each (down/up/side) on their PO_PAL (dialogue_data.asm),
# then the car's 8 quadrants, the 5 loot sprites and the exhaust puff.
_PERSONA_POPAL = [3, 4, 5, 6, 7, 6, 4, 6, 3, 7]  # police..farmer
_PERSONA_PAL = (
    [("OBJ", p) for p in _PERSONA_POPAL for _ in range(3)]   # 30 persona tiles
    + [("OBJ", 0)] * 8                                       # car 2x2 quadrants
    + [("OBJ", 0), ("OBJ", 2), ("OBJ", 1),                  # apple, beans, crate
       ("OBJ", 1), ("OBJ", 2)]                              # pot, chest
    + [("OBJ", 6)]                                          # exhaust puff (charcoal)
    # battle target-bar cells + crosshair. The zone tiles are drawn in-game on a
    # DYNAMIC palette (battle.asm ZonePalette), not a gfx.asm one — the round-trip
    # just needs SOME 4-distinct-colour palette to be lossless, so pin them to BG3
    # (a terrain palette). The crosshair uses its real OBJ palette (bubble/cursor).
    + [("BG", 3), ("BG", 3), ("BG", 3), ("OBJ", 2)]        # zone R/A/G, crosshair
)

TILE_PALETTES = {
    "Tiles": _TILES_PAL,
    "PersonaTiles": _PERSONA_PAL,
    "Font1bpp": [("BG", 4)] * 53,   # every glyph is talk-UI paper/ink
}

COLS = 16   # atlas width in tiles; blocks/groups wrap at this width
TILE = 8    # px per tile edge


# --- atlas grouping: multi-tile objects render as their real 2D shape ----------
# A group is (w, h, [(dx, dy), ...]) and consumes len(offsets) CONSECUTIVE tiles
# (in gfx.asm order) placed at those cell offsets inside a w x h box. Groups are
# shelf-packed left-to-right (wrapping at COLS), each block starting a fresh band,
# so a tree/car-side reads as a 2x2, the framed UI corners+edges as a 3x3 frame,
# etc. The atlas cell <-> tile mapping stays deterministic (same for export and
# import), so idempotency holds. Every block's groups must consume EXACTLY its
# tiles, in order — extend these when you add tiles (see CLAUDE.md).
def _tile():
    return (1, 1, [(0, 0)])


def _grid(w, h):
    return (w, h, [(x, y) for y in range(h) for x in range(w)])


# frame tiles are authored TL, TR, BL, BR, then edges T, B, L, R — lay them as a
# 3x3 picture frame (centre cell empty/transparent).
_FRAME = (3, 3, [(0, 0), (2, 0), (0, 2), (2, 2), (1, 0), (1, 2), (0, 1), (2, 1)])

GROUPS = {
    "Tiles": (
        [_tile()] * 10        # 0-9 grass..marsh (single ground tiles)
        + [_grid(2, 2)]       # 10-13 tree (TL TR / BL BR)
        + [_grid(6, 1)]       # 14-19 player walk frames
        + [_grid(6, 1)]       # 20-25 zombie walk frames
        + [_tile(), _tile()]  # 26 alert bubble, 27 menu cursor
        + [_FRAME]            # 28-35 portrait frame
        + [_grid(9, 1)]       # 36-44 affinity bar 0/8..8/8
        + [_FRAME]            # 45-52 UI panel frame
        + [_grid(3, 1)]       # 53-55 swim frames
        + [_tile()]           # 56 splash
        + [_tile()] * 7       # 57-63 sand, cactus, snow, ice, grave, wheat, fence
    ),
    "PersonaTiles": (
        [_grid(3, 1)] * 10    # 10 personas x (down, up, side) kept on one row
        + [_grid(1, 2)]       # car down: top/bottom LEFT halves (right = X-flip)
        + [_grid(1, 2)]       # car up:   top/bottom left halves
        + [_grid(2, 2)]       # car side: TL TR / BL BR (full 2x2)
        + [_tile()] * 5       # loot: apple, beans, crate, pot, chest
        + [_tile()]           # exhaust puff
        + [_tile()] * 4       # battle: zone red/amber/green + crosshair
    ),
    "Font1bpp": [_tile()] * 53,   # glyphs flow COLS per row
}

_ROW2_RE = re.compile(r"^(\s*dw\s+`)([0-3]{8})(.*)$")
_ROW1_RE = re.compile(
    r"^(\s*db\s+)((?:\$[0-9A-Fa-f]{2})(?:\s*,\s*\$[0-9A-Fa-f]{2}){7})(.*)$")
_PAL_RE = re.compile(r"^(\s*dw\s+)(.*?)(\s*)(;.*)?$")
_PAL_EXPR_RE = re.compile(
    r"\(\s*(\d+)\s*<<\s*10\)\s*\|\s*\(\s*(\d+)\s*<<\s*5\)\s*\|\s*(\d+)")
_PAL_HEX_RE = re.compile(r"\$([0-9A-Fa-f]+)")
_LABEL_RE = re.compile(r"^(\w+)::")


# ---- BGR555 <-> 8-bit RGB (the CGB's 5->8 expansion) -------------------------
def _exp5(v):
    return (v << 3) | (v >> 2)


def bgr_to_rgb(v):
    return (_exp5(v & 31), _exp5((v >> 5) & 31), _exp5((v >> 10) & 31))


def rgb_to_bgr(c):
    return ((c[2] >> 3) << 10) | ((c[1] >> 3) << 5) | (c[0] >> 3)


def _parse_bgr(value):
    m = _PAL_EXPR_RE.search(value)
    if m:
        b, g, r = (int(x) for x in m.groups())
        return (b << 10) | (g << 5) | r
    m = _PAL_HEX_RE.search(value)
    if m:
        return int(m.group(1), 16)
    raise SystemExit(f"tilepng: cannot parse palette colour {value!r}")


def _fmt_bgr(v):
    return f"({(v >> 10) & 31} << 10) | ({(v >> 5) & 31} << 5) | {v & 31}"


def _hex(px):
    return "%02X%02X%02X" % (px[0], px[1], px[2])


# ---- gfx.asm reading ---------------------------------------------------------
def load_lines():
    with open(GFX) as f:
        return f.read().split("\n")


def parse_tiles(lines):
    """{block_name: [tile,...]}, tile = 8 rows of 8 ints (0-3), source order.
    1bpp glyph bits are decoded to indices 0 (paper) / 3 (ink)."""
    meta = {b[0]: (b[1], b[2]) for b in TILE_BLOCKS}
    starts, ends = set(meta), {b[1] for b in TILE_BLOCKS}
    tiles = {b[0]: [] for b in TILE_BLOCKS}
    cur = kind = None
    rowbuf = []
    for ln in lines:
        lbl = _LABEL_RE.match(ln)
        if lbl:
            name = lbl.group(1)
            if name in starts:
                cur, kind, rowbuf = name, meta[name][1], []
            elif name in ends:
                cur = kind = None
            continue
        if not cur:
            continue
        if kind == "2bpp":
            m = _ROW2_RE.match(ln)
            if m:
                rowbuf.append([int(ch) for ch in m.group(2)])
                if len(rowbuf) == 8:
                    tiles[cur].append(rowbuf)
                    rowbuf = []
        else:  # 1bpp: one line = one glyph = 8 bytes = 8 rows
            m = _ROW1_RE.match(ln)
            if m:
                bs = [int(h.strip().lstrip("$"), 16) for h in m.group(2).split(",")]
                tiles[cur].append([[3 if (b >> (7 - x)) & 1 else 0
                                    for x in range(8)] for b in bs])
    for name, tl in tiles.items():
        if not tl:
            raise SystemExit(f"tilepng: no tiles found in block {name}::")
        want = len(TILE_PALETTES.get(name, []))
        if want != len(tl):
            raise SystemExit(f"tilepng: TILE_PALETTES[{name!r}] has {want} entries"
                             f" but the block has {len(tl)} tiles — update it")
    return tiles


def parse_palettes(lines):
    """{("BG"|"OBJ", n): [bgr555 x4]} for every palette in the palette blocks."""
    kinds = {b[0]: b[2] for b in PALETTE_BLOCKS}
    ends = {b[1] for b in PALETTE_BLOCKS}
    seq = {b[2]: [] for b in PALETTE_BLOCKS}
    cur = None
    for ln in lines:
        lbl = _LABEL_RE.match(ln)
        if lbl:
            name = lbl.group(1)
            cur = kinds.get(name) if name in kinds else (
                None if name in ends else cur)
            continue
        if cur and re.match(r"^\s*dw\s", ln):
            seq[cur].append(_parse_bgr(_PAL_RE.match(ln).group(2)))
    pals = {}
    for kind, vals in seq.items():
        if len(vals) % 4:
            raise SystemExit(f"tilepng: {kind} palette has {len(vals)} colours "
                             f"(not a multiple of 4)")
        for n in range(len(vals) // 4):
            pals[(kind, n)] = vals[n * 4:n * 4 + 4]
    return pals


# ---- atlas geometry ----------------------------------------------------------
def layout():
    """Atlas placements from GROUPS (shelf-packed). placement = (block_name,
    tile_idx, col, row); returns (placements, grid_rows). Each block starts on a
    fresh band; multi-tile groups occupy their w x h box."""
    placements, y = [], 0
    for name, _end, _kind in TILE_BLOCKS:
        x = band = ti = 0
        for (w, h, offs) in GROUPS[name]:
            if x + w > COLS:
                y += band
                x = band = 0
            for (dx, dy) in offs:
                placements.append((name, ti, x + dx, y + dy))
                ti += 1
            x += w
            band = max(band, h)
        y += band
    return placements, y


def _check_counts(blocks):
    """GROUPS must consume exactly each block's tiles, in order (maintenance)."""
    for name, tiles in blocks.items():
        placed = sum(len(offs) for (_w, _h, offs) in GROUPS[name])
        if placed != len(tiles):
            raise SystemExit(f"tilepng: GROUPS[{name!r}] lays out {placed} tiles "
                             f"but the block has {len(tiles)} — update GROUPS")


# ---- palette reconciliation + tile decode (import) ---------------------------
def _used_palettes():
    keys = set()
    for plist in TILE_PALETTES.values():
        keys.update(plist)
    return keys


def reconcile_palettes(blocks_old, pal_old, px, placements):
    """Work out each used palette's NEW colours from the atlas, telling a colour
    SWAP (a brand-new colour replacing a slot) apart from pixel edits (existing
    colours rearranged). Returns pal_new; raises on any forbidden inconsistency."""
    old_opaque = {}
    for key, cols in pal_old.items():
        slots = range(4) if key[0] == "BG" else (1, 2, 3)
        old_opaque[key] = {cols[i] for i in slots}

    brand = {key: {i: set() for i in range(4)} for key in _used_palettes()}
    for (block, tidx, c, r) in placements:
        key = TILE_PALETTES[block][tidx]
        tile = blocks_old[block][tidx]
        for y in range(TILE):
            for x in range(TILE):
                p = px[c * TILE + x, r * TILE + y]
                if p[3] < 128:                     # transparent
                    continue
                bgr = rgb_to_bgr(p[:3])
                if bgr in old_opaque[key]:
                    continue                       # existing colour -> pixel edit
                if key[0] == "OBJ" and tile[y][x] == 0:
                    raise SystemExit(
                        f"tilepng: new opaque colour #{_hex(p)} at a transparent "
                        f"pixel of {block}[{tidx}] (palette {key[0]}{key[1]}); "
                        f"paint with an existing palette colour, or recolour a "
                        f"slot uniformly")
                brand[key][tile[y][x]].add(bgr)

    pal_new = {k: list(v) for k, v in pal_old.items()}
    for key in _used_palettes():
        assigned = {}
        for i in range(4):
            cand = brand[key][i]
            if not cand:
                continue
            if len(cand) > 1:
                raise SystemExit(
                    f"tilepng: palette {key[0]}{key[1]} slot {i} shows "
                    f"{len(cand)} new colours — a colour swap must replace a slot"
                    f" with exactly ONE new colour")
            (newc,) = tuple(cand)
            if newc in assigned:
                raise SystemExit(
                    f"tilepng: new colour #{_hex(bgr_to_rgb(newc))} replaces both "
                    f"slot {assigned[newc]} and slot {i} of palette "
                    f"{key[0]}{key[1]} — recolour one slot at a time")
            assigned[newc] = i
            pal_new[key][i] = newc
        slots = list(range(4)) if key[0] == "BG" else [1, 2, 3]
        cols = [pal_new[key][i] for i in slots]
        if len(set(cols)) != len(cols):
            raise SystemExit(
                f"tilepng: palette {key[0]}{key[1]} would have duplicate colours "
                f"after the edit — its {len(slots)} colours must stay distinct")
    return pal_new


def decode_tiles(blocks_old, pal_new, px, placements):
    """Recover new 2bpp indices for every tile from the atlas using pal_new."""
    new = {name: [[[0] * TILE for _ in range(TILE)] for _ in tiles]
           for name, tiles in blocks_old.items()}
    for (block, tidx, c, r) in placements:
        key = TILE_PALETTES[block][tidx]
        kind = key[0]
        slots = list(range(4)) if kind == "BG" else [1, 2, 3]
        lut = {pal_new[key][i]: i for i in slots}
        is_font = (block == "Font1bpp")
        for y in range(TILE):
            for x in range(TILE):
                p = px[c * TILE + x, r * TILE + y]
                if p[3] < 128:
                    if kind != "OBJ":
                        raise SystemExit(
                            f"tilepng: transparent pixel in opaque {block}[{tidx}]"
                            f" (palette {kind}{key[1]}) — BG tiles have no "
                            f"transparency")
                    continue  # index 0
                bgr = rgb_to_bgr(p[:3])
                if bgr not in lut:
                    raise SystemExit(
                        f"tilepng: colour #{_hex(p)} in {block}[{tidx}] is not in "
                        f"palette {kind}{key[1]} — repaint it with a palette "
                        f"colour, or recolour that slot for EVERY tile sharing it")
                idx = lut[bgr]
                if is_font and idx not in (0, 3):
                    raise SystemExit(
                        f"tilepng: glyph {block}[{tidx}] uses palette slot {idx}; "
                        f"the 1bpp font can only use paper (slot 0) and ink "
                        f"(slot 3) of palette BG{key[1]}")
                new[block][tidx][y][x] = idx
    return new


# ---- gfx.asm writing (only changed digits / bytes / colours) -----------------
def rewrite_tiles(lines, new_blocks):
    meta = {b[0]: (b[1], b[2]) for b in TILE_BLOCKS}
    starts, ends = set(meta), {b[1] for b in TILE_BLOCKS}
    cur = kind = None
    ti = ri = 0
    out = []
    for ln in lines:
        lbl = _LABEL_RE.match(ln)
        if lbl:
            name = lbl.group(1)
            if name in starts:
                cur, kind, ti, ri = name, meta[name][1], 0, 0
            elif name in ends:
                cur = kind = None
            out.append(ln)
            continue
        if cur and kind == "2bpp":
            m = _ROW2_RE.match(ln)
            if m:
                row = new_blocks[cur][ti][ri]
                out.append(m.group(1) + "".join(map(str, row)) + m.group(3))
                ri += 1
                if ri == 8:
                    ri, ti = 0, ti + 1
                continue
        elif cur and kind == "1bpp":
            m = _ROW1_RE.match(ln)
            if m:
                tile = new_blocks[cur][ti]
                ti += 1
                bs = []
                for row in tile:
                    byte = 0
                    for x in range(8):
                        if row[x] == 3:
                            byte |= 1 << (7 - x)
                    bs.append(f"${byte:02X}")
                out.append(m.group(1) + ",".join(bs) + m.group(3))
                continue
        out.append(ln)
    return "\n".join(out)


def rewrite_palettes(lines, pal_new, pal_old):
    kinds = {b[0]: b[2] for b in PALETTE_BLOCKS}
    ends = {b[1] for b in PALETTE_BLOCKS}
    cur = None
    n = 0
    out = []
    for ln in lines:
        lbl = _LABEL_RE.match(ln)
        if lbl:
            name = lbl.group(1)
            if name in kinds:
                cur, n = kinds[name], 0
            elif name in ends:
                cur = None
            out.append(ln)
            continue
        if cur and re.match(r"^\s*dw\s", ln):
            key, slot = (cur, n // 4), n % 4
            n += 1
            if key in pal_new and pal_new[key][slot] != pal_old[key][slot]:
                m = _PAL_RE.match(ln)
                out.append(m.group(1) + _fmt_bgr(pal_new[key][slot])
                           + m.group(3) + (m.group(4) or ""))
                continue
        out.append(ln)
    return "\n".join(out)


# ---- top-level export / import ----------------------------------------------
def export(gfx=None, atlas=None):
    from PIL import Image
    lines = load_lines() if gfx is None else open(gfx).read().split("\n")
    atlas = atlas or ATLAS
    blocks = parse_tiles(lines)
    pals = parse_palettes(lines)
    names = [b[0] for b in TILE_BLOCKS]
    counts = [len(blocks[n]) for n in names]
    _check_counts(blocks)
    placements, grid_rows = layout()
    img = Image.new("RGBA", (COLS * TILE, grid_rows * TILE), (0, 0, 0, 0))
    px = img.load()
    for (block, tidx, c, r) in placements:
        key = TILE_PALETTES[block][tidx]
        cols = pals[key]
        tile = blocks[block][tidx]
        for y in range(TILE):
            for x in range(TILE):
                i = tile[y][x]
                if key[0] == "OBJ" and i == 0:
                    px[c * TILE + x, r * TILE + y] = (0, 0, 0, 0)
                else:
                    px[c * TILE + x, r * TILE + y] = bgr_to_rgb(cols[i]) + (255,)
    os.makedirs(os.path.dirname(atlas), exist_ok=True)
    img.save(atlas)
    return counts


def import_(gfx=None, atlas=None):
    from PIL import Image
    gfx = gfx or GFX
    atlas = atlas or ATLAS
    lines = open(gfx).read().split("\n")
    blocks = parse_tiles(lines)
    pal_old = parse_palettes(lines)
    names = [b[0] for b in TILE_BLOCKS]
    counts = [len(blocks[n]) for n in names]
    _check_counts(blocks)
    placements, grid_rows = layout()

    img = Image.open(atlas).convert("RGBA")
    exp = (COLS * TILE, grid_rows * TILE)
    if img.size != exp:
        raise SystemExit(
            f"tilepng: atlas is {img.size[0]}x{img.size[1]} but gfx.asm has "
            f"{sum(counts)} tiles (expected {exp[0]}x{exp[1]}). Re-run "
            f"export-tiles.py after adding tiles, or check TILE_BLOCKS.")
    px = img.load()

    pal_new = reconcile_palettes(blocks, pal_old, px, placements)
    new_tiles = decode_tiles(blocks, pal_new, px, placements)

    out = rewrite_tiles(lines, new_tiles)
    out = rewrite_palettes(out.split("\n"), pal_new, pal_old)
    with open(gfx, "w") as f:
        f.write(out)

    changed = [(k, s) for k in sorted(pal_new) for s in range(4)
               if pal_new[k][s] != pal_old[k][s]]
    return counts, changed
