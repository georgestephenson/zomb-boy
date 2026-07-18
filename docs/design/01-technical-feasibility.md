# 01 — Technical Feasibility

This doc answers the load-bearing question: **can a Game Boy Color actually run an
endless, procedurally-generated world that remembers where you've been — and if we
run out of memory, barrier off the edges?**

Short answer: **Yes, comfortably — but only if we generate deterministically and
persist *changes*, not terrain.** The rest of this doc explains why, with the real
hardware numbers.

---

## 1. The hardware we're working with

Game Boy Color (in GBC-only mode, which we target — `rgbfix -C`):

| Resource | Amount | Notes |
|----------|--------|-------|
| CPU | Sharp LR35902 @ 4.19 MHz, **8.38 MHz in double-speed** | We'll likely run double-speed during logic-heavy frames. |
| Work RAM (WRAM) | **32 KB** | `C000–CFFF` fixed bank 0 + `D000–DFFF` switchable banks 1–7. DMG only had 8 KB. |
| Video RAM (VRAM) | **16 KB** | Two banks; bank 1 holds GBC tile attributes. |
| OAM (sprites) | 40 sprites, **10 per scanline** | Hard limit on on-screen actors. |
| Background | 256×256 px tilemap; screen is **160×144** (20×18 tiles) | Scrolls via `SCX`/`SCY`. |
| Cartridge ROM | up to **8 MB** (MBC5, 512 × 16 KB banks) | All our code, art, text, and generation tables. |
| Cartridge SRAM (save) | up to **128 KB** (MBC5, 16 × 8 KB banks), battery-backed | **This is the only memory that persists between sessions.** |

**Decision: MBC5 + 128 KB SRAM + battery.** MBC5 is the modern standard (clean
banking, well-supported by flashcarts and emulators) and 128 KB of battery save is
the ceiling that matters for "the world remembers."

---

## 2. Why "remember the whole world" is the wrong framing

The naïve idea is: as the player explores, store each visited chunk's tiles to
SRAM. Let's price that out.

- Say a **chunk** is 16×16 tiles. At 1 byte/tile that's 256 bytes of terrain.
- 128 KB SRAM ÷ 256 B ≈ **512 chunks**. A 16-tile chunk is one screen-ish, so
  that's a world only ~22×22 screens before the save is full. That's *tiny* for
  something billed as "endless." Dead on arrival.

The problem is that we'd be storing information the game can already *recompute*.

## 3. The Minecraft trick: deterministic generation

Minecraft's world is "infinite" but its save file doesn't grow linearly with
distance walked, because terrain is a **pure function of a seed**:

```
terrain(worldSeed, chunkX, chunkY)  →  always the same tiles
```

If generation is deterministic, we **never store unmodified terrain**. Walk 10,000
tiles east, walk back, and we regenerate the identical ground on the fly from the
seed. Cost to store that journey: **zero bytes.**

On GBC this is very achievable. Our generator is a cheap hash-based noise function
(not floating-point Perlin — we use integer value-noise / a hashed PRNG):

```
h = hash(worldSeed, chunkX, chunkY, tileX, tileY)   ; a few adds/xors/mul
tileType = thresholds(h)                            ; grass / rubble / road / wall / loot
```

This is a handful of 8-bit ops per tile, table-driven. Generating a fresh 16×16
chunk is a few thousand cycles — trivial to do during a screen transition or spread
across frames as the player approaches a chunk boundary. See
[02 — World & Exploration](02-world-and-exploration.md) for the exact algorithm.

## 4. So what DO we store? Only diffs.

The player *changes* the world: kills a zombie, loots a crate, breaks a barricade,
drops an item. Those changes can't be recomputed from the seed, so those are the
only things we persist. A **diff** is a small record:

```
struct WorldDiff {         ; ~5 bytes packed
    s16 chunkX, chunkY      ; which chunk        (could pack tighter)
    u8  localIndex          ; which tile/entity within the chunk (0..255)
    u8  newState            ; looted / destroyed / dead / opened ...
}
```

At ~5 bytes each, even reserving **64 KB** of SRAM for diffs holds **~13,000
changes** — vastly more meaningful player actions than anyone will make in one
playthrough. The other half of SRAM holds the player save (inventory, stats,
position, relationships, RNG seed).

Persistence therefore scales with **how much you change the world**, not **how far
you walk** — exactly the property we want.

### Keeping the diff store fast

- Diffs are grouped/indexed by chunk so that loading a chunk is: regenerate from
  seed, then apply only the diffs whose `(chunkX,chunkY)` match. We keep a small
  per-region index so we don't scan all 13k diffs per chunk.
- Only chunks in a small window around the player are ever "live" in WRAM (see the
  active-set discussion in [02](02-world-and-exploration.md)). SRAM is the cold
  store; WRAM holds just the neighborhood.

## 5. "Once we run out of memory, barrier off the edges." Feasible?

**Yes, and it's a clean fallback rather than a hack.** Two independent limits can
be hit, and each has a graceful barrier:

1. **Coordinate range.** We use signed 16-bit chunk coordinates: ±32,767 chunks ×
   16 tiles ≈ **±524,000 tiles** in each axis. At normal walking speed that's
   effectively unreachable — but it's a *hard, well-defined* edge. When the player
   reaches it, generation places an impassable "the world ends here" barrier
   (rubble wall / ocean / fog). No overflow, no undefined behavior.

2. **Diff store full.** If a player somehow makes 13,000 persistent changes, we
   stop accepting *new* changes to *not-yet-visited* far regions — i.e. the
   frontier freezes. Already-visited areas still work; you just can't permanently
   alter brand-new far-flung terrain. In practice we'll surface this as a soft
   "the world beyond here is unstable" barrier long before the array truly fills.

Both barriers are just generation rules keyed on coordinate/state, so they cost
nothing extra and are fully testable (we can unit-test "at max coord, tile ==
BARRIER"). The important correctness property — **no integer overflow on world
coordinates** — is enforced by clamping in one place and covered by tests (see
[06](06-testing-and-memory-safety.md)).

## 6. WRAM budget (the RAM that matters frame-to-frame)

A rough first-pass allocation of the 32 KB WRAM. This is a design target, not final:

| Region | Budget | Purpose |
|--------|-------:|---------|
| Player + save-shadow | ~1 KB | Stats, inventory, position, loadout, RNG state |
| Active chunk window | ~4–6 KB | The 3×3 (or 5×5) chunks around the player, decompressed to tiles |
| Entity list | ~1 KB | On-screen zombies/survivors/items (position, type, state) |
| Combat state | ~0.5 KB | Only allocated during battles |
| Dialogue/grammar scratch | ~0.5 KB | Only during survivor conversations |
| Rendering buffers (shadow OAM, tile queue) | ~1 KB | DMA'd shadow OAM, VRAM update queue |
| Stack | ~256 B | Watched by a canary in tests |
| Free / headroom | remainder | Deliberately kept large |

Combat, dialogue, and generation are **mutually exclusive modes**, so their scratch
regions can overlap (a union), which keeps peak WRAM use low.

## 7. Bottom line

- **Endless world:** yes — deterministic generation makes terrain free to store.
- **Remembers where you went:** yes — we store *changes* (diffs), which is all that
  can't be regenerated; scales with actions, not distance.
- **Barrier at the edges when memory runs out:** yes — two clean, testable barriers
  (coordinate max, diff-store full), both expressed as ordinary generation rules.

The engineering risk is not "can the hardware do it" — it's "is our assembly
memory-safe while doing it." That risk is addressed head-on in
[06 — Testing & Memory Safety](06-testing-and-memory-safety.md).
