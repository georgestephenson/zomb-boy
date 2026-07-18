# hUGEDriver (vendored)

This directory is a **vendored copy** of hUGEDriver — the Game Boy sound driver
that plays music composed in [hUGETracker](https://github.com/SuperDisk/hUGETracker).
Unlike the toolchain in `.tools/` (fetched on demand), the driver is *build-input
source* that becomes part of the ROM, so it is committed here rather than fetched.

- **Upstream project:** https://github.com/SuperDisk/hUGEDriver
- **Source of this copy:** the hUGEDriver **bundled inside hUGETracker 1.0.11**
  (`.tools/hugetracker/hUGEDriver/`, installed by `make hugetracker`).
- **License:** dedicated to the **public domain** (upstream README, "License").

## ⚠️ Why the tracker's bundled driver, not GitHub `master`

The song-data format is a **contract between the driver and the tracker**. The
driver, the tracker's "RGBDS .asm" exporter, and the tracker's sample songs must
all agree on it. hUGETracker 1.0.11 ships the exact `hUGEDriver.asm` its exporter
targets, so vendoring **that** copy guarantees a matched set.

GitHub `master` is *ahead* of the 1.0.11 release and has already changed the song
descriptor layout — its `hUGE_init` reads a **4-byte** tempo + a 1-byte order
count, whereas 1.0.11 songs (and the 1.0.11 exporter) emit a **1-byte** tempo +
a *pointer* to the order count. Feeding a 1.0.11-format song to a `master` driver
makes it read pointer bytes as the tempo → a garbage (huge) `ticks_per_row` → the
song crawls one row every ~0.6 s, so you hear **a couple of blips then apparent
silence**. That is exactly the bug this copy fixes. **Keep the driver and the
pinned hUGETracker version in lockstep.**

## What's here (a trimmed subset of the bundle)

| Path | Purpose |
|------|---------|
| `hUGEDriver.asm` | The driver. Assembled + linked into the ROM. |
| `include/hUGE.inc` | `dn` note macro + note-name constants (used by songs). |
| `include/hUGE_note_table.inc` | Period table `INCLUDE`d by the driver. |
| `include/hardware.inc` | The driver's **own** hardware defs. Kept so the driver assembles as a self-contained object, independent of the project's pinned v4.12.0 `hardware.inc`. |
| `songs/song_demo.asm` | Demo tune (bundle's `rgbds_example/sample_song.asm`, public domain). Only the descriptor label was renamed to `song_demo`. |

## How it's built

`hUGEDriver.asm` and `songs/song_demo.asm` are each assembled with
`-i vendor/hUGEDriver/` (so their `include "include/..."` statements resolve to
this directory's `include/`), then linked with the game objects. See the Makefile
(`AUDIO_OBJS`). They are assembled **outside** the project's `-Weverything` rule
because they are third-party sources held to upstream's conventions, not ours.

## Updating (and re-sync)

To move to a newer hUGETracker: bump `HUGETRACKER_VERSION` in the Makefile,
`make hugetracker`, then re-copy from `.tools/hugetracker/hUGEDriver/`:

```sh
H=.tools/hugetracker/hUGEDriver; D=vendor/hUGEDriver
cp $H/hUGEDriver.asm $D/hUGEDriver.asm
cp $H/include/{hUGE.inc,hUGE_note_table.inc,hardware.inc} $D/include/
cp $H/rgbds_example/sample_song.asm $D/songs/song_demo.asm   # re-apply the song_demo:: label rename
```

Then rebuild and re-test audio (see below).

## Verifying audio without a human

Interactive listening needs `make run` (mGBA). Headlessly you can still prove the
driver plays the song at the correct tempo two ways:

1. **Driver state via PyBoy** — after boot, `ticks_per_row` should equal the
   song's tempo (2 for the demo) and `order_cnt` its order count (68), and `row`
   should advance ~30×/s, not ~1×/s.
2. **Render to audio with gbsplay** — build a GBS with the bundle's `gbs.asm`
   (`SECTION` the song as `ROM0`, strip the `$400` header padding at offset
   `$70`) and `gbsplay -o stdout` it; a working combo is ~sustained energy, a
   broken one is one blip then near-silence.
