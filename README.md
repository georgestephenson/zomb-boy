# Zomb Boy

A monster-battler-style **Game Boy Color** game where the "creatures" are zombies
and the world is an **endless, procedurally-generated** survival landscape.
Written in Z80 (SM83) assembly with [RGBDS](https://rgbds.gbdev.io/).

> Status: **v0.2** — you can walk a genuinely infinite, streaming world (grass,
> water, roads, trees, walls) with a 4-direction animated character and tile
> collision. Combat, survival, and survivors are designed but not yet built.

## Quickstart

Everything is pinned and repo-local — you don't need to install a toolchain.
On first run, `make` downloads the exact RGBDS + `hardware.inc` versions into a
gitignored `.tools/`.

```sh
make          # build the ROM (build/zombboy.gbc)
make run      # build + play it (auto-downloads the mGBA emulator on first run)
make test     # run the test suite (see Testing below)
make clean    # remove build output
```

Requirements: Linux x86_64, plus `make`, `curl`, `sha256sum`, `unzip`. To use
your own emulator instead of the vendored one: `make run EMULATOR=/path/to/it`.

## What works today (v0.2)

- **Endless world.** 16-bit world coordinates; terrain is a deterministic
  function of `(seed, x, y)`, so it's "infinite" without storing anything — the
  32×32 background map is a circular buffer and only the incoming edge is
  regenerated as you walk.
- **Layered terrain.** Grass, brush, trees, walls, **water ponds/lakes**, and a
  **road grid** — all generated per-tile.
- **Movement.** Grid-based walking with tile collision; 4-direction, 2-frame
  walk animation. The player stays centered while the world scrolls under it.

Not yet: combat, food/sleep, survivors, houses/rivers, save system. See the
roadmap below and the design docs.

## Project structure

```
Makefile                 Pinned toolchain + build/run/test targets
src/
  main.asm               Entry point, boot init, main loop
  world.asm              Terrain generation + BG streaming (the engine)
  player.asm             Movement, collision, camera, sprite
  video.asm              VBlank, OAM DMA, palettes, scroll
  input.asm              Joypad read
  gfx.asm                Tile + palette data
  ram.asm                All WRAM/HRAM variable declarations
  util.asm               16-bit pointer math helpers
  include/constants.inc  Shared constants (tile ids, screen, pad bits, ...)
docs/design/             The design docs — what we're building and why
test/model/              Host-side reference models (Python) of pure ROM logic
tools/                   Fetch scripts for the pinned toolchain + emulator
```

## Design docs

The [`docs/design/`](docs/design/) directory is the source of truth for the full
vision (only part of which is built yet). Start with
[the design README](docs/design/README.md). Highlights:

- [01 — Technical Feasibility](docs/design/01-technical-feasibility.md): why an
  endless, self-remembering world fits on GBC hardware.
- [02 — World & Exploration](docs/design/02-world-and-exploration.md): chunks,
  generation, streaming, the save format.
- [06 — Testing & Memory Safety](docs/design/06-testing-and-memory-safety.md):
  how we keep raw-memory assembly correct.

## Testing

Assembly gives raw memory access, so correctness is a first-class concern.
Current coverage:

- **Reference models** ([`test/model/`](test/model/)) replicate pure ROM logic
  (e.g. the tile generator) in Python and assert on its behavior —
  `python3 test/model/worldgen_model.py`.
- **On-target test ROMs** run headless in an emulator: designed in
  [doc 06](docs/design/06-testing-and-memory-safety.md), wired to `make test`,
  not yet populated.

## Roadmap

Built in vertical slices (see [doc 02 §6](docs/design/02-world-and-exploration.md)):

- [x] v0.1 — controllable player on a generated world
- [x] v0.2 — endless streaming world, water + roads, walk animation
- [ ] Houses + rivers (multi-tile / connected structures)
- [ ] First zombie with line-of-sight → battle trigger
- [ ] Turn-based combat (2 weapons + 2 skills)
- [ ] Save system (battery SRAM diffs)
- [ ] Food/sleep survival pressure
- [ ] Survivors (compatibility + grammar dialogue)

## License / attribution

Toolchain: [RGBDS](https://github.com/gbdev/rgbds) and
[hardware.inc](https://github.com/gbdev/hardware.inc); emulator:
[mGBA](https://mgba.io/). All pinned and fetched by `make tools` / `make run`.
