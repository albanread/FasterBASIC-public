' Demo: Canvas control — draws a small scene using basic shapes.

' ── Menu Bar ──────────────────────────────────────────────────────────
MENU DEFINE
  MENU "Sunflowers"
  ITEM 303, "Quit", "Cmd+Q"
  END MENU
END DEFINE

WINDOW DEFINE 1, "Canvas Demo", 100, 100, 500, 440
    WINDOW CANVAS 10, 10, 10, 480, 380
    WINDOW BUTTON 20, "Redraw", 10, 400, 100, 28
    WINDOW BUTTON 21, "Quit",   380, 400, 100, 28
END WINDOW

WINDOW SHOW 1

' Draw once up front
GOSUB draw_scene

running = 1
DO WHILE running
    SLEEP 0.05
    IF WINDOW EVENT(win, ctl) THEN
        IF win = 1 THEN
            SELECT CASE ctl
            CASE 0
                running = 0
            CASE 20
                GOSUB draw_scene
            CASE 21
                running = 0
            END SELECT
        END IF
    END IF
LOOP

WINDOW SHUTDOWN
END

' ─── Draw scene ──────────────────────────────────────────────────────────────
draw_scene:

WINDOW CANVAS BEGIN 1, 10

    ' Set paper colour and clear
    PAPER 100, 180, 240, 255
    CLEAR

    ' Sun
    COLOR 255, 220, 0, 255
    CIRCLE 390, 60, 40, 1

    ' Ground
    COLOR 80, 160, 60, 255
    RECT 0, 300, 480, 80, 1

    ' House body
    COLOR 210, 160, 100, 255
    RECT 150, 200, 180, 100, 1

    ' House outline
    COLOR 80, 60, 40, 255
    LINEWIDTH 2
    RECT 150, 200, 180, 100, 0

    ' Roof
    COLOR 180, 60, 50, 255
    TRIANGLE 140, 200, 330, 200, 240, 120, 1

    ' Door
    COLOR 100, 70, 40, 255
    RECT 215, 260, 50, 40, 1

    ' Window left
    COLOR 160, 210, 240, 255
    RECT 165, 220, 40, 35, 1
    COLOR 80, 60, 40, 255
    LINEWIDTH 1
    RECT 165, 220, 40, 35, 0

    ' Window right
    COLOR 160, 210, 240, 255
    RECT 275, 220, 40, 35, 1
    COLOR 80, 60, 40, 255
    RECT 275, 220, 40, 35, 0

    ' Path
    COLOR 200, 190, 160, 255
    RECT 215, 300, 50, 30, 1

    ' Label
    COLOR 30, 30, 30, 255
    TEXT 150, 340, "A simple canvas demo"

WINDOW CANVAS END

RETURN
