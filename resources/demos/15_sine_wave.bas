' ============================================
' Test 15 — Sine Wave (PSET Pixel Plotting)
' ============================================
'
' Focused test for PSET pixel-by-pixel drawing
' using sine waves and related curves.
'
' Exercises:
'   - PSET at various screen positions
'   - Floating-point SIN / COS arithmetic
'   - Palette colour cycling across pixels
'   - Overlapping sine waves with different
'     frequencies, amplitudes, and phases
'   - Lissajous curve (parametric PSET)
'   - Dot-pattern grid via PSET
'
' Renders to 640x480, holds for 5 seconds.

SCREEN 640, 480,2
SCREENTITLE "Test 15 Sine Wave (PSET)  "
SETTARGET 0

' ── Palette ──────────────────────────────────────────
PALETTE 16, 10, 10, 20 ' dark background
PALETTE 17, 255, 60, 60 ' red
PALETTE 18, 255, 160, 40 ' orange
PALETTE 19, 255, 255, 60 ' yellow
PALETTE 20, 60, 255, 60 ' green
PALETTE 21, 60, 255, 200 ' teal
PALETTE 22, 60, 160, 255 ' sky blue
PALETTE 23, 100, 80, 255 ' blue-violet
PALETTE 24, 200, 60, 255 ' purple
PALETTE 25, 255, 60, 200 ' magenta
PALETTE 26, 255, 255, 255 ' white
PALETTE 27, 180, 180, 200 ' light grey
PALETTE 28, 100, 100, 120 ' mid grey
PALETTE 29, 60, 60, 80 ' dark grey

GCLS 16

' ── Title bar ────────────────────────────────────────
RECT 0, 0, 640, 18, 29, 1
DRAWTEXT 220, 4, "Test 15 Sine Wave (PSET Plotting) ", 26, 0

DIM i AS INTEGER
DIM py AS INTEGER
DIM px AS INTEGER
DIM c AS INTEGER

' ════════════════════════════════════════════════════
' SECTION 1: Basic sine wave (y = 30..100)
' ════════════════════════════════════════════════════
DRAWTEXT 10, 24, "Basic sine wave (amplitude 30, period 120px)", 27, 0

DIM baseline1 AS INTEGER
baseline1 = 68

' Draw faint centre line
FOR i = 0 TO 599
  PSET 20 + i, baseline1, 29
NEXT i

' Draw the sine wave
FOR i = 0 TO 599
  py = baseline1 + INT(SIN(i * 3.14159265 / 60.0) * 30.0)
  c = 17 + (i \ 75) MOD 9
  IF py >= 30 AND py <= 105 THEN
    PSET 20 + i, py, c
  END IF
NEXT i

' ════════════════════════════════════════════════════
' SECTION 2: Multi-frequency overlay (y = 110..200)
' ════════════════════════════════════════════════════
DRAWTEXT 10, 110, "Three overlapping sine waves", 27, 0

DIM baseline2 AS INTEGER
baseline2 = 158

' Centre line
FOR i = 0 TO 599
  PSET 20 + i, baseline2, 29
NEXT i

' Wave 1: low frequency, large amplitude (red)
FOR i = 0 TO 599
  py = baseline2 + INT(SIN(i * 3.14159265 / 100.0) * 35.0)
  IF py >= 118 AND py <= 198 THEN
    PSET 20 + i, py, 17
  END IF
NEXT i

' Wave 2: medium frequency, medium amplitude (green)
FOR i = 0 TO 599
  py = baseline2 + INT(SIN(i * 3.14159265 / 40.0) * 20.0)
  IF py >= 118 AND py <= 198 THEN
    PSET 20 + i, py, 20
  END IF
NEXT i

' Wave 3: high frequency, small amplitude (blue)
FOR i = 0 TO 599
  py = baseline2 + INT(SIN(i * 3.14159265 / 15.0) * 10.0)
  IF py >= 118 AND py <= 198 THEN
    PSET 20 + i, py, 22
  END IF
NEXT i

' Composite wave (all three summed, white)
FOR i = 0 TO 599
  DIM sum AS DOUBLE
  sum = SIN(i * 3.14159265 / 100.0) * 35.0
  sum = sum + SIN(i * 3.14159265 / 40.0) * 20.0
  sum = sum + SIN(i * 3.14159265 / 15.0) * 10.0
  py = baseline2 + INT(sum * 0.5)
  IF py >= 118 AND py <= 198 THEN
    PSET 20 + i, py, 26
  END IF
NEXT i

' ════════════════════════════════════════════════════
' SECTION 3: Lissajous curve (y = 210..350)
' ════════════════════════════════════════════════════
DRAWTEXT 10, 206, "Lissajous curve (3:2 ratio)", 27, 0

DIM lcx AS INTEGER, lcy AS INTEGER
lcx = 110
lcy = 285

' Draw bounding box outline with PSET dots
FOR i = 0 TO 139
  PSET lcx - 70 + i, lcy - 65, 29
  PSET lcx - 70 + i, lcy + 65, 29
NEXT i
FOR i = 0 TO 129
  PSET lcx - 70, lcy - 65 + i, 29
  PSET lcx + 70, lcy - 65 + i, 29
NEXT i

' Draw the Lissajous figure (3:2)
FOR i = 0 TO 3600
  DIM t AS DOUBLE
  t = i * 3.14159265 / 1800.0
  px = lcx + INT(SIN(3.0 * t) * 62.0)
  py = lcy + INT(SIN(2.0 * t) * 58.0)
  c = 17 + (i \ 400) MOD 9
  IF px >= 0 AND px <= 639 AND py >= 0 AND py <= 479 THEN
    PSET px, py, c
  END IF
NEXT i

' Second Lissajous (5:4 ratio) offset to the right
DIM lcx2 AS INTEGER, lcy2 AS INTEGER
lcx2 = 310
lcy2 = 285

FOR i = 0 TO 139
  PSET lcx2 - 70 + i, lcy2 - 65, 29
  PSET lcx2 - 70 + i, lcy2 + 65, 29
NEXT i
FOR i = 0 TO 129
  PSET lcx2 - 70, lcy2 - 65 + i, 29
  PSET lcx2 + 70, lcy2 - 65 + i, 29
NEXT i

FOR i = 0 TO 5400
  t = i * 3.14159265 / 2700.0
  px = lcx2 + INT(SIN(5.0 * t) * 62.0)
  py = lcy2 + INT(SIN(4.0 * t) * 58.0)
  c = 17 + (i \ 600) MOD 9
  IF px >= 0 AND px <= 639 AND py >= 0 AND py <= 479 THEN
    PSET px, py, c
  END IF
NEXT i

' Third Lissajous (1:1 = circle/ellipse) for comparison
DIM lcx3 AS INTEGER, lcy3 AS INTEGER
lcx3 = 510
lcy3 = 285

FOR i = 0 TO 139
  PSET lcx3 - 70 + i, lcy3 - 65, 29
  PSET lcx3 - 70 + i, lcy3 + 65, 29
NEXT i
FOR i = 0 TO 129
  PSET lcx3 - 70, lcy3 - 65 + i, 29
  PSET lcx3 + 70, lcy3 - 65 + i, 29
NEXT i

FOR i = 0 TO 3600
  t = i * 3.14159265 / 1800.0
  px = lcx3 + INT(SIN(1.0 * t + 1.5708) * 62.0)
  py = lcy3 + INT(SIN(1.0 * t) * 58.0)
  IF px >= 0 AND px <= 639 AND py >= 0 AND py <= 479 THEN
    PSET px, py, 21
  END IF
NEXT i

DRAWTEXT lcx - 30, lcy + 68, "3:2", 27, 0
DRAWTEXT lcx2 - 30, lcy2 + 68, "5:4", 27, 0
DRAWTEXT lcx3 - 30, lcy3 + 68, "1:1", 27, 0

' ════════════════════════════════════════════════════
' SECTION 4: Damped sine wave (y = 365..435)
' ════════════════════════════════════════════════════
DRAWTEXT 10, 362, "Damped sine wave (exponential decay)", 27, 0

DIM baseline4 AS INTEGER
baseline4 = 410

' Centre line
FOR i = 0 TO 599
  PSET 20 + i, baseline4, 29
NEXT i

' Decay envelope (dotted, upper and lower)
FOR i = 0 TO 599
  DIM envelope AS DOUBLE
  envelope = 35.0 * EXP(-i * 0.004)
  IF i MOD 4 = 0 THEN
    py = baseline4 - INT(envelope)
    IF py >= 370 AND py <= 450 THEN
      PSET 20 + i, py, 28
    END IF
    py = baseline4 + INT(envelope)
    IF py >= 370 AND py <= 450 THEN
      PSET 20 + i, py, 28
    END IF
  END IF
NEXT i

' The damped wave itself
FOR i = 0 TO 599
  DIM amp AS DOUBLE
  amp = 35.0 * EXP(-i * 0.004)
  py = baseline4 + INT(SIN(i * 3.14159265 / 20.0) * amp)
  c = 17 + (i \ 75) MOD 9
  IF py >= 370 AND py <= 450 THEN
    PSET 20 + i, py, c
  END IF
NEXT i

' ── Footer ───────────────────────────────────────────
DRAWTEXT 240, 470, "Test 15 — Sine Waves complete", 26, 0

' ── Hold for 5 seconds ───────────────────────────────
DIM frame AS INTEGER
frame = 0
DO
  VSYNC
  frame = frame + 1
LOOP UNTIL frame >= 300

SCREENCLOSE
END
