#!/usr/bin/env bash
#
# smoke-sameboy.sh — boot the ROM in SameBoy (the accuracy-reference core) in
# BOTH console modes and fail on anything the tester flags.
#
# Why beside PyBoy: PyBoy is lenient (zeroed RAM, forgiving PPU timing) and
# cannot run a CGB-flagged ROM as a DMG at all. SameBoy is the strictest
# software emulator available, and --dmg exercises our real DMG fallback path
# (grayscale palettes, no double-speed, no attribute plane) headless — the
# closest thing to hardware verification without a flash cart.
#
# The tester auto-presses START+A (so it gets past the title into gameplay),
# runs SMOKE_SECS emulated seconds, and writes <rom>.log ONLY on a detected
# failure (deadlock, stack overflow, FF-loop, blank screen, boot ROM stuck).
# We fail on any log output, and belt-and-braces check the end-state
# screenshot isn't a near-solid frame.
#
# Usage: tools/smoke-sameboy.sh <rom> <tester-dir> <out-dir>
set -euo pipefail

ROM="${1:?usage: smoke-sameboy.sh <rom> <tester-dir> <out-dir>}"
TESTER_DIR="${2:?usage: smoke-sameboy.sh <rom> <tester-dir> <out-dir>}"
OUT="${3:?usage: smoke-sameboy.sh <rom> <tester-dir> <out-dir>}"

TESTER="$TESTER_DIR/sameboy_tester"
SMOKE_SECS="${SMOKE_SECS:-10}"

[ -x "$TESTER" ] || { echo "error: $TESTER not found — run 'make sameboy'." >&2; exit 1; }

mkdir -p "$OUT"
fail=0

for mode in cgb dmg; do
    # The tester writes zombboy.bmp/.log beside the ROM it was given, so give
    # it a per-mode copy inside the output dir.
    cp "$ROM" "$OUT/$mode.gbc"
    rm -f "$OUT/$mode.log" "$OUT/$mode.bmp"
    echo ">> SameBoy smoke: $mode mode, ${SMOKE_SECS}s emulated"
    "$TESTER" "--$mode" --start --length "$SMOKE_SECS" "$OUT/$mode.gbc"
    rm -f "$OUT/$mode.gbc"

    if [ -s "$OUT/$mode.log" ]; then
        echo "!! SameBoy flagged a failure in $mode mode:" >&2
        sed 's/^/   /' "$OUT/$mode.log" >&2
        fail=1
        continue
    fi
    # Screenshot sanity: a healthy in-game frame has at least a few distinct
    # colors (DMG = 4 shades); ~1 means the game died to a blank/solid screen.
    python3 - "$OUT/$mode.bmp" <<'EOF' || fail=1
import struct, sys
path = sys.argv[1]
data = open(path, "rb").read()
off = struct.unpack_from("<I", data, 10)[0]      # BITMAPFILEHEADER bfOffBits
pixels = {data[i:i+4] for i in range(off, len(data), 4)}
if len(pixels) < 3:
    sys.exit(f"error: {path} is a near-solid frame ({len(pixels)} colors) — "
             "the game likely crashed to a blank screen.")
print(f">>   ok: {path} ({len(pixels)} distinct colors)")
EOF
done

exit $fail
