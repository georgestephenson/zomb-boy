; =============================================================================
; perm.inc — the 256-byte permutation table for the world-gen value-noise hash.
;
; SINGLE SOURCE OF TRUTH, referenced directly by both consumers (no copying):
;   * src/world.asm  INCLUDEs it into `PermTable` (compile-time -> static ROM
;     table, zero runtime cost).
;   * test/model/worldgen_model.py parses the `$xx` bytes below at import.
; A fixed permutation of 0..255 (order is arbitrary but must be a permutation);
; edit here only, and the streaming integration test will catch any asm<->model
; drift. Just `db` bytes — no SECTION/label (world.asm provides those).
; =============================================================================
    db $A6,$A4,$FA,$FE,$A9,$93,$CF,$C1,$83,$46,$C2,$94,$9D,$D4,$8E,$FB
    db $DA,$E1,$AA,$AF,$3E,$7E,$F6,$F2,$74,$4F,$F8,$B3,$EF,$86,$10,$EA
    db $D2,$6A,$7C,$9A,$23,$91,$DC,$2B,$72,$E2,$D5,$69,$F4,$C4,$8D,$98
    db $68,$84,$88,$A5,$FF,$F0,$13,$C5,$85,$40,$79,$F3,$4D,$53,$50,$E3
    db $9C,$1F,$65,$7F,$92,$32,$24,$C7,$A2,$F1,$A0,$FD,$6F,$FC,$F9,$F5
    db $4B,$5D,$7A,$B7,$3A,$D0,$E0,$63,$E4,$D1,$B6,$15,$DB,$E8,$8C,$27
    db $BC,$61,$F7,$59,$2D,$DD,$42,$29,$57,$4E,$09,$67,$EB,$2E,$89,$A8
    db $43,$D7,$D6,$CD,$14,$90,$A1,$CC,$C0,$99,$26,$37,$5E,$9E,$33,$06
    db $18,$12,$64,$48,$0B,$75,$4A,$DE,$7D,$0F,$DF,$3C,$6B,$C3,$C8,$31
    db $E6,$51,$B4,$1B,$03,$66,$0C,$00,$AC,$60,$95,$8A,$54,$28,$05,$5F
    db $1E,$5A,$78,$4C,$3B,$AD,$80,$55,$0A,$01,$22,$04,$30,$ED,$21,$62
    db $20,$82,$11,$D9,$44,$08,$45,$EE,$41,$3D,$5B,$1A,$39,$07,$BB,$16
    db $B9,$52,$B1,$17,$9B,$56,$6C,$0D,$BA,$34,$BD,$8F,$AB,$36,$2A,$87
    db $1D,$1C,$B8,$70,$B5,$CA,$81,$77,$0E,$02,$38,$25,$BF,$CB,$A3,$73
    db $D3,$C6,$19,$47,$6E,$49,$B2,$71,$97,$CE,$5C,$6D,$2F,$BE,$E9,$A7
    db $AE,$C9,$E7,$7B,$96,$EC,$58,$B0,$35,$9F,$8B,$76,$2C,$D8,$E5,$3F
