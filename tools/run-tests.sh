#!/usr/bin/env bash
#
# run-tests.sh — the project test suite.
#
#   1. Host-side reference-model checks (pure generator logic, no emulator).
#   2. Headless integration tests: boot the built ROM in PyBoy and assert on
#      memory / OAM / the tilemap (see test/integration/ and
#      docs/design/06-testing-and-memory-safety.md).
#
# The ROM must already be built (the Makefile's `test` target depends on it).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENV="$ROOT/.tools/venv"
PY="$VENV/bin/python"

# Bootstrap the pinned Python test env on first run. The .ok sentinel is
# written only after setup-testenv.sh verifies the imports, so a half-created
# venv (interrupted or failed install) gets rebuilt instead of trusted.
if [ ! -x "$PY" ] || [ ! -f "$VENV/.ok" ]; then
    "$ROOT/tools/setup-testenv.sh" "$VENV"
fi

if [ ! -f "$ROOT/build/zombboy.gbc" ]; then
    echo "error: build/zombboy.gbc not found — run \`make\` first." >&2
    exit 1
fi

echo "== reference-model checks =="
"$PY" "$ROOT/test/model/worldgen_model.py"
"$PY" "$ROOT/test/model/dialogue_bounds.py"

echo
echo "== headless integration tests =="
# Every test boots its own PyBoy instance (function-scoped fixtures, no shared
# state), so they parallelize cleanly; -n auto cuts the wall time roughly by
# the core count. PYTEST_JOBS=1 forces the old serial run for debugging.
cd "$ROOT"
"$PY" -m pytest test/integration/ -q -n "${PYTEST_JOBS:-auto}"
