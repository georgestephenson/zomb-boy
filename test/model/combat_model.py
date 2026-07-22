#!/usr/bin/env python3
"""Host-side reference model of the combat math (src/battle.asm + battle_data.asm).

Mirrors the pure, testable parts of the battle engine — the damage formula, the
crosshair HIT ZONES, and saturating HP — so we can prove the invariants the
design calls out (docs/design/04 §4/§6) without an emulator:

  * damage saturates: never < 1 on a landed hit, never > 255, never wraps.
  * the crosshair's three outcomes are ordered: a head shot (crit) beats a body
    shot (hit) beats empty air (miss = 0). Slice 2 replaced the horizontal
    red/amber/green zone bar with a free crosshair that hit-tests the drawn
    zombies — a body cell is a hit, the head band a crit — so the position ->
    outcome mapping is now geometric (verified against the renderer in
    test_battle.py); only the outcome -> damage math is modelled here.
  * a fight actually terminates (HP monotonically falls to 0).

Keep in lockstep with battle.asm / battle_data.asm — change both together.
"""

# --- constants (constants.inc) ----------------------------------------------
DMG_SHIFT = 2
PLAYER_ATK = 12
PLAYER_DEF = 6
ZONE_MISS, ZONE_HIT, ZONE_CRIT = 0, 1, 2   # air / body / head

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


# --- pure model (mirror the asm exactly) ------------------------------------
def clampmin1(x):
    """clamp(x, 1, 255) — the design's `min 1` landed-hit floor + no overflow."""
    return max(1, min(255, x))


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
    """clampmin1(enemyATK - PLAYER_DEF>>2) — a melee foe's bite (BattleFoesTurn)."""
    return clampmin1(atk - (PLAYER_DEF >> DMG_SHIFT))


def sat_sub(hp, dmg):
    return max(0, hp - dmg)


def sat_add(hp, amt, cap=100):
    return min(cap, hp + amt)


# --- checks ------------------------------------------------------------------
def check_hit_zones_ordered():
    """head shot (crit) > body shot (hit) > empty air (miss = 0), for every
    weapon against every foe — the crosshair is honest about what it rewards."""
    for wname in WEAPONS:
        for zname, (_, _, edef) in ZOMBIES.items():
            miss = weapon_lock(wname, edef, ZONE_MISS)
            hit = weapon_lock(wname, edef, ZONE_HIT)
            crit = weapon_lock(wname, edef, ZONE_CRIT)
            assert miss == 0, f"{wname} vs {zname}: a miss must deal 0, got {miss}"
            assert crit > hit > 0, f"{wname} vs {zname}: {miss} {hit} {crit} order"
    return 0


def check_damage_saturates():
    """No landed hit deals < 1; nothing ever exceeds 255 or wraps."""
    for wname in WEAPONS:
        for zname, (_, _, edef) in ZOMBIES.items():
            for zone in (ZONE_MISS, ZONE_HIT, ZONE_CRIT):
                d = weapon_lock(wname, edef, zone)
                assert 0 <= d <= 255, f"{wname} vs {zname} zone {zone}: {d} OOR"
                if zone != ZONE_MISS:
                    assert d >= 1, f"{wname} landed hit floored below 1: {d}"
    # a landed hit against absurd defence still deals at least 1
    assert player_damage(1, 255) == 1
    # enemy attacks also floor at 1 and never wrap
    for zname, (_, atk, _) in ZOMBIES.items():
        e = enemy_attack(atk)
        assert 1 <= e <= 255, f"{zname} attack {e} OOR"
    return 0


def check_fight_terminates():
    """A perfect-crit run with the BAT drops each zombie to exactly 0 in a finite
    number of turns (monotone, saturating — no underflow wrap to 255)."""
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
    for check in (check_hit_zones_ordered, check_damage_saturates,
                  check_fight_terminates):
        rc |= check()
        print(f"ok  {check.__name__}")
    # a quick readout of the modelled numbers, for eyeballing balance
    print("\nweapon damage (body / head) vs each zombie:")
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
