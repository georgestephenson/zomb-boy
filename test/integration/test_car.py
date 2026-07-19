"""Drivable car: board/leave it, drive at double speed, and burn fuel (which
takes over the HUD energy slot) instead of energy — an empty tank strands you.

Boarding is layout-sensitive (you must stand next to the car and face it), so
the enter/exit test pokes the car onto the tile the player faces. The physics
tests (speed/fuel/energy) set wInCar directly — the movement code only looks at
that flag — and drive along a lane the reference model confirms is clear, since
a car (unlike the swimmer) can't cross water.
"""
from harness import Game
from worldgen_model import gen_tile_type, SOLID

EFACE_DOWN, EFACE_UP, EFACE_LEFT, EFACE_RIGHT = 0, 1, 2, 3
FONT_BASE = 128
DIGIT0 = FONT_BASE + 27
SPACE = FONT_BASE
HUD_ENERGY = FONT_BASE + 51
HUD_FUEL = FONT_BASE + 52
SCRN1 = 0x9C00
CLOCK_MINUTE_FRAMES = 10
ENERGY_DRAIN_MINS = 16
FUEL_START = 100

DIRS = [("right", 1, 0), ("down", 0, 1), ("left", -1, 0), ("up", 0, -1)]


def _pos(g):
    return (g.s16("wPlayerWX"), g.s16("wPlayerWY"))


def _w16(g, name, val):
    a = g.addr(name)
    g.pyboy.memory[a] = val & 0xFF
    g.pyboy.memory[a + 1] = (val >> 8) & 0xFF


def _w16b(g, addr, val):
    g.pyboy.memory[addr] = val & 0xFF
    g.pyboy.memory[addr + 1] = (val >> 8) & 0xFF


def _press_a(g):
    g.hold("a")
    g.tick(3)
    g.release("a")
    g.tick(3)


def _drivable_lane(g):
    """A direction the 2x2 car can actually drive several tiles: its footprint
    (top-left at the player, extending one tile right and one down) must stay on
    non-solid ground at every step of the way (water is solid to a car). Returns
    the button name, or None."""
    px, py = _pos(g)
    for button, dx, dy in DIRS:
        clear = True
        for k in range(0, 6):                      # k=0 is the parked footprint
            for i in (0, 1):                        # 2x2 footprint tiles
                for j in (0, 1):
                    if gen_tile_type(px + dx * k + i, py + dy * k + j) in SOLID:
                        clear = False
        if clear:
            return button
    return None


def _min_step_gap(g, button, frames=90):
    """Hold one direction; return the smallest frame gap between consecutive tile
    changes — the free-run step cadence, immune to the one-off turn delay."""
    changes, last, frame = [], _pos(g), 0
    g.hold(button)
    for _ in range(frames):
        g.tick(1)
        frame += 1
        p = _pos(g)
        if p != last:
            changes.append(frame)
            last = p
    g.release(button)
    g.tick(2)
    gaps = [b - a for a, b in zip(changes, changes[1:])]
    return min(gaps) if gaps else None


def test_car_spawns_on_foot_with_a_full_tank():
    g = Game()
    try:
        px, py = _pos(g)
        cx, cy = g.s16("wCarWX"), g.s16("wCarWY")
        assert abs(cx - px) <= 10 and abs(cy - py) <= 10, \
            f"car spawned far from the player: {(cx, cy)} vs {(px, py)}"
        assert g.r8("wInCar") == 0, "should start on foot"
        assert g.r8("wFuel") == FUEL_START, f"tank not full at spawn: {g.r8('wFuel')}"
    finally:
        g.close()


def test_enter_and_exit_the_car():
    g = Game()
    try:
        px, py = _pos(g)
        # put the car on the tile directly to the player's right and face it
        g.pyboy.memory[g.addr("wFacing")] = EFACE_RIGHT
        _w16(g, "wCarWX", px + 1)
        _w16(g, "wCarWY", py)
        assert g.r8("wInCar") == 0
        _press_a(g)
        assert g.r8("wInCar") == 1, "A while facing the car should board it"
        assert _pos(g) == (px, py), "boarding must not move the player's tile"
        # A again gets out; the car parks on a tile next to where you stopped
        _press_a(g)
        assert g.r8("wInCar") == 0, "A while driving should get you out"
        cx, cy = g.s16("wCarWX"), g.s16("wCarWY")
        assert abs(cx - px) + abs(cy - py) <= 1, \
            f"car should park next to the player: {(cx, cy)} vs {(px, py)}"
    finally:
        g.close()


def _find_clear_block(g, w, h):
    """(ax, ay) near the player where the w x h tile block is all non-solid, else
    None — a scratch spot to drop the car and probe collision deterministically."""
    px, py = _pos(g)
    for r in range(1, 14):
        for dy in range(-r, r + 1):
            for dx in range(-r, r + 1):
                ax, ay = px + dx, py + dy
                if all(gen_tile_type(ax + i, ay + j) not in SOLID
                       for i in range(w) for j in range(h)):
                    return ax, ay
    return None


def _reset_foot(g, x, y):
    _w16(g, "wPlayerWX", x)
    _w16(g, "wPlayerWY", y)
    g.pyboy.memory[g.addr("wPlayerState")] = 0
    g.pyboy.memory[g.addr("wStepOffset")] = 0
    g.pyboy.memory[g.addr("wInCar")] = 0


def test_car_occupies_four_solid_tiles():
    """The parked car is a 2x2 world object (wCarWX/WY = top-left): the player on
    foot must not be able to walk onto any of its four tiles. Probed against a
    control run with the car moved away, so a coincidental wall can't pass it."""
    g = Game()
    try:
        blk = _find_clear_block(g, 4, 3)   # left approach column + 2x2 + margin
        assert blk, "no clear 4x3 block near spawn to test collision"
        ax, ay = blk
        cx, cy = ax + 1, ay                # car top-left, one tile right of approach
        for row in (cy, cy + 1):           # the car's left column: both rows solid
            # control: with the car elsewhere the player crosses this ground freely
            _w16(g, "wCarWX", cx + 60)
            _w16(g, "wCarWY", cy + 60)
            _reset_foot(g, ax, row)
            g.walk("right", 40)
            assert _pos(g)[0] >= cx, \
                f"control failed: clear ground at row {row} wasn't crossable: {_pos(g)}"
            # now park the car's 2x2 here -> the player stops just left of it
            _w16(g, "wCarWX", cx)
            _w16(g, "wCarWY", cy)
            _reset_foot(g, ax, row)
            g.walk("right", 40)
            assert _pos(g) == (cx - 1, row), \
                f"player walked onto the car's tile (row {row}): {_pos(g)}"
    finally:
        g.close()


def test_zombie_cannot_enter_the_car():
    """Zombies treat all four of the car's tiles as solid too — a zombie marched
    straight at the parked car never lands on its footprint."""
    g = Game()
    try:
        blk = _find_clear_block(g, 4, 3)
        assert blk, "no clear 4x3 block near spawn"
        ax, ay = blk
        cx, cy = ax + 1, ay
        _w16(g, "wCarWX", cx)
        _w16(g, "wCarWY", cy)
        g.pyboy.memory[g.addr("wInCar")] = 0
        foot = {(cx + i, cy + j) for i in (0, 1) for j in (0, 1)}
        b = g.addr("wZombies")

        def sz16(off):
            v = g.r16(b + off)
            return v - 0x10000 if v >= 0x8000 else v

        g.pyboy.memory[b + 0] = 1                 # active
        _w16b(g, b + 1, ax)                       # zombie at the approach tile
        _w16b(g, b + 3, cy)
        g.pyboy.memory[b + 5] = EFACE_RIGHT       # facing / marching right at the car
        g.pyboy.memory[b + 6] = EFACE_RIGHT       # EO_DIR
        landed = None
        for _ in range(150):
            g.tick(1)
            z = (sz16(1), sz16(3))
            if z in foot:
                landed = z
                break
            if g.r8("wGameMode") != 0:            # keep it marching if it alerts
                g.pyboy.memory[g.addr("wGameMode")] = 0
                g.pyboy.memory[b + 6] = EFACE_RIGHT
                g.pyboy.memory[b + 7] = 90
                g.pyboy.memory[b + 8] = 0
        assert landed is None, f"zombie stepped onto a car tile: {landed}"
    finally:
        g.close()


def test_car_moves_twice_as_fast():
    g = Game()
    try:
        px, py = _pos(g)
        button = _drivable_lane(g)
        assert button, "no clear lane near spawn for the speed comparison"
        foot = _min_step_gap(g, button)
        assert foot, "player never walked on foot"
        # reset to the same spot, board, and drive the very same lane
        _w16(g, "wPlayerWX", px)
        _w16(g, "wPlayerWY", py)
        g.pyboy.memory[g.addr("wPlayerState")] = 0
        g.pyboy.memory[g.addr("wStepOffset")] = 0
        g.pyboy.memory[g.addr("wInCar")] = 1
        g.pyboy.memory[g.addr("wFuel")] = 100
        car = _min_step_gap(g, button)
        assert car, "car never moved"
        assert car < foot, f"car step {car} not faster than foot step {foot}"
        assert car <= foot // 2 + 3, f"car step {car} not ~half of foot step {foot}"
    finally:
        g.close()


def test_fuel_drains_but_energy_does_not_while_driving():
    g = Game()
    try:
        button = _drivable_lane(g) or "up"
        g.pyboy.memory[g.addr("wInCar")] = 1
        g.pyboy.memory[g.addr("wFuel")] = 100
        f0, e0 = g.r8("wFuel"), g.r8("wEnergy")
        g.walk(button, 60)                     # drive several tiles down the lane
        assert g.r8("wFuel") < f0, "fuel should drop as the car drives"
        # energy is spared while driving, even across a full energy-drain period
        g.tick((ENERGY_DRAIN_MINS + 1) * CLOCK_MINUTE_FRAMES)
        assert g.r8("wEnergy") == e0, "energy must not drain while in the car"
    finally:
        g.close()


def test_empty_tank_cannot_move():
    g = Game()
    try:
        g.pyboy.memory[g.addr("wInCar")] = 1
        g.pyboy.memory[g.addr("wFuel")] = 0
        p0 = _pos(g)
        for d, _dx, _dy in DIRS:
            g.walk(d, 40)
        assert _pos(g) == p0, "a car with an empty tank must not move"
    finally:
        g.close()


def test_hud_swaps_energy_for_fuel_while_driving():
    g = Game()
    try:
        # on foot the third meter is energy
        assert g.r8(SCRN1 + 10) == HUD_ENERGY, "expected the energy icon on foot"
        # board (poke) and let a minute tick recompose + push the row
        g.pyboy.memory[g.addr("wInCar")] = 1
        g.pyboy.memory[g.addr("wFuel")] = 77
        g.tick(CLOCK_MINUTE_FRAMES + 2)
        row = [g.r8(SCRN1 + i) for i in range(20)]
        assert row[10] == HUD_FUEL, f"expected the fuel icon while driving: {row}"
        # and it reads the fuel value (77 -> space, 7, 7), not energy
        assert row[11:14] == [SPACE, DIGIT0 + 7, DIGIT0 + 7], row
    finally:
        g.close()
