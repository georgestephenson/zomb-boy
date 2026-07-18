#!/usr/bin/env bash
#
# fetch-rgbds.sh — download a pinned RGBDS toolchain into the repo.
#
# This is the repo's equivalent of installing a pinned dev-dependency: it
# fetches a specific RGBDS release, verifies its checksum, and extracts the
# binaries into .tools/rgbds/ (which is gitignored). The Makefile calls this
# automatically, so `make` "just works" on a fresh clone.
#
# Usage: tools/fetch-rgbds.sh <version> <dest-dir>
#   e.g. tools/fetch-rgbds.sh 1.0.1 .tools/rgbds
#
set -euo pipefail

VERSION="${1:?usage: fetch-rgbds.sh <version> <dest-dir>}"
DEST="${2:?usage: fetch-rgbds.sh <version> <dest-dir>}"

# --- Pinned artifacts -------------------------------------------------------
# Only Linux x86_64 is pinned here because that's this repo's build host.
# To support another platform, add its asset name + sha256 below.
ASSET="rgbds-linux-x86_64.tar.xz"
SHA256="80a5cad8dae27e24e46a93041352c47cadbc165103983f41c2b3082c42f6dad9"
URL="https://github.com/gbdev/rgbds/releases/download/v${VERSION}/${ASSET}"

# --- Sanity checks ----------------------------------------------------------
if [ "$(uname -s)" != "Linux" ] || [ "$(uname -m)" != "x86_64" ]; then
    echo "error: pinned RGBDS is Linux x86_64 only (host is $(uname -s)/$(uname -m))." >&2
    echo "       Install RGBDS $VERSION yourself and set RGBDS=/path in the Makefile." >&2
    exit 1
fi

command -v curl    >/dev/null || { echo "error: curl not found"    >&2; exit 1; }
command -v sha256sum >/dev/null || { echo "error: sha256sum not found" >&2; exit 1; }

mkdir -p "$DEST"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo ">> fetching RGBDS $VERSION ($ASSET)"
curl -fsSL "$URL" -o "$tmp/$ASSET"

echo ">> verifying checksum"
echo "$SHA256  $tmp/$ASSET" | sha256sum -c - >/dev/null || {
    echo "error: checksum mismatch for $ASSET — refusing to install." >&2
    echo "       expected $SHA256" >&2
    echo "       got      $(sha256sum "$tmp/$ASSET" | cut -d' ' -f1)" >&2
    exit 1
}

echo ">> extracting into $DEST"
tar -xJf "$tmp/$ASSET" -C "$DEST"
chmod +x "$DEST"/rgbasm "$DEST"/rgblink "$DEST"/rgbfix "$DEST"/rgbgfx

# Stamp the installed version so the Makefile can detect drift.
echo "$VERSION" > "$DEST/.version"

echo ">> RGBDS $VERSION ready in $DEST"
