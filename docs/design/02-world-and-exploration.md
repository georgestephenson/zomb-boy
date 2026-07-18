# 02 — World & Exploration

How the endless world is generated, streamed, and persisted. Builds directly on
the feasibility argument in [01](01-technical-feasibility.md).

---

## 1. Coordinate system

- **Tile:** the atomic unit. 8×8 px. The player moves tile-by-tile (Pokémon-style
  grid movement).
- **Chunk:** 16×16 tiles. The unit of generation, persistence, and streaming.
- **Chunk coordinates** are signed 16-bit `(chunkX, chunkY)`. World origin `(0,0)`
  is where the player starts.

Conversion is pure shifts/masks:

```
chunkX  = tileX >> 4          ; divide by 16
localX  = tileX &  15         ; position within chunk
```

Because chunk coords are `s16`, the reachable world is ±32,767 chunks per axis —
the hard barrier from [01 §5](01-technical-feasibility.md#5-once-we-run-out-of-memory-barrier-off-the-edges-feasible).

## 2. Deterministic generation

Terrain is a **pure function** of the world seed and the tile's global coordinates.
No floating point; everything is integer hashing.

```
; Inputs: worldSeed (u32), tileX (s16), tileY (s16)
; Output: tileType (u8)

hash = worldSeed
hash = mix(hash, tileX)      ; mix = xor, multiply by an odd constant, rotate
hash = mix(hash, tileY)
tileType = TERRAIN_LUT[ hash & TERRAIN_MASK ]   ; weighted table -> grass/road/rubble/wall/loot
```

Key properties:
- **Deterministic:** same inputs → same output, this session or ten sessions later.
  This is what makes terrain free to store (we recompute it).
- **Local:** a tile's type depends only on its own coordinates (plus, for features
  that need neighborhood context like roads/buildings, a second pass over the chunk
  using the same hash). No global state, so we can generate any chunk in isolation.
- **Cheap:** ~10–20 CPU cycles per tile; a full 256-tile chunk is a few thousand
  cycles — done during a walk-toward-boundary over several frames, never in one lump.

### Structure beyond noise (LATER-friendly)
The v0 generator can be pure noise (grass/rubble/scattered loot). Richer structure —
roads, buildings, biomes ("suburbs", "downtown", "forest") — layers on as additional
deterministic passes keyed on coarser coordinates (e.g. a "district" hash on
`chunkX>>3`). These are **LATER**; the architecture supports them without change
because everything is still `f(seed, coords)`.

## 3. Streaming: the active window

Only a small neighborhood is "live" in WRAM at once.

- The **active window** is the 3×3 chunks centered on the player's current chunk
  (5×5 if the budget allows — see WRAM table in [01 §6](01-technical-feasibility.md#6-wram-budget-the-ram-that-matters-frame-to-frame)).
- When the player crosses a chunk boundary, we **generate the newly-entered ring**
  of chunks and **discard the ring left behind**. This is a scrolling ring buffer,
  not a full reload.
- Generation of the incoming ring is **spread across frames** as the player
  approaches the boundary, so there's no single-frame hitch.

Loading one chunk =
1. Generate terrain from seed (§2).
2. Apply matching diffs from SRAM (§4) — overwrite looted/destroyed/spawned tiles.
3. Spawn its entities (zombies/survivors/items) using a *separate* deterministic
   spawn hash, minus any that a diff records as already dead/taken.

## 4. Persistence (diffs) — the save format

Recap from [01 §4](01-technical-feasibility.md#4-so-what-do-we-store-only-diffs):
we persist only what can't be regenerated.

SRAM layout (128 KB total, MBC5, battery-backed):

| Region | Size (target) | Contents |
|--------|-------------:|----------|
| Save header | 64 B | Magic bytes, version, checksum, worldSeed, playtime |
| Player save | ~2 KB | Position, stats, food/sleep, inventory, loadout, RNG state |
| Relationship table | ~2 KB | Known survivors + affinity (see [05](05-survivors-social.md)) |
| Region index | ~4 KB | Maps a coarse region → offset/count into the diff array (fast lookup) |
| **Diff array** | ~64 KB+ | The world-change log (~13k entries) |
| Reserve | remainder | Future expansion; keeps us from designing to the exact edge |

**Integrity:** the header carries a checksum. On boot we validate it; a corrupt or
absent save (checksum fail / wrong magic) triggers new-game generation rather than
reading garbage. This is both a UX feature and a memory-safety guard (never trust
SRAM contents — a flashcart's SRAM can be uninitialized).

**Save-anywhere vs. checkpoint:** because state is small and always in WRAM, we can
save on sleep and/or on a menu command. Battery-backed SRAM means no "save file"
ceremony — it's just there next boot.

## 5. Barriers (the "run out of memory" edges)

Implemented purely as generation rules, so they're testable in isolation:

- **Coordinate barrier:** if `|chunkX|` or `|chunkY|` ≥ `WORLD_MAX_CHUNK`, the
  generator returns `TILE_BARRIER` (impassable) regardless of noise. Test:
  *"generate at max coord ⇒ every edge tile is BARRIER, and the tile just inside is
  not."*
- **Diff-store barrier:** a `diffCount >= DIFF_SOFT_LIMIT` flag flips the frontier
  to read-only. Already-stored changes still load; new far changes are refused (and
  we can visually fog the unstable frontier). Test: *"with the diff array at the
  soft limit, a new change to an unvisited chunk is rejected and does not corrupt
  the array."*

No pointer arithmetic runs unclamped near these edges — clamping happens in **one**
coordinate-normalization routine that everything funnels through, which is the
single thing the tests hammer.

## 6. v0 vertical slice (the first thing we build)

To prove the core loop end-to-end before adding systems:

1. Boot → generate world from a fixed seed.
2. Walk around on a grid; world streams correctly across chunk boundaries.
3. Diffs persist one kind of change (e.g. "opened a loot crate") across a reset.
4. One **basic zombie** patrols; if it sees you (line of sight, [04](04-combat-weapons-skills.md)),
   it triggers a battle.
5. A minimal battle you can win or lose.

Explicitly **NOT** in v0: survivors, multiple zombie types, food/sleep pressure,
music, biomes. Those arrive in later slices per their own docs.
