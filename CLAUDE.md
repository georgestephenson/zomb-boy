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
make test       # runs tools/run-tests.sh (model + on-target ROMs; also runs
                # the SameBoy smoke when the tester is installed)
make smoke      # SameBoy accuracy smoke: boots the ROM in CGB AND true DMG
                # mode (the DMG path PyBoy can't run); auto-builds the tester
make sameboy    # just install the pinned SameBoy tester (source build)
make stats      # per-bank ROM/RAM utilization from the .map (ROM0 is tight!)
make play SCRIPT='walk right 60; state; entities; shot'
                # scripted headless play: inputs, screenshots, memory/state
                # dumps, ASCII world map — see tools/play.py --help
make shot       # boot headless + screenshot to build/play/
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
- **Headless input testing goes through PyBoy, not mGBA.** The mGBA AppImage
  ships only the Qt GUI (`mgba-qt`) — no Lua/CLI. But `make play` (tools/play.py,
  same PyBoy harness as the tests) can *drive* the game headless: scripted
  inputs, screenshots, decoded state/entity dumps, an ASCII world map. Use it to
  verify behavior and eyeball frames. What it still can't verify is *feel*
  (scrolling smoothness, animation timing on real hardware) and DMG-mode
  rendering — those need a human running `make run`. Say so; don't claim felt
  behavior is "verified."
- **Sandboxed/hosted sessions (e.g. Claude's web environment) block GitHub
  *release-asset* downloads at the egress policy (HTTP 403).** What that breaks
  and what still works, verified in-environment:
  * ❌ `github.com/.../releases/download/...` and `codeload.github.com` tarballs
    → 403. This is the RGBDS binary, the mGBA AppImage, and the hUGETracker
    bundle. `curl` hides the body on a failed CONNECT; the reason is at
    `curl -sS "$HTTPS_PROXY/__agentproxy/status"`. **Never** retry or route
    around a 403 — it's an org policy denial.
  * ✅ `git clone` (smart-HTTP), `raw.githubusercontent.com` (so `hardware.inc`
    fetches fine), and `pypi.org` (so `pip install pyboy` → `make test` works).
  * **RGBDS**: `tools/fetch-rgbds.sh` auto-falls back to a `git clone` + source
    build of the pinned tag when the binary download 403s (or force it with
    `RGBDS_FROM_SOURCE=1`). The source build needs `build-essential`, `bison`,
    `libpng-dev`, `pkg-config` — present in the hosted image. So `make` and
    `make test` just work here unattended; only the *first* build eats ~30s
    compiling the toolchain.
  * **Emulator**: `make run` (mGBA) can't fetch its AppImage here and isn't
    usable headless anyway — that's fine, headless tests use PyBoy via pip.
    Interactive checks still need a human on a normal machine.
  * **SameBoy** (`make smoke`/`make sameboy`) is always a source build (no
    Linux release binaries exist), so it works here unattended too — git clone
    + cc + our pinned RGBDS for its boot ROMs, ~a minute on first build.

## Architecture

Modules (all `.asm` under `src/` are separately assembled, then linked — there is
**no runtime cost** to splitting; cross-file symbols are exported with `::`):

| Module | Responsibility |
|--------|----------------|
| `main.asm` | Entry ($0100), boot init, title screen (seed capture), main loop (`wGameMode` dispatch) |
| `title.asm` | CGB full-screen title background loader (`ShowTitle`; both VRAM banks) |
| `title_data.asm` | Title image: palettes + tiles + tile/attr maps (ROMX BANK[3]) |
| `world.asm` | Tile generator, map init, BG streaming (the engine) |
| `player.asm` | Movement, collision, camera, sprite |
| `entity.asm` | Zombie AI + LOS; shared 16-byte entity struct + pool helpers; the dynamic spawn/despawn manager (`UpdateSpawns`) for both pools |
| `npc.asm` | Survivor NPCs: initial spawn, dynamic respawn (`SpawnNPC`), world render, occupancy, A-press talk trigger |
| `talk.asm` | Dialogue screen (MODE_TALK): SCRN1 UI, state machine, VRAM queue |
| `dialogue.asm` | Grammar composer (bounded) + persona/tone affinity math |
| `dialogue_data.asm` | Personas, word banks, templates (ROMX; charmap strings) |
| `anim.asm` | Living-world tile-art animation: water shimmer, tree sway, brush rustle, house-door open/close (shared-tile-art swaps; no map/OAM changes) |
| `hud.asm` | Window-layer status bar (HP/food/energy/clock) + the survival tick |
| `battle.asm` | Placeholder battle transition (flash) |
| `menu.asm` | START pause menu (MODE_MENU): party/equip/bag/status/save/options/exit |
| `items.asm` | Item database (type + name tables) + inventory helpers (party/bag init) |
| `loot.asm` | World loot: dynamic pickup/container pool (reuses the entity struct + spawn manager); biome-flavoured kinds, food-eat + breakable-container interaction |
| `rng.asm` | 16-bit LFSR (`Rand`) — dynamic behaviour, NOT worldgen |
| `video.asm` | VBlank sync, OAM DMA, palettes, font loader, scroll; VBlank IRQ vector |
| `input.asm` | Joypad read with edge detection |
| `audio.asm` | Music seam over vendored hUGEDriver (`InitSound`/`UpdateSound`) |
| `gfx.asm` | Tile + palette data; 1bpp font (expanded to $8800 at boot) |
| `ram.asm` | **All** WRAM/HRAM variables (one place) |
| `util.asm` | 16-bit LE pointer math (`Inc16Ptr`/`Dec16Ptr`/`Add16Ptr`) |
| `include/constants.inc` | Shared `EQU` constants |
| `include/charmap.inc` | ASCII → font-tile `charmap` (dialogue + title strings) |

### Main loop (main.asm)
Logic runs **before** VBlank; VRAM/OAM pushes happen **inside** VBlank:
```
overworld: UpdateSound → ReadInput → UpdateSurvival → UpdatePlayer → UpdateView
           → (GenStrip if moved) → UpdateZombies → UpdateSpawns → UpdateLootSpawns
           → CheckCarToggle → CheckLoot → CheckTreeTouch → CheckTalkStart → UpdateAnim
           → ComputeCamLag → DrawEntities
           WaitVBlank → OAM DMA → SetScroll → PushHUD → BlitStream → PushAnim
talk mode: UpdateSound → ReadInput → UpdateTalk (fills wTalkQ)
           WaitVBlank → OAM DMA → DrainTalkQ
menu mode: UpdateSound → ReadInput → UpdateMenu (input + panel nav, LCD-off
           rebuilds) → WaitVBlank → OAM DMA   (game paused; no clock/world)
```
START in the overworld calls `EnterMenu`; `UpdateSound` is gated on `wOptMusic`
(the OPTIONS music toggle).
`GenStrip` builds the incoming edge into a WRAM buffer (heavy, outside VBlank);
`BlitStream` pushes it to VRAM (tight, inside VBlank) in the **same frame** the
scroll updates — so there's no seam or one-frame latency.

### Zombie encounters (entity.asm `CheckLOS` → `UpdateAlert`, MODE_ALERT)
- **Detection fires when a step *finishes*, not when it starts (Pokemon-style).**
  The player's logical tile (`wPlayerWX/WY`) jumps at the *start* of a step so
  collision/streaming see the destination immediately, but zombie line-of-sight is
  tested against `wSeenWX/WY` — a second copy that catches up only when the step
  **completes** (`SyncSeen` in player.asm, called on the spawn tile and at each
  step's end). So mid-step `wSeen` still names the tile you're leaving, and you
  only trigger an encounter once you've actually arrived on the line tile — not the
  frame you've moved a pixel toward it. This is *which tile LOS compares*, not a
  gate on the LOS call: `CheckLOS` still runs every overworld frame (its cheap
  `SameCol`/`SameRow` early-out skips the occlusion walk unless you're aligned), so
  it isn't a CPU win — mid-step the answer is just stable because `wSeen` is fixed.
- **On detection the zombie charges; everyone else freezes.** `UpdateZombies`
  switches to `MODE_ALERT` and records the spotter (`wAlertZombie`). In alert mode
  the main loop runs **only** `UpdateAlert` — the player, the other zombies, the
  survivors and the spawner all stop (their updaters live in the overworld branch).
  `UpdateAlert` holds the "!" bubble for `ALERT_FRAMES`, then steps the zombie
  straight at the player along its sight line (`EO_FACING`, which LOS already aimed
  at them) at the normal shuffle cadence, animating the slide; when the tile ahead
  is the player's it runs `BattleTransition` (the placeholder flash) and returns to
  the overworld with the zombie removed. `wChaseTimer` (`CHASE_MAX_FRAMES`) is a
  watchdog that forces the battle if the charge ever stalls (an entity parked on the
  terrain-clear line), so alert mode can't soft-lock.
- **`UpdateAlert` lives in a `ROMX BANK[1]` section** ("Alert Code"), not ROM0 —
  the fixed bank is nearly full. It only runs from the overworld loop's alert
  branch, where bank 1 is mapped (`UpdateSound` restores it every frame), and every
  routine it calls is exported ROM0 or ROM0, reachable regardless of the mapped
  ROMX bank. New alert/combat code should go here, not ROM0.

### Dynamic spawning (entity.asm `UpdateSpawns` / npc.asm `SpawnNPC`)
- **Encounters are procedural, not fixed.** `InitZombies`/`InitNPCs` still seed a
  starting cluster near the spawn (deterministic — the boot state the older tests
  assume), but each overworld frame `UpdateSpawns` (called right after
  `UpdateZombies`) **culls** any zombie/survivor whose Chebyshev distance from the
  player exceeds `ENT_CULL_DIST` (frees its pool slot) and, on a throttled timer,
  **respawns** one in a ring at `ENT_SPAWN_DIST` — just outside the visible window —
  when the pool is below its *refill target* (zombies → `ZOMB_SPAWN_TARGET`,
  survivors → `NPC_SPAWN_TARGET`; the `MAX_*` pool sizes stay the hard cap). So the
  world stays populated wherever you go, encounters never repeat when you backtrack,
  and the fixed pools cap count (memory safety).
- **Rarity is tuned by the targets/periods.** Survivors are deliberately rare
  (`NPC_SPAWN_TARGET` small, `NPC_SPAWN_PERIOD` long) because their rewards are big
  and they should be hard to find; zombies refill toward `ZOMB_SPAWN_TARGET` (below
  `MAX_ZOMBIES`) so the overworld isn't wall-to-wall. Lowering a target only changes
  the far-exploration density — near the spawn the boot cluster keeps the pool at or
  above target, so the manager stays inert (no RNG) there and the tests stay
  deterministic.
- **Spawn positions come from the dynamic LFSR (`Rand`), NOT the terrain hash** —
  that's the whole point: the same ground yields a different encounter each visit.
  `PickRingTile` picks one of four sides + a −8..+7 offset (so one axis is always
  `ENT_SPAWN_DIST` out → off-screen, and always `> SIGHT_RANGE` so a fresh spawn
  can never alert the instant it appears), then rejects solid/occupied tiles
  (water is solid, so nothing spawns in it). Respawned survivors get a **random
  persona** and neutral affinity (a stranger you haven't met).
- **The manager only touches `Rand` when it actually spawns.** While a pool is full
  (nothing culled — i.e. you haven't travelled far) it consumes no RNG and
  perturbs nothing, so behaviour near the spawn is byte-identical to before — which
  is why the whole existing suite still passes unchanged. `ENT_CULL_DIST` (15) is
  set above the boot cluster's reach so the starting entities don't cull-then-
  respawn during boot. `InitSpawns` arms the timers; state is in ram.asm's
  "Spawn State" section.

### World loot (loot.asm)
- **Loot objects reuse the entity struct and the entity spawn manager.** `wLoot`
  is a pool of `MAX_LOOT` 16-byte entity structs (the kind lives in `EO_KIND`,
  the `EO_FACING` slot), managed by the exact same `SetPool`/`CullFarPool`/
  `CountActivePool`/`FindFreeSlot`/`PickRingTile` helpers as the zombies/survivors
  (all exported from entity.asm). `UpdateLootSpawns` (right after `UpdateSpawns`)
  culls far loot and respawns toward `LOOT_TARGET` in the ring — same "only
  touches `Rand` when it actually spawns" discipline, so it's inert near spawn.
- **Kinds are biome-flavoured** (`PickLootKind`, from the ring tile's `CalcBiome`,
  via the dynamic RNG not the terrain hash): forest → apples, city → beans,
  everywhere → the odd container (crate/pot common, chest ~1/8). **The module
  lives in ROMX `BANK[1]`** (moved when ROM0 filled up): every entry point —
  boot init, the overworld logic/draw phases, and `UpdateAlert` (itself
  BANK[1]) — runs with bank 1 mapped, and everything it calls is exported
  ROM0. `InitLoot` seeds
  a handful of **food only** near the spawn (containers are solid and would block
  the movement tests' walk paths); a seed slot on a solid tile is skipped, never
  nudged (a far nudge could trip a cull-then-respawn mid-test).
- **Food vs containers.** Apples/beans are **non-solid**: `CheckLoot` auto-grabs
  one on the player's own tile, and food restores hunger straight into `wFood`
  (`AddFood`, saturating). Crates/pots/chests are **solid** — `CheckLootSolidAt`
  is wired into `TryStartStep` (player) and `UpdateZombieAI` (zombies) next to
  `CheckCarAt`, so you (and zombies) can't walk onto them — and are opened by
  `CheckLoot` on an A-press facing them (consumes the press, like `CheckCarToggle`).
  Opening rolls `CrateGear`/`ChestGear` into the bag (`AddItem`) or, for a crate's
  ration pack, straight into the food meter. Loot draws in OAM slots
  `OAM_LOOT`..(+`MAX_LOOT`) via `DrawLoot` (mirrors `DrawNPCs`); its 5 sprite
  tiles (`TILE_LOOT_BASE` 219..223) are appended to `PersonaTiles` after the car,
  sharing existing OBJ palettes (there are no free ones). State is in ram.asm's
  "Loot State" section. **Ammo is intentionally not modelled yet** — it belongs on
  ranged weapons once real combat lands (see docs/design/04 §3).

### Living world (anim.asm)
- **Every effect is a swap of a SHARED background tile's ART in VRAM**
  (`$8000 + id*16`) — never a tile-MAP write and never an OBJ sprite. That's the
  key invariant: the map cell ids are untouched (so the streaming model and the
  boot-hygiene "every map cell ≤ 13" / "OAM slots 33+ hidden" poison tests are
  blind to it), it costs zero OAM budget, and it works identically on DMG (tile
  data is bank-0, no attribute plane involved). Because the art is shared, an
  effect animates **every on-screen instance of that tile at once** — a bumped
  tree reads as a gust through the foliage, and doors/brush are sparse enough
  that the shared-art caveat never shows.
- **Nothing here touches `Rand`** (ambient timers are plain frame counters), so
  spawn/loot/talk determinism — and the whole integration suite — is unperturbed.
- Four effects: **water shimmer** (ambient 3-frame ripple on `TILE_WATER`),
  **tree sway** (`TILE_TREE_TL/TR` wobble, triggered by bumping a tree in
  `player.asm`'s step or an A-press via `CheckTreeTouch`, plus a periodic ambient
  breeze), **brush rustle** (`TILE_BRUSH` ripples when a step commits onto it),
  and **house doors** (`TILE_DOOR` swaps to an open leaf while `wOnDoor`, with a
  short `DOOR_LINGER` so it visibly shuts behind you — reusing the car door SFX
  `PlayCarDoor` on each open/close, as the design asked).
- **Sway/rustle speed is one knob per effect: `TREE_SWAY_LOG` / `BRUSH_RUSTLE_LOG`**
  (constants.inc) — each sub-frame is held `1 << LOG` frames and `*_DUR` is derived
  as `PAT_LEN << LOG`, so raising the LOG slows the motion (currently 4 = 16
  frames/sub-frame, a gentle sway). `TriggerTreeSway`/`TriggerBrushRustle`
  **don't restack an in-progress sway** — otherwise holding a direction INTO a
  tree (or walking a long brush run) re-arms the timer every frame and freezes it
  on sub-frame 0; instead each cycle plays out, then the next held bump starts a
  fresh one → a continuous wobble.
- **The two canopy tiles (`TL|TR`) are one 16×8 image, so a sway frame must shift
  the whole 16-px row as a unit** — the pixel leaving one tile's edge has to enter
  the other's, or a 1-px gap opens at the seam. `F1` = base 1-px right, `F2` = 1-px
  left; `test_anim.py` decodes the canopy and asserts every swaying frame is a
  clean ±1-px shift (this guards the seam-gap regression).
- `UpdateAnim` (logic phase) advances the timers and picks each group's current
  frame; `PushAnim` (VBlank) copies only the 16-byte frames that changed, and is
  **skipped on the single strip-blit frame per step** (captured `wStrKind` before
  `BlitStream`) to keep the DMG VBlank budget — a slow-cycling effect frame being
  ~invisibly late is fine. Frame 0 of each group is byte-identical to the tile's
  base art in `gfx.asm`, so the resting look never shifts. State + timing
  constants live in ram.asm's "Anim State" and constants.inc's "World animation".
- **Interactive feel (sway/rustle/swing) is a human check on mGBA/hardware** —
  `test/integration/test_anim.py` verifies the *logic* (timers fire, VRAM art
  actually swaps) end-to-end, but not how it looks.
- The module lives in **ROMX `BANK[1]`** (ROM0 is full): bank 1 is the
  default-mapped bank and is mapped in every context these routines run, so ROM0
  callers reach it directly with no bank switching (see the banking invariant).

### HUD (hud.asm, docs/design/03 — v0: meters visible + draining, non-lethal)
- The status bar is the **hardware window** over the **bottom 8 px**
  (WY=SCRN_Y-8, WX=7), sourced from **SCRN1 row 0** — free because the talk
  layout starts at row 1. **The window is not a sizable rectangle: it renders
  from (WX,WY) to the screen's bottom-right corner**, so a top bar would cover
  the whole world with SCRN1 (this bug shipped once) — only a bottom band, or
  an LYC raster split, can make a partial-height window.
  Talk mode runs with the window bit off; `BuildTalkScreen` wipes the row and
  `ExitTalkScreen` restores it via `DrawHUDRow` (tiles + `hIsCGB`-gated attrs)
  inside its exit VBlank. Both overworld LCDC writes (main.asm boot,
  ExitTalkScreen) must carry `LCDCF_WINON | LCDCF_WIN9C00`.
- Row layout is exactly 20 cells: `[HP]100 [food]100 [energy]100 HH:MM`, using
  four extra font glyphs (colon, HP ligature, apple, bolt — ids in
  constants.inc). `ComposeHUD` renders into `wHUDText` in the logic phase;
  **`PushHUD` (VBlank) is skipped on any frame that blits a world strip** so
  the DMG budget holds — it must run *before* `BlitStream` eats `wStrKind`.
- Meters are 0..`METER_MAX` (100) **saturating**; drains fire on power-of-2
  in-game-minute boundaries (`FOOD/ENERGY_DRAIN_MINS` — keep them powers of 2,
  the tick masks a minute counter). The clock ticks only in overworld mode
  (`CLOCK_MINUTE_FRAMES` frames/minute); time pauses in talk/alert.
- Sprites render **on top of** the window, so `EntScreenPos` culls any sprite
  with OAM Y >= 145 (its 8-px box would reach the bar). The player never can
  (fixed at screen row 9). Day/night palettes and starvation damage are LATER.
- **Pickup toasts** reuse the row **without pausing**: `ShowNotice` (a charmap'd
  string) / `ShowNoticeItem` (`GOT <name>` from an item id) overwrite `wHUDText`
  and arm `wNoticeTimer` (`NOTICE_FRAMES`). `ComposeHUD` yields while the timer is
  up (so a minute tick can't clobber the message), and `TickNotice` (called from
  `UpdateSurvival` every overworld frame) counts it down and rebuilds the meters
  when it expires. loot.asm fires these on eat/open (`ATE APPLE`, `GOT PISTOL`, …).

### Swimming (player.asm / entity.asm / hud.asm)
- **Water stays solid in `PassTable`** — zombies still avoid it and LOS occlusion
  is unchanged. Only the *player's* `TryStartStep` special-cases `TILE_WATER` as
  the one walkable "solid", so the worldgen model/tests need no change. `wSwimming`
  tracks the player's current tile (set at step-commit from `wDestTile`).
- Crossing the land↔water boundary fires `TriggerSplash`: a short ch4 noise blip
  (`PlaySplash`, audio.asm — borrows the channel from the music for one tick) plus
  the splash sprite at `OAM_SPLASH` (slot 20) for `SWIM_SPLASH_FRAMES`.
- While swimming the player draws single-frame head-and-shoulders tiles
  (`TILE_SWIM_BASE` 53..55, bottom rows transparent so the water shows through),
  energy drains an extra point per in-game minute (`UpdateSurvival`), and
  `CheckLOS` early-returns "unseen" so zombies can't detect you in the water.

### Driving (car.asm / player.asm / hud.asm)
- One car spawns near the start (`InitCar`, offset `CAR_SPAWN_DX/DY`, nudged right
  until the whole footprint is clear via `Is2x2Clear`). It's a **single world
  object** (`wCarWX/WY`, `wCarFacing`), not an entity-pool member, but it
  **physically occupies a 2×2 tile footprint** whose **top-left** is `wCarWX/WY`.
- **Collision is on all four tiles.** `CheckCarAt` returns true for any tile of
  the footprint (`InSpan2` bounds each axis to `{anchor, anchor+1}`); the anchor
  is **always** `wCarWX/WY` — the car is a real world object that stays put when
  parked and moves as a unit while driven (its anchor and the player advance
  together each drive step), so the on-foot player (`TryStartStep`) and zombies
  both treat all four tiles as solid in every state — you **board it, not walk
  onto it**. The one exception is the **driver**: the car can't block its own
  body, so driving movement uses `CheckDriveEdge` (below) instead of `CheckCarAt`.
- **Boarding: you WALK into the car; it does not move to meet you.** `A` while
  facing any car tile *arms* a walk-onto-the-car step (`wCarBoard`, consumed by
  `UpdatePlayer`'s idle path → `StartBoardStep`). That step is a normal on-foot
  walk (camera follows, world streams) that is simply *allowed* to step onto the
  car; `wInCar` flips on only when the walk **finishes** (`player.asm` `.walking`
  completion), which also thuds the door (`PlayCarDoor`) and swaps the HUD. Since
  the flip happens with the player exactly on the car and the camera centred there
  (lag 0), the car transitions from world-locked to camera-locked at the same
  spot — no jump. `A` while driving calls `ExitCar`. `CheckCarToggle` runs in the
  overworld loop *before* `CheckTalkStart` and **consumes the A press**
  (`res 4, wNewKeys`); `CheckTalkStart` also early-returns while `wInCar`.
- **Getting out steps the *player* off; the car stays put** (`ExitCar` — it no
  longer moves `wCarWX/WY`). The player steps to a passable, unoccupied tile
  **outside the footprint** (`TryEjectDir`: facing dir first, then a sweep; it
  rejects tiles still on the car via `CheckCarAt`, so you climb out toward open
  ground; water is solid so you never eject into it; boxed in → you stay on the
  car). The step is **deferred**: `ExitCar` *arms* `wCarEject` (= `EFACE_*+1`);
  `UpdatePlayer`'s idle path consumes it next frame via the normal `TryStartStep`,
  so the walk-out rides the ordinary step + streaming path.
- While driving, the player sits at one footprint tile — their **boarding seat**
  (whichever tile they walked onto). The camera follows the player as always;
  driving advances `wPlayerWX/WY` **and** `wCarWX/WY` in lockstep, so the seat
  offset (`player − car`, each axis 0/1) stays constant.
- While driving: the car is a **16×16 (2×2) sprite** in OAM slots
  `OAM_CAR`..`OAM_CAR+3` (21..24), **camera-locked** (no lag, like the player it
  replaces) with its top-left at `playerCell − seat×8` px, so it sits on its own
  tiles; the on-foot player slot 0 is hidden. Parked, the same 4-slot block sits
  at `wCarWX/WY`'s screen position, culled via `EntScreenPos` like the other
  sprites (the anchor is the top-left, so the car can vanish a tile early at the
  top/left screen edge — cosmetic). `DrawCar` handles both cases and `DrawCar2x2`
  paints the quadrants (TL/TR/BL/BR) at offsets `{0,8}`: down/up are left-right
  symmetric so the right column is the stored left tile with `OAMF_XFLIP`; side
  stores all four quadrants and X-flips the whole 16×16 for left
  (`Car{Down,Up,Right,Left}TA` descriptors).
- **Driving movement checks the footprint's leading edge, not one tile**
  (`CheckDriveEdge`, from the `wCarWX/WY` anchor): the two tiles the 2×2 newly
  covers in the travel direction must both be passable + free of zombie/NPC, so
  the car can't drive its body through a wall (it needs a **2-wide corridor**).
  With the anchor at the top-left, right/down step twice from it and up/left once.
  Steps use `CAR_STEP_SPEED` (2 = **2x** pace); water is **not** walkable (a car
  can't float); each committed tile burns one `wFuel` and recomposes the HUD.
- **Enter/leave plays a door "thunk"** (`PlayCarDoor`, audio.asm) — a low, buzzy
  noise-channel blip, the same music-channel-borrowing trick as the swim
  `PlaySplash`.
- **Fuel replaces energy in the HUD while driving** (`ComposeHUD` branches on
  `wInCar`: `TILE_HUD_FUEL` gas-pump glyph + `wFuel`), and `UpdateSurvival`
  **skips the energy drain** in the car. Empty tank (`wFuel == 0`) → the fuel
  gate in `TryStartStep` blocks movement (you can still turn). Adding the fuel
  glyph bumped `FONT_GLYPHS` 52→53, so `TILE_PSURV_BASE` is now 181 (persona
  world tiles 181..210; the car's **8** tiles `TILE_CAR_BASE` 211..218 — 2 each
  for down/up + 4 for side — are appended to `PersonaTiles`).

### Start menu (menu.asm / items.asm)
- **Pokemon-style pause menu on MODE_MENU.** START in the overworld opens it
  (`EnterMenu`); it lives on **SCRN1** exactly like the talk screen (window HUD
  off, BG9C00, SCX/SCY=0), so the world map on SCRN0 is untouched and `ExitMenu`
  is a cheap LCDC flip + `SetScroll` + `DrawHUDRow` (which restores the row-0 HUD
  the menu overwrote). The game is **paused**: the menu is its own main-loop
  branch, so `UpdateSurvival` never runs and the clock/meters freeze.
- **Panels are rebuilt whole with the LCD off** (`RebuildMenu`: WaitVBlank → LCD
  off → `BuildCurrent` → sprites → DMA → LCD on), same discipline as
  `BuildTalkScreen`. Only the cursor OBJ (slot 0) and the status avatar (slot 1)
  move between rebuilds. Every panel is a full-screen `TILE_PANEL_*` frame +
  header drawn by `BuildBase`/`MClear`; content uses the existing font/panel/bar
  tiles, so **no new gfx**. `RowAddr`/`MPutsDE`/`PutNumDE` are the drawing
  primitives; keep list content clear of the col-19 right border (item names are
  padded to `ITEM_NAME_MAX` = 8 for exactly this).
- **Root list** (`RootLabels`, `wRootCursor`): PARTY EQUIP BAG STATUS SAVE
  OPTIONS EXIT. Submenus use `wMenuCursor` (equip slots / options) or the generic
  scrolling list `wListN/Cur/Top` + `MenuListMove` (BAG, equip picker). B backs
  out; EXIT does `di : jp Start` (a soft-reset to the title — `Start` is exported
  for this).
- **Inventory model (items.asm):** two parallel tables index a plain item id —
  `ItemType` (ITYPE_*) and `ItemNames`. The bag is `BAG_MAX`(20) `{id,count}`
  stacks, **kept compacted** (`AddItem`/`RemoveOneItem`→`CompactBag`) so lists are
  gap-free and BAG's `wListN` is just the leading non-empty run. Party is
  `wPartyEquip` = `MAX_PARTY`×`EQUIP_SLOTS` item ids (2 weapons + armour + charm);
  only member 0 (the player) exists so far, its stats are the global meters.
  Equipping references a bag item (doesn't consume it). The equip picker filters
  the bag by the slot's `EquipSlotType`.
- **STATUS** is **two pages** (LEFT/RIGHT flip `wStatusPage`; A/B exits, entry
  resets to page 0). Page 0 (vitals) shows the player OBJ avatar, LEVEL, EXP and
  NEXT (XP to the next level, or "MAX" at 99), HP/food/energy, the clock, and
  position **relative to the spawn tile** (`wSpawnWX/WY`, recorded in
  `InitPlayer`; magnitude capped at 255 — signed via a leading space/'-' since
  the font has no '+'). Page 1 lists the six **stat points** (`GetStat`); the
  avatar is hidden there so it can't overlap the value column.

### Party levels / experience / stats (items.asm)
- **The party has levels + XP + six stat points** (docs task). Each member (only
  member 0, the player, exists so far) starts at `START_LEVEL` (1) with 0 XP and
  climbs to `MAX_LEVEL` (99). Level/XP live in ram.asm's Party section
  (`wPartyLevel` 1 byte + `wPartyXP` 16-bit each, `MAX_PARTY` wide); PARTY shows
  "LV n" per member, STATUS page 0 the full readout.
- **XP is cumulative and each level costs exponentially more** (`LevelXP`, a
  98-entry `dw` table of the cumulative XP needed to REACH levels 2..99, ~1.06x
  per step from a base of 5, capped to fit 16 bits — max 25078). `RecalcLevel`
  raises member 0's level while its XP meets the next threshold (idempotent; the
  PARTY/STATUS builds call it so a poked/earned XP reflects immediately);
  `AddPlayerXP` (BC, saturating) is the hook combat will call once battles land
  ("this will increase experience points"); `XPToNext` drives the NEXT readout.
- **The six stats derive from the level** (`GetStat` = `StatBase[id] +
  (level-1)*StatGrow[id]`, saturating): STAT_STR (melee power/defence), STAT_DEX
  (ranged power), STAT_END (HP), STAT_IMM (zombie defence), STAT_ACC (hit/crit),
  STAT_SPD (evasion/turn order). Wiring them into combat and mapping Endurance to
  a real max-HP is **LATER** (they're display-only until battles exist).
- **`LevelXP`/`StatBase`/`StatGrow` live in a ROMX BANK[1] section** ("Party
  Data"), the always-mapped default bank the dialogue data uses, because the
  fixed ROM0 bank is nearly full. RecalcLevel/GetStat read them only from the
  overworld/menu (bank 1 mapped), so no bank switch is needed. SAVE persists
  level+XP (save version bumped to 2; the checksum spans them automatically).
- **SAVE** writes a battery-backed block to cart RAM (see the ROM banking
  invariant below) with a magic + 8-bit checksum; **there is no load-on-boot yet**
  (the title still captures a fresh seed) — that's LATER. OPTIONS is a music
  on/off toggle (gates `UpdateSound` + unroutes NR51) with the rest TBC.

### Dialogue (npc/talk/dialogue*, docs/design/05)
- The talk screen lives on **SCRN1** ($9C00) with SCX/SCY=0; the world map on
  SCRN0 is untouched, so exit is just an LCDC flip + `SetScroll`. Entry builds
  the UI with the **LCD off inside VBlank** (never `WaitVBlank` while it's off —
  no IRQ fires) after flushing any half-blitted world strip. Its bank-1
  attribute pass is `hIsCGB`-gated (on DMG those writes would hit the tile map).
- **Font** is 1bpp in `gfx.asm`, expanded at boot to tiles `FONT_BASE` (128+,
  $8800). Dialogue strings are authored via `charmap.inc`, so they assemble
  straight to tile ids; control bytes `CTRL_NOUN`/`CTRL_ADJ` mark grammar slots.
- The composer writes into the 3×18 grid `wTalkText` through a **word buffer +
  greedy wrap** (`FlushWord` is the bounds check — nothing may write past the
  grid; `wTalkGuard` is a tested canary). Slot expansions glue into the current
  token ("THE ",CTRL_NOUN,"." → `BADGE.`), so nouns/adjectives must be
  single words. **`test/model/dialogue_bounds.py` walks the banks in the built
  ROM and proves every composable line fits — run it after ANY data change.**
- All talk-mode VRAM writes go through `wTalkQ` (logic fills ≤16/frame, VBlank
  drains all) — the typewriter reveal, menus and face changes ride this queue.
- **Round rhythm:** every round is NPC *turn* → your reply → NPC reaction,
  and an NPC turn is **2-3 pages**: their sentence (greeting round 1; rounds
  2+ a **prompt** line — `ComposePrompt`, continuation openers + topic), an
  *optional* **observation** page, and always a closing **question** page
  that hands you the menu. The question FOLLOWS UP the observation when one
  fired (`wCtxKind` carries the CTX_* into `ComposeQuestion`, which asks
  from the persona's context-question bank — "SIT DOWN. LET ME SEE THAT."
  → "WHERE DOES IT HURT?"); otherwise it draws from the generic per-persona
  `PO_QUESTS` bank (`wLastQuest` repeat guard). Turn 1 always tries the observation; later
  turns coin-flip it (`wTalkObs`), so turn length is unpredictable. Phases:
  `TPH_GREET/PROMPT → [TPH_OBS] → TPH_QUEST → menu → TPH_REACT`. Reactions
  are a bucket quip plus a **tone tag** answering the specific tone picked
  (`ToneTagsLiked`/`Disliked` by the delta's sign). After `TALK_ROUNDS`
  replies, final affinity picks fight/part/reward.
- **Convincingness tricks** (all data + a few bytes of state):
  * *Subject threading* — each conversation fixes one noun (`wTalkSubject`);
    `CTRL_SUBJ` slots emit it, `CTRL_NOUN` slots stay random (and are guarded
    against repeating), so the NPC audibly talks *about something*.
  * *Trait-tinted adjectives* — `EmitAdj` shifts the mood bank one step
    bleaker/warmer when |T1| ≥ `TINT_THRESH`: the maid grumbles in hostile
    vocabulary at neutral affinity, the preacher beams.
  * *Return greetings* — `EO_MET` (struct offset 15) flips on first talk;
    repeat visits greet from the continuation bank ("STILL HERE?").
  * *State-aware observations, in the persona's voice* —
    `ComposeObservation`/`PickContext` (dialogue.asm) scan LIVE state in
    priority order: low `wHP`/`wFood`/`wEnergy` (< `CTX_LOW_METER`), an
    equipped weapon (`CTRL_ITEM` splices the actual item name from
    `wPartyEquip`), then the `wClockH` time-of-day bucket as a backstop.
    The line itself comes from the TALKING persona's own `PO_CTX` table
    (16 banks: 8 observations + 8 follow-up questions, index CTX_*): the
    raider menaces your pistol ("DROP THE PISTOL AND WALK."), the preacher
    tuts at it ("PUT THE PISTOL AWAY, CHILD.") — and each closes the turn
    with its own follow-up question for that context. `wCtxUsed` (bitmask) stops a context repeating within one
    conversation; if nothing is fresh the turn just skips to the question.
- **Tones:** a pool of `TONE_COUNT` (8) covering every trait axis both ways
  (NICE FLIRT JOKE RUDE GUARDED CHEER GRIM DEMAND). Each menu offers a random
  **4 distinct** of them (`BuildMenu` → `wMenuTones`; picking applies
  `wMenuTones[cursor]`), redrawn until at least one option has a non-negative
  delta for the persona — there is always a playable move. Tests poke
  `wMenuTones[0]` to sidestep menu randomness. Labels are **context-
  sensitive**: `ToneLabelMoods` keys 2 synonyms per tone per current mood
  (soothing a hostile NPC reads EASY, agreeing with a warm one LOVE IT) —
  the mechanical tone is still the `TONE_*` id underneath.
- Affinity is per-NPC (`EO_AFFIN`, 0..255 **saturating**), persists across
  conversations in WRAM; `delta = clamp(dot(tone push, persona traits)>>2, ±16)
  + tone base`. The integration tests hold a lockstep copy of the police
  traits + the 8-tone table — keep `test_talk.py` in sync with
  `dialogue_data.asm`.
- **OBJ palettes are the persona cap for distinct tints:** only palettes 3..7
  are free (player/zombie/bubble own 0-2), so with 10 personas the tints are
  shared via each record's `PO_PAL`. Persona *data* is cheap (~200 bytes each,
  in ROMX); OAM allows `MAX_NPCS` more sprites (slots start at `OAM_NPC0`) —
  mind the 10-sprites-per-scanline hardware limit if raising it further.
- **Portrait art pipeline** (every persona MUST have one — talk.asm has no
  small-sprite fallback): `img/portrait/source/*.png` (112×112 AI art, noisy)
  → `tools/prep-portraits.py` → GBC-exact 56×56 PNGs in `img/portrait/`
  (RGB555, 3 palettes × 4 colours, one palette per 8×8 tile — BG slots 5/6/7)
  → `tools/gen-portraits.py` → `src/portrait_data.asm` (committed). gen
  converts constraint-satisfying images **losslessly** (`exact_portrait`);
  its lossy k-means path is only a fallback for unconstrained art. Rerun both
  tools (in that order) after any art change.

### Title screen (title.asm / title_data.asm, docs/design LATER)
- **CGB** shows a full-screen 160×144 image; **DMG** keeps the classic text
  title (`DrawTitle` — "ZOMB BOY / PRESS START" on the grass backdrop), gated on
  `hIsCGB` in `main.asm` boot. A 20×18 detailed scene barely dedups (~359 unique
  tiles), so it can't fit DMG (256 tiles, one bank, no BG attributes) — that's
  inherent, not a bug.
- **Pipeline:** `img/source/title.png` (1024×1024 AI pixel-art with the text
  baked in) → `tools/gen-title.py` → `src/title_data.asm` (committed) +
  `img/title.png` (what the hardware shows) to eyeball. The tool resizes/crops to 160×144,
  denoises the AI dithering to flat colours, fits **8 BG palettes × 4 colours,
  one palette per 8×8 tile** (the same alternating-refinement solver as
  prep-portraits, `NUM_PALS=8`), then dedups tiles under H/V flip. Each palette
  is sorted lightest..darkest so a flat region hits the same 2bpp index in every
  palette (dedups across palettes; keeps DMG grayscale coherent).
- **The scene spans BOTH VRAM banks:** tile ids 0..255 → bank 0, 256.. → bank 1
  (re-based to 0); the CGB BG attribute byte carries the bank bit (3) plus
  palette (0-2) and X/Y flip (5/6). `gen-title.py` asserts ≤512 tiles and emits
  `TITLE_BANK0/1_BYTES` so the loader needs no assembly-time arithmetic.
- `ShowTitle` (LCD off, at boot) maps BANK[3], loads all 8 BG palettes + both
  tile banks + the tile/attr maps, then restores bank 1. The title owns all of
  VRAM; after START `main.asm` re-runs `LoadTiles`/`LoadFont`/`LoadPalettes` and
  `InitMap` rewrites the whole map, so there's no title cleanup. Rerun
  `gen-title.py` and `make` after any art change.

### The endless-world trick (world.asm)
- World coords are **16-bit signed tile** coordinates (`wPlayerWX/WY`).
- The 32×32 BG map is a **circular buffer**: world tile `(X,Y)` always lives in
  cell `(X & 31, Y & 31)`. `SCX/SCY = (view & 31) * 8`.
- Moving one tile only invalidates the **single incoming column/row**, so we
  regenerate just that edge — this is what makes the world endless. Every visible
  cell is always current; off-screen margin cells may be stale but aren't shown.
- **`Hash8` is a permutation-table value-noise hash** (256-byte `PermTable`,
  page-aligned so an index is just `ld l,a`). Seeded by `(hWorldSeed + salt)`;
  callers put the coord-transformed inputs in `wHX/wHY` and pass a salt in `B`.
  It replaced an ad-hoc add/xor/swap hash that produced **diagonal streaks**.
- **The seed is per-playthrough, captured on the title screen** (`Start` in
  main.asm): the world generates only after START, and `hWorldSeed` = the
  press-frame counter ^ `rDIV` — human timing is the only entropy source on a
  cartridge (DIV *at boot* is deterministic, don't seed there). **SELECT+START
  forces the classic `WORLD_SEED` ($A5)** — that's how the harness and the
  reference model's default stay reproducible. The seed is one byte, so
  `worldgen_model.py` sweeps **all 256 possible worlds** (spawn passable,
  spawn area walkable, biomes vary) on every run; `--seed N` runs the full
  statistics at one seed.
- **`GenTileType` is biome-driven.** A coarse, domain-warped `CalcBiome` field
  (~64-tile cells) slices the 0..255 noise value into **11 biomes** — city,
  plains, forest, marsh, plus ruins, farm, jungle, graveyard, desert, mountains,
  tundra (each `BIOME_*`; the threshold cascade must stay in lockstep with
  `worldgen_model.py:biome()`). Each biome has its own `Gen*` routine assembling
  features from shared noise fields (`WaterField`, `TreeQuad`, `ScatterHash`), so
  water clusters in marsh, straight roads+houses in city, trees in forest,
  cactus in desert, cracked roads+rubble in ruins, fenced wheat fields in farm,
  headstones+a church in graveyard, etc. **City streets (`RoadHere`):** vertical
  **avenues** are full-length straight lines (one per 16-wide band, column
  jittered 0..7 by the band index alone) — the connected backbone. Horizontal
  **cross-streets JOG**: a street's row is jittered per avenue-*interval*, so it
  steps up/down each time it crosses an avenue → bends and T-junctions. The jog
  lands exactly ON an avenue and the full-length avenue bridges the two
  different-row segments, so every street segment has both ends on an avenue and
  the whole network stays connected (verified 100% within a city by flood fill;
  a straight-only grid was the earlier, blander version). Avenue spacing varies
  9..23 tiles too, so blocks are irregular in both axes.
  **A city building yields to any avenue/street that runs through it**
  (`GenTileType` checks `RoadHere` before letting a house stand) so streets stay
  whole; a graveyard church always stands (no roads there). Ruins reuse the same
  street network and crack it.
  The **band order is deliberate**: forest sits just below the marsh band so the
  classic seed ($A5, field value 195) keeps its forest spawn (the reproducible
  test world), and marsh keeps the wet top end so its water still dominates the
  world's water (the model's clustering check). New biomes add **no water** (dry
  ground or, for tundra, solid ICE via the water field) so marsh stays dominant.
  Trees are **2×2** (a `TreeQuad` anchor + per-cell quadrant tile); houses are one
  optional building per 16×16 chunk (`HouseTile`: wall perimeter + floor + door),
  gated on city **or graveyard** (a church), and are cut by any street that
  crosses them (roads win — see above). Domain-warped 2-octave water gives
  organic ponds.
- **New-biome BG terrain tiles live at ids 57..63** (sand, cactus, snow, ice,
  grave, wheat, fence) — appended to the `Tiles` table (gfx.asm) after the splash
  sprite so `LoadTiles` streams them into the free VRAM gap between the UI tiles
  (..56) and portraits (64+). `PassTable`/`AttrTable` (world.asm) are indexed by
  tile id and carry entries for them (ids 14..56 are filler — OBJ/UI tiles never
  appear as a BG map cell). They reuse existing BG palettes 0..3, so they're
  DMG-safe. The `> 13` BG-tile poison checks (`test_boot_hygiene`, `test_dmg`)
  allow `57..63` too. **The mountains ledge-jump, slippery ice, and farm animals
  are intentionally deferred** (they need new movement/collision semantics or OBJ
  budget, not just terrain) — see docs; the biomes themselves are complete.
- **Multi-tile features are decided from a consistent anchor so they never clip:**
  the terrain biome is sampled at the **2×2 block** anchor (`wGen & $FFFE`) so a
  tree's four quadrants always agree, and houses gate on the **16×16 chunk** anchor
  (`wGen & $FFF0`) so a whole building shares one biome. Trees are placed **before**
  water so a pond can't bite a quadrant out of a tree. If you add a multi-tile
  feature, anchor its decision the same way (and floor the biome sample to match).
- **`CalcBiome` is memoized** (1-entry cache, `wBioCache*` in ram.asm): biome is
  pure in (anchor, seed) and consecutive tiles share block/chunk anchors, so
  ~half of all biome computations during streaming are cache hits. The cache is
  valid because the seed can only change across a boot and `ClearRAM` zeroes
  `wBioCacheOK`; if you ever make `hWorldSeed` changeable mid-run (e.g. load-on-
  boot into a running game), clear `wBioCacheOK` at that point too.
- **The generator is CPU-heavy** (~2 biome samples + several field hashes/tile).
  That's why boot (`InitMap`, 1024 tiles) and per-step `GenStrip` run under **CGB
  double-speed** (enabled in `Start`, *gated on running on CGB*). Double-speed also
  lets `BLIT_CHUNK` push a whole strip in one VBlank. If you add per-tile work,
  watch boot time (the harness allows `settle=150` frames after its title
  START-press for `InitMap` + spawns — keep well under that; on DMG there's no
  double-speed so it's ~2x slower). The harness presses **SELECT+START through
  the title** (classic seed) at `press_frame=90` (PyBoy's boot-ROM logo runs
  until frame ~64, so the title only exists from ~73) and re-seeds the
  reference model from the ROM's actual `hWorldSeed` so tilemap comparisons
  hold at any seed (`Game(seed="random", press_frame=N)` boots a random world;
  see `test_seed.py`).

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
- Song data is `ROMX` in its **own bank** (it outgrew bank 1 when the
  dialogue data grew): `InitSound`/`UpdateSound` bracket every driver call
  with a switch to `BANK(song_demo)` and a restore of bank 1, per the ROM
  banking invariant below. `test/integration/test_audio.py` asserts the
  driver's WRAM tempo/order-count match the song and that the row cursor
  advances — the headless canary for a broken bank seam (or driver/tracker
  format drift, which fails the same way).
- To swap the tune: export from hUGETracker as "RGBDS .asm", drop it in
  `vendor/hUGEDriver/songs/` keeping the `song_demo::` descriptor label.

## Conventions & invariants (don't break these)

- **The cart is 128 KB MBC5 with 8 KB battery RAM (`-m 0x1B -r 0x02` in
  `FIXFLAGS`); ROMX bank 1 is the default-mapped bank.** Bank 1 holds the
  dialogue data + code (read throughout talk mode) and — now that ROM0 is full —
  the `anim.asm` living-world code and the whole of `loot.asm` (`BANK[1]`, run
  from the always-mapped bank so they need no switching, exactly like
  `dialogue.asm`); boot maps bank 1
  explicitly (don't trust MBC power-on state). Portraits are `BANK[2]`, mapped **only** inside
  `ShowPortrait` (talk.asm); the song data floats in its own bank, mapped
  **only** inside `InitSound`/`UpdateSound` (audio.asm) via `BANK(song_demo)`.
  The **graphics data** (`gfx.asm` `GfxData`: tiles/font/palettes) is `BANK[3]`
  too (shared with the boot-only title image), read **only** by
  `LoadTiles`/`LoadFont`/`LoadPalettes` (video.asm), each of which maps
  `BANK(Tiles)` and restores bank 1 — this is what keeps ROM0 (the fixed 16 KB
  code bank) from overflowing, so keep boot-loaded data out of ROM0.
  Both restore bank 1 before returning. New banked data must do the same:
  switch, read, restore bank 1 — nothing else may assume another bank. **Cart RAM (`SECTION ... , SRAM`, the menu's SAVE block) is
  disabled by default; `DoSave` brackets every access with the `rRAMG` enable /
  disable writes** (and `rRAMB`=0) — never leave it enabled.
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
- **Dual-mode: colour on CGB, grayscale on DMG.** The cart is CGB-*compatible*
  (`-c`/`$80`, not CGB-only), so it also runs on an original Game Boy. `Start`
  probes `rVBK` to set `hIsCGB` (1=CGB, 0=DMG; in HRAM so `ClearRAM` can't wipe
  it). **Every CGB-only operation must be gated on `hIsCGB`:** double-speed (the
  `stop` would hang a DMG) and the bank-1 attribute writes (on DMG `rVBK` is
  ignored, so an attribute write lands on the tile id in bank 0 and corrupts the
  map). DMG uses the classic `rBGP`/`rOBP0`/`rOBP1` palettes (set in
  `LoadPalettes`; without them sprites are solid black). Per-tile BG colour is a
  CGB-only feature, so DMG is single-palette 4-shade grayscale — that's inherent.
  PyBoy can't emulate DMG mode for a CGB-flagged ROM, so the harness forces CGB;
  `test/integration/test_dmg.py` patches the detection to exercise the DMG code
  path (no hang, BG uncorrupted, palettes set). True grayscale look = verify on
  mGBA/hardware.
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
- **Use the shared helpers, don't re-inline them:** `GenSolid` (world.asm) for
  the generate-then-passability test on wGenX/wGenY, `GenFromPlayer::`
  (entity.asm) to seed wGen from the player's tile. Both are exported ROM0, so
  they're callable from any bank.

## Adding things

- **A new BG tile type:** add its `TILE_*` id in `constants.inc`, its 8×8 art in
  `gfx.asm` (at the matching tile index), a `PassTable` entry (solid?) and an
  `AttrTable` entry (palette) in `world.asm`, and a branch in `GenTileType`.
  Update the reference model + rerun it.
- **A new module:** create `src/<name>.asm` (the Makefile globs `src/**/*.asm`),
  `INCLUDE` what it needs, export its public routines with `::`. Put any new RAM
  in `ram.asm`, not scattered.
- **A new persona:** data + art. In `dialogue_data.asm` add a `PersonaTable`
  record (name, 4 traits in -60..+60, noun + topic + **question** banks +
  a **`PO_CTX` context table** — 16 in-voice banks indexed by `CTX_*`
  (8 observations, then 8 follow-up questions ending in `?`), every
  `CTX_WEAPON` observation carrying `CTRL_ITEM`; `PO_PAL` — pick any
  OBJ palette 3..7, shared tints are fine; the record is
  `PERSONA_SIZE` = 16 bytes, question bank at `PO_QUESTS`, questions must end
  in `?`), bump `PERSONA_COUNT`/`MAX_NPCS` +
  a spawn offset in `npc.asm`. Art is **mandatory** (no fallbacks): a 112×112
  source in `img/portrait/source/` run through the portrait pipeline (see the
  dialogue section) + a `PERSONA_ART` entry, and 3 world-sprite tiles
  (down/up/side) appended to `PersonaTiles` in `gfx.asm` — order must match
  the persona id (tile = `TILE_PSURV_BASE` + persona*3 + dir; ids grow past
  209 toward the 255 ceiling). Then `make && python3
  test/model/dialogue_bounds.py` — it enforces the authoring rules
  (single-word nouns, every line fits 3×18, |dot| ≤ 127, palette range,
  label length) **including winnability**: some tone's delta must be ≥ +7 so
  three perfect replies reach `AFFIN_REWARD`.
- **A new reply tone:** add a `ToneTable` record (push vector + base) and a
  synonym bank of ≤7-char labels under **each of the three moods** in
  `ToneLabelMoods` (`dialogue_data.asm`), bump `TONE_COUNT` — but keep it a
  **power of 2** (`BuildMenu` masks `Rand`), and rerun the bounds model
  (winnability shifts for every persona).
- **New dialogue text:** only charmap'd characters (`A-Z 0-9 . , ! ? ' -`);
  hyphenate multi-word nouns; in topics use `CTRL_SUBJ` for the continuity
  slot (~half the templates) and `CTRL_NOUN` for variety; rerun the bounds
  model.

## Watch out for

- **VBlank budget.** `BlitStream` pushes a whole strip (up to a 20-tile row × 2
  passes, `BLIT_CHUNK = 20`) plus OAM DMA in one VBlank. We now run in **GBC
  double-speed** (see the world-gen notes), which doubles the VBlank cycle budget,
  so the full-strip blit fits comfortably. PyBoy won't reproduce VBlank-overrun
  tearing — if you add per-frame VRAM work, sanity-check the budget by hand /
  `make run`. If it ever overruns, lower `BLIT_CHUNK` to re-chunk across VBlanks.
- **`ld a, b : or c` clear loops** rely on the byte count being < 256 (high byte
  stays 0). Fine for the current buffers; re-check if a cleared region grows.
- Commit messages: **do not** add Claude as an author/co-author (user's global
  rule). Branch off before committing on a default branch; only commit/push when
  asked.
- **Versioning: minor bumps are the user's call.** Never bump the minor version
  (v0.5 → v0.6) or tag a new minor release without asking first — the roadmap
  buckets in README.md say what each minor means, and the user decides when a
  version is "done". Patch/hotfix bumps (v0.5.0 → v0.5.1) are fine without
  asking. When cutting any release tag, bump the cart header's mask-ROM version
  byte to match (`rgbfix -n` in the Makefile's `FIXFLAGS`) — a real cartridge
  revision did the same.
