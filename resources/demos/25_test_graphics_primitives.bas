' ── test_graphics_primitives.bas ─────────────────────────────────────────────
' Smoke test for the core drawing primitives:
'   GLINE / RECT (filled + outline) / CIRCLE (filled + outline) / DRAWTEXT
'
' For each primitive group we:
'   1. Call the command(s) -- crash = test failure
'   2. Increment a counter
'   3. After SCREENCLOSE check the counter matches expectations
'
' Section counters are checked with PASS/FAIL assertions so the test
' produces verifiable output in a text runner.

DIM allPass AS INTEGER
DIM w AS INTEGER
allPass = 1

PRINT "test_graphics_primitives: GLINE / RECT / CIRCLE / DRAWTEXT"
PRINT ""

' ═════════════════════════════════════════════════════════════════════════════
' SECTION 1: GLINE (line segments)
' ═════════════════════════════════════════════════════════════════════════════
DIM linesDone AS INTEGER
linesDone = 0

SCREEN 320, 240
SCREENTITLE "help-test: primitives"

PALETTE 16, 10, 10, 20      ' dark background
PALETTE  1, 255, 255,   0   ' yellow
PALETTE  2, 255,   0,   0   ' red
PALETTE  3,   0, 255,   0   ' green
PALETTE  4,   0,   0, 255   ' blue
PALETTE  5, 255, 128,   0   ' orange
PALETTE  6,   0, 220, 220   ' cyan

GCLS 16

' Horizontal line
GLINE 10, 10, 309, 10, 1
linesDone = linesDone + 1

' Vertical line
GLINE 160, 10, 160, 229, 2
linesDone = linesDone + 1

' Diagonal line top-left → bottom-right
GLINE 10, 10, 309, 229, 3
linesDone = linesDone + 1

' Diagonal line top-right → bottom-left
GLINE 309, 10, 10, 229, 4
linesDone = linesDone + 1

' Single-pixel "line" (zero length)
GLINE 50, 50, 50, 50, 5
linesDone = linesDone + 1

FLIP
FOR w = 1 TO 1200
  VSYNC
NEXT w
SCREENCLOSE

IF linesDone = 5 THEN
    PRINT "PASS: GLINE — all 5 line variants drew without error"
ELSE
    PRINT "FAIL: GLINE — expected linesDone=5, got " & linesDone
    allPass = 0
END IF

' ═════════════════════════════════════════════════════════════════════════════
' SECTION 2: RECT (filled + outline)
' ═════════════════════════════════════════════════════════════════════════════
DIM rectsDone AS INTEGER
rectsDone = 0

SCREEN 320, 240
SCREENTITLE "help-test: rectangles"
GCLS 16

' Filled rectangle
RECT 10, 10, 150, 110, 1, 1
rectsDone = rectsDone + 1

' Outline rectangle
RECT 10, 10, 150, 110, 5, 0
rectsDone = rectsDone + 1

' 1-pixel wide rectangle (outline)
RECT 160, 10, 161, 110, 2, 0
rectsDone = rectsDone + 1

' Tiny 1×1 filled square
RECT 200, 200, 200, 200, 3, 1
rectsDone = rectsDone + 1

' Full-width title bar
RECT 0, 0, 319, 15, 4, 1
rectsDone = rectsDone + 1

' Nested rectangles (concentric)
DIM n AS INTEGER
FOR n = 1 TO 5
    RECT 10 + n*8, 120 + n*4, 150 - n*8, 230 - n*4, n, 0
    rectsDone = rectsDone + 1
NEXT n

FLIP
FOR w = 1 TO 1200
  VSYNC
NEXT w
SCREENCLOSE

IF rectsDone = 10 THEN
    PRINT "PASS: RECT — all 10 rectangle variants drew without error"
ELSE
    PRINT "FAIL: RECT — expected rectsDone=10, got " & rectsDone
    allPass = 0
END IF

' ═════════════════════════════════════════════════════════════════════════════
' SECTION 3: CIRCLE (filled + outline)
' ═════════════════════════════════════════════════════════════════════════════
DIM circlesDone AS INTEGER
circlesDone = 0

SCREEN 320, 240
SCREENTITLE "help-test: circles"
GCLS 16

' Small filled circle
CIRCLE 40, 60, 20, 1, 1
circlesDone = circlesDone + 1

' Medium outline circle
CIRCLE 120, 60, 30, 2, 0
circlesDone = circlesDone + 1

' Large filled circle
CIRCLE 220, 80, 50, 3, 1
circlesDone = circlesDone + 1

' Radius-1 (single pixel region)
CIRCLE 10, 10, 1, 4, 1
circlesDone = circlesDone + 1

' Concentric rings
DIM r AS INTEGER
FOR r = 5 TO 40 STEP 5
    CIRCLE 160, 120, r, (r / 5) MOD 6 + 1, 0
    circlesDone = circlesDone + 1
NEXT r

' Circle at edge of screen (partially clipped)
CIRCLE 0, 0, 20, 5, 1
circlesDone = circlesDone + 1

FLIP
FOR w = 1 TO 1200
  VSYNC
NEXT w
SCREENCLOSE

' Expected: 4 base + 8 loop iterations + 1 edge = 13
IF circlesDone = 13 THEN
    PRINT "PASS: CIRCLE — all 13 circle variants drew without error"
ELSE
    PRINT "FAIL: CIRCLE — expected circlesDone=13, got " & circlesDone
    allPass = 0
END IF

' ═════════════════════════════════════════════════════════════════════════════
' SECTION 4: DRAWTEXT (small + large font)
' ═════════════════════════════════════════════════════════════════════════════
DIM textsDone AS INTEGER
textsDone = 0

SCREEN 320, 240
SCREENTITLE "help-test: drawtext"
GCLS 16

' Small font (flag 0 - default)
DRAWTEXT 10, 10, "ABCDEFGHIJKLMNOPQRSTUVWXYZ", 1, 0
textsDone = textsDone + 1

DRAWTEXT 10, 22, "abcdefghijklmnopqrstuvwxyz", 2, 0
textsDone = textsDone + 1

DRAWTEXT 10, 34, "0123456789 !@#$%^&*()", 3, 0
textsDone = textsDone + 1

' Large font (flag 1)
DRAWTEXT 10, 60, "Large Font", 4, 1
textsDone = textsDone + 1

DRAWTEXT 10, 80, "HELLO WORLD", 5, 1
textsDone = textsDone + 1

' Near screen edges
DRAWTEXT 0, 0, "TL", 6, 0
textsDone = textsDone + 1

DRAWTEXT 290, 230, "BR", 1, 0
textsDone = textsDone + 1

' Text over a coloured background
RECT 10, 110, 200, 130, 4, 1
DRAWTEXT 12, 112, "Text over colour", 1, 0
textsDone = textsDone + 1

FLIP
FOR w = 1 TO 1200
  VSYNC
NEXT w
SCREENCLOSE

IF textsDone = 8 THEN
    PRINT "PASS: DRAWTEXT — all 8 text variants rendered without error"
ELSE
    PRINT "FAIL: DRAWTEXT — expected textsDone=8, got " & textsDone
    allPass = 0
END IF

' ═════════════════════════════════════════════════════════════════════════════
' Summary
' ═════════════════════════════════════════════════════════════════════════════
PRINT ""
IF allPass = 1 THEN
    PRINT "RESULT: PASS"
ELSE
    PRINT "RESULT: FAIL"
END IF
