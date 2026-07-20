# 07 — GBC Hardware Tricks

A research digest of the best-known techniques for squeezing the most out of Game
Boy Color hardware — from Pan Docs, the gbdev community, the demoscene, and shipped
commercial games — **filtered for what a streaming-world SM83/RGBDS game like Zomb
Boy can actually use.**

This is a reference, not a roadmap. Each technique is tagged for how it maps onto
*our* engine (double-speed already on, circular-buffer BG streaming, a bottom-band
window HUD, entity pools, hUGEDriver over a vendored driver). Sources are linked
inline; the load-bearing hardware facts are from Pan Docs (primary).

> **Method note.** This was assembled by a fan-out research pass (22 sources, ~106
> extracted claims, adversarial verification). Claims marked ✅ were confirmed 3/3 by
> independent verifiers; the rest are sourced to the authoritative reference (Pan
> Docs / gbdev) or clearly attributed to a blog/forum/retrospective. Feel/latency
> claims about shipped games are secondary and flagged as such.

---

## 0. The one thing to internalize: the frame is a cycle budget, not a canvas

Everything below is a way of spending a fixed per-frame budget. The numbers that
bound every trick:

| Fact | Value | Source |
|------|-------|--------|
| Frame rate | ~59.7 Hz; VBlank at LY=144, lasts ~1.1 ms, VRAM freely accessible ✅ | [Pan Docs — Interrupts](https://gbdev.io/pandocs/Interrupt_Sources.html) |
| Scanline | exactly 456 dots = 114 CPU cycles (single speed); Mode 2 is a constant 20 cycles | [gbdev — LYC timing](https://gbdev.io/guides/lyc_timing) |
| VRAM access | Modes 0 (HBlank), 1 (VBlank), 2 (OAM scan) only | [Pan Docs — Accessing VRAM/OAM](https://gbdev.io/pandocs/Accessing_VRAM_and_OAM.html) |
| OAM access | Modes 0 and 1 only | same |
| Mode 3 (drawing) | VRAM/OAM writes **ignored**, reads return `$FF` | same |
| Naive VBlank copy budget | ~2280 bytes ≈ **142 tiles** per VBlank via GDMA | [Pan Docs — CGB Registers](https://gbdev.io/pandocs/CGB_Registers.html) |

**Double-speed is a CPU multiplier, not a video one.** KEY1+`stop` doubles the CPU,
timer/DIV, serial, and OAM-DMA clocks — but the **LCD, HDMA-to-VRAM, and all audio
timings stay at normal speed**. So double-speed buys you ~2× the *CPU work* per
scanline/HBlank/VBlank window; it does **not** widen the HDMA pipe or change PPU
timing. The switch itself stalls the CPU for 2050 M-cycles, so do it once at boot
(we already do, gated on `hIsCGB`).
[Pan Docs — CGB Registers](https://gbdev.io/pandocs/CGB_Registers.html)

---

## 1. Visual & raster effects

### 1.1 The STAT/LYC raster split — the master key

Almost every "impossible" GBC visual is one mechanism: an **LY=LYC STAT interrupt**
that fires on a chosen scanline and rewrites a PPU register mid-frame. The STAT
interrupt line is the OR of the enabled mode conditions and the LYC=LY compare, and
it fires only on **rising edges** of that combined line. ✅
[Pan Docs — Interrupts](https://gbdev.io/pandocs/Interrupt_Sources.html)

Two traps that bite every naive implementation:

- **STAT blocking.** If two STAT sources are enabled and both conditions hold across
  a transition (e.g. Mode 0 then Mode 1), the line never drops low between them and
  the second interrupt is **silently lost**. ✅ Combine HBlank + LYC/VBlank sources
  carefully. [Pan Docs — Interrupts](https://gbdev.io/pandocs/Interrupt_Sources.html)
- **The interrupt fires too early to write the line it names.** LY=LYC fires at the
  *start* of the scanline, during the ~20-cycle Mode 2 — too little time to do
  anything. The fix: to affect scanline *N*, trigger on *N−1* and do the write in
  **that** line's HBlank (set `LYC=15` to change scanline 16).
  [gbdev — LYC timing](https://gbdev.io/guides/lyc_timing)

A properly **cycle-counted** handler has ~22 cycles of worst-case HBlank to write
registers — enough for up to ~3 PPU-register writes plus `pop`/`reti`. Variable-length
branches blow the budget and tear; keep the handler constant-time.
[gbdev — LYC timing](https://gbdev.io/guides/lyc_timing) · Double-speed roughly doubles
this window (more CPU per fixed dot count).

**For Zomb Boy:** we don't use STAT/LYC at all yet. It's the enabling technology for
a *top* HUD bar, a colored sky/horizon band, and day/night gradient — see §5.

### 1.2 "Hi-color": thousands of colours by rewriting palettes per scanline

The headline demoscene trick. The BG normally shows 32 colours (8 palettes × 4). By
**rewriting palette memory during HBlank**, in principle every scanline gets its own
8 palettes — in practice the CPU can only load a full fresh set every **2 scanlines**,
yielding **~2000 colours on one screen**. ✅
[romhack — GBC Hicolour](https://romhack.github.io/doc/gbcHiColour/) ·
[png2hicolorgb](https://github.com/bbbbbr/png2hicolorgb)

How it's actually structured (the maintained `png2hicolorgb` / Glen Cook pipeline):

- Screen split **left (palettes 0–3) / right (palettes 4–7)**, each region ~80×2 px.
  A full 160×144 image needs **73 left + 72 right** palette updates. ✅
- Updates are **timed to PPU mode**: most of the next line's palette writes start in
  HBlank (Mode 0); the first two happen in VBlank (Mode 1). ✅
- Image is diced into **16×2-px blocks each owning one palette** (Crystalis-style:
  512 palettes = `$1000` bytes for a 128×128 image). [romhack](https://romhack.github.io/doc/gbcHiColour/)

**Cost and verdict:** it eats *most of the CPU every frame* and bloats ROM with
pre-baked per-scanline palette tables — so it's for **static images** (title, cutscene
stills), never a scrolling gameplay scene.
[png2hicolorgb](https://github.com/bbbbbr/png2hicolorgb) · Commercially, Pokémon
Gold/Silver is cited as doing lighter between-scanline BG palette rewrites.
[gbdev forum](https://gbdev.gg8.se/forums/viewtopic.php?id=551)
**For Zomb Boy:** viable only for our CGB title screen (already a static full-screen
image) if we ever want it richer — not the overworld.

### 1.3 Palette swaps as cheap animation (the technique we already lean on)

Changing a tile's **colours** is a 1-byte palette write; changing its **pixels** is up
to 16 bytes of VRAM that must land in VBlank. Palette writes are the cheapest visual
change on the platform. [blog.tigris.fr](https://blog.tigris.fr/2025/05/20/playing-with-game-boy-palettes/)

- **Palette cycling** (flowing water, lava, pulsing lights) = rotate the palette
  register. On DMG it's literally two `RLC` on `BGP` per step from the VBlank handler
  — zero VRAM cost. On CGB, rewrite the 4-colour BG palette via `BCPS`/`BCPD`.
  [blog.tigris.fr](https://blog.tigris.fr/2025/05/20/playing-with-game-boy-palettes/)
- CGB BG/OBJ palettes can be written **any time except Mode 3**. [devrs FAQ](http://www.devrs.com/gb/files/faqs.html)

**For Zomb Boy:** our `anim.asm` living-world effects swap **shared tile *art*** in
VRAM (`$8000+id*16`) — correct where the shape changes (tree sway, door open). But
anything that's only a **colour** change (water shimmer, a day/night tint, a
damage-flash) is cheaper as a **palette rotate** than an art swap, and palette writes
dodge the "skip PushAnim on the strip-blit frame" VBlank contention entirely. Worth
considering for the water shimmer specifically.

### 1.4 Tile-art animation vs map animation (our core invariant, validated)

Swapping the **art** behind a shared tile id animates *every* on-screen instance at
once, touches no tilemap cell, costs no OAM, and is DMG-safe (bank-0 tile data, no
attributes). This is exactly `anim.asm`'s design and it's the textbook-correct choice
— the research surfaced no better general pattern for ambient BG animation. The only
refinement is §1.3: prefer a palette write when only colour changes.

### 1.5 Parallax on a one-layer machine

The GBC has a single BG layer, yet Shantae and Toki Tori show visible parallax. The
trick: an LYC/STAT handler **rewrites `SCX` per horizontal band**, so different screen
rows scroll at different speeds. [Larold's GBDK parallax](https://fkefjzwv.elementor.cloud/tutorial/parallax-backgrounds-with-gbdk-2020/) ·
[Racketboy](https://racketboy.com/retro/game-boy-games-that-pushed-the-limits-of-graphics-sound)

- Cheap multi-speed layers from **one** 16-bit master scroll counter, right-shifted
  by different amounts per band (`SCX = counter>>7` far … `SCX = counter` near) — 5
  bands, near-zero CPU. [Larold's](https://fkefjzwv.elementor.cloud/tutorial/parallax-backgrounds-with-gbdk-2020/)
- Timing facts that make it glitch-free: `SCX/SCY` are writable even in Mode 3 ✅, and
  the PPU **re-reads scroll on every tile fetch except the low 3 bits of SCX**, which
  latch at scanline start ✅ — so coarse X can change mid-line but **fine (sub-tile) X
  only takes effect next line**. Do fine-scroll splits in HBlank.
  [Pan Docs — Scrolling](https://gbdev.io/pandocs/Scrolling.html)
- **Demotronic** pioneered *vertical* raster splits by writing **`SCY`** mid-display
  (plus a checkerboard "scaling" effect and a tunnel) — so accuracy-sensitive it ships
  emulator-detection and only BGB/Gambatte/SameBoy reproduce it. [pouët](https://www.pouet.net/prod.php?which=7175)

**For Zomb Boy:** our world is top-down and endless, so *world* parallax doesn't apply
— but a **decorative sky/cloud band** or a **subtle heat-haze in the desert biome**
(a per-line SCX wobble on a few rows) would be a legitimate, cheap use. Caveat: the
GBDK parallax tutorial explicitly assumes a ≤256-px BG and does **not** handle a
streaming world larger than the tilemap — combining per-line SCX with our
circular-buffer streaming needs care (the handler must respect the same `view & 31`
wrap our engine uses).

### 1.6 Rendering big things as background, not sprites

Shantae draws its **large bosses in the BG layer** specifically to dodge the
10-sprite-per-scanline limit and its flicker/slowdown. [Racketboy](https://racketboy.com/retro/game-boy-games-that-pushed-the-limits-of-graphics-sound)
A general principle: anything big, slow-moving, and non-overlapping is cheaper as BG
tiles than as a sprite army. **For Zomb Boy:** if a future boss zombie or a vehicle
is larger than ~2×2, consider a BG-tile representation over burning the OAM budget.

---

## 2. Sprites, OAM & the window

### 2.1 The hard limits and how to hide correctly

40 sprites total; **10 per scanline**, a hardware cap. ✅
[Pan Docs — OAM](https://gbdev.io/pandocs/OAM.html) The critical, easy-to-get-wrong
rule:

> **Off-screen sprites hidden by X still burn a per-scanline slot** — the PPU selects
> objects by **Y only**. Hide unused/culled sprites by setting **Y = 0 or Y ≥ 160**,
> never by parking X. ✅ [Pan Docs — OAM](https://gbdev.io/pandocs/OAM.html)

**Zomb Boy already does this correctly:** `HideEntitySprites` (entity.asm) zeroes the
OAM **Y** byte for every pool slot before drawing, and `DrawCar` hides the on-foot
player with `Y=0`. No change needed — but keep the rule in mind for any new pool.

### 2.2 Priority ordering differs DMG vs CGB

DMG resolves sprite-vs-sprite priority by **X coordinate** (lower X wins, OAM index
tiebreak); **CGB resolves purely by OAM index**. ✅
[Pan Docs — OAM](https://gbdev.io/pandocs/OAM.html) This matters for the classic
**flicker multiplexer**: to survive the 10/line cap when contended, rotate OAM entry
order each frame so the *dropped* sprite differs frame-to-frame (even, deliberate
flicker rather than the same actor always vanishing).
[gbdev forum — flicker](https://gbdev.gg8.se/forums/viewtopic.php?id=631) On CGB the
thing you re-sort is **OAM index**.
**For Zomb Boy:** with `MAX_ZOMBIES`/`MAX_NPCS` small and entities spread across a
top-down field, we rarely contend 10-on-a-line. If a dense horde mode ever appears,
per-frame OAM-index rotation is the escape hatch — cheap to add to `DrawEntities`.

### 2.3 CGB sprite richness for free

Each CGB sprite attribute picks **1 of 8 OBJ palettes** and **either VRAM tile bank**
— doubling tile capacity and colour variety over DMG's two palettes, at no OAM cost. ✅
[Pan Docs — OAM](https://gbdev.io/pandocs/OAM.html) We already exploit palette
selection for persona tints; VRAM-bank-1 sprite tiles are unused headroom if we run
short of the 256-tile OBJ space.

### 2.4 OAM DMA discipline (we do this right)

Build a **shadow OAM in WRAM**, copy via **OAM DMA (`$FF46`)** — faster than direct
writes and the only clean way outside HBlank/VBlank. The trampoline must run from
**HRAM** because every non-VRAM area is bus-disabled during the ~160 µs transfer (80 µs
in double-speed). ✅ [Pan Docs — OAM](https://gbdev.io/pandocs/OAM.html) ·
[Accessing VRAM/OAM](https://gbdev.io/pandocs/Accessing_VRAM_and_OAM.html) This is
exactly our `hOAMDMA` boot-copied trampoline + 256-byte-aligned shadow OAM.

### 2.5 The window is a bottom-right rectangle, not a band

The window draws **above BG, below sprites**, and always spans from (WX,WY) to the
**bottom-right corner** — so a full-frame window hides the whole world. A partial HUD
needs a **raster split**: `LYC` = the HUD's Y edge, and the STAT handler toggles LCDC
(window/sprite bits) at that line. [GB ASM tutorial — HUD](https://gbdev.io/gb-asm-tutorial/part3/heads-up-interface.html)
Point BG and window at **different tilemaps** (`LCDCF_WIN9C00 | LCDCF_BG9800`).

**For Zomb Boy:** our HUD is a *bottom* 8-px band sourced from SCRN1 row 0 — which
works **without** a raster split precisely because the window extends *down* to the
corner and we put it at the bottom. A **top** status bar (or a two-line HUD) is the
canonical LYC use-case and would be our first STAT handler if we want one. The repo
note already records the "window is not a sizable rectangle" gotcha — this confirms it.

---

## 3. Audio

### 3.1 Driver design & our current choice

hUGEDriver is a "fast, tracker-based, public-domain" driver ✅ positioned as the
**middle ground** between LSDJ (flexible, CPU-heavy) and GBT Player (compact, less
versatile) — fast playback + compact data, *suitable for embedding in a game* where
LSDJ/DefleMask are not. [hUGEDriver](https://github.com/SuperDisk/hUGEDriver) ·
[hUGETracker wiki](https://nickfa.ro/wiki/HUGETracker) The integration model is one
`hUGE_init` (song ptr in `hl`) then **one `hUGE_dosound` per frame**. This is exactly
`InitSound`/`UpdateSound`, and our once-per-frame, outside-VBlank call site is the
recommended low-overhead pattern.

### 3.2 Sharing the wave channel (directly relevant to our SFX)

Our `PlaySplash`/`PlayCarDoor` borrow a channel for one-shot SFX. The driver **caches
CH3's waveform**, so if we ever push our own wave into CH3 we must set
`hUGE_current_wave = hUGE_NO_WAVE` to force a reload, or the driver won't restore its
own waveform. [hUGEDriver](https://github.com/SuperDisk/hUGEDriver)

### 3.3 Wave-channel / pseudo-PCM sample playback

The most impressive commercial GBC audio is **PCM samples** streamed through the APU:

- **CH3** plays a 4-bit, 32-sample waveform at **32× its programmed frequency**;
  sample #0 is skipped on start-up. [Pan Docs — Audio](https://gbdev.io/pandocs/Audio_details.html)
- **Retrigger artifacts:** CH3 emits from an internal buffer that retriggering does
  **not** refresh — the first sample out is a stale nibble. And on **DMG**, triggering
  while it reads a sample **corrupts the first 4 bytes of wave RAM**; the documented
  fix is to stop the channel (`NR30` ← 0 then `$80`) before every retrigger. Since we
  ship a **dual-mode CGB/DMG** cart, a sample driver would have to honour this.
  [Pan Docs — Audio](https://gbdev.io/pandocs/Audio_details.html)
- **1-bit sample playback** by modulating `NR51` routing instead of wave RAM is a
  documented cheaper variant. [devrs FAQ](http://www.devrs.com/gb/files/faqs.html)
- **"Zombie mode":** change a pulse/noise channel's volume mid-note by writing `NRx2`
  without retriggering (most consistent on CGB-02/-04) — smooth volume ramps.
  [Pan Docs — Audio](https://gbdev.io/pandocs/Audio_details.html)

**Commercial practice:** the common pattern is **music on 3 channels + 1 channel for
PCM SFX** (Mortal Kombat 4, Simba's Mighty Adventure, Duke Nukem). Cannon Fodder
samples *all* its audio (voice, theme, ambience) even under FMV. The advanced move is
mixing PCM **into** the music alongside all channels — **Project S-11** (demoscene
composers Purple Motion & Heatbeat) put **PCM drums and bass in the wave channel**;
102 Dalmatians uses a sampled xylophone. Warlocked's unit-acknowledgement speech is
cited as the platform's best. Alone in the Dark uses PCM for in-game **ambience**.
[chipmusic — PCM list](https://chipmusic.org/forums/topic/16824/incomplete-list-of-gbgbc-games-to-use-pcm-samples/) ·
[Racketboy](https://racketboy.com/retro/game-boy-games-that-pushed-the-limits-of-graphics-sound)
Note S-11's music is CPU-heavy enough to *drag under emulation but run fine on
hardware* — a reminder that PCM buys richness at real CPU cost.

**For Zomb Boy — realistic verdict:** full music-PCM is out of scope, but a **single
short sampled SFX** (a zombie groan, a gunshot when combat lands, a UI blip) played
through CH3 on the "3 music + 1 SFX" pattern is well-trodden and would add a lot of
atmosphere. It costs a timer-driven feed loop and the DMG-corruption guard; park it
behind combat (docs/design/04) where a hit already interrupts the loop.

---

## 4. Performance, DMA & banking

### 4.1 GDMA vs HDMA vs CPU copy — the streaming-engine decision

Three ways to get bytes into VRAM, and our `BlitStream` currently uses the third:

| Method | Behaviour | Best for |
|--------|-----------|----------|
| **GDMA** (general-purpose) | Copies `$10`–`$800` bytes at once, **CPU stalled** until done; ~2280 bytes / **142 tiles per VBlank** ✅ | Big one-shot loads (room/biome transition, menu rebuild) inside VBlank or LCD-off |
| **HDMA** (HBlank DMA) | Copies **`$10` bytes per HBlank** on visible lines 1–144, CPU runs between blocks | Streaming a large transfer *across* a frame without eating the whole VBlank |
| **CPU copy** (`ld [hl+]` / stack-pop) | Fully flexible; unrolled `pop`/`push` ≈ 9 cyc/2 bytes; ~8 bytes in a Mode-0+2 window | Small, irregular strips; when you need to transform data en route |

Key constraints:
[Pan Docs — CGB Registers](https://gbdev.io/pandocs/CGB_Registers.html) ·
[devrs FAQ](http://www.devrs.com/gb/files/faqs.html)

- **HDMA rate does NOT double in double-speed** — only CPU copies benefit from
  double-speed. So the choice between HDMA and CPU-copy shifts *toward CPU copy* on a
  double-speed machine like ours.
- HDMA needs **16-byte-aligned** source & dest, does nothing with the screen off, is
  **paused during VBlank**, and is **broken by `HALT` in the main loop** — so it
  doesn't compose with our `WaitVBlank`-via-halt loop without restructuring.
- During an HDMA/GDMA you must **not change the dest VRAM bank (`FF4F`) or the source
  ROM/RAM bank** — constrains interleaving with MBC5 banked reads.
- Above **~1600 bytes (~100 tiles) per VBlank with the screen on you *need*
  double-speed** for GDMA to fit. ✅ [devrs FAQ](http://www.devrs.com/gb/files/faqs.html)

**For Zomb Boy:** our per-step strip is one 20-tile row × 2 passes, pushed by a CPU
copy in the same VBlank as the scroll update — comfortably inside the ~142-tile
double-speed budget, which is why it holds. Two upgrades worth considering:
1. **GDMA for the boot `InitMap` (1024 tiles) and menu/talk full-screen rebuilds** —
   these already run LCD-off, where GDMA is fastest and unconstrained. Could shave the
   boot-settle budget.
2. **HDMA is a poor fit for our per-step streaming** specifically because our loop
   halts for VBlank (HDMA pauses in VBlank and breaks under HALT). Keep the CPU-copy
   strip blit; if per-frame VRAM work ever grows past the VBlank budget, the repo's
   existing plan (lower `BLIT_CHUNK`, re-chunk across frames) is the right lever, not
   HDMA.

### 4.2 The LCD-off full-rebuild pattern (we use it; here's the rule)

Turning the LCD off is **only safe during VBlank** — doing it mid-frame can burn a
line into real hardware (Nintendo reportedly rejected games that did). ✅
[blog.tigris.fr](https://blog.tigris.fr/2025/05/20/playing-with-game-boy-palettes/) Our
`BuildTalkScreen`/`RebuildMenu`/`ShowTitle` do WaitVBlank→LCD-off→rebuild→LCD-on, which
is correct. Never `WaitVBlank` *while* the LCD is off (no STAT/VBlank IRQ fires) — the
repo already notes this.

### 4.3 Fast-copy idioms

The community-standard fast copies, in case a hot path needs them:
[gbdev forum — fastest VRAM copy](https://gbdev.gg8.se/forums/viewtopic.php?id=495)

- **Stack-pop copy:** point `sp` at the source, `pop` pairs of bytes, `push`/`ld` to
  dest — ~9 cycles per 2 bytes, the fastest CPU copy. (Disable interrupts; restore
  `sp`.)
- **256-byte-align buffers** so pointer math only touches the low byte — we already do
  this for shadow OAM, and it's worth it for any per-line palette/strip buffer.
- Unrolled `ld [hl+], a` beats a tight loop for known small sizes.

### 4.4 Banking (MBC5, our controller)

MBC5 is the modern standard and what the heavy-hitters shipped on (Cannon Fodder's
FMV cart is MBC5). [Racketboy](https://racketboy.com/retro/game-boy-games-that-pushed-the-limits-of-graphics-sound)
Our banking invariant (bank 1 default-mapped; each banked reader switches, reads,
restores bank 1) is already disciplined. The one DMA-specific rule to remember: **do
not flip the source bank mid-HDMA** (§4.1) — not a concern for our CPU-copy strip, but
it would be if we ever HDMA out of a ROMX data bank.

---

## 5. Concrete opportunities for Zomb Boy

Ranked by value-for-effort. None are committed work — this is the menu the research
suggests.

1. **Day/night palette tint (cheap, high impact).** docs/design/03 lists day/night as
   LATER. A time-of-day tint over BG palettes is a handful of `BCPS`/`BCPD` writes per
   in-game hour — no per-frame cost, no VRAM. The clock already exists (`wClockH`).
   This is the single best colour-for-money win. (§1.3)
2. **Water shimmer as palette cycle, not art swap.** If the shimmer is only colour, a
   palette rotate is cheaper than `anim.asm`'s art swap and sidesteps the PushAnim /
   strip-blit VBlank contention. (§1.3–1.4)
3. **A single sampled combat SFX via CH3** (3-music + 1-PCM pattern), gated behind
   combat, with the DMG wave-RAM-corruption guard. Atmosphere for modest CPU. (§3.3)
4. **Top HUD / second HUD line via LYC split**, if the design ever wants more than the
   bottom band. This would be our first STAT handler and unlocks everything in §1. (§2.5)
5. **Decorative sky/haze parallax band** — niche, top-down world limits it, but a
   desert heat-haze or a scrolling cloud strip is a legitimate per-line SCX effect.
   Must cooperate with the circular-buffer wrap. (§1.5)
6. **GDMA for LCD-off rebuilds** (boot map, menu, talk) — a pure speed refinement of
   paths that are already LCD-off. (§4.1)

Things the research says to **avoid** for our engine: full-screen hi-color in the
overworld (static-image only, §1.2); HDMA for per-step streaming (fights our
halt-based VBlank loop, doesn't benefit from double-speed, §4.1); hiding sprites by X
(we don't — keep it that way, §2.1).

---

## Sources

Primary (Pan Docs / gbdev, authoritative):
[Interrupts](https://gbdev.io/pandocs/Interrupt_Sources.html) ·
[OAM](https://gbdev.io/pandocs/OAM.html) ·
[Scrolling](https://gbdev.io/pandocs/Scrolling.html) ·
[Accessing VRAM/OAM](https://gbdev.io/pandocs/Accessing_VRAM_and_OAM.html) ·
[CGB Registers](https://gbdev.io/pandocs/CGB_Registers.html) ·
[Audio Details](https://gbdev.io/pandocs/Audio_details.html) ·
[LYC timing guide](https://gbdev.io/guides/lyc_timing) ·
[HUD tutorial](https://gbdev.io/gb-asm-tutorial/part3/heads-up-interface.html) ·
[devrs GB DEV FAQ](http://www.devrs.com/gb/files/faqs.html)

Technique writeups / tools:
[png2hicolorgb](https://github.com/bbbbbr/png2hicolorgb) ·
[GBC Hicolour notes](https://romhack.github.io/doc/gbcHiColour/) ·
[Lazy Stripes — GB palettes](https://blog.tigris.fr/2025/05/20/playing-with-game-boy-palettes/) ·
[GBDK parallax](https://fkefjzwv.elementor.cloud/tutorial/parallax-backgrounds-with-gbdk-2020/) ·
[hUGEDriver](https://github.com/SuperDisk/hUGEDriver) ·
[hUGETracker wiki](https://nickfa.ro/wiki/HUGETracker) ·
gbdev forums:
[palette swap in HBlank](https://gbdev.gg8.se/forums/viewtopic.php?id=551),
[avoiding flicker](https://gbdev.gg8.se/forums/viewtopic.php?id=631),
[fastest VRAM copy](https://gbdev.gg8.se/forums/viewtopic.php?id=495)

Exemplars (secondary / retrospective):
[Racketboy — games that pushed the limits](https://racketboy.com/retro/game-boy-games-that-pushed-the-limits-of-graphics-sound) ·
[HG101 — Shantae](https://www.hardcoregaming101.net/shantae/) ·
[Demotronic — pouët](https://www.pouet.net/prod.php?which=7175) ·
[Nintendo Life — Alone in the Dark GBC](https://www.nintendolife.com/features/soapbox-alone-in-the-dark-on-gbc-is-a-bizarre-relic-you-should-play-at-least-once) ·
[chipmusic — GB/GBC PCM games](https://chipmusic.org/forums/topic/16824/incomplete-list-of-gbgbc-games-to-use-pcm-samples/)
