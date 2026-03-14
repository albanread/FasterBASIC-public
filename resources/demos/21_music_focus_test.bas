' Focused MUSIC/MIDI test
' Keys:
'   1 = play melodic slot 10
'   2 = play percussion slot 11
'   3 = play pad slot 12
'   S = stop music
'   Q = quit

SCREEN 640, 360, 2
SCREENTITLE "Music Focus Test"

SOUND VOLUME 0.0
MUSIC VOLUME 1.0

' Slot 10: obvious square-lead melody
MUSIC LOAD 10, """X:1
T:Lead Test
M:4/4
L:1/8
Q:1/4=160
V:1 program=80
K:C
C E G c | c G E C |"""

' Slot 11: percussion hits on GM channel 10
MUSIC LOAD 11, """X:1
T:Drum Test
M:4/4
L:1/16
Q:1/4=180
K:C
%%MIDI percussion
V:1
[B,,D,^CA]2 z2 [B,,D,]2 z2 | [^C]4 z12 |"""

' Slot 12: sustained pad chord to make silence obvious
MUSIC LOAD 12, """X:1
T:Pad Test
M:4/4
L:1/4
Q:1/4=90
%%MIDI program 91
V:1
K:C
[C E G]4 | z2 [F A c]2 |"""

DIM running AS INTEGER
DIM status$ AS STRING
DIM key_code AS INTEGER
DIM frame_count AS INTEGER
DIM auto_step AS INTEGER
DIM f1 AS INTEGER, f2 AS INTEGER, f3 AS INTEGER
DIM fs AS INTEGER, fq AS INTEGER
DIM c1 AS INTEGER, c2 AS INTEGER, c3 AS INTEGER
DIM cs AS INTEGER, cq AS INTEGER

CONSTANT KEY_1 = 18
CONSTANT KEY_2 = 19
CONSTANT KEY_3 = 20
CONSTANT KEY_S = 1
CONSTANT KEY_Q = 12
CONSTANT KEY_ESC = 53

running = 1
status$ = "Ready"
frame_count = 0
auto_step = 0
f1 = 0 : f2 = 0 : f3 = 0 : fs = 0 : fq = 0

DO WHILE running = 1
    IF auto_step = 0 AND frame_count >= 30 THEN
        f1 = 8
        MUSIC PLAY 10, 1.0
        status$ = "Auto-played slot 10 lead melody"
        auto_step = 1
    ELSEIF auto_step = 1 AND frame_count >= 180 THEN
        f2 = 8
        MUSIC PLAY 11, 1.0
        status$ = "Auto-played slot 11 percussion"
        auto_step = 2
    ELSEIF auto_step = 2 AND frame_count >= 330 THEN
        f3 = 8
        MUSIC PLAY 12, 1.0
        status$ = "Auto-played slot 12 pad"
        auto_step = 3
    END IF

    key_code = GINKEY()
    IF key_code > 0 THEN
        IF key_code = KEY_1 THEN
            f1 = 8
            MUSIC PLAY 10, 1.0
            status$ = "Played slot 10 lead melody"
        ELSEIF key_code = KEY_2 THEN
            f2 = 8
            MUSIC PLAY 11, 1.0
            status$ = "Played slot 11 percussion"
        ELSEIF key_code = KEY_3 THEN
            f3 = 8
            MUSIC PLAY 12, 1.0
            status$ = "Played slot 12 pad"
        ELSEIF key_code = KEY_S THEN
            fs = 8
            MUSIC STOP
            status$ = "Stopped music"
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
    cs = 11 : IF fs > 0 THEN cs = 14
    cq = 11 : IF fq > 0 THEN cq = 14

    DRAWTEXT 20, 20,  "Music Focus Test (MUSIC only)", 15, 0
    DRAWTEXT 20, 34,  "Auto-plays lead, drums, then pad on startup", 8, 0
    DRAWTEXT 20, 48,  "[1] PLAY LEAD", c1, 0
    DRAWTEXT 220, 48, "[2] PLAY DRUMS", c2, 0
    DRAWTEXT 440, 48, "[3] PLAY PAD", c3, 0
    DRAWTEXT 20, 76,  "[S] STOP", cs, 0
    DRAWTEXT 220, 76, "[Q] QUIT", cq, 0

    DRAWTEXT 20, 120, "MUSIC VOLUME=" & STR$(MUSICVOLUME()), 14, 0
    DRAWTEXT 20, 144, "MUSIC COUNT=" & STR$(MUSICCOUNT()), 14, 0
    DRAWTEXT 20, 168, "MUSIC STATE=" & STR$(MUSICSTATE()), 14, 0
    DRAWTEXT 20, 192, "PLAYING(10)=" & STR$(MUSICPLAYING(10)), 10, 0
    DRAWTEXT 20, 216, "PLAYING(11)=" & STR$(MUSICPLAYING(11)), 10, 0
    DRAWTEXT 20, 240, "PLAYING(12)=" & STR$(MUSICPLAYING(12)), 10, 0
    DRAWTEXT 20, 264, "Last key code=" & STR$(key_code), 12, 0
    DRAWTEXT 20, 312, "Status: " & status$, 13, 0

    IF f1 > 0 THEN f1 = f1 - 1
    IF f2 > 0 THEN f2 = f2 - 1
    IF f3 > 0 THEN f3 = f3 - 1
    IF fs > 0 THEN fs = fs - 1
    IF fq > 0 THEN fq = fq - 1
    frame_count = frame_count + 1

    FLIP
    VSYNC
LOOP

MUSIC STOP
MUSIC FREE ALL
SCREENCLOSE
END