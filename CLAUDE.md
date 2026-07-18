# CLAUDE.md — working notes for Zomb Boy

Guidance for Claude working in this repo. Keep it current when architecture or
conventions change.

## What this is

A monster-battler-style **Game Boy Color** game (zombies, endless procedural
world) in SM83 assembly using RGBDS. The full vision lives in
[`docs/design/`](docs/design/) — treat those as the spec. Only a slice is built
so far (see the roadmap in [README.md](README.md)). Build in **vertical slices**;
don't gold-plate ahead of a working core loop. Anything not yet needed is marked
**LATER** in the design docs.

## Commands

```sh
make            # build build/zombboy.gbc (auto-fetches pinned toolchain)
make run        # build + launch in the vendored mGBA (auto-fetched first time)
make test       # runs tools/run-tests.sh (model + on-target ROMs)
make clean      # remove build/ ; make distclean also removes .tools/
python3 test/model/worldgen_model.py   # reference-model check for the generator
```

The toolchain is a **pinned, repo-local dev dependency** (`.tools/`, gitignored),
fetched with checksum verification by `tools/fetch-*.sh`. Versions are pinned in
the `Makefile` (`RGBDS_VERSION`, `HWINC_REF`, `EMU_VERSION`).

## Environment gotchas (learned the hard way)

- **Host is Ubuntu 26.04** — very new libstdc++/glibc. Prebuilt binaries often
  aren't ready for it; prefer self-contained bundles (AppImage) over distro
  tarballs.
- **Emulator is mGBA, not Mesen2.** Mesen2 crashes (`std::bad_cast` in a
  settings-parsing `std::regex`) against this libstdc++. mGBA's AppImage bundles
  its libs. We **extract** the AppImage at fetch time (`--appimage-extract`)
  because Ubuntu 26.04 has FUSE 3 only (no `libfuse2`), and run
  `.tools/emulator/squashfs-root/AppRun`.
- **`hardware.inc` is pinned to v4.12.0 on purpose.** v5.0 renamed every constant
  (`LCDCF_ON` → `LCDC_ON`, dropped `_VRAM`/`SCRN_Y`/`BCPSF_AUTOINC`, ...). Our
  source uses the classic v4 names that match Pan Docs and every tutorial.
- **No headless input testing available.** The mGBA AppImage ships only the Qt
  GUI (`mgba-qt`) — no Lua/CLI. So we can boot-smoke-test and validate *pure*
  logic via host reference models, but *interactive* behavior (scrolling feel,
  animation, collision) needs a human running `make run`. Say so; don't claim
  interactive behavior is "verified."

## Architecture

Modules (all `.asm` under `src/` are separately assembled, then linked — there is
**no runtime cost** to splitting; cross-file symbols are exported with `::`):

| Module | Responsibility |
|--------|----------------|
| `main.asm` | Entry ($0100), boot init, main loop |
| `world.asm` | Tile generator, map init, BG streaming (the engine) |
| `player.asm` | Movement, collision, camera, sprite |
| `video.asm` | VBlank sync, OAM DMA, palettes, scroll; VBlank IRQ vector |
| `input.asm` | Joypad read with edge detection |
| `audio.asm` | Music seam over vendored hUGEDriver (`InitSound`/`UpdateSound`) |
| `gfx.asm` | Tile + palette data |
| `ram.asm` | **All** WRAM/HRAM variables (one place) |
| `util.asm` | 16-bit LE pointer math (`Inc16Ptr`/`Dec16Ptr`/`Add16Ptr`) |
| `include/constants.inc` | Shared `EQU` constants |

### Main loop (main.asm)
Logic runs **before** VBlank; VRAM/OAM pushes happen **inside** VBlank:
```
UpdateSound → ReadInput → UpdatePlayer → UpdateView → (GenStrip if moved) → DrawPlayerSprite
WaitVBlank → OAM DMA → SetScroll → BlitStream
```
`GenStrip` builds the incoming edge into a WRAM buffer (heavy, outside VBlank);
`BlitStream` pushes it to VRAM (tight, inside VBlank) in the **same frame** the
scroll updates — so there's no seam or one-frame latency.

### The endless-world trick (world.asm)
- World coords are **16-bit signed tile** coordinates (`wPlayerWX/WY`).
- The 32×32 BG map is a **circular buffer**: world tile `(X,Y)` always lives in
  cell `(X & 31, Y & 31)`. `SCX/SCY = (view & 31) * 8`.
- Moving one tile only invalidates the **single incoming column/row**, so we
  regenerate just that edge — this is what makes the world endless. Every visible
  cell is always current; off-screen margin cells may be stale but aren't shown.
- Terrain is layered in `GenTileType`: water (coarse `>>2` noise) → road grid
  (`x&15==0 || y&15==0`) → per-tile scatter (trees/walls/brush) → grass.

### Audio (audio.asm + vendored hUGEDriver)
- Music uses **hUGEDriver**, vendored (committed, public domain) under
  `vendor/hUGEDriver/` — see its `PROVENANCE.md`. It's *build-input source*, so
  it's committed, not fetched. The composer tool **hUGETracker** is a pinned dev
  dependency (`make hugetracker`, into `.tools/`), like the emulator.
- **The driver copy comes from the hUGETracker bundle, NOT GitHub `master`, and
  they must stay in lockstep.** The song-data format is a driver↔tracker contract;
  `master` has already changed it (4-byte tempo vs 1.0.11's 1-byte tempo + order
  pointer). A format mismatch doesn't error — it plays the song at a garbage tempo
  (~1 row/sec), which sounds like *a couple of blips then silence*. If music ever
  regresses to that after a version bump, re-sync the driver from the bundle
  (`PROVENANCE.md` → "Updating"). Sanity check headlessly: `ticks_per_row` should
  equal the song's tempo (2 for the demo) and `order_cnt` its count (68).
- The driver + demo song assemble as **separate objects** with `-i vendor/hUGEDriver/`
  and **without** `-Weverything` (third-party; upstream's style, not ours). They
  keep their **own** bundled `hardware.inc` (newer `rAUDxxx` names) — that's fine,
  each object only needs EQUs at assemble time, independent of our pinned v4.
- `audio.asm` is the seam: `InitSound` powers the APU on + `hUGE_init`s the song;
  `UpdateSound` (`hUGE_dosound`) advances one tick. Call `UpdateSound` **once per
  frame, outside VBlank** (top of the loop) — the loop is frame-locked by
  `WaitVBlank`, and keeping it out of the VBlank window spares that tight budget.
- Song data is `ROMX` (bank 1). The cart is still 32 KB ROM-ONLY (banks 0+1, no
  MBC). If songs grow past bank 1, add `-m`/`-r` to `FIXFLAGS` for a real MBC.
- To swap the tune: export from hUGETracker as "RGBDS .asm", drop it in
  `vendor/hUGEDriver/songs/` keeping the `song_demo::` descriptor label.

## Conventions & invariants (don't break these)

- **RGBDS syntax, v4 `hardware.inc` names.** `ldh [rLCDC], a`, `ld [hl+], a`,
  `LCDCF_*`, `_VRAM`, `_SCRN0`, `BCPSF_AUTOINC`, etc.
- **Exports:** anything used across files is defined with `::`. File-local labels
  use `:`; scope-local use `.name`.
- **Shadow OAM is 256-byte aligned** (`ALIGN[8]`) — OAM DMA takes only the
  source high byte. Don't move it off a `$xx00` boundary.
- **OAM DMA runs from HRAM** (`hOAMDMA`, trampoline copied at boot). The CPU can
  only touch HRAM during DMA.
- **GBC BG attribute map (VRAM bank 1) must be initialized.** Uninitialized
  attributes caused stray white tiles. `InitMap` writes bank-1 attributes for
  every cell; streaming writes them per tile. If you add BG tiles, set their
  palette in `AttrTable` (world.asm).
- **Never rely on zeroed RAM/VRAM.** Real hardware and mGBA leave memory as
  garbage at power-on (PyBoy zeros it, which *hides* these bugs). Boot clears all
  WRAM (`ClearRAM`) and both VRAM banks (`ClearVRAM`) in `Start`; any new state
  must either be cleared there or explicitly initialized before first read. The
  `test/integration/test_boot_hygiene.py` poison tests guard this. Boot also sets
  `sp` explicitly, silences the APU, and fixes the WRAM/VRAM banks.
- **Saturating 8-bit math, no wrap.** Meters/stats clamp to `0..255`. This is a
  memory-safety rule from the design; tests must cover both ends.
- **Build is warning-clean** under `-Weverything` (see `ASMFLAGS`). Keep it that
  way; a new warning is a smell. (A rgbfix "Overwrote a non-zero byte in the
  Nintendo logo/title" warning means a section drifted into the cartridge header
  — the `ds $0150 - @` in `EntryPoint` reserves $0104–$014F to prevent this.)
- **Unique SECTION names.** Every `SECTION "..."` name must be unique across all
  files (WRAM and ROM alike), or the linker errors.
- **`JR` reaches ±127 bytes.** Long loops need conditional `JP` for the back-edge.
- **The generator and its reference model must stay in lockstep.** If you change
  `GenTileType`/`Hash8` in `world.asm`, update `test/model/worldgen_model.py` to
  match byte-for-byte and re-run it.

## Adding things

- **A new BG tile type:** add its `TILE_*` id in `constants.inc`, its 8×8 art in
  `gfx.asm` (at the matching tile index), a `PassTable` entry (solid?) and an
  `AttrTable` entry (palette) in `world.asm`, and a branch in `GenTileType`.
  Update the reference model + rerun it.
- **A new module:** create `src/<name>.asm` (the Makefile globs `src/**/*.asm`),
  `INCLUDE` what it needs, export its public routines with `::`. Put any new RAM
  in `ram.asm`, not scattered.

## Watch out for

- **VBlank budget.** `BlitStream` writes up to a 20-tile row × 2 passes plus OAM
  DMA, all in VBlank. It currently fits at normal speed, but if you add per-frame
  VRAM work and see edge tearing, switch to **GBC double-speed** for headroom.
- **`ld a, b : or c` clear loops** rely on the byte count being < 256 (high byte
  stays 0). Fine for the current buffers; re-check if a cleared region grows.
- Commit messages: **do not** add Claude as an author/co-author (user's global
  rule). Branch off before committing on a default branch; only commit/push when
  asked.
