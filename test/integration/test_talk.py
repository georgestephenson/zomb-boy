"""Survivor dialogue (docs/design/05): NPC 0 (the policeman) stands one tile
below the spawn; bumping into them and pressing A must open MODE_TALK,
generate readable text into the bounded grid, offer a random 4-tone menu
(always containing a non-negative option), move affinity per the persona/tone
math, run the sentence -> reply -> reaction rhythm for three rounds, and never
scribble past the text buffer (canary byte).

Trait/tone tables here are LOCKSTEP copies of src/dialogue_data.asm
(PersonaTable / ToneTable / ToneLabels) — dialogue_bounds.py checks the ROM
side. Menus are random, so tests either read wMenuTones to see what's offered
or poke a tone into slot 0 (the engine applies wMenuTones[cursor] on pick).
"""
from harness import Game

ENT_SIZE = 16
EO_AFFIN = 14
MODE_OVERWORLD, MODE_ALERT, MODE_TALK = 0, 1, 2
TS_REVEAL, TS_WAIT, TS_MENU = 0, 1, 2
TPH_GREET, TPH_REACT, TPH_OUTCOME, TPH_PROMPT, TPH_OBS, TPH_QUEST = range(6)
OUTCOME_FIGHT, OUTCOME_PART, OUTCOME_REWARD = 0, 1, 2
TALK_TEXT_MAX, GUARD = 54, 0xC5
FONT_BASE = 128
CHARSET = " ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.,!?'-"
VALID = set(range(FONT_BASE, FONT_BASE + len(CHARSET)))
SCRN1 = 0x9C00
TXT_ROW0, TXT_COL0 = 12, 1

POLICE_TRAITS = (-40, 10, 20, 50)
TONES = [  # id order matches ToneTable: (name, push over T0..T3, base)
    ("NICE", (0, 1, 1, 0), 2),
    ("FLIRT", (1, 0, 0, -1), 0),
    ("JOKE", (0, 0, 0, -1), 0),
    ("RUDE", (-1, 0, -1, 0), -6),
    ("GUARDED", (-1, 0, 0, 1), 0),
    ("CHEER", (0, 1, 0, -1), 1),
    ("GRIM", (0, -1, 0, 1), -1),
    ("DEMAND", (0, 0, -1, 0), -2),
]
T_NICE, T_FLIRT, T_JOKE, T_RUDE, T_GUARDED, T_CHEER, T_GRIM, T_DEMAND = range(8)

# Lockstep copy of ToneLabelMoods (dialogue_data.asm): the menu shows a
# mood-keyed synonym for each tone, so tests accept any variant for the tone.
TONE_LABEL_VARIANTS = [  # [tone] -> set of labels across all moods x variants
    {"EASY", "SOOTHE", "NICE", "KIND", "LOVE IT", "AGREED"},
    {"CHARM", "WINK", "FLIRT", "TEASE", "SWOON", "DARLING"},
    {"DEFLECT", "QUIP", "JOKE", "JEST", "BANTER", "RIFF"},
    {"SNAP", "SCOFF", "RUDE", "MOCK", "NEEDLE", "JAB"},
    {"CAREFUL", "WARY", "GUARDED", "HEDGE", "DEMUR", "MODEST"},
    {"RALLY", "UPLIFT", "CHEER", "PEP", "HOORAY", "BEAM"},
    {"AGREE", "BLEAK", "GRIM", "SIGH", "SOBER", "LAMENT"},
    {"PRESS", "EXTORT", "DEMAND", "ASK", "BEG", "REQUEST"},
]
LABEL_MAX = 7

# Lockstep copy of the POLICEMAN's hurt bank (observation banks are per-
# persona now — dialogue_data.asm CtxPolice; NPC 0 is the policeman).
HURT_WORDS = ("FILE A REPORT", "CODE THREE")


def expected_delta(tone_id, traits=POLICE_TRAITS):
    _, push, base = TONES[tone_id]
    dot = sum(p * t for p, t in zip(push, traits))
    return max(-16, min(16, dot >> 2)) + base


def npc_affin(g, i=0):
    return g.r8(g.addr("wNPCs") + i * ENT_SIZE + EO_AFFIN)


def poke_affin(g, value, i=0):
    g.pyboy.memory[g.addr("wNPCs") + i * ENT_SIZE + EO_AFFIN] = value


def menu_tones(g):
    base = g.addr("wMenuTones")
    return [g.r8(base + i) for i in range(4)]


def press(g, button, settle=4):
    g.hold(button)
    g.tick(3)
    g.release(button)
    g.tick(settle)


def wait_for(g, cond, frames=240):
    for _ in range(frames):
        if cond():
            return True
        g.tick(1)
    return False


def goto_npc0(g):
    """NPC 0 stands at (0,1), one step below the spawn: bump into them, which
    leaves the player at (0,0) facing down at the survivor."""
    g.walk("down", 24)
    assert (g.s16("wPlayerWX"), g.s16("wPlayerWY")) == (0, 0), \
        "player should stand at the spawn, blocked by NPC 0"
    assert g.r8("wFacing") == 0, "player should face down (EFACE_DOWN)"


def start_talk(g):
    press(g, "a")
    assert g.r8("wGameMode") == MODE_TALK, "A next to a survivor should open talk"


def advance_to_menu(g):
    """Press through the NPC's pages (reaction, prompt, observation, question)
    until the menu is up. A turn runs 2-3 pages now, plus the reaction."""
    for _ in range(8):
        assert wait_for(g, lambda: g.r8("wTalkState") in (TS_WAIT, TS_MENU)), \
            "reveal never finished"
        if g.r8("wTalkState") == TS_MENU:
            return
        press(g, "a")
    assert g.r8("wTalkState") == TS_MENU, "menu never opened"


def force_pick(g, tone_id):
    """At the menu: put the wanted tone in slot 0 and pick it (the engine
    applies wMenuTones[cursor], so this sidesteps menu randomness)."""
    assert g.r8("wTalkState") == TS_MENU
    g.pyboy.memory[g.addr("wMenuTones")] = tone_id
    press(g, "a")


def read_text(g):
    base = g.addr("wTalkText")
    return [g.r8(base + i) for i in range(TALK_TEXT_MAX)]


def decode(cells):
    return "".join(CHARSET[b - FONT_BASE] if b in VALID else "#" for b in cells)


def flow_text(g):
    """The grid re-joined as one line: words survive the greedy wrap (a phrase
    like 'KIND SOUL.' may straddle a row boundary in the raw 54-cell decode)."""
    cells = read_text(g)
    rows = [decode(cells[r * 18:(r + 1) * 18]) for r in range(3)]
    return " ".join(" ".join(row.split()) for row in rows).strip()


def assert_text_sane(g):
    cells = read_text(g)
    assert all(b in VALID for b in cells), f"non-glyph bytes in grid: {decode(cells)}"
    assert sum(1 for b in cells if b != FONT_BASE) >= 3, "grid practically empty"
    assert g.r8("wTalkGuard") == GUARD, "composer wrote past the text grid!"


def run_conversation(g, tone_ids):
    start_talk(g)
    for tone_id in tone_ids:
        advance_to_menu(g)
        force_pick(g, tone_id)
    # final reaction -> A -> outcome line -> read it -> A -> resolve
    assert wait_for(g, lambda: g.r8("wTalkState") == TS_WAIT), "no final reaction"
    press(g, "a")
    assert wait_for(g, lambda: g.r8("wTalkState") == TS_WAIT), "no outcome line"
    outcome = g.r8("wTalkOutcome")
    assert_text_sane(g)
    press(g, "a")
    assert wait_for(g, lambda: g.r8("wGameMode") == MODE_OVERWORLD, 120), \
        "conversation didn't resolve back to the overworld"
    g.tick(100)  # a FIGHT outcome's placeholder flash ignores input while it runs
    return outcome


# --- opening the conversation -------------------------------------------------

def test_talk_opens_with_generated_text(game):
    goto_npc0(game)
    start_talk(game)
    assert game.r8("wTalkPersona") == 0  # the policeman
    assert wait_for(game, lambda: game.r8("wTalkState") == TS_WAIT)
    assert_text_sane(game)


def test_npc_blocks_walking(game):
    goto_npc0(game)
    game.hold("down")
    game.tick(60)
    game.release("down")
    assert (game.s16("wPlayerWX"), game.s16("wPlayerWY")) == (0, 0), \
        "walked through a survivor"
    assert game.r8("wGameMode") == MODE_OVERWORLD


# --- the menu -----------------------------------------------------------------

def test_menu_offers_four_distinct_playable_tones(game):
    goto_npc0(game)
    start_talk(game)
    advance_to_menu(game)
    tones = menu_tones(game)
    assert all(0 <= t < len(TONES) for t in tones), f"bad tone ids: {tones}"
    assert len(set(tones)) == 4, f"duplicate tones offered: {tones}"
    assert any(expected_delta(t) >= 0 for t in tones), \
        f"menu {tones} has no non-negative option for the policeman"
    press(game, "b")


def test_cursor_slots_map_to_offered_tones(game):
    """Navigate to slot 3 (right+down) and confirm the applied delta belongs
    to the tone shown there — the honest, non-poked path."""
    goto_npc0(game)
    start_talk(game)
    advance_to_menu(game)
    slot3 = menu_tones(game)[3]
    before = npc_affin(game)
    press(game, "right")
    press(game, "down")
    press(game, "a")
    got = npc_affin(game) - before
    want = expected_delta(slot3)
    assert got == want, f"slot 3 held tone {slot3}, delta {got} != {want}"
    press(game, "b")


def test_menu_labels_reach_vram(game):
    """The label shown for slot 0 must be one of the mood-keyed synonyms for
    the tone actually offered there (labels are context-sensitive now)."""
    goto_npc0(game)
    start_talk(game)
    advance_to_menu(game)
    game.tick(12)  # let the fast reveal drain through the VBlank queue
    slot0 = menu_tones(game)[0]
    row = SCRN1 + TXT_ROW0 * 32
    shown = decode([game.r8(row + TXT_COL0 + 1 + i) for i in range(LABEL_MAX)])
    shown = shown.rstrip()
    assert shown in TONE_LABEL_VARIANTS[slot0], \
        f"slot 0 offers tone {slot0}, VRAM shows '{shown}' (not a known synonym)"
    press(game, "b")


# --- affinity math ------------------------------------------------------------

def test_each_tone_shifts_affinity_per_personality(game):
    goto_npc0(game)
    for tone_id in range(len(TONES)):
        poke_affin(game, 128)
        start_talk(game)
        advance_to_menu(game)
        force_pick(game, tone_id)
        want = 128 + expected_delta(tone_id)
        got = npc_affin(game)
        assert got == want, f"{TONES[tone_id][0]}: affinity {got}, expected {want}"
        press(game, "b")  # leave early
        assert wait_for(game, lambda: game.r8("wGameMode") == MODE_OVERWORLD, 60)


def test_affinity_saturates_both_ends(game):
    goto_npc0(game)
    # top end: GUARDED (+16 at the policeman) from 254 must clamp to 255
    poke_affin(game, 254)
    start_talk(game)
    advance_to_menu(game)
    force_pick(game, T_GUARDED)
    assert npc_affin(game) == 255, "affinity wrapped past 255"
    press(game, "b")
    assert wait_for(game, lambda: game.r8("wGameMode") == MODE_OVERWORLD, 60)
    # bottom end: FLIRT (-16 at the policeman) from 1 must clamp to 0
    poke_affin(game, 1)
    start_talk(game)
    advance_to_menu(game)
    force_pick(game, T_FLIRT)
    assert npc_affin(game) == 0, "affinity wrapped below 0"
    press(game, "b")


def test_b_exit_keeps_affinity_for_next_time(game):
    goto_npc0(game)
    start_talk(game)
    advance_to_menu(game)
    force_pick(game, T_NICE)
    press(game, "b")
    assert wait_for(game, lambda: game.r8("wGameMode") == MODE_OVERWORLD, 60)
    assert npc_affin(game) == 128 + expected_delta(T_NICE)
    start_talk(game)  # relationship resumes
    assert game.r8("wTalkRound") == 0, "rounds should reset per conversation"
    press(game, "b")


# --- generation smartness -----------------------------------------------------

NICE_TAGS = ("SWEET OF YOU.", "KIND SOUL.")  # lockstep: ToneTagsLiked[NICE]


def test_reaction_carries_a_tone_tag(game):
    """A liked reply's reaction must include the tag for THAT tone — the NPC
    answers what you said, not just how much they liked it."""
    goto_npc0(game)
    start_talk(game)
    advance_to_menu(game)
    force_pick(game, T_NICE)  # +9 at the policeman -> liked -> NICE tag
    assert wait_for(game, lambda: game.r8("wTalkState") == TS_WAIT)
    text = flow_text(game)
    assert any(tag in text for tag in NICE_TAGS), \
        f"reaction lacks a NICE tag: '{text}'"
    press(game, "b")


def test_conversation_keeps_its_subject(game):
    """Subject threading: one noun is fixed at talk start and stays fixed, so
    the NPC's lines orbit an actual topic."""
    goto_npc0(game)
    start_talk(game)
    subject = game.r8("wTalkSubject")
    assert subject < 6, f"subject {subject} out of the 6-noun bank"
    advance_to_menu(game)
    force_pick(game, T_NICE)
    advance_to_menu(game)  # through reaction + round-2 prompt
    assert game.r8("wTalkSubject") == subject, "subject drifted mid-conversation"
    press(game, "b")


def test_npc_remembers_meeting(game):
    """EO_MET flips after the first conversation; return visits skip the
    stranger greeting (composed from the continuation bank instead)."""
    EO_MET = 15
    met_addr = game.addr("wNPCs") + EO_MET
    goto_npc0(game)
    assert game.r8(met_addr) == 0
    start_talk(game)
    assert game.r8("wTalkMet") == 0, "first talk should read as a first meeting"
    assert game.r8(met_addr) == 1, "EO_MET should be set once the talk starts"
    press(game, "b")
    assert wait_for(game, lambda: game.r8("wGameMode") == MODE_OVERWORLD, 60)
    start_talk(game)
    assert game.r8("wTalkMet") == 1, "second talk should know we've met"
    press(game, "b")


# --- the three-round rhythm and its outcomes ----------------------------------

def test_rounds_are_sentence_reply_reaction(game):
    """Rounds 2+ must open with a fresh NPC prompt line: after a pick, the
    reaction is acknowledged, then another NPC line, then their question,
    THEN the next menu."""
    goto_npc0(game)
    start_talk(game)
    advance_to_menu(game)
    force_pick(game, T_NICE)
    assert wait_for(game, lambda: game.r8("wTalkState") == TS_WAIT)
    assert game.r8("wTalkPhase") == TPH_REACT
    press(game, "a")
    assert wait_for(game, lambda: game.r8("wTalkState") == TS_WAIT)
    assert game.r8("wTalkPhase") == TPH_PROMPT, "no fresh NPC line before round 2"
    assert_text_sane(game)
    # the turn always closes with a question page before the menu opens
    saw_question = False
    for _ in range(4):
        press(game, "a")
        assert wait_for(game, lambda: game.r8("wTalkState") in (TS_WAIT, TS_MENU))
        if game.r8("wTalkState") == TS_MENU:
            break
        if game.r8("wTalkPhase") == TPH_QUEST:
            saw_question = True
            assert "?" in decode(read_text(game)), "question page lacks a ?"
    assert game.r8("wTalkState") == TS_MENU, "menu never opened"
    assert saw_question, "menu opened without the NPC asking a question"
    press(game, "b")


def test_turn_ends_with_question_page(game):
    """Round 1, observation suppressed: greeting -> question -> menu. The
    question is the turn's last beat and carries an actual '?'."""
    goto_npc0(game)
    start_talk(game)
    game.pyboy.memory[game.addr("wTalkObs")] = 0   # force the 2-page turn
    assert wait_for(game, lambda: game.r8("wTalkState") == TS_WAIT)
    press(game, "a")
    assert wait_for(game, lambda: game.r8("wTalkState") == TS_WAIT)
    assert game.r8("wTalkPhase") == TPH_QUEST, "greeting wasn't followed by a question"
    assert "?" in decode(read_text(game))
    assert_text_sane(game)
    press(game, "a")
    assert wait_for(game, lambda: game.r8("wTalkState") == TS_MENU, 60)
    press(game, "b")


# --- context awareness: the NPC reads live game state ---------------------------

def test_observation_notices_low_hp(game):
    """With HP low, the round-1 observation page must come from the HURT bank
    (meters outrank everything in PickContext) and mark its context used."""
    goto_npc0(game)
    game.pyboy.memory[game.addr("wHP")] = 10
    start_talk(game)
    assert wait_for(game, lambda: game.r8("wTalkState") == TS_WAIT)
    press(game, "a")
    assert wait_for(game, lambda: game.r8("wTalkState") == TS_WAIT)
    assert game.r8("wTalkPhase") == TPH_OBS, "no observation page on turn 1"
    text = flow_text(game)
    assert any(w in text for w in HURT_WORDS), \
        f"low-HP observation isn't from the HURT bank: '{text}'"
    assert game.r8("wCtxUsed") & 1, "CTX_HURT not marked used"
    press(game, "b")
    game.pyboy.memory[game.addr("wHP")] = 100


def test_observation_names_equipped_weapon(game):
    """With full meters and a bat equipped, the NPC's remark must splice the
    actual item name out of the inventory (CTRL_ITEM)."""
    ITEM_BAT = 1
    goto_npc0(game)
    game.pyboy.memory[game.addr("wPartyEquip")] = ITEM_BAT
    start_talk(game)
    assert wait_for(game, lambda: game.r8("wTalkState") == TS_WAIT)
    press(game, "a")
    assert wait_for(game, lambda: game.r8("wTalkState") == TS_WAIT)
    assert game.r8("wTalkPhase") == TPH_OBS, "no observation page on turn 1"
    text = flow_text(game)
    assert "BAT" in text, f"weapon remark doesn't name the BAT: '{text}'"
    assert_text_sane(game)
    press(game, "b")
    game.pyboy.memory[game.addr("wPartyEquip")] = 0


def test_three_nice_rounds_reach_reward(game):
    goto_npc0(game)
    outcome = run_conversation(game, [T_NICE] * 3)
    assert outcome == OUTCOME_REWARD
    assert npc_affin(game) == 128 + 3 * expected_delta(T_NICE)  # 155


def test_three_flirt_rounds_pick_a_fight(game):
    goto_npc0(game)
    outcome = run_conversation(game, [T_FLIRT] * 3)
    assert outcome == OUTCOME_FIGHT
    assert npc_affin(game) == 128 + 3 * expected_delta(T_FLIRT)  # 80
    # placeholder scuffle flash ran; the survivor stays (real combat LATER)
    assert game.r8(game.addr("wNPCs")) == 1, "NPC should survive the flash"


def test_mixed_rounds_part_ways(game):
    goto_npc0(game)
    outcome = run_conversation(game, [T_NICE, T_RUDE, T_NICE])  # +9 -1 +9 = 145
    assert outcome == OUTCOME_PART
    assert game.r8("wGameMode") == MODE_OVERWORLD


# --- memory safety ------------------------------------------------------------

def test_talk_under_poisoned_boot():
    """Boot-hygiene for the whole talk path: none of it may depend on zeroed
    RAM/VRAM (PyBoy zeroes; hardware doesn't — see test_boot_hygiene)."""
    g = Game(poison=0xA5)
    try:
        goto_npc0(g)
        start_talk(g)
        assert wait_for(g, lambda: g.r8("wTalkState") == TS_WAIT)
        assert_text_sane(g)
        advance_to_menu(g)
        force_pick(g, T_NICE)
        assert npc_affin(g) == 128 + expected_delta(T_NICE)
    finally:
        g.close()


def test_many_conversations_never_breach_the_guard(game):
    """Hammer the composer across rounds/moods/phases; the canary must survive
    (FlushWord's bounds check is the only thing standing between a long
    generated line and the memory after the grid)."""
    goto_npc0(game)
    for tone_ids in ([T_RUDE] * 3, [T_GRIM] * 3, [T_NICE, T_FLIRT, T_JOKE]):
        run_conversation(game, tone_ids)
        assert game.r8("wTalkGuard") == GUARD
