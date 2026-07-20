#!/usr/bin/env bash
#
# fetch-rgbds.sh — install a pinned RGBDS toolchain into the repo.
#
# This is the repo's equivalent of installing a pinned dev-dependency. The happy
# path fetches a specific RGBDS *release binary* and verifies its checksum, then
# extracts into .tools/rgbds/ (gitignored). The Makefile calls this automatically,
# so `make` "just works" on a fresh clone.
#
# FALLBACK: some sandboxed/CI environments (e.g. Claude's hosted sessions) block
# GitHub *release-asset* downloads at the egress policy (HTTP 403) while still
# allowing `git clone`. If the binary download or checksum fails, we fall back to
# cloning the pinned tag and building RGBDS from source. That keeps the fast,
# checksum-verified path for normal machines/CI and keeps `make` unattended-green
# where downloads are blocked. Set RGBDS_FROM_SOURCE=1 to force the source build.
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
REPO="https://github.com/gbdev/rgbds.git"          # source-build fallback (git clone)
BINS=(rgbasm rgblink rgbfix rgbgfx)

# --- Sanity checks ----------------------------------------------------------
if [ "$(uname -s)" != "Linux" ] || [ "$(uname -m)" != "x86_64" ]; then
    echo "error: pinned RGBDS is Linux x86_64 only (host is $(uname -s)/$(uname -m))." >&2
    echo "       Install RGBDS $VERSION yourself and set RGBDS=/path in the Makefile." >&2
    exit 1
fi

command -v curl      >/dev/null || { echo "error: curl not found"      >&2; exit 1; }
command -v sha256sum >/dev/null || { echo "error: sha256sum not found" >&2; exit 1; }

mkdir -p "$DEST"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# stamp_version: record what we installed so the Makefile can detect drift.
stamp_version() { echo "$VERSION" > "$DEST/.version"; }

# fetch_prebuilt: the fast path — download the release binary + verify checksum.
# Returns non-zero (without aborting the script) if the download or checksum
# fails, so the caller can fall back to a source build.
fetch_prebuilt() {
    echo ">> fetching RGBDS $VERSION ($ASSET)"
    curl -fsSL "$URL" -o "$tmp/$ASSET" || return 1
    echo ">> verifying checksum"
    echo "$SHA256  $tmp/$ASSET" | sha256sum -c - >/dev/null 2>&1 || {
        echo "error: checksum mismatch for $ASSET — refusing to install it." >&2
        echo "       expected $SHA256" >&2
        echo "       got      $(sha256sum "$tmp/$ASSET" | cut -d' ' -f1)" >&2
        return 1
    }
    echo ">> extracting into $DEST"
    tar -xJf "$tmp/$ASSET" -C "$DEST"
    chmod +x "${BINS[@]/#/$DEST/}"
    stamp_version
    echo ">> RGBDS $VERSION ready in $DEST (prebuilt, checksum-verified)"
}

# build_from_source: the fallback — clone the pinned tag over `git` (which stays
# reachable where release-asset downloads are blocked) and compile. Pinned by tag
# rather than by binary checksum; the RGBDS build needs a C toolchain plus bison,
# libpng-dev and pkg-config.
build_from_source() {
    echo ">> falling back to a source build of RGBDS $VERSION (git clone)"
    for t in git make cc bison; do
        command -v "$t" >/dev/null || {
            echo "error: source build needs '$t' — install it (build-essential," >&2
            echo "       bison, libpng-dev, pkg-config) or provide RGBDS another way." >&2
            return 1
        }
    done
    git clone --depth 1 --branch "v${VERSION}" "$REPO" "$tmp/src" || {
        echo "error: git clone of RGBDS v${VERSION} failed." >&2
        return 1
    }
    echo ">> compiling (this takes a moment)"
    make -C "$tmp/src" -j"$(nproc 2>/dev/null || echo 2)" >/dev/null || {
        echo "error: RGBDS source build failed (missing build deps?)." >&2
        return 1
    }
    for b in "${BINS[@]}"; do
        cp "$tmp/src/$b" "$DEST/$b"
        chmod +x "$DEST/$b"
    done
    stamp_version
    echo ">> RGBDS $VERSION ready in $DEST (built from source at tag v${VERSION})"
}

# --- Install ----------------------------------------------------------------
if [ "${RGBDS_FROM_SOURCE:-0}" = "1" ]; then
    build_from_source
elif ! fetch_prebuilt; then
    echo ">> prebuilt fetch failed (blocked download or checksum) — trying source" >&2
    build_from_source
fi
