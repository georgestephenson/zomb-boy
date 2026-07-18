#!/usr/bin/env bash
#
# run-tests.sh — build and run the headless test ROMs.
#
# See docs/design/06-testing-and-memory-safety.md for the strategy. Each test ROM
# under test/ sets up a scenario, runs a real subsystem routine, and reports
# pass/fail via the serial port / a result byte. A headless emulator (Mesen2 Lua
# or SameBoy tester) runs each ROM and this script aggregates the exit codes.
#
# Right now there are no test ROMs yet (the engine doesn't exist). This script is
# a working placeholder that exits cleanly with a clear message, so `make test`
# is never a broken target. As subsystems land, their test ROMs plug in here.
set -euo pipefail

TEST_DIR="test"

if [ ! -d "$TEST_DIR" ] || [ -z "$(find "$TEST_DIR" -name '*.asm' 2>/dev/null)" ]; then
    echo "No test ROMs yet (test/ is empty)."
    echo "Testing strategy: docs/design/06-testing-and-memory-safety.md"
    echo "Nothing to run — exiting 0."
    exit 0
fi

# --- Emulator discovery (for when real tests exist) -------------------------
# Prefer a headless-capable emulator. Override with EMU_TEST=/path.
EMU_TEST="${EMU_TEST:-$(command -v mesen sameboy 2>/dev/null | head -n1 || true)}"
if [ -z "$EMU_TEST" ]; then
    echo "warn: no headless emulator found (install Mesen2 or SameBoy)."
    echo "      Set EMU_TEST=/path/to/emulator to run the test ROMs."
    exit 1
fi

echo "TODO: build test/*.asm into ROMs and run each under $EMU_TEST, asserting"
echo "      the result byte. Wire this up as the first subsystem lands."
exit 0
