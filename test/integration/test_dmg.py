"""DMG (original Game Boy) fallback path.

The ROM is CGB-compatible ($80 header): it detects the console at boot and gates
every CGB-only operation (double-speed, VRAM-bank-1 attribute plane) so it also
runs on a monochrome Game Boy, in grayscale.

PyBoy can't faithfully emulate DMG mode for a CGB-flagged ROM (its rVBK reads as
CGB regardless), so we can't exercise the *detection* headlessly — that's
verified on hardware/mGBA. What we CAN do is force the DMG code path (patch the
detection to store hIsCGB = 0) and prove the guards are correct: the game boots
without hanging on the double-speed STOP, the background is written with valid
tile ids (not corrupted by attribute writes landing in bank 0), and the DMG
palette registers are set so sprites aren't solid black.
"""
import os

import pytest
from pyboy import PyBoy

from harness import ROM, load_symbols
from worldgen_model import gen_tile_type

SCRN0 = 0x9800
VIEW_COLS, VIEW_ROWS = 20, 18


def _forced_dmg_rom(tmp_path):
    """Copy the ROM but patch console detection to always pick DMG.
    The detector ends with `and 1 : xor 1` (E6 01 EE 01); rewriting the `xor 1`
    to `xor a : nop` (AF 00) makes it store hIsCGB = 0 unconditionally."""
    rom = bytearray(open(ROM, "rb").read())
    needle = b"\xE6\x01\xEE\x01"
    assert rom.count(needle) == 1, "detection sequence not found uniquely"
    i = rom.find(needle)
    rom[i + 2], rom[i + 3] = 0xAF, 0x00
    path = os.path.join(tmp_path, "forced_dmg.gbc")
    open(path, "wb").write(rom)
    return path


@pytest.fixture
def dmg(tmp_path):
    pb = PyBoy(_forced_dmg_rom(tmp_path), window="null",
               sound_emulated=False, cgb=True)
    # No double-speed on the DMG path, so boot is slower — settle generously.
    for _ in range(320):
        pb.tick()
    yield pb
    pb.stop(save=False)


def _s16(pb, sym, name):
    a = sym[name]
    v = pb.memory[a] | (pb.memory[a + 1] << 8)
    return v - 0x10000 if v >= 0x8000 else v


def test_dmg_path_boots_without_hanging(dmg):
    sym = load_symbols()
    assert dmg.memory[sym["hIsCGB"]] == 0, "forced-DMG build should read as DMG"
    assert dmg.memory[0xFF40] & 0x80, "LCD off — boot hung (double-speed STOP?)"


def test_dmg_background_not_corrupted(dmg):
    """Tile ids must still be valid and match the generator — i.e. the skipped
    bank-1 attribute writes didn't overwrite tile ids in bank 0."""
    sym = load_symbols()
    vtx, vty = _s16(dmg, sym, "wViewTX"), _s16(dmg, sym, "wViewTY")
    mismatches = []
    for dy in range(VIEW_ROWS):
        for dx in range(VIEW_COLS):
            wx, wy = vtx + dx, vty + dy
            got = dmg.memory[SCRN0 + ((wy & 31) * 32) + (wx & 31)]
            assert got <= 13, f"invalid BG tile {got} at ({wx},{wy})"
            if got != gen_tile_type(wx, wy):
                mismatches.append((wx, wy, gen_tile_type(wx, wy), got))
    assert not mismatches, f"BG differs from model on DMG path: {mismatches[:8]}"


def test_dmg_palettes_set_so_sprites_arent_black(dmg):
    # Without these, DMG renders every object pixel as one shade (the "pure
    # black sprites" bug). rBGP/rOBP0/rOBP1 must all be programmed.
    assert dmg.memory[0xFF47] != 0x00, "rBGP unset"
    assert dmg.memory[0xFF48] != 0x00, "rOBP0 unset"
    assert dmg.memory[0xFF49] != 0x00, "rOBP1 unset"
    player = dmg.memory[0xFE00:0xFE00 + 4]
    assert player[0] == 88 and player[1] == 80, "player sprite misplaced on DMG"
