; =============================================================================
; audio.asm — music + sound-effects seam over the vendored hUGEDriver.
; -----------------------------------------------------------------------------
; The driver itself (vendor/hUGEDriver/hUGEDriver.asm) and the song data
; (vendor/hUGEDriver/songs/*.asm) are third-party, assembled separately and
; linked in (see the Makefile's AUDIO_OBJS). This module is the *game-side*
; wrapper: the rest of the game asks for a track by id or an SFX by id and never
; touches driver internals or channel registers directly.
;
;   InitSound        — power the APU on and start the title theme.
;   PlayMusic        — switch to a track by id (no-op if that song's already on).
;   UpdateSound      — advance playback one tick; call once per frame.
;   UpdateWorldMusic — pick the overworld track from the player's biome.
;   PlaySFX          — fire a short one-shot sound effect (channel 1).
;   PlaySplash / PlayCarDoor — bespoke channel-4 blips (kept from before).
;
; ---------------------------------------------------------------------------
; MUSIC: one asset, many slots (PLACEHOLDERS)
; ---------------------------------------------------------------------------
; The design wants distinct music per screen — a title theme, eight overworld
; tracks (one per biome group), and a dialogue theme per persona. We only have
; ONE composed song so far (the vendored public-domain demo), so EVERY slot in
; MusicTracks points at it as a placeholder. PlayMusic compares the *song* (not
; the track id), so requesting a different slot that resolves to the same asset
; is a no-op — the demo just keeps playing seamlessly as you move between
; screens. The moment real songs are dropped in and the table entries updated,
; the per-screen switching below starts working with no other code changes.
;   >>> TODO(music): replace the placeholder song per MusicTracks entry with a
;   >>> real composed track (each in its OWN ROM bank — a full song is large;
;   >>> see vendor/hUGEDriver/PROVENANCE.md for the export/vendoring flow). The
;   >>> label on every entry says exactly where that track is heard.
;
; BANKING: song data lives in ROMX (its own bank, since it outgrew bank 1 beside
; the dialogue data). Both driver entry points read song data, so InitSound/
; PlayMusic/UpdateSound bracket the driver calls with a switch to the song's bank
; (remembered in wMusicBank) and a restore of bank 1 — the repo invariant. The
; driver keeps only WRAM state between ticks, so nothing dangles across a switch.
; PlaySFX/PlaySplash/PlayCarDoor are pure register writes and need no banking.
; =============================================================================
INCLUDE "hardware.inc"
INCLUDE "include/constants.inc"

SECTION "Audio", ROM0

; -----------------------------------------------------------------------------
; InitSound: turn the APU on and start the title theme. Call once at boot, after
; the LCD/content is set up and before the title loop (hUGEDriver requires the
; APU enabled before hUGE_init). Supersedes the boot-time InitAudio silence.
; -----------------------------------------------------------------------------
InitSound::
    ld a, $80                       ; NR52: master enable (bit7). Must precede any
    ldh [rNR52], a                  ;       other APU writes — regs ignore writes off.
    ld a, $FF                       ; NR51: every channel routed to both L and R.
    ldh [rNR51], a
    ld a, $77                       ; NR50: max master volume, left and right.
    ldh [rNR50], a
    xor a, a                        ; "no song loaded yet" so PlayMusic really inits
    ld [wMusicSong], a
    ld [wMusicSong+1], a
    ld [wMusicBank], a
    ld a, TRK_TITLE
    jp PlayMusic                    ; tail-call: load + start the title theme

; -----------------------------------------------------------------------------
; PlayMusic: A = TRK_* track id. Look the track up in MusicTracks, and if it
; resolves to a DIFFERENT song than the one currently loaded, (re)initialise the
; driver on it. If it's the same song (e.g. two world biomes sharing the one
; placeholder asset), do nothing — the music plays on uninterrupted. Clobbers
; a/bc/de/hl (hUGE_init clobbers freely; callers must tolerate it).
; -----------------------------------------------------------------------------
PlayMusic::
    ld e, a
    ld d, 0
    ld hl, MusicTracks
    add hl, de                      ; hl = MusicTracks + 3*track (entry = db bank, dw ptr)
    add hl, de
    add hl, de
    ld a, [hl+]                     ; B = the track's song bank
    ld b, a
    ld a, [hl+]                     ; DE = the song descriptor pointer (little-endian)
    ld e, a
    ld a, [hl]
    ld d, a
    ; already playing this exact song? (compare bank + pointer)
    ld a, [wMusicBank]
    cp b
    jr nz, .switch
    ld a, [wMusicSong]
    cp e
    jr nz, .switch
    ld a, [wMusicSong+1]
    cp d
    ret z                           ; same song already loaded -> keep it playing
.switch:
    ld a, b
    ld [wMusicBank], a              ; remember the new song for UpdateSound's banking
    ld a, e
    ld [wMusicSong], a
    ld a, d
    ld [wMusicSong+1], a
    ld a, b
    ld [rROMB0], a                  ; map the song's bank for hUGE_init to read
    ld h, d
    ld l, e                         ; HL = song descriptor
    call hUGE_init
    ld a, 1
    ld [rROMB0], a                  ; restore the default (dialogue) bank
    ret

; -----------------------------------------------------------------------------
; UpdateSound: advance the music one tick. Call at a steady once-per-frame rate;
; the main loop is frame-locked by WaitVBlank, so calling it once per iteration
; (outside the VBlank window) is exactly one call per frame. Maps the current
; song's bank (the driver re-reads pattern bytes each tick), then restores bank 1.
; -----------------------------------------------------------------------------
UpdateSound::
    ld a, [wMusicBank]
    ld [rROMB0], a
    call hUGE_dosound
    ld a, 1                         ; back to the default (dialogue) bank
    ld [rROMB0], a
    ret

; -----------------------------------------------------------------------------
; UpdateWorldMusic: choose the overworld track from the biome under the player
; and request it (a no-op while every biome shares the placeholder song). Called
; each sustained-overworld frame, so it also restores the world track when you
; step back out of a dialogue. CalcBiome is memoized; this touches no RNG, so
; worldgen/spawn determinism is unperturbed.
; -----------------------------------------------------------------------------
UpdateWorldMusic::
    call GenFromPlayer              ; wGen = player's world tile (entity.asm)
    ld a, [wGenX]
    ld [wBiX], a
    ld a, [wGenX+1]
    ld [wBiX+1], a
    ld a, [wGenY]
    ld [wBiY], a
    ld a, [wGenY+1]
    ld [wBiY+1], a
    call CalcBiome                  ; A = BIOME_* at the player
    ld e, a
    ld d, 0
    ld hl, WorldTrackForBiome
    add hl, de
    ld a, [hl]                      ; TRK_WORLD_* for this biome group
    ld [wWorldTrack], a
    jp PlayMusic                    ; tail-call

; -----------------------------------------------------------------------------
; PlaySFX: A = SFX_* id. Fire a short one-shot blip on channel 1 (pulse) by
; writing its five register bytes from SFXTable and triggering. The music driver
; re-owns the channel on its next tick, so the effect is a brief attack layered
; over the music — the same channel-borrowing trick as PlaySplash. Silenced with
; the music when the OPTIONS toggle unroutes the channels (NR51=0). Clobbers a/de/hl.
; -----------------------------------------------------------------------------
PlaySFX::
    ld e, a
    ld d, 0
    ld hl, SFXTable
    add hl, de                      ; hl = SFXTable + 5*id
    add hl, de
    add hl, de
    add hl, de
    add hl, de
    ld a, [hl+]
    ldh [rNR10], a                  ; sweep
    ld a, [hl+]
    ldh [rNR11], a                  ; duty + length
    ld a, [hl+]
    ldh [rNR12], a                  ; envelope (volume + decay)
    ld a, [hl+]
    ldh [rNR13], a                  ; frequency low
    ld a, [hl]
    ldh [rNR14], a                  ; trigger + length-enable + frequency high
    ret

; Play a short splash blip on the noise channel (ch4) for entering/leaving water.
; This writes ch4 directly, borrowing it from the music for an instant: the driver
; re-owns the channel on its next tick, which is exactly a splash's length anyway.
; NR51 (set in InitSound) already routes ch4 to both speakers.
PlaySplash::
    ld a, %00110000                 ; NR41: length timer (64-t) -> a brief burst
    ldh [rNR41], a
    ld a, $F2                       ; NR42: full volume, envelope down (quick decay)
    ldh [rNR42], a
    ld a, $37                       ; NR43: noise divisor/shift -> a wet "plip" pitch
    ldh [rNR43], a
    ld a, $C0                       ; NR44: trigger (bit7) + length-enable (bit6)
    ldh [rNR44], a
    ret

; Play a short low "clunk" on the noise channel (ch4) for boarding/leaving the
; car — a stylised door thud, lower and with a touch more body than the splash.
; Same channel-borrowing trick as PlaySplash (the music re-owns ch4 next tick).
PlayCarDoor::
    ld a, %00100000                 ; NR41: length timer -> a bit more body than a splash
    ldh [rNR41], a
    ld a, $F3                       ; NR42: full volume, slower decay (a short ring)
    ldh [rNR42], a
    ld a, $59                       ; NR43: low, buzzy divisor/shift -> a door "thunk"
    ldh [rNR43], a
    ld a, $C0                       ; NR44: trigger (bit7) + length-enable (bit6)
    ldh [rNR44], a
    ret

; =============================================================================
; Data
; =============================================================================
SECTION "Audio Tables", ROM0

; -----------------------------------------------------------------------------
; Music track table (indexed by TRK_*). Each entry is `db songBank` then
; `dw songPtr` (3 bytes). EVERY entry is the vendored demo song for now — a
; PLACEHOLDER. The comment on each line is where that track plays; replace the
; asset (and give it its own bank) to make the game's music per-screen. See the
; big TODO(music) at the top of this file.
; -----------------------------------------------------------------------------
MusicTracks::
    db BANK(song_demo)
    dw song_demo                    ; TRK_TITLE   — title screen         TODO(music): real title theme
    db BANK(song_demo)
    dw song_demo                    ; TRK_WORLD_0 — overworld: city/ruins TODO(music): urban theme
    db BANK(song_demo)
    dw song_demo                    ; TRK_WORLD_1 — overworld: plains/farm TODO(music): open/pastoral theme
    db BANK(song_demo)
    dw song_demo                    ; TRK_WORLD_2 — overworld: forest/jungle TODO(music): green/wild theme
    db BANK(song_demo)
    dw song_demo                    ; TRK_WORLD_3 — overworld: marsh      TODO(music): wet/uneasy theme
    db BANK(song_demo)
    dw song_demo                    ; TRK_WORLD_4 — overworld: graveyard  TODO(music): eerie theme
    db BANK(song_demo)
    dw song_demo                    ; TRK_WORLD_5 — overworld: desert     TODO(music): arid theme
    db BANK(song_demo)
    dw song_demo                    ; TRK_WORLD_6 — overworld: mountains  TODO(music): high/sparse theme
    db BANK(song_demo)
    dw song_demo                    ; TRK_WORLD_7 — overworld: tundra     TODO(music): cold theme
    ; --- per-persona dialogue themes (TRK_TALK_0 + persona id) ---
    db BANK(song_demo)
    dw song_demo                    ; TRK_TALK_0  — talk: persona 0 (police)  TODO(music): persona theme
    db BANK(song_demo)
    dw song_demo                    ; TRK_TALK_1  — talk: persona 1            TODO(music): persona theme
    db BANK(song_demo)
    dw song_demo                    ; TRK_TALK_2  — talk: persona 2            TODO(music): persona theme
    db BANK(song_demo)
    dw song_demo                    ; TRK_TALK_3  — talk: persona 3            TODO(music): persona theme
    db BANK(song_demo)
    dw song_demo                    ; TRK_TALK_4  — talk: persona 4            TODO(music): persona theme
    db BANK(song_demo)
    dw song_demo                    ; TRK_TALK_5  — talk: persona 5            TODO(music): persona theme
    db BANK(song_demo)
    dw song_demo                    ; TRK_TALK_6  — talk: persona 6            TODO(music): persona theme
    db BANK(song_demo)
    dw song_demo                    ; TRK_TALK_7  — talk: persona 7            TODO(music): persona theme
    db BANK(song_demo)
    dw song_demo                    ; TRK_TALK_8  — talk: persona 8            TODO(music): persona theme
    db BANK(song_demo)
    dw song_demo                    ; TRK_TALK_9  — talk: persona 9            TODO(music): persona theme

; Map each biome to one of the eight world tracks (indexed by BIOME_*). Groups
; related biomes so the eight tracks cover all eleven biomes with a coherent
; mood per region.
WorldTrackForBiome::
    db TRK_WORLD_0     ; BIOME_CITY      urban
    db TRK_WORLD_1     ; BIOME_PLAINS    open
    db TRK_WORLD_2     ; BIOME_FOREST    green
    db TRK_WORLD_3     ; BIOME_MARSH     wet
    db TRK_WORLD_0     ; BIOME_RUINS     urban (broken city)
    db TRK_WORLD_1     ; BIOME_FARM      open (fields)
    db TRK_WORLD_2     ; BIOME_JUNGLE    green (dense)
    db TRK_WORLD_4     ; BIOME_GRAVEYARD eerie
    db TRK_WORLD_5     ; BIOME_DESERT    arid
    db TRK_WORLD_6     ; BIOME_MOUNTAINS high
    db TRK_WORLD_7     ; BIOME_TUNDRA    cold

; Sound-effect table (indexed by SFX_*): five channel-1 register bytes each —
; NR10 (sweep), NR11 (duty+length), NR12 (envelope), NR13 (freq low), NR14
; (trigger+len-enable+freq high). These are hand-tuned by ear on the design's
; intent; feel free to nudge the pitches/decays — they're just data.
;   TODO(sfx): tune final values on real hardware / mGBA (PyBoy proves they fire,
;   not how they sound).
SFXTable::
    db $34, $80, $81, $60, $C6      ; SFX_BUMP    — low thud, quick downward sweep (walls)
    db $00, $B8, $71, $00, $C7      ; SFX_MOVE    — tiny high click (cursor move)
    db $15, $86, $A3, $00, $C6      ; SFX_CONFIRM — rising "bwip" (select an option)
    db $24, $05, $81, $C0, $C5      ; SFX_CANCEL  — thin falling tone (back out)
    db $16, $86, $A4, $40, $C6      ; SFX_OPEN    — rising chirp (menu opens)
    db $36, $86, $94, $C0, $C6      ; SFX_CLOSE   — falling chirp (menu closes)
    db $13, $41, $63, $80, $C5      ; SFX_EAT     — soft low "nom" (consume food)
    db $00, $88, $C4, $C0, $C7      ; SFX_PICKUP  — bright "ding" (gear into the bag)
