"""Boot hygiene — the game must not depend on power-on RAM/VRAM being zero.

Real hardware and accurate emulators (mGBA) leave RAM full of garbage at power-on
(PyBoy happens to zero it). If the boot code doesn't sanitize memory, behaviour
becomes garbage-dependent — that caused a total freeze on mGBA. These tests boot
with WRAM+VRAM poisoned to several patterns and assert identical, correct
behaviour, which only holds if boot clears RAM/VRAM.
"""
import pytest
from harness import Game
from worldgen_model import gen_tile_type

POISON_PATTERNS = [0xFF, 0xA5, 0x3C, 0x01]


def _run(poison):
    g = Game(poison=poison)
    try:
        lcd_on = bool(g.r8(0xFF40) & 0x80)
        x0 = g.s16("wPlayerWX")
        g.walk("right", 60)
        x1 = g.s16("wPlayerWX")
        # unused OAM slots hidden (no garbage sprites regardless of RAM state);
        # slots 10..19 are the survivor NPCs, 20 the splash, 21..24 the car's
        # 2x2 sprite, 25..32 world loot (all legitimate — see test_sprites.py);
        # 33+ must stay hidden.
        garbage = [s for s in range(33, 40) if g.sprite(s)["y"] != 0]
        # BG map is valid terrain (VRAM was sanitized, not showing poison).
        # Valid BG tile ids are 0..13 (grass..tree quadrants); anything higher
        # is a sprite tile or garbage leaking into the map.
        bad_tiles = sum(1 for a in range(0x9800, 0x9C00) if g.r8(a) > 13)
        return lcd_on, x0, x1, garbage, bad_tiles
    finally:
        g.close()


@pytest.mark.parametrize("poison", POISON_PATTERNS)
def test_boots_correctly_with_poisoned_memory(poison):
    lcd_on, x0, x1, garbage, bad_tiles = _run(poison)
    assert lcd_on, f"LCD off after boot with poison {poison:#04x} (froze?)"
    assert x0 == 0, f"player start X should be deterministic (0), got {x0}"
    assert 1 <= (x1 - x0) <= 7, f"player didn't move right correctly: {x0}->{x1}"
    assert not garbage, f"garbage sprites with poison {poison:#04x}: {garbage}"
    assert bad_tiles == 0, f"invalid BG tiles with poison {poison:#04x}: {bad_tiles}"


def test_behaviour_identical_across_poison_patterns():
    # The whole point: outcome must not depend on power-on memory.
    results = {p: _run(p)[1:3] for p in POISON_PATTERNS}
    first = next(iter(results.values()))
    for p, r in results.items():
        assert r == first, f"poison {p:#04x} gave different result {r} vs {first}"
