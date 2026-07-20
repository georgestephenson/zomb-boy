"""HUD pickup toasts (hud.asm ShowNotice/ShowNoticeItem/TickNotice).

When you eat food or pull loot from a container the status row is briefly
overwritten with a message ("ATE APPLE", "GOT PISTOL") for NOTICE_FRAMES and
then reverts to the meters — WITHOUT pausing the game (the clock keeps ticking).
The window still renders SCRN1 row 0, so we read the toast straight out of VRAM.
"""
from harness import Game

ENT_SIZE = 16
EO_ACTIVE, EO_WXLO, EO_WYLO, EO_KIND = 0, 1, 3, 5
LOOT_APPLE, LOOT_BEANS, LOOT_CRATE, LOOT_CHEST = 0, 1, 2, 4
MAX_LOOT = 8
SCRN1 = 0x9C00
FONT_BASE = 128
CHARSET = " ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.,!?'-"
TILE_HUD_HP = FONT_BASE + 49
NOTICE_FRAMES = 90
CLOCK_MINUTE_FRAMES = 10


def _enc(s):
    return [FONT_BASE + CHARSET.index(c) for c in s]


def _row(g):
    return [g.r8(SCRN1 + i) for i in range(20)]


def _decode(g):
    return "".join(CHARSET[b - FONT_BASE] if 0 <= b - FONT_BASE < len(CHARSET)
                   else "#" for b in _row(g))


def _w16(g, addr, val):
    g.pyboy.memory[addr] = val & 0xFF
    g.pyboy.memory[addr + 1] = (val >> 8) & 0xFF


def _first_food(g):
    base = g.addr("wLoot")
    for i in range(MAX_LOOT):
        b = base + i * ENT_SIZE
        if g.r8(b + EO_ACTIVE) and g.r8(b + EO_KIND) in (LOOT_APPLE, LOOT_BEANS):
            x = g.r16(b + EO_WXLO)
            y = g.r16(b + EO_WYLO)
            x -= 0x10000 if x >= 0x8000 else 0
            y -= 0x10000 if y >= 0x8000 else 0
            return i, x, y, g.r8(b + EO_KIND)
    return None


def _free_slot(g):
    base = g.addr("wLoot")
    for i in range(MAX_LOOT):
        if not g.r8(base + i * ENT_SIZE + EO_ACTIVE):
            return i
    return None


def test_eating_food_shows_a_toast():
    g = Game()
    try:
        food = _first_food(g)
        assert food, "no boot food to eat"
        _, x, y, kind = food
        _w16(g, g.addr("wPlayerWX"), x & 0xFFFF)
        _w16(g, g.addr("wPlayerWY"), y & 0xFFFF)
        g.tick(8)  # auto-grab fires, PushHUD lands the toast (player is idle)
        msg = "ATE APPLE" if kind == LOOT_APPLE else "ATE BEANS"
        assert _row(g)[:len(msg)] == _enc(msg), \
            f"expected '{msg}' on the HUD, got '{_decode(g)}'"
    finally:
        g.close()


def test_toast_reverts_to_the_meters():
    g = Game()
    try:
        food = _first_food(g)
        _, x, y, _ = food
        _w16(g, g.addr("wPlayerWX"), x & 0xFFFF)
        _w16(g, g.addr("wPlayerWY"), y & 0xFFFF)
        g.tick(8)
        assert g.r8(SCRN1) != TILE_HUD_HP, "toast never took over the row"
        g.tick(NOTICE_FRAMES + 8)  # let it expire and recompose the meters
        assert g.r8(SCRN1) == TILE_HUD_HP, \
            f"HUD did not revert to meters: '{_decode(g)}'"
    finally:
        g.close()


def test_game_not_paused_during_a_toast():
    g = Game()
    try:
        food = _first_food(g)
        _, x, y, _ = food
        _w16(g, g.addr("wPlayerWX"), x & 0xFFFF)
        _w16(g, g.addr("wPlayerWY"), y & 0xFFFF)
        g.tick(4)
        m0 = g.r8("wClockH") * 60 + g.r8("wClockM")
        g.tick(3 * CLOCK_MINUTE_FRAMES)         # still well inside the toast
        m1 = g.r8("wClockH") * 60 + g.r8("wClockM")
        assert m1 - m0 == 3, f"clock froze during the toast ({m0}->{m1})"
    finally:
        g.close()


def test_opening_a_container_toasts_what_you_got():
    g = Game()
    try:
        px, py = g.s16("wPlayerWX"), g.s16("wPlayerWY")
        g.pyboy.memory[g.addr("wFacing")] = 3   # face right
        slot = _free_slot(g)
        b = g.addr("wLoot") + slot * ENT_SIZE
        g.pyboy.memory[b + EO_ACTIVE] = 1
        _w16(g, b + EO_WXLO, (px + 1) & 0xFFFF)
        _w16(g, b + EO_WYLO, py & 0xFFFF)
        g.pyboy.memory[b + EO_KIND] = LOOT_CRATE
        g.hold("a")
        g.tick(3)
        g.release("a")
        g.tick(8)
        shown = _decode(g)
        assert shown.startswith("GOT ") or shown.startswith("ATE RATION"), \
            f"container open didn't toast its loot: '{shown}'"
    finally:
        g.close()
