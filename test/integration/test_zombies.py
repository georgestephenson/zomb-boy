"""Zombie behaviour: they spawn, wander over time, and — the regression that
mattered — their ON-SCREEN motion stays smooth whether the player is standing
still or walking (the camera lag must be applied to sprites too, else zombies
appear to zoom around when the player moves).
"""
ENT_SIZE = 16
EO_ACTIVE, EO_WXLO, EO_WYLO, EO_FACING, EO_DIR, EO_TIMER = 0, 1, 3, 5, 6, 8
MAX_ZOMBIES, MAX_NPCS = 8, 10
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


def _w16(game, a, v):
    game.pyboy.memory[a] = v & 0xFF
    game.pyboy.memory[a + 1] = (v >> 8) & 0xFF


def _clear_pool(game, name, count):
    base = game.addr(name)
    for i in range(count):
        game.pyboy.memory[base + i * ENT_SIZE + EO_ACTIVE] = 0


def _plant_zombie_facing_player(game, dist=1):
    """Park zombie 0 `dist` tiles right of the player, idle, facing left at it —
    an unobstructed line, so CheckLOS resolves as soon as the player is settled.
    A big EO_TIMER keeps it from re-planning (wandering) during the test window."""
    px, py = game.r16("wPlayerWX"), game.r16("wPlayerWY")
    base = game.addr("wZombies")
    game.pyboy.memory[base + EO_ACTIVE] = 1
    _w16(game, base + EO_WXLO, (px + dist) & 0xFFFF)
    _w16(game, base + EO_WYLO, py & 0xFFFF)
    game.pyboy.memory[base + EO_FACING] = EFACE_LEFT
    game.pyboy.memory[base + EO_DIR] = 0xFF  # idle
    game.pyboy.memory[base + EO_TIMER] = 250  # ...and frozen there (won't wander)


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


def test_los_keys_off_arrived_tile_not_step_start():
    # THE timing bug: the encounter must fire only once the player has FINISHED
    # stepping onto a tile, not the instant the logical tile jumps at step start.
    # LOS is tested against wSeen (the arrived tile), which lags the logical tile
    # while mid-step. Proof, decoupled from frame timing: with the logical tile in
    # the zombie's line but the ARRIVED tile off it, no alert; snap the arrived
    # tile onto the line and the very same zombie now spots the player.
    from harness import Game
    g = Game()
    try:
        g.pyboy.memory[g.addr("wSwimming")] = 0
        _clear_pool(g, "wZombies", MAX_ZOMBIES)   # only our planted zombie may alert
        _plant_zombie_facing_player(g)            # in line with the LOGICAL tile
        px, py = g.r16("wPlayerWX"), g.r16("wPlayerWY")
        # mid-step: arrived tile is still a row away from the zombie's sight line
        _w16(g, g.addr("wSeenWX"), px)
        _w16(g, g.addr("wSeenWY"), (py + 3) & 0xFFFF)
        g.tick(2)
        assert g.r8("wGameMode") == MODE_OVERWORLD, "alerted before the step finished"
        # step finished: the arrived tile catches up to the logical tile
        _w16(g, g.addr("wSeenWX"), px)
        _w16(g, g.addr("wSeenWY"), py)
        g.tick(2)
        assert g.r8("wGameMode") == MODE_ALERT, "no alert after arriving on the tile"
    finally:
        g.close()


def test_zombie_charges_the_player_then_battles():
    # Once spotted, the alerting zombie walks straight at the player (everything
    # else frozen) and the battle fires when it arrives. Here: plant it three
    # tiles out in a clear line, let it detect, then watch it close the gap while
    # the player stays put — and finally resolve into a battle (mode returns to
    # the overworld with the zombie removed).
    from harness import Game
    g = Game()
    try:
        g.pyboy.memory[g.addr("wSwimming")] = 0
        _clear_pool(g, "wZombies", MAX_ZOMBIES)
        _clear_pool(g, "wNPCs", MAX_NPCS)         # keep the charge lane clear
        # relocate the player onto a row that's clear for three tiles to its right
        # (the classic-seed spawn row has trees), so the whole charge lane is open.
        for nm in ("wPlayerWX", "wSeenWX"):
            _w16(g, g.addr(nm), 0)
        for nm in ("wPlayerWY", "wSeenWY"):
            _w16(g, g.addr(nm), 0xFFFF)           # y = -1
        # hold off the respawner so slot 0 stays empty right after the battle
        # (else a fresh zombie refills it before we can observe the removal)
        g.pyboy.memory[g.addr("wZombSpawnTimer")] = 200
        _plant_zombie_facing_player(g, dist=3)
        zx0 = _ent16(g, 0, EO_WXLO)
        px0, py0 = g.r16("wPlayerWX"), g.r16("wPlayerWY")
        g.tick(2)
        assert g.r8("wGameMode") == MODE_ALERT, "zombie should spot the player"
        # through the "!" beat and a couple of charge steps
        g.tick(60)
        zx_mid = _ent16(g, 0, EO_WXLO)
        assert zx_mid < zx0, "zombie did not advance toward the player"
        assert g.r16("wPlayerWX") == px0 and g.r16("wPlayerWY") == py0, \
            "player moved during the charge (should be frozen)"
        # let it reach the player and run the (placeholder) battle; the charge
        # exits alert mode only via the battle, so OVERWORLD again == it resolved
        resolved = False
        for _ in range(240):
            g.tick(1)
            if g.r8("wGameMode") == MODE_OVERWORLD:
                assert _ent(g, 0, EO_ACTIVE) == 0, "battle should remove the zombie"
                resolved = True
                break
        assert resolved, "charge never reached the player / resolved into a battle"
    finally:
        g.close()
