# 06 — Testing & Memory Safety

You called this out specifically: **assembly gives us raw memory access, so we must
prove the code is memory-safe and bug-free.** This doc is the strategy for doing
that. It's a first-class part of the project, not an afterthought.

The core idea: **a Game Boy game is deterministic**, so it's unusually testable. Same
inputs → same memory state, every time. We exploit that hard.

---

## 1. Threat model — what actually goes wrong in GB assembly

The bugs we're defending against, concretely:

1. **Buffer overruns** — writing past a fixed array (tile buffers, the dialogue
   grammar buffer in [05](05-survivors-social.md), the diff array in
   [02](02-world-and-exploration.md)).
2. **Integer wrap** — 8-bit meters/stats wrapping `255→0` or `0→255` instead of
   saturating ([03](03-survival.md), [04](04-combat-weapons-skills.md)).
3. **Coordinate overflow** — world coordinates exceeding `s16` and wrapping the
   player to the far side of the world ([01 §5](01-technical-feasibility.md#5-once-we-run-out-of-memory-barrier-off-the-edges-feasible)).
4. **Stack overflow / corruption** — deep call chains or unbalanced push/pop
   trampling WRAM.
5. **Uninitialized reads** — trusting WRAM/SRAM that was never set (SRAM on a fresh
   cart is garbage — see the save-checksum guard in [02 §4](02-world-and-exploration.md#4-persistence-diffs--the-save-format)).
6. **PPU-timing violations** — touching VRAM/OAM outside the allowed PPU modes,
   causing corruption on real hardware.

Each maps to a specific test category below.

## 2. Three layers of testing

### Layer A — Assertions built into the code (debug builds)
- A `DEBUG` assembler flag enables `ASSERT`-style macros that, on a failed invariant,
  halt and write a distinctive signature to a known RAM address / the serial port.
- **Bounds macros** for every array write: `SAFE_WRITE dest, index, max` asserts
  `index < max` before storing. In release builds these compile to nothing (or to a
  clamp), so there's no shipping cost.
- **Stack canary:** a known sentinel value placed at the low end of the stack region;
  a periodic check asserts it's intact. Catches stack overflow before it silently
  corrupts.

### Layer B — On-target test ROMs, run headless in an emulator
This is the workhorse. We build **separate test ROMs** (sources under `test/`) that:
1. Set up a scenario (e.g. "meter at 0, apply drain").
2. Run the real subsystem routine.
3. Compare RAM against expected values.
4. Report pass/fail via the **serial port** (or a result byte in RAM).

An emulator with a scripting/CLI API runs each test ROM **headless** and checks the
result — no human, no GUI. Preferred harnesses (see the tools note in the repo):
- **mGBA + Lua:** mGBA (our vendored emulator, see the Makefile) exposes a Lua
  scripting API and a headless CLI — load ROM, run N frames, read memory, assert,
  exit with a code. This is the default the test harness targets.
- **SameBoy tester:** headless run of test ROMs, most cycle-accurate GBC behavior —
  an optional second opinion if you install it.

> Note: we originally planned Mesen2 for its Lua API, but its GUI crashes
> (`std::bad_cast` in a settings-parsing regex) on very new libstdc++ builds
> (Ubuntu 26.04), so we switched to mGBA, which also scripts in Lua.

`make test` drives these (see `tools/run-tests.sh`). CI runs the same command.

### Layer C — Property / fuzz tests over pure functions
The generation and math routines are **pure** (no I/O), which makes them ideal for
property testing:
- **Deterministic generation:** `generate(seed, x, y)` called twice ⇒ identical
  output. Fuzz thousands of random coords.
- **Saturating math:** for all `a,b`, `meterAdd(a,b) ∈ [0,255]` and never wraps.
- **Coordinate clamp:** for all inputs incl. extremes, the normalized coordinate is
  within `[-WORLD_MAX, +WORLD_MAX]` and the barrier tile appears exactly at the edge.
- **Diff store:** applying then reading back a random sequence of diffs round-trips;
  at the soft limit, new far-diffs are rejected without corrupting existing entries.

Where practical we can also mirror a pure routine's spec in a **host-side model**
(tiny C or Python reference) and cross-check the ROM's output against it over random
inputs — differential testing.

## 3. What "done" looks like per subsystem

Every subsystem lands with its tests in the same change. A subsystem is not
"complete" until:
- [ ] Every fixed-size buffer it writes has a bounds test hitting the boundary + 1.
- [ ] Every 8-bit accumulator has a saturation test at both ends.
- [ ] Any state it allocates in shared scratch is proven cleared on entry.
- [ ] Its pure functions have determinism/property tests.
- [ ] It runs in a headless ROM that exits non-zero on failure (CI-gating).

## 4. Regression & CI

- All of the above run on every change via `make test`.
- Test ROMs are small and fast; the whole suite should run in seconds.
- A failing memory-safety test **blocks the build** — we treat a buffer overrun the
  way other projects treat a failing unit test.

## 5. Tooling recap

| Purpose | Tool |
|---------|------|
| Assemble/link/fix | RGBDS (pinned in repo via `make tools`) |
| Headless test + memory assertions | mGBA (Lua) and/or SameBoy tester |
| Illegal-access / bad-timing detection | Emulicious (dev-time) |
| Interactive debugging | SameBoy debugger |

## 6. Why this is tractable here (and not on, say, a PC game)

Determinism. No OS, no threads, no wall-clock nondeterminism, no heap. The machine
state is fully observable and reproducible. That's a gift: it means "prove it's
memory-safe" is a realistic goal for this project rather than a slogan — which is
exactly why you asked for it, and why we're building the harness *before* the game
grows large.
