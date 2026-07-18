# 04 — Combat, Weapons & Skills

Classic monster-battler-legible, turn-based encounters against zombies (and hostile survivors).

---

## 1. Getting into a fight: line of sight

Zombies are the "trainers." Each zombie has:
- A **position** and **facing** on the overworld grid.
- A **sight cone**: N tiles straight ahead (v0: a straight line; LATER: a small
  cone/peripheral). Line-of-sight is blocked by walls/obstacles.

Each tick, awake zombies check whether the player is within the unobstructed sight
line. If spotted → a short "alert" beat → the encounter begins. This mirrors
classic monster-battler trainer aggro and is fully deterministic/testable ("player at these tiles is
seen; behind this wall is not").

Zombies may also **wander** (deterministic patrol from their spawn hash) so the
overworld feels alive without per-zombie AI cost.

## 2. Turn structure

A minimal, readable turn loop on the 160×144 screen:

```
[ Your turn ]
  Choose: Weapon 1 | Weapon 2 | Skill 1 | Skill 2 | Item | Flee
[ Resolve player action ]
[ Enemy turn ]  -> enemy picks an action (simple weighted AI in v0)
[ Resolve enemy action ]
[ Check win/lose/flee ]  -> repeat
```

- **Win:** enemy HP ≤ 0 → rewards (loot, maybe XP LATER), and a **diff** records
  that zombie as dead so it doesn't respawn ([02 §4](02-world-and-exploration.md#4-persistence-diffs--the-save-format)).
- **Lose:** player HP ≤ 0 → death handling ([03 §4](03-survival.md#4-death--consequences)).
- **Flee:** chance-based; on success return to overworld (zombie may remain).

## 3. The loadout: two weapons + two skills

This is the core "build" expression, echoing the classic four-move slots but split
into two categories.

### Weapons (2 equipped)
Physical options with distinct **trade-offs**, not just numbers:

| Axis | Example weapons |
|------|-----------------|
| Fast/weak vs slow/strong | Knife (fast, low dmg, high accuracy) vs Bat (slow, high dmg) |
| Melee vs ranged | Pipe (melee, no ammo) vs Pistol (ranged, **uses ammo**) |
| Reliable vs risky | Revolver (steady) vs Shotgun (big dmg, can miss) |

Weapons have: damage, accuracy, speed/priority, and optionally **ammo** (a resource
tying combat back into scavenging/survival).

### Skills (2 equipped)
Non-weapon abilities on a **cooldown or charge** (so they're not spammable):

- **Offensive:** Adrenaline (extra turn), Molotov (damage-over-time / hits groups
  LATER), Aimed Shot (guaranteed hit).
- **Defensive/utility:** Bandage (heal), Distract (raise flee chance / skip enemy
  turn), Scavenge (chance to grab an item mid-fight).

You carry more weapons/skills in inventory but only **2 + 2 are equipped** at once —
swapping is a between-fights decision (a real choice, like a monster's moveset).

## 4. Stats (kept small on purpose)

Per combatant, all bytes:
- `HP` / `maxHP`
- `ATK` (scales weapon damage), `DEF` (reduces incoming)
- `SPD` (turn order / flee)
- Optional status flags: `bleeding`, `stunned`, `infected` (LATER)

Damage formula is a simple, saturating integer expression (documented and
unit-tested for no overflow, no negative wrap):

```
dmg = clamp( weaponDmg + ATK/const - target.DEF/const , 1 , 255 )   ; min 1
```

## 5. Zombie types

**v0: one "Basic Zombie"** — slow, melee, low HP. That's it. Prove the loop.

**LATER (add incrementally, each is just a data row + maybe one behavior flag):**
- Runner (high SPD, low HP) — punishes slow weapons.
- Brute (high HP/DEF) — rewards strong/ranged.
- Spitter (ranged) — forces defensive skills.
- Screamer (calls more zombies) — a "handle it fast" threat.
- Infected survivor (bridges to the social system — a survivor who turned).

Because a zombie is a **data row** (stats + a small behavior enum), adding types is
low-risk and doesn't touch the combat engine — exactly the "expand as we go" the
brief asked for.

## 6. Memory-safety notes

- Combat state lives in a **dedicated scratch region** allocated only during battle
  ([01 §6](01-technical-feasibility.md#6-wram-budget-the-ram-that-matters-frame-to-frame)),
  and is fully cleared on entry so no stale data from a previous fight leaks in
  (tested).
- All stat math saturates; equip slots are bounds-checked (you cannot equip into a
  3rd weapon slot — tested against out-of-range indices).
