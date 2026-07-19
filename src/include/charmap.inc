; =============================================================================
; charmap.inc — maps ASCII string literals to font tile ids (FONT_BASE order:
; space, A-Z, 0-9, . , ! ? ' -). Include AFTER constants.inc, and only in files
; that author font text — dialogue plus the title strings (string literals
; assemble straight to tile ids, so nothing translates at runtime).
; Control codes (CTRL_NOUN etc.) are emitted as explicit `db` bytes between
; string pieces — they deliberately have no charmap entry.
; =============================================================================
IF !DEF(CHARMAP_INC)
DEF CHARMAP_INC EQU 1

charmap " ", FONT_BASE + 0
charmap "A", FONT_BASE + 1
charmap "B", FONT_BASE + 2
charmap "C", FONT_BASE + 3
charmap "D", FONT_BASE + 4
charmap "E", FONT_BASE + 5
charmap "F", FONT_BASE + 6
charmap "G", FONT_BASE + 7
charmap "H", FONT_BASE + 8
charmap "I", FONT_BASE + 9
charmap "J", FONT_BASE + 10
charmap "K", FONT_BASE + 11
charmap "L", FONT_BASE + 12
charmap "M", FONT_BASE + 13
charmap "N", FONT_BASE + 14
charmap "O", FONT_BASE + 15
charmap "P", FONT_BASE + 16
charmap "Q", FONT_BASE + 17
charmap "R", FONT_BASE + 18
charmap "S", FONT_BASE + 19
charmap "T", FONT_BASE + 20
charmap "U", FONT_BASE + 21
charmap "V", FONT_BASE + 22
charmap "W", FONT_BASE + 23
charmap "X", FONT_BASE + 24
charmap "Y", FONT_BASE + 25
charmap "Z", FONT_BASE + 26
charmap "0", FONT_BASE + 27
charmap "1", FONT_BASE + 28
charmap "2", FONT_BASE + 29
charmap "3", FONT_BASE + 30
charmap "4", FONT_BASE + 31
charmap "5", FONT_BASE + 32
charmap "6", FONT_BASE + 33
charmap "7", FONT_BASE + 34
charmap "8", FONT_BASE + 35
charmap "9", FONT_BASE + 36
charmap ".", FONT_BASE + 37
charmap ",", FONT_BASE + 38
charmap "!", FONT_BASE + 39
charmap "?", FONT_BASE + 40
charmap "'", FONT_BASE + 41
charmap "-", FONT_BASE + 42

ENDC
