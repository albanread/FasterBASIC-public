' ============================================
' Test 08 — High-Resolution Barnsley Fern
' ============================================
'
' Draws a Barnsley fern at 1024x768 resolution
' with 2,000,000 points for dense, detailed
' fractal structure. Rendered progressively so
' you can watch it grow on screen.
'
' This test exercises:
'   - PSET pixel plotting at high resolution
'   - Floating-point IFS arithmetic
'   - RND() random number generation
'   - Multi-shade green palette gradient
'   - Progressive rendering with VSYNC pacing
'
' Renders 2,000,000 points then holds for 5 seconds.

SCREEN 1024, 768
SCREENTITLE "Test 08 — Hi-Res Barnsley Fern (1024x768)"
SETTARGET 0

' ── Palette: rich greens on black ────────────────────
PALETTE 16, 0, 0, 0           ' black background
PALETTE 17, 0, 50, 0          ' darkest green (stem base)
PALETTE 18, 0, 80, 10         ' dark green
PALETTE 19, 0, 110, 20        ' medium-dark green
PALETTE 20, 0, 145, 30        ' medium green
PALETTE 21, 10, 180, 40       ' medium-bright green
PALETTE 22, 20, 210, 55       ' bright green
PALETTE 23, 40, 235, 70       ' vivid green
PALETTE 24, 80, 255, 100      ' highlight green
PALETTE 25, 140, 255, 150     ' pale green tips
PALETTE 26, 200, 255, 200     ' near-white tips
PALETTE 27, 255, 255, 255     ' white (title text)

GCLS 16

DRAWTEXT 380, 8, "Barnsley Fern (1024x768)", 27, 0
DRAWTEXT 380, 752, "2M iterations", 15, 0

' ── IFS state ────────────────────────────────────────
DIM x AS DOUBLE, y AS DOUBLE
DIM nx AS DOUBLE, ny AS DOUBLE
DIM r AS DOUBLE
DIM px AS INTEGER, py AS INTEGER
DIM c AS INTEGER

x = 0.0
y = 0.0

' ── Render the fern progressively ────────────────────
' 2,000,000 total iterations, drawn in batches of 5000.
' VSYNC every batch so the fern visibly grows.

DIM total AS INTEGER
DIM batch AS INTEGER
DIM i AS INTEGER

total = 2000000
batch = 5000

FOR i = 1 TO total

  r = RND()

  IF r < 0.01 THEN
    ' Stem (f1): contracts to the base
    nx = 0.0
    ny = 0.16 * y

  ELSEIF r < 0.86 THEN
    ' Main frond (f2): the bulk of the fern
    nx =  0.85 * x + 0.04 * y
    ny = -0.04 * x + 0.85 * y + 1.6

  ELSEIF r < 0.93 THEN
    ' Left leaflet (f3)
    nx =  0.20 * x - 0.26 * y
    ny =  0.23 * x + 0.22 * y + 1.6

  ELSE
    ' Right leaflet (f4)
    nx = -0.15 * x + 0.28 * y
    ny =  0.26 * x + 0.24 * y + 0.44

  END IF

  x = nx
  y = ny

  ' Map IFS coordinates to screen pixels
  ' x range is roughly -2.2 to 2.7 → centre horizontally
  ' y range is roughly 0 to 10    → fill height with margins
  px = INT(x * 100.0 + 512.0)
  py = INT(730.0 - y * 70.0)

  ' Colour based on height (y value) — 10 shades of green
  IF y < 0.5 THEN
    c = 17
  ELSEIF y < 1.5 THEN
    c = 18
  ELSEIF y < 2.5 THEN
    c = 19
  ELSEIF y < 3.5 THEN
    c = 20
  ELSEIF y < 4.5 THEN
    c = 21
  ELSEIF y < 5.5 THEN
    c = 22
  ELSEIF y < 7.0 THEN
    c = 23
  ELSEIF y < 8.5 THEN
    c = 24
  ELSEIF y < 9.5 THEN
    c = 25
  ELSE
    c = 26
  END IF

  ' Plot if within screen bounds
  IF px >= 0 AND px <= 1023 AND py >= 0 AND py <= 767 THEN
    PSET px, py, c
  END IF

  ' Pace the rendering so the fern visibly grows
  IF i MOD batch = 0 THEN
    VSYNC
  END IF

NEXT i

' ── Hold for 5 seconds ───────────────────────────────
DIM frame AS INTEGER
frame = 0
DO
  VSYNC
  frame = frame + 1
LOOP UNTIL frame >= 300

SCREENCLOSE
END
