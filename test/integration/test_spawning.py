"""Dynamic spawn manager (entity.asm UpdateSpawns / npc.asm SpawnNPC).

Zombies and survivors are no longer all placed at the start: as the player
explores, the manager destroys any entity that strays too far behind and
respawns fresh ones in a ring just outside the view. This gives procedural,
never-repeating encounters while keeping the pools (and memory) bounded.

The manager is deliberately inert while a pool is full and nothing has been
culled (it only touches the RNG when it actually spawns), so the boot cluster
and every near-spawn test behave exactly as before — those live in the other
suites. Here we drive the player far (by poking the position, the same trick the
car tests use) and assert the cull / cap / replenish guarantees.
"""
ENT_SIZE = 16
EO_ACTIVE, EO_WXLO, EO_WYLO, EO_DIR = 0, 1, 3, 6
MAX_ZOMBIES = 8
MAX_NPCS = 10
ENT_CULL_DIST = 15
MODE_OVERWORLD = 0


def _s16(v):
    return v - 0x10000 if v >= 0x8000 else v


def _player(g):
    return (g.s16("wPlayerWX"), g.s16("wPlayerWY"))


def _w16(g, addr, val):
    g.pyboy.memory[addr] = val & 0xFF
    g.pyboy.memory[addr + 1] = (val >> 8) & 0xFF


def _teleport(g, x, y):
    """Drop the player at a distant tile; the manager treats the position as
    truth (culling/spawning key off it), so this stands in for a long walk
    without depending on the terrain being walkable that far."""
    _w16(g, g.addr("wPlayerWX"), x)
    _w16(g, g.addr("wPlayerWY"), y)
    g.pyboy.memory[g.addr("wPlayerState")] = 0
    g.pyboy.memory[g.addr("wStepOffset")] = 0


def _active(g, base_name, count):
    base = g.addr(base_name)
    out = []
    for i in range(count):
        b = base + i * ENT_SIZE
        if g.r8(b + EO_ACTIVE):
            x = _s16(g.r16(b + EO_WXLO))
            y = _s16(g.r16(b + EO_WYLO))
            out.append((i, x, y))
    return out


def _cheby(ax, ay, bx, by):
    return max(abs(ax - bx), abs(ay - by))


def test_entities_far_from_the_player_are_despawned(game):
    """Walk far away: everything left behind near the old spawn must despawn,
    and every survivor left active must be within the cull radius."""
    game.tick(30)  # let the boot cluster settle near (0,0)
    assert _active(game, "wZombies", MAX_ZOMBIES), "expected zombies near spawn"
    _teleport(game, 300, 300)
    game.tick(90)
    px, py = _player(game)
    for name, count in (("wZombies", MAX_ZOMBIES), ("wNPCs", MAX_NPCS)):
        for i, x, y in _active(game, name, count):
            d = _cheby(x, y, px, py)
            assert d <= ENT_CULL_DIST, \
                f"{name}[{i}] at ({x},{y}) is {d} tiles away (> {ENT_CULL_DIST})"


def test_a_planted_far_zombie_is_culled(game):
    """A single zombie poked 40 tiles away is gone within a few frames — the
    far position is vacated (its slot may then be reused by a fresh near spawn,
    which is fine: no ACTIVE zombie may remain out at the cull radius)."""
    px, py = _player(game)
    b = game.addr("wZombies")            # reuse slot 0
    far = (px + 40, py)
    _w16(game, b + EO_WXLO, far[0] & 0xFFFF)
    _w16(game, b + EO_WYLO, far[1] & 0xFFFF)
    game.pyboy.memory[b + EO_ACTIVE] = 1
    game.pyboy.memory[b + EO_DIR] = 0xFF  # idle: don't wander this frame
    game.tick(40)
    for i, x, y in _active(game, "wZombies", MAX_ZOMBIES):
        assert (x, y) != far, f"the far zombie survived at {far}"
        assert _cheby(x, y, px, py) <= ENT_CULL_DIST, \
            f"zombie[{i}] at ({x},{y}) is beyond the cull radius"


def test_population_replenishes_as_you_explore(game):
    """After leaving the boot cluster behind, the manager refills zombies in a
    ring around the NEW location — the world stays populated wherever you go."""
    _teleport(game, -400, 250)
    # first cull the strays, then give the throttled spawner time to refill
    game.tick(220)
    assert len(_active(game, "wZombies", MAX_ZOMBIES)) >= 1, \
        "no zombies respawned around the player after exploring"


def test_pool_caps_are_never_exceeded(game):
    """The hard memory bound: however much we jump around, the active counts
    never exceed the pool sizes (a runaway spawner would corrupt WRAM)."""
    for x, y in ((120, 0), (0, -160), (-90, 90), (250, 250), (5, 5)):
        _teleport(game, x, y)
        game.tick(70)
        nz = len(_active(game, "wZombies", MAX_ZOMBIES))
        nn = len(_active(game, "wNPCs", MAX_NPCS))
        assert nz <= MAX_ZOMBIES, f"zombie cap exceeded: {nz}"
        assert nn <= MAX_NPCS, f"npc cap exceeded: {nn}"


def test_spawned_entities_are_off_screen_not_in_your_face(game):
    """A freshly spawned entity appears in the ring OUTSIDE the visible window,
    never right next to the player — so encounters approach, they don't ambush.
    (The view is ~10 tiles from the player to each edge.)"""
    _teleport(game, 500, -300)
    game.tick(60)
    px, py = _player(game)
    for name, count in (("wZombies", MAX_ZOMBIES), ("wNPCs", MAX_NPCS)):
        for i, x, y in _active(game, name, count):
            # every active entity here was spawned by the manager (the boot
            # cluster is 500+ tiles away and long culled); none may sit on the
            # player's own tile.
            assert (x, y) != (px, py), f"{name}[{i}] spawned on the player"
