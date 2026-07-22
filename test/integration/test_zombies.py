"""Zombie behaviour: they spawn, wander over time, and — the regression that
mattered — their ON-SCREEN motion stays smooth whether the player is standing
still or walking (the camera lag must be applied to sprites too, else zombies
appear to zoom around when the player moves).
"""
ENT_SIZE = 16
EO_ACTIVE, EO_WXLO, EO_WYLO, EO_FACING, EO_DIR, EO_TIMER = 0, 1, 3, 5, 6, 8
EO_SLIDE, EO_SLIDEDIR = 11, 12
MAX_ZOMBIES, MAX_NPCS, MAX_LOOT = 8, 10, 8
EFACE_LEFT = 2
MODE_OVERWORLD, MODE_ALERT, MODE_BATTLE = 0, 1, 4


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
    # Re-pin the zombie on the sight line each frame (see the detailed note in
    # test_los_keys_off_arrived_tile_not_step_start): an idle zombie re-plans
    # within a tick, so a one-shot plant only lines up by frame-phase luck that
    # shifts with any ROM code-size change. Re-pinning decouples the LOS check
    # from that phase, so the detection is observed regardless of loop size.
    from harness import Game
    g = Game()
    try:
        for _ in range(6):
            g.pyboy.memory[g.addr("wSwimming")] = 0
            _plant_zombie_facing_player(g)
            g.tick(1)
            if g.r8("wGameMode") == MODE_ALERT:
                break
        assert g.r8("wGameMode") == MODE_ALERT, "zombie should spot the player"
    finally:
        g.close()


def test_los_blind_while_player_swims():
    # In the water the player is hidden: the same staring zombie must not detect.
    # Mirror the land control's re-pin loop so the two are true opposites: pin the
    # zombie in line every frame and assert it STILL never alerts across the whole
    # window (a false positive would show up on any frame).
    from harness import Game
    g = Game()
    try:
        for _ in range(6):
            g.pyboy.memory[g.addr("wSwimming")] = 1
            _plant_zombie_facing_player(g)
            g.tick(1)
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
        px, py = g.r16("wPlayerWX"), g.r16("wPlayerWY")
        # We re-plant the zombie on the sight line every frame: an idle zombie's
        # wander timer drains within a tick and it re-plans, so a one-shot plant
        # only holds it in line by frame-phase luck (which shifts with any ROM
        # size change). Re-pinning each frame decouples the LOS check from that
        # phase — the zombie is provably on the line whenever we sample the mode.
        #
        # mid-step: the arrived tile (wSeen) is a row off the zombie's sight line,
        # so even with the zombie pinned in line it must NOT alert (LOS keys off
        # wSeen, not the logical tile).
        for _ in range(3):
            _plant_zombie_facing_player(g)
            _w16(g, g.addr("wSeenWX"), px)
            _w16(g, g.addr("wSeenWY"), (py + 3) & 0xFFFF)
            g.tick(1)
            assert g.r8("wGameMode") == MODE_OVERWORLD, \
                "alerted before the step finished"
        # step finished: snap the arrived tile onto the line -> the very same
        # zombie now spots the player (allow a few frames for the loop's CheckLOS).
        for _ in range(6):
            _plant_zombie_facing_player(g)
            _w16(g, g.addr("wSeenWX"), px)
            _w16(g, g.addr("wSeenWY"), py)
            g.tick(1)
            if g.r8("wGameMode") == MODE_ALERT:
                break
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
        px0, py0 = g.r16("wPlayerWX"), g.r16("wPlayerWY")
        # Re-pin on the sight line each frame until detection (an idle zombie
        # re-plans within a tick, so a one-shot plant only lines up by frame-phase
        # luck that shifts with ROM size — see test_los_keys_off_...). zx0 is the
        # planted x (px0 + 3), stable across re-plants; the charge closes from there.
        zx0 = None
        for _ in range(6):
            _plant_zombie_facing_player(g, dist=3)
            zx0 = _ent16(g, 0, EO_WXLO)
            g.tick(1)
            if g.r8("wGameMode") == MODE_ALERT:
                break
        assert g.r8("wGameMode") == MODE_ALERT, "zombie should spot the player"
        # through the "!" beat and a couple of charge steps
        g.tick(60)
        zx_mid = _ent16(g, 0, EO_WXLO)
        assert zx_mid < zx0, "zombie did not advance toward the player"
        assert g.r16("wPlayerWX") == px0 and g.r16("wPlayerWY") == py0, \
            "player moved during the charge (should be frozen)"
        # let it reach the player; the charge exits alert mode only INTO combat
        # (MODE_BATTLE now — real combat, not the old flash). The zombie stays in
        # the pool as the battle foe and is removed only on a win (see test_battle).
        resolved = False
        for _ in range(240):
            g.tick(1)
            if g.r8("wGameMode") == MODE_BATTLE:
                assert g.r8("wBattleFoe") == 0, "the charging zombie should be the foe"
                assert _ent(g, 0, EO_ACTIVE) == 1, "foe stays in the pool until a win"
                resolved = True
                break
        assert resolved, "charge never reached the player / resolved into a battle"
    finally:
        g.close()


def _setup_clear_row(g):
    """Relocate the player onto the classic-seed row y=-1 (clear for several tiles
    each way, unlike the tree-filled spawn row), camera synced, pools emptied."""
    _clear_pool(g, "wZombies", MAX_ZOMBIES)
    _clear_pool(g, "wNPCs", MAX_NPCS)
    _clear_pool(g, "wLoot", MAX_LOOT)
    g.pyboy.memory[g.addr("wZombSpawnTimer")] = 250   # hold off respawns
    g.pyboy.memory[g.addr("wSwimming")] = 0
    for nm in ("wPlayerWX", "wSeenWX"):
        _w16(g, g.addr(nm), 0)
    for nm in ("wPlayerWY", "wSeenWY"):
        _w16(g, g.addr(nm), 0xFFFF)                   # y = -1
    g.tick(1)                                         # UpdateView syncs the camera


def test_no_sprite_jump_when_spotting_mid_slide():
    # BUG: a zombie that was mid-step when it spotted the player used to SNAP to
    # its tile (.detected zeroed EO_SLIDE), jerking the sprite up to 8px. Now the
    # residual slide keeps easing across the alert transition. Force a full slide
    # toward the player at spot time and assert the sprite never jumps.
    from harness import Game
    g = Game()
    try:
        _setup_clear_row(g)
        base = g.addr("wZombies")
        _plant_zombie_facing_player(g, dist=3)        # (3,-1) facing left, frozen
        g.pyboy.memory[base + EO_SLIDE] = 16          # mid-step...
        g.pyboy.memory[base + EO_SLIDEDIR] = EFACE_LEFT  # ...sliding toward the player
        prev = None
        worst = 0
        saw_alert = False
        for _ in range(12):                           # stays within the "!" beat
            g.tick(1)
            if g.r8("wGameMode") == MODE_ALERT:
                saw_alert = True
            s = g.sprite(1)                           # zombie 0 -> OAM slot 1
            if prev is not None and 8 <= s["x"] <= 160 and 16 <= s["y"] <= 152:
                worst = max(worst, abs(s["x"] - prev[0]), abs(s["y"] - prev[1]))
            prev = (s["x"], s["y"])
        assert saw_alert, "zombie never spotted the player"
        assert worst <= 3, f"zombie sprite jumped {worst}px when spotting mid-slide"
    finally:
        g.close()


def test_no_walk_through_when_spotted_mid_step():
    # BUG: detection keys off wSeen (the arrived tile) but the charge's adjacency
    # test used wPlayer (the logical tile) — a step ahead mid-walk — so the zombie
    # strode onto/through the player. Now detection settles the player onto wSeen,
    # and the charge stops adjacent. Fake a step in flight (logical tile a step
    # PAST the seen tile) and assert the zombie never occupies the seen tile.
    from harness import Game
    g = Game()
    try:
        _setup_clear_row(g)
        # seen (where the zombie sees you) = (1,-1); logical a step further = (0,-1)
        _w16(g, g.addr("wSeenWX"), 1)
        _w16(g, g.addr("wPlayerWX"), 0)
        _plant_zombie_facing_player(g, dist=3)        # reads wPlayerWX=0 -> (3,-1)
        g.tick(2)
        assert g.r8("wGameMode") == MODE_ALERT, "zombie should spot the seen tile"
        assert g.r16("wPlayerWX") == g.r16("wSeenWX"), "player not settled onto wSeen"
        seen = (g.r16("wSeenWX"), g.r16("wSeenWY"))
        resolved = False
        for _ in range(240):
            g.tick(1)
            z = (_ent16(g, 0, EO_WXLO), _ent16(g, 0, EO_WYLO))
            assert z != seen, "zombie walked onto/through the player's tile"
            if g.r8("wGameMode") == MODE_BATTLE:
                resolved = True
                break
        assert resolved, "charge never resolved into a battle"
    finally:
        g.close()


def test_walking_player_is_detected():
    # BUG: with the player and zombie both moving, detection could blink out
    # "depending on where the frames hit" because it compared the player's lagging
    # visual tile to the zombie's leading logical tile. Both now use their on-screen
    # tile, so a facing zombie reliably spots a player who walks into range.
    from harness import Game
    g = Game()
    try:
        _setup_clear_row(g)
        _plant_zombie_facing_player(g, dist=6)        # (6,-1) facing left, frozen
        g.hold("right")                               # walk into range (SIGHT_RANGE=5)
        detected = False
        for _ in range(80):
            g.tick(1)
            if g.r8("wGameMode") == MODE_ALERT:
                detected = True
                break
        g.release("right")
        assert detected, "a facing zombie failed to detect the walking player"
    finally:
        g.close()
