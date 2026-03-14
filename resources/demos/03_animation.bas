' ============================================
' Test 03 — Double-Buffered Animation
' ============================================
'
' A bouncing ball with smooth motion. Demonstrates
' the FLIP / VSYNC game loop pattern for tear-free
' double-buffered animation.
'
' Runs for 300 frames (~5 seconds) then exits.

SCREEN 320, 200
SCREENTITLE "Test 03 — Bouncing Ball"

' ── Palette setup ────────────────────────────────────
PALETTE 16, 16, 16, 40       ' dark background
PALETTE 17, 255, 80, 60      ' ball colour (red-orange)
PALETTE 18, 255, 180, 60     ' ball highlight
PALETTE 19, 60, 60, 80       ' shadow colour
PALETTE 20, 40, 40, 60       ' darker shadow
PALETTE 21, 80, 80, 120      ' floor colour
PALETTE 22, 255, 255, 255    ' white text

' ── Ball state ───────────────────────────────────────
DIM bx AS DOUBLE, by AS DOUBLE
DIM vx AS DOUBLE, vy AS DOUBLE
DIM radius AS INTEGER
DIM gravity AS DOUBLE
DIM damping AS DOUBLE
DIM frame AS INTEGER

bx = 50.0
by = 40.0
vx = 2.5
vy = 0.0
radius = 12
gravity = 0.15
damping = 0.92
frame = 0

DIM floor_y AS INTEGER
floor_y = 175

' ── Main loop ────────────────────────────────────────
DIM k AS DOUBLE
k = 0

DO
  ' ── Physics ──────────────────────────────────────
  vy = vy + gravity
  bx = bx + vx
  by = by + vy

  ' Bounce off floor
  IF by + radius > floor_y THEN
    by = floor_y - radius
    vy = -vy * damping
    ' Tiny nudge so the ball doesn't sink
    IF ABS(vy) < 0.5 THEN vy = -3.0
  END IF

  ' Bounce off walls
  IF bx - radius < 0 THEN
    bx = radius
    vx = -vx
  END IF
  IF bx + radius > 319 THEN
    bx = 319 - radius
    vx = -vx
  END IF

  ' Bounce off ceiling
  IF by - radius < 0 THEN
    by = radius
    vy = -vy * 0.8
  END IF

  ' ── Draw (back buffer) ──────────────────────────
  GCLS 16

  ' Floor
  RECT 0, floor_y, 320, 25, 21, 1

  ' Floor line
  GLINE 0, floor_y, 319, floor_y, 15

  ' Shadow on the floor (ellipse, scales with height)
  DIM shadow_scale AS DOUBLE
  shadow_scale = 1.0 - (floor_y - by - radius) / 160.0
  IF shadow_scale < 0.2 THEN shadow_scale = 0.2
  IF shadow_scale > 1.0 THEN shadow_scale = 1.0

  DIM shadow_rx AS INTEGER
  shadow_rx = INT(radius * shadow_scale)
  IF shadow_rx < 3 THEN shadow_rx = 3

  ELLIPSE INT(bx), floor_y + 4, shadow_rx, 3, 20, 1

  ' Ball (filled circle)
  CIRCLE INT(bx), INT(by), radius, 17, 1

  ' Ball outline
  CIRCLE INT(bx), INT(by), radius, 15, 0

  ' Highlight (small circle offset up-left)
  CIRCLE INT(bx) - 3, INT(by) - 3, 3, 18, 1

  ' ── HUD text ────────────────────────────────────
  DRAWTEXT 4, 4, "Test 03: Bouncing Ball", 22, 0
  DRAWTEXT 4, 188, "300 frame test", 15, 0

  ' Frame counter in corner
  frame = frame + 1

  ' ── Present ─────────────────────────────────────
  FLIP
  VSYNC

LOOP UNTIL frame >= 300

SCREENCLOSE
PRINT "CLOSED"
END
