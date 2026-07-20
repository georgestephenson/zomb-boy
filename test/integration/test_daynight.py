"""Day/night palette tint (daynight.asm).

The four terrain BG palettes (0..3) are re-shaded to the time of day by
rewriting palette memory when the clock crosses a bucket boundary. These tests
drive the logic end-to-end via the WRAM buffer the VBlank push streams:

  * ComputeTint fills wTintPal (32 bytes = palettes 0..3, tinted);
  * PushDayNight streams it and clears wTintPending in VBlank.

So a cleared wTintPending after a bucket change proves the whole logic->VBlank
path ran. Colour maths is checked by comparing per-bucket brightness.

Buckets (must match constants.inc DN_* / the dialogue clock):
    MORNING 0 (05..11)  DAY 1 (12..17)  DUSK 2 (18..21)  NIGHT 3 (22..04)
Morning and day are identity, so boot at 08:00 shows the neutral BGPalette.
"""
import pytest
from harness import Game

DN_MORNING, DN_DAY, DN_DUSK, DN_NIGHT = 0, 1, 2, 3


@pytest.fixture
def game():
    g = Game()
    yield g
    g.close()


def read_tint(g):
    """wTintPal -> list of 16 (R,G,B) tuples (BGR555, 0..31 per channel)."""
    base = g.addr("wTintPal")
    out = []
    for i in range(16):
        lo = g.r8(base + i * 2)
        hi = g.r8(base + i * 2 + 1)
        v = lo | (hi << 8)
        out.append((v & 0x1F, (v >> 5) & 0x1F, (v >> 10) & 0x1F))
    return out


def brightness(pal):
    return sum(r + g + b for (r, g, b) in pal)


def channel_sums(pal):
    return (sum(r for r, _, _ in pal),
            sum(g for _, g, _ in pal),
            sum(b for _, _, b in pal))


def set_hour(g, hour, frames=3):
    """Poke the clock to `hour` and let UpdateDayNight re-tint. `frames` stays
    below CLOCK_MINUTE_FRAMES so the poked hour isn't advanced away."""
    g.pyboy.memory[g.addr("wClockH")] = hour
    g.tick(frames)


def test_boot_is_morning_neutral(game):
    """Start hour is 08:00 -> MORNING bucket, identity tint, push consumed."""
    assert game.r8("wDayBucket") == DN_MORNING
    assert game.r8("wTintPending") == 0, "re-tint should have been pushed by now"
    # identity factors mean wTintPal is a faithful copy of BGPalette: non-empty,
    # and a plausibly bright daytime palette.
    day = read_tint(game)
    assert brightness(day) > 0


def test_night_is_darker_and_cooler(game):
    day = read_tint(game)
    set_hour(game, 23)                         # -> NIGHT
    assert game.r8("wDayBucket") == DN_NIGHT
    assert game.r8("wTintPending") == 0, "night re-tint was not pushed"
    night = read_tint(game)
    assert brightness(night) < brightness(day), "night should be dimmer than day"
    dr, dg, db = channel_sums(day)
    nr, ng, nb = channel_sums(night)
    # night factors (R4,G5,B7) knock red down hardest, blue least -> cooler.
    assert nr / dr < nb / db, "night should cool toward blue (red cut more than blue)"


def test_dusk_is_dimmer_but_warm(game):
    day = read_tint(game)
    set_hour(game, 20)                         # -> DUSK
    assert game.r8("wDayBucket") == DN_DUSK
    assert game.r8("wTintPending") == 0
    dusk = read_tint(game)
    assert brightness(dusk) < brightness(day), "dusk should be dimmer than day"
    dr, _, db = channel_sums(day)
    ur, _, ub = channel_sums(dusk)
    # dusk factors (R8,G6,B4) keep red, drop blue -> warmer than daytime balance.
    assert ur / dr > ub / db, "dusk should warm toward red (blue cut more than red)"


def test_returns_to_neutral_at_morning(game):
    day = read_tint(game)
    set_hour(game, 2)                          # -> NIGHT (tinted)
    assert read_tint(game) != day
    set_hour(game, 9)                          # -> MORNING (identity again)
    assert game.r8("wDayBucket") == DN_MORNING
    assert read_tint(game) == day, "morning should restore the neutral palette"


def test_no_retint_within_a_bucket(game):
    """Poking to another hour in the SAME bucket must not re-arm a push (the
    manager stays inert -> no needless VBlank work)."""
    set_hour(game, 13)                         # -> DAY
    assert game.r8("wDayBucket") == DN_DAY
    assert game.r8("wTintPending") == 0
    game.pyboy.memory[game.addr("wClockH")] = 16   # still DAY
    game.tick(3)
    assert game.r8("wTintPending") == 0, "same-bucket hour change must not re-tint"
    assert game.r8("wDayBucket") == DN_DAY
