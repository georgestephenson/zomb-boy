; =============================================================================
; Zomb Boy — main.asm  (v0.2: endless world)
; -----------------------------------------------------------------------------
; Entry point, boot init, and the main loop. Systems live in sibling modules:
;   world.asm   terrain generation + BG streaming
;   player.asm  movement, collision, camera, sprite
;   video.asm   VBlank, OAM DMA, palettes, scroll
;   input.asm   joypad
;   gfx.asm     tile + palette data
;   ram.asm     WRAM/HRAM variables
; =============================================================================
INCLUDE "hardware.inc"
INCLUDE "include/constants.inc"
INCLUDE "include/charmap.inc"       ; title strings assemble to font tile ids

SECTION "EntryPoint", ROM0[$0100]
    di
    jp Start
    ; Reserve the cartridge header ($0104-$014F) so the linker never places code
    ; here — rgbfix fills it with the logo/title/checksums.
    ds $0150 - @

SECTION "Main", ROM0[$0150]
Start::                             ; exported: the menu's EXIT soft-resets here
    ld sp, $FFFE                    ; explicit stack top (don't trust the boot ROM)

    ; --- map ROMX bank 1 (song + dialogue data) ---------------------------------
    ; MBC5: don't trust the power-on register values. Bank 1 is the default
    ; mapped bank everywhere; only ShowPortrait (talk.asm) switches away, to the
    ; portrait bank, and restores bank 1 before returning.
    ld a, 1
    ld [rROMB0], a
    xor a, a
    ld [rROMB1], a

    ; --- detect console, stash in HRAM (ClearRAM below only wipes WRAM) --------
    ; Probe the VRAM-bank register: on CGB it's writable, so bank 0 reads back
    ; with bit0 = 0; on DMG rVBK is unmapped and reads $FF (bit0 = 1). (The boot
    ; ROM's A = $11/$01 handoff also works on hardware, but this probe is robust
    ; regardless of how we were launched.) Everything CGB-only is gated on the
    ; flag so the ROM also runs on an original Game Boy, in grayscale.
    xor a, a
    ldh [rVBK], a
    ldh a, [rVBK]
    and 1                           ; 0 = CGB, 1 = DMG
    xor 1                           ; -> 1 = CGB, 0 = DMG
    ldh [hIsCGB], a
    and a
    jr z, .noSpeed                  ; DMG: skip double-speed (STOP would hang it)

    ; --- CGB double-speed CPU ---------------------------------------------
    ; The biome generator does a lot of hashing per tile; at normal speed the
    ; full-map InitMap at boot and the per-step GenStrip are heavy. Double speed
    ; halves all CPU-bound work (boot generation *and* the VBlank blit budget).
    ; Interrupts are still disabled here (`di` at $0100), which STOP requires.
    ldh a, [rKEY1]
    bit 7, a                        ; already running double-speed?
    jr nz, .noSpeed
    ld a, $30
    ldh [rP1], a                    ; deselect joypad lines (required before STOP)
    ld a, 1
    ldh [rKEY1], a                  ; arm the speed switch
    stop                            ; performs the switch, then resumes
.noSpeed:

    call WaitVBlankLY               ; safe point to turn the LCD off
    xor a, a
    ldh [rLCDC], a

    ; --- boot hygiene: power-on RAM/VRAM/APU/bank state is undefined on real
    ;     hardware (mGBA), so put everything in a known state before we start.
    call ClearRAM                   ; zero WRAM  (nothing may rely on zeroed RAM)
    call ClearVRAM                  ; zero both VRAM banks
    call InitAudio                  ; silence the APU during setup (InitSound powers it on)
    ld a, 1
    ldh [rSVBK], a                  ; map WRAM bank 1 at $D000
    xor a, a
    ldh [rVBK], a                   ; VRAM bank 0 for rendering

    ; --- content setup ---
    call CopyDMARoutine

    ; --- title screen ------------------------------------------------------
    ; CGB shows the full-screen image (title.asm — both VRAM banks + per-tile
    ; palettes); DMG can't (256 tiles, one bank, no BG attributes), so it keeps
    ; the classic text title on the grass backdrop. Either way, the frame the
    ; player presses START on is the only entropy source for the world seed
    ; (DIV at boot is deterministic on hardware and emulators alike, so seeding
    ; there gives the same world every power-on). SELECT+START forces the
    ; classic WORLD_SEED so the tests and reference model get a reproducible one.
    ldh a, [hIsCGB]
    and a, a
    jr z, .dmgtitle
    call ShowTitle                  ; CGB: full-screen background
    jr .titleon
.dmgtitle:
    call LoadTiles
    call LoadFont                   ; expand the 1bpp font to $8800 (FONT_BASE)
    call LoadPalettes
    call DrawTitle
.titleon:
    xor a, a
    ldh [rSCY], a                   ; power-on scroll registers are undefined
    ldh [rSCX], a
    ld a, LCDCF_ON | LCDCF_BGON | LCDCF_BG8000 | LCDCF_BG9800
    ldh [rLCDC], a
    call InitSound                  ; power the APU on + start the title theme
.title:
    ldh a, [rLY]                    ; leave the current VBlank...
    cp SCRN_Y
    jr nc, .title
    call WaitVBlankLY               ; ...and spin to the next: one tick/frame
    call UpdateSound                ; advance the title music one tick
    ld hl, wTitleTick
    inc [hl]
    call ReadInput
    ld a, [wNewKeys]
    and PAD_START
    jr z, .title
    ld a, [wTitleTick]              ; seed = press frame ^ DIV sub-frame bits
    ld b, a
    ldh a, [rDIV]
    xor b
    ld b, a
    ld a, [wCurKeys]
    and PAD_SELECT
    jr z, .seeded
    ld b, WORLD_SEED                ; SELECT held: the classic world
.seeded:
    ld a, b
    ldh [hWorldSeed], a
    call WaitVBlankLY               ; safe point to turn the LCD back off
    xor a, a
    ldh [rLCDC], a                  ; (InitMap below overwrites the title text)

    call LoadTiles                  ; restore game tiles (the title owned all of
    call LoadFont                   ; VRAM on CGB); InitMap redraws the tile map
    call LoadPalettes               ; game palettes (title used all 8 BG slots)
    call InitPlayer                 ; choose a passable start tile
    call UpdateView                 ; derive the camera from the player
    call InitMap                    ; generate the initial 32x32 map + attrs

    ; seed the RNG (must be non-zero) and spawn wandering zombies + survivors.
    ; wGameMode / wStrKind etc. are already 0 from ClearRAM.
    ld a, $AC
    ld [wRngState], a
    ld a, $E1
    ld [wRngState+1], a
    call InitZombies
    call InitNPCs
    call InitCar                    ; one drivable car near the start
    call InitSpawns                 ; arm the dynamic respawn timers
    call InitLoot                   ; scatter starting pickups + arm loot respawns
    call InitAnim                   ; arm the world-animation timers (water/trees/...)
    call InitHUD                    ; meters/clock + the window row (LCD is off)
    call InitDayNight               ; arm the time-of-day palette tint (CGB only)
    call InitInventory              ; party (just the player) + starting bag + options

    call UpdateWorldMusic           ; APU is already on from the title; swap the
                                    ; title theme for this biome's overworld track

    call DrawEntities
    ld a, HIGH(wShadowOAM)
    call hOAMDMA                    ; clean OAM before the first visible frame
    call SetScroll

    ld a, LCDCF_ON | LCDCF_BGON | LCDCF_OBJON | LCDCF_OBJ8 | LCDCF_BG8000 | LCDCF_BG9800 | LCDCF_WINON | LCDCF_WIN9C00
    ldh [rLCDC], a

    ld a, IEF_VBLANK
    ldh [rIE], a
    xor a, a
    ldh [rIF], a
    ei

; -----------------------------------------------------------------------------
; Main loop. Logic runs first (generating any incoming strip into WRAM), then
; we wait for VBlank and push OAM + scroll + the strip to VRAM in one shot, so
; the new edge appears the same frame the camera scrolls — no seam, no latency.
; -----------------------------------------------------------------------------
MainLoop:
    ld a, [wOptMusic]               ; music can be turned off in the pause menu's
    and a, a                        ; OPTIONS screen (gates the per-frame tick)
    call nz, UpdateSound            ; advance music one tick (once/frame, pre-VBlank)
    call ReadInput
    ld a, [wGameMode]
    cp MODE_TALK
    jp z, .talk
    cp MODE_MENU
    jp z, .menu
    cp MODE_BATTLE
    jp z, .battle
    and a, a                        ; MODE_OVERWORLD == 0
    jr nz, .alert
    ; --- overworld ---
    ld a, [wNewKeys]
    and PAD_START
    jr z, .noMenu
    call EnterMenu                  ; START -> pause menu (its own frame)
    jp MainLoop
.noMenu:
    call UpdateSurvival             ; clock + meter drains (time flows only here)
    call UpdateDayNight             ; re-shade terrain palettes on a time-of-day change
    call UpdatePlayer
    call UpdateView
    ld a, [wMoveDir]
    and a, a
    call nz, GenStrip               ; build incoming column/row (outside VBlank)
    call UpdateZombies              ; wander + line-of-sight (may trigger alert)
    call UpdateSpawns               ; cull far zombies/survivors + respawn fresh ones
    call UpdateLootSpawns           ; cull far loot + respawn fresh pickups/containers
    call CheckCarToggle             ; A next to the car -> board it / drive off
    call CheckLoot                  ; grab food underfoot / open a faced container
    call CheckTreeTouch             ; A facing a tree -> rustle it
    call CheckTalkStart             ; A at a survivor -> EnterTalk (MODE_TALK)
    ld a, [wGameMode]
    cp MODE_TALK
    jr z, MainLoop                  ; EnterTalk presented its own frame
    call UpdateAnim                 ; advance world animation (water/trees/brush/doors)
    call UpdateWorldMusic           ; track follows the player's biome (no-op unless
                                    ; it changed; also resumes world music after talk)
    jr .draw
.alert:
    call UpdateAlert                ; "!" beat -> zombie charges the player -> battle
    ld a, [wGameMode]
    cp MODE_BATTLE
    jp z, MainLoop                  ; EnterBattle presented its own frame
.draw:
    call ComputeCamLag              ; shared sub-tile camera offset (BG + sprites)
    call DrawEntities

    call WaitVBlank
    ; --- VBlank window ---
    ld a, HIGH(wShadowOAM)
    call hOAMDMA
    call SetScroll
    call PushHUD                    ; HUD row if dirty (skipped on strip frames;
                                    ; must run BEFORE BlitStream eats wStrKind)
    call PushDayNight               ; time-of-day palette re-shade if pending (rare)
    ld a, [wStrKind]                ; is a world strip being blitted this frame?
    push af
    call BlitStream                 ; push the queued strip into VRAM
    pop af
    and a, a
    call z, PushAnim                ; animated tile art — skip on the (single) strip
                                    ; frame to keep the DMG VBlank budget (an effect
                                    ; frame is ~invisibly late; water cycles slowly)
    jp MainLoop                     ; (JP: the added day/night calls push this >127)

; --- talk mode: dialogue logic, then a lighter VBlank (no scroll/stream) ---
.talk:
    call UpdateTalk                 ; state machine; fills the VRAM write queue
    ld a, [wGameMode]
    cp MODE_TALK
    jp nz, MainLoop                 ; exited (to overworld or battle) — frame shown
    call WaitVBlank
    ld a, HIGH(wShadowOAM)
    call hOAMDMA
    call DrainTalkQ                 ; typewriter/menu writes, bounded
    jp MainLoop

; --- menu mode: pause menu logic, then OAM push (screen is built LCD-off by the
;     menu itself on each navigation). The game is paused: no clock, no world. ---
.menu:
    call UpdateMenu                 ; input + panel navigation (may exit the mode)
    call WaitVBlank
    ld a, HIGH(wShadowOAM)
    call hOAMDMA
    jp MainLoop

; --- battle mode: combat logic, then a lighter VBlank (no scroll/stream). The
;     engine + its VBlank drainer live in a floating ROMX bank (ROM0/bank1 are
;     full), so map it around the calls and hand bank 1 back before looping. ---
.battle:
    ld a, BANK(UpdateBattle)
    ld [rROMB0], a
    call UpdateBattle               ; state machine; fills the VRAM write queue
    ld a, [wGameMode]
    cp MODE_BATTLE
    jr nz, .battleDone              ; ExitBattle already restored + presented a frame
    call WaitVBlank
    ld a, HIGH(wShadowOAM)
    call hOAMDMA
    call DrainBattleQ
    call DrawArena                  ; repaint the approaching foes if dirty (VBlank)
.battleDone:
    ld a, 1                         ; restore the default bank for the next frame
    ld [rROMB0], a
    jp MainLoop

; -----------------------------------------------------------------------------
; DrawTitle: write the title strings straight to SCRN0 (call with the LCD off).
; The strings are charmap'd, so each byte already IS a font tile id; the
; cleared tile map (tile 0 = grass) is the backdrop.
; -----------------------------------------------------------------------------
DrawTitle:
    ld hl, _SCRN0 + 6 * 32 + 6      ; row 6, centred (8 chars)
    ld de, TitleName
    call .puts
    ld hl, _SCRN0 + 10 * 32 + 4     ; row 10, centred (11 chars)
    ld de, TitlePrompt
    ; fall through
.puts:
    ld a, [de]
    and a, a
    ret z
    ld [hl+], a
    inc de
    jr .puts

TitleName:   db "ZOMB BOY", 0
TitlePrompt: db "PRESS START", 0
