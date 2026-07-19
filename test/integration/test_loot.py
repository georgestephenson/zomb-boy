"""World loot (loot.asm): dynamic pickups + breakable containers.

Loot rides the same pool machinery as the entities: it seeds near the spawn
(FOOD only, so nothing blocks the movement tests), respawns biome-flavoured in a
ring as you explore, and despawns when far. Food (apple/beans) is non-solid and
grabbed by walking over it or facing+A; containers (crate/pot/chest) are solid
and opened with A, dropping loot into the bag or, for a ration, into the food
meter. These tests plant loot directly (positions/kinds) to drive each path.
"""
ENT_SIZE = 16
EO_ACTIVE, EO_WXLO, EO_WYLO, EO_KIND = 0, 1, 3, 5
LOOT_APPLE, LOOT_BEANS, LOOT_CRATE, LOOT_POT, LOOT_CHEST = range(5)
MAX_LOOT = 8
ENT_CULL_DIST = 15
APPLE_FOOD, BEANS_FOOD = 10, 25
BAG_MAX = 20


def _s16(v):
    return v - 0x10000 if v >= 0x8000 else v


def _w16(g, addr, val):
    g.pyboy.memory[addr] = val & 0xFF
    g.pyboy.memory[addr + 1] = (val >> 8) & 0xFF


def _loot(g):
    base = g.addr("wLoot")
    out = []
    for i in range(MAX_LOOT):
        b = base + i * ENT_SIZE
        if g.r8(b + EO_ACTIVE):
            out.append((i, _s16(g.r16(b + EO_WXLO)), _s16(g.r16(b + EO_WYLO)),
                        g.r8(b + EO_KIND)))
    return out


def _free_slot(g):
    base = g.addr("wLoot")
    for i in range(MAX_LOOT):
        if not g.r8(base + i * ENT_SIZE + EO_ACTIVE):
            return i
    return None


def _plant(g, slot, x, y, kind):
    b = g.addr("wLoot") + slot * ENT_SIZE
    g.pyboy.memory[b + EO_ACTIVE] = 1
    _w16(g, b + EO_WXLO, x & 0xFFFF)
    _w16(g, b + EO_WYLO, y & 0xFFFF)
    g.pyboy.memory[b + EO_KIND] = kind


def _bag_total(g):
    base = g.addr("wBag")
    return sum(g.r8(base + i * 2 + 1) for i in range(BAG_MAX))


def _press_a(g):
    g.hold("a")
    g.tick(3)
    g.release("a")
    g.tick(3)


def _player(g):
    return (g.s16("wPlayerWX"), g.s16("wPlayerWY"))


# --- seeding ------------------------------------------------------------------

def test_boot_scatters_food_near_spawn(game):
    """The starting scatter is FOOD only (non-solid) so it can't block the walk
    paths the movement tests drive — and there are several of them."""
    items = _loot(game)
    assert len(items) >= 3, f"expected several starting pickups, got {items}"
    for i, x, y, kind in items:
        assert kind in (LOOT_APPLE, LOOT_BEANS), \
            f"boot loot slot {i} is a container ({kind}) near spawn"


# --- food -------------------------------------------------------------------

def test_walking_over_food_eats_it(game):
    """Stepping onto a food tile auto-collects it: the object vanishes and the
    hunger meter climbs by the right amount (saturating)."""
    food = [t for t in _loot(game) if t[3] in (LOOT_APPLE, LOOT_BEANS)]
    assert food, "no boot food to collect"
    slot, x, y, kind = food[0]
    game.pyboy.memory[game.addr("wFood")] = 40   # leave headroom below the cap
    _w16(game, game.addr("wPlayerWX"), x & 0xFFFF)
    _w16(game, game.addr("wPlayerWY"), y & 0xFFFF)
    game.tick(6)
    assert game.r8(game.addr("wLoot") + slot * ENT_SIZE + EO_ACTIVE) == 0, \
        "food object not consumed after walking onto it"
    want = 40 + (APPLE_FOOD if kind == LOOT_APPLE else BEANS_FOOD)
    assert game.r8("wFood") == want, f"food meter {game.r8('wFood')} != {want}"


# --- containers ---------------------------------------------------------------

def test_a_crate_blocks_walking(game):
    """A crate is solid: you can't walk onto its tile (you break it, not step on
    it). Planted one tile to the player's right; walking right must not pass it."""
    px, py = _player(game)
    slot = _free_slot(game)
    assert slot is not None
    _plant(game, slot, px + 1, py, LOOT_CRATE)
    game.walk("right", 40)
    assert game.s16("wPlayerWX") == px, \
        f"walked past a solid crate: {_player(game)}"


def test_opening_a_container_yields_loot_and_removes_it(game):
    """Facing a crate and pressing A breaks it: the object is gone and something
    was granted — a bag item, or a ration into the food meter."""
    px, py = _player(game)
    game.pyboy.memory[game.addr("wFacing")] = 3   # face right
    slot = _free_slot(game)
    _plant(game, slot, px + 1, py, LOOT_CRATE)
    bag0, food0 = _bag_total(game), game.r8("wFood")
    _press_a(game)
    assert game.r8(game.addr("wLoot") + slot * ENT_SIZE + EO_ACTIVE) == 0, \
        "crate not consumed by A"
    grew = _bag_total(game) > bag0 or game.r8("wFood") > food0
    assert grew, "opening a crate granted nothing (no bag item, no food)"
    assert (game.s16("wPlayerWX"), game.s16("wPlayerWY")) == (px, py), \
        "opening a container should not move the player"


def test_chest_opens_too(game):
    """Chests use the valuable table; opening one still consumes it and drops a
    bag item (chest loot is all gear)."""
    px, py = _player(game)
    game.pyboy.memory[game.addr("wFacing")] = 3
    slot = _free_slot(game)
    _plant(game, slot, px + 1, py, LOOT_CHEST)
    bag0 = _bag_total(game)
    _press_a(game)
    assert game.r8(game.addr("wLoot") + slot * ENT_SIZE + EO_ACTIVE) == 0
    assert _bag_total(game) == bag0 + 1, "chest should drop exactly one bag item"


# --- the pool discipline (cull / cap / replenish) -----------------------------

def test_loot_is_culled_and_replenished_as_you_explore(game):
    """Leave the spawn behind: every surviving loot object is within the cull
    radius of the new location, the pool never exceeds its cap, and the world
    still offers loot (respawned in a ring around you)."""
    _w16(game, game.addr("wPlayerWX"), 260)
    _w16(game, game.addr("wPlayerWY"), -180)
    game.tick(260)
    px, py = _player(game)
    items = _loot(game)
    assert len(items) <= MAX_LOOT, f"loot cap exceeded: {len(items)}"
    for i, x, y, kind in items:
        d = max(abs(x - px), abs(y - py))
        assert d <= ENT_CULL_DIST, f"loot slot {i} is {d} tiles away (> cull)"
    assert items, "no loot respawned around the player after exploring"


def test_exploring_turns_up_containers(game):
    """The whole point of crates/chests: they appear out in the world (not at
    spawn). After wandering, at least one container has been spawned."""
    seen = set()
    for x, y in ((150, 0), (-140, 90), (0, 220), (300, 300)):
        _w16(game, game.addr("wPlayerWX"), x)
        _w16(game, game.addr("wPlayerWY"), y)
        game.tick(180)
        seen.update(k for *_, k in _loot(game))
    assert seen & {LOOT_CRATE, LOOT_POT, LOOT_CHEST}, \
        f"exploring never produced a container: kinds seen {sorted(seen)}"
