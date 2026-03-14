' ============================================
' Test 10 — Circles
' ============================================
'
' Focused test for CIRCLE primitive: filled, outline,
' concentric, overlapping, varying radii, edge cases.
'
' Exercises:
'   - CIRCLE filled and outline
'   - Small and large radii
'   - Concentric rings
'   - Overlapping transparent circles
'   - Circles at screen edges
'   - Single-pixel radius circle
'
' Renders to 640x480, holds for 5 seconds.

SCREEN 640, 480
SCREENTITLE "Test 10 — Circles"
SETTARGET 0

' ── Palette ──────────────────────────────────────────
PALETTE 16, 12, 12, 28        ' dark background
PALETTE 17, 255, 60, 60       ' red
PALETTE 18, 60, 255, 60       ' green
PALETTE 19, 60, 100, 255      ' blue
PALETTE 20, 255, 220, 40      ' yellow
PALETTE 21, 255, 60, 220      ' magenta
PALETTE 22, 40, 220, 220      ' cyan
PALETTE 23, 255, 140, 40      ' orange
PALETTE 24, 160, 100, 255     ' purple
PALETTE 25, 255, 255, 255     ' white
PALETTE 26, 140, 140, 160     ' grey
PALETTE 27, 80, 80, 100       ' dark grey
PALETTE 28, 200, 200, 220     ' light grey

GCLS 16

' ── Title ────────────────────────────────────────────
RECT 0, 0, 640, 22, 27, 1
DRAWTEXT 260, 5, "Test 10 — Circles", 25, 1

DIM i AS INTEGER

' ════════════════════════════════════════════════════
' SECTION 1: Basic filled circles (top-left)
' ════════════════════════════════════════════════════

DRAWTEXT 20, 30, "Filled circles", 25, 0

' Row of filled circles, increasing size
CIRCLE 50, 70, 8, 17, 1
CIRCLE 90, 70, 12, 18, 1
CIRCLE 145, 70, 18, 19, 1
CIRCLE 210, 70, 24, 20, 1
CIRCLE 290, 70, 32, 21, 1

' ════════════════════════════════════════════════════
' SECTION 2: Outline circles (top-right)
' ════════════════════════════════════════════════════

DRAWTEXT 370, 30, "Outline circles", 25, 0

' Row of outline circles, increasing size
CIRCLE 400, 70, 8, 17, 0
CIRCLE 440, 70, 12, 18, 0
CIRCLE 495, 70, 18, 19, 0
CIRCLE 560, 70, 24, 20, 0

' ════════════════════════════════════════════════════
' SECTION 3: Concentric rings (centre-left)
' ════════════════════════════════════════════════════

DRAWTEXT 20, 110, "Concentric rings", 25, 0

' 10 concentric outline circles from the same centre
FOR i = 1 TO 10
  CIRCLE 120, 180, i * 7, 16 + (i MOD 12), 0
NEXT i

' ════════════════════════════════════════════════════
' SECTION 4: Concentric filled (centre)
' ════════════════════════════════════════════════════

DRAWTEXT 230, 110, "Concentric filled", 25, 0

' Filled concentric — draw largest first (painter's algo)
CIRCLE 320, 180, 50, 17, 1
CIRCLE 320, 180, 42, 19, 1
CIRCLE 320, 180, 34, 20, 1
CIRCLE 320, 180, 26, 22, 1
CIRCLE 320, 180, 18, 23, 1
CIRCLE 320, 180, 10, 24, 1
CIRCLE 320, 180, 4, 25, 1

' ════════════════════════════════════════════════════
' SECTION 5: Overlapping filled circles (right)
' ════════════════════════════════════════════════════

DRAWTEXT 430, 110, "Overlapping", 25, 0

' Three overlapping filled circles (Venn diagram)
CIRCLE 500, 165, 35, 17, 1
CIRCLE 535, 195, 35, 19, 1
CIRCLE 465, 195, 35, 20, 1

' Outline to define boundaries
CIRCLE 500, 165, 35, 25, 0
CIRCLE 535, 195, 35, 25, 0
CIRCLE 465, 195, 35, 25, 0

' ════════════════════════════════════════════════════
' SECTION 6: Tiny circles / edge cases (bottom-left)
' ════════════════════════════════════════════════════

DRAWTEXT 20, 250, "Tiny radii (1-5)", 25, 0

' Very small radii
CIRCLE 40, 285, 1, 17, 1
CIRCLE 60, 285, 2, 18, 1
CIRCLE 85, 285, 3, 19, 1
CIRCLE 115, 285, 4, 20, 1
CIRCLE 150, 285, 5, 21, 1

' Same but outline
CIRCLE 40, 315, 1, 17, 0
CIRCLE 60, 315, 2, 18, 0
CIRCLE 85, 315, 3, 19, 0
CIRCLE 115, 315, 4, 20, 0
CIRCLE 150, 315, 5, 21, 0

' ════════════════════════════════════════════════════
' SECTION 7: Large circle (bottom-centre)
' ════════════════════════════════════════════════════

DRAWTEXT 230, 250, "Large circle", 25, 0

CIRCLE 320, 370, 80, 22, 0
CIRCLE 320, 370, 78, 19, 0
CIRCLE 320, 370, 60, 24, 1
CIRCLE 320, 370, 40, 20, 1
CIRCLE 320, 370, 20, 22, 1

' ════════════════════════════════════════════════════
' SECTION 8: Circle grid (bottom-right)
' ════════════════════════════════════════════════════

DRAWTEXT 450, 250, "Grid pattern", 25, 0

DIM row AS INTEGER, col AS INTEGER
FOR row = 0 TO 4
  FOR col = 0 TO 4
    DIM gc AS INTEGER
    gc = 17 + (row + col) MOD 8
    IF (row + col) MOD 2 = 0 THEN
      CIRCLE 470 + col * 30, 280 + row * 30, 10, gc, 1
    ELSE
      CIRCLE 470 + col * 30, 280 + row * 30, 10, gc, 0
    END IF
  NEXT col
NEXT row

' ── Edge circles: partially off-screen ───────────────
DRAWTEXT 20, 340, "Edge clipping", 25, 0

' Circles touching or exceeding screen edges
CIRCLE 0, 400, 25, 23, 1
CIRCLE 639, 400, 25, 22, 1
CIRCLE 100, 479, 25, 21, 1

' ── Footer ───────────────────────────────────────────

DRAWTEXT 250, 465, "Test 10 — Circles complete", 25, 0

' ── Hold for 5 seconds ───────────────────────────────
DIM frame AS INTEGER
frame = 0
DO
  VSYNC
  frame = frame + 1
LOOP UNTIL frame >= 300

SCREENCLOSE
END
