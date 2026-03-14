
' Focused SOUND SFX test (no MUSIC)
' Keys:
'   1 = SHOOT
'   2 = ZAP
'   3 = EXPLODE
'   4 = BIGEXPLODE
'   5 = rapid SHOOT burst
'   6 = rapid EXPLODE burst
'   R = stop all sounds
'   Q = quit

SCREEN 640, 360, 2
SCREENTITLE "SFX Focus Test"

SOUND VOLUME 1.0
MUSIC VOLUME 0.0

' Preload only the effects we need to debug (longer, obvious durations)
SOUND SHOOT 1, 0.85, 0.80
SOUND ZAP 2, 240, 1.00
SOUND EXPLODE 3, 1.00, 1.20
SOUND BIGEXPLODE 4, 1.00, 1.80

DIM running AS INTEGER
DIM status$ AS STRING
DIM key_code AS INTEGER
DIM c1 AS INTEGER, c2 AS INTEGER, c3 AS INTEGER, c4 AS INTEGER
DIM c5 AS INTEGER, c6 AS INTEGER, cr AS INTEGER, cq AS INTEGER
DIM f1 AS INTEGER, f2 AS INTEGER, f3 AS INTEGER, f4 AS INTEGER
DIM f5 AS INTEGER, f6 AS INTEGER, fr AS INTEGER, fq AS INTEGER

CONSTANT KEY_1 = 18
CONSTANT KEY_2 = 19
CONSTANT KEY_3 = 20
CONSTANT KEY_4 = 21
CONSTANT KEY_5 = 23
CONSTANT KEY_6 = 22
CONSTANT KEY_R = 15
CONSTANT KEY_Q = 12
CONSTANT KEY_ESC = 53

running = 1
status$ = "Ready"
f1 = 0 : f2 = 0 : f3 = 0 : f4 = 0
f5 = 0 : f6 = 0 : fr = 0 : fq = 0

DO WHILE running = 1
    key_code = GINKEY()
    IF key_code > 0 THEN
        IF key_code = KEY_1 THEN
            f1 = 8
        SOUND PLAY 1, 1.0, 0.0
        status$ = "Played SHOOT"
        ELSEIF key_code = KEY_2 THEN
            f2 = 8
        SOUND PLAY 2, 1.0, 0.0
        status$ = "Played ZAP"
        ELSEIF key_code = KEY_3 THEN
            f3 = 8
        SOUND PLAY 3, 1.0, 0.0
        status$ = "Played EXPLODE"
        ELSEIF key_code = KEY_4 THEN
            f4 = 8
        SOUND PLAY 4, 1.0, 0.0
        status$ = "Played BIGEXPLODE"
        ELSEIF key_code = KEY_5 THEN
            f5 = 8
        SOUND PLAY 1, 1.0, 0.0
        SOUND PLAY 1, 1.0, 0.0
        SOUND PLAY 1, 1.0, 0.0
        status$ = "Played SHOOT burst"
        ELSEIF key_code = KEY_6 THEN
            f6 = 8
        SOUND PLAY 3, 1.0, 0.0
        SOUND PLAY 3, 1.0, 0.0
        SOUND PLAY 3, 1.0, 0.0
        status$ = "Played EXPLODE burst"
        ELSEIF key_code = KEY_R THEN
            fr = 8
        SOUND STOP
        status$ = "Stopped all sounds"
        ELSEIF key_code = KEY_Q OR key_code = KEY_ESC THEN
            fq = 8
        running = 0
        ELSE
            status$ = "Key code=" & STR$(key_code)
        END IF
    END IF

    GCLS 0

    c1 = 11 : IF f1 > 0 THEN c1 = 14
    c2 = 11 : IF f2 > 0 THEN c2 = 14
    c3 = 11 : IF f3 > 0 THEN c3 = 14
    c4 = 11 : IF f4 > 0 THEN c4 = 14
    c5 = 11 : IF f5 > 0 THEN c5 = 14
    c6 = 11 : IF f6 > 0 THEN c6 = 14
    cr = 11 : IF fr > 0 THEN cr = 14
    cq = 11 : IF fq > 0 THEN cq = 14

    DRAWTEXT 20, 20,  "SFX Focus Test (SOUND only)", 15, 0
    DRAWTEXT 20, 48,  "[1] SHOOT", c1, 0
    DRAWTEXT 170, 48, "[2] ZAP", c2, 0
    DRAWTEXT 290, 48, "[3] EXPLODE", c3, 0
    DRAWTEXT 460, 48, "[4] BIGEXPLODE", c4, 0
    DRAWTEXT 20, 72,  "[5] SHOOT BURST", c5, 0
    DRAWTEXT 290, 72, "[6] EXPLODE BURST", c6, 0
    DRAWTEXT 20, 96,  "[R] STOP ALL", cr, 0
    DRAWTEXT 290, 96, "[Q] QUIT", cq, 0
    DRAWTEXT 20, 132, "SOUND VOLUME=" & STR$(SOUNDVOLUME()), 14, 0
    DRAWTEXT 20, 156, "SOUNDCOUNT=" & STR$(SOUNDCOUNT()), 14, 0
    DRAWTEXT 20, 180, "Last key code=" & STR$(key_code), 12, 0

    DRAWTEXT 20, 204, "PLAYING(1 SHOOT): " & STR$(SOUNDPLAYING(1)), 10, 0
    DRAWTEXT 20, 228, "PLAYING(2 ZAP):   " & STR$(SOUNDPLAYING(2)), 10, 0
    DRAWTEXT 20, 252, "PLAYING(3 EXP):   " & STR$(SOUNDPLAYING(3)), 10, 0
    DRAWTEXT 20, 276, "PLAYING(4 BIG):   " & STR$(SOUNDPLAYING(4)), 10, 0

    DRAWTEXT 20, 320, "Status: " & status$, 13, 0

    IF f1 > 0 THEN f1 = f1 - 1
    IF f2 > 0 THEN f2 = f2 - 1
    IF f3 > 0 THEN f3 = f3 - 1
    IF f4 > 0 THEN f4 = f4 - 1
    IF f5 > 0 THEN f5 = f5 - 1
    IF f6 > 0 THEN f6 = f6 - 1
    IF fr > 0 THEN fr = fr - 1
    IF fq > 0 THEN fq = fq - 1

    FLIP
    VSYNC
LOOP

SOUND STOP
SOUND FREE ALL
SCREENCLOSE
END
