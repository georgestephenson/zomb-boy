"""Player <-> zombie collision: they must never occupy the same tile. Before the
fix, player movement ignored zombies, so you could walk straight through them.
"""
ENT_SIZE = 16
EO_ACTIVE, EO_WXLO, EO_WYLO = 0, 1, 3
MAX_ZOMBIES = 8


def _player(game):
    return (game.s16("wPlayerWX"), game.s16("wPlayerWY"))


def _zombie_tiles(game):
    base = game.addr("wZombies")
    out = []
    for i in range(MAX_ZOMBIES):
        b = base + i * ENT_SIZE
        if game.r8(b + EO_ACTIVE):
            wx = game.r16(b + EO_WXLO)
            wy = game.r16(b + EO_WYLO)
            wx = wx - 0x10000 if wx >= 0x8000 else wx
            wy = wy - 0x10000 if wy >= 0x8000 else wy
            out.append((wx, wy))
    return out


def test_player_never_shares_tile_with_zombie(game):
    # Wander a long, varied path (zombies are clustered near spawn, so we cross
    # them repeatedly). At no frame may the player's tile equal a zombie's tile.
    for d in ["right", "down", "left", "up", "left", "down",
              "right", "up", "right", "down", "left", "up"]:
        game.hold(d)
        for _ in range(70):
            game.tick(1)
            p = _player(game)
            zs = _zombie_tiles(game)
            assert p not in zs, f"player {p} overlapped a zombie at {p}"
        game.release(d)
        game.tick(2)
