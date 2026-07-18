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
wHX::               ds 2
wHY::               ds 2

; Input
wCurKeys::          ds 1               ; held this frame (1 = pressed)
wNewKeys::          ds 1               ; pressed this frame (edge)
wPrevKeys::         ds 1
wMoveCooldown::     ds 1

; Player animation / movement
wMoveDir::          ds 1               ; DIR_* set by UpdatePlayer this frame
wFacing::           ds 1               ; 0 down, 1 up, 2 side
wWalkFrame::        ds 1               ; 0/1 walk-cycle frame
wFlip::             ds 1               ; OAM attr (OAMF_XFLIP for facing left)
wCurTile::          ds 1               ; scratch: last generated tile type

; VRAM streaming: one column/row of fresh tiles queued for the next VBlank.
; Buffer holds quads {addrLo, addrHi, tile, attr} so the VBlank blit is tight.
wStrKind::          ds 1               ; 0 = nothing pending, 1 = pending
wStrLen::           ds 1               ; number of quads
wStrIsCol::         ds 1               ; 1 = vertical strip, 0 = horizontal
wStrI::             ds 1               ; fill-loop counter
wBufPtr::           ds 2               ; fill-loop write pointer
wStrBuf::           ds 24 * 4          ; up to 24 quads

SECTION "HRAM Vars", HRAM
hVBlankFlag::       ds 1               ; set by the VBlank IRQ
hOAMDMA::           ds 16              ; OAM DMA trampoline (copied here at boot)
