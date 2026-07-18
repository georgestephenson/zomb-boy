"""Zombie behaviour: they spawn, wander over time, and — the regression that
mattered — their ON-SCREEN motion stays smooth whether the player is standing
still or walking (the camera lag must be applied to sprites too, else zombies
appear to zoom around when the player moves).
"""
ENT_SIZE = 16
EO_ACTIVE, EO_WXLO, EO_WYLO, EO_DIR = 0, 1, 3, 6
MAX_ZOMBIES = 8


def _ent(game, i, off):
    return game.r8(game.addr("wZombies") + i * ENT_SIZE + off)


def _ent16(game, i, off):
    b = game.addr("wZombies") + i * ENT_SIZE + off
    return game.r16(b)


def test_zombies_spawn_active(game):
    n = sum(_ent(game, i, EO_ACTIVE) for i in range(MAX_ZOMBIES))
    assert n >= 4, f"expected several active zombies, got {n}"


def test_zombies_wander(game):
    # over time at least one zombie should change its logical tile position
    start = {i: (_ent16(game, i, EO_WXLO), _ent16(game, i, EO_WYLO))
             for i in range(MAX_ZOMBIES) if _ent(game, i, EO_ACTIVE)}
    game.tick(240)
    moved = 0
    for i, p0 in start.items():
        if _ent(game, i, EO_ACTIVE):
            p1 = (_ent16(game, i, EO_WXLO), _ent16(game, i, EO_WYLO))
            if p1 != p0:
                moved += 1
    assert moved >= 1, "no zombie wandered over 240 frames"


def _max_onscreen_jump(game, frames):
    """Max per-frame on-screen movement of any zombie sprite, counting only
    frames where the sprite stays comfortably on-screen (avoids edge-cull jumps).
    """
    prev = {}
    worst = 0
    for _ in range(frames):
        game.tick(1)
        for slot in range(1, 1 + MAX_ZOMBIES):
            s = game.sprite(slot)
            on = 12 <= s["x"] <= 156 and 20 <= s["y"] <= 148
            if on and slot in prev:
                dx = abs(s["x"] - prev[slot][0])
                dy = abs(s["y"] - prev[slot][1])
                worst = max(worst, dx, dy)
            prev[slot] = (s["x"], s["y"]) if on else None
            if not on:
                prev.pop(slot, None)
    return worst


def test_zombie_motion_smooth_when_idle(game):
    worst = _max_onscreen_jump(game, 90)
    assert worst <= 3, f"zombie sprite jumped {worst}px/frame while player idle"


def test_zombie_motion_smooth_when_player_walks(game):
    # THE regression: holding a direction must not make zombies teleport.
    game.hold("right")
    worst = _max_onscreen_jump(game, 90)
    game.release("right")
    assert worst <= 3, f"zombie sprite jumped {worst}px/frame while player walks"
