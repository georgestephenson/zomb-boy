; =============================================================================
; input.asm — joypad read with edge detection.
; Fills wCurKeys (held), wNewKeys (pressed this frame). Bit set = pressed,
; layout = PAD_* in constants.inc.
; =============================================================================
INCLUDE "hardware.inc"
INCLUDE "include/constants.inc"

SECTION "Input", ROM0

ReadInput::
    ; --- buttons (A,B,Select,Start) -> high nibble ---
    ld a, P1F_GET_BTN
    ldh [rP1], a
    ldh a, [rP1]
    ldh a, [rP1]                ; read twice to debounce
    and $0F
    swap a
    ld b, a
    ; --- d-pad (Right,Left,Up,Down) -> low nibble ---
    ld a, P1F_GET_DPAD
    ldh [rP1], a
    ldh a, [rP1]
    ldh a, [rP1]
    ldh a, [rP1]
    ldh a, [rP1]
    and $0F
    or b                        ; combine; 0 = pressed at this point
    cpl                         ; invert -> 1 = pressed
    ld b, a
    ; release the pad
    ld a, P1F_GET_NONE
    ldh [rP1], a
    ; edge detect: new = current AND NOT previous
    ld a, [wPrevKeys]
    cpl
    and b
    ld [wNewKeys], a
    ld a, b
    ld [wCurKeys], a
    ld [wPrevKeys], a
    ret
