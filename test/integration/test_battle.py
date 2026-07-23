"""Turn-based combat, slice 3 (docs task): a zombie's line of sight drops the
player into MODE_BATTLE, where a RANDOM-sized pack of zombies shuffles toward the
player as scaled BG sprites (with reserves waiting behind), a free crosshair
replaces the zone bar, and the player's REAL stats + equipped weapons drive the
damage. Verify the loop headlessly — entry seeds a leveled pack + clears the
scratch, the crosshair's hit-test drives damage (body = hit, head = crit, air =
miss), foes only bite at melee, killing one pulls in a reserve, and
win/lose/flee resolve back to the overworld.

The crosshair *timing feel* is interactive (no headless input), so these tests
pin the crosshair onto a foe's body/head and press A. The foe geometry
(TIERS / the per-foe lane) is the lockstep partner of battle_zombie_data.asm +
constants.inc; the damage numbers are randomised, so the tests assert relations
(full HP at start, crit > body, a bite hurts) rather than exact values.
"""
from harness import Game

ENT_SIZE = 16
EO_ACTIVE = 0
MODE_OVERWORLD, MODE_ALERT, MODE_BATTLE = 0, 1, 4
BS_MENU, BS_AIM, BS_MSG, BS_ENEMY, BS_END = 0, 1, 2, 3, 4
BM_MAIN, BM_FIGHT, BM_ITEM = 0, 1, 2
BO_ONGOING, BO_WIN, BO_LOSE, BO_FLEE = 0, 1, 2, 3
EPK_ZOMBIE, EPK_PERSONA = 0, 1
GUARD = 0xC5

# Foe struct (constants.inc FO_*) + arena geometry (battle_zombie_data.asm
# BattleZombieTiers, battle.asm ComputeFoeBox). Kept in lockstep so a test can
# pin the crosshair onto a foe's body or head.
FOE_STRUCT = 16
FO = {"TYPE": 0, "LEVEL": 1, "MAXHP": 2, "HP": 3, "ATK": 4, "DEF": 5,
      "TIER": 6, "SPD": 7, "STEP": 8, "LANE": 9}
FOE_TIER_MAX = 5
TIERS = [(1, 1, 1), (1, 2, 1), (2, 3, 1), (2, 4, 1), (3, 5, 2), (4, 7, 2)]
FOE_GROUND_ROW = 8
VIEW_COLS = 20


def poke(g, name, v):
    g.pyboy.memory[g.addr(name)] = v & 0xFF


def wait_for(g, cond, frames=300):
    for _ in range(frames):
        if cond():
            return True
        g.tick(1)
    return False


def press(g, button, settle=4):
    g.hold(button)
    g.tick(3)
    g.release(button)
    g.tick(settle)


def ent_active(g, i=0):
    return g.r8(g.addr("wZombies") + i * ENT_SIZE + EO_ACTIVE)


def foe_addr(g, i):
    return g.addr("wFoes") + i * FOE_STRUCT


def foe(g, i, field):
    return g.r8(foe_addr(g, i) + FO[field])


def set_foe(g, i, field, v):
    g.pyboy.memory[foe_addr(g, i) + FO[field]] = v & 0xFF


def lead_living(g):
    for i in range(g.r8("wFoeCount")):
        if foe(g, i, "HP") > 0:
            return i
    return None


def foe_box(g, i):
    """The foe's on-screen tile rectangle — a lockstep copy of ComputeFoeBox."""
    wt, ht, head = TIERS[foe(g, i, "TIER")]
    row_base = FOE_GROUND_ROW + 1 - ht
    col_base = max(0, min(VIEW_COLS - wt, foe(g, i, "LANE") - wt // 2))
    return col_base, row_base, wt, ht, head


def aim_at(g, i, head=True):
    """Pin the crosshair centre over foe i's head band (crit) or body (hit)."""
    cb, rb, wt, ht, head_rows = foe_box(g, i)
    poke(g, "wCrossX", cb * 8 + wt * 4 - 3)
    y_row = rb if head else rb + head_rows
    poke(g, "wCrossY", y_row * 8 + 1)


def aim_miss(g):
    poke(g, "wCrossX", 0)                          # top-left corner
    poke(g, "wCrossY", 0)


def shoot(g):
    press(g, "a")
    assert wait_for(g, lambda: g.r8("wBattleState") in (BS_MSG, BS_END)), "no resolve"


def ack(g):
    press(g, "a")


def enter_zombie_battle(g):
    """Get spotted, ride the '!' charge + flash, and land in MODE_BATTLE."""
    import test_zombies as tz
    poke(g, "wSwimming", 0)
    alerted = False
    for _ in range(8):
        tz._plant_zombie_facing_player(g)
        g.tick(1)
        if g.r8("wGameMode") == MODE_ALERT:
            alerted = True
            break
    assert alerted, "zombie never spotted the player"
    assert wait_for(g, lambda: g.r8("wGameMode") == MODE_BATTLE, 250), \
        "the '!' charge never resolved into a battle"
    assert wait_for(g, lambda: g.r8("wBattleState") == BS_MENU), "menu never opened"


def open_aim(g, weapon_slot=0):
    """From the main menu: Fight -> the given weapon -> BS_AIM."""
    assert g.r8("wBattleState") == BS_MENU and g.r8("wBattleMenu") == BM_MAIN
    press(g, "a")                                   # Fight
    assert wait_for(g, lambda: g.r8("wBattleMenu") == BM_FIGHT), "no submenu"
    for _ in range(weapon_slot):
        press(g, "right")
    press(g, "a")                                   # weapon
    assert wait_for(g, lambda: g.r8("wBattleState") == BS_AIM), "no aim state"


def advance_to_menu(g):
    """Ack the hit line, the enemy's turn, and land back at the main menu."""
    assert wait_for(g, lambda: g.r8("wBattleState") == BS_MSG)
    ack(g)                                          # hit/miss line -> enemy turn
    assert wait_for(g,
                    lambda: g.r8("wBattleState") == BS_MENU
                    or (g.r8("wBattleState") == BS_MSG
                        and g.r8("wBattleMsgNext") == BS_MENU)), "no enemy turn"
    if g.r8("wBattleState") == BS_MSG:
        ack(g)                                      # enemy line -> menu
    assert wait_for(g, lambda: g.r8("wBattleState") == BS_MENU)


# --- entry / scratch ---------------------------------------------------------

def test_zombie_sight_starts_battle(game):
    enter_zombie_battle(game)
    assert game.r8("wBattleEKind") == EPK_ZOMBIE
    assert game.r8("wBattleFoe") == 0, "the spotting zombie is the foe"
    n = game.r8("wFoeCount")
    assert 2 <= n <= 4, f"a random pack of 2..4 appears, got {n}"
    for i in range(n):
        assert foe(game, i, "HP") == foe(game, i, "MAXHP"), "foes start at full HP"
        assert 1 <= foe(game, i, "LEVEL") <= 99, "foes carry a level"
    assert game.r8("wBattleState") == BS_MENU and game.r8("wBattleMenu") == BM_MAIN


def test_foe_level_tracks_the_player(game):
    """Zombie levels are randomised around the player's own level."""
    enter_zombie_battle(game)
    ply = game.r8("wPlyLevel")
    for i in range(game.r8("wFoeCount")):
        lv = foe(game, i, "LEVEL")
        assert ply - 1 <= lv <= ply + 3, f"foe level {lv} vs player {ply}"


def test_foes_start_below_melee(game):
    """Nobody bites on turn one — the pack is still closing the distance."""
    enter_zombie_battle(game)
    for i in range(game.r8("wFoeCount")):
        assert foe(game, i, "TIER") < FOE_TIER_MAX


def test_battle_scratch_cleared_under_poison():
    """Boot-hygiene: entering combat must not inherit poisoned RAM (design 04
    §6). The canary is armed, the fight is fresh, cooldowns zeroed."""
    g = Game(poison=0xA5)
    try:
        enter_zombie_battle(g)
        assert g.r8("wBattleGuard") == GUARD, "battle canary not armed"
        assert g.r8("wBattleOutcome") == BO_ONGOING
        assert foe(g, 0, "HP") == foe(g, 0, "MAXHP"), "foe HP inherited poison"
        assert g.r8("wSkillCd") == 0 and g.r8(g.addr("wSkillCd") + 1) == 0
    finally:
        g.close()


# --- the crosshair drives damage ---------------------------------------------

def test_miss_deals_no_damage_crit_does(game):
    enter_zombie_battle(game)
    hp0 = foe(game, 0, "HP")
    open_aim(game)
    aim_miss(game)                                  # crosshair on empty air
    shoot(game)
    assert foe(game, 0, "HP") == hp0, "a miss dealt damage"
    advance_to_menu(game)
    open_aim(game)
    aim_at(game, 0, head=True)                       # head band -> crit
    shoot(game)
    assert foe(game, 0, "HP") < hp0, "a headshot should hurt"


def test_headshot_beats_body_shot(game):
    """A hit anywhere on the foe damages it; the head band crits for more."""
    enter_zombie_battle(game)
    open_aim(game)
    set_foe(game, 0, "TIER", 3)                       # a size with a body below the head
    set_foe(game, 0, "MAXHP", 250)
    set_foe(game, 0, "HP", 250)
    aim_at(game, 0, head=False)                      # body -> plain hit
    shoot(game)
    body = 250 - foe(game, 0, "HP")
    advance_to_menu(game)
    open_aim(game)
    set_foe(game, 0, "TIER", 3)
    set_foe(game, 0, "HP", 250)
    aim_at(game, 0, head=True)                        # head -> crit
    shoot(game)
    head = 250 - foe(game, 0, "HP")
    assert body > 0 and head > body, f"body {body} head {head}"


def test_foes_approach_each_turn(game):
    """A max-speed foe grows a size tier (closes in) on the enemy turn."""
    enter_zombie_battle(game)
    set_foe(game, 0, "SPD", 4)                        # advance every turn
    set_foe(game, 0, "STEP", 0)
    set_foe(game, 0, "TIER", 1)
    open_aim(game)
    aim_miss(game)
    shoot(game)                                      # miss -> enemy turn
    advance_to_menu(game)
    assert foe(game, 0, "TIER") == 2


def test_enemy_turn_damages_player_in_melee(game):
    """A foe at full size (melee range) bites the player on its turn."""
    enter_zombie_battle(game)
    set_foe(game, 0, "TIER", FOE_TIER_MAX)           # drag foe 0 into melee
    hp0 = game.r8("wHP")
    open_aim(game)
    aim_miss(game)                                   # miss so the foe survives to bite
    shoot(game)
    advance_to_menu(game)
    assert game.r8("wHP") < hp0, "a melee foe should have hurt the player"


# --- reserves ----------------------------------------------------------------

def test_reserve_fills_an_emptied_slot(game):
    """Killing a visible foe while reserves remain pulls a fresh one in behind."""
    enter_zombie_battle(game)
    if game.r8("wFoeReserve") == 0:
        poke(game, "wFoeReserve", 2)                 # guarantee a reserve to test
    open_aim(game)
    i = lead_living(game)
    set_foe(game, i, "HP", 1)                         # one crit finishes it
    r0 = game.r8("wFoeReserve")
    aim_at(game, i, head=True)
    shoot(game)
    assert game.r8("wFoeReserve") == r0 - 1, "a reserve should have been consumed"
    assert foe(game, i, "HP") > 0, "the emptied slot should be refilled"


# --- outcomes ----------------------------------------------------------------

def g_mode(g):
    return g.r8("wGameMode")


def test_win_despawns_the_spotter(game):
    enter_zombie_battle(game)
    poke(game, "wFoeReserve", 0)                      # no reserves: clear the visible pack
    for _ in range(60):
        assert wait_for(game, lambda: game.r8("wBattleState") == BS_MENU)
        poke(game, "wHP", 100)                        # outlast the pack while clearing it
        open_aim(game)
        i = lead_living(game)
        assert i is not None
        set_foe(game, i, "HP", 1)                     # one crit per foe keeps it quick
        aim_at(game, i, head=True)
        shoot(game)
        if game.r8("wBattleOutcome") == BO_WIN:
            break
        advance_to_menu(game)
    else:
        assert False, "the pack never dropped"
    ack(game)                                        # ack the win line -> exit
    assert wait_for(game, lambda: g_mode(game) == MODE_OVERWORLD, 120), \
        "win didn't return to the overworld"
    assert ent_active(game, 0) == 0, "the spotting zombie should be despawned"
    assert game.r8("wAlertGrace") > 0, "a grace period should follow the fight"


def test_lose_returns_to_overworld_without_despawn(game):
    enter_zombie_battle(game)
    set_foe(game, 0, "TIER", FOE_TIER_MAX)           # a melee foe to finish the player
    set_foe(game, 0, "ATK", 40)                      # a solid bite
    poke(game, "wHP", 1)
    open_aim(game)
    aim_miss(game)                                   # miss -> the foe gets its bite
    shoot(game)
    ack(game)                                        # miss line -> enemy turn
    assert wait_for(game, lambda: game.r8("wBattleOutcome") == BO_LOSE, 120), \
        "player at 1 HP should lose to the melee foe"
    ack(game)                                        # ack "YOU FELL" -> exit
    assert wait_for(game, lambda: g_mode(game) == MODE_OVERWORLD, 120)
    assert ent_active(game, 0) == 1, "a loss must not despawn the zombie"


def test_flee_eventually_escapes(game):
    enter_zombie_battle(game)
    escaped = False
    for _ in range(16):
        assert wait_for(game, lambda: game.r8("wBattleState") == BS_MENU)
        poke(game, "wHP", 100)                        # keep failed flees from killing us
        for i in range(game.r8("wFoeCount")):        # keep melee foes off our back
            set_foe(game, i, "TIER", 0)
        poke(game, "wBattleCursor", 3)               # Flee
        press(game, "a")
        if wait_for(game, lambda: game.r8("wBattleOutcome") == BO_FLEE, 30):
            escaped = True
            break
        advance_to_menu(game)                        # failed flee -> enemy turn -> menu
    assert escaped, "flee never succeeded in 16 tries"
    ack(game)                                        # ack "GOT AWAY" -> exit
    assert wait_for(game, lambda: g_mode(game) == MODE_OVERWORLD, 120)
    assert ent_active(game, 0) == 1, "fleeing must not despawn the zombie"


# --- items menu --------------------------------------------------------------

def test_item_menu_medkit_heals(game):
    """The Item menu lists the real bag consumables; a MEDKIT heals the player."""
    enter_zombie_battle(game)
    poke(game, "wHP", 20)
    assert g_mode(game) == MODE_BATTLE
    press(game, "up")                                # main menu: move to Item (cursor 2)
    assert game.r8("wBattleCursor") == 2
    press(game, "a")                                 # open the Item submenu
    assert wait_for(game, lambda: game.r8("wBattleMenu") == BM_ITEM), "no item menu"
    # the menu lists the real bag consumables; pick the MEDKIT slot (id 9)
    ITEM_MEDKIT = 9
    m = [game.r8(game.addr("wBattleItemMap") + k) for k in range(4)]
    assert ITEM_MEDKIT in m, f"medkit not offered: {m}"
    poke(game, "wBattleCursor", m.index(ITEM_MEDKIT))
    press(game, "a")
    assert wait_for(game, lambda: g_mode(game) == MODE_BATTLE)
    assert game.r8("wHP") > 20, "the medkit should have healed the player"


# --- the shared engine also serves hostile survivors -------------------------

def test_survivor_fight_uses_persona_portrait(game):
    """The talk 'fight' outcome enters the SAME battle engine with the persona's
    portrait and a single foe."""
    import test_talk as tt
    tt.goto_npc0(game)
    outcome = tt.run_conversation(game, [tt.T_FLIRT] * 3)   # -> OUTCOME_FIGHT
    assert outcome == tt.OUTCOME_FIGHT
    assert game.r8("wGameMode") == MODE_BATTLE
    assert game.r8("wBattleEKind") == EPK_PERSONA
    assert game.r8("wBattleFoe") == 0xFF, "no pool zombie backs a survivor fight"
    assert game.r8("wFoeCount") == 1, "a survivor is a single foe"
    assert game.r8("wEnemyHP") == game.r8("wEnemyMaxHP")
