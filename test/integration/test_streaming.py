"""World streaming correctness — the rendered tilemap must always match the
deterministic generator, at boot and after arbitrary walking. Guards against the
"walk through a tree / tree with water colour" class of streaming bugs.
"""
from worldgen_model import gen_tile_type

SCRN0 = 0x9800
VIEW_COLS, VIEW_ROWS = 20, 18


def _mismatches(game):
    vtx = game.s16("wViewTX")
    vty = game.s16("wViewTY")
    out = []
    for dy in range(VIEW_ROWS):
        for dx in range(VIEW_COLS):
            wx, wy = vtx + dx, vty + dy
            cell = SCRN0 + ((wy & 31) * 32) + (wx & 31)
            got = game.r8(cell)
            exp = gen_tile_type(wx, wy)
            if got != exp:
                out.append((wx, wy, exp, got))
    return out


def test_tilemap_matches_model_at_boot(game):
    m = _mismatches(game)
    assert not m, f"{len(m)} tile mismatches at boot: {m[:8]}"


def test_tilemap_matches_model_after_long_walk(game):
    # sustained motion in each direction stresses column + row streaming and the
    # chunked blit keeping up between steps
    for d in ["right", "down", "left", "up"]:
        game.walk(d, 200)
        m = _mismatches(game)
        assert not m, f"{len(m)} mismatches after long {d}: {m[:8]}"


def test_tilemap_matches_model_zigzag(game):
    for d in ["right", "down", "right", "up", "left", "down",
              "left", "up", "right", "right"]:
        game.walk(d, 45)
        m = _mismatches(game)
        assert not m, f"{len(m)} mismatches after zigzag {d}: {m[:8]}"
