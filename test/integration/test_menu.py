"""Start menu (menu.asm) — the Pokemon-style pause menu.

Opening it (START) pauses the game and shows a full-screen panel on SCRN1; the
root list navigates to Party/Equip/Bag/Status/Save/Options and EXIT soft-resets
to the title. These tests drive the menu by button edges and read the menu state
machine + VRAM + SRAM the same way the other integration tests do.
"""
from harness import Game

SCRN1 = 0x9C00
FONT_BASE = 128

# wMenuScreen values (constants.inc MSCR_*)
MSCR_ROOT, MSCR_PARTY, MSCR_EQUIP, MSCR_PICK = 0, 1, 2, 3
MSCR_BAG, MSCR_STATUS, MSCR_OPTIONS, MSCR_SAVE = 4, 5, 6, 7

MODE_OVERWORLD, MODE_MENU = 0, 3
TILE_PLAYER_BASE = 14


def press(g, button, settle=3):
    """One button edge: press, let ReadInput see it, release, settle."""
    g.hold(button)
    g.tick(2)
    g.release(button)
    g.tick(settle)


def open_menu(g):
    press(g, "start")
    assert g.r8("wGameMode") == MODE_MENU, "START did not open the menu"


def test_start_opens_and_pauses():
    g = Game()
    try:
        open_menu(g)
        # Window HUD is off while the menu owns SCRN1; BG fetches from $9C00.
        lcdc = g.r8(0xFF40)
        assert lcdc & 0x01, "BG off"
        assert not (lcdc & 0x20), "window should be off in the menu"
        assert lcdc & 0x08, "BG map should be $9C00 (LCDC bit 3)"
        assert g.r8("wMenuScreen") == MSCR_ROOT
        # Paused: the survival clock does not advance while the menu is up.
        h0, m0 = g.r8("wClockH"), g.r8("wClockM")
        g.tick(80)
        assert (g.r8("wClockH"), g.r8("wClockM")) == (h0, m0), "clock ticked while paused"
    finally:
        g.close()


def test_close_with_b_returns_to_overworld():
    g = Game()
    try:
        open_menu(g)
        press(g, "b")
        assert g.r8("wGameMode") == MODE_OVERWORLD
        # Window HUD restored on the way out.
        assert g.r8(0xFF40) & 0x20, "window HUD not restored after closing"
    finally:
        g.close()


def test_root_cursor_moves():
    g = Game()
    try:
        open_menu(g)
        assert g.r8("wRootCursor") == 0
        press(g, "down")
        assert g.r8("wRootCursor") == 1
        press(g, "down")
        assert g.r8("wRootCursor") == 2
        press(g, "up")
        assert g.r8("wRootCursor") == 1
    finally:
        g.close()


def test_bag_lists_starting_kit():
    g = Game()
    try:
        open_menu(g)
        press(g, "down")            # -> EQUIP
        press(g, "down")            # -> BAG
        press(g, "a")               # open BAG
        assert g.r8("wMenuScreen") == MSCR_BAG
        # StartKit (items.asm) seeds 8 distinct stacks.
        assert g.r8("wListN") == 8, g.r8("wListN")
    finally:
        g.close()


def test_status_shows_avatar():
    g = Game()
    try:
        open_menu(g)
        for _ in range(3):          # PARTY->EQUIP->BAG->STATUS
            press(g, "down")
        press(g, "a")
        assert g.r8("wMenuScreen") == MSCR_STATUS
        # The player avatar rides OAM slot 1 (the down-facing sprite tile).
        av = g.sprite(1)
        assert av["tile"] == TILE_PLAYER_BASE, av
        assert av["y"] != 0, "avatar hidden"
    finally:
        g.close()


def test_equip_a_weapon():
    g = Game()
    try:
        open_menu(g)
        press(g, "down")            # -> EQUIP
        press(g, "a")               # open EQUIP (cursor on WEAPON slot 0)
        assert g.r8("wMenuScreen") == MSCR_EQUIP
        press(g, "a")               # open the picker for slot 0 (weapons)
        assert g.r8("wMenuScreen") == MSCR_PICK
        # Row 0 = unequip (NONE); the two starter weapons (BAT, PISTOL) follow.
        assert g.r8("wListN") == 3, g.r8("wListN")
        press(g, "down")            # move to the first real weapon
        press(g, "a")               # equip it
        assert g.r8("wMenuScreen") == MSCR_EQUIP
        equipped = g.r8("wPartyEquip")   # member 0, weapon slot 0
        assert equipped in (1, 2), equipped   # ITEM_BAT / ITEM_PISTOL
    finally:
        g.close()


def test_options_toggles_music():
    g = Game()
    try:
        open_menu(g)
        for _ in range(5):          # ...-> OPTIONS
            press(g, "down")
        press(g, "a")
        assert g.r8("wMenuScreen") == MSCR_OPTIONS
        assert g.r8("wOptMusic") == 1
        press(g, "a")               # toggle off
        assert g.r8("wOptMusic") == 0
        # Muted: channels unrouted (NR51=0) and the per-frame music tick is gated.
        assert g.r8(0xFF25) == 0, "NR51 not unrouted when muted"
        press(g, "a")               # toggle back on
        assert g.r8("wOptMusic") == 1
    finally:
        g.close()


def test_save_writes_sram():
    g = Game()
    try:
        open_menu(g)
        for _ in range(4):          # ...-> SAVE
            press(g, "down")
        press(g, "a")               # select SAVE (runs DoSave)
        assert g.r8("wSaveDone") == 1
        assert g.r8("wMenuScreen") == MSCR_SAVE
        # Enable cart RAM (MBC5 RAMG) and read the save block back.
        g.pyboy.memory[0x0000] = 0x0A
        magic = g.addr("sMagic")
        assert g.r8(magic) == 0x5A and g.r8(magic + 1) == 0x42, "save magic missing"
        # Checksum = 8-bit sum of the block (menu.asm DoSave).
        start = g.addr("sMagic")
        end = g.addr("sChecksum")
        total = sum(g.r8(a) for a in range(start, end)) & 0xFF
        assert g.r8(end) == total, "save checksum mismatch"
        assert g.r8(g.addr("sSeed")) == g.r8("hWorldSeed"), "seed not saved"
    finally:
        g.close()


def test_exit_returns_to_title():
    g = Game()
    try:
        open_menu(g)
        for _ in range(6):          # ...-> EXIT
            press(g, "down")
        assert g.r8("wRootCursor") == 6
        press(g, "a")               # soft-reset to the title
        g.tick(90)                  # boot ROM + title come back up
        # The title loop free-runs wTitleTick; seeing it advance means we're back.
        t0 = g.r8("wTitleTick")
        g.tick(10)
        assert g.r8("wTitleTick") > t0, "not back on the title screen"
    finally:
        g.close()
