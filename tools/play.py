#!/usr/bin/env python3
"""play.py — scripted headless play + inspection of the built ROM.

Lets anyone (human or agent) *play* the game without a display: boot the ROM
in PyBoy, feed it a small input script, and observe the result as screenshots,
memory, OAM, decoded game state or an ASCII map. This is the interactive
counterpart to the pytest suite — same harness, ad-hoc driving.

Run it with the test venv's python (the Makefile's `make play` does this):

  .tools/venv/bin/python tools/play.py 'walk right 60; state; shot'
  .tools/venv/bin/python tools/play.py --seed random 'wait 120; entities; map'
  .tools/venv/bin/python tools/play.py 'press start; wait 10; shot menu.png'

The script is a semicolon/newline-separated command list:

  wait N              tick N frames
  hold BTN [N]        press-and-hold BTN (optionally for N frames, then keep)
  release BTN         release a held button
  press BTN           tap BTN (held 4 frames — one input edge)
  walk BTN N          hold BTN for N frames, release, settle 4 (one tile = 16)
  shot [PATH]         save a 3x-scaled screenshot (default: auto-numbered PNG)
  state               decoded game state (mode, position, meters, clock, seed)
  entities            decoded zombie / survivor / loot pool tables
  oam [N]             raw OAM entries 0..N-1 (default 16)
  mem NAME|$ADDR [N]  hex-dump N bytes (default 1) at a .sym name or address
  map [R]             ASCII world map within R tiles of the player (default 9),
                      from the generator model (ground truth, any seed)

Buttons: up down left right a b start select.
Boot options mirror the test harness: --seed classic (SELECT+START, the fixed
$A5 world), --seed random (START at --press-frame), --seed title (stay on the
title screen). Exit code is nonzero on a bad script or a failed command.
"""
import argparse
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "test", "integration"))
sys.path.insert(0, os.path.join(ROOT, "test", "model"))

BUTTONS = {"up", "down", "left", "right", "a", "b", "start", "select"}

# Tile id -> map glyph, kept in sync with TILE_* in src/include/constants.inc
# via worldgen_model (which the map command renders from).
TILE_GLYPHS = {
    0: ".",                     # grass
    1: ",",                     # brush
    2: "*",                     # flower
    3: ":",                     # dirt
    4: "~",                     # water (solid)
    5: "=",                     # road
    6: "#",                     # house wall (solid)
    7: "_",                     # house floor
    8: "D",                     # house door
    9: "%",                     # marsh
    10: "T", 11: "T", 12: "T", 13: "T",  # tree quadrants (solid)
}


def parse_script(text):
    cmds = []
    for raw in text.replace("\n", ";").split(";"):
        toks = raw.strip().split()
        if toks:
            cmds.append(toks)
    return cmds


class Player:
    def __init__(self, game, outdir):
        self.g = game
        self.outdir = outdir
        self.nshot = 0

    # --- commands (cmd_<name> convention; discovered by dispatch) ---
    def cmd_wait(self, n):
        self.g.tick(int(n))

    def cmd_hold(self, btn, n=None):
        assert btn in BUTTONS, f"unknown button {btn!r}"
        self.g.hold(btn)
        if n is not None:
            self.g.tick(int(n))

    def cmd_release(self, btn):
        self.g.release(btn)

    def cmd_press(self, btn):
        assert btn in BUTTONS, f"unknown button {btn!r}"
        self.g.hold(btn)
        self.g.tick(4)
        self.g.release(btn)
        self.g.tick(2)

    def cmd_walk(self, btn, n):
        assert btn in BUTTONS, f"unknown button {btn!r}"
        self.g.walk(btn, int(n))

    def cmd_shot(self, path=None):
        if path is None:
            path = f"shot{self.nshot:03d}.png"
            self.nshot += 1
        if not os.path.isabs(path):
            path = os.path.join(self.outdir, path)
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        self.g.screenshot(path)
        print(f"[shot] {path}")

    def cmd_state(self):
        g = self.g
        mode = {0: "OVERWORLD", 1: "ALERT", 2: "TALK", 3: "MENU"}.get(
            g.r8("wGameMode"), "?")
        print(f"mode={mode} seed=${g.r8('hWorldSeed'):02x} "
              f"pos=({g.s16('wPlayerWX')},{g.s16('wPlayerWY')}) "
              f"seen=({g.s16('wSeenWX')},{g.s16('wSeenWY')})")
        print(f"hp={g.r8('wHP')} food={g.r8('wFood')} energy={g.r8('wEnergy')} "
              f"fuel={g.r8('wFuel')} clock={g.r8('wClockH'):02d}:{g.r8('wClockM'):02d} "
              f"incar={g.r8('wInCar')} swim={g.r8('wSwimming')} "
              f"car=({g.s16('wCarWX')},{g.s16('wCarWY')})")

    def _pool(self, base_sym, count, name, extra=(), facing=True):
        g = self.g
        base = g.addr(base_sym)
        print(f"{name}:")
        for i in range(count):
            o = base + i * 16
            if not g.r8(o):          # EO_ACTIVE
                continue
            wx = g.r16(o + 1)
            wy = g.r16(o + 3)
            wx = wx - 0x10000 if wx >= 0x8000 else wx
            wy = wy - 0x10000 if wy >= 0x8000 else wy
            more = " ".join(f"{label}={g.r8(o + off)}" for label, off in extra)
            face = f"facing={g.r8(o + 5)} " if facing else ""
            print(f"  [{i}] pos=({wx},{wy}) {face}{more}")

    def cmd_entities(self):
        self._pool("wZombies", 8, "zombies", [("alert", 10)])
        self._pool("wNPCs", 10, "survivors", [("persona", 13), ("affin", 14), ("met", 15)])
        self._pool("wLoot", 8, "loot", [("kind", 5)], facing=False)

    def cmd_oam(self, n="16"):
        for i in range(int(n)):
            s = self.g.sprite(i)
            print(f"oam[{i:2}] y={s['y']:3} x={s['x']:3} "
                  f"tile={s['tile']:3} attr=${s['attr']:02x}")

    def cmd_mem(self, where, n="1"):
        g = self.g
        addr = int(where[1:], 16) if where.startswith("$") else g.addr(where)
        data = [g.r8(addr + i) for i in range(int(n))]
        for off in range(0, len(data), 16):
            row = data[off:off + 16]
            print(f"${addr + off:04x}: " + " ".join(f"{b:02x}" for b in row))

    def cmd_map(self, r="9"):
        import worldgen_model
        g, r = self.g, int(r)
        px, py = g.s16("wPlayerWX"), g.s16("wPlayerWY")
        for y in range(py - r, py + r + 1):
            row = ""
            for x in range(px - r, px + r + 1):
                if (x, y) == (px, py):
                    row += "@"
                else:
                    t = worldgen_model.gen_tile_type(x, y)
                    row += TILE_GLYPHS.get(t, "?")
            print(row)
        print(f"(@ = player at ({px},{py}); model ground truth, seed "
              f"${g.r8('hWorldSeed'):02x})")

    def run(self, cmds):
        for toks in cmds:
            fn = getattr(self, f"cmd_{toks[0]}", None)
            if fn is None:
                sys.exit(f"error: unknown command {toks[0]!r} (see --help)")
            try:
                fn(*toks[1:])
            except TypeError:
                sys.exit(f"error: bad arguments for {toks[0]!r}: {' '.join(toks)}")


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("script", nargs="?", default="state; shot",
                    help="semicolon-separated command list (default: 'state; shot')")
    ap.add_argument("--seed", choices=["classic", "random", "title"], default="classic")
    ap.add_argument("--press-frame", type=int, default=90)
    ap.add_argument("--settle", type=int, default=150)
    ap.add_argument("--out-dir", default=os.path.join(ROOT, "build", "play"),
                    help="where auto-numbered screenshots go")
    args = ap.parse_args()

    cmds = parse_script(args.script)

    from harness import Game
    seed = None if args.seed == "title" else args.seed
    game = Game(settle=args.settle, seed=seed, press_frame=args.press_frame)
    try:
        Player(game, args.out_dir).run(cmds)
    finally:
        game.close()


if __name__ == "__main__":
    main()
