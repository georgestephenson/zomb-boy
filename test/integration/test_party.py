"""Party levels / experience + the multi-page STATUS screen (items.asm, menu.asm).

The player (party member 0) starts at LEVEL 1 with 0 XP and climbs to 99, each
level costing exponentially more XP (the LevelXP cumulative table). RecalcLevel
re-derives the level from the running XP total (battles will feed it via
AddPlayerXP). The STATUS panel is two pages: vitals (level/XP/meters) and the six
stat points, flipped with LEFT/RIGHT.
"""
from harness import Game

SCRN1 = 0x9C00
FONT_BASE = 128
TILE_DIGIT0 = FONT_BASE + 27

MSCR_STATUS = 5
MODE_MENU = 3
MAX_LEVEL = 99

# Menu layout (constants.inc)
MENU_LIST_COL = 3
MENU_BODY_ROW = 3


def press(g, button, settle=4):
    g.hold(button)
    g.tick(2)
    g.release(button)
    g.tick(settle)


def cell(g, row, col):
    """Tile id in SCRN1's tile map at (row, col)."""
    return g.r8(SCRN1 + row * 32 + col)


def letter(ch):
    return FONT_BASE + 1 + (ord(ch) - ord("A"))


def set16(g, name, val):
    a = g.addr(name)
    g.pyboy.memory[a] = val & 0xFF
    g.pyboy.memory[a + 1] = (val >> 8) & 0xFF


def open_status(g):
    press(g, "start")
    assert g.r8("wGameMode") == MODE_MENU
    for _ in range(3):          # PARTY -> EQUIP -> BAG -> STATUS
        press(g, "down")
    press(g, "a")
    assert g.r8("wMenuScreen") == MSCR_STATUS


def test_party_starts_level1_zero_xp():
    g = Game()
    try:
        assert g.r8("wPartyLevel") == 1, "player should start at LEVEL 1"
        assert g.r16("wPartyXP") == 0, "player should start with 0 XP"
    finally:
        g.close()


def test_status_vitals_page_shows_level():
    g = Game()
    try:
        open_status(g)
        assert g.r8("wStatusPage") == 0, "STATUS opens on the vitals page"
        # "LEVEL  " label heads row BODY+1; the value sits one column past it.
        assert cell(g, MENU_BODY_ROW + 1, MENU_LIST_COL) == letter("L")
        assert cell(g, MENU_BODY_ROW + 1, MENU_LIST_COL + 7) == TILE_DIGIT0 + 1
        # "NEXT" at level 1 needs 5 XP (LevelXP[0]).
        assert cell(g, MENU_BODY_ROW + 3, MENU_LIST_COL) == letter("N")
        assert cell(g, MENU_BODY_ROW + 3, MENU_LIST_COL + 7) == TILE_DIGIT0 + 5
    finally:
        g.close()


def test_status_flips_to_stats_page():
    g = Game()
    try:
        open_status(g)
        press(g, "right")
        assert g.r8("wStatusPage") == 1, "RIGHT should flip to the stats page"
        # "STRENGTH" heads row BODY+1; its value (base 6) is 10 columns in.
        assert cell(g, MENU_BODY_ROW + 1, MENU_LIST_COL) == letter("S")
        assert cell(g, MENU_BODY_ROW + 1, MENU_LIST_COL + 10) == TILE_DIGIT0 + 6
        # "ENDURANCE" (base 8) two rows below.
        assert cell(g, MENU_BODY_ROW + 3, MENU_LIST_COL) == letter("E")
        assert cell(g, MENU_BODY_ROW + 3, MENU_LIST_COL + 10) == TILE_DIGIT0 + 8
        # The avatar sprite is hidden on the stats page (keeps its column clear).
        assert g.sprite(1)["y"] == 0, "avatar should be hidden on the stats page"
        press(g, "left")
        assert g.r8("wStatusPage") == 0, "LEFT should flip back to vitals"
    finally:
        g.close()


def test_xp_drives_leveling():
    g = Game()
    try:
        open_status(g)
        assert g.r8("wPartyLevel") == 1
        # One XP short of level 2 stays at level 1; hitting the threshold levels up.
        set16(g, "wPartyXP", 4)
        press(g, "right")          # any rebuild runs RecalcLevel
        assert g.r8("wPartyLevel") == 1, "4 XP is below the level-2 threshold (5)"
        set16(g, "wPartyXP", 5)
        press(g, "left")
        assert g.r8("wPartyLevel") == 2, "5 XP should reach level 2"
    finally:
        g.close()


def test_level_caps_at_99():
    g = Game()
    try:
        open_status(g)
        # The top cumulative threshold (25078) is the whole climb; any XP at or
        # above it pins the level at MAX_LEVEL, never past it.
        set16(g, "wPartyXP", 65000)
        press(g, "right")
        assert g.r8("wPartyLevel") == MAX_LEVEL
        # Stats scale with the level: ENDURANCE = base 8 + 98*grow 2 = 204.
        assert g.r8("wStatusPage") == 1
        v = MENU_BODY_ROW + 3      # ENDURANCE row
        got = [cell(g, v, MENU_LIST_COL + 10 + i) for i in range(3)]
        assert got == [TILE_DIGIT0 + 2, TILE_DIGIT0 + 0, TILE_DIGIT0 + 4], got
        # Vitals page shows NEXT = "MAX" (no further level).
        press(g, "left")
        assert g.r8("wStatusPage") == 0
        want = [letter("M"), letter("A"), letter("X")]
        got = [cell(g, MENU_BODY_ROW + 3, MENU_LIST_COL + 7 + i) for i in range(3)]
        assert got == want, got
    finally:
        g.close()


def test_party_page_shows_level():
    g = Game()
    try:
        press(g, "start")
        press(g, "a")              # PARTY (root cursor starts on it)
        assert g.r8("wMenuScreen") == 1   # MSCR_PARTY
        # Member 0's row: "ZOMB BOY  LV 1" — the "LV" tag then the level digit.
        row = MENU_BODY_ROW
        assert cell(g, row, MENU_LIST_COL) == letter("Z")
        # "ZOMB BOY" is 8 chars, "  LV " is 5 -> value at col +13.
        assert cell(g, row, MENU_LIST_COL + 13) == TILE_DIGIT0 + 1
    finally:
        g.close()
