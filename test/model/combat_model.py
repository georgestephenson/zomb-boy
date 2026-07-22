#!/usr/bin/env python3
"""Host-side reference model of the combat math (src/battle.asm + battle_data.asm).

Mirrors the pure, testable parts of the battle engine — the damage formula, the
crosshair zone mapping, and saturating HP — so we can prove the invariants the
design calls out (docs/design/04 §4/§6) without an emulator:

  * damage saturates: never < 1 on a landed hit, never > 255, never wraps.
  * the red/amber/green target bar's zones line up with the tiles drawn on
    screen (ZoneBarTiles in battle.asm) — a lock in cell N does what cell N looks
    like it does.
  * a fight actually terminates (HP monotonically falls to 0).

Keep in lockstep with battle.asm / battle_data.asm — change both together. The
crosshair *timing feel* is interactive and human-verified (no headless input);
only the position->outcome mapping is modelled here.
"""

# --- constants (constants.inc) ----------------------------------------------
DMG_SHIFT = 2
PLAYER_ATK = 12
PLAYER_DEF = 6
CROSS_CENTRE = 64
CROSS_MAX = 127
GREEN_HALF = 8
AMBER_HALF = 40
ZONE_MISS, ZONE_HIT, ZONE_CRIT = 0, 1, 2
ZONE_COL0, ZONE_CELLS = 2, 16   # bar geometry on SCRN1 (cols 2..17)

# --- data rows (battle_data.asm) --------------------------------------------
WEAPONS = {            # name: (WO_DMG, WO_CRIT)
    "KNIFE": (9, 6),
    "BAT": (15, 12),
}
SKILLS = {             # name: (kind, power, cooldown)
    "BANDAGE": ("heal", 30, 3),
    "AIMED": ("aimed", 10, 2),
}
ZOMBIES = {            # name: (maxHP, ATK, DEF)
    "RED": (44, 11, 6),
    "BLUE": (30, 8, 2),
}

# The tiles battle.asm lays across the bar, left to right (R=miss, A=hit, G=crit).
ZONE_BAR = "RRRAAAAGGAAAARRR"
ZONE_OF_LETTER = {"R": ZONE_MISS, "A": ZONE_HIT, "G": ZONE_CRIT}


# --- pure model (mirror the asm exactly) ------------------------------------
def clampmin1(x):
    """clamp(x, 1, 255) — the design's `min 1` landed-hit floor + no overflow."""
    return max(1, min(255, x))


def zone_of(x):
    """Crosshair position (0..CROSS_MAX) -> ZONE_* (see CrossZone)."""
    d = abs(x - CROSS_CENTRE)
    if d < GREEN_HALF:
        return ZONE_CRIT
    if d < AMBER_HALF:
        return ZONE_HIT
    return ZONE_MISS


def player_damage(base, enemy_def):
    """clampmin1(base + PLAYER_ATK>>2 - enemyDEF>>2) — CalcPlayerDamage."""
    return clampmin1(base + (PLAYER_ATK >> DMG_SHIFT) - (enemy_def >> DMG_SHIFT))


def weapon_lock(weapon, enemy_def, zone):
    """Full weapon resolution: formula damage, then the crosshair zone."""
    dmg, crit = WEAPONS[weapon]
    base = player_damage(dmg, enemy_def)
    if zone == ZONE_MISS:
        return 0
    if zone == ZONE_CRIT:
        return min(255, base + crit)
    return base


def enemy_attack(atk):
    """clampmin1(enemyATK - PLAYER_DEF>>2) — EnemyTurn."""
    return clampmin1(atk - (PLAYER_DEF >> DMG_SHIFT))


def sat_sub(hp, dmg):
    return max(0, hp - dmg)


def sat_add(hp, amt, cap=100):
    return min(cap, hp + amt)


# --- checks ------------------------------------------------------------------
def check_zone_layout():
    """Every bar cell's centre pixel must resolve to the zone its tile depicts —
    the minigame is honest: cell N does what cell N looks like."""
    assert len(ZONE_BAR) == ZONE_CELLS
    for cell, letter in enumerate(ZONE_BAR):
        centre = cell * 8 + 4              # pixel at the cell's middle
        want = ZONE_OF_LETTER[letter]
        got = zone_of(centre)
        assert got == want, (
            f"cell {cell} shows {letter} (zone {want}) but position {centre} "
            f"resolves to zone {got}")
    # green only dead-centre, red only at the edges
    assert zone_of(CROSS_CENTRE) == ZONE_CRIT
    assert zone_of(0) == ZONE_MISS and zone_of(CROSS_MAX) == ZONE_MISS
    return 0


def check_damage_saturates():
    """No landed hit deals < 1; nothing ever exceeds 255 or wraps."""
    for wname in WEAPONS:
        for zname, (_, _, edef) in ZOMBIES.items():
            for zone in (ZONE_MISS, ZONE_HIT, ZONE_CRIT):
                d = weapon_lock(wname, edef, zone)
                assert 0 <= d <= 255, f"{wname} vs {zname} zone {zone}: {d} OOR"
                if zone == ZONE_MISS:
                    assert d == 0, f"a miss must deal 0, got {d}"
                else:
                    assert d >= 1, f"{wname} landed hit floored below 1: {d}"
    # a landed hit against absurd defence still deals at least 1
    assert player_damage(1, 255) == 1
    # crit >= hit > miss for every weapon/enemy
    for wname in WEAPONS:
        for _, _, edef in ZOMBIES.values():
            miss = weapon_lock(wname, edef, ZONE_MISS)
            hit = weapon_lock(wname, edef, ZONE_HIT)
            crit = weapon_lock(wname, edef, ZONE_CRIT)
            assert crit >= hit > miss == 0, f"{wname}: {miss} {hit} {crit} ordering"
    # enemy attacks also floor at 1 and never wrap
    for zname, (_, atk, _) in ZOMBIES.items():
        e = enemy_attack(atk)
        assert 1 <= e <= 255, f"{zname} attack {e} OOR"
    return 0


def check_fight_terminates():
    """A perfect-crit run with the BAT must drop each zombie to exactly 0 in a
    finite number of turns (monotone, saturating — no underflow wrap to 255)."""
    for zname, (maxhp, _, edef) in ZOMBIES.items():
        hp = maxhp
        turns = 0
        while hp > 0:
            hp = sat_sub(hp, weapon_lock("BAT", edef, ZONE_CRIT))
            turns += 1
            assert turns < 100, f"{zname} fight never ends"
        assert hp == 0
    # heal saturates at the meter cap, never overshoots
    assert sat_add(90, 30) == 100
    assert sat_add(0, 30) == 30
    return 0


def main():
    rc = 0
    for check in (check_zone_layout, check_damage_saturates, check_fight_terminates):
        rc |= check()
        print(f"ok  {check.__name__}")
    # a quick readout of the modelled numbers, for eyeballing balance
    print("\nweapon damage (hit / crit) vs each zombie:")
    for wname in WEAPONS:
        row = []
        for zname, (_, _, edef) in ZOMBIES.items():
            h = weapon_lock(wname, edef, ZONE_HIT)
            c = weapon_lock(wname, edef, ZONE_CRIT)
            row.append(f"{zname} {h}/{c}")
        print(f"  {wname:6s} " + "   ".join(row))
    return rc


if __name__ == "__main__":
    import sys
    raise SystemExit(main())
