' =========================================================================
' Mandelbrot Demo + Palette Rotation Animation
' =========================================================================
'
' Draws a static Mandelbrot image, then animates 14 user colours
' using GPU palette cycling.
'
' Palette rules:
'   0 = transparent/black (reserved)
'   1 = black (reserved)
'   16..29 = 14 user colours (cycled globally)

SCREEN 640, 480, 2
SCREENTITLE "Mandelbrot - Palette Cycle"

PALETTE  1,   0,   0,   0
PALETTE 16,   0,   0,  48
PALETTE 17,   0,   0,  80
PALETTE 18,   0,  16, 112
PALETTE 19,   0,  40, 144
PALETTE 20,   0,  72, 176
PALETTE 21,   0, 104, 208
PALETTE 22,   0, 136, 240
PALETTE 23,  20, 168, 255
PALETTE 24,  56, 200, 224
PALETTE 25,  96, 232, 176
PALETTE 26, 152, 248, 112
PALETTE 27, 208, 232,  64
PALETTE 28, 240, 176,  32
PALETTE 29, 255, 112,   0

DIM xmin AS DOUBLE
DIM xmax AS DOUBLE
DIM ymin AS DOUBLE
DIM ymax AS DOUBLE
DIM max_iter AS INTEGER

xmin = -2.4
xmax =  1.2
ymin = -1.35
ymax =  1.35
max_iter = 64

DIM x AS INTEGER
DIM y AS INTEGER
DIM i AS INTEGER
DIM c AS INTEGER

DIM cx AS DOUBLE
DIM cy AS DOUBLE
DIM zx AS DOUBLE
DIM zy AS DOUBLE
DIM zx2 AS DOUBLE
DIM zy2 AS DOUBLE
DIM tx AS DOUBLE

GCLS 0

FOR y = 0 TO 479
    cy = ymin + (y * (ymax - ymin) / 479.0)

    FOR x = 0 TO 639
        cx = xmin + (x * (xmax - xmin) / 639.0)

        zx = 0.0
        zy = 0.0
        i = 0

        WHILE i < max_iter
            zx2 = zx * zx
            zy2 = zy * zy
            IF zx2 + zy2 > 4.0 THEN EXIT WHILE

            tx = zx2 - zy2 + cx
            zy = 2.0 * zx * zy + cy
            zx = tx

            INC i
        WEND

        IF i = max_iter THEN
            c = 1
        ELSE
            c = 16 + (i MOD 14)
        END IF

        PSET x, y, c
    NEXT x

    IF (y MOD 16) = 0 THEN
        IF GKEYDOWN(53) THEN END
    END IF
NEXT y

DRAWTEXT 12, 12, "MANDELBROT RENDERED", 15, 0
DRAWTEXT 12, 30, "ANIMATING COLOURS 16..29 - PRESS ANY KEY", 14, 0
FLIP
VSYNC

' Rotate the 14 user colours forever until keypress/ESC.
' PALCYCLE slot, first_index, last_index, speed, direction
PALCYCLE 0, 16, 29, 2, 1

DO
    VSYNC
    IF GKEYDOWN(53) THEN
        PALSTOPALL
        END
    END IF
LOOP UNTIL GINKEY() > 0

PALSTOPALL
END
