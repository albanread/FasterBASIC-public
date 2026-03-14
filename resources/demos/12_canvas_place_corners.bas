' Demo: create four coloured-circle images and place them in the canvas corners.

WINDOW DEFINE 1, "Place Corners", 80, 80, 520, 420
    WINDOW CANVAS 10, 10, 10, 500, 340
    WINDOW BUTTON 20, "Quit", 410, 360, 80, 26
END WINDOW

WINDOW SHOW 1

' ── Create four 100x100 images, each with a distinct coloured circle ──

' Red circle
WINDOW IMAGE CREATE 1, 100, 100
WINDOW IMAGE BEGIN 1
    PAPER 0, 0, 0, 0
    CLEAR
    COLOR 220, 40, 40, 255
    CIRCLE 50, 50, 45, 1
WINDOW IMAGE END

' Green circle
WINDOW IMAGE CREATE 2, 100, 100
WINDOW IMAGE BEGIN 2
    PAPER 0, 0, 0, 0
    CLEAR
    COLOR 40, 200, 40, 255
    CIRCLE 50, 50, 45, 1
WINDOW IMAGE END

' Blue circle
WINDOW IMAGE CREATE 3, 100, 100
WINDOW IMAGE BEGIN 3
    PAPER 0, 0, 0, 0
    CLEAR
    COLOR 50, 80, 220, 255
    CIRCLE 50, 50, 45, 1
WINDOW IMAGE END

' Yellow circle
WINDOW IMAGE CREATE 4, 100, 100
WINDOW IMAGE BEGIN 4
    PAPER 0, 0, 0, 0
    CLEAR
    COLOR 240, 220, 40, 255
    CIRCLE 50, 50, 45, 1
WINDOW IMAGE END

' ── Place the four images in the four corners of the canvas ──

WINDOW CANVAS BEGIN 1, 10
    PAPER 32, 32, 32, 255
    CLEAR

    ' Top-left: red
    PLACE IMAGE 1 AT 0, 0, 100, 100

    ' Top-right: green
    PLACE IMAGE 2 AT 400, 0, 100, 100

    ' Bottom-left: blue
    PLACE IMAGE 3 AT 0, 240, 100, 100

    ' Bottom-right: yellow
    PLACE IMAGE 4 AT 400, 240, 100, 100

    COLOR 255, 255, 255, 255
    TEXT 140, 160, "Four circles in four corners"
WINDOW CANVAS END

running = 1
DO WHILE running
    SLEEP 0.05
    IF WINDOW EVENT(win, ctl) THEN
        IF win = 1 THEN
            IF ctl = 0 OR ctl = 20 THEN running = 0
        END IF
    END IF
LOOP

WINDOW IMAGE DESTROY 1
WINDOW IMAGE DESTROY 2
WINDOW IMAGE DESTROY 3
WINDOW IMAGE DESTROY 4
WINDOW SHUTDOWN
END
