"""Music playback regression (audio.asm over the vendored hUGEDriver).

The song data lives in its own ROMX bank (it outgrew bank 1, which the grown
dialogue data owns), so audio.asm must map BANK(song_demo) around every driver
call and restore bank 1 after. If that seam breaks, hUGE_init copies whatever
bank 1 holds (dialogue tables) into the driver's WRAM state and the music
degrades to a couple of blips then silence — the exact failure mode CLAUDE.md
warns about for driver/data mismatches. These are the headless sanity checks
it prescribes: the driver's WRAM copies of ticks_per_row / order_cnt must
match the demo song, and the row cursor must actually advance.

(The harness's symbol table keeps the LAST duplicate in the .sym file, which
for order_cnt is the driver's WRAM copy, not the ROM descriptor — asserted
below so a re-sort of the .sym can't silently retarget the test.)
"""

SONG_TICKS_PER_ROW = 2   # the demo song's tempo
SONG_ORDER_CNT = 68      # its order-list length (2 bytes per order entry)


def test_driver_loaded_the_song(game):
    assert game.addr("order_cnt") >= 0xC000, "order_cnt must resolve to WRAM"
    assert game.r8("ticks_per_row") == SONG_TICKS_PER_ROW, \
        "driver tempo doesn't match the song (bank seam or driver/data drift)"
    assert game.r8("order_cnt") == SONG_ORDER_CNT, \
        "driver order count doesn't match the song"


def test_music_advances(game):
    """At 2 ticks/row the row cursor moves every other frame; a stuck cursor
    means the driver is chewing garbage instead of pattern data."""
    before = (game.r8("current_order"), game.r8("row"))
    game.tick(16)
    after = (game.r8("current_order"), game.r8("row"))
    assert after != before, f"music not advancing: stuck at order/row {before}"
