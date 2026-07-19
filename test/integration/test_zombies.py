"""Zombie behaviour: they spawn, wander over time, and — the regression that
mattered — their ON-SCREEN motion stays smooth whether the player is standing
still or walking (the camera lag must be applied to sprites too, else zombies
appear to zoom around when the player moves).
"""
ENT_SIZE = 16
EO_ACTIVE, EO_WXLO, EO_WYLO, EO_FACING, EO_DIR = 0, 1, 3, 5, 6
MAX_ZOMBIES = 8
EFACE_LEFT = 2
MODE_OVERWORLD, MODE_ALERT = 0, 1


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


def _plant_zombie_facing_player(game):
    """Park zombie 0 one tile right of the player, idle, facing left at it — an
    unobstructed adjacent line, so CheckLOS resolves immediately."""
    px, py = game.r16("wPlayerWX"), game.r16("wPlayerWY")
    base = game.addr("wZombies")

    def w16(a, v):
        game.pyboy.memory[a] = v & 0xFF
        game.pyboy.memory[a + 1] = (v >> 8) & 0xFF

    game.pyboy.memory[base + EO_ACTIVE] = 1
    w16(base + EO_WXLO, (px + 1) & 0xFFFF)
    w16(base + EO_WYLO, py & 0xFFFF)
    game.pyboy.memory[base + EO_FACING] = EFACE_LEFT
    game.pyboy.memory[base + EO_DIR] = 0xFF  # idle: won't wander off this frame


def test_los_detects_player_on_land():
    # Control for the swim test: a zombie staring at the adjacent player raises
    # the alert (switches to MODE_ALERT).
    # Tick a couple frames, not one: a single PyBoy frame need not span the main
    # loop's UpdateZombies (the loop is VBlank-locked, so where the frame boundary
    # falls in it shifts with any code-size change), and MODE_ALERT persists for
    # ALERT_FRAMES once set — so 2 frames reliably captures the detection.
    from harness import Game
    g = Game()
    try:
        g.pyboy.memory[g.addr("wSwimming")] = 0
        _plant_zombie_facing_player(g)
        g.tick(2)
        assert g.r8("wGameMode") == MODE_ALERT, "zombie should spot the player"
    finally:
        g.close()


def test_los_blind_while_player_swims():
    # In the water the player is hidden: the same staring zombie must not detect
    # (over the same 2-frame window the land control uses).
    from harness import Game
    g = Game()
    try:
        g.pyboy.memory[g.addr("wSwimming")] = 1
        _plant_zombie_facing_player(g)
        g.tick(2)
        assert g.r8("wGameMode") == MODE_OVERWORLD, "swimming player was detected"
    finally:
        g.close()
