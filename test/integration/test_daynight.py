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
MODE_OVERWORLD = 0


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


def read_live_pal(g, n=32):
    """The 32 bytes actually in BG palette RAM (palettes 0..3), read via BCPS/BCPD.
    This is what the hardware shows — as opposed to wTintPal, the WRAM buffer.
    PyBoy doesn't auto-increment the index on reads, so set it per byte."""
    out = []
    for i in range(n):
        g.pyboy.memory[0xFF68] = i          # rBCPS: palette-RAM index (no autoinc)
        out.append(g.pyboy.memory[0xFF69])  # rBCPD
    return out


def go_night(g):
    """Enter night at the very start so the main loop's own ticks apply the tint
    (a poke + a separate tick(N) would shift the zombie-detection frame phase)."""
    g.pyboy.memory[g.addr("wClockH")] = 23


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


# --- the tint must survive the modes that leave the overworld ----------------
# The tint lives in BG palette RAM 0..3. Menu and talk never touch those, so it
# persists; the battle flash reloads the NEUTRAL palettes (LoadPalettes), so it
# must invalidate the applied bucket to force a re-tint on return. These drive
# each mode end-to-end and assert BG palette RAM still holds the night tint after.

import test_zombies as tz
import test_talk as tt


def test_tint_survives_battle(game):
    """A zombie catching you runs the placeholder battle flash, which restores
    neutral palettes. On return the world must be re-tinted, not left daytime."""
    g = game
    go_night(g)                                # loop ticks below apply it
    g.pyboy.memory[g.addr("wSwimming")] = 0
    tz._clear_pool(g, "wZombies", tz.MAX_ZOMBIES)
    tz._clear_pool(g, "wNPCs", tz.MAX_NPCS)
    for nm in ("wPlayerWX", "wSeenWX"):
        tz._w16(g, g.addr(nm), 0)
    for nm in ("wPlayerWY", "wSeenWY"):
        tz._w16(g, g.addr(nm), 0xFFFF)         # a clear charge lane (y = -1)
    g.pyboy.memory[g.addr("wZombSpawnTimer")] = 200
    for _ in range(6):                         # re-pin until detection (frame-phase)
        tz._plant_zombie_facing_player(g, dist=3)
        g.tick(1)
        if g.r8("wGameMode") == tz.MODE_ALERT:
            break
    assert g.r8("wGameMode") == tz.MODE_ALERT, "zombie should spot the player"
    night = read_live_pal(g)                    # night tint, live, pre-battle
    assert g.r8("wDayBucket") == DN_NIGHT
    for _ in range(300):                        # "!" beat -> charge -> battle -> overworld
        g.tick(1)
        if g.r8("wGameMode") == MODE_OVERWORLD:
            break
    g.tick(3)                                   # let the overworld re-tint
    assert read_live_pal(g) == night, "battle left the world daytime (tint not re-applied)"


def test_tint_survives_menu(game):
    """The START pause menu lives on SCRN1 and never rewrites palettes 0..3, so
    the tint persists across open/close with no re-apply."""
    g = game
    go_night(g)
    g.tick(2)
    night = read_live_pal(g)
    assert g.r8("wDayBucket") == DN_NIGHT
    g.hold("start"); g.tick(3); g.release("start"); g.tick(4)   # open
    assert g.r8("wGameMode") == 3, "START should open the menu (MODE_MENU)"
    assert read_live_pal(g) == night, "menu open changed the tint"
    g.hold("start"); g.tick(3); g.release("start"); g.tick(4)   # close
    assert g.r8("wGameMode") == 0
    assert read_live_pal(g) == night, "menu close changed the tint"


def test_tint_survives_talk(game):
    """The dialogue screen lives on SCRN1 and only touches the portrait palettes
    (5..7), so the terrain tint persists across a conversation."""
    g = game
    go_night(g)
    tt.goto_npc0(g)                            # walk to the survivor (still night)
    night = read_live_pal(g)
    assert g.r8("wDayBucket") == DN_NIGHT
    tt.start_talk(g)
    assert g.r8("wGameMode") == 2, "A next to a survivor should open talk"
    assert read_live_pal(g) == night, "talk open changed the tint"
    for _ in range(8):                         # back out to the overworld
        tt.press(g, "b")
        if g.r8("wGameMode") == 0:
            break
    assert g.r8("wGameMode") == 0
    assert read_live_pal(g) == night, "talk close changed the tint"
