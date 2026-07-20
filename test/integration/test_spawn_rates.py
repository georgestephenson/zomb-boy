"""Spawn-rate tuning: survivors are rare (big rewards -> hard to find), zombies
are a touch less common than the pool cap.

Both pools seed a starting cluster near spawn (the older tests depend on it), so
we drive the player far away, let the managers cull the cluster and settle to
their *targets*, and assert the steady-state density around the new location.
"""
ENT_SIZE = 16
EO_ACTIVE = 0
MAX_ZOMBIES = 8
MAX_NPCS = 10
ZOMB_SPAWN_TARGET = 6
NPC_SPAWN_TARGET = 2


def _w16(g, name, val):
    a = g.addr(name)
    g.pyboy.memory[a] = val & 0xFF
    g.pyboy.memory[a + 1] = (val >> 8) & 0xFF


def _active(g, base_name, count):
    base = g.addr(base_name)
    return sum(1 for i in range(count)
               if g.r8(base + i * ENT_SIZE + EO_ACTIVE))


def test_survivors_are_rare_when_exploring(game):
    """Far from the starting cluster only a couple of survivors linger (target 2)
    — down from the old, denser default, so they're a real find."""
    _w16(game, "wPlayerWX", 400)
    _w16(game, "wPlayerWY", -260)
    game.tick(700)  # cull the boot cluster, settle to the survivor target
    n = _active(game, "wNPCs", MAX_NPCS)
    assert n <= NPC_SPAWN_TARGET, f"too many survivors around you: {n}"


def test_zombies_settle_below_the_pool_cap(game):
    """Zombies refill toward their target (6), not the full pool cap (8), so the
    overworld is a little less crowded — but never empty."""
    _w16(game, "wPlayerWX", -350)
    _w16(game, "wPlayerWY", 300)
    game.tick(700)
    n = _active(game, "wZombies", MAX_ZOMBIES)
    assert 1 <= n <= ZOMB_SPAWN_TARGET, f"zombie density off target: {n}"
