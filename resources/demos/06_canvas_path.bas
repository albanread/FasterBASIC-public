' Demo: Compound PATH — MOVE, LINE, CURVE, BEZIER, ARC, CLOSE, FILL, STROKE
'
' PATH ops accumulate a shape; PATH FILL or PATH STROKE renders it.
' CURVE  cx,cy, x2,y2            — quadratic bezier (1 control point)
' BEZIER cx1,cy1, cx2,cy2, x2,y2 — cubic bezier (2 control points)
' ARC    cx,cy, r, start_deg, end_deg — arc segment (connects from current point)

WINDOW DEFINE 1, "Path Demo", 80, 80, 560, 520
    WINDOW CANVAS 10, 10, 10, 540, 480
    WINDOW BUTTON 20, "Quit", 450, 490, 80, 24
END WINDOW

WINDOW SHOW 1
GOSUB draw_paths

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

' ─── Draw paths ──────────────────────────────────────────────────────────────
draw_paths:

WINDOW CANVAS BEGIN 1, 10

    PAPER 22, 22, 35, 255
    CLEAR

    ' ── 1. House silhouette ───────────────────────────────────────────────
    ' Sky gradient suggestion: filled rects behind the house
    FILL   60, 120, 200, 255
    COLOR  60, 120, 200, 255
    PATH MOVE   0,  60
    PATH LINE 200,  60
    PATH LINE 200, 270
    PATH LINE   0, 270
    PATH CLOSE
    PATH FILL

    ' Ground
    FILL   70, 140,  60, 255
    COLOR  50, 110,  40, 255
    PATH MOVE   0, 260
    PATH LINE 200, 260
    PATH LINE 200, 280
    PATH LINE   0, 280
    PATH CLOSE
    PATH FILL

    ' House body — warm sandstone
    FILL  215, 175, 130, 255
    COLOR 140, 100,  60, 255
    LINEWIDTH 1.5
    PATH MOVE  30, 160
    PATH LINE  30, 262
    PATH LINE 170, 262
    PATH LINE 170, 160
    PATH CLOSE
    PATH FILL
    PATH MOVE  30, 160
    PATH LINE  30, 262
    PATH LINE 170, 262
    PATH LINE 170, 160
    PATH CLOSE
    PATH STROKE

    ' Roof — terracotta
    FILL  195,  70,  45, 255
    COLOR 140,  45,  25, 255
    PATH MOVE  18, 163
    PATH LINE 100,  88
    PATH LINE 182, 163
    PATH CLOSE
    PATH FILL
    PATH MOVE  18, 163
    PATH LINE 100,  88
    PATH LINE 182, 163
    PATH CLOSE
    PATH STROKE

    ' Door — rich brown with arch top
    FILL  120,  70,  35, 255
    COLOR  80,  45,  15, 255
    LINEWIDTH 2
    PATH MOVE  82, 262
    PATH LINE  82, 212
    PATH ARC   97, 212, 15, 180, 0
    PATH LINE 112, 262
    PATH CLOSE
    PATH FILL
    PATH MOVE  82, 262
    PATH LINE  82, 212
    PATH ARC   97, 212, 15, 180, 0
    PATH LINE 112, 262
    PATH STROKE

    ' Left window — sky-blue glass with warm frame
    FILL  160, 210, 245, 200
    COLOR 140, 100,  60, 255
    LINEWIDTH 1.5
    PATH MOVE  40, 178
    PATH LINE  76, 178
    PATH LINE  76, 218
    PATH LINE  40, 218
    PATH CLOSE
    PATH FILL
    PATH MOVE  40, 178
    PATH LINE  76, 178
    PATH LINE  76, 218
    PATH LINE  40, 218
    PATH CLOSE
    PATH STROKE

    ' Right window
    PATH MOVE 124, 178
    PATH LINE 160, 178
    PATH LINE 160, 218
    PATH LINE 124, 218
    PATH CLOSE
    PATH FILL
    PATH MOVE 124, 178
    PATH LINE 160, 178
    PATH LINE 160, 218
    PATH LINE 124, 218
    PATH CLOSE
    PATH STROKE

    ' Sun — golden
    FILL  255, 225,  50, 255
    COLOR 240, 170,   0, 255
    LINEWIDTH 1
    PATH MOVE 168,  72
    PATH ARC  168,  72, 22, 0, 360
    PATH FILL

    ' ── 2. CURVE (quadratic) ─────────────────────────────────────────────
    LINEWIDTH 1
    COLOR 160, 200, 240, 255
    TEXT  210,  68, "CURVE (quadratic)"

    ' Three arches in different hues
    LINEWIDTH 2.5
    COLOR  80, 180, 255, 255
    PATH MOVE  210, 140
    PATH CURVE 255,  72, 300, 140
    PATH STROKE

    COLOR 160, 100, 255, 255
    PATH MOVE  300, 140
    PATH CURVE 345,  72, 390, 140
    PATH STROKE

    ' Filled wave shape
    FILL   50, 130, 210,  90
    COLOR  80, 180, 255, 255
    LINEWIDTH 1.5
    PATH MOVE  210, 190
    PATH CURVE 255, 130, 300, 190
    PATH CURVE 345, 130, 390, 190
    PATH LINE  390, 240
    PATH LINE  210, 240
    PATH CLOSE
    PATH FILL
    PATH MOVE  210, 190
    PATH CURVE 255, 130, 300, 190
    PATH CURVE 345, 130, 390, 190
    PATH STROKE

    ' ── 3. BEZIER (cubic) ────────────────────────────────────────────────
    LINEWIDTH 1
    COLOR 255, 190, 100, 255
    TEXT  210, 263, "BEZIER (cubic)"

    ' S-curve in orange-amber
    LINEWIDTH 2.5
    COLOR 255, 150,  40, 255
    PATH MOVE  210, 310
    PATH BEZIER 260, 248, 340, 372, 390, 310
    PATH STROKE

    ' Layered sail shapes — sunset palette
    FILL  255,  90,  50,  80
    COLOR 255,  90,  50, 200
    LINEWIDTH 1
    PATH MOVE  210, 385
    PATH BEZIER 225, 318, 305, 298, 390, 385
    PATH BEZIER 368, 440, 238, 448, 210, 385
    PATH CLOSE
    PATH FILL

    FILL  255, 170,  40,  70
    COLOR 255, 170,  40, 200
    PATH MOVE  225, 375
    PATH BEZIER 238, 320, 312, 305, 385, 375
    PATH BEZIER 360, 430, 245, 438, 225, 375
    PATH CLOSE
    PATH FILL

    ' ── 4. Rounded rect (lines + arcs) ───────────────────────────────────
    LINEWIDTH 1
    COLOR 160, 240, 160, 255
    TEXT  430,  68, "Mixed path"

    FILL   30, 110,  60,  90
    COLOR  80, 200, 110, 255
    LINEWIDTH 1.5
    PATH MOVE  432, 118
    PATH LINE  518, 118
    PATH ARC   518, 133, 15, 270, 0
    PATH LINE  533, 202
    PATH ARC   518, 202, 15,   0, 90
    PATH LINE  432, 217
    PATH ARC   432, 202, 15,  90, 180
    PATH LINE  417, 133
    PATH ARC   432, 133, 15, 180, 270
    PATH CLOSE
    PATH FILL
    COLOR 120, 240, 150, 255
    PATH MOVE  432, 118
    PATH LINE  518, 118
    PATH ARC   518, 133, 15, 270, 0
    PATH LINE  533, 202
    PATH ARC   518, 202, 15,   0, 90
    PATH LINE  432, 217
    PATH ARC   432, 202, 15,  90, 180
    PATH LINE  417, 133
    PATH ARC   432, 133, 15, 180, 270
    PATH CLOSE
    PATH STROKE

    ' Inner accent rect
    FILL  160, 255, 190,  40
    COLOR 160, 255, 190, 160
    LINEWIDTH 1
    PATH MOVE  448, 134
    PATH LINE  502, 134
    PATH ARC   502, 146,  9, 270, 0
    PATH LINE  511, 186
    PATH ARC   502, 186,  9,   0, 90
    PATH LINE  448, 195
    PATH ARC   448, 186,  9,  90, 180
    PATH LINE  439, 146
    PATH ARC   448, 146,  9, 180, 270
    PATH CLOSE
    PATH FILL
    PATH STROKE

    ' ── 5. Star — gem colours ────────────────────────────────────────────
    ' Outer star: magenta-gold
    FILL  255,  60, 160, 255
    COLOR 200,  20, 100, 255
    LINEWIDTH 1.5
    PATH MOVE  480, 298
    PATH LINE  492, 336
    PATH LINE  533, 336
    PATH LINE  500, 358
    PATH LINE  512, 396
    PATH LINE  480, 373
    PATH LINE  448, 396
    PATH LINE  460, 358
    PATH LINE  427, 336
    PATH LINE  468, 336
    PATH CLOSE
    PATH FILL

    ' Inner highlight star: gold
    FILL  255, 230,  60, 200
    COLOR 240, 180,  10, 255
    LINEWIDTH 1
    PATH MOVE  480, 318
    PATH LINE  488, 341
    PATH LINE  513, 341
    PATH LINE  493, 356
    PATH LINE  500, 379
    PATH LINE  480, 365
    PATH LINE  460, 379
    PATH LINE  467, 356
    PATH LINE  447, 341
    PATH LINE  472, 341
    PATH CLOSE
    PATH FILL
    PATH STROKE

WINDOW CANVAS END

RETURN
