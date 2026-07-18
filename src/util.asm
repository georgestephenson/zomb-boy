; =============================================================================
; util.asm — small reusable helpers (16-bit little-endian pointer math).
; =============================================================================
SECTION "Util", ROM0

; Inc16Ptr: increment the 16-bit LE value at HL. Clobbers A; advances HL.
Inc16Ptr::
    inc [hl]
    ret nz                      ; low byte didn't wrap
    inc hl
    inc [hl]
    ret

; Dec16Ptr: decrement the 16-bit LE value at HL. Clobbers A; advances HL.
Dec16Ptr::
    ld a, [hl]
    dec [hl]
    and a
    ret nz                      ; low byte wasn't 0 -> no borrow
    inc hl
    dec [hl]
    ret

; Add16Ptr: add A (0..255) to the 16-bit LE value at HL. Clobbers A, B; HL ends
; at the high byte.
Add16Ptr::
    ld b, a
    ld a, [hl]
    add a, b
    ld [hl+], a
    ld a, [hl]
    adc a, 0
    ld [hl], a
    ret
