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
# numpy needs a per-interpreter pin: 2.5.x dropped Python <3.12, and hosted
# CI/agent images still ship 3.11 — both pins are exact, just keyed on the
# interpreter, so runs stay reproducible either way.
"$VENV/bin/pip" install --quiet \
    "pyboy==2.7.0" \
    "pytest==9.1.1" \
    "pytest-xdist==3.8.0" \
    "pillow==12.3.0" \
    "numpy==2.5.1; python_version >= '3.12'" \
    "numpy==2.2.6; python_version < '3.12'"

# Prove the env actually works before declaring it ready — a partial install
# (e.g. a pin that doesn't resolve on this interpreter) must not leave a venv
# that run-tests.sh would mistake for a good one.
"$VENV/bin/python" - <<'EOF'
import pytest, PIL, numpy
from pyboy import PyBoy
print(f">> test env ready (numpy {numpy.__version__}, pytest {pytest.__version__})")
EOF
touch "$VENV/.ok"
