' ── test_graphics_screen.bas ────────────────────────────────────────────────
' Smoke test for the SCREEN lifecycle:
'   SCREEN / SCREENTITLE / GCLS / PALETTE / FLIP / VSYNC / SCREENCLOSE
'
' No pixel-level assertions are possible from a text runner, so each section
' is a structural "did we get here without crashing?" check.  A variable
' (step) is incremented after every graphics command; at the end we verify
' it reached the expected value.

DIM allPass AS INTEGER
DIM step    AS INTEGER
allPass = 1
step    = 0
DIM w AS INTEGER

PRINT "test_graphics_screen: SCREEN lifecycle"
PRINT ""

' ── Step 1: open a 320×200 window ────────────────────────────────────────────
SCREEN 320, 200
step = step + 1

' ── Step 2: set the window title ─────────────────────────────────────────────
SCREENTITLE "help-test: screen lifecycle"
step = step + 1

' ── Step 3: set a custom palette entry ───────────────────────────────────────
PALETTE 16, 0, 0, 80        ' deep blue background
PALETTE 17, 0, 200, 80      ' phosphor green for text
step = step + 1

' ── Step 4: clear the screen ─────────────────────────────────────────────────
GCLS 16
step = step + 1

' ── Step 5: draw a label ─────────────────────────────────────────────────────
DRAWTEXT 40, 90, "SCREEN lifecycle test", 17
step = step + 1

' ── Step 6: flip to display ──────────────────────────────────────────────────
FLIP
step = step + 1

' ── Step 7: wait 1 minute (3 600 frames @ 60 fps) so the result is visible ───
FOR w = 1 TO 1200
  VSYNC
NEXT w
step = step + 1

' ── Step 8: close the window ─────────────────────────────────────────────────
SCREENCLOSE
step = step + 1

' ── Assertions ───────────────────────────────────────────────────────────────
PRINT "Checking step counter..."

IF step = 8 THEN
    PRINT "PASS: all 8 lifecycle steps completed"
ELSE
    PRINT "FAIL: expected step=8, got step=" & step
    allPass = 0
END IF

' ── Second window: verify GCLS with a different colour ───────────────────────
DIM step2 AS INTEGER
step2 = 0

SCREEN 160, 100
step2 = step2 + 1

PALETTE 18, 60, 0, 0        ' dark red background
GCLS 18
step2 = step2 + 1

FLIP
step2 = step2 + 1

FOR w = 1 TO 1200
  VSYNC
NEXT w
SCREENCLOSE
step2 = step2 + 1

IF step2 = 4 THEN
    PRINT "PASS: second window open/clear/close succeeded"
ELSE
    PRINT "FAIL: second window, expected step2=4, got step2=" & step2
    allPass = 0
END IF

' ── Summary ──────────────────────────────────────────────────────────────────
PRINT ""
IF allPass = 1 THEN
    PRINT "RESULT: PASS"
ELSE
    PRINT "RESULT: FAIL"
END IF
