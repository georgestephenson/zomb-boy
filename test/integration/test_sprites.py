"""Sprite hygiene — regression test for the "white squiggle" (garbage sprites).

We only ever draw the player (slot 0), zombies (1..8), the alert bubble (9),
survivor NPCs (10..19), the water splash (20) and the car (21..24 — a 2x2
sprite). All other OAM slots must stay hidden (Y == 0). A bug in ClearShadowOAM
once left slots holding a stale counter ramp -> visible garbage on hardware.
"""
FIRST_UNUSED_SLOT = 25  # after OAM_SPLASH (20) + the car's 2x2 block (21..24)


def _assert_unused_hidden(game):
    bad = []
    for slot in range(FIRST_UNUSED_SLOT, 40):
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


def test_npc_sprites_use_survivor_tiles_and_palettes(game):
    """Regression: NPCTileAttr once clobbered DrawNPCs' OAM pointer, so
    visible NPCs kept tile 0 (grass) / palette 0 — near-invisible ghosts.
    Every on-screen NPC must use its persona's own world sprite (3 tiles per
    persona from TILE_PSURV_BASE = 181: down/up/side; NPC in OAM slot
    OAM_NPC0+i spawned with persona i) and an OBJ palette 3..7."""
    PSURV_BASE = 181
    seen = 0
    for slot in range(10, 20):  # OAM_NPC0 .. +MAX_NPCS
        s = game.sprite(slot)
        if s["y"] == 0:
            continue  # off-screen / culled
        seen += 1
        persona = slot - 10
        expect = range(PSURV_BASE + persona * 3, PSURV_BASE + persona * 3 + 3)
        assert s["tile"] in expect, \
            f"NPC slot {slot} (persona {persona}) has tile {s['tile']}, " \
            f"expected one of {list(expect)}: {s}"
        assert 3 <= (s["attr"] & 0x07) <= 7, \
            f"NPC slot {slot} has bad OBJ palette: {s}"
    assert seen >= 2, "expected several NPCs visible near the start"
