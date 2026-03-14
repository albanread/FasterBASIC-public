' ============================================
' Test 11 — Rectangles
' ============================================
'
' Focused test for RECT primitive covering:
'   - Filled rectangles in various sizes
'   - Outline rectangles in various sizes
'   - Overlapping filled rectangles (z-order)
'   - Nested outline rectangles
'   - Tiny rectangles (1x1, 2x2, 3x3)
'   - Full-width and full-height rectangles
'   - Edge-aligned rectangles (corners, edges)
'   - Grid of coloured rectangles
'
' Renders to 640x480, holds for 6 seconds.

SCREEN 640, 480
SCREENTITLE "Test 11 — Rectangles"
SETTARGET 0

' ── Palette ──────────────────────────────────────────
PALETTE 16, 20, 20, 35        ' dark background
PALETTE 17, 255, 60, 60       ' red
PALETTE 18, 60, 255, 60       ' green
PALETTE 19, 60, 100, 255      ' blue
PALETTE 20, 255, 220, 40      ' yellow
PALETTE 21, 255, 60, 200      ' magenta
PALETTE 22, 40, 220, 220      ' cyan
PALETTE 23, 255, 140, 40      ' orange
PALETTE 24, 160, 100, 255     ' purple
PALETTE 25, 255, 255, 255     ' white
PALETTE 26, 140, 140, 160     ' grey
PALETTE 27, 80, 80, 100       ' dark grey
PALETTE 28, 200, 200, 220     ' light grey
PALETTE 29, 180, 60, 60       ' dark red
PALETTE 30, 60, 180, 60       ' dark green
PALETTE 31, 60, 60, 180       ' dark blue

GCLS 16

' ── Title ────────────────────────────────────────────
RECT 0, 0, 640, 22, 27, 1
DRAWTEXT 240, 5, "Test 11 — Rectangles", 25, 0

DIM i AS INTEGER
DIM j AS INTEGER

' ════════════════════════════════════════════════════
' SECTION 1: Filled Rectangles (various sizes)
' ════════════════════════════════════════════════════
DRAWTEXT 20, 30, "Filled Rectangles", 25, 0

' Small filled
RECT 20, 46, 40, 30, 17, 1

' Medium filled
RECT 80, 46, 70, 50, 18, 1

' Large filled
RECT 170, 46, 100, 60, 19, 1

' Tall narrow filled
RECT 290, 46, 20, 70, 20, 1

' Wide short filled
RECT 330, 46, 120, 20, 21, 1

' Square filled
RECT 330, 76, 40, 40, 22, 1

' ════════════════════════════════════════════════════
' SECTION 2: Outline Rectangles (various sizes)
' ════════════════════════════════════════════════════
DRAWTEXT 20, 130, "Outline Rectangles", 25, 0

' Small outline
RECT 20, 146, 40, 30, 17, 0

' Medium outline
RECT 80, 146, 70, 50, 18, 0

' Large outline
RECT 170, 146, 100, 60, 22, 0

' Tall narrow outline
RECT 290, 146, 20, 70, 23, 0

' Wide short outline
RECT 330, 146, 120, 20, 24, 0

' Square outline
RECT 330, 176, 40, 40, 20, 0

' ════════════════════════════════════════════════════
' SECTION 3: Overlapping Filled (z-order test)
' ════════════════════════════════════════════════════
DRAWTEXT 470, 30, "Overlapping", 25, 0

' Three overlapping rectangles — last drawn on top
RECT 470, 46, 80, 60, 17, 1
RECT 490, 56, 80, 60, 19, 1
RECT 510, 66, 80, 60, 20, 1

' Partially transparent layering effect
RECT 470, 136, 60, 40, 29, 1
RECT 490, 146, 60, 40, 30, 1
RECT 510, 156, 60, 40, 31, 1

' ════════════════════════════════════════════════════
' SECTION 4: Nested Outlines
' ════════════════════════════════════════════════════
DRAWTEXT 20, 228, "Nested Outlines", 25, 0

' Concentric rectangles
FOR i = 0 TO 7
  RECT 20 + i * 8, 244 + i * 5, 140 - i * 16, 80 - i * 10, 17 + i, 0
NEXT i

' Concentric rectangles (tight)
FOR i = 0 TO 10
  RECT 190 + i * 2, 244 + i * 2, 80 - i * 4, 80 - i * 4, 17 + (i MOD 8), 0
NEXT i

' ════════════════════════════════════════════════════
' SECTION 5: Tiny Rectangles (edge cases)
' ════════════════════════════════════════════════════
DRAWTEXT 300, 228, "Tiny Rects", 25, 0

' 1x1 pixel rects
RECT 300, 250, 1, 1, 17, 1
RECT 305, 250, 1, 1, 18, 1
RECT 310, 250, 1, 1, 19, 1
RECT 315, 250, 1, 1, 20, 1
RECT 320, 250, 1, 1, 21, 1

DRAWTEXT 300, 256, "1x1", 26, 0

' 2x2 pixel rects
RECT 300, 270, 2, 2, 17, 1
RECT 306, 270, 2, 2, 18, 1
RECT 312, 270, 2, 2, 19, 1
RECT 318, 270, 2, 2, 20, 1
RECT 324, 270, 2, 2, 21, 1

DRAWTEXT 300, 278, "2x2", 26, 0

' 3x3 pixel rects
RECT 300, 290, 3, 3, 17, 1
RECT 307, 290, 3, 3, 18, 1
RECT 314, 290, 3, 3, 19, 1
RECT 321, 290, 3, 3, 20, 1
RECT 328, 290, 3, 3, 21, 1

DRAWTEXT 300, 299, "3x3", 26, 0

' 1-pixel wide and tall rects
RECT 300, 314, 40, 1, 22, 1
DRAWTEXT 345, 310, "40x1", 26, 0

RECT 300, 320, 1, 20, 23, 1
DRAWTEXT 306, 326, "1x20", 26, 0

' ════════════════════════════════════════════════════
' SECTION 6: Edge-Aligned Rectangles
' ════════════════════════════════════════════════════
DRAWTEXT 420, 228, "Edge-Aligned", 25, 0

' Rectangles in the four corners of a bounding area
DIM bx AS INTEGER, by AS INTEGER
DIM bw AS INTEGER, bh AS INTEGER
bx = 420
by = 244
bw = 200
bh = 100

' Bounding box outline
RECT bx, by, bw, bh, 27, 0

' Top-left corner
RECT bx + 2, by + 2, 30, 20, 17, 1

' Top-right corner
RECT bx + bw - 32, by + 2, 30, 20, 18, 1

' Bottom-left corner
RECT bx + 2, by + bh - 22, 30, 20, 19, 1

' Bottom-right corner
RECT bx + bw - 32, by + bh - 22, 30, 20, 20, 1

' Centre
RECT bx + bw \ 2 - 15, by + bh \ 2 - 10, 30, 20, 22, 1

' ════════════════════════════════════════════════════
' SECTION 7: Colour Grid
' ════════════════════════════════════════════════════
DRAWTEXT 20, 348, "Colour Grid", 25, 0

' 14x3 grid of coloured filled rectangles
FOR j = 0 TO 2
  FOR i = 0 TO 13
    RECT 20 + i * 30, 364 + j * 24, 28, 22, 2 + j * 14 + i, 1
  NEXT i
NEXT j

' ════════════════════════════════════════════════════
' SECTION 8: Outline vs Filled Side by Side
' ════════════════════════════════════════════════════
DRAWTEXT 20, 440, "Outline vs Filled:", 25, 0

' Side-by-side comparison
RECT 180, 440, 50, 30, 17, 0
DRAWTEXT 190, 450, "out", 26, 0

RECT 240, 440, 50, 30, 17, 1
DRAWTEXT 250, 450, "fill", 26, 0

RECT 300, 440, 50, 30, 18, 0
DRAWTEXT 310, 450, "out", 26, 0

RECT 360, 440, 50, 30, 18, 1
DRAWTEXT 370, 450, "fill", 26, 0

RECT 420, 440, 50, 30, 19, 0
DRAWTEXT 430, 450, "out", 26, 0

RECT 480, 440, 50, 30, 19, 1
DRAWTEXT 490, 450, "fill", 26, 0

' ── Footer ───────────────────────────────────────────
RECT 0, 470, 640, 10, 27, 1

' ── Hold for 6 seconds ───────────────────────────────
DIM frame AS INTEGER
frame = 0
DO
  VSYNC
  frame = frame + 1
LOOP UNTIL frame >= 360

SCREENCLOSE
END
