#!/usr/bin/env bash
#
# fetch-sameboy.sh — build the pinned SameBoy *tester* into the repo.
#
# SameBoy is the community's accuracy-reference GB/GBC emulator (passes the
# full blargg/mooneye suites); its Tester target is a headless CLI that boots a
# ROM for N emulated seconds, auto-presses START/A, screenshots the end state,
# and writes a .log ONLY when it detects a failure (deadlock, stack overflow,
# FF-loop, blank screen, boot ROM never finishing). We use it as a second-
# emulator smoke gate beside PyBoy — crucially it CAN run our CGB-flagged ROM
# in true DMG mode, which PyBoy cannot.
#
# SameBoy ships no Linux release binaries, so this is always a source build
# (git clone of the pinned tag — reachable even where GitHub release-asset
# downloads are blocked). The build needs: git, make, cc, and RGBDS on PATH
# (for SameBoy's boot ROMs) — we pass our own pinned RGBDS in.
#
# Usage: tools/fetch-sameboy.sh <version> <dest-dir> <rgbds-dir>
#   e.g. tools/fetch-sameboy.sh 1.0.3 .tools/sameboy .tools/rgbds
#
set -euo pipefail

VERSION="${1:?usage: fetch-sameboy.sh <version> <dest-dir> <rgbds-dir>}"
DEST="${2:?usage: fetch-sameboy.sh <version> <dest-dir> <rgbds-dir>}"
RGBDS_DIR="${3:?usage: fetch-sameboy.sh <version> <dest-dir> <rgbds-dir>}"

REPO="https://github.com/LIJI32/SameBoy.git"

for t in git make cc; do
    command -v "$t" >/dev/null || { echo "error: SameBoy build needs '$t'" >&2; exit 1; }
done
[ -x "$RGBDS_DIR/rgbasm" ] || {
    echo "error: RGBDS not found at $RGBDS_DIR (SameBoy's boot ROMs need it)" >&2
    echo "       run 'make tools' first." >&2
    exit 1
}

RGBDS_ABS="$(cd "$RGBDS_DIR" && pwd)"
mkdir -p "$DEST"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo ">> cloning SameBoy v${VERSION}"
git clone --depth 1 --branch "v${VERSION}" "$REPO" "$tmp/src"

echo ">> building the tester (this takes a minute)"
PATH="$RGBDS_ABS:$PATH" make -C "$tmp/src" tester CONF=release \
    -j"$(nproc 2>/dev/null || echo 2)" >/dev/null

# The tester binary plus the boot ROMs it loads from its own directory.
cp "$tmp/src"/build/bin/tester/* "$DEST/"
chmod +x "$DEST/sameboy_tester"
echo "$VERSION" > "$DEST/.version"
echo ">> SameBoy tester $VERSION ready in $DEST"
