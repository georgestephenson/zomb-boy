"""Player movement: turn-before-walk weight, smooth step timing, and collision.
Facing enum: 0 down, 1 up, 2 left, 3 right.
"""
from worldgen_model import gen_tile_type, SOLID

STEP_TOTAL = 16
TURN_DELAY = 7


def _pos(game):
    return (game.s16("wPlayerWX"), game.s16("wPlayerWY"))


def test_turn_before_walk(game):
    # Player boots facing down (0). Press RIGHT: it should first turn to face
    # right without moving, for ~TURN_DELAY frames, then start walking.
    start = _pos(game)
    game.hold("right")
    game.tick(1)
    assert game.r8("wFacing") == 3, "should face right immediately on press"
    # during the turn delay the tile position must not change yet
    game.tick(TURN_DELAY - 2)
    assert _pos(game) == start, "player moved during the turn-in-place delay"
    # after enough frames it has walked at least one tile
    game.tick(40)
    game.release("right")
    assert _pos(game) != start, "player never walked after turning"


def test_movement_is_weighty_not_instant(game):
    # Walk a long path and record the frame of every tile change. The *smallest*
    # gap between consecutive changes is the free-walk step time — it must be
    # ~STEP_TOTAL, never near-instant (which is what the old teleport felt like).
    changes = []
    last = _pos(game)
    frame = 0
    for d in ["right", "down", "left", "up", "right", "down", "left", "up"]:
        game.hold(d)
        for _ in range(80):
            game.tick(1)
            frame += 1
            p = _pos(game)
            if p != last:
                changes.append(frame)
                last = p
        game.release(d)
        game.tick(2)
        frame += 2
    assert len(changes) >= 5, f"player barely moved ({len(changes)} tile changes)"
    gaps = [b - a for a, b in zip(changes, changes[1:])]
    assert min(gaps) >= STEP_TOTAL - 2, f"a step was too fast: {min(gaps)} frames"


def test_never_stands_on_solid_tile(game):
    # Wander a long, varied path; the player's logical tile must never be solid
    # (tree/wall/water) — that would mean collision let it walk into an obstacle.
    for d in ["right", "down", "left", "up", "right", "right",
              "down", "down", "left", "up", "left", "down"]:
        game.hold(d)
        for _ in range(60):
            game.tick(1)
            x, y = _pos(game)
            t = gen_tile_type(x, y)
            assert t not in SOLID, f"player on solid tile {t} at ({x},{y})"
        game.release(d)
        game.tick(2)
