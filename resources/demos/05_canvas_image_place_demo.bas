' Demo: place two offscreen images onto a canvas using IMAGE AT / BLEND / SRC.

WINDOW DEFINE 1, "Canvas Image Place", 60, 60, 640, 460
    WINDOW CANVAS 10, 10, 10, 600, 360
    WINDOW BUTTON 20, "Quit", 520, 382, 80, 26
END WINDOW

WINDOW SHOW 1

' Build image #1: sky + checker
WINDOW IMAGE CREATE 1, 180, 130
WINDOW IMAGE BEGIN 1
    PAPER 215, 235, 255, 255
    CLEAR
    COLOR 180, 210, 240, 255
    RECT 0, 0, 180, 80, 1
    COLOR 120, 170, 110, 255
    RECT 0, 80, 180, 50, 1
    COLOR 255, 210, 80, 255
    CIRCLE 30, 30, 18, 1
    COLOR 60, 90, 120, 180
    RECT 70, 16, 96, 64, 0
    ' Light checker stripe
    COLOR 240, 245, 255, 180
    RECT 12, 92, 24, 24, 1
    RECT 60, 92, 24, 24, 1
    RECT 108, 92, 24, 24, 1
    RECT 156, 92, 24, 24, 1
WINDOW IMAGE END

' Build image #2: warm gradient blocks
WINDOW IMAGE CREATE 2, 160, 120
WINDOW IMAGE BEGIN 2
    PAPER 255, 240, 225, 255
    CLEAR
    COLOR 255, 130, 80, 240
    RECT 0, 0, 160, 60, 1
    COLOR 200, 90, 50, 240
    RECT 0, 60, 160, 60, 1
    COLOR 255, 200, 120, 220
    RECT 16, 20, 64, 40, 1
    COLOR 90, 40, 20, 255
    LINEWIDTH 2
    RECT 12, 16, 72, 48, 0
    COLOR 255, 255, 255, 220
    RECT 96, 24, 42, 30, 1
    COLOR 120, 70, 40, 255
    RECT 96, 64, 42, 36, 0
WINDOW IMAGE END

' Compose on the canvas using the readable placement syntax
WINDOW CANVAS BEGIN 1, 10
    PAPER 24, 28, 38, 255
    CLEAR

    ' Full image 1 at top-left
    PLACE IMAGE 1 AT 40, 40, 200, 150

    ' Full image 2 with additive blend for a glowing look
    PLACE IMAGE 2 AT 280, 80, 200, 150 BLEND ADD

    ' Cropped portion of image 2 with XOR blend and a smaller dest rect
    PLACE IMAGE 2 AT 500, 60, 120, 90 SRC 16, 16, 96, 72 BLEND XOR

    ' Cropped portion of image 1 scaled down
    PLACE IMAGE 1 AT 460, 200, 140, 100 SRC 60, 20, 80, 60

    COLOR 220, 230, 240, 255
    TEXT 32, 330, "Two offscreen images placed with AT / SRC / BLEND"
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
WINDOW SHUTDOWN
END
