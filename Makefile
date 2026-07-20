# =============================================================================
# Zomb Boy — Game Boy Color zombie-survival game
# =============================================================================
# This Makefile treats RGBDS as a *pinned, repo-local* dev dependency. On a
# fresh clone, `make` downloads the exact toolchain version below into .tools/
# (gitignored) and builds from that — nothing needs to be installed globally.
#
#   make            Build the ROM (auto-installs the pinned toolchain first)
#   make tools      Just install the pinned build toolchain + includes
#   make emulator   Install the pinned mGBA emulator (~25 MB)
#   make hugetracker Install the pinned hUGETracker music tracker (~4.6 MB)
#   make run        Build, then play the ROM (auto-installs the emulator)
#   make test       Build + run the memory-safety / logic test ROMs
#   make stats      Per-bank ROM/RAM utilization report (from the .map file)
#   make play       Drive the ROM headless with a command script + screenshots
#                   e.g. make play SCRIPT='walk right 60; state; shot'
#   make shot       Boot headless and save a screenshot to build/play/
#   make clean      Remove build output (keeps the downloaded toolchain)
#   make distclean  Remove build output AND all downloaded tools
# =============================================================================

# --- Pinned dependency versions ---------------------------------------------
# gbdev/hardware.inc release tag.
# Pinned to the v4.x line on purpose: v5.0 renamed every constant
# (LCDCF_ON -> LCDC_ON, dropped _VRAM/SCRN_Y/BCPSF_AUTOINC, ...), which
# diverges from Pan Docs and virtually all GB-asm tutorials. v4.12.0 uses the
# classic, widely-documented names our source is written against.
RGBDS_VERSION   := 1.0.1
HWINC_REF       := v4.12.0
# mgba-emu/mGBA release tag. Open source (MPL 2.0), distro-independent AppImage
# (extracted at fetch time so no libfuse2 is needed at runtime). Chosen over
# Mesen2, whose settings-parsing std::regex crashes (std::bad_cast) on very new
# libstdc++ builds like Ubuntu 26.04's.
EMU_VERSION     := 0.10.5
# SuperDisk/hUGETracker release tag. The GUI music tracker you compose in; it
# exports songs in "RGBDS .asm" format that our vendored hUGEDriver plays. A dev
# tool only (the ROM builds without it), so it's a pinned, checksum-verified
# fetch into .tools/ like the emulator — not committed. Public domain.
HUGETRACKER_VERSION := 1.0.11

# --- Repo-local toolchain paths ---------------------------------------------
TOOLS_DIR       := .tools
RGBDS_DIR       := $(TOOLS_DIR)/rgbds
RGBASM          := $(RGBDS_DIR)/rgbasm
RGBLINK         := $(RGBDS_DIR)/rgblink
RGBFIX          := $(RGBDS_DIR)/rgbfix
RGBGFX          := $(RGBDS_DIR)/rgbgfx
HWINC           := $(TOOLS_DIR)/include/hardware.inc
EMU_DIR         := $(TOOLS_DIR)/emulator
# The runnable binary inside the extracted AppImage.
EMU_BIN         := $(EMU_DIR)/squashfs-root/AppRun
HUGETRACKER_DIR := $(TOOLS_DIR)/hugetracker
HUGETRACKER_BIN := $(HUGETRACKER_DIR)/.version   # sentinel: fetch stamps this

# --- Project layout ---------------------------------------------------------
SRC_DIR         := src
# generated asm (from graphics, data)
GEN_DIR         := build/gen
OBJ_DIR         := build/obj
ROM             := build/zombboy.gbc

# Include search paths handed to rgbasm (-i). Add more as the tree grows.
INCLUDES        := -i $(SRC_DIR)/ -i $(TOOLS_DIR)/include/ -i $(GEN_DIR)/

# Assemble every .asm under src/ (recursively). Test sources live in test/
# and are built by the `test` target, not here.
SRCS            := $(shell find $(SRC_DIR) -name '*.asm' 2>/dev/null)
OBJS            := $(patsubst $(SRC_DIR)/%.asm,$(OBJ_DIR)/%.o,$(SRCS))

# --- Vendored audio (hUGEDriver) --------------------------------------------
# The sound driver + demo song live in vendor/ (committed, public domain — see
# vendor/hUGEDriver/PROVENANCE.md). They're third-party sources assembled under
# upstream's conventions, NOT our -Weverything rule, and their includes resolve
# against their own directory (-i $(HUGE_DIR)/), so they get their own rules and
# object outputs rather than going through the src/ pattern rule above.
HUGE_DIR        := vendor/hUGEDriver
AUDIO_OBJS      := $(OBJ_DIR)/vendor/hUGEDriver.o $(OBJ_DIR)/vendor/song_demo.o

# --- Toolchain flags --------------------------------------------------------
# -Weverything: surface every warning; asm bugs are costly on real hardware.
ASMFLAGS        := $(INCLUDES) -Weverything -Wno-obsolete
# rgbfix: -c = GBC-compatible ($80, runs on DMG too — the ROM detects the console
# at boot and falls back to grayscale), -v = fix header, -p 0xFF = pad (also sets
# the ROM-size byte; $FF is the era-authentic filler, matching unprogrammed mask
# ROM), -m 0x1B = MBC5+RAM+BATTERY: the ROM is 64 KB — ROMX bank 1
# is the default-mapped bank (song + dialogue data), bank 2 the portraits — and
# the cart carries 8 KB of battery-backed RAM (-r 0x02) for the menu's SAVE
# option (see menu.asm DoSave / the SaveData SRAM section). Title <= 11.
# Licensed-era header conventions (cosmetic, but what a real post-1994 cart
# carried): -l 0x33 = old-licensee $33 (the "see new licensee" escape every
# SGB-era cart used — also a precondition if we ever add SGB support),
# -k ZB = our two-char new-licensee code, -j = non-Japan destination,
# -n 0 = mask ROM version (bump on re-release).
FIXFLAGS        := -c -v -p 0xFF -m 0x1B -r 0x02 -t ZOMBBOY -l 0x33 -k ZB -j -n 0

# Emulator used by `make run`. Defaults to the vendored, pinned mGBA (auto-
# fetched on first `make run`). Override to use your own, e.g.
#   make run EMULATOR=sameboy
EMULATOR        ?= $(EMU_BIN)

# =============================================================================
# Targets
# =============================================================================
.PHONY: all tools emulator hugetracker run test stats play shot clean distclean

all: $(ROM)

# --- Dependency bootstrap ---------------------------------------------------
# `tools` installs just the build toolchain (fast). The ~38 MB emulator is a
# separate target, auto-fetched by `make run`/`make test` when needed.
tools: $(RGBASM) $(HWINC)

emulator: $(EMU_BIN)

# hUGETracker is a standalone dev tool (compose/export music); fetched on demand,
# never needed to build the ROM. Songs it exports go in vendor/hUGEDriver/songs/.
hugetracker: $(HUGETRACKER_BIN)

$(RGBASM):
	./tools/fetch-rgbds.sh $(RGBDS_VERSION) $(RGBDS_DIR)

$(HWINC):
	./tools/fetch-hardware-inc.sh $(HWINC_REF) $(HWINC)

$(EMU_BIN):
	./tools/fetch-emulator.sh $(EMU_VERSION) $(EMU_DIR)

$(HUGETRACKER_BIN):
	./tools/fetch-hugetracker.sh $(HUGETRACKER_VERSION) $(HUGETRACKER_DIR)

# --- Build ------------------------------------------------------------------
# Every object depends on the toolchain + includes being present (order-only),
# AND on the specific files it INCLUDEs. rgbasm emits a .d makefile fragment
# (-M) listing those includes; we -include them below so that editing e.g.
# hardware.inc or a generated data file forces the right objects to rebuild.
# -MP adds phony targets so a deleted include doesn't wedge the build.
$(OBJ_DIR)/%.o: $(SRC_DIR)/%.asm | $(RGBASM) $(HWINC)
	@mkdir -p $(dir $@)
	$(RGBASM) $(ASMFLAGS) -M $(@:.o=.d) -MP -MQ $@ -o $@ $<

# Vendored hUGEDriver: driver + demo song. Assembled with the driver's own
# include dir on the search path (its `include "include/..."` resolves there)
# and WITHOUT -Weverything — it's third-party code held to upstream's style, and
# a new upstream warning shouldn't fail our build. Each depends on the whole
# vendored tree so editing an .inc rebuilds it.
VENDORED_AUDIO  := $(wildcard $(HUGE_DIR)/hUGEDriver.asm $(HUGE_DIR)/include/*.inc $(HUGE_DIR)/songs/*.asm)

$(OBJ_DIR)/vendor/hUGEDriver.o: $(HUGE_DIR)/hUGEDriver.asm $(VENDORED_AUDIO) | $(RGBASM)
	@mkdir -p $(dir $@)
	$(RGBASM) -i $(HUGE_DIR)/ -o $@ $<

$(OBJ_DIR)/vendor/song_demo.o: $(HUGE_DIR)/songs/song_demo.asm $(VENDORED_AUDIO) | $(RGBASM)
	@mkdir -p $(dir $@)
	$(RGBASM) -i $(HUGE_DIR)/ -o $@ $<

$(ROM): $(OBJS) $(AUDIO_OBJS)
	@mkdir -p $(dir $@)
	$(RGBLINK) -o $@ -n $(basename $@).sym -m $(basename $@).map $(OBJS) $(AUDIO_OBJS)
	$(RGBFIX) $(FIXFLAGS) $@
	@echo ">> built $@"

# Pull in auto-generated per-object dependency fragments (ignored if absent).
-include $(OBJS:.o=.d)

# --- Run / test -------------------------------------------------------------
# Launch the ROM. When using the default (vendored) emulator, fetch it first if
# missing. If the user overrode EMULATOR with their own, just run that.
run: $(ROM)
	@if [ "$(EMULATOR)" = "$(EMU_BIN)" ] && [ ! -x "$(EMU_BIN)" ]; then $(MAKE) --no-print-directory emulator; fi
	@echo ">> launching $(EMULATOR) $(ROM)"
	$(EMULATOR) $(ROM)

# Tests need the built ROM (they run it headless in PyBoy), not the GUI emulator.
test: $(ROM)
	./tools/run-tests.sh

# --- Inspection (works headless; no GUI or display needed) -------------------
# Per-bank utilization from the linker map — "how full is ROM0 and what's
# eating it". Plain python3, no venv.
stats: $(ROM)
	python3 tools/romstats.py --map $(basename $(ROM)).map

# Scripted headless play: boot the ROM in PyBoy (same harness as the tests),
# run a command script (inputs, screenshots, memory/state dumps, ASCII map).
# Anyone without a display — CI, agents — can *play and look at* the game:
#   make play SCRIPT='walk right 60; state; entities; shot'
# See tools/play.py --help for the command list. Screenshots -> build/play/.
VENV_OK := $(TOOLS_DIR)/venv/.ok
$(VENV_OK):
	./tools/setup-testenv.sh $(TOOLS_DIR)/venv

SCRIPT ?= state; shot
play: $(ROM) $(VENV_OK)
	$(TOOLS_DIR)/venv/bin/python tools/play.py '$(SCRIPT)'

# One-shot "what does it look like right now": boot + screenshot.
shot: $(ROM) $(VENV_OK)
	$(TOOLS_DIR)/venv/bin/python tools/play.py 'shot'

# --- Cleanup ----------------------------------------------------------------
clean:
	rm -rf build

distclean: clean
	rm -rf $(TOOLS_DIR)
