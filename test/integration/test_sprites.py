"""Sprite hygiene — regression test for the "white squiggle" (garbage sprites).

We only ever draw the player (slot 0), zombies (1..8) and the alert bubble (9).
All other OAM slots must stay hidden (Y == 0). A bug in ClearShadowOAM once left
slots 10..39 holding a stale counter ramp -> visible garbage on hardware.
"""


def _assert_unused_hidden(game):
    bad = []
    for slot in range(10, 40):
        s = game.sprite(slot)
        if s["y"] != 0:
            bad.append((slot, s))
    assert not bad, f"unused OAM slots not hidden (garbage sprites): {bad}"


def test_no_garbage_sprites_at_boot(game):
    _assert_unused_hidden(game)


def test_no_garbage_sprites_after_walking(game):
    for d in ["right", "down", "left", "up", "right", "down"]:
        game.walk(d, 40)
        _assert_unused_hidden(game)


def test_player_sprite_present_and_centered(game):
    p = game.sprite(0)
    # Player is fixed near screen centre (SPR_X=80, SPR_Y=88 in OAM coords).
    assert p["y"] == 88 and p["x"] == 80, f"player sprite misplaced: {p}"
    # Player OBJ tiles are 14..19 (TILE_PLAYER_BASE..).
    assert 14 <= p["tile"] < 20, f"player using a non-player tile: {p['tile']}"
