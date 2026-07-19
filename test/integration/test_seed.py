"""World-seed capture on the title screen.

The world used to be identical every boot (the seed was an immediate baked into
Hash8). Now the title screen waits for START and derives hWorldSeed from the
press timing (frame counter ^ DIV); SELECT+START forces the classic WORLD_SEED
($A5) so the rest of the suite keeps its reproducible world.

PyBoy is deterministic, so "random" here means: the same press frame always
gives the same seed (reproducible tests), while different press frames give
different seeds — which is exactly the entropy a human supplies on hardware.
"""
from harness import Game
from worldgen_model import DEFAULT_SEED, gen_tile_type, set_seed

SCRN0 = 0x9800


def _bg_row(g, row):
    return bytes(g.r8(SCRN0 + row * 32 + x) for x in range(32))


def _world(g):
    """The visible BG rows + the seed that produced them."""
    return g.r8("hWorldSeed"), b"".join(_bg_row(g, r) for r in range(18))


def test_title_waits_for_start():
    g = Game(seed=None, settle=120)
    try:
        lcdc = g.r8(0xFF40)
        assert lcdc & 0x80, "LCD should be on, showing the title"
        assert not (lcdc & 0x02), "OBJ on — the game started without START"
        assert g.r8("wTitleTick") > 0, "title frame counter not ticking"
    finally:
        g.close()


def test_select_start_forces_classic_seed():
    g = Game()  # default: classic
    try:
        assert g.r8("hWorldSeed") == DEFAULT_SEED
    finally:
        g.close()


def test_press_timing_changes_the_world():
    worlds = {}
    for frame in (100, 133, 167):
        g = Game(seed="random", press_frame=frame)
        try:
            seed, bg = _world(g)
            worlds[frame] = (seed, bg)
        finally:
            g.close()
    seeds = [s for s, _ in worlds.values()]
    assert len(set(seeds)) == len(seeds), f"press timing did not vary the seed: {seeds}"
    bgs = [bg for _, bg in worlds.values()]
    assert len(set(bgs)) == len(bgs), "different seeds rendered identical worlds"


def test_random_world_still_matches_the_model():
    """The generator/model lockstep must hold at ANY seed, not just $A5.
    (The harness re-seeds the model from hWorldSeed after boot.)"""
    g = Game(seed="random", press_frame=111)
    try:
        seed = g.r8("hWorldSeed")
        assert seed != DEFAULT_SEED  # else this repeats test_streaming
        vtx, vty = g.s16("wViewTX"), g.s16("wViewTY")
        mismatches = []
        for dy in range(18):
            for dx in range(20):
                wx, wy = vtx + dx, vty + dy
                got = g.r8(SCRN0 + ((wy & 31) * 32) + (wx & 31))
                if got != gen_tile_type(wx, wy):
                    mismatches.append((wx, wy))
        assert not mismatches, \
            f"BG differs from model at seed 0x{seed:02X}: {mismatches[:8]}"
    finally:
        g.close()
        set_seed(DEFAULT_SEED)
