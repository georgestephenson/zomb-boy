#!/usr/bin/env bash
#
# fetch-hardware-inc.sh — vendor gbdev's hardware.inc at a pinned commit.
#
# hardware.inc is the community-standard set of GB/GBC hardware register
# definitions (rP1, rLCDC, rSTAT, ...). RGBDS no longer bundles it, so we pin
# it here just like the toolchain itself.
#
# Usage: tools/fetch-hardware-inc.sh <git-ref> <dest-file>
set -euo pipefail

REF="${1:?usage: fetch-hardware-inc.sh <git-ref> <dest-file>}"
DEST="${2:?usage: fetch-hardware-inc.sh <git-ref> <dest-file>}"

URL="https://raw.githubusercontent.com/gbdev/hardware.inc/${REF}/hardware.inc"

command -v curl >/dev/null || { echo "error: curl not found" >&2; exit 1; }

mkdir -p "$(dirname "$DEST")"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

echo ">> fetching hardware.inc @ ${REF}"
curl -fsSL "$URL" -o "$tmp"

# Note: we verify by ref (pinned tag/commit) rather than a hardcoded hash here,
# since the file is small and human-auditable. Print its hash for the record.
echo ">> hardware.inc sha256: $(sha256sum "$tmp" | cut -d' ' -f1)"

mv "$tmp" "$DEST"
trap - EXIT
echo ">> hardware.inc ready at $DEST"
