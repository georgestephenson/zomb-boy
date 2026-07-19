# 05 — Survivors & Social

Instead of every human being a fight, some are **survivors** — a relationship
minigame with a compatibility model and a procedural dialogue generator. Befriend
them for gifts (LATER: trading, party members); annoy them and it becomes a fight.

This is the most "generated" system in the game: we author *rules and word banks*,
not conversations.

---

## 1. Encountering a survivor

When you meet a survivor (random encounter while exploring, like a wild encounter
but peaceful by default), we generate them deterministically from a hash of their
spawn coordinates + world seed, so the *same* survivor is the same person if you
return. A generated survivor has:

- A **personality vector** (a few signed bytes, see §2).
- A small **appearance** (palette + sprite variant).
- A stable **id** so their affinity persists in the relationship table
  ([02 §4](02-world-and-exploration.md#4-persistence-diffs--the-save-format)).

## 2. Compatibility model

Keep it small and legible. The player has an (implicit) personality too, nudged by
choices. Each personality is a vector over a handful of **traits**, e.g.:

```
traits = { WARY <-> TRUSTING,
           GRIM  <-> HOPEFUL,
           SELFISH <-> GENEROUS,
           JOKING <-> SERIOUS }
```

Each trait is a signed value (e.g. `-64..+63`). **Compatibility** between the player
and a survivor is a cheap distance/dot-product:

```
affinityDelta = Σ  agreement(playerTrait_i, survivorTrait_i)
```

- Your **dialogue choices** (§4) express traits. Choosing the "joking" reply when
  they're `SERIOUS` costs affinity; matching their vibe gains it.
- Running **affinity** per known survivor is stored `0..255` (start neutral). Cross
  a high threshold → they **like** you (gift / LATER join/trade). Cross a low
  threshold → they turn **hostile** → a battle ([04](04-combat-weapons-skills.md)),
  or you can pick a fight yourself at any time.

All of this is integer math over tiny vectors — nothing here strains the CPU.

## 3. Grammar generator (procedural sentences)

Survivors "talk in randomly generated sentences." We use a **template + word-bank
grammar** (a tiny context-free grammar), which is compact and completely
deterministic given a seed:

```
GREETING   := OPENER ", " TOPIC "."
OPENER     := "Hey" | "Careful out there" | "Didn't expect to see anyone" | ...
TOPIC      := "you seen any " THREAT " around?" | MOOD | ASK_TRADE | ...
THREAT     := "runners" | "the dead" | "raiders" | ...
MOOD       := "I'm about done with " HARDSHIP
HARDSHIP   := "the cold" | "being hungry" | "the quiet" | ...
```

- Each `:=` alternative list is a **word bank** in ROM. Expanding a rule is:
  pick an index from the bank via the survivor's RNG stream, recurse. A few hundred
  bytes of tables yields thousands of distinct lines.
- **Personality-weighting:** a `GRIM` survivor draws from bleak banks; a `HOPEFUL`
  one from warmer banks. Same grammar, different weights → the *voice* matches the
  personality vector for free.
- Text is assembled into a **bounded scratch buffer** (fixed max length; the
  generator hard-stops at the buffer limit — tested, no overrun). This is a prime
  memory-safety target: string building in assembly is exactly where buffer
  overflows hide.

## 4. Your responses (four context-sensitive choices)

Each time it's your turn to reply, the game offers **four** options, generated to be
*context-sensitive* to what they just said and tagged with the trait they express:

| Slot | Flavor | Trait pushed |
|------|--------|--------------|
| A | Warm / agree | +TRUSTING / +HOPEFUL |
| B | Guarded / deflect | +WARY / +SERIOUS |
| C | Joke / lighten | +JOKING |
| D | Blunt / self-interested | +SELFISH / provoke |

- The *wording* of each choice is itself grammar-generated to fit the current topic,
  so replies feel responsive without a hand-written dialogue tree.
- Picking a reply applies its trait push → recomputes `affinityDelta` → nudges the
  running affinity. Conversation continues for a few exchanges, then resolves:
  **gift**, **neutral parting**, or **fight**, based on where affinity landed.

## 5. Outcomes

- **Like:** they give a **gift** (item/ammo/food). *LATER:* open a **trade** UI, or
  offer to **join your party** as a combat ally.
- **Neutral:** part ways; affinity remembered for next time.
- **Dislike/Hostile:** battle. A survivor uses the same combat system as zombies but
  with weapons/skills, making them tougher, more interesting fights.

## 6. Scope

- **v0:** survivors are **not** in the first slice at all — the core loop is
  walk/generate/fight-a-zombie ([02 §6](02-world-and-exploration.md#6-v0-vertical-slice-the-first-thing-we-build)).
- **First social slice:** compatibility + grammar + 4 choices + gift/fight outcome.
- **LATER:** trading, party members, survivors turning into (infected) zombies,
  reputation across a settlement.

### Status (v0.4): first social slice BUILT

`npc.asm` / `talk.asm` / `dialogue.asm` / `dialogue_data.asm` implement this
doc with one authoring twist: survivors ship as **named persona presets** —
ten of them (policeman, scientist, cheerleader, maid, businessman, prepper,
medic, raider, preacher, farmer) — each a preset trait vector (§2) plus themed
noun/topic banks (§3), which keeps voices loud and data legible. Persona data
is ~200 bytes; the practical cap on *distinct looks* is the five free OBJ
palettes (tints are shared beyond that).

The §4 reply slots draw from an **eight-tone pool** covering every trait axis
in both directions (NICE, FLIRT, JOKE, RUDE, GUARDED, CHEER, GRIM, DEMAND);
each menu deals a random four with at least one non-punishing option
guaranteed. The §4 *context-sensitive wording* ships as **mood-keyed label
synonyms**: each tone's menu label is drawn from a bank keyed by the NPC's
current mood (soothing a hostile NPC reads EASY; agreeing with a warm one
reads LOVE IT — same mechanical tone, phrased for the moment). A conversation
runs greeting + **3 rounds** of *their turn → your reply → their reaction*,
where an NPC **turn is itself 2-3 pages**: their sentence, sometimes an
**observation**, and always a closing **question** that hands you the menu
(rounds 2+ open with a fresh generated prompt line) + resolution by affinity
thresholds (§5).

The generator earns its "convincing" with cheap tricks: each conversation
fixes a **subject noun** the templates keep returning to; reactions append a
**tone tag** that answers the specific reply picked ("WISE." vs "SO TENSE.");
the §3 personality-weighting ships as **trait-tinted adjective banks** (grim
personas draw bleaker words at equal affinity); NPCs **remember meeting
you** — return visits skip the stranger hello and pick the thread back up;
and observations read **live game state** — low HP/food/energy, the in-game
clock's time of day, even the name of your equipped weapon spliced from the
inventory — **in the speaking persona's own voice** (each persona carries its
own 8 context banks: the raider menaces your pistol with "DROP THE PISTOL AND
WALK.", the preacher tuts "PUT THE PISTOL AWAY, CHILD.", the medic wants it
off the cots) — with a per-conversation used-mask so the same remark never
fires twice in one talk. When an observation fires, the turn's closing
question **follows the same thread** from a matching per-persona bank — the
medic who just said "SIT DOWN. LET ME SEE THAT." asks "WHERE DOES IT HURT?",
the farmer who noticed you starving offers "COULD YOU EAT A BAKED SPUD?" —
so the two-page beat reads as one continuous thought.

Still placeholder: the **gift** hands over no item yet (no inventory), and
**hostile** plays the battle-flash stand-in — both resolve and announce
correctly, ready to wire up. Random encounters, procedural spawning across the
world, the persistent relationship table (needs the save system) and the
player's own drifting personality vector are also still LATER. The §3 bounded-
buffer requirement is enforced by `test/model/dialogue_bounds.py` against the
built ROM plus a runtime canary tested in `test_talk.py`.
