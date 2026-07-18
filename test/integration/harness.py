"""Headless integration-test harness for Zomb Boy, built on PyBoy.

Boots the built ROM in a headless emulator and exposes helpers to tick frames,
read memory by *symbol name* (parsed from the linker .sym file), hold/release
buttons, and read OAM. This is how we verify runtime behaviour without a human:
memory + sprite state are fully observable and deterministic.

NOTE: PyBoy is lenient about VRAM-access timing (it won't reproduce the VRAM
corruption that a VBlank overrun causes on real hardware / mGBA). So these tests
verify *logic* (positions, tilemap contents, collision, sprite hygiene); the
timing budget is handled structurally (chunked blitting) rather than asserted.
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ROM = os.path.join(ROOT, "build", "zombboy.gbc")
SYM = os.path.join(ROOT, "build", "zombboy.sym")
sys.path.insert(0, os.path.join(ROOT, "test", "model"))

from pyboy import PyBoy  # noqa: E402

OAM_BASE = 0xFE00


def load_symbols():
    """Parse RGBDS .sym -> {name: address}. Lines look like '00:c138 wName'."""
    syms = {}
    with open(SYM) as f:
        for line in f:
            line = line.split(";", 1)[0].strip()
            if not line or ":" not in line:
                continue
            addr_part, _, name = line.partition(" ")
            name = name.strip()
            try:
                bank, addr = addr_part.split(":")
                syms[name] = int(addr, 16)
            except ValueError:
                continue
    return syms


class Game:
    def __init__(self, settle=150, poison=None):
        assert os.path.exists(ROM), f"ROM not built: {ROM} (run `make` first)"
        # The ROM is now CGB-compatible ($80 header) so it also runs on DMG; force
        # CGB here since these tests validate the colour/double-speed path. (PyBoy
        # doesn't faithfully emulate DMG mode for a CGB-flagged ROM, so the DMG
        # fallback is verified on hardware/mGBA, not here.)
        self.pyboy = PyBoy(ROM, window="null", sound_emulated=False, cgb=True)
        self.sym = load_symbols()
        self._held = set()
        # Simulate real-hardware / mGBA power-on garbage: PyBoy zeros RAM, so
        # fill WRAM+VRAM with a pattern before the CPU runs boot. A correct boot
        # sequence must sanitize this and behave identically regardless.
        if poison is not None:
            for a in range(0xC000, 0xE000):
                self.pyboy.memory[a] = poison
            for a in range(0x8000, 0xA000):
                self.pyboy.memory[a] = poison
        if settle:
            self.tick(settle)

    # --- lifecycle ---
    def close(self):
        for b in list(self._held):
            self.pyboy.button_release(b)
        self.pyboy.stop(save=False)

    def tick(self, n=1):
        for _ in range(n):
            self.pyboy.tick()

    # --- input ---
    def hold(self, button):
        self.pyboy.button_press(button)
        self._held.add(button)

    def release(self, button):
        self.pyboy.button_release(button)
        self._held.discard(button)

    def walk(self, button, frames):
        """Hold a direction for `frames`, then release and settle briefly."""
        self.hold(button)
        self.tick(frames)
        self.release(button)
        self.tick(4)

    # --- memory ---
    def addr(self, name):
        return self.sym[name]

    def r8(self, a):
        if isinstance(a, str):
            a = self.sym[a]
        return self.pyboy.memory[a]

    def r16(self, a):
        if isinstance(a, str):
            a = self.sym[a]
        return self.pyboy.memory[a] | (self.pyboy.memory[a + 1] << 8)

    def s16(self, a):
        v = self.r16(a)
        return v - 0x10000 if v >= 0x8000 else v

    # --- OAM (post-DMA hardware sprite table) ---
    def sprite(self, slot):
        o = OAM_BASE + slot * 4
        m = self.pyboy.memory
        return {"y": m[o], "x": m[o + 1], "tile": m[o + 2], "attr": m[o + 3]}

    def screenshot(self, path):
        self.pyboy.screen.image.convert("RGB").resize((480, 432), 0).save(path)
