' =========================================================================
' Galaga Sprite Demo: High-Res Scene
' =========================================================================

SCREEN 640, 480, 2
SCREENTITLE "Ed: Galaga High-Res Sprite Demo"

' -------------------------------------------------------------------------
' 0. GAME STATE
' -------------------------------------------------------------------------

GLOBAL px AS DOUBLE
GLOBAL py AS DOUBLE
GLOBAL formation_x AS DOUBLE
GLOBAL formation_y AS DOUBLE
GLOBAL formation_dir AS INTEGER
GLOBAL returnee_count AS INTEGER
GLOBAL ships AS INTEGER
GLOBAL fire_cooldown AS INTEGER
GLOBAL shoot_held AS INTEGER
GLOBAL shoot_release_frames AS INTEGER
GLOBAL p_death_timer AS INTEGER
GLOBAL saucer_active AS INTEGER
GLOBAL saucer_spawn_timer AS INTEGER
GLOBAL saucer_x AS DOUBLE
GLOBAL saucer_y AS DOUBLE
GLOBAL saucer_dx AS DOUBLE
GLOBAL saucer_exploding AS INTEGER

DIM bullet_x(3) AS DOUBLE
DIM bullet_y(3) AS DOUBLE
DIM bullet_dx(3) AS DOUBLE
DIM bullet_active(3) AS INTEGER
DIM enemy_alive(60) AS INTEGER
DIM enemy_dive(60) AS DOUBLE
DIM enemy_return(60) AS DOUBLE
DIM enemy_join_row(60) AS INTEGER
DIM enemy_target_col(60) AS INTEGER
DIM bomb_active(10) AS INTEGER
DIM bomb_x(10) AS DOUBLE
DIM bomb_y(10) AS DOUBLE
DIM bomb_dx(10) AS DOUBLE
DIM bomb_dy(10) AS DOUBLE
DIM p_alive AS INTEGER
DIM p_respawn AS INTEGER
DIM explosion_timer(5) AS INTEGER
DIM score AS INTEGER
DIM score_text AS STRING
DIM prev_score AS INTEGER
DIM i AS INTEGER

FOR i = 1 TO 60 : enemy_alive(i) = 1 : enemy_dive(i) = 0.0 : enemy_return(i) = 0.0 : enemy_join_row(i) = 0 : enemy_target_col(i) = 0 : NEXT i
FOR i = 1 TO 5 : explosion_timer(i) = 20 : NEXT i
FOR i = 0 TO 4 : SPRITE i + 80, 6, -100, -100 : NEXT i
px = 308 : py = 450
p_alive = 1
p_respawn = 0
returnee_count = 0
ships = 3
fire_cooldown = 0
shoot_held = 0
shoot_release_frames = 0
formation_x = 0 : formation_y = 0 : formation_dir = 1

' -------------------------------------------------------------------------
' 1. INITIALIZATION & ART DEFINITION
' -------------------------------------------------------------------------

SUB InitArt()
    ' ─── Player ship palette (Def 0: 16x16) ──────────────────────────
    SPRITE DEF 0, 16, 16
    SPRITE PALETTE 0, 1, 255, 255, 255   ' white hull
    SPRITE PALETTE 0, 2, 220,  20,  20   ' red wings
    SPRITE PALETTE 0, 3,  20,  60, 220   ' blue body
    SPRITE PALETTE 0, 4,   0, 255, 255   ' cyan cockpit
    SPRITE PALETTE 0, 5, 100, 100, 100   ' dark grey engines
    SPRITE PALETTE 0, 6, 255, 200,   0   ' yellow flame

    SPRITE BEGIN 0
    GCLS 0
    SPRITE ROW 0, "0000000110000000"
    SPRITE ROW 1, "0000001111000000"
    SPRITE ROW 2, "0000001111000000"
    SPRITE ROW 3, "0000011111100000"
    SPRITE ROW 4, "0000011441100000"
    SPRITE ROW 5, "0000011331100000"
    SPRITE ROW 6, "0000011331100000"
    SPRITE ROW 7, "0000211111120000"
    SPRITE ROW 8, "0002211111122000"
    SPRITE ROW 9, "0022221111222200"
    SPRITE ROW 10, "0222221111222220"
    SPRITE ROW 11, "2222221111222222"
    SPRITE ROW 12, "2222221111222222"
    SPRITE ROW 13, "2220022552200222"
    SPRITE ROW 14, "0200002552000020"
    SPRITE ROW 15, "0000000660000000"
    SPRITE END

    ' ─── Bee enemy palette (Def 1: 16x16) ───────────────────────────
    SPRITE DEF 1, 16, 16
    SPRITE PALETTE 1, 1,   0,   0,   0   ' black outline
    SPRITE PALETTE 1, 2, 255, 230,   0   ' yellow body
    SPRITE PALETTE 1, 3, 220,  60,  60   ' red wings
    SPRITE PALETTE 1, 4, 255, 255, 255   ' white accents
    SPRITE PALETTE 1, 5,  80, 200, 255   ' cyan eyes

    SPRITE BEGIN 1
    GCLS 0
    ' Thorax/Body (yellow)
    ELLIPSE 8, 10, 5, 4, 2, 1
    ' Head (yellow)
    ELLIPSE 8, 5, 3, 2, 2, 1
    ' Eyes (cyan)
    PSET 6, 4, 5 : PSET 10, 4, 5
    ' Wings (red)
    TRIANGLE 4, 6, 0, 10, 4, 14, 3, 1
    TRIANGLE 12, 6, 16, 10, 12, 14, 3, 1
    ' Wing detail (white)
    GLINE 1, 10, 3, 10, 4
    GLINE 13, 10, 15, 10, 4
    SPRITE END

    ' ─── Boss Galaga palette (Def 2: 24x20) ────────────────────────
    SPRITE DEF 2, 24, 20
    SPRITE PALETTE 2, 1,   0,   0,   0   ' black outline
    SPRITE PALETTE 2, 2,  60, 220,  60   ' green hull
    SPRITE PALETTE 2, 3, 180,  60, 180   ' purple highlights
    SPRITE PALETTE 2, 4,  80,  80, 120   ' dim blue-grey
    SPRITE PALETTE 2, 5, 255,  80, 255   ' bright pink lasers

    SPRITE BEGIN 2
    GCLS 0
    ' Main bulk (green)
    RECT 6, 4, 12, 12, 2, 1
    TRIANGLE 12, 0, 6, 4, 18, 4, 3, 1
    ' Purple wing-ends
    TRIANGLE 6, 4, 0, 8, 6, 12, 3, 1
    TRIANGLE 18, 4, 24, 8, 18, 12, 3, 1
    ' Underside beams (dim blue-grey)
    RECT 8, 16, 8, 2, 4, 1
    ' Highlight accents
    PSET 12, 8, 5 : PSET 12, 12, 5
    SPRITE END

    ' ─── Player bullet (Def 3: 4x8) ───────────────────────────────
    SPRITE DEF 3, 4, 8
    SPRITE PALETTE 3, 1, 255, 255, 255   ' white tip
    SPRITE PALETTE 3, 2, 255, 255,   0   ' yellow core
    SPRITE PALETTE 3, 3, 255, 128,   0   ' orange tail
    SPRITE PALETTE 3, 4, 255,   0,   0   ' red exhaust

    SPRITE BEGIN 3
    GCLS 0
    SPRITE ROW 0, "0110"
    SPRITE ROW 1, "0220"
    SPRITE ROW 2, "0220"
    SPRITE ROW 3, "0220"
    SPRITE ROW 4, "0330"
    SPRITE ROW 5, "0330"
    SPRITE ROW 6, "0440"
    SPRITE ROW 7, "0440"
    SPRITE END

    ' ─── Enemy bullet (Def 4: 4x8) ────────────────────────────────
    SPRITE DEF 4, 4, 8
    SPRITE PALETTE 4, 1, 255, 120,   0   ' orange fireball
    SPRITE PALETTE 4, 2, 255,  60,  60   ' red glow
    SPRITE BEGIN 4
    GCLS 0
    CIRCLEF 2, 2, 2, 2
    CIRCLEF 2, 2, 1, 1
    SPRITE END

    ' ─── Background star (Def 5: 4x4) ──────────────────────────────
    SPRITE DEF 5, 4, 4
    SPRITE PALETTE 5, 1, 200, 200, 255   ' twinkling blue-white
    SPRITE BEGIN 5
    GCLS 0
    PSET 1, 1, 1 : PSET 2, 2, 1
    SPRITE END

    ' ─── Explosion (Def 6: 24x24, 6 frames) ─────────────────────────
    SPRITE DEF 6, 144, 24
    SPRITE FRAMES 6, 24, 24, 6
    SPRITE PALETTE 6, 1, 255, 255,   0   ' yellow core
    SPRITE PALETTE 6, 2, 255, 120,   0   ' orange expansion
    SPRITE PALETTE 6, 3, 200,  50,  50   ' red outer debris
    SPRITE PALETTE 6, 4, 255, 255, 255   ' white flash core

    SPRITE BEGIN 6
    ' Frame 0: White/Yellow flash core
    SPRITE FRAME 0
    GCLS 0
    CIRCLEF 12, 12, 4, 4
    CIRCLEF 12, 12, 2, 1

    ' Frame 1: Expanding yellow core
    SPRITE FRAME 1
    GCLS 0
    CIRCLEF 12, 12, 8, 1
    CIRCLEF 12, 12, 4, 4

    ' Frame 2: Core expanding, Orange expanding
    SPRITE FRAME 2
    GCLS 0
    CIRCLEF 12, 12, 10, 2
    CIRCLEF 12, 12, 6, 1

    ' Frame 3: Orange expanding, Red shards start
    SPRITE FRAME 3
    GCLS 0
    CIRCLEF 12, 12, 11, 2
    TRIANGLE 12, 2, 8, 10, 16, 10, 3, 1
    TRIANGLE 12, 22, 16, 14, 8, 14, 3, 1
    TRIANGLE 2, 12, 10, 16, 10, 8, 3, 1
    TRIANGLE 22, 12, 14, 8, 14, 16, 3, 1

    ' Frame 4: Orange ring, Red shards expanding
    SPRITE FRAME 4
    GCLS 0
    CIRCLE 12, 12, 11, 2
    PSET 12, 0, 3 : PSET 12, 24, 3 : PSET 0, 12, 3 : PSET 24, 12, 3
    PSET 4, 4, 3 : PSET 20, 4, 3 : PSET 4, 20, 3 : PSET 20, 20, 3

    ' Frame 5: Fading red shards
    SPRITE FRAME 5
    GCLS 0
    PSET 12, -2, 3 : PSET 12, 26, 3 : PSET -2, 12, 3 : PSET 26, 12, 3
    PSET 3, 3, 3 : PSET 21, 3, 3 : PSET 3, 21, 3 : PSET 21, 21, 3
    SPRITE END

    ' ─── Bonus saucer (Def 11: 32x14) ─────────────────────────────
    SPRITE DEF 11, 32, 14
    SPRITE PALETTE 11, 1,  20,  20,  20   ' outline
    SPRITE PALETTE 11, 2, 200, 200, 255   ' hull top
    SPRITE PALETTE 11, 3, 120, 150, 255   ' hull body
    SPRITE PALETTE 11, 4, 255, 120,  60   ' engine glow
    SPRITE PALETTE 11, 5, 255, 255, 255   ' canopy

    SPRITE BEGIN 11
    GCLS 0
    ' Body ellipse
    ELLIPSE 16, 8, 14, 5, 3, 1
    ' Top dome
    ELLIPSE 16, 6, 8, 3, 2, 1
    ' Canopy
    ELLIPSE 16, 5, 4, 2, 5, 1
    ' Engine glow
    PSET 6, 11, 4 : PSET 16, 11, 4 : PSET 26, 11, 4
    ' Outline trim
    GLINE 2, 8, 30, 8, 1
    SPRITE END

    ' ─── Butterfly alien palette (Def 7: 16x16) ─────────────────────
    SPRITE DEF 7, 16, 16
    SPRITE PALETTE 7, 1,   0,   0,   0   ' black outline
    SPRITE PALETTE 7, 2, 220,  60, 220   ' magenta wings
    SPRITE PALETTE 7, 3, 255, 255, 255   ' white body
    SPRITE PALETTE 7, 4,   0, 255, 255   ' cyan wing-spot
    SPRITE PALETTE 7, 5, 255, 120,  60   ' orange head

    SPRITE BEGIN 7
    GCLS 0
    ' Body
    RECT 7, 4, 2, 10, 3, 1
    ' Head
    CIRCLEF 8, 3, 2, 5
    ' Wings
    TRIANGLE 7, 4, 0, 0, 0, 8, 2, 1
    TRIANGLE 7, 10, 0, 15, 0, 8, 2, 1
    TRIANGLE 9, 4, 15, 0, 15, 8, 2, 1
    TRIANGLE 9, 10, 15, 15, 15, 8, 2, 1
    ' Wing spots
    PSET 3, 4, 4 : PSET 12, 4, 4
    SPRITE END

    ' ─── Scorpion alien (Def 8: 32x16, 2 frames) ──────────────────────
    ' Frame 0: Pincer Closed | Frame 1: Pincer Open
    SPRITE DEF 8, 32, 16
    SPRITE FRAMES 8, 16, 16, 2
    SPRITE PALETTE 8, 1,   0,   0,   0   ' black
    SPRITE PALETTE 8, 2, 220,   0,   0   ' red shell
    SPRITE PALETTE 8, 3, 255, 255,   0   ' yellow eyes/sting
    SPRITE PALETTE 8, 4, 120, 120, 120   ' grey pincers

    ' Frame 0: Pincer Closed
    SPRITE BEGIN 8
    SPRITE FRAME 0
    SPRITE ROW 0, "0000033000000000"
    SPRITE ROW 1, "0000333300000000"
    SPRITE ROW 2, "0002222220000000"
    SPRITE ROW 3, "0022222222000000"
    SPRITE ROW 4, "0222222222200000"
    SPRITE ROW 5, "0222222222200000"
    SPRITE ROW 6, "0222222222200000"
    SPRITE ROW 7, "0022222222220000"
    SPRITE ROW 8, "0442222224400000"
    SPRITE ROW 9, "4444222244440000"
    SPRITE ROW 10, "4444222244440000"
    SPRITE ROW 11, "0440222204400000"
    SPRITE ROW 12, "0003222230000000"
    SPRITE ROW 13, "0033300333000000"

    ' Frame 1: Pincer Open
    SPRITE FRAME 1
    SPRITE ROW 0, "0000033000000000"
    SPRITE ROW 1, "0000333300000000"
    SPRITE ROW 2, "0002222220000000"
    SPRITE ROW 3, "0022222222000000"
    SPRITE ROW 4, "0222222222200000"
    SPRITE ROW 5, "0222222222200000"
    SPRITE ROW 6, "0222222222200000"
    SPRITE ROW 7, "0022222222220000"
    SPRITE ROW 8, "4402222220440000"
    SPRITE ROW 9, "4400222200440000"
    SPRITE ROW 10, "4400222200440000"
    SPRITE ROW 11, "0440222204400000"
    SPRITE ROW 12, "0003222230000000"
    SPRITE ROW 13, "0033300333000000"
    SPRITE END

    ' ─── Blue Bee (Def 9: 32x16, 2 frames) ──────────────────────────
    ' Frame 0: Wings Up | Frame 1: Wings Down
    SPRITE DEF 9, 32, 16
    SPRITE FRAMES 9, 16, 16, 2
    SPRITE PALETTE 9, 1,   0,   0,   0   ' black outline
    SPRITE PALETTE 9, 2,  60, 100, 255   ' blue body
    SPRITE PALETTE 9, 3, 255, 230,   0   ' yellow wings
    SPRITE PALETTE 9, 4, 150, 200, 255   ' light blue head
    SPRITE PALETTE 9, 5, 220,   0,   0   ' red eyes

    SPRITE BEGIN 9
    GCLS 0
    ' --- FRAME 0: Wings Up ---
    SPRITE FRAME 0
    ' Body/Head
    ELLIPSE 8, 10, 5, 4, 2, 1
    ELLIPSE 8, 5, 3, 2, 4, 1
    PSET 6, 4, 5 : PSET 10, 4, 5
    ' Wings (Angled Up)
    TRIANGLE 4, 8, 0, 2, 4, 2, 3, 1
    TRIANGLE 12, 8, 16, 2, 12, 2, 3, 1

    ' --- FRAME 1: Wings Down ---
    SPRITE FRAME 1
    ' Body/Head
    ELLIPSE 8, 10, 5, 4, 2, 1
    ELLIPSE 8, 5, 3, 2, 4, 1
    PSET 6, 4, 5 : PSET 10, 4, 5
    ' Wings (Angled Down)
    TRIANGLE 4, 10, 0, 14, 4, 14, 3, 1
    TRIANGLE 12, 10, 16, 14, 12, 14, 3, 1
    SPRITE END

    ' ─── Moth (Def 10: 48x16, 3 frames) ─────────────────────────────
    ' Frame 0: Wings Up | Frame 1: Wings Flat | Frame 2: Wings Down
    SPRITE DEF 10, 48, 16
    SPRITE FRAMES 10, 16, 16, 3
    SPRITE PALETTE 10, 1,   0,   0,   0   ' black outline
    SPRITE PALETTE 10, 2, 180, 180, 180   ' grey body
    SPRITE PALETTE 10, 3, 100, 255, 100   ' green wings
    SPRITE PALETTE 10, 4, 255, 255, 255   ' white eyes
    SPRITE PALETTE 10, 5, 255,   0, 255   ' magenta wing spots

    SPRITE BEGIN 10
    GCLS 0

    ' --- FRAME 0: Wings Up ---
    SPRITE FRAME 0
    ' Body
    RECT 6, 4, 4, 10, 2, 1
    ' Eyes
    PSET 6, 4, 4 : PSET 9, 4, 4
    ' Wings Up
    TRIANGLE 6, 6, 0, 0, 2, 8, 3, 1
    TRIANGLE 10, 6, 16, 0, 14, 8, 3, 1
    ' Spots
    PSET 2, 4, 5 : PSET 13, 4, 5

    ' --- FRAME 1: Wings Flat ---
    SPRITE FRAME 1
    ' Body
    RECT 6, 4, 4, 10, 2, 1
    ' Eyes
    PSET 6, 4, 4 : PSET 9, 4, 4
    ' Wings Flat
    TRIANGLE 6, 8, 0, 6, 0, 10, 3, 1
    TRIANGLE 10, 8, 16, 6, 16, 10, 3, 1
    ' Spots
    PSET 2, 8, 5 : PSET 13, 8, 5

    ' --- FRAME 2: Wings Down ---
    SPRITE FRAME 2
    ' Body
    RECT 6, 4, 4, 10, 2, 1
    ' Eyes
    PSET 6, 4, 4 : PSET 9, 4, 4
    ' Wings Down
    TRIANGLE 6, 10, 0, 16, 2, 8, 3, 1
    TRIANGLE 10, 10, 16, 16, 14, 8, 3, 1
    ' Spots
    PSET 2, 12, 5 : PSET 13, 12, 5

    SPRITE END
END SUB

SUB UpdateSaucer(frame AS INTEGER)
    SHARED saucer_active, saucer_spawn_timer, saucer_x, saucer_y, saucer_dx, saucer_exploding
    SHARED explosion_timer
    DIM k AS INTEGER

    ' Sustain: fire random explosions across the saucer wreckage for ~60 frames
    IF saucer_exploding > 0 THEN
        saucer_exploding = saucer_exploding - 1
        IF saucer_exploding MOD 8 = 0 THEN
            FOR k = 1 TO 5
                IF explosion_timer(k) >= 15 THEN
                    explosion_timer(k) = 0
                    SPRITE 80 + k - 1, 6, saucer_x + RND() * 32 - 8, saucer_y + RND() * 14 - 4
                    SPRITE SHOW 80 + k - 1
                    SPRITE ANIMATE 80 + k - 1, 0.35
                    EXIT FOR
                END IF
            NEXT k
        END IF
        EXIT SUB
    END IF

    IF saucer_active = 0 THEN
        saucer_spawn_timer = saucer_spawn_timer - 1
        IF saucer_spawn_timer <= 0 THEN
            IF NOT MUSICPLAYING(12) THEN MUSIC PLAY 12, 1.0
            saucer_active = 1
            saucer_y = 40
            IF RND() < 0.5 THEN
                saucer_x = -40
                saucer_dx = 2.8
            ELSE
                saucer_x = 680
                saucer_dx = -2.8
            END IF
            SPRITE 500, 11, saucer_x, saucer_y
            SPRITE SCALE 500, 1.1, 1.1
            SPRITE SHOW 500
        END IF
        EXIT SUB
    END IF

    saucer_x = saucer_x + saucer_dx
    SPRITE POS 500, saucer_x, saucer_y

    IF saucer_x < -80 OR saucer_x > 720 THEN
        saucer_active = 0
        saucer_spawn_timer = 240 + INT(RND() * 360)
        SPRITE HIDE 500
    END IF
END SUB

SUB InitStars()
    ' Distribute 20 stars across screen (slots 100-119)
    DIM i AS INTEGER
    DIM sx AS INTEGER
    DIM sy AS INTEGER
    FOR i = 0 TO 19
        sx = INT(RND() * 640)
        sy = INT(RND() * 480)
        SPRITE i + 100, 5, sx, sy
        SPRITE SHOW i + 100
    NEXT i
END SUB

SUB DrawShipsHUD()
    ' Render remaining ships as scaled mini-ship icons (instances 300-304)
    DIM i AS INTEGER
    DIM icon_id AS INTEGER
    DIM max_icons AS INTEGER
    DIM sx AS INTEGER
    max_icons = 5
    sx = 560

    FOR i = 0 TO max_icons - 1
        icon_id = 300 + i
        IF i < ships THEN
            SPRITE icon_id, 0, sx + i * 16, 12
            SPRITE SCALE icon_id, 0.6, 0.6
            SPRITE SHOW icon_id
        ELSE
            SPRITE HIDE icon_id
        END IF
    NEXT i
END SUB

SUB InitSounds()
    ' Lower the global sound level a bit to prevent clipping/pops on overlap
    SOUND VOLUME 0.75
    MUSIC VOLUME 3.0

    ' Slot 1: Player shoot — short, softer
    ' SOUND SHOOT 1, 0.35, 0.15
    ' Slot 2: Enemy shoot/bomb — lower pitch, short
    ' SOUND ZAP 2, 320, 0.25
    ' Slot 3: Enemy explosion — tighter, sharper tail
    ' SOUND SMALLEXPLODE 3, 0.85, 0.30
    ' Slot 4: Player explosion — heavier, longer tail
    ' SOUND BIGEXPLODE 4, 0.78, 0.30

    ' Music slot 10: Alien triumph fanfare — plays during GAME OVER
    ' Program 80 = Lead 1 (square wave) — retro arcade tone
    MUSIC LOAD 10, """X:1
    T:Alien Victory
    M:4/4
    L:1/16
    Q:1/4=210
    V:1 program=80
    K:Cm
    G,8 _B,8|c8 _e8|_e4d4c4_B4|G,16|
    G,4G,4_A,4_B,4|c4_e4g4_e4|c8_B8|G,16|
    _E4F4G4_A4|_B4c4_e4g4|fedc_BA_AG|_E16|"""

    ' Music slot 11: Percussion boom — bass drum + snare + crash hit
    ' On channel 10 (GM percussion), note pitches map to drum sounds:
    '   B,, = Acoustic Bass Drum (35)   D, = Acoustic Snare (38)
    '   ^C  = Crash Cymbal 1 (49)       A  = Crash Cymbal 2 (57)
    MUSIC LOAD 11, """X:1
    T:Perc Boom
    M:4/4
    L:1/16
    Q:1/4=200
    K:C
    %%MIDI percussion
    V:1
    [B,,D,^CA]2 z2 [B,,D,]1 z1 z10 |
    """

    MUSIC LOAD 12, """
    X:1
    T:Saucer Wooh
    M:4/4
    L:1/16
    Q:1/4=160
    K:C
    %%MIDI program 91
    V:1
    G2 z2 G2 z2 | (GABc)(cBAG) ||
    """

    ' Music slot 13: Player wins — bright glockenspiel fanfare
    MUSIC LOAD 13, """X:1
    T:You Win!
    M:4/4
    L:1/16
    Q:1/4=234
    K:C
    %%MIDI program 9
    V:1
    c2e2g2c'2 e'2c'2b2a2 | g2e2c2G2 c4 z4 |
    f2a2c'2f'2 e'2d'2c'2b2 | c'16 |"""

    ' Music slot 14: Stage start — ominous choir build
    MUSIC LOAD 14, """X:1
    T:Stage Alert
    M:4/4
    L:1/16
    Q:1/4=84
    K:Am
    %%MIDI program 52
    V:1
    z8 A,4 E4 | A4 c4 e4 d4 | c8 B8 | A16 |"""

    ' Music slot 15: Player ship destroyed — massive multi-drum impact + crash ring
    MUSIC LOAD 15, """X:1
    T:Player Explodes
    M:4/4
    L:1/16
    Q:1/4=180
    K:C
    %%MIDI percussion
    V:1
    [B,,D,^CA]8 [B,,D,]2 [^C]4 z2 |"""

    ' Music slot 16: Alien destroyed — short deep bass boom (bass drums + low floor tom)
    MUSIC LOAD 16, """X:1
    T:Alien Boom
    M:4/4
    L:1/16
    Q:1/4=200
    K:C
    %%MIDI percussion
    V:1
    [B,,C,E]4 z12 |"""

    ' Music slot 17: Saucer destruction — sustained rolling crash + bass cascade
    MUSIC LOAD 17, """X:1
    T:Saucer Death
    M:4/4
    L:1/16
    Q:1/4=160
    K:C
    %%MIDI percussion
    V:1
    [B,,^CA]8 [B,,D,]4 ^C4 |
    [B,,D,]4 ^C4 [B,,]4 ^C4 |
    ^C8 z8 |"""

END SUB

SUB InitPlayer()
    SHARED px
    ' py is 450, which is near the bottom of the 480px screen
    SPRITE 0, 0, px, 450
    SPRITE SHOW 0
END SUB

SUB InitEnemies()
    SHARED formation_x, formation_y
    ' Arrange enemy grid (instances 1-50)
    ' Row 0: 10 Bosses (slots 1-10)
    ' Row 1: 10 Butterflies (slots 11-20)
    ' Row 2: 10 Bees (slots 21-30)
    ' Row 3: 10 Scorpions (slots 31-40)
    ' Row 4: 10 Blue Bees (slots 41-50) - Animated!
    DIM i AS INTEGER
    DIM ex AS INTEGER
    DIM ey AS INTEGER

    ' Top row: Bosses (Def 2) — one empty returnee row above at y=60
    FOR i = 1 TO 10
        ex = 80 + (i - 1) * 50 + formation_x
        ey = 100 + formation_y
        SPRITE i, 2, ex, ey
        SPRITE SHOW i
    NEXT i

    ' Row 1: Butterflies (Def 7)
    FOR i = 11 TO 20
        ex = 88 + (i - 11) * 50 + formation_x
        ey = 140 + formation_y
        SPRITE i, 7, ex, ey
        SPRITE SHOW i
        SPRITE ANIMATE i, 0.05
    NEXT i

    ' Row 2: Bees (Def 1)
    FOR i = 21 TO 30
        ex = 88 + (i - 21) * 50 + formation_x
        ey = 180 + formation_y
        SPRITE i, 1, ex, ey
        SPRITE SHOW i
        SPRITE ANIMATE i, 0.05
    NEXT i

    ' Row 3: Scorpions (Def 8)
    FOR i = 31 TO 40
        ex = 88 + (i - 31) * 50 + formation_x
        ey = 220 + formation_y
        SPRITE i, 8, ex, ey
        SPRITE SHOW i
        SPRITE ANIMATE i, 0.05
    NEXT i

    ' Row 4: Blue Bees (Def 9)
    FOR i = 41 TO 50
        ex = 88 + (i - 41) * 50 + formation_x
        ey = 260 + formation_y
        SPRITE i, 9, ex, ey
        SPRITE SHOW i
        SPRITE ANIMATE i, 0.08
    NEXT i

    ' Row 5: Moths (Def 10)
    FOR i = 51 TO 60
        ex = 88 + (i - 51) * 50 + formation_x
        ey = 300 + formation_y
        SPRITE i, 10, ex, ey
        SPRITE SHOW i
        SPRITE ANIMATE i, 0.04
    NEXT i
END SUB

' -------------------------------------------------------------------------
' 2. UPDATE LOGIC
' -------------------------------------------------------------------------

SUB UpdateStars()
    ' Scroll stars down and wrap
    DIM i AS INTEGER, sy AS DOUBLE
    FOR i = 100 TO 119
        sy = SPRITEY(i) + 1.5
        IF sy > 480 THEN sy = -4
        SPRITE POS i, SPRITEX(i), sy
    NEXT i
END SUB

SUB UpdateScoreText()
    SHARED score, score_text, prev_score
    IF score <> prev_score THEN
        score_text = "SCORE: " & RIGHT$("000000" & STR$(score), 6)
        prev_score = score
    END IF
END SUB

SUB UpdatePlayer(frame AS INTEGER)
    SHARED px, py, p_alive, p_respawn, explosion_timer, ships, fire_cooldown, p_death_timer, shoot_held, shoot_release_frames
    SHARED bullet_active, bullet_x, bullet_y, bullet_dx
    DIM k AS INTEGER

    IF p_alive = 0 THEN
        ' Sustain the death spectacle — fire fresh explosion bursts every 18 frames
        IF p_death_timer > 0 THEN
            p_death_timer = p_death_timer - 1
            IF p_death_timer MOD 18 = 0 THEN
                FOR k = 1 TO 5
                    IF explosion_timer(k) >= 15 THEN
                        explosion_timer(k) = 0
                        SPRITE 80 + k - 1, 6, px + INT(RND() * 28) - 14, 440 + INT(RND() * 14) - 7
                        SPRITE SHOW 80 + k - 1
                        SPRITE ANIMATE 80 + k - 1, 0.3
                        EXIT FOR
                    END IF
                NEXT k
            END IF
            EXIT SUB
        END IF
        p_respawn = p_respawn + 1
        IF p_respawn > 100 THEN
            IF ships > 0 THEN
                p_alive = 1
                p_respawn = 0
                px = 308 : py = 450
                SPRITE POS 0, px, 440
                SPRITE SHOW 0
            END IF
        END IF
        EXIT SUB
    END IF

    ' Manual movement + lean aim
    DIM aim_dx AS DOUBLE
    DIM ship_angle AS DOUBLE
    ship_angle = 0.0
    aim_dx = 0.0

    IF GKEYDOWN(123) THEN
        px = px - 4.0
        ship_angle = -12.0
        aim_dx = -2.0
    END IF
    IF GKEYDOWN(124) THEN
        px = px + 4.0
        ship_angle = 12.0
        aim_dx = 2.0
    END IF
    IF GKEYDOWN(126) THEN
        ship_angle = 0.0
        aim_dx = 0.0
    END IF

    ' Clamp to screen
    IF px < 10 THEN px = 10
    IF px > 614 THEN px = 614

    SPRITE POS 0, px, 440    ' Force Y to bottom of screen (480 total height)
    SPRITE ROT 0, ship_angle
    SPRITE SHOW 0

    ' Manual fire (spacebar = 49)
    IF fire_cooldown > 0 THEN
        fire_cooldown = fire_cooldown - 1
    END IF

    ' Edge-triggered shoot: only once per physical key-down.
    DIM key_down AS INTEGER
    key_down = GKEYDOWN(49)

    ' Debounce key-up: require a few consecutive frames of key_down=0 before releasing shoot_held
    IF key_down = 0 THEN
        shoot_release_frames = shoot_release_frames + 1
        IF shoot_release_frames >= 3 THEN
            shoot_held = 0
            shoot_release_frames = 3 ' clamp
        END IF
    ELSE
        shoot_release_frames = 0
        IF shoot_held = 0 THEN
            ' First stable press after release
            shoot_held = 1
            IF fire_cooldown = 0 THEN
                DIM i AS INTEGER
                FOR i = 1 TO 3
                    IF bullet_active(i) = 0 THEN
                        bullet_active(i) = 1
                        bullet_x(i) = px + 6 + aim_dx * 2.0
                        bullet_y(i) = 430  ' Align bullet start with ship Y (440)
                        bullet_dx(i) = aim_dx
                        SPRITE i + 60, 3, bullet_x(i), bullet_y(i)
                        SPRITE SHOW i + 60
                        fire_cooldown = 15 ' 15 frames cooldown
                        IF NOT MUSICPLAYING(11) THEN MUSIC PLAY 11, 1.0
                        ' IF NOT SOUNDPLAYING(1) THEN SOUND PLAY 1, 0.75
                        EXIT FOR
                    END IF
                NEXT i
            END IF
        END IF
    END IF
END SUB

SUB UpdateEnemies(frame AS INTEGER)
    SHARED formation_x, formation_y, formation_dir
    SHARED enemy_alive, enemy_dive, enemy_return, enemy_join_row, enemy_target_col, bomb_active, bomb_x, bomb_y, bomb_dx, bomb_dy, p_alive, p_respawn, p_death_timer, explosion_timer, returnee_count, ships
    ' 1. Move formation horizontally in current direction
    formation_x = formation_x + (1.5 * formation_dir)

    ' 2. Edge check: if formation hits bounds, step down and reverse
    ' Right edge trigger: leftmost enemy (80) + width (450) + offset(100) = 630.
    ' Left edge trigger: leftmost enemy (80) + offset(-70) = 10.
    IF formation_x > 100 THEN
        formation_dir = -1
        formation_y = formation_y + 10
    ELSEIF formation_x < -70 THEN
        formation_dir = 1
        formation_y = formation_y + 10
    END IF

    ' 3. Random dive logic — divers come from the lowest surviving row
    DIM i AS INTEGER, ex AS DOUBLE, ey AS DOUBLE, t AS DOUBLE
    DIM dx_dive AS DOUBLE, dy_dive AS DOUBLE, ey_target AS DOUBLE
    DIM ri AS INTEGER
    DIM front_start AS INTEGER, front_end AS INTEGER, any_alive AS INTEGER
    DIM jj AS INTEGER, tc AS INTEGER, try_tc AS INTEGER, orig_col AS INTEGER, col_taken AS INTEGER
    DIM total_shuffle AS DOUBLE, shuffle_t AS DOUBLE

    ' Determine the lowest row with living original enemies (not returnees).
    ' Start at Bosses (row 1-10) as the fallback; each surviving lower row
    ' displaces it downward so the front line is always the bottom-most row.
    front_start = 1 : front_end = 10

    any_alive = 0
    FOR i = 11 TO 20
        IF enemy_alive(i) = 1 AND enemy_join_row(i) = 0 THEN any_alive = 1
    NEXT i
    IF any_alive = 1 THEN front_start = 11 : front_end = 20

    any_alive = 0
    FOR i = 21 TO 30
        IF enemy_alive(i) = 1 AND enemy_join_row(i) = 0 THEN any_alive = 1
    NEXT i
    IF any_alive = 1 THEN front_start = 21 : front_end = 30

    any_alive = 0
    FOR i = 31 TO 40
        IF enemy_alive(i) = 1 AND enemy_join_row(i) = 0 THEN any_alive = 1
    NEXT i
    IF any_alive = 1 THEN front_start = 31 : front_end = 40

    any_alive = 0
    FOR i = 41 TO 50
        IF enemy_alive(i) = 1 AND enemy_join_row(i) = 0 THEN any_alive = 1
    NEXT i
    IF any_alive = 1 THEN front_start = 41 : front_end = 50

    any_alive = 0
    FOR i = 51 TO 60
        IF enemy_alive(i) = 1 AND enemy_join_row(i) = 0 THEN any_alive = 1
    NEXT i
    IF any_alive = 1 THEN front_start = 51 : front_end = 60

    ' Check if any original enemies (non-returnee) are still alive
    DIM originals_alive AS INTEGER
    originals_alive = 0
    DIM total_alive AS INTEGER
    total_alive = 0
    FOR i = 1 TO 60
        IF enemy_alive(i) = 1 THEN
            total_alive = total_alive + 1
            IF enemy_join_row(i) = 0 AND enemy_return(i) = 0 AND enemy_dive(i) = 0 THEN
                originals_alive = 1
            END IF
        END IF
    NEXT i

    IF originals_alive = 0 OR total_alive < 5 THEN
        ' FRENZY: only returnees left or less than 5 total — send them all diving every 8 frames
        IF frame MOD 8 = 0 THEN
            FOR i = 1 TO 60
                IF enemy_alive(i) = 1 AND enemy_dive(i) = 0 AND enemy_return(i) = 0 THEN
                    enemy_dive(i) = 0.001
                END IF
            NEXT i
        END IF
    ELSE
        ' Every 45 frames, pick a random diver from the front-line row
        IF frame MOD 45 = 0 THEN
            ri = front_start + INT(RND() * (front_end - front_start + 1))
            IF enemy_alive(ri) = 1 AND enemy_dive(ri) = 0 AND enemy_return(ri) = 0 AND enemy_join_row(ri) = 0 THEN
                enemy_dive(ri) = 0.001
            END IF
        END IF
    END IF

    ' 4. Enemy Bomb logic
    ' In frenzy mode, drop bombs more frequently
    DIM bomb_rate AS INTEGER
    IF originals_alive = 0 OR total_alive < 5 THEN
        bomb_rate = 10
    ELSE
        bomb_rate = 25
    END IF

    IF frame MOD bomb_rate = 0 THEN
        ri = 1 + INT(RND() * 59)
        IF enemy_alive(ri) = 1 THEN
            FOR i = 1 TO 10
                IF bomb_active(i) = 0 THEN
                    bomb_active(i) = 1
                    bomb_x(i) = SPRITEX(ri) + 6
                    bomb_y(i) = SPRITEY(ri) + 12

                    bomb_dx(i) = 0.0
                    bomb_dy(i) = 4.0

                    SPRITE i + 200, 4, bomb_x(i), bomb_y(i)
                    SPRITE SHOW i + 200
                    EXIT FOR
                END IF
            NEXT i
        END IF
    END IF

    ' Update bombs
    DIM k AS INTEGER
    FOR i = 1 TO 10
        IF bomb_active(i) = 1 THEN
            bomb_x(i) = bomb_x(i) + bomb_dx(i)
            bomb_y(i) = bomb_y(i) + bomb_dy(i)
            SPRITE POS i + 200, bomb_x(i), bomb_y(i)
            IF bomb_y(i) > 480 OR bomb_x(i) < 0 OR bomb_x(i) > 640 THEN
                bomb_active(i) = 0
                SPRITE HIDE i + 200
            END IF

            ' Collision with player
            IF p_alive = 1 THEN
                IF SPRITEHIT(i + 200, 0) THEN
                    p_alive = 0
                    p_respawn = 0
                    p_death_timer = 150
                    ships = ships - 1
                    bomb_active(i) = 0
                    SPRITE HIDE i + 200
                    SPRITE HIDE 0
                    ' Player explosion — sound only when we actually spawn it
                    FOR k = 1 TO 5
                        IF explosion_timer(k) >= 15 THEN
                            explosion_timer(k) = 0
                            SPRITE 80 + k - 1, 6, SPRITEX(0), SPRITEY(0)
                            SPRITE SHOW 80 + k - 1
                            SPRITE ANIMATE 80 + k - 1, 0.4
                           ' IF NOT SOUNDPLAYING(4) THEN SOUND PLAY 4, 0.85
                            IF NOT MUSICPLAYING(15) THEN MUSIC PLAY 15, 1.0
                            EXIT FOR
                        END IF
                    NEXT k
                END IF
            END IF
        END IF
    NEXT i

    FOR i = 1 TO 60
        IF enemy_alive(i) = 1 THEN
            ' Determine 'formation base position' for each enemy
            ' Returnee rows sit above the main formation
            IF enemy_join_row(i) > 0 THEN
                ex = 88 + ((enemy_join_row(i) - 1) MOD 10) * 50 + formation_x
                ' If the matching Boss-row slot is vacant, drift down to fill it
                ri = ((enemy_join_row(i) - 1) MOD 10) + 1
                IF enemy_alive(ri) = 0 THEN
                    ey = 100 + formation_y   ' fill gap in Boss row
                ELSE
                    ey = 60 + formation_y    ' hold returnee row
                END IF
            ELSEIF i <= 10 THEN
                ex = 80 + (i - 1) * 50 + formation_x
                ey = 100 + formation_y
            ELSEIF i <= 20 THEN
                ex = 88 + (i - 11) * 50 + formation_x
                ey = 140 + formation_y
            ELSEIF i <= 30 THEN
                ex = 88 + (i - 21) * 50 + formation_x
                ey = 180 + formation_y
            ELSEIF i <= 40 THEN
                ex = 88 + (i - 31) * 50 + formation_x
                ey = 220 + formation_y
            ELSEIF i <= 50 THEN
                ex = 88 + (i - 41) * 50 + formation_x
                ey = 260 + formation_y
            ELSE
                ex = 88 + (i - 51) * 50 + formation_x
                ey = 300 + formation_y
            END IF

            ' If a formation enemy has descended to the player line, force a dive
            IF enemy_dive(i) = 0 AND enemy_return(i) = 0 AND ey >= py THEN
                enemy_dive(i) = 0.001
            END IF

            ' Dive / return arc
            IF enemy_dive(i) > 0 THEN
                enemy_dive(i) = enemy_dive(i) + 0.004
                t = enemy_dive(i)

                ' Smooth swoop: wide sinusoid X, linear Y
                ' dx_dive is the total offset, so the instantaneous velocity in X is the derivative:
                ' d(dx_dive)/dt = 180.0 * 2.5 * COS(t * 2.5) = 450.0 * COS(t * 2.5)
                ' dy_dive is the total offset, so the instantaneous velocity in Y is the derivative:
                ' d(dy_dive)/dt = 450.0
                dx_dive = SIN(t * 2.5) * 180.0
                dy_dive = t * 450.0

                ' ATAN2(y, x) gives angle from positive X axis.
                ' We want angle from positive Y axis (downwards), so we swap x and y and negate x.
                ' Actually, standard rotation is 0 = up, 90 = right, 180 = down, 270 = left.
                ' Velocity vector: vx = 450.0 * COS(t * 2.5), vy = 450.0
                ' Angle = ATAN2(vx, -vy) * 57.295 + 180
                SPRITE ROT i, ATAN2(450.0 * COS(t * 2.5), -450.0) * 57.295 + 180.0

                ex = ex + dx_dive
                ey = ey + dy_dive

                ' Off bottom — assign a free return column, then begin return arc
                IF ey > 550 THEN
                    ' Prefer the enemy's own original column (1-10), fall back to nearest free one
                    tc = ((i - 1) MOD 10) + 1
                    ' Check whether preferred column is already claimed
                    col_taken = 0
                    FOR jj = 1 TO 60
                        IF jj <> i AND enemy_alive(jj) = 1 THEN
                            IF enemy_target_col(jj) = tc AND enemy_return(jj) > 0 THEN col_taken = 1
                            IF enemy_join_row(jj) = tc AND enemy_dive(jj) = 0 AND enemy_return(jj) = 0 THEN col_taken = 1
                        END IF
                    NEXT jj
                    ' Scan for a free column if needed
                    IF col_taken = 1 THEN
                        FOR try_tc = 1 TO 10
                            col_taken = 0
                            FOR jj = 1 TO 60
                                IF jj <> i AND enemy_alive(jj) = 1 THEN
                                    IF enemy_target_col(jj) = try_tc AND enemy_return(jj) > 0 THEN col_taken = 1
                                    IF enemy_join_row(jj) = try_tc AND enemy_dive(jj) = 0 AND enemy_return(jj) = 0 THEN col_taken = 1
                                END IF
                            NEXT jj
                            IF col_taken = 0 THEN tc = try_tc : EXIT FOR
                        NEXT try_tc
                    END IF
                    enemy_target_col(i) = tc
                    enemy_dive(i) = 0.0
                    enemy_return(i) = 0.001
                    ex = ex - dx_dive   ' restore formation column x
                    ey = -30.0
                    SPRITE ROT i, 180.0  ' nose pointing down on entry
                END IF

            ELSEIF enemy_return(i) > 0 THEN
                enemy_return(i) = enemy_return(i) + 0.004
                t = enemy_return(i)

                ' Home toward the pre-assigned column — prevents any two returners overlapping
                ey_target = 60.0 + formation_y
                ex = 88.0 + (enemy_target_col(i) - 1) * 50.0 + formation_x
                dx_dive = SIN(t * 3.14159) * 80.0   ' lateral flourish, zero at t=0 and t=1
                ey = -30.0 + t * (ey_target + 30.0)
                ex = ex + dx_dive

                ' Rotation: 180° (nose-down) on entry, 0° (upright) on landing
                SPRITE ROT i, 180.0 * (1.0 - t)

                ' Landed — slot into pre-assigned column
                IF enemy_return(i) >= 1.0 THEN
                    enemy_return(i) = 0.0
                    enemy_join_row(i) = enemy_target_col(i)
                    SPRITE ROT i, 0.0
                END IF

            ELSE
                SPRITE ROT i, 0.0
            END IF

            ' Shuffle: stationary formation members slide aside as a returner descends
            total_shuffle = 0.0
            IF enemy_dive(i) = 0 AND enemy_return(i) = 0 AND enemy_join_row(i) = 0 THEN
                orig_col = ((i - 1) MOD 10) + 1
                FOR jj = 1 TO 60
                    IF enemy_alive(jj) = 1 AND enemy_return(jj) > 0 AND enemy_target_col(jj) > 0 THEN
                        ' Peaks mid-arc (sin), zero at start and on landing — no visual pop
                        shuffle_t = SIN(enemy_return(jj) * 3.14159)
                        IF orig_col > enemy_target_col(jj) AND (orig_col - enemy_target_col(jj)) <= 2 THEN
                            total_shuffle = total_shuffle + 22.0 * shuffle_t
                        ELSEIF orig_col < enemy_target_col(jj) AND (enemy_target_col(jj) - orig_col) <= 2 THEN
                            total_shuffle = total_shuffle - 22.0 * shuffle_t
                        END IF
                    END IF
                NEXT jj
            END IF

            SPRITE POS i, ex + total_shuffle, ey

            ' Collision with player
            IF p_alive = 1 THEN
                IF SPRITEHIT(i, 0) THEN
                    p_alive = 0
                    p_respawn = 0
                    p_death_timer = 150
                    enemy_alive(i) = 0
                    ships = ships - 1
                    SPRITE HIDE i
                    SPRITE HIDE 0

                    ' Player explosion — sound only when spawned
                    FOR k = 1 TO 5
                        IF explosion_timer(k) >= 15 THEN
                            explosion_timer(k) = 0
                            SPRITE 80 + k - 1, 6, SPRITEX(0), SPRITEY(0)
                            SPRITE SHOW 80 + k - 1
                            SPRITE ANIMATE 80 + k - 1, 0.4
                            IF NOT MUSICPLAYING(15) THEN MUSIC PLAY 15, 1.0
                            ' IF NOT SOUNDPLAYING(4) THEN SOUND PLAY 4, 0.85
                            EXIT FOR
                        END IF
                    NEXT k

                    ' Enemy explosion — sound only when spawned
                    FOR k = 1 TO 5
                        IF explosion_timer(k) >= 15 THEN
                            explosion_timer(k) = 0
                            SPRITE 80 + k - 1, 6, SPRITEX(i), SPRITEY(i)
                            SPRITE SHOW 80 + k - 1
                            SPRITE ANIMATE 80 + k - 1, 0.4
                            IF NOT MUSICPLAYING(16) THEN MUSIC PLAY 16, 1.0
                            ' IF NOT SOUNDPLAYING(3) THEN SOUND PLAY 3, 0.8
                            EXIT FOR
                        END IF
                    NEXT k
                END IF
            END IF
        END IF
    NEXT i
END SUB

SUB UpdateEnemiesCelebration(frame AS INTEGER)
    SHARED enemy_alive
    DIM i AS INTEGER
    DIM cx AS DOUBLE, cy AS DOUBLE
    DIM angle AS DOUBLE, radius AS DOUBLE
    DIM ex AS DOUBLE, ey AS DOUBLE
    cx = 320.0
    cy = 240.0

    FOR i = 1 TO 60
        IF enemy_alive(i) = 1 THEN
            angle = frame * 0.04 + i * 0.2
            radius = 120.0 + SIN(frame * 0.02 + i * 0.1) * 100.0

            ex = cx + COS(angle) * radius
            ey = cy + SIN(angle) * radius

            SPRITE POS i, ex, ey
            SPRITE ROT i, (angle * 57.295) + 90.0
        END IF
    NEXT i
END SUB

SUB UpdateBullets()
    ' Move bullets and check collisions
    SHARED bullet_active, bullet_x, bullet_y, bullet_dx, enemy_alive, enemy_dive, explosion_timer, frame, score
    SHARED saucer_active, saucer_x, saucer_y, saucer_spawn_timer, saucer_exploding
    DIM i AS INTEGER, j AS INTEGER, k AS INTEGER, exp_count AS INTEGER
    FOR i = 1 TO 3
        IF bullet_active(i) = 1 THEN
            bullet_y(i) = bullet_y(i) - 6
            bullet_x(i) = bullet_x(i) + bullet_dx(i)
            SPRITE POS i + 60, bullet_x(i), bullet_y(i)

            ' Bounds check
            IF bullet_y(i) < -10 OR bullet_x(i) < -20 OR bullet_x(i) > 660 THEN
                bullet_active(i) = 0
                SPRITE HIDE i + 60
            END IF

            ' Collision check: bullets vs enemies
            FOR j = 1 TO 60
                IF enemy_alive(j) = 1 AND bullet_active(i) = 1 THEN
                    IF SPRITEHIT(i + 60, j) THEN
                        enemy_alive(j) = 0
                        bullet_active(i) = 0
                        score = score + 10
                        SPRITE HIDE j
                        SPRITE HIDE i + 60

                        ' Trigger explosion at enemy position (sound only when spawned)
                        FOR k = 1 TO 5
                            IF explosion_timer(k) >= 15 THEN
                                explosion_timer(k) = 0
                                SPRITE 80 + k - 1, 6, SPRITEX(j), SPRITEY(j)
                                SPRITE SHOW 80 + k - 1
                                SPRITE ANIMATE 80 + k - 1, 0.4
                                IF NOT MUSICPLAYING(16) THEN MUSIC PLAY 16, 1.0
                                EXIT FOR
                            END IF
                        NEXT k
                    END IF
                END IF
            NEXT j

            ' Collision vs saucer bonus
            IF saucer_active = 1 AND bullet_active(i) = 1 THEN
                IF SPRITEHIT(i + 60, 500) THEN
                    bullet_active(i) = 0
                    SPRITE HIDE i + 60
                    saucer_active = 0
                    SPRITE HIDE 500
                    saucer_spawn_timer = 300 + INT(RND() * 360)
                    score = score + 100
                    saucer_exploding = 64
                    MUSIC PLAY 17, 1.0
                    ' Spawn 3 explosions for the initial hit burst
                    exp_count = 0
                    FOR k = 1 TO 5
                        IF explosion_timer(k) >= 15 AND exp_count < 3 THEN
                            explosion_timer(k) = 0
                            IF exp_count = 0 THEN
                                SPRITE 80 + k - 1, 6, saucer_x,      saucer_y
                            ELSEIF exp_count = 1 THEN
                                SPRITE 80 + k - 1, 6, saucer_x + 14, saucer_y - 5
                            ELSE
                                SPRITE 80 + k - 1, 6, saucer_x + 25, saucer_y + 3
                            END IF
                            SPRITE SHOW 80 + k - 1
                            SPRITE ANIMATE 80 + k - 1, 0.4
                            exp_count = exp_count + 1
                        END IF
                    NEXT k
                END IF
            END IF
        END IF
    NEXT i

    ' Tick explosion timers
    FOR k = 1 TO 5
        IF explosion_timer(k) < 15 THEN
            explosion_timer(k) = explosion_timer(k) + 1
            IF explosion_timer(k) >= 15 THEN SPRITE HIDE 80 + k - 1
        END IF
    NEXT k
END SUB

SUB ResetGameState()
    SHARED enemy_alive, enemy_dive, enemy_return, enemy_join_row, enemy_target_col
    SHARED explosion_timer, bullet_active, bullet_dx, bomb_active
    SHARED px, py, p_alive, p_respawn, returnee_count, ships, fire_cooldown, shoot_held, shoot_release_frames
    SHARED formation_x, formation_y, formation_dir, score
    SHARED saucer_active, saucer_spawn_timer, saucer_exploding
    DIM i AS INTEGER

    FOR i = 1 TO 60 : enemy_alive(i) = 1 : enemy_dive(i) = 0.0 : enemy_return(i) = 0.0 : enemy_join_row(i) = 0 : enemy_target_col(i) = 0 : NEXT i
    FOR i = 1 TO 5 : explosion_timer(i) = 20 : SPRITE HIDE i + 80 - 1 : NEXT i
    FOR i = 1 TO 3 : bullet_active(i) = 0 : bullet_dx(i) = 0 : SPRITE HIDE i + 60 : NEXT i
    FOR i = 1 TO 10 : bomb_active(i) = 0 : SPRITE HIDE i + 200 : NEXT i

    px = 308 : py = 450
    p_alive = 1
    p_respawn = 0
    p_death_timer = 0
    returnee_count = 0
    ships = 3
    score = 0
    score_text = "SCORE: 000000"
    prev_score = -1
    fire_cooldown = 0
    shoot_held = 0
    shoot_release_frames = 0
    saucer_active = 0
    saucer_exploding = 0
    saucer_spawn_timer = 240
    formation_x = 0 : formation_y = 0 : formation_dir = 1

    SPRITE HIDE 500

    MUSIC STOP
    CALL InitPlayer()
    CALL InitEnemies()
END SUB

' -------------------------------------------------------------------------
' 3. MAIN LOOP
' -------------------------------------------------------------------------

CALL InitArt()
CALL InitStars()
CALL InitSounds()

DIM quit_game AS INTEGER
quit_game = 0

DIM frame AS INTEGER
DIM all_dead AS INTEGER
DIM intro_timer AS INTEGER
DIM intro_color AS INTEGER
DIM key_pressed AS INTEGER
DIM flash_color AS INTEGER
DIM flash_timer AS INTEGER

CONSTANT STATE_INTRO = 0
CONSTANT STATE_PLAYING = 1
CONSTANT STATE_GAMEOVER = 2
CONSTANT STATE_WIN = 3
CONSTANT DEBUG_SHOOT = 0
CONSTANT DEBUG_SHOOT_PRINT_INTERVAL = 6

DIM game_state AS INTEGER
game_state = STATE_INTRO

CALL ResetGameState()

DO
    GCLS 0
    CALL UpdateScoreText()

    IF GKEYDOWN(53) THEN
        quit_game = 1
        EXIT DO
    END IF

    IF game_state = STATE_INTRO THEN
        DRAWTEXT 10, 10, score_text, 15, 0
        DRAWTEXT 280, 20, "STAGE 1", 15, 0
        CALL DrawShipsHUD()
        CALL UpdateStars()

        IF intro_timer = 0 THEN MUSIC PLAY 14, 1.0

        intro_color = 9 + ((intro_timer / 10) MOD 6)
        DRAWTEXT 260, 200, "PLAYER 1 READY", intro_color, 0

        key_pressed = GINKEY()
        IF key_pressed = 53 OR key_pressed = 12 THEN ' 53 = Esc, 12 = 'q'
            quit_game = 1
            EXIT DO
        ELSEIF key_pressed > 0 THEN
            game_state = STATE_PLAYING
            frame = 0
        END IF

        intro_timer = intro_timer + 1
        IF intro_timer > 600 THEN
            game_state = STATE_PLAYING
            frame = 0
        END IF

    ELSEIF game_state = STATE_PLAYING THEN
        DRAWTEXT 10, 10, score_text, 15, 0
        DRAWTEXT 280, 20, "STAGE 1", 15, 0
        CALL DrawShipsHUD()

        IF DEBUG_SHOOT THEN
            DRAWTEXT 10, 30, "DBG shoot: key=" & STR$(GKEYDOWN(49)) & " held=" & STR$(shoot_held) & " cd=" & STR$(fire_cooldown), 11, 0
            IF (frame MOD DEBUG_SHOOT_PRINT_INTERVAL) = 0 THEN
                PRINT "DBG: key="; GKEYDOWN(49); " held="; shoot_held; " cd="; fire_cooldown
            END IF
        END IF

        CALL UpdateStars()
        CALL UpdatePlayer(frame)
        CALL UpdateEnemies(frame)
    CALL UpdateSaucer(frame)
        CALL UpdateBullets()

        all_dead = 1
        FOR i = 1 TO 60
            IF enemy_alive(i) = 1 THEN
                all_dead = 0
            END IF
        NEXT i

        IF ships <= 0 AND p_death_timer <= 0 THEN
            game_state = STATE_GAMEOVER
            flash_timer = 0
            MUSIC PLAY 10, 1.0
        ELSEIF all_dead = 1 THEN
            game_state = STATE_WIN
            flash_timer = 0
            MUSIC PLAY 13, 1.0
        END IF

        frame = frame + 1

    ELSEIF game_state = STATE_GAMEOVER THEN
        DRAWTEXT 10, 10, score_text, 15, 0
        DRAWTEXT 280, 20, "STAGE 1", 15, 0
        CALL DrawShipsHUD()
        CALL UpdateStars()
        CALL UpdateEnemiesCelebration(flash_timer)

        flash_color = 9 + ((flash_timer / 10) MOD 6)
        DRAWTEXT 280, 200, "GAME OVER", flash_color, 0

        flash_timer = flash_timer + 1
        IF flash_timer > 900 THEN
            CALL ResetGameState()
            game_state = STATE_INTRO
            intro_timer = 0
            ' Clear any pending keypresses so it doesn't skip the intro
            DO WHILE GINKEY() > 0
            LOOP
        END IF

    ELSEIF game_state = STATE_WIN THEN
        DRAWTEXT 10, 10, score_text, 15, 0
        DRAWTEXT 280, 20, "STAGE 1", 15, 0
        CALL DrawShipsHUD()
        CALL UpdateStars()
        CALL UpdatePlayer(frame)
        CALL UpdateEnemies(frame)
        CALL UpdateSaucer(frame)
        CALL UpdateBullets()

        flash_color = 9 + ((flash_timer / 10) MOD 6)
        DRAWTEXT 260, 200, "PLAYER WINS!", flash_color, 0

        flash_timer = flash_timer + 1
        IF flash_timer > 180 THEN
            CALL ResetGameState()
            game_state = STATE_INTRO
            intro_timer = 0
            ' Clear any pending keypresses so it doesn't skip the intro
            DO WHILE GINKEY() > 0
            LOOP
        END IF
    END IF

    FLIP
    VSYNC
LOOP UNTIL quit_game = 1

SCREENSAVE "/tmp/galaga_demo.png"
PRINT "GALAGA DEMO COMPLETE: /tmp/galaga_demo.png"
SCREENCLOSE
END
