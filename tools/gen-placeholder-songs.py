#!/usr/bin/env python3
"""gen-placeholder-songs.py — derive distinct placeholder songs from the demo.

We have exactly one composed, format-correct hUGEDriver song (the vendored demo,
song_demo.asm). The music design wants a different track per screen (title, the
eight world biomes, each persona's dialogue), and we want the ROM to actually
*reserve the memory* those distinct songs will need — one full song per ROM bank
— rather than every slot secretly sharing one asset.

Since the sandbox can't fetch more sample tunes (the hUGETracker bundle is a
blocked GitHub release asset, and its other samples are .uge tracker projects
that need the GUI to export), and any song from elsewhere would have to match
our pinned 1.0.11 song-data format exactly, the safe way to get MORE valid,
distinct songs is to transform the one we have: transpose its notes and change
its tempo. The result is guaranteed format-correct (same driver contract),
sounds audibly different, and occupies the same memory a real song will — so the
cartridge budget is honest.

These are still PLACEHOLDERS: drop a real composed tune over any songs/*.asm and
rebuild. Usage:  python3 tools/gen-placeholder-songs.py   (regenerates them all)
"""
import re
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
DEMO = ROOT / "vendor" / "hUGEDriver" / "songs" / "song_demo.asm"
INC = ROOT / "vendor" / "hUGEDriver" / "include" / "hUGE.inc"
# Generated into the (gitignored) build tree — these are build inputs derived
# from the committed demo, not source to check in. The Makefile assembles them.
OUT = ROOT / "build" / "gen" / "songs"

# Each variant: (song label suffix, human note, ticks/row tempo, semitone shift).
# Tempo + transpose together make each placeholder clearly distinct by ear while
# staying valid. Repoint MusicTracks (src/audio.asm) at these; see that table.
# Keep this list in sync with PLACEHOLDER_SONGS in the Makefile.
VARIANTS = [
    ("urban", "world: city / ruins — brisk, mid-bright",  2, +2),
    ("open",  "world: plains / farm — bright, airy",      2, +7),
    ("green", "world: forest / jungle — warm mid",        2, +4),
    ("wet",   "world: marsh — lower, slower",             3, -3),
    ("eerie", "world: graveyard — low and slow",          3, -9),
    ("arid",  "world: desert — thin, high",               2, +9),
    ("cold",  "world: tundra — sparse, low",              4, -7),
    ("talk",  "dialogue — mellow, mid-low",               3, -5),
]

NOTE_MIN, NOTE_MAX = 0, 71          # C_3 .. B_8 (LAST_NOTE = 72 is out of range)
NO_NOTES = {"___", "NO_NOTE"}       # rows with no note trigger — never transposed


def load_note_maps():
    """name<->value from hUGE.inc's `DEF C_3 EQU 0` note constants (value < 72)."""
    name2val, val2name = {}, {}
    for line in INC.read_text().splitlines():
        m = re.match(r"\s*DEF\s+(\S+)\s+EQU\s+(\d+)\s*$", line)
        if not m:
            continue
        name, val = m.group(1), int(m.group(2))
        if val < 72 and re.match(r"^[A-G][_#]\d$", name):
            name2val[name] = val
            val2name.setdefault(val, name)   # first (sharp) spelling wins
    return name2val, val2name


def global_labels(text):
    """Every global label defined in the demo (`name:` / `name::`), longest first
    so the whole-word rewrite never clips a prefix (P1 inside P10, etc.)."""
    names = set(re.findall(r"^([A-Za-z_][A-Za-z0-9_]*)::?", text, re.MULTILINE))
    return sorted(names, key=len, reverse=True)


def transpose_line(line, shift, name2val, val2name):
    """Shift the note in a `dn NOTE,instr,effect` row by `shift` semitones."""
    m = re.match(r"^(\s*dn\s+)([A-G][_#]\d|\S+?)(,.*)$", line)
    if not m:
        return line
    head, note, tail = m.groups()
    if note in NO_NOTES or note not in name2val:
        return line
    val = max(NOTE_MIN, min(NOTE_MAX, name2val[note] + shift))
    return f"{head}{val2name[val]}{tail}"


def make_song(suffix, blurb, tempo, shift, name2val, val2name):
    text = DEMO.read_text()

    # 1) transpose every note row
    out = [transpose_line(ln, shift, name2val, val2name) for ln in text.splitlines()]
    text = "\n".join(out)

    # 2) rename every global label so the copy links beside the others.
    #    song_demo -> song_<suffix> (the exported entry); the rest get a prefix.
    for name in global_labels(text):
        if name == "song_demo":
            repl = f"song_{suffix}"
        else:
            repl = f"{suffix}_{name}"
        text = re.sub(rf"\b{re.escape(name)}\b", repl, text)

    # 3) unique SECTION name (the linker requires it) + the new tempo byte
    text = text.replace('SECTION "Song Data"', f'SECTION "Song Data {suffix}"', 1)
    text = re.sub(rf"(song_{suffix}::\s*\ndb )\d+", rf"\g<1>{tempo}", text, count=1)

    header = (
        f"; song_{suffix}.asm — GENERATED placeholder (tools/gen-placeholder-songs.py).\n"
        f"; A distinct-sounding derivative of the vendored demo song: {blurb}\n"
        f"; (tempo {tempo}, transposed {shift:+d} semitones). Same 1.0.11 song format,\n"
        f"; so it is guaranteed driver-compatible. Replace with a real composed tune\n"
        f"; when one exists — keep the `song_{suffix}::` label. DO NOT hand-edit.\n\n"
    )
    # keep the original's `include \"include/hUGE.inc\"`; strip its old comment head
    body = re.sub(r"\A(?:;.*\n)+\n?", "", text)
    (OUT / f"song_{suffix}.asm").write_text(header + body)
    print(f">> wrote {OUT.relative_to(ROOT)}/song_{suffix}.asm  (tempo {tempo}, transpose {shift:+d})")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    name2val, val2name = load_note_maps()
    for suffix, blurb, tempo, shift in VARIANTS:
        make_song(suffix, blurb, tempo, shift, name2val, val2name)


if __name__ == "__main__":
    main()
