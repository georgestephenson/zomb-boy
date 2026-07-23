; =============================================================================
; ram.asm — all WRAM/HRAM variable declarations in one place.
; Every symbol is exported (::) so the other modules can reference it.
; =============================================================================
INCLUDE "include/constants.inc"

; Shadow OAM must be 256-byte aligned: OAM DMA takes only the source's high
; byte, so the low byte has to be $00.
SECTION "Shadow OAM", WRAM0, ALIGN[8]
wShadowOAM::        ds 40 * 4          ; 40 sprites x (Y, X, tile, attr)
wShadowOAM_End::

SECTION "Game State", WRAM0
; Player + camera use 16-bit signed world *tile* coordinates (endless world).
wPlayerWX::         ds 2               ; player world tile X (little-endian)
wPlayerWY::         ds 2               ; player world tile Y
wSpawnWX::          ds 2               ; the tile the player started on (InitPlayer);
wSpawnWY::          ds 2               ; the status screen shows position relative to it
; The tile the player has FULLY arrived on — lags the logical tile by one step
; while mid-walk (the logical tile jumps at step start; this catches up only when
; the step finishes). Zombie line-of-sight is tested against THIS so an encounter
; only triggers once you've stepped onto the tile, monster-battler-style — not the instant
; you begin the step (SyncSeen in player.asm updates it).
wSeenWX::           ds 2
wSeenWY::           ds 2
wViewTX::           ds 2               ; world tile at screen's top-left column
wViewTY::           ds 2               ; ... and row (= player - centre offset)

; Scratch inputs to the tile generator (16-bit world coords) and hash.
wGenX::             ds 2
wGenY::             ds 2
wHX::               ds 2               ; hash input X (already coord-transformed)
wHY::               ds 2               ; hash input Y
wWX::               ds 2               ; domain-warped X used by water/biome passes
wWY::               ds 2               ; domain-warped Y
wBiX::              ds 2               ; biome-sample anchor X (chunk- or block-floored)
wBiY::              ds 2               ; biome-sample anchor Y
; CalcBiome memo cache: biome is pure in (anchor, seed) and neighbouring tiles
; share anchors, so one entry skips ~half the biome hashing during streaming.
; ClearRAM zeroes wBioCacheOK at boot (and on the EXIT soft-reset), so a stale
; seed can never leak through the cache. Key bytes must stay contiguous.
wBioCacheX::        ds 2               ; cached anchor X (16-bit LE)
wBioCacheY::        ds 2               ; cached anchor Y
wBioCacheVal::      ds 1               ; BIOME_* for that anchor
wBioCacheOK::       ds 1               ; nonzero once the entry is valid
; House pass scratch (city biome): building size + this tile's offset into it.
wHW::               ds 1               ; house width
wHH::               ds 1               ; house height
wHDX::              ds 1               ; this tile's dx within the house bbox
wHDY::              ds 1               ; ... and dy

; Title screen: frames spent waiting for START (the press timing is the world
; seed's entropy source — see TitleScreen in main.asm).
wTitleTick::        ds 1

; Input
wCurKeys::          ds 1               ; held this frame (1 = pressed)
wNewKeys::          ds 1               ; pressed this frame (edge)
wPrevKeys::         ds 1
wMoveCooldown::     ds 1

; Player animation / movement
wMoveDir::          ds 1               ; DIR_* set at a step start (drives streaming)
wFacing::           ds 1               ; EFACE_* (0 down,1 up,2 left,3 right)
wWalkFrame::        ds 1               ; 0/1 walk-cycle frame
wPlayerState::      ds 1               ; PSTATE_* (idle / turning / walking)
wStepOffset::       ds 1               ; 0..STEP_TOTAL progress into the current step
wStepDir::          ds 1               ; EFACE_* being walked
wTurnTimer::        ds 1               ; frames left of the turn-in-place delay
; Sub-tile camera lag (signed px) added to SCX/SCY while the player mid-steps.
; The SAME value is subtracted from every world sprite so they stay glued to the
; scrolling background (else they appear to slide/zoom relative to the world).
wCamLagX::          ds 1
wCamLagY::          ds 1
wCurTile::          ds 1               ; scratch: last generated tile type
wDestTile::         ds 1               ; tile the player is stepping onto (swim test)
wSwimming::         ds 1               ; 1 while the player stands on a water tile
wSplashTimer::      ds 1               ; frames left to draw the enter/leave splash

; VRAM streaming: one column/row of fresh tiles queued for the next VBlank.
; Buffer holds quads {addrLo, addrHi, tile, attr} so the VBlank blit is tight.
wStrKind::          ds 1               ; 0 = nothing pending, 1 = pending
wStrLen::           ds 1               ; number of quads
wStrDone::          ds 1               ; quads already blitted (chunked across frames)
wStrIsCol::         ds 1               ; 1 = vertical strip, 0 = horizontal
wStrI::             ds 1               ; fill-loop counter
wBufPtr::           ds 2               ; fill-loop write pointer
wStrBuf::           ds 24 * 4          ; up to 24 quads

; Entities (zombies) + supporting scratch.
SECTION "Entities", WRAM0
wRngState::         ds 2               ; 16-bit LFSR (must stay non-zero)
wGameMode::         ds 1               ; MODE_*
wZombIdx::          ds 1               ; loop index into wZombies
wAlertZombie::      ds 1               ; index of the zombie that spotted you
wChaseTimer::       ds 1               ; MODE_ALERT watchdog: frames left before the
                                       ; charge is forced to end in a battle
wLosCount::         ds 1               ; occlusion-walk counter (survives Gen calls)
wScrX::             ds 1               ; scratch: on-screen sprite X
wScrY::             ds 1               ; scratch: on-screen sprite Y
wEnt::              ds ENT_SIZE        ; the entity currently being processed
wZombies::          ds MAX_ZOMBIES * ENT_SIZE
; Frames after a battle during which no new alert may fire, so a flee/loss isn't
; instantly re-triggered while the player is still in the zombie's sight line.
; (Placed after the pool so it doesn't shift the entity-scratch addresses.)
wAlertGrace::       ds 1

; Survivor NPCs (same 16-byte entity struct; EO_PERSONA/EO_AFFIN in 13/14).
SECTION "NPC State", WRAM0
wNPCs::             ds MAX_NPCS * ENT_SIZE
wNPCIdx::           ds 1               ; loop index into wNPCs

; Dynamic spawn manager (entity.asm UpdateSpawns): respawn throttles + the
; scratch CullFarPool scans a pool through. Timers armed by InitSpawns.
SECTION "Spawn State", WRAM0
wZombSpawnTimer::   ds 1               ; frames until the next zombie respawn try
wNPCSpawnTimer::    ds 1               ; ... and the next survivor respawn try
wPoolBase::         ds 2               ; base address of the pool being culled
wPoolCount::        ds 1               ; ... its entity count
wPoolIdx::          ds 1               ; ... loop index / stashed free-slot index

; World loot (loot.asm): a pool of pickups/containers reusing the entity struct
; (kind in EO_KIND). Managed by the same cull/respawn machinery as the entities.
SECTION "Loot State", WRAM0
wLoot::             ds MAX_LOOT * ENT_SIZE
wLootSpawnTimer::   ds 1               ; frames until the next loot respawn try
wLootKind::         ds 1               ; scratch: the kind being placed
wLootDX::           ds 1               ; scratch: InitLoot table dx/dy
wLootDY::           ds 1

; Drivable car (car.asm): a single world object the player can board and drive.
; Zeroed by ClearRAM at boot, then positioned + fuelled by InitCar.
SECTION "Car State", WRAM0
wCarWX::            ds 2               ; parked car world tile X (16-bit LE)
wCarWY::            ds 2               ; ... and Y
wCarFacing::        ds 1               ; EFACE_* the parked car faces
wInCar::            ds 1               ; 1 while the player is driving
wCarBoard::         ds 1               ; 0 = none; else (EFACE_*+1) = walk one tile
                                       ; ONTO the car that way, then start driving
                                       ; (consumed by UpdatePlayer next idle frame)
wBoarding::         ds 1               ; 1 while the walk-onto-the-car step animates;
                                       ; when it finishes, wInCar flips on (the door
                                       ; shuts) — so the car never jumps on boarding
wCarEject::         ds 1               ; 0 = none; else (EFACE_*+1) = get out of the
                                       ; car and step the player one tile that way
                                       ; (consumed by UpdatePlayer next idle frame)
wFuel::             ds 1               ; 0..METER_MAX, saturating (drives the HUD
                                       ; fuel readout; replaces energy while driving)
wCarRumble::        ds 1               ; free-running frame counter for the driving
                                       ; engine-rumble sprite wobble (DrawCar); purely
                                       ; cosmetic, advanced only while wInCar
wSmokeTimer::       ds 1               ; frames left to draw the exhaust puff (0 = none)
wCarLastDir::       ds 1               ; last EFACE_* the car drove ($FF = stopped); a
                                       ; driving step puffs smoke when it differs (a
                                       ; fresh start or a turn), not on a straight chain
wCarScrX::          ds 1               ; the driving car's on-screen top-left, stashed by
wCarScrY::          ds 1               ; DrawCar so DrawSmoke can anchor the puff behind it
; InitCar road-spawn search scratch (boot only). wCarRngSave brackets the search
; so consuming Rand while probing doesn't perturb the dynamic-spawn stream.
wCarRngSave::       ds 2               ; saved wRngState across the spawn search
wCarTries::         ds 1               ; remaining candidate anchors to try
wCarScan::          ds 1               ; 2x2 classify accumulator (bit0 = saw road)

; Music manager + SFX state (audio.asm). The currently-loaded song is remembered
; so PlayMusic only re-inits the driver when the track actually changes song (a
; same-song request — e.g. every world track sharing the one placeholder asset —
; is a no-op, so the music never restarts as you cross screens/biomes).
SECTION "Audio State", WRAM0
wMusicSong::        ds 2               ; pointer to the loaded song descriptor (0 = none)
wMusicBank::        ds 1               ; its ROM bank (UpdateSound maps this each tick)
wWorldTrack::       ds 1               ; last world track selected (TRK_WORLD_*), for resume
wBumpCd::           ds 1               ; frames until the wall-bump SFX may fire again

; World animation (anim.asm): ambient + reactive tile-art swaps. All 1-byte
; frame counters / current-frame indices; "shown" tracks what PushAnim last wrote
; so it only re-copies art on a change. Zeroed by ClearRAM, then InitAnim arms
; the two free-running dividers.
SECTION "Anim State", WRAM0
wAnimTick::         ds 1               ; free-running frame counter
wWaterDiv::        ds 1               ; frames left until the next shimmer sub-frame
wWaterFrame::      ds 1               ; current water ripple frame (0..2)
wWaterShown::      ds 1               ; last-pushed water frame
wBreezeTimer::     ds 1               ; frames until the next ambient tree gust
wTreeTimer::       ds 1               ; sway remaining (0 = at rest)
wTreeFrame::       ds 1               ; current canopy sway frame (0..2)
wTreeShown::       ds 1
wBrushTimer::      ds 1               ; rustle remaining (0 = at rest)
wBrushFrame::      ds 1               ; current brush frame (0..2)
wBrushShown::      ds 1
wOnDoor::          ds 1               ; 1 while the player stands on a door tile
wDoorLinger::      ds 1               ; frames a door stays open after stepping off
wDoorFrame::       ds 1               ; 0 = closed art, 1 = open art
wDoorShown::       ds 1

; HUD / survival meters (docs/design/03; v0 non-lethal) — see hud.asm.
SECTION "HUD State", WRAM0
wHP::               ds 1               ; 0..METER_MAX, saturating
wFood::             ds 1
wEnergy::           ds 1
wClockH::           ds 1               ; in-game clock 00:00-23:59
wClockM::           ds 1
wClockFrame::       ds 1               ; frames into the current minute
wClockMinCount::    ds 1               ; free-running minute counter (drain mask)
wHUDDirty::         ds 1               ; nonzero: wHUDText needs a VRAM push
wNoticeTimer::      ds 1               ; >0: a pickup toast owns the row (frames left)
wHUDText::          ds HUD_COLS        ; the composed row (font tile ids)

; Day/night palette tint (daynight.asm). wDayBucket is the currently-applied
; DN_* bucket (DN_INVALID forces a re-tint). ComputeTint fills wTintPal (the 4
; terrain palettes, tinted) in the logic phase; PushDayNight streams it to
; palette RAM in VBlank when wTintPending is set. The rest are per-call scratch.
SECTION "DayNight State", WRAM0
wDayBucket::        ds 1               ; applied DN_* bucket (DN_INVALID = none yet)
wTintPending::      ds 1               ; nonzero: wTintPal needs a VBlank push
wNeutralPal::       ds 32              ; boot copy of BGPalette 0..3 (LoadPalettes
                                       ; caches it while the gfx bank is mapped, so
                                       ; ComputeTint — in BANK[1] — needn't switch)
wTintPal::          ds 32              ; BG palettes 0..3, tinted (4 pals x 4 x 2 B)
wTintFR::           ds 1               ; per-call: R/G/B scale factors (0..8)
wTintFG::           ds 1
wTintFB::           ds 1
wTintLo::           ds 1               ; per-colour scratch: source lo/hi bytes
wTintHi::           ds 1
wTintR::            ds 1               ; per-colour scratch: scaled channels
wTintG::            ds 1
wTintBb::           ds 1
wTintOut0::         ds 1               ; per-colour scratch: repacked lo/hi bytes
wTintOut1::         ds 1

; Talk mode (survivor dialogue screen) — see talk.asm / dialogue.asm.
SECTION "Talk State", WRAM0
wTalkNPC::          ds 1               ; index of the NPC we're talking to
wTalkPersona::      ds 1               ; its PERSONA_* (cached from the struct)
wTalkState::        ds 1               ; TS_*
wTalkPhase::        ds 1               ; TPH_*
wTalkRound::        ds 1               ; replies given so far (0..TALK_ROUNDS)
wTalkDelta::        ds 1               ; signed affinity delta of the last reply
wTalkMood::         ds 1               ; MOOD_* (recomputed as affinity moves)
wTalkOutcome::      ds 1               ; OUTCOME_* (valid in TPH_OUTCOME)
wTalkSubject::      ds 1               ; noun-bank index the conversation orbits
wTalkTone::         ds 1               ; TONE_* just picked (drives react tags)
wTalkMet::          ds 1               ; EO_MET as it was BEFORE this talk
wTalkCursor::       ds 1               ; menu cursor 0..3 (bit0 = col, bit1 = row)
wMenuTones::        ds 4               ; the TONE_* offered in each menu slot
wMenuTries::        ds 1               ; BuildMenu redraw counter
; Typewriter reveal: walks wTalkText into VRAM via the write queue.
wRevPos::           ds 1               ; next cell to reveal (0..TALK_TEXT_MAX)
wRevCol::           ds 1               ; its column / row (avoids div by 18)
wRevRow::           ds 1
wRevSpeed::         ds 1               ; cells enqueued per frame
; Grammar composer scratch (dialogue.asm)
wTalkCol::          ds 1               ; compose write position: column 0..17
wTalkRow::          ds 1               ; ... and row 0..2
wWordLen::          ds 1
wWordBuf::          ds WORD_MAX + 1    ; current word (incl. glued punctuation)
wLastNoun::         ds 1               ; repeat-pick guards (bank indexes)
wLastTopic::        ds 1
wLastQuest::        ds 1
; Multi-page NPC turns: each turn may add a context remark before its question.
wTalkObs::          ds 1               ; 1 = try an observation page this turn
wCtxUsed::          ds 1               ; CTX_* bits already remarked this talk
wCtxKind::          ds 1               ; the CTX_* this turn's observation used
                                       ; (CTX_NONE if none) — the question beat
                                       ; follows it up in the persona's voice
; The 3x18 text grid (font tile ids). wTalkGuard is a canary: set to $C5 on
; talk entry and never written again — the composer is bounds-checked and the
; integration tests assert it survives (docs/design/05 §3 memory safety).
wTalkText::         ds TALK_TEXT_MAX
wTalkGuard::        ds 1
; VRAM write queue: logic fills (bounded), the talk VBlank path drains fully.
wTalkQN::           ds 1               ; entries used this frame
wTalkQ::            ds TALKQ_CAP * 3   ; {addrHi, addrLo, value}

; Start menu (menu.asm): the pause menu, party, inventory and equipment.
SECTION "Menu State", WRAM0
wMenuScreen::       ds 1               ; MSCR_* — which panel is showing
wRootCursor::       ds 1               ; selected option on the root list (kept
                                       ; across submenu visits so B returns here)
wMenuCursor::       ds 1               ; sub-cursor for the equip slots / options
wOptMusic::         ds 1               ; options: 1 = music on (gates UpdateSound)
wOptSfx::           ds 1               ; options: 1 = sound effects on (gates PlaySFX)
wSaveDone::         ds 1               ; nonzero once a save has completed (SAVE screen)
wMenuId::           ds 1               ; scratch: item id being drawn in a list row
wMenuCount::        ds 1               ; scratch: its stack count
wAllowType::        ds 1               ; scratch: equip picker's accepted ITYPE_*
wStatusPage::       ds 1               ; STATUS panel: 0 = vitals, 1 = stat points
                                       ; (LEFT/RIGHT flip; reset on entry)
; A generic scrolling list (BAG, equip picker): count, cursor, and the index of
; the first visible row. See MenuListMove / DrawList in menu.asm.
wListN::            ds 1
wListCur::          ds 1
wListTop::          ds 1
; Equip picker: which member/slot is being filled, and a map from picker row to
; the item id it offers (row 0 = ITEM_NONE = unequip).
wPickMember::       ds 1
wPickSlot::         ds 1
wPickMap::          ds BAG_MAX + 1
; Party: one record per member is its EQUIP_SLOTS item ids plus a level + 16-bit
; XP total (member survival stats for slot 0 are still the global player meters;
; extra members are LATER). Slot 0 = player. Level/XP grow through battles
; (AddPlayerXP); stat points are derived from the level (items.asm StatBase/Grow).
wPartyCount::       ds 1
wPartyEquip::       ds MAX_PARTY * EQUIP_SLOTS
wPartyLevel::       ds MAX_PARTY               ; 1..MAX_LEVEL per member
wPartyXP::          ds MAX_PARTY * 2           ; 16-bit LE cumulative XP per member
; Inventory: BAG_MAX stacks of {item id, count}; 0 = empty. Compacted on removal.
wBag::              ds BAG_MAX * 2

; Battery-backed save (menu.asm SAVE option). MBC5+RAM+battery (-m 0x1B); the
; RAM enable/bank writes bracket every access. sMagic+sChecksum validate a block.
SECTION "SaveData", SRAM
sMagic::            ds 2               ; "ZB" — a written, valid save
sVersion::          ds 1
sSeed::             ds 1               ; hWorldSeed (which world this is)
sPlayerWX::         ds 2
sPlayerWY::         ds 2
sSpawnWX::          ds 2
sSpawnWY::          ds 2
sHP::               ds 1
sFood::             ds 1
sEnergy::           ds 1
sFuel::             ds 1
sClockH::           ds 1
sClockM::           ds 1
sPartyCount::       ds 1
sPartyEquip::       ds MAX_PARTY * EQUIP_SLOTS
sPartyLevel::       ds MAX_PARTY               ; save version 2: levels + XP
sPartyXP::          ds MAX_PARTY * 2
sBag::              ds BAG_MAX * 2
sOptMusic::         ds 1
sOptSfx::           ds 1               ; save version 3: SFX on/off
sChecksum::         ds 1               ; 8-bit sum of every byte above

; Battle mode (turn-based combat screen) — see battle.asm. A dedicated scratch
; region, fully cleared on EnterBattle so no stale fight leaks in (design 04 §6);
; wBattleGuard is a $C5 canary the poison test asserts survives.
SECTION "Battle State", WRAM0
wBattleState::      ds 1               ; BS_*
wBattleMenu::       ds 1               ; BM_MAIN / BM_FIGHT
wBattleCursor::     ds 1               ; 0..3 (bit0 = col, bit1 = row)
wBattleOutcome::    ds 1               ; BO_*
wBattleEKind::      ds 1               ; EPK_* (which portrait table)
wBattleEIdx::       ds 1               ; enemy portrait index
wBattleFoe::        ds 1               ; zombie pool index to despawn on a win,
                                       ; or $FF (survivor fight — nothing to remove)
; Enemy stats (copied from the ZombieTable row on entry)
wEnemyMaxHP::       ds 1
wEnemyHP::          ds 1
wEnemyATK::         ds 1
wEnemyDEF::         ds 1
wEnemyName::        ds 2               ; ptr to the enemy's name string
; Free-moving crosshair (slice 2). wCrossX/Y are its SCREEN pixel position, set
; each frame from wCrossPhase along the chosen orbit path (see wBattlePattern in
; the Battle Foes section below).
wCrossX::           ds 1               ; crosshair screen X (0..159)
wBattleWeapon::     ds 1               ; weapon index chosen for the current lock
wSkillCd::          ds SKILL_COUNT     ; per-skill cooldown counters
wBattleMsgNext::    ds 1               ; BS_* to enter when the message is A'd
; Message / menu paint buffer: composed in the logic phase, revealed to SCRN1
; a few cells per frame (bounded) via the write queue.
wBattleBox::        ds BATTLE_BOX_CELLS
wBoxPos::           ds 1               ; next cell to paint (== CELLS: done)
wBattleGuard::      ds 1               ; $C5 canary (see above)
; VRAM write queue: logic fills (bounded), the battle VBlank path drains fully.
wBattleQN::         ds 1
wBattleQ::          ds BATTLEQ_CAP * 3 ; {addrHi, addrLo, value}

; --- slice 2: the approaching-zombie arena (battle.asm) ---------------------
; Up to MAX_FOES foes as one interleaved struct array (index 0 = the spotter /
; lead). A zombie foe grows a TIER each enemy turn and only bites at
; FOE_TIER_MAX; a survivor foe (drawn as the persona portrait) is always in
; melee. wEnemy* above mirror the TARGETED foe for the shared HP-bar/tests.
SECTION "Battle Foes", WRAM0
wFoes::             ds MAX_FOES * FOE_STRUCT
wFoeCount::         ds 1               ; foes on screen (slots in use)
wFoeReserve::       ds 1               ; zombies still waiting behind — a slot that
                                       ; empties pulls one in until this hits 0
wFoeTarget::        ds 1               ; foe the last shot resolved against
wEncBiome::         ds 1               ; BIOME_* where the fight started (backdrop)
; Player combat values, derived from the real party stats (GetStat) once at
; battle entry — the engine runs in the battle bank where the BANK[1] stat tables
; aren't mapped, so they're cached here by the ROM0 entry trampoline instead.
wPlyLevel::         ds 1               ; cached wPartyLevel[0] (foe levels track it)
wPlyMelee::         ds 1               ; STR >> PLY_ATK_SHIFT (melee damage bonus)
wPlyRanged::        ds 1               ; DEX >> PLY_ATK_SHIFT (ranged damage bonus)
wPlyDef::           ds 1               ; IMM >> PLY_DEF_SHIFT (bite reduction)
wPlyCrit::          ds 1               ; ACC >> PLY_CRIT_SHIFT (crit damage bonus)
wBattleItemMap::    ds 4               ; the ITEM_* offered in each Item-menu slot
wSeedTier::         ds 1               ; start tier passed to SeedFoeSlot
; SeedFoeSlot / ScaleFoeStats scratch (Rand clobbers registers, so results park
; in RAM between the random rolls and the struct write).
wSeedIdx::          ds 1
wSeedHP::           ds 1
wSeedATK::          ds 1
wSeedDEF::          ds 1
wSeedLv1::          ds 1
wCrossY::           ds 1               ; crosshair screen Y (wCrossX = screen X now)
wCrossPhase::       ds 1               ; orbit phase (indexes the sine LUT)
wBattlePattern::    ds 1               ; PAT_CIRCLE / PAT_FIGURE8 (chosen on entry)
wFoeFlip::          ds 1               ; 0/1 walk-shuffle mirror frame
wFoeFlipTimer::     ds 1               ; frames until the next mirror flip
wArenaDirty::       ds 1               ; nonzero: repaint the arena this VBlank
; FoeBox scratch — the on-screen tile rectangle of the foe being drawn/tested.
wFoeBC::            ds 1               ; block col base (SCRN1 column)
wFoeBR::            ds 1               ; block row base
wFoeBW::            ds 1               ; width in tiles
wFoeBH::            ds 1               ; height in tiles
wFoeBHead::         ds 1               ; head rows (top band = crit on a hit)
wFoeBOff::          ds 1               ; tier's first atlas tile (offset from FOE_ATLAS_BASE)
wFoePalTmp::        ds 1               ; scratch: the foe's BG palette while painting
wBiteAcc::          ds 1               ; scratch: melee damage summed over the enemy turn
wHpSum::            ds 2               ; scratch: Σ foe HP (16-bit) for the overall bar
wHpMax::            ds 2               ; scratch: Σ foe MAXHP (16-bit)
wBattleXP::         ds 2               ; XP earned this fight (Σ level*XP_PER_LEVEL),
                                       ; granted to the party on a win

SECTION "HRAM Vars", HRAM
hVBlankFlag::       ds 1               ; set by the VBlank IRQ
hIsCGB::            ds 1               ; 1 = Game Boy Color, 0 = DMG (set at boot,
                                       ; lives in HRAM so ClearRAM can't wipe it)
hWorldSeed::        ds 1               ; the world-gen seed (set on the title
                                       ; screen; HRAM keeps Hash8's read cheap)
hOAMDMA::           ds 16              ; OAM DMA trampoline (copied here at boot)
