#!/usr/bin/env bash
#
# fetch-emulator.sh — download a pinned mGBA emulator into the repo.
#
# mGBA is open source (MPL 2.0) and ships a distro-independent AppImage. We
# vendor it as a pinned dev-dependency just like RGBDS. Because the AppImage
# needs libfuse2 at runtime (absent on newer distros like Ubuntu 26.04, which
# ship FUSE 3), we *extract* it at fetch time and run the unpacked AppRun — no
# FUSE required to play the ROM.
#
# (We previously tried Mesen2, but its settings-parsing std::regex path throws
#  std::bad_cast against very new libstdc++ builds — unusable on Ubuntu 26.04.
#  mGBA's AppImage bundles its own libs and sidesteps that entirely.)
#
# Usage: tools/fetch-emulator.sh <version> <dest-dir>
#   e.g. tools/fetch-emulator.sh 0.10.5 .tools/emulator
set -euo pipefail

VERSION="${1:?usage: fetch-emulator.sh <version> <dest-dir>}"
DEST="${2:?usage: fetch-emulator.sh <version> <dest-dir>}"

# --- Pinned artifact --------------------------------------------------------
# Linux x86_64 only (this repo's build host). To support ARM64, add its asset
# name + sha256 and a uname branch.
ASSET="mGBA-${VERSION}-appimage-x64.appimage"
SHA256="fdf0a5c1588e1606c38315735cf48a9f9dca3573f32a3947ebc956f8297e85cd"
URL="https://github.com/mgba-emu/mgba/releases/download/${VERSION}/${ASSET}"

# --- Sanity checks ----------------------------------------------------------
if [ "$(uname -s)" != "Linux" ] || [ "$(uname -m)" != "x86_64" ]; then
    echo "error: pinned mGBA is Linux x86_64 only (host is $(uname -s)/$(uname -m))." >&2
    echo "       Install any GB/GBC emulator and run: make run EMULATOR=/path/to/it" >&2
    exit 1
fi

for tool in curl sha256sum; do
    command -v "$tool" >/dev/null || { echo "error: $tool not found" >&2; exit 1; }
done

# Start from a clean emulator dir (also clears any previous vendored emulator).
rm -rf "$DEST"
mkdir -p "$DEST"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo ">> fetching mGBA $VERSION ($ASSET, ~25 MB)"
curl -fsSL "$URL" -o "$tmp/$ASSET"

echo ">> verifying checksum"
echo "$SHA256  $tmp/$ASSET" | sha256sum -c - >/dev/null || {
    echo "error: checksum mismatch for $ASSET — refusing to install." >&2
    echo "       expected $SHA256" >&2
    echo "       got      $(sha256sum "$tmp/$ASSET" | cut -d' ' -f1)" >&2
    exit 1
}

echo ">> extracting AppImage (avoids the libfuse2 runtime dependency)"
chmod +x "$tmp/$ASSET"
# --appimage-extract unpacks into ./squashfs-root in the current dir.
( cd "$DEST" && "$tmp/$ASSET" --appimage-extract >/dev/null )

APPRUN="$DEST/squashfs-root/AppRun"
[ -x "$APPRUN" ] || { echo "error: expected runnable $APPRUN after extraction" >&2; exit 1; }
echo "$VERSION" > "$DEST/.version"

echo ">> mGBA $VERSION ready at $APPRUN"
