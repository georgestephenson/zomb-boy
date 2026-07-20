#!/usr/bin/env python3
"""romstats.py — per-bank ROM/RAM utilization report from the rgblink .map file.

The fixed ROM0 bank is chronically near-full in this project, so "how many
bytes are left, and what's eating them" is a question we answer constantly.
This parses build/zombboy.map (written on every `make`) and prints:

  * a per-bank table: used / free / % full for every ROM, SRAM, WRAM and HRAM
    bank the linker placed sections in, and
  * the largest sections per ROM bank (the "what's eating it" half).

Usage:
  python3 tools/romstats.py [--map build/zombboy.map] [--top N]
                            [--markdown] [--min-rom0-free BYTES]

  --markdown          GitHub-flavoured table (for $GITHUB_STEP_SUMMARY in CI).
  --min-rom0-free N   Exit 1 if ROM0 has fewer than N bytes free (budget gate).

No dependencies beyond the stdlib, so it runs with any python3 — no venv needed.
"""
import argparse
import re
import sys
from collections import OrderedDict

BANK_RE = re.compile(r"^(\w+) bank #(\d+):")
SECT_RE = re.compile(r'^\s*SECTION: \$([0-9a-f]+)-\$([0-9a-f]+) \(\$([0-9a-f]+) bytes\) \["(.+)"\]')
EMPTY_RE = re.compile(r"^\s*TOTAL EMPTY: \$([0-9a-f]+) bytes")
# A bank with zero empty bytes gets no TOTAL EMPTY line; a bank that is one
# giant EMPTY run gets no SECTION lines. Both parse fine below.


def parse_map(path):
    """-> OrderedDict[(region, bank)] = {"sections": [(name, size)], "free": int}"""
    banks = OrderedDict()
    cur = None
    with open(path) as f:
        for line in f:
            m = BANK_RE.match(line)
            if m:
                cur = banks.setdefault((m.group(1), int(m.group(2))),
                                       {"sections": [], "free": 0})
                continue
            if cur is None:
                continue
            m = SECT_RE.match(line)
            if m:
                cur["sections"].append((m.group(4), int(m.group(3), 16)))
                continue
            m = EMPTY_RE.match(line)
            if m:
                cur["free"] = int(m.group(1), 16)
                cur = None  # TOTAL EMPTY is the last line of a bank block
    return banks


def rows(banks):
    for (region, bank), info in banks.items():
        used = sum(s for _, s in info["sections"])
        free = info["free"]
        total = used + free
        pct = 100.0 * used / total if total else 0.0
        yield region, bank, used, free, total, pct, info["sections"]


def bar(pct, width=20):
    fill = int(round(pct / 100 * width))
    return "#" * fill + "." * (width - fill)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--map", default="build/zombboy.map")
    ap.add_argument("--top", type=int, default=5,
                    help="largest sections listed per ROM bank (0 = none)")
    ap.add_argument("--markdown", action="store_true")
    ap.add_argument("--min-rom0-free", type=int, default=0, metavar="BYTES")
    args = ap.parse_args()

    try:
        banks = parse_map(args.map)
    except FileNotFoundError:
        sys.exit(f"error: {args.map} not found — run `make` first.")
    if not banks:
        sys.exit(f"error: no banks parsed from {args.map} (format change?).")

    rom0_free = None
    if args.markdown:
        print("### ROM/RAM bank utilization\n")
        print("| Bank | Used | Free | Size | Full |")
        print("|------|-----:|-----:|-----:|-----:|")
    for region, bank, used, free, total, pct, sections in rows(banks):
        name = region if region in ("ROM0", "HRAM") else f"{region}[{bank}]"
        if region == "ROM0":
            rom0_free = free
        if args.markdown:
            print(f"| {name} | {used} | {free} | {total} | {pct:.1f}% |")
        else:
            print(f"{name:9} {used:6} used {free:6} free / {total:6}  "
                  f"[{bar(pct)}] {pct:5.1f}%")

    if args.top:
        print()
        for region, bank, used, free, total, pct, sections in rows(banks):
            if region not in ("ROM0", "ROMX") or not sections:
                continue
            name = region if region == "ROM0" else f"{region}[{bank}]"
            biggest = sorted(sections, key=lambda s: -s[1])[:args.top]
            if args.markdown:
                items = ", ".join(f"`{n}` {s}B" for n, s in biggest)
                print(f"- **{name}** largest: {items}")
            else:
                items = ", ".join(f"{n} {s}B" for n, s in biggest)
                print(f"{name:9} largest: {items}")

    if args.min_rom0_free and rom0_free is not None and rom0_free < args.min_rom0_free:
        print(f"\nerror: ROM0 has {rom0_free} bytes free "
              f"(< budget floor {args.min_rom0_free}).", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
