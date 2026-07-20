"""Turn-based combat (docs/design/04): a zombie's line of sight drops the player
into MODE_BATTLE. Verify the whole loop headlessly — entry clears the fight
scratch, the crosshair zone controls damage, HP saturates, and win/lose/flee each
resolve back to the overworld (a win despawning the foe).

The crosshair *timing feel* is interactive (no headless input), so these tests
poke wCrossX to a known position and press A — exercising the lock->zone->damage
logic, not the sweep's difficulty. Enemy stats/damage numbers are the lockstep
partner of test/model/combat_model.py and battle_data.asm.
"""
from harness import Game

ENT_SIZE = 16
EO_ACTIVE, EO_WXLO, EO_WYLO, EO_FACING, EO_DIR = 0, 1, 3, 5, 6
EFACE_LEFT = 2
MODE_OVERWORLD, MODE_ALERT, MODE_BATTLE = 0, 1, 4
BS_MENU, BS_AIM, BS_MSG, BS_ENEMY, BS_END = 0, 1, 2, 3, 4
BM_MAIN, BM_FIGHT = 0, 1
BO_ONGOING, BO_WIN, BO_LOSE, BO_FLEE = 0, 1, 2, 3
EPK_ZOMBIE, EPK_PERSONA = 0, 1
CROSS_CENTRE = 64
GUARD = 0xC5
# RED zombie row (battle_data.asm ZombieTable[0]); zombie pool idx 0 -> type RED.
RED_MAXHP, RED_ATK, RED_DEF = 44, 11, 6


def w16(g, a, v):
    g.pyboy.memory[a] = v & 0xFF
    g.pyboy.memory[a + 1] = (v >> 8) & 0xFF


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


def enter_zombie_battle(g):
    """Get spotted, ride the '!' charge + flash, and land in MODE_BATTLE. Detection
    (post-#25) compares the zombie's lagging visual tile to the player's arrived
    tile, so re-pin the zombie in line each frame until it alerts — the same trick
    test_zombies uses (reused here so both stay in lockstep with the LOS code)."""
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


def lock_at(g, x):
    """Freeze the crosshair at x and press A to lock (the sweep nudges it a few
    px first, but the zones are wide enough that a poked centre stays a crit)."""
    poke(g, "wCrossX", x)
    poke(g, "wCrossDir", 0)
    press(g, "a")
    assert wait_for(g, lambda: g.r8("wBattleState") in (BS_MSG, BS_END)), "no resolve"


def ack(g):
    press(g, "a")


def advance_to_menu(g):
    """Ack the hit line, the enemy's turn, and land back at the main menu."""
    assert wait_for(g, lambda: g.r8("wBattleState") == BS_MSG)
    ack(g)                                          # hit line -> enemy turn
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
    # pool idx 0 -> type RED: full HP, RED's stats copied into scratch
    assert game.r8("wEnemyMaxHP") == RED_MAXHP
    assert game.r8("wEnemyHP") == RED_MAXHP, "enemy should start at full HP"
    assert game.r8("wEnemyDEF") == RED_DEF and game.r8("wEnemyATK") == RED_ATK
    assert game.r8("wBattleState") == BS_MENU and game.r8("wBattleMenu") == BM_MAIN


def test_battle_scratch_cleared_under_poison():
    """Boot-hygiene: entering combat must not inherit poisoned RAM (design 04
    §6). The canary is armed, the fight is fresh, cooldowns zeroed."""
    g = Game(poison=0xA5)
    try:
        enter_zombie_battle(g)
        assert g.r8("wBattleGuard") == GUARD, "battle canary not armed"
        assert g.r8("wBattleOutcome") == BO_ONGOING
        assert g.r8("wEnemyHP") == RED_MAXHP, "enemy HP inherited poison"
        assert g.r8("wSkillCd") == 0 and g.r8(g.addr("wSkillCd") + 1) == 0
    finally:
        g.close()


# --- the crosshair drives damage ---------------------------------------------

def test_miss_deals_no_damage_crit_does(game):
    enter_zombie_battle(game)
    hp0 = game.r8("wEnemyHP")
    open_aim(game)
    lock_at(game, 0)                                # red edge -> miss
    assert game.r8("wEnemyHP") == hp0, "a miss dealt damage"
    advance_to_menu(game)
    open_aim(game)
    lock_at(game, CROSS_CENTRE)                     # green centre -> crit
    dealt = hp0 - game.r8("wEnemyHP")
    assert dealt >= 17, f"crit should hurt (KNIFE crit vs RED = 17), dealt {dealt}"


def test_enemy_turn_damages_player(game):
    enter_zombie_battle(game)
    hp0 = game.r8("wHP")
    open_aim(game)
    lock_at(game, 0)                                # miss so the enemy survives
    advance_to_menu(game)
    assert game.r8("wHP") < hp0, "enemy turn should have hurt the player"


# --- outcomes ----------------------------------------------------------------

def test_win_despawns_the_zombie(game):
    enter_zombie_battle(game)
    for _ in range(6):
        open_aim(game)
        lock_at(game, CROSS_CENTRE)                 # crit every time
        if game.r8("wBattleOutcome") == BO_WIN:
            break
        advance_to_menu(game)
    else:
        assert False, "enemy never dropped under repeated crits"
    ack(game)                                       # ack the win line -> exit
    assert wait_for(game, lambda: g_mode(game) == MODE_OVERWORLD, 120), \
        "win didn't return to the overworld"
    assert ent_active(game, 0) == 0, "the defeated zombie should be despawned"
    assert game.r8("wAlertGrace") > 0, "a grace period should follow the fight"


def g_mode(g):
    return g.r8("wGameMode")


def test_lose_returns_to_overworld_without_despawn(game):
    enter_zombie_battle(game)
    poke(game, "wHP", 1)                            # one bite finishes the player
    open_aim(game)
    lock_at(game, 0)                                # miss -> enemy gets its turn
    ack(game)                                       # hit(miss) line -> enemy turn
    assert wait_for(game, lambda: game.r8("wBattleOutcome") == BO_LOSE, 120), \
        "player at 1 HP should lose to the enemy turn"
    ack(game)                                       # ack the "YOU FELL" line -> exit
    assert wait_for(game, lambda: g_mode(game) == MODE_OVERWORLD, 120)
    assert ent_active(game, 0) == 1, "a loss must not despawn the zombie"


def test_flee_eventually_escapes(game):
    enter_zombie_battle(game)
    escaped = False
    for _ in range(16):
        assert wait_for(game, lambda: game.r8("wBattleState") == BS_MENU)
        poke(game, "wHP", 100)                      # keep failed flees from killing us
        poke(game, "wBattleCursor", 3)              # Flee
        press(game, "a")
        if wait_for(game, lambda: game.r8("wBattleOutcome") == BO_FLEE, 30):
            escaped = True
            break
        # failed flee -> "CANT ESCAPE" -> enemy turn -> back to the menu
        advance_to_menu(game)
    assert escaped, "flee never succeeded in 16 tries"
    ack(game)                                       # ack the "GOT AWAY" line -> exit
    assert wait_for(game, lambda: g_mode(game) == MODE_OVERWORLD, 120)
    assert ent_active(game, 0) == 1, "fleeing must not despawn the zombie"


# --- the shared engine also serves hostile survivors -------------------------

def test_survivor_fight_uses_persona_portrait(game):
    """The talk 'fight' outcome enters the SAME battle engine with the persona's
    portrait — proving one screen serves a zombie or a survivor."""
    import test_talk as tt
    tt.goto_npc0(game)
    outcome = tt.run_conversation(game, [tt.T_FLIRT] * 3)   # -> OUTCOME_FIGHT
    assert outcome == tt.OUTCOME_FIGHT
    assert game.r8("wGameMode") == MODE_BATTLE
    assert game.r8("wBattleEKind") == EPK_PERSONA
    assert game.r8("wBattleFoe") == 0xFF, "no pool zombie backs a survivor fight"
    assert game.r8("wEnemyHP") == game.r8("wEnemyMaxHP")
