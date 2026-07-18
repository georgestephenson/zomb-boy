# =============================================================================
# Zomb Boy — Game Boy Color zombie-survival game
# =============================================================================
# This Makefile treats RGBDS as a *pinned, repo-local* dev dependency. On a
# fresh clone, `make` downloads the exact toolchain version below into .tools/
# (gitignored) and builds from that — nothing needs to be installed globally.
#
#   make            Build the ROM (auto-installs the pinned toolchain first)
#   make tools      Just install the pinned toolchain + includes
#   make run        Build, then launch the ROM in $(EMULATOR)
#   make test       Build + run the memory-safety / logic test ROMs
#   make clean      Remove build output (keeps the downloaded toolchain)
#   make distclean  Remove build output AND the downloaded toolchain
# =============================================================================

# --- Pinned dependency versions ---------------------------------------------
# gbdev/hardware.inc release tag.
# Pinned to the v4.x line on purpose: v5.0 renamed every constant
# (LCDCF_ON -> LCDC_ON, dropped _VRAM/SCRN_Y/BCPSF_AUTOINC, ...), which
# diverges from Pan Docs and virtually all GB-asm tutorials. v4.12.0 uses the
# classic, widely-documented names our source is written against.
RGBDS_VERSION   := 1.0.1
HWINC_REF       := v4.12.0

# --- Repo-local toolchain paths ---------------------------------------------
TOOLS_DIR       := .tools
RGBDS_DIR       := $(TOOLS_DIR)/rgbds
RGBASM          := $(RGBDS_DIR)/rgbasm
RGBLINK         := $(RGBDS_DIR)/rgblink
RGBFIX          := $(RGBDS_DIR)/rgbfix
RGBGFX          := $(RGBDS_DIR)/rgbgfx
HWINC           := $(TOOLS_DIR)/include/hardware.inc

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

# --- Toolchain flags --------------------------------------------------------
# -Weverything: surface every warning; asm bugs are costly on real hardware.
ASMFLAGS        := $(INCLUDES) -Weverything -Wno-obsolete
# rgbfix: -C = GBC-only, -v = fix header, -p 0xFF = pad, -m/-r default MBC set
# in the fix target once we know the cart type. Title <= 11 chars for GBC.
FIXFLAGS        := -C -v -p 0xFF -t ZOMBBOY

# Emulator used by `make run` — override on the CLI, e.g.
#   make run EMULATOR=sameboy
EMULATOR        ?= $(firstword $(shell command -v sameboy mesen emulicious bgb 2>/dev/null) echo)

# =============================================================================
# Targets
# =============================================================================
.PHONY: all tools run test clean distclean

all: $(ROM)

# --- Dependency bootstrap ---------------------------------------------------
tools: $(RGBASM) $(HWINC)

$(RGBASM):
	./tools/fetch-rgbds.sh $(RGBDS_VERSION) $(RGBDS_DIR)

$(HWINC):
	./tools/fetch-hardware-inc.sh $(HWINC_REF) $(HWINC)

# --- Build ------------------------------------------------------------------
# Every object depends on the toolchain + includes being present (order-only),
# AND on the specific files it INCLUDEs. rgbasm emits a .d makefile fragment
# (-M) listing those includes; we -include them below so that editing e.g.
# hardware.inc or a generated data file forces the right objects to rebuild.
# -MP adds phony targets so a deleted include doesn't wedge the build.
$(OBJ_DIR)/%.o: $(SRC_DIR)/%.asm | $(RGBASM) $(HWINC)
	@mkdir -p $(dir $@)
	$(RGBASM) $(ASMFLAGS) -M $(@:.o=.d) -MP -MQ $@ -o $@ $<

$(ROM): $(OBJS)
	@mkdir -p $(dir $@)
	$(RGBLINK) -o $@ -n $(basename $@).sym -m $(basename $@).map $(OBJS)
	$(RGBFIX) $(FIXFLAGS) $@
	@echo ">> built $@"

# Pull in auto-generated per-object dependency fragments (ignored if absent).
-include $(OBJS:.o=.d)

# --- Run / test -------------------------------------------------------------
run: $(ROM)
	@if [ -z "$(EMULATOR)" ] || [ "$(EMULATOR)" = "echo" ]; then \
		echo "No emulator found. Install SameBoy/Mesen/Emulicious or set EMULATOR=..."; \
	else \
		$(EMULATOR) $(ROM); \
	fi

test: $(RGBASM) $(HWINC)
	./tools/run-tests.sh

# --- Cleanup ----------------------------------------------------------------
clean:
	rm -rf build

distclean: clean
	rm -rf $(TOOLS_DIR)
