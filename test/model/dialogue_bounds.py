#!/usr/bin/env python3
"""Exhaustive bounds check of the dialogue grammar — against the BUILT ROM.

Unlike worldgen_model.py (a lockstep re-implementation), this reads the real
word banks out of build/zombboy.gbc via the .sym file, so the data can never
drift from what's checked. It then simulates the composer's exact tokenising +
greedy wrap (dialogue.asm: EmitFrag/FlushWord) over EVERY reachable sentence:

    greeting/prompt = opener-or-continuation(mood) + topic(persona)
    observation     = one line from the PERSONA'S OWN context banks (PO_CTX
                      entries 0..7, indexed by CTX_*; CTRL_ITEM = an item name)
    question        = the turn's last beat: the persona's FOLLOW-UP bank for
                      the observed context (PO_CTX entries 8..15), or a
                      generic persona question on turns with no observation
    react           = bucket quip + tone tag (liked/disliked by delta sign)
    outcome         = one closing fragment

Topics may reference the conversation SUBJECT (CTRL_SUBJ — one noun fixed per
conversation) and fresh nouns (CTRL_NOUN); adjective banks are the mood
shifted by the persona's T1 trait (TINT_THRESH), all mirrored here.

and asserts, per docs/design/05 §3 (string building is THE memory-safety
target):

  * every fragment byte is a mapped glyph or a known control code;
  * every fully-expanded token fits wWordBuf (WORD_MAX) — no silent truncation;
  * every composed line fits the 3x18 grid with zero dropped words;
  * nouns/adjectives are single words (no spaces — they glue into tokens);
  * |dot(tone push, persona traits)| <= 127 (ComputeDelta's 8-bit accumulator);
  * persona OBJ palettes are valid (3..7 — tints may be shared);
  * tone labels fit a menu cell (<= 7 chars);
  * every persona is WINNABLE: some tone's delta >= +7, so three perfect
    replies clear AFFIN_REWARD from the neutral start (CLAUDE.md promise).

The wrap simulation must stay in lockstep with FlushWord if that ever changes.
"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ROM_PATH = os.path.join(ROOT, "build", "zombboy.gbc")
SYM_PATH = os.path.join(ROOT, "build", "zombboy.sym")

FONT_BASE = 128
CHARSET = " ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.,!?'-"
VALID_GLYPHS = set(range(FONT_BASE, FONT_BASE + len(CHARSET)))
CTRL_END, CTRL_NOUN, CTRL_ADJ, CTRL_SUBJ, CTRL_ITEM = 0, 1, 2, 3, 4
SLOT_CODES = (CTRL_NOUN, CTRL_ADJ, CTRL_SUBJ, CTRL_ITEM)
SPACE = FONT_BASE
TINT_THRESH = 17  # |T1| >= this shifts the adjective bank (dialogue.asm)

COLS, ROWS, WORD_MAX = 18, 3, 15
N_PERSONAS, N_MOODS, N_REACTS, N_OUTCOMES, N_TONES = 10, 3, 5, 3, 8
N_CTX, N_ITEMS = 8, 11
PERSONA_SIZE = 16
LABEL_MAX = 7           # menu cell width
WINNABLE_DELTA = 7      # 3 * this must clear AFFIN_REWARD - AFFIN_START (20)


def load_symbols():
    """RGBDS .sym -> {name: flat file offset} (32K ROM-only: offset == address)."""
    syms = {}
    with open(SYM_PATH) as f:
        for line in f:
            line = line.split(";", 1)[0].strip()
            if not line or ":" not in line:
                continue
            addr_part, _, name = line.partition(" ")
            try:
                bank, addr = addr_part.split(":")
                bank, addr = int(bank, 16), int(addr, 16)
            except ValueError:
                continue
            if addr < 0x8000:  # ROM only
                off = addr if addr < 0x4000 else bank * 0x4000 + (addr - 0x4000)
                syms[name.strip()] = off
    return syms


def le16(rom, off):
    return rom[off] | (rom[off + 1] << 8)


def cpu_to_off(addr):
    return addr  # flat 32K mapping (banks 0+1, no MBC)


def read_frag(rom, addr, what):
    off, out = cpu_to_off(addr), []
    for _ in range(64):
        b = rom[off]
        off += 1
        if b == CTRL_END:
            return out
        assert b in VALID_GLYPHS or b in SLOT_CODES, \
            f"{what}: invalid byte {b:#04x} at {addr:#06x}"
        out.append(b)
    raise AssertionError(f"{what}: unterminated fragment at {addr:#06x}")


def read_bank(rom, addr, what):
    off = cpu_to_off(addr)
    n = rom[off]
    assert 1 <= n <= 16, f"{what}: implausible bank count {n} at {addr:#06x}"
    return [read_frag(rom, le16(rom, off + 1 + 2 * i), f"{what}[{i}]")
            for i in range(n)]


def read_ptr_table(rom, addr, n, what):
    off = cpu_to_off(addr)
    return [le16(rom, off + 2 * i) for i in range(n)]


def decode(frag):
    return "".join(CHARSET[b - FONT_BASE] if b in VALID_GLYPHS else f"%{b}"
                   for b in frag)


def expand(frag, fills):
    """Composer semantics: chars glue into a token, SPACE flushes, slots splice
    the fill word into the current token. Returns the token list."""
    fills = list(fills)
    tokens, word = [], []
    for b in frag:
        if b in SLOT_CODES:
            word.extend(fills.pop(0))
        elif b == SPACE:
            if word:
                tokens.append(word)
                word = []
        else:
            word.append(b)
    if word:
        tokens.append(word)
    assert not fills, "slot/fill mismatch"
    return tokens


def wrap_fits(tokens):
    """Mirror of FlushWord's greedy wrap. Returns (fits, cells_used_row_count)."""
    col = row = 0
    for tok in tokens:
        if len(tok) > WORD_MAX:
            return False, f"token '{decode(tok)}' longer than WORD_MAX"
        if col > 0:
            if col + 1 + len(tok) > COLS:
                row += 1
                col = 0
            else:
                col += 1
        if row >= ROWS:
            return False, f"dropped '{decode(tok)}' (out of rows)"
        col += len(tok)
    return True, row + 1


def slot_kinds(frag):
    return [b for b in frag if b in SLOT_CODES]


def fill_choices(kinds, nouns, adjs, subject_idx=None, items=()):
    """All slot assignments. SUBJ slots always take the fixed subject noun;
    consecutive NOUN slots can't repeat (the wLastNoun guard re-rolls, matching
    PickNounFrag) — earlier-guard states are over-approximated as 'any noun'.
    ITEM slots expand over every possible item name (EmitItem)."""
    def rec(i, prev_noun, acc):
        if i == len(kinds):
            yield acc
            return
        kind = kinds[i]
        if kind == CTRL_ADJ:
            for a in adjs:
                yield from rec(i + 1, prev_noun, acc + [a])
        elif kind == CTRL_SUBJ:
            yield from rec(i + 1, prev_noun, acc + [nouns[subject_idx]])
        elif kind == CTRL_ITEM:
            for it in items:
                yield from rec(i + 1, prev_noun, acc + [it])
        else:
            for j, n in enumerate(nouns):
                if j == prev_noun and len(nouns) > 1:
                    continue
                yield from rec(i + 1, j, acc + [n])
    yield from rec(0, None, [])


def eff_mood(t1, mood):
    """Mirror of EmitAdj's trait tint: grim shifts one bank bleaker, hopeful
    one warmer, clamped to the 3 mood banks."""
    if t1 <= -TINT_THRESH:
        return max(0, mood - 1)
    if t1 >= TINT_THRESH:
        return min(2, mood + 1)
    return mood


def main() -> int:
    assert os.path.exists(ROM_PATH), f"ROM not built: {ROM_PATH} (run `make`)"
    rom = open(ROM_PATH, "rb").read()
    syms = load_symbols()

    # --- pull the data out of the ROM ---
    persona_base = syms["PersonaTable"]
    personas = []
    for i in range(N_PERSONAS):
        off = persona_base + i * PERSONA_SIZE
        name = read_frag(rom, le16(rom, off), f"name[{i}]")
        traits = [rom[off + 2 + k] for k in range(4)]
        traits = [t - 256 if t >= 128 else t for t in traits]
        nouns = read_bank(rom, le16(rom, off + 6), f"nouns[{i}]")
        topics = read_bank(rom, le16(rom, off + 8), f"topics[{i}]")
        pal = rom[off + 10]
        quests = read_bank(rom, le16(rom, off + 12), f"quests[{i}]")
        ctx_ptrs = read_ptr_table(rom, le16(rom, off + 14), N_CTX * 2,
                                  f"ctxtable[{i}]")
        ctx = [read_bank(rom, a, f"ctx[{i}][{c}]") for c, a in
               enumerate(ctx_ptrs[:N_CTX])]
        ctxq = [read_bank(rom, a, f"ctxq[{i}][{c}]") for c, a in
                enumerate(ctx_ptrs[N_CTX:])]
        personas.append((name, traits, nouns, topics, pal, quests, ctx, ctxq))

    openers = [read_bank(rom, a, f"openers[{m}]") for m, a in
               enumerate(read_ptr_table(rom, syms["OpenerMoods"], N_MOODS, "OpenerMoods"))]
    prompts = [read_bank(rom, a, f"prompts[{m}]") for m, a in
               enumerate(read_ptr_table(rom, syms["PromptMoods"], N_MOODS, "PromptMoods"))]
    adjs = [read_bank(rom, a, f"adjs[{m}]") for m, a in
            enumerate(read_ptr_table(rom, syms["AdjMoods"], N_MOODS, "AdjMoods"))]
    reacts = [read_bank(rom, a, f"reacts[{r}]") for r, a in
              enumerate(read_ptr_table(rom, syms["ReactBanks"], N_REACTS, "ReactBanks"))]
    outcomes = [read_bank(rom, a, f"outcomes[{o}]") for o, a in
                enumerate(read_ptr_table(rom, syms["OutcomeBanks"], N_OUTCOMES, "OutcomeBanks"))]
    tone_base = syms["ToneTable"]
    tones = []
    for t in range(N_TONES):
        rec = rom[tone_base + t * 6: tone_base + t * 6 + 5]
        push = [b - 256 if b >= 128 else b for b in rec[:4]]
        base = rec[4] - 256 if rec[4] >= 128 else rec[4]
        tones.append((push, base))
    label_banks = []  # [mood][tone] -> list of synonym fragments
    for m, ma in enumerate(read_ptr_table(rom, syms["ToneLabelMoods"], N_MOODS,
                                          "ToneLabelMoods")):
        label_banks.append([read_bank(rom, a, f"labels[m{m}][t{t}]") for t, a in
                            enumerate(read_ptr_table(rom, ma, N_TONES, f"labels[m{m}]"))])
    # Item names (items.asm): space-padded; EmitItem stops at the first pad
    # space, so the effective fill is the leading run of non-space glyphs.
    items = []
    for i, a in enumerate(read_ptr_table(rom, syms["ItemNames"], N_ITEMS, "ItemNames")):
        off = cpu_to_off(a)
        name = []
        while rom[off] != 0 and rom[off] != SPACE:
            name.append(rom[off])
            off += 1
        items.append(name)
    items = items[1:]  # id 0 is the "--------" empty marker, never equipped
    items.append(read_frag(rom, syms["FragBareHands"], "FragBareHands"))
    tags_liked = [read_bank(rom, a, f"tagL[{t}]") for t, a in
                  enumerate(read_ptr_table(rom, syms["ToneTagsLiked"], N_TONES, "ToneTagsLiked"))]
    tags_disliked = [read_bank(rom, a, f"tagD[{t}]") for t, a in
                     enumerate(read_ptr_table(rom, syms["ToneTagsDisliked"], N_TONES, "ToneTagsDisliked"))]

    ok, checked, max_rows = True, 0, 0

    def clamped_delta(push, base, traits):
        dot = sum(p * t for p, t in zip(push, traits))
        d = dot >> 2  # python >> is arithmetic, same as two SRAs
        return max(-16, min(16, d)) + base

    # --- static data rules ---
    for m, tone_table in enumerate(label_banks):
        for t, bank in enumerate(tone_table):
            for lbl in bank:
                if len(lbl) > LABEL_MAX or any(b not in VALID_GLYPHS for b in lbl):
                    print(f"FAIL: label m{m}/t{t} '{decode(lbl)}' too long or invalid")
                    ok = False
    QMARK = FONT_BASE + CHARSET.index("?")
    CTX_WEAPON = 3
    for i, (name, traits, nouns, topics, pal, quests, ctx, ctxq) in enumerate(personas):
        for q in quests:
            if q[-1] != QMARK:
                print(f"FAIL: persona {i} question '{decode(q)}' doesn't end in ?")
                ok = False
        for c, bank in enumerate(ctxq):
            for q in bank:
                if q[-1] != QMARK:
                    print(f"FAIL: persona {i} ctx follow-up '{decode(q)}' "
                          f"doesn't end in ?")
                    ok = False
        for line in ctx[CTX_WEAPON]:
            if CTRL_ITEM not in line:
                print(f"FAIL: persona {i} weapon remark '{decode(line)}' "
                      f"lacks CTRL_ITEM (must name the equipped item)")
                ok = False
        if not 3 <= pal <= 7:
            print(f"FAIL: persona {i} PO_PAL={pal} outside OBJ palettes 3..7")
            ok = False
        if len(name) > 16 or any(b not in VALID_GLYPHS for b in name):
            print(f"FAIL: persona {i} name bad: '{decode(name)}'")
            ok = False
        for bank, kind in ((nouns, "noun"),):
            for w in bank:
                if SPACE in w or slot_kinds(w):
                    print(f"FAIL: {kind} '{decode(w)}' isn't a single plain word")
                    ok = False
        for push, _base in tones:
            dot = sum(p * t for p, t in zip(push, traits))
            if abs(dot) > 127:
                print(f"FAIL: persona {i} x push {push}: |dot|={abs(dot)} > 127")
                ok = False
        best = max(clamped_delta(p, b, traits) for p, b in tones)
        if best < WINNABLE_DELTA:
            print(f"FAIL: persona {i} '{decode(name)}' unwinnable: "
                  f"best tone delta {best} < {WINNABLE_DELTA}")
            ok = False
    for m in range(N_MOODS):
        for w in adjs[m]:
            if SPACE in w or slot_kinds(w):
                print(f"FAIL: adjective '{decode(w)}' isn't a single plain word")
                ok = False

    # --- every composable line must fit the 3x18 grid ---
    def check_line(head, topic, nouns_b, adjs_b, what):
        nonlocal ok, checked, max_rows
        assert not slot_kinds(head), f"{what}: head fragments must be slot-free"
        kinds = slot_kinds(topic) if topic is not None else []
        subjects = range(len(nouns_b)) if CTRL_SUBJ in kinds else [None]
        for si in subjects:
            for fills in fill_choices(kinds, nouns_b, adjs_b, si, items):
                tokens = expand(head, [])
                if topic is not None:
                    tokens += expand(topic, fills)
                fits, info = wrap_fits(tokens)
                checked += 1
                if not fits:
                    text = " ".join(decode(t) for t in tokens)
                    print(f"FAIL: {what}: '{text}' -> {info}")
                    ok = False
                else:
                    max_rows = max(max_rows, info)

    # Line shapes as composed by dialogue.asm: greeting/prompt = head + topic
    # (adjectives from the trait-tinted mood bank); reaction = bucket quip +
    # tone tag matching the delta's sign; outcome fragments stand alone.
    for p, (name, traits, nouns_b, topics, _, quests, ctx, ctxq) in enumerate(personas):
        for m in range(N_MOODS):
            adjs_b = adjs[eff_mood(traits[1], m)]
            heads = [(h, f"greet p{p} m{m}") for h in openers[m]] + \
                    [(h, f"prompt p{p} m{m}") for h in prompts[m]]
            for head, what in heads:
                for topic in topics:
                    check_line(head, topic, nouns_b, adjs_b, what)
            # questions and context observations stand alone on their page
            for q in quests:
                check_line([], q, nouns_b, adjs_b, f"quest p{p} m{m}")
            for c, bank in enumerate(ctx):
                for line in bank:
                    check_line([], line, nouns_b, adjs_b, f"ctx p{p}[{c}] m{m}")
            for c, bank in enumerate(ctxq):
                for line in bank:
                    check_line([], line, nouns_b, adjs_b, f"ctxq p{p}[{c}] m{m}")
    for quips, tag_tables, pol in ((reacts[0] + reacts[1], tags_liked, "liked"),
                                   (reacts[3] + reacts[4], tags_disliked, "disliked")):
        for quip in quips:
            for bank in tag_tables:
                for tag in bank:
                    check_line(quip, tag, [], [], f"react {pol}")
    for quip in reacts[2]:
        check_line(quip, None, [], [], "react meh")
    for bank in outcomes:
        for frag in bank:
            check_line(frag, None, [], [], "outcome")

    print(f"Checked {checked} composed lines "
          f"(worst used {max_rows}/{ROWS} rows) against the built ROM")
    print("PASS: dialogue bounds checks passed" if ok else "FAILURES above")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
