# Zomb Boy — Design Docs

A monster-battler-style Game Boy **Color** game where the "creatures" are zombies and the
world is an endless, procedurally-generated survival landscape.

This directory is the single source of truth for *what* we're building and *why*.
Implementation lives in [`../../src/`](../../src/); these docs are written to be
readable before a single line of assembly exists.

## The pitch

You are a survivor in an endless, procedurally-generated post-apocalyptic world.
You explore (the world generates as you walk, Minecraft-style, and remembers your
changes), you manage **food and sleep** to stay alive, you **fight zombies** in
monster-battler-style encounters using **two equipped weapons and two special skills**,
and you meet **other survivors** who talk to you in procedurally-generated
sentences — befriend them for gifts, or fight them if it goes badly.

## Design pillars

1. **Endless but bounded-memory.** The world feels infinite; the *save* is finite.
   We lean on deterministic generation so we only ever store *changes*, not terrain.
   (See [01 — Technical Feasibility](01-technical-feasibility.md) for how, and
   whether it's possible on GBC. Short answer: yes.)
2. **Survival pressure.** Food and sleep meters create a reason to keep moving,
   scavenging, and taking risks. (See [03 — Survival](03-survival.md).)
3. **Legible combat.** Two weapons + two skills, monster-battler-legible turn structure,
   readable on a 160×144 screen. (See [04 — Combat](04-combat-weapons-skills.md).)
4. **People are systems, not scripts.** Survivors are generated: a compatibility
   model plus a grammar generator make each conversation feel authored without
   authoring each one. (See [05 — Survivors & Social](05-survivors-social.md).)
5. **Memory-safe by construction.** Assembly means raw memory access. Every
   subsystem ships with tests that prove it stays in its lane.
   (See [06 — Testing & Memory Safety](06-testing-and-memory-safety.md).)

## Document index

| # | Doc | Covers |
|---|-----|--------|
| 00 | This README | Pitch, pillars, scope |
| 01 | [Technical Feasibility](01-technical-feasibility.md) | GBC hardware limits, memory map, and the answer to "can the world remember itself?" |
| 02 | [World & Exploration](02-world-and-exploration.md) | Chunks, deterministic generation, persistence, edge barriers |
| 03 | [Survival](03-survival.md) | Food, sleep, day/night, death |
| 04 | [Combat, Weapons & Skills](04-combat-weapons-skills.md) | Turn structure, the 2+2 loadout, zombie types |
| 05 | [Survivors & Social](05-survivors-social.md) | Compatibility model, grammar generator, dialogue choices |
| 06 | [Testing & Memory Safety](06-testing-and-memory-safety.md) | How we prove the assembly is correct and safe |

## Scope discipline

To ship *anything*, we build in vertical slices. The **v0 slice** (walk around a
generated world, get spotted by one basic zombie, win/lose a fight) is defined at
the end of [02](02-world-and-exploration.md). Everything else — survivor trading,
party members, more zombie types — is explicitly deferred and marked **LATER** in
the docs so we don't gold-plate before the core loop is fun.
