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
; House pass scratch (city biome): building size + this tile's offset into it.
wHW::               ds 1               ; house width
wHH::               ds 1               ; house height
wHDX::              ds 1               ; this tile's dx within the house bbox
wHDY::              ds 1               ; ... and dy

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
wLosCount::         ds 1               ; occlusion-walk counter (survives Gen calls)
wScrX::             ds 1               ; scratch: on-screen sprite X
wScrY::             ds 1               ; scratch: on-screen sprite Y
wEnt::              ds ENT_SIZE        ; the entity currently being processed
wZombies::          ds MAX_ZOMBIES * ENT_SIZE

; Survivor NPCs (same 16-byte entity struct; EO_PERSONA/EO_AFFIN in 13/14).
SECTION "NPC State", WRAM0
wNPCs::             ds MAX_NPCS * ENT_SIZE
wNPCIdx::           ds 1               ; loop index into wNPCs

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
; The 3x18 text grid (font tile ids). wTalkGuard is a canary: set to $C5 on
; talk entry and never written again — the composer is bounds-checked and the
; integration tests assert it survives (docs/design/05 §3 memory safety).
wTalkText::         ds TALK_TEXT_MAX
wTalkGuard::        ds 1
; VRAM write queue: logic fills (bounded), the talk VBlank path drains fully.
wTalkQN::           ds 1               ; entries used this frame
wTalkQ::            ds TALKQ_CAP * 3   ; {addrHi, addrLo, value}

SECTION "HRAM Vars", HRAM
hVBlankFlag::       ds 1               ; set by the VBlank IRQ
hIsCGB::            ds 1               ; 1 = Game Boy Color, 0 = DMG (set at boot,
                                       ; lives in HRAM so ClearRAM can't wipe it)
hOAMDMA::           ds 16              ; OAM DMA trampoline (copied here at boot)
