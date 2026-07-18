#!/usr/bin/env bash
#
# fetch-emulator.sh — download a pinned Mesen2 emulator into the repo.
#
# Mesen2 is open source (GPLv3) and its Linux build is a single self-contained
# native ELF, so we can vendor it as a pinned dev-dependency just like RGBDS.
# It serves double duty: an interactive GUI to *play* the ROM, and a Lua-
# scriptable core for the headless memory-safety tests described in
# docs/design/06-testing-and-memory-safety.md.
#
# Usage: tools/fetch-emulator.sh <version> <dest-dir>
#   e.g. tools/fetch-emulator.sh 2.1.1 .tools/emulator
set -euo pipefail

VERSION="${1:?usage: fetch-emulator.sh <version> <dest-dir>}"
DEST="${2:?usage: fetch-emulator.sh <version> <dest-dir>}"

# --- Pinned artifact --------------------------------------------------------
# Linux x86_64 only (this repo's build host). The zip contains a single `Mesen`
# ELF binary. To support ARM64, add its asset name + sha256 and a uname branch.
ASSET="Mesen_${VERSION}_Linux_x64.zip"
SHA256="7a9947575cc198209f743fef83fb2b702b786ea705506bdf3f2aea01ab7c1ce9"
URL="https://github.com/SourMesen/Mesen2/releases/download/${VERSION}/${ASSET}"

# --- Sanity checks ----------------------------------------------------------
if [ "$(uname -s)" != "Linux" ] || [ "$(uname -m)" != "x86_64" ]; then
    echo "error: pinned Mesen2 is Linux x86_64 only (host is $(uname -s)/$(uname -m))." >&2
    echo "       Install any GB/GBC emulator and run: make run EMULATOR=/path/to/it" >&2
    exit 1
fi

for tool in curl sha256sum unzip; do
    command -v "$tool" >/dev/null || { echo "error: $tool not found" >&2; exit 1; }
done

mkdir -p "$DEST"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo ">> fetching Mesen2 $VERSION ($ASSET, ~38 MB)"
curl -fsSL "$URL" -o "$tmp/$ASSET"

echo ">> verifying checksum"
echo "$SHA256  $tmp/$ASSET" | sha256sum -c - >/dev/null || {
    echo "error: checksum mismatch for $ASSET — refusing to install." >&2
    echo "       expected $SHA256" >&2
    echo "       got      $(sha256sum "$tmp/$ASSET" | cut -d' ' -f1)" >&2
    exit 1
}

echo ">> extracting into $DEST"
unzip -oq "$tmp/$ASSET" -d "$DEST"
chmod +x "$DEST/Mesen"
echo "$VERSION" > "$DEST/.version"

echo ">> Mesen2 $VERSION ready at $DEST/Mesen"
