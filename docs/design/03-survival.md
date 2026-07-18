# 03 — Survival: Food & Sleep

The survival meters are the *reason* to keep exploring and taking risks. They must
create pressure without becoming tedious babysitting.

---

## 1. The two meters

Each is a single byte `0–255`, shown as a small gauge in the HUD.

| Meter | Drains when… | Refilled by… | At zero… |
|-------|--------------|--------------|----------|
| **Food** | Time passes (every in-game tick), faster when fighting/running | Eating items found while scavenging | Health drains steadily (starving) |
| **Sleep** | Time passes; drains only while awake | Sleeping at a safe spot / bed / campfire | Stats debuff (weaker attacks, worse aim/accuracy), then forced collapse |

Design intent:
- **Food** is the *spatial* pressure — it pushes you to keep moving and scavenging
  new chunks (which is where zombies and survivors are). Standing still starves you.
- **Sleep** is the *risk/tempo* pressure — sleeping refills it but **advances time
  and is dangerous in the open** (see §3). It forces a "find somewhere safe"
  decision loop.

## 2. Time & day/night

- The world runs an in-game clock (independent of real time). A **day** is a fixed
  number of ticks.
- **Night** raises zombie spawn rates / aggression and shrinks visibility (a
  lighting palette shift — cheap on GBC via palette swaps, no new art). This makes
  the sleep decision spicy: sleep through the dangerous night, but only if you're
  somewhere safe.
- Sleeping fast-forwards time to morning (or a set duration).

## 3. Sleeping mechanics

- You can attempt to sleep anywhere, but **safety depends on location**:
  - Safe spot (cleared building, bed you've found): full refill, no risk.
  - Open ground: refills, but a chance of a **night ambush** — you may wake up
    already in a battle. High risk, sometimes necessary.
- Sleeping is also the natural **save point** ([02 §4](02-world-and-exploration.md#4-persistence-diffs--the-save-format)),
  reinforcing "make it to safety" as a satisfying beat.

## 4. Death & consequences

When health hits zero (from starvation, a lost battle, or an ambush):

- **v0:** respawn at last safe sleep spot; keep world diffs, drop some carried loot
  where you fell (recoverable — a soft penalty, not a wipe). This keeps the endless
  world persistent through death.
- **LATER options** (pick during tuning, not now): permadeath mode; a "wake up
  injured elsewhere" mechanic; losing a party member instead of yourself.

We deliberately avoid a hard wipe by default because the whole point is a persistent
world you're invested in.

## 5. Balancing knobs (all data, all testable)

Every rate is a named constant in a data table, so tuning is a data edit, not a code
change — and each is covered by a test asserting the meter math never under/overflows:

- `FOOD_DRAIN_PER_TICK`, `FOOD_DRAIN_COMBAT_MULT`
- `SLEEP_DRAIN_PER_TICK`
- `STARVE_HP_DRAIN`, `SLEEP_DEBUFF_THRESHOLDS`
- `DAY_LENGTH_TICKS`, `NIGHT_SPAWN_MULT`
- `AMBUSH_CHANCE_OPEN_GROUND`

**Memory-safety note:** meter updates are saturating (clamp to `0..255`), never
wrapping. A test feeds extreme inputs (drain a 0 meter, refill a 255 meter) and
asserts no wrap-around — a classic 8-bit bug we refuse to ship.

## 6. Not in v0

Food/sleep pressure is a **later slice** than the core walk-fight loop. v0 can have
the meters present but non-lethal (visible, draining, but not yet ending runs) so we
can feel the pacing before we let them kill the player.
