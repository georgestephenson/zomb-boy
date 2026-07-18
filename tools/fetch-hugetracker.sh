#!/usr/bin/env bash
#
# fetch-hugetracker.sh — download a pinned hUGETracker into the repo.
#
# hUGETracker is the GUI music tracker you compose in; it exports songs in
# "RGBDS .asm" format that our vendored hUGEDriver (vendor/hUGEDriver/) plays.
# It is a *dev tool*, not a build input — the ROM builds fine without it — so,
# like the emulator, we vendor it as a pinned, checksum-verified dependency in
# .tools/ (gitignored) rather than committing it. Run `make hugetracker`, then
# launch it to author/export tunes; drop the exported .asm into
# vendor/hUGEDriver/songs/ (see that dir's PROVENANCE.md).
#
# hUGETracker (and hUGEDriver) are dedicated to the public domain.
#
# Usage: tools/fetch-hugetracker.sh <version> <dest-dir>
#   e.g. tools/fetch-hugetracker.sh 1.0.11 .tools/hugetracker
set -euo pipefail

VERSION="${1:?usage: fetch-hugetracker.sh <version> <dest-dir>}"
DEST="${2:?usage: fetch-hugetracker.sh <version> <dest-dir>}"

# --- Pinned artifact --------------------------------------------------------
# Linux x86_64 only (this repo's build host). The release ships a plain zip
# (Lazarus/FPC GTK2 build), not an AppImage. To support another platform, add
# its asset name + sha256 below and a uname branch.
ASSET="hUGETracker-${VERSION}-linux.zip"
SHA256="9e2e21d50d2ebbeb5653168c483279b188ff1b01b908b685172b0b353e506e24"
URL="https://github.com/SuperDisk/hUGETracker/releases/download/v${VERSION}/${ASSET}"

# --- Sanity checks ----------------------------------------------------------
if [ "$(uname -s)" != "Linux" ] || [ "$(uname -m)" != "x86_64" ]; then
    echo "error: pinned hUGETracker is Linux x86_64 only (host is $(uname -s)/$(uname -m))." >&2
    echo "       Grab it yourself from https://github.com/SuperDisk/hUGETracker/releases" >&2
    exit 1
fi

for tool in curl sha256sum unzip; do
    command -v "$tool" >/dev/null || { echo "error: $tool not found" >&2; exit 1; }
done

# Start from a clean dir (also clears any previous vendored tracker version).
rm -rf "$DEST"
mkdir -p "$DEST"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo ">> fetching hUGETracker $VERSION ($ASSET, ~4.6 MB)"
curl -fsSL "$URL" -o "$tmp/$ASSET"

echo ">> verifying checksum"
echo "$SHA256  $tmp/$ASSET" | sha256sum -c - >/dev/null || {
    echo "error: checksum mismatch for $ASSET — refusing to install." >&2
    echo "       expected $SHA256" >&2
    echo "       got      $(sha256sum "$tmp/$ASSET" | cut -d' ' -f1)" >&2
    exit 1
}

echo ">> extracting into $DEST"
unzip -q "$tmp/$ASSET" -d "$DEST"

# Locate the runnable binary (release layout has occasionally shifted); the
# executable is named 'hUGETracker' somewhere under the extracted tree.
BIN="$(find "$DEST" -maxdepth 3 -type f -name 'hUGETracker' | head -1 || true)"
if [ -n "$BIN" ]; then
    chmod +x "$BIN"
    echo "$VERSION" > "$DEST/.version"
    echo ">> hUGETracker $VERSION ready — launch with: $BIN"
else
    echo "warn: extracted hUGETracker but couldn't find a 'hUGETracker' binary." >&2
    echo "      Look under $DEST and run it manually." >&2
    echo "$VERSION" > "$DEST/.version"
fi
