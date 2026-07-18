; =============================================================================
; rng.asm — pseudo-random numbers for dynamic behavior (zombie wandering).
; This is deliberately separate from the world generator's hash: world terrain
; must be deterministic/reproducible, but wandering should feel unpredictable.
; 16-bit Galois LFSR (poly $B400), advanced a full byte per call.
; =============================================================================
INCLUDE "include/constants.inc"

SECTION "RNG", ROM0

; Rand: advance the LFSR by 8 bits, return a fresh byte in A. Seed (wRngState)
; must be non-zero. Clobbers B, H, L.
Rand::
    ld a, [wRngState]
    ld l, a
    ld a, [wRngState+1]
    ld h, a                     ; HL = state
    ld b, 8
.bit:
    srl h
    rr l                        ; shift right; bit shifted out -> carry
    jr nc, .skip
    ld a, h
    xor $B4                     ; feedback tap (high byte of $B400)
    ld h, a
.skip:
    dec b
    jr nz, .bit
    ld a, l
    ld [wRngState], a
    ld a, h
    ld [wRngState+1], a
    ld a, l
    ret
