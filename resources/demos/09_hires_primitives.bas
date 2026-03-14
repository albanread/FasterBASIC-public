' ============================================
' Test 09 — Hi-Res Primitives & Blitting
' ============================================
'
' A 1024x768 showcase of drawing primitives
' plus blitting operations.
'
' Exercises:
'   - RECT, CIRCLE, ELLIPSE, TRIANGLE
'   - GLINE, PSET, FILLAREA
'   - DRAWTEXT (both fonts)
'   - BLIT / BLITSOLID / BLITSCALE / BLITFLIP
'   - SETTARGET (off-screen buffers)
'
' Renders to 1024x768, holds for 8 seconds.

SCREEN 1024, 768
SCREENTITLE "Test 09 — Hi-Res Primitives & Blitting"
SETTARGET 0

' ── Palette ──────────────────────────────────────────
PALETTE 16, 18, 18, 28        ' dark background
PALETTE 17, 255, 80, 80       ' red
PALETTE 18, 80, 255, 80       ' green
PALETTE 19, 80, 120, 255      ' blue
PALETTE 20, 255, 220, 60      ' yellow
PALETTE 21, 255, 80, 220      ' magenta
PALETTE 22, 60, 240, 240      ' cyan
PALETTE 23, 255, 160, 60      ' orange
PALETTE 24, 180, 120, 255     ' purple
PALETTE 25, 255, 255, 255     ' white
PALETTE 26, 140, 140, 160     ' grey
PALETTE 27, 80, 80, 100       ' dark grey
PALETTE 28, 200, 200, 220     ' light grey

GCLS 16

' ── Title bar ────────────────────────────────────────
RECT 0, 0, 1024, 28, 27, 1
DRAWTEXT 340, 6, "Hi-Res Primitives & Blitting (1024x768)", 25, 1

DIM i AS INTEGER

' ════════════════════════════════════════════════════
' ROW 1: Basic Shapes (y = 40..220)
' ════════════════════════════════════════════════════

' ── Rectangles ───────────────────────────────────────
DRAWTEXT 20, 36, "RECT", 25, 0

' Filled rectangles (overlapping)
RECT 20, 52, 100, 70, 17, 1
RECT 40, 62, 100, 70, 19, 1
RECT 60, 72, 100, 70, 18, 1

' Outline rectangles
RECT 200, 52, 80, 60, 22, 0
RECT 210, 58, 80, 60, 20, 0
RECT 220, 64, 80, 60, 23, 0

' ── Circles ──────────────────────────────────────────
DRAWTEXT 340, 36, "CIRCLE", 25, 0

' Filled circles
CIRCLE 390, 100, 45, 17, 1
CIRCLE 430, 95, 35, 19, 1
CIRCLE 415, 120, 25, 20, 1

' Concentric outline circles
FOR i = 1 TO 8
  CIRCLE 550, 100, i * 7, 16 + i, 0
NEXT i

' ── Ellipses ─────────────────────────────────────────
DRAWTEXT 680, 36, "ELLIPSE", 25, 0

' Wide filled
ELLIPSE 750, 85, 60, 25, 21, 1
' Tall outline
ELLIPSE 750, 85, 20, 45, 25, 0

' Concentric ellipses
FOR i = 1 TO 5
  ELLIPSE 920, 95, 15 + i * 12, 10 + i * 8, 17 + i, 0
NEXT i

' ── Triangles ────────────────────────────────────────
DRAWTEXT 20, 170, "TRIANGLE", 25, 0

' Filled triangles
TRIANGLE 30, 260, 110, 190, 190, 260, 23, 1
TRIANGLE 60, 250, 130, 200, 170, 255, 20, 1

' Outline triangles
TRIANGLE 230, 260, 280, 190, 330, 260, 22, 0
TRIANGLE 240, 255, 280, 200, 320, 255, 17, 0

' Star from two triangles
TRIANGLE 400, 195, 470, 195, 435, 260, 20, 1
TRIANGLE 400, 245, 470, 245, 435, 180, 21, 1

' ── Lines ────────────────────────────────────────────
DRAWTEXT 520, 170, "GLINE", 25, 0

' Starburst
DIM cx AS INTEGER, cy AS INTEGER
cx = 600
cy = 230
FOR i = 0 TO 23
  DIM lx AS INTEGER, ly AS INTEGER
  lx = cx + INT(COS(i * 3.14159265 / 12.0) * 50.0)
  ly = cy + INT(SIN(i * 3.14159265 / 12.0) * 50.0)
  GLINE cx, cy, lx, ly, 17 + (i MOD 8)
NEXT i

' Parallel coloured lines
FOR i = 0 TO 15
  GLINE 710, 190 + i * 5, 870, 190 + i * 5, 17 + (i MOD 8)
NEXT i

' Crosshatch
FOR i = 0 TO 10
  GLINE 900 + i * 10, 185, 900, 185 + i * 10, 22
  GLINE 1000, 185 + i * 10, 900 + i * 10, 285, 19
NEXT i

' ════════════════════════════════════════════════════
' ROW 2: Fill, Text, Pixels (y = 280..440)
' ════════════════════════════════════════════════════

' ── Flood Fill ───────────────────────────────────────
DRAWTEXT 20, 280, "FILLAREA", 25, 0

' Diamond → fill orange
GLINE 80, 330, 130, 295, 25
GLINE 130, 295, 180, 330, 25
GLINE 180, 330, 130, 365, 25
GLINE 130, 365, 80, 330, 25
FILLAREA 130, 330, 23

' Circle → fill blue
CIRCLE 280, 330, 38, 25, 0
FILLAREA 280, 330, 19

' ── Text rendering ───────────────────────────────────
DRAWTEXT 380, 280, "DRAWTEXT", 25, 0

DRAWTEXT 380, 300, "Small font (8x8):", 28, 0
DRAWTEXT 380, 314, "ABCDEFGHIJKLMNOPQRSTUVWXYZ", 17, 0
DRAWTEXT 380, 326, "abcdefghijklmnopqrstuvwxyz", 18, 0
DRAWTEXT 380, 338, "0123456789 !@#$%^&*()", 22, 0

DRAWTEXT 380, 360, "Large font (8x16):", 28, 1
DRAWTEXT 380, 380, "ABCDEFGHIJKLMNOP", 17, 1
DRAWTEXT 380, 398, "abcdefghijklmnop", 19, 1
DRAWTEXT 380, 416, "0123456789 !@#$%", 23, 1

' ── Pixel patterns ───────────────────────────────────
DRAWTEXT 20, 385, "PSET", 25, 0

' Sine wave
DIM j AS INTEGER
FOR i = 0 TO 300
  DIM py AS INTEGER
  py = 420 + INT(SIN(i * 3.14159265 / 30.0) * 15.0)
  PSET 20 + i, py, 2 + (i \ 20) MOD 14
NEXT i

' ════════════════════════════════════════════════════
' ROW 3: Blitting (y = 460..740)
' ════════════════════════════════════════════════════

DRAWTEXT 20, 460, "BLIT / BLITSOLID / BLITSCALE / BLITFLIP", 25, 0

' ── Draw a sprite into buffer 2 ──────────────────────
SETTARGET 2
GCLS 0

' Simple spaceship shape (colour 0 = transparent bg)
RECT 20, 8, 24, 44, 19, 1
RECT 26, 4, 12, 52, 22, 1
RECT 30, 0, 4, 60, 25, 1
CIRCLE 32, 25, 8, 20, 1
CIRCLE 32, 25, 4, 25, 1

' Simple star shape
TRIANGLE 100, 30, 130, 30, 115, 5, 20, 1
TRIANGLE 100, 30, 130, 30, 115, 55, 23, 1
TRIANGLE 95, 15, 95, 45, 80, 30, 21, 1
TRIANGLE 135, 15, 135, 45, 150, 30, 24, 1
CIRCLE 115, 30, 6, 25, 1

SETTARGET 0

' ── BLIT (transparent) ───────────────────────────────
DRAWTEXT 20, 482, "BLIT (colour 0 = transparent)", 28, 0

' Checkerboard background to show transparency
FOR i = 0 TO 9
  FOR j = 0 TO 5
    DIM bc AS INTEGER
    IF (i + j) MOD 2 = 0 THEN bc = 27 ELSE bc = 16
    RECT 20 + i * 16, 500 + j * 16, 16, 16, bc, 1
  NEXT j
NEXT i

BLIT 2, 12, 0, 0, 30, 504, 50, 60
BLIT 2, 78, 3, 0, 95, 504, 75, 55

' ── BLITSOLID (opaque) ───────────────────────────────
DRAWTEXT 220, 482, "BLITSOLID (opaque)", 28, 0

FOR i = 0 TO 9
  FOR j = 0 TO 5
    DIM bc2 AS INTEGER
    IF (i + j) MOD 2 = 0 THEN bc2 = 27 ELSE bc2 = 16
    RECT 220 + i * 16, 500 + j * 16, 16, 16, bc2, 1
  NEXT j
NEXT i

BLITSOLID 2, 12, 0, 0, 230, 504, 50, 60
BLITSOLID 2, 78, 3, 0, 295, 504, 75, 55

' ── BLITSCALE ────────────────────────────────────────
DRAWTEXT 430, 482, "BLITSCALE", 28, 0

' 2x scale
BLITSCALE 2, 12, 0, 50, 60, 0, 430, 500, 100, 120

' 0.5x scale
BLITSCALE 2, 12, 0, 50, 60, 0, 545, 530, 25, 30

' Wide stretch
BLITSCALE 2, 78, 3, 75, 55, 0, 580, 520, 150, 40

' ── BLITFLIP ─────────────────────────────────────────
DRAWTEXT 760, 482, "BLITFLIP", 28, 0

DRAWTEXT 760, 564, "orig", 26, 0
BLIT 2, 12, 0, 0, 765, 500, 50, 60

DRAWTEXT 830, 564, "H", 26, 0
BLITFLIP 2, 12, 0, 0, 835, 500, 50, 60, 1

DRAWTEXT 900, 564, "V", 26, 0
BLITFLIP 2, 12, 0, 0, 905, 500, 50, 60, 2

DRAWTEXT 965, 564, "HV", 26, 0
BLITFLIP 2, 12, 0, 0, 965, 500, 50, 60, 3

' ── Footer ───────────────────────────────────────────
RECT 0, 750, 1024, 18, 27, 1
DRAWTEXT 400, 753, "Test 09 — All primitives + blitting", 25, 0

' ── Hold for 8 seconds ───────────────────────────────
DIM frame AS INTEGER
frame = 0
DO
  VSYNC
  frame = frame + 1
LOOP UNTIL frame >= 480

SCREENCLOSE
END
