' Demo: ARC and FILL — pie slices, outlines, pac-man shapes.
' ARC cx, cy, r, start_deg, end_deg, fill
'   Angles: 0=right, 90=down (screen Y-down), increasing clockwise.
'   fill=1  -> pie-wedge (centre + arc + close, uses FILL colour)
'   fill=0  -> open arc stroke (uses COLOR)

WINDOW DEFINE 1, "Arc Demo", 100, 100, 520, 480
    WINDOW CANVAS 10, 10, 10, 500, 440
    WINDOW BUTTON 20, "Quit", 400, 450, 80, 24
END WINDOW

WINDOW SHOW 1

GOSUB draw_arcs

running = 1
DO WHILE running
    SLEEP 0.05
    IF WINDOW EVENT(win, ctl) THEN
        IF win = 1 THEN
            IF ctl = 0 OR ctl = 20 THEN running = 0
        END IF
    END IF
LOOP

WINDOW SHUTDOWN
END

' ─── Draw arcs ───────────────────────────────────────────────────────────────
draw_arcs:

WINDOW CANVAS BEGIN 1, 10

    PAPER 30, 30, 45, 255
    CLEAR

    ' ── Row 1: pie slices with distinct fill colour ─────────────────────────
    ' Quarter pie (90 degrees)
    COLOR 200, 200, 200, 255
    FILL  255, 80, 80, 255
    ARC 80, 90, 60, 0, 90, 1

    ' Half pie (180 degrees)
    FILL  80, 200, 100, 255
    ARC 220, 90, 60, 0, 180, 1

    ' Three-quarter pie (270 degrees)
    FILL  80, 140, 255, 255
    ARC 360, 90, 60, 0, 270, 1

    ' Full circle via ARC
    FILL  255, 200, 60, 255
    ARC 460, 90, 40, 0, 360, 1

    ' ── Row 2: outline arcs only ─────────────────────────────────────────────
    LINEWIDTH 2
    NOFILL

    COLOR 255, 100, 100, 255
    ARC 80, 230, 60, 0, 90, 0

    COLOR 100, 220, 120, 255
    ARC 220, 230, 60, 0, 180, 0

    COLOR 100, 160, 255, 255
    ARC 360, 230, 60, 0, 270, 0

    COLOR 255, 210, 60, 255
    ARC 460, 230, 40, 0, 360, 0

    ' ── Row 3: pac-man shapes ────────────────────────────────────────────────
    LINEWIDTH 1
    COLOR 250,250, 50, 255

    ' Facing right (mouth opens right)
    FILL  255, 220, 0, 255
    ARC 80, 370, 55, 30, 330, 1

    ' Facing left
    FILL  255, 160, 20, 255
    ARC 220, 370, 55, 210, 150, 1

    ' Facing down
    FILL  255, 100, 60, 255
    ARC 360, 370, 55, 120, 60, 1

    ' Outline pac-man
    NOFILL
    LINEWIDTH 2
    COLOR 240, 240, 240, 255
    ARC 460, 370, 45, 30, 330, 0

    ' ── Labels ───────────────────────────────────────────────────────────────
    LINEWIDTH 1
    COLOR 200, 200, 200, 255
    TEXT 10, 155, "Filled pies  (fill=1)"
    TEXT 10, 295, "Outline arcs (fill=0)"
    TEXT 10, 430, "Pac-man shapes"

WINDOW CANVAS END

RETURN
