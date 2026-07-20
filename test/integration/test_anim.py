"""World animation (anim.asm) — the "living world" tile-art effects.

These verify the *logic* of each effect (timers fire, VRAM tile art swaps): the
actual on-screen sway/rustle/swing is a visual thing a human confirms on mGBA
(per CLAUDE.md). Everything here animates SHARED background tile art at $8000, so
we assert both the WRAM state machine and that the tile's 16 VRAM bytes change —
never the tile map (which the streaming/boot-hygiene tests own) and never OAM.
"""

# VRAM tile-art address = $8000 + id*16 (BG uses $8000 addressing).
def _art(g, tile_id):
    base = 0x8000 + tile_id * 16
    return bytes(g.pyboy.memory[base + i] for i in range(16))


TILE_WATER, TILE_BRUSH, TILE_DOOR, TILE_TREE_TL = 4, 1, 8, 10


def test_water_shimmer_is_ambient(game):
    # Water ripples on its own, with no input at all.
    frames = set()
    arts = set()
    for _ in range(90):                     # > 3 * WATER_ANIM_FRAMES (22)
        game.tick(1)
        frames.add(game.r8("wWaterFrame"))
        arts.add(_art(game, TILE_WATER))
    assert len(frames) >= 2, f"water frame never advanced: {frames}"
    assert len(arts) >= 2, "water tile art never changed in VRAM"


def test_ambient_breeze_sways_trees(game):
    # With no input, the periodic breeze must stir the canopy (tree pipeline
    # end-to-end: TriggerTreeSway -> UpdateAnim -> PushAnim).
    base = _art(game, TILE_TREE_TL)
    fired = False
    swapped = False
    for _ in range(300):                    # > BREEZE_PERIOD (210) + sway
        game.tick(1)
        if game.r8("wTreeTimer") > 0:
            fired = True
        if _art(game, TILE_TREE_TL) != base:
            swapped = True
    assert fired, "ambient breeze never started a tree sway"
    assert swapped, "tree canopy art never changed during the breeze"


def test_bumping_a_tree_sways_it(game):
    # Classic-seed layout: spawn (0,0) is open, (1,0) open, (2,0) a tree. Holding
    # right walks onto (1,0) then bumps the tree — which must start a sway.
    assert game.s16("wPlayerWX") == 0 and game.s16("wPlayerWY") == 0
    game.hold("right")
    swayed = False
    for _ in range(40):                     # one step (16f) + the bump
        game.tick(1)
        if game.r8("wTreeTimer") > 0:
            swayed = True
    game.release("right")
    # bumped: blocked by the tree at (2,0), so the player rests at x=1
    assert game.s16("wPlayerWX") == 1, "player should be stopped against the tree"
    assert swayed, "bumping the tree did not sway it"


def test_walking_through_brush_rustles_it(game):
    # Holding up from spawn walks through the long grass north of it.
    base = _art(game, TILE_BRUSH)
    game.hold("up")
    rustled = False
    swapped = False
    for _ in range(120):
        game.tick(1)
        if game.r8("wBrushTimer") > 0:
            rustled = True
        if _art(game, TILE_BRUSH) != base:
            swapped = True
    game.release("up")
    assert rustled, "walking through brush never triggered a rustle"
    assert swapped, "brush tile art never changed while rustling"


def test_door_opens_on_threshold_and_shuts_behind(game):
    # Reaching a real doorway needs fragile navigation, so drive the door state
    # machine directly (wOnDoor is the one-line wDestTile check set on a step,
    # mirroring the brush trigger tested above). Assert the shared TILE_DOOR art
    # swaps to the open leaf while on the threshold and shuts after the linger.
    closed = _art(game, TILE_DOOR)
    assert game.r8("wDoorFrame") == 0

    game.pyboy.memory[game.addr("wOnDoor")] = 1     # step onto the doorway
    game.tick(4)
    assert game.r8("wDoorFrame") == 1, "door did not open on the threshold"
    opened = _art(game, TILE_DOOR)
    assert opened != closed, "open-door art was not written to VRAM"

    game.pyboy.memory[game.addr("wOnDoor")] = 0     # step off
    game.tick(2)
    assert game.r8("wDoorFrame") == 1, "door should linger open briefly"
    game.tick(30)                                   # > DOOR_LINGER (16)
    assert game.r8("wDoorFrame") == 0, "door never shut behind the player"
    assert _art(game, TILE_DOOR) == closed, "door art did not restore to closed"
