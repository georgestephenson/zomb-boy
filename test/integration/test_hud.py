"""HUD / survival meters (docs/design/03; v0: visible + draining, non-lethal).

The HUD is the hardware window over the top 8 px, sourced from SCRN1 row 0
(hud.asm). These tests verify the row's composition in VRAM, the window
registers, the in-game clock, the drain schedule, and the saturating (no-wrap)
meter rule.
"""
from harness import Game

SCRN1 = 0x9C00

# Mirror of the font layout (constants.inc): FONT_BASE=128, digits at +27.
FONT_BASE = 128
SPACE = FONT_BASE
DIGIT0 = FONT_BASE + 27
COLON = FONT_BASE + 48
HUD_HP = FONT_BASE + 49
HUD_FOOD = FONT_BASE + 50
HUD_ENERGY = FONT_BASE + 51

CLOCK_MINUTE_FRAMES = 10
FOOD_DRAIN_MINS = 8
ENERGY_DRAIN_MINS = 16


def digit(n):
    return DIGIT0 + n


def fmt3(v):
    """Mirror of hud.asm Put3: right-aligned, leading spaces."""
    s = f"{v:3d}"
    return [SPACE if ch == " " else digit(int(ch)) for ch in s]


def row(g):
    return [g.r8(SCRN1 + i) for i in range(20)]


def clock_minutes(g):
    return g.r8("wClockH") * 60 + g.r8("wClockM")


def test_hud_row_and_window_after_boot():
    g = Game()
    try:
        # Window enabled, fetching from SCRN1, positioned over the top band.
        lcdc = g.r8(0xFF40)
        assert lcdc & 0x20, "LCDCF_WINON not set"
        assert lcdc & 0x40, "LCDCF_WIN9C00 not set"
        # The window renders from (WX,WY) to the screen's bottom-right, so the
        # bar sits on the BOTTOM 8 scanlines — a top bar would cover the world.
        assert g.r8(0xFF4A) == 144 - 8, "WY should be 136 (bottom band)"
        assert g.r8(0xFF4B) == 7, "WX should be 7 (leftmost)"

        r = row(g)
        # HP boots full and has no v0 drain; food/energy may already have had
        # a scheduled drain during the boot settle — match the live meters.
        assert r[0:5] == [HUD_HP, digit(1), digit(0), digit(0), SPACE], r
        assert r[5:10] == [HUD_FOOD] + fmt3(g.r8("wFood")) + [SPACE], r
        assert r[10:15] == [HUD_ENERGY] + fmt3(g.r8("wEnergy")) + [SPACE], r
        # Clock: started 08:00; the boot settle only ticks minutes, not the hour.
        assert r[15:17] == [digit(0), digit(8)], r
        assert r[17] == COLON, r
        assert all(DIGIT0 <= t <= DIGIT0 + 9 for t in r[18:20]), r
    finally:
        g.close()


def test_clock_ticks_one_minute_per_period():
    g = Game()
    try:
        m0 = clock_minutes(g)
        g.tick(5 * CLOCK_MINUTE_FRAMES)
        assert clock_minutes(g) - m0 == 5
    finally:
        g.close()


def test_minute_tick_recomposes_row_into_vram():
    g = Game()
    try:
        # Poke a meter; the next minute tick recomposes and PushHUD lands it
        # (no movement here, so no strip frames can defer the push).
        g.pyboy.memory[g.addr("wFood")] = 42
        g.tick(CLOCK_MINUTE_FRAMES + 2)
        assert row(g)[5:9] == [HUD_FOOD, SPACE, digit(4), digit(2)]
    finally:
        g.close()


def test_meters_drain_on_schedule():
    g = Game()
    try:
        f0 = g.r8("wFood")
        assert f0 <= 100
        # 9 in-game minutes contain 1 or 2 multiples of FOOD_DRAIN_MINS (8).
        g.tick(9 * CLOCK_MINUTE_FRAMES)
        f1 = g.r8("wFood")
        assert f0 - 2 <= f1 <= f0 - 1, (f0, f1)
        # Energy drains at half the rate but must have moved off full
        # eventually; force a full period to check it drains at all.
        e0 = g.r8("wEnergy")
        g.tick((ENERGY_DRAIN_MINS + 1) * CLOCK_MINUTE_FRAMES)
        assert g.r8("wEnergy") < e0
        # HP has no drain in v0.
        assert g.r8("wHP") == 100
    finally:
        g.close()


def test_meters_saturate_at_zero():
    g = Game()
    try:
        g.pyboy.memory[g.addr("wFood")] = 0
        g.pyboy.memory[g.addr("wEnergy")] = 0
        # A full energy period covers a food period too.
        g.tick((ENERGY_DRAIN_MINS + 1) * CLOCK_MINUTE_FRAMES)
        assert g.r8("wFood") == 0, "food wrapped below zero"
        assert g.r8("wEnergy") == 0, "energy wrapped below zero"
    finally:
        g.close()


def test_hud_survives_walking():
    g = Game()
    try:
        # Streamed strips must never clobber the window row, and deferred
        # pushes must still land while moving.
        g.walk("right", 5 * 16)
        r = row(g)
        assert r[0] == HUD_HP and r[5] == HUD_FOOD and r[10] == HUD_ENERGY, r
        assert r[17] == COLON, r
    finally:
        g.close()
