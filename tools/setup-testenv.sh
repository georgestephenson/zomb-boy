#!/usr/bin/env bash
#
# setup-testenv.sh — create the pinned Python venv used by the headless
# integration tests (PyBoy + pytest). Lives in .tools/venv (gitignored), so it's
# a repo-local dev dependency like the toolchain.
#
# Usage: tools/setup-testenv.sh <venv-dir>
set -euo pipefail

VENV="${1:?usage: setup-testenv.sh <venv-dir>}"

command -v python3 >/dev/null || { echo "error: python3 not found" >&2; exit 1; }

if [ ! -x "$VENV/bin/python" ]; then
    echo ">> creating venv at $VENV"
    python3 -m venv "$VENV"
fi

echo ">> installing pinned test dependencies"
"$VENV/bin/pip" install --quiet --upgrade pip
# Pinned so tests are reproducible. PyBoy is a scriptable headless GB/GBC
# emulator; it drives the ROM and lets tests read memory/OAM/framebuffer.
"$VENV/bin/pip" install --quiet \
    "pyboy==2.7.0" \
    "pytest==9.1.1" \
    "pillow==12.3.0" \
    "numpy==2.5.1"

echo ">> test env ready ($("$VENV/bin/python" --version))"
