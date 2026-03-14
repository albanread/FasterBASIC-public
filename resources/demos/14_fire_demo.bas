' =========================================================================
' Classic Fire Demo — Cellular Automata + Palette Mapping
' =========================================================================
'
' This demo showcases:
' - Custom palette generation (Black -> Red -> Orange -> Yellow -> White)
' - High-speed heat-map processing
' - Double buffering (FLIP) for smooth animation

' Set a lower resolution for that chunky retro feel (also faster)
SCREEN 320, 200, 2
SCREENTITLE "FasterBASIC - Classic Fire Demo"

' 1. Generate Fire Palette (Global Indices 16-255)
' Using 240 indices for the gradient (16-255)
FOR i = 0 TO 59
    PALETTE 16 + i, i * 4, 0, 0                       ' Black to Red
    PALETTE 76 + i, 255, i * 4, 0                      ' Red to Orange/Yellow
    PALETTE 136 + i, 255, 255, i * 4                  ' Yellow to White/Yellow
    PALETTE 196 + i, 255, 255, 255                    ' Pure White
NEXT i

' 2. Working setup
DIM W AS INTEGER = 320
DIM H AS INTEGER = 200
' Fire buffer (including one extra row at bottom for source)
DIM fire(320, 201) AS INTEGER

DIM x AS INTEGER
DIM y AS INTEGER
DIM c AS INTEGER

GCLS 0

DO
    ' Heat source at the bottom: Randomize the last row (0..239 intensity)
    FOR x = 0 TO W - 1
        fire(x, H) = RND(0, 240)
    NEXT x

    ' Apply many points of random heat for a "sparky" look
    FOR i = 1 TO 20
        fire(RND(0, W), H) = 239
    NEXT i

    ' 3. Process the fire (Moving upwards)
    FOR y = 1 TO H - 1
        FOR x = 1 TO W - 2
            ' Average neighbors below
            c = fire(x - 1, y + 1) + fire(x, y + 1) + fire(x + 1, y + 1) + fire(x, y + 2)
            c = c / 4
            
            ' Apply cooling/decay
            IF c > 1 THEN 
                c = c - 1
            ELSE
                c = 0
            END IF
            
            ' Store and draw
            fire(x, y) = c
            ' Map to global palette (16-255)
            IF c > 0 THEN
                PSET x, y, 16 + c
            ELSE
                PSET x, y, 0  ' Transparent/Background
            END IF
        NEXT x
    NEXT y

    FLIP
    IF GKEYDOWN(53) THEN EXIT DO ' Esc
LOOP
