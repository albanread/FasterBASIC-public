' Demo: Sunflowers using compound PATH curves.
' Petals are quadratic Beziers; stems are cubic Beziers; leaves use two arcs.

APPNAME "Sunflowers Demo"

WINDOW DEFINE 1, "Sunflowers", 80, 60, 580, 460
  WINDOW CANVAS 10, 10, 10, 560, 420
  WINDOW BUTTON 20, "Quit", 470, 432, 80, 24
END WINDOW

WINDOW SHOW 1

PI = 3.14159265358979

GOSUB draw_scene

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

' ─── Scene ───────────────────────────────────────────────────────────────────
draw_scene:

' Sky and ground
WINDOW CANVAS BEGIN 1, 10
  PAPER 108, 174, 232, 255
  CLEAR
  ' Upper sky
  FILL 148, 205, 248, 255
  PATH MOVE 0, 0
  PATH LINE 560, 0
  PATH LINE 560, 160
  PATH LINE 0, 160
  PATH CLOSE
  PATH FILL
  ' Lower sky
  FILL 100, 162, 222, 255
  PATH MOVE 0, 160
  PATH LINE 560, 160
  PATH LINE 560, 308
  PATH LINE 0, 308
  PATH CLOSE
  PATH FILL
  ' Ground
  FILL 68, 138, 52, 255
  PATH MOVE 0, 306
  PATH LINE 560, 306
  PATH LINE 560, 420
  PATH LINE 0, 420
  PATH CLOSE
  PATH FILL
  ' Bright strip at ground horizon
  FILL 92, 170, 62, 150
  PATH MOVE 0, 306
  PATH LINE 560, 306
  PATH LINE 560, 325
  PATH LINE 0, 325
  PATH CLOSE
  PATH FILL
WINDOW CANVAS END

' Sunflower 1 — left, tallest
fcx = 148 : fcy = 212
finner_r = 37 : fpetal_r = 88 : fcenter_r = 34 : np = 14
GOSUB draw_flower

' Sunflower 2 — centre, mid height
fcx = 300 : fcy = 192
finner_r = 33 : fpetal_r = 78 : fcenter_r = 30 : np = 13
GOSUB draw_flower

' Sunflower 3 — right
fcx = 455 : fcy = 205
finner_r = 35 : fpetal_r = 83 : fcenter_r = 32 : np = 14
GOSUB draw_flower

RETURN

' ─── Single flower ───────────────────────────────────────────────────────────
draw_flower:

fstem_bot = 308

' Stem — dark green cubic Bezier with lighter highlight on top
WINDOW CANVAS BEGIN 1, 10
  COLOR 58, 130, 38, 255
  LINEWIDTH 6
  PATH MOVE fcx, fcy + fcenter_r
  PATH BEZIER fcx - 20, fcy + (fstem_bot - fcy) * 0.45, fcx + 14, fcy + (fstem_bot - fcy) * 0.78, fcx, fstem_bot
  PATH STROKE
  COLOR 78, 162, 54, 255
  LINEWIDTH 3
  PATH MOVE fcx, fcy + fcenter_r
  PATH BEZIER fcx - 20, fcy + (fstem_bot - fcy) * 0.45, fcx + 14, fcy + (fstem_bot - fcy) * 0.78, fcx, fstem_bot
  PATH STROKE
WINDOW CANVAS END

' Left leaf
lx = fcx - 8
ly = fcy + (fstem_bot - fcy) * 0.40
WINDOW CANVAS BEGIN 1, 10
  FILL 72, 152, 44, 230
  COLOR 48, 115, 28, 255
  LINEWIDTH 1
  PATH MOVE lx, ly
  PATH CURVE lx - 40, ly - 24, lx - 54, ly + 4
  PATH CURVE lx - 24, ly + 26, lx, ly
  PATH CLOSE
  PATH FILL
  COLOR 95, 178, 58, 170
  LINEWIDTH 0.8
  PATH MOVE lx, ly
  PATH CURVE lx - 40, ly - 24, lx - 54, ly + 4
  PATH STROKE
WINDOW CANVAS END

' Right leaf
lx = fcx + 8
ly = fcy + (fstem_bot - fcy) * 0.62
WINDOW CANVAS BEGIN 1, 10
  FILL 72, 152, 44, 230
  COLOR 48, 115, 28, 255
  LINEWIDTH 1
  PATH MOVE lx, ly
  PATH CURVE lx + 40, ly - 24, lx + 54, ly + 4
  PATH CURVE lx + 24, ly + 26, lx, ly
  PATH CLOSE
  PATH FILL
  COLOR 95, 178, 58, 170
  LINEWIDTH 0.8
  PATH MOVE lx, ly
  PATH CURVE lx + 40, ly - 24, lx + 54, ly + 4
  PATH STROKE
WINDOW CANVAS END

' Petals — drawn petal-by-petal so SIN/COS can be computed in the loop
ha = 22.0
FOR p = 0 TO np - 1
  ang = p * 360.0 / np
  rad = ang * PI / 180.0
  radL = (ang - ha) * PI / 180.0
  radR = (ang + ha) * PI / 180.0
  radCL = (ang - ha * 0.60) * PI / 180.0
  radCR = (ang + ha * 0.60) * PI / 180.0

  blx = fcx + finner_r * COS(radL)
  bly = fcy + finner_r * SIN(radL)
  brx = fcx + finner_r * COS(radR)
  bry = fcy + finner_r * SIN(radR)
  tx = fcx + fpetal_r * COS(rad)
  ty = fcy + fpetal_r * SIN(rad)
  c1x = fcx + fpetal_r * 0.80 * COS(radCL)
  c1y = fcy + fpetal_r * 0.80 * SIN(radCL)
  c2x = fcx + fpetal_r * 0.80 * COS(radCR)
  c2y = fcy + fpetal_r * 0.80 * SIN(radCR)

  WINDOW CANVAS BEGIN 1, 10
    FILL 255, 198, 18, 255
    COLOR 218, 152, 6, 255
    LINEWIDTH 0.8
    PATH MOVE blx, bly
    PATH CURVE c1x, c1y, tx, ty
    PATH CURVE c2x, c2y, brx, bry
    PATH CLOSE
    PATH FILL
    PATH MOVE blx, bly
    PATH CURVE c1x, c1y, tx, ty
    PATH CURVE c2x, c2y, brx, bry
    PATH CLOSE
    PATH STROKE
  WINDOW CANVAS END
NEXT p

' Disc centre — three concentric brown circles
WINDOW CANVAS BEGIN 1, 10
  FILL 88, 46, 12, 255
  ARC fcx, fcy, fcenter_r, 0, 360, 1
  FILL 55, 26, 5, 255
  ARC fcx, fcy, fcenter_r * 0.72, 0, 360, 1
  FILL 95, 55, 18, 200
  ARC fcx, fcy, fcenter_r * 0.40, 0, 360, 1
WINDOW CANVAS END

RETURN
