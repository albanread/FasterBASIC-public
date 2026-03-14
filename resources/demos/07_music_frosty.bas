' Frosty the Snowman ABC playback smoke test.

SCREEN 320, 120, 2
SCREENTITLE "music-frosty"

DRAWTEXT 10, 10, "Frosty the Snowman (ABC)", 15, 0
DRAWTEXT 10, 30, "Key C, L:1/8", 11, 0

MUSIC LOAD 1, """X:1
T:Frosty the Snowman
C:Steve Nelson (1950)
M:C|
L:1/8
Q:1/4=120
K:C
|: G4 E3F | G2 c4 Bc |
d2 c2 B2 A2 | G6 Bc |
d2 c2 B2 A2 | G2 c2 E2 GA |
G2 F2 E2 F2 | G6 z2 :|
|: C2 | A2 A2 c2 c2 | B2 A2 G2 E2 |
F2 A2 G2 F2 | E6 E2 |
D2 D2 B2 B2 | B2 B2 d2 Bc |
d2 c2 B2 A2 | G2 z2 G4 A2 :|]"""

MUSIC PLAY 1, 0.8

DIM ticks AS INTEGER
ticks = 0

DO WHILE ticks < 1500 ' ~25s at 60Hz
	FLIP
	VSYNC
	ticks = ticks + 1
LOOP

MUSIC STOP
MUSIC FREE ALL
SCREENCLOSE

END
