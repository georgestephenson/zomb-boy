# Zomb Boy

[![CI](https://github.com/georgestephenson/zomb-boy/actions/workflows/ci.yml/badge.svg)](https://github.com/georgestephenson/zomb-boy/actions/workflows/ci.yml)
[![Deploy Pages](https://github.com/georgestephenson/zomb-boy/actions/workflows/pages.yml/badge.svg)](https://github.com/georgestephenson/zomb-boy/actions/workflows/pages.yml)

A monster-battler-style **Game Boy Color** game where the "creatures" are zombies
and the world is an **endless, procedurally-generated** survival landscape.
Written in Z80 (SM83) assembly with [RGBDS](https://rgbds.gbdev.io/).

### ▶ [Play it in your browser](https://georgestephenson.github.io/zomb-boy/)

No install, no emulator download — the latest `main` build runs in-browser via
[GitHub Pages](https://georgestephenson.github.io/zomb-boy/) (rebuilt on every
push). Arrow keys to move, <kbd>X</kbd>/<kbd>Z</kbd> for A/B, <kbd>Enter</kbd> to
start.

> Status: **v0.4** — an infinite streaming world with wandering zombies
> (line-of-sight alerts) and **talkable survivors**: five personas who speak in
> procedurally generated sentences, react to your tone, and end a conversation
> as a friend, a stranger, or a fight. Real combat and items are next.

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

## What works today (v0.4)

- **Endless world.** 16-bit world coordinates; terrain is a deterministic
  function of `(seed, x, y)`, so it's "infinite" without storing anything — the
  32×32 background map is a circular buffer and only the incoming edge is
  regenerated as you walk.
- **Layered terrain.** Grass, brush, trees, walls, **water ponds/lakes**, and a
  **road grid** — all generated per-tile.
- **Movement.** Grid-based walking with tile collision; 4-direction, 2-frame
  walk animation. The player stays centered while the world scrolls under it.
- **Zombies.** Wandering shufflers with line-of-sight; get spotted and a "!"
  alert triggers the (placeholder) battle transition.
- **Procedural encounters.** Zombies and survivors aren't all parked at the
  start any more: as you explore, a spawn manager destroys anyone who falls too
  far behind and respawns fresh ones (from the dynamic RNG, not the terrain
  hash) in a ring just off-screen — so the world stays populated wherever you
  wander, encounters never repeat when you backtrack, and fixed pools keep the
  count bounded. Survivors are **rare** (their rewards are big, so they're a real
  find); zombies are common but not wall-to-wall.
- **Scavengeable loot.** Food and containers spawn the same way — biome-flavoured
  (apples in forest, cans of beans in the city) and fresh every time. Walk over
  food to eat it (it refills the hunger meter); break **crates and pots** (solid —
  face them and press A) for everyday gear and ration packs; crack **treasure
  chests** for the rare, valuable finds. Gear lands in your bag, and a quick
  **toast** on the status bar tells you what you picked up ("ATE APPLE", "GOT
  PISTOL") without pausing the game.
- **Survivors & dialogue.** Ten personas (policeman, scientist, cheerleader,
  maid, businessman, prepper, medic, raider, preacher, farmer) stand in the
  world; face one, press **A**, and a dialogue screen opens. Every round is
  *their* generated sentence → your reply → their reaction: lines come from a
  template + word-bank grammar flavoured by personality and mood, and each
  menu deals a random four replies from an eight-tone pool (NICE, FLIRT, JOKE,
  RUDE, GUARDED, CHEER, GRIM, DEMAND — always at least one they won't punish).
  Affinity shifts per their trait vector; after three rounds the conversation
  resolves: reward, part ways, or fight. Each conversation orbits a fixed
  subject noun, reactions answer the specific tone you picked, grim souls
  reach for bleaker words than hopeful ones — and survivors remember you:
  return visits skip the hello. (The businessman respects DEMAND. The raider
  warms to RUDE. The prepper trusts only the GUARDED.)
- **Music.** A demo tune plays via [hUGEDriver](https://github.com/SuperDisk/hUGEDriver)
  (vendored, public domain) — the audio pipeline is wired end-to-end. Compose your
  own with `make hugetracker`; details in `vendor/hUGEDriver/PROVENANCE.md`.

Not yet: real turn-based combat, survivor gifts, sleep pressure, houses/rivers,
save system. See the roadmap below and the design docs.

## Project structure

```
Makefile                 Pinned toolchain + build/run/test targets
src/
  main.asm               Entry point, boot init, main loop (mode dispatch)
  world.asm              Terrain generation + BG streaming (the engine)
  player.asm             Movement, collision, camera, sprite
  entity.asm             Zombies: wandering AI, line-of-sight, entity structs
  npc.asm                Survivor NPCs: spawning, rendering, talk trigger
  talk.asm               The dialogue screen: UI, state machine, VRAM queue
  dialogue.asm           Grammar composer + persona/tone compatibility math
  dialogue_data.asm      Personas, word banks, sentence templates (ROMX)
  battle.asm             Placeholder battle transition (flash)
  rng.asm                16-bit LFSR for dynamic behaviour
  audio.asm              Music seam over the vendored hUGEDriver
  video.asm              VBlank, OAM DMA, palettes, font loader, scroll
  input.asm              Joypad read
  gfx.asm                Tile + palette data, 1bpp text font
  ram.asm                All WRAM/HRAM variable declarations
  util.asm               16-bit pointer math helpers
  include/constants.inc  Shared constants (tile ids, screen, pad bits, ...)
  include/charmap.inc    ASCII -> font tile mapping for dialogue strings
docs/design/             The design docs — what we're building and why
test/model/              Host-side reference models (Python) of pure ROM logic
test/integration/        Headless PyBoy tests (memory / OAM / VRAM assertions)
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
  in Python and assert on its behavior: `worldgen_model.py` mirrors the tile
  generator byte-for-byte, and `dialogue_bounds.py` walks the word banks in the
  **built ROM** and proves every composable sentence fits the bounded text
  buffer (the doc-06 string-safety target).
- **Headless integration tests** ([`test/integration/`](test/integration/))
  boot the ROM in PyBoy and assert on memory, OAM and the tilemap: movement,
  collision, streaming, zombies, sprite hygiene, the full dialogue flow, and
  poison-boot checks that nothing depends on zeroed power-on RAM.

## Roadmap

Built in vertical slices (see [doc 02 §6](docs/design/02-world-and-exploration.md)):

- [x] v0.1 — controllable player on a generated world
- [x] v0.2 — endless streaming world, water + roads, walk animation
- [x] Music playback (hUGEDriver + hUGETracker pipeline, demo song)
- [x] v0.3 — wandering zombies with line-of-sight → battle trigger (placeholder)
- [x] Title screen with a random world seed per playthrough (START-press
      timing; SELECT+START replays the classic seed)
- [x] v0.4 — survivors: 10 personas, grammar dialogue, 8-tone random menus,
      affinity, 3-round outcomes
- [ ] Gift items + real survivor combat (wire the outcome placeholders up)
- [ ] Houses + rivers (multi-tile / connected structures)
- [ ] Turn-based combat (2 weapons + 2 skills)
- [ ] Save system (battery SRAM diffs)
- [ ] Food/sleep survival pressure

## License / attribution

Toolchain: [RGBDS](https://github.com/gbdev/rgbds) and
[hardware.inc](https://github.com/gbdev/hardware.inc); emulator:
[mGBA](https://mgba.io/). All pinned and fetched by `make tools` / `make run`.
