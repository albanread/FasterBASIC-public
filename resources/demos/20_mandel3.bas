' =========================================================================
' Mandelbrot Demo v3 — Array Expressions + Built-in COMPLEX
' =========================================================================
'
' This demo uses built-in COMPLEX support:
' - DIM ... AS COMPLEX
' - CMPLX(re, im), REAL(z), IMAG(z)
' - whole-array complex recurrence: z() = z() * z() + c()
APPNAME "Mandel3"
SCREEN 640, 480, 2
SCREENTITLE "Mandelbrot v3 - Array Expressions"

' Palette rules:
'   0 = transparent/black (reserved)
'   1 = black (reserved)
'   2..15 = 14 user-defined colors
PALETTE  1,   0,   0,   0
PALETTE  2,   0,   0,  48
PALETTE  3,   0,   0,  80
PALETTE  4,   0,  16, 112
PALETTE  5,   0,  40, 144
PALETTE  6,   0,  72, 176
PALETTE  7,   0, 104, 208
PALETTE  8,   0, 136, 240
PALETTE  9,  20, 168, 255
PALETTE 10,  56, 200, 224
PALETTE 11,  96, 232, 176
PALETTE 12, 152, 248, 112
PALETTE 13, 208, 232,  64
PALETTE 14, 240, 176,  32
PALETTE 15, 255, 112,   0

DIM viewMin AS COMPLEX
DIM viewMax AS COMPLEX
viewMin = CMPLX(-2.4, -1.35)
viewMax = CMPLX( 1.2,  1.35)

DIM max_iter AS INTEGER
max_iter = 64

DIM W AS INTEGER
W = 640

' Row working buffers (1..640)
DIM cr(640) AS DOUBLE
DIM z(640) AS COMPLEX
DIM cc(640) AS COMPLEX
DIM escaped(640) AS INTEGER
DIM x AS INTEGER
DIM y AS INTEGER
DIM xi AS INTEGER
DIM it AS INTEGER
DIM c AS INTEGER
DIM cy AS DOUBLE
DIM zr AS DOUBLE
DIM zi AS DOUBLE
DIM mag2 AS DOUBLE

' Precompute real coordinate for each x column once
FOR xi = 1 TO W
    cr(xi) = REAL(viewMin) + ((xi - 1) * (REAL(viewMax) - REAL(viewMin)) / 639.0)
NEXT xi

GCLS 0

FOR y = 0 TO 479
    cy = IMAG(viewMin) + (y * (IMAG(viewMax) - IMAG(viewMin)) / 479.0)

    ' Initialize row state
    escaped() = 0
    FOR xi = 1 TO W
        z(xi) = CMPLX(0.0, 0.0)
        cc(xi) = CMPLX(cr(xi), cy)
    NEXT xi

    FOR it = 1 TO max_iter
        z() = z() * z() + cc()

        ' Record first escape iteration per pixel
        FOR xi = 1 TO W
            IF escaped(xi) = 0 THEN
                zr = REAL(z(xi))
                zi = IMAG(z(xi))
                mag2 = zr * zr + zi * zi
                IF mag2 > 4.0 THEN escaped(xi) = it
            END IF
        NEXT xi
    NEXT it

    FOR xi = 1 TO W
        x = xi - 1

        IF escaped(xi) = 0 THEN
            c = 1
        ELSE
            c = 2 + (escaped(xi) MOD 14)
        END IF

        PSET x, y, c
    NEXT xi

    IF (y MOD 16) = 0 THEN
        IF GKEYDOWN(53) THEN END
    END IF
NEXT y

FLIP
VSYNC
DRAWTEXT 14, 14, "MANDELBROT V3 (ARRAY EXPRESSIONS) - PRESS ANY KEY", 15, 0

DO
    IF GKEYDOWN(53) THEN END
LOOP UNTIL GINKEY() > 0
