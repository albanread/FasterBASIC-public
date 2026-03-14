' ============================================
' Test 04 — GPU Palette Animation Effects
' ============================================
'
' Demonstrates GPU-driven palette animation with
' LARGE, HIGH-CONTRAST, UNMISSABLE effects.
'
' Runs for 480 frames (~8 seconds) then exits.

SCREEN 320, 200
SCREENTITLE "Test 04 — Palette Effects"

' ── Background ───────────────────────────────────────
PALETTE 16, 20, 20, 30         ' dark background
GCLS 16

' ════════════════════════════════════════════════════
' SECTION 1: PALGRADIENT — Full-width raster bars
' ════════════════════════════════════════════════════
' Per-line palette index 2, covering lines 8–55
' Should show vivid red-to-cyan horizontal bars

DRAWTEXT 4, 0, "GRADIENT:", 15, 0

DIM i AS INTEGER
FOR i = 8 TO 55
  GLINE 0, i, 319, i, 2
NEXT i

PALGRADIENT 0, 2, 8, 55, 255, 0, 0, 0, 255, 255

' ════════════════════════════════════════════════════
' SECTION 2: PALCYCLE — Big rainbow blocks
' ════════════════════════════════════════════════════
' Global palette 32–39, speed 4 (fast cycling)

DRAWTEXT 4, 58, "CYCLE:", 15, 0

PALETTE 32, 255, 0, 0
PALETTE 33, 255, 160, 0
PALETTE 34, 255, 255, 0
PALETTE 35, 0, 255, 0
PALETTE 36, 0, 255, 255
PALETTE 37, 0, 0, 255
PALETTE 38, 160, 0, 255
PALETTE 39, 255, 0, 160

FOR i = 0 TO 7
  RECT i * 40, 68, 38, 28, 32 + i, 1
NEXT i

PALCYCLE 2, 32, 39, 4, 1

' ════════════════════════════════════════════════════
' SECTION 3: PALSTROBE — Flashing warning bar
' ════════════════════════════════════════════════════
' Alternates WHITE and RED — impossible to miss
' 20 frames on, 20 frames off = ~1.5 Hz flash

DRAWTEXT 4, 100, "STROBE:", 15, 0

PALETTE 56, 255, 255, 255

RECT 0, 110, 320, 30, 56, 1
DRAWTEXT 88, 117, "!! ALERT !!", 1, 1

PALSTROBE 4, 56, 20, 20, 255, 255, 255, 255, 0, 0

' ════════════════════════════════════════════════════
' SECTION 4: PALPULSE — Glowing text (large)
' ════════════════════════════════════════════════════
' Oscillates between BLACK and BRIGHT GREEN
' Speed 40 = ~1.5 Hz pulse — very visible

PALETTE 48, 0, 0, 0

DRAWTEXT 40, 148, "* PULSING TEXT *", 48, 1

PALPULSE 3, 48, 40, 0, 0, 0, 0, 255, 0

' ════════════════════════════════════════════════════
' SECTION 5: PALFADE — Panel fades from black
' ════════════════════════════════════════════════════
' Palette 64 fades from black to bright yellow
' over 180 frames (~3 seconds)

PALETTE 64, 0, 0, 0
PALETTE 65, 0, 0, 0

RECT 0, 170, 320, 30, 64, 1
DRAWTEXT 60, 178, "FADE IN SLOWLY...", 65, 1

PALFADE 5, 64, 180, 0, 0, 0, 255, 255, 0
PALFADE 6, 65, 240, 0, 0, 0, 255, 255, 255

' ── Present and run ──────────────────────────────────
FLIP

DIM frame AS INTEGER
frame = 0

DO
  VSYNC
  frame = frame + 1
LOOP UNTIL frame >= 480

PALSTOPALL
SCREENCLOSE
END
