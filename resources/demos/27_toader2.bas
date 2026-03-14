' =========================================================================
' TOADER - Frogger-style demo
' =========================================================================

SCREEN 640, 480, 2
SCREENTITLE "Toader"

CONSTANT STATE_INTRO = 0
CONSTANT STATE_PLAYING = 1
CONSTANT STATE_WIN = 2
CONSTANT STATE_GAMEOVER = 3

CONSTANT TILE = 32
CONSTANT GOAL_COUNT = 5
CONSTANT CAR_COUNT = 12
CONSTANT LOG_COUNT = 10
CONSTANT FROG_SPRITE = 900

GLOBAL game_state AS INTEGER
GLOBAL score AS INTEGER
GLOBAL lives AS INTEGER
GLOBAL level AS INTEGER
GLOBAL frogs_home AS INTEGER
GLOBAL timer_frames AS INTEGER

GLOBAL frog_x AS DOUBLE
GLOBAL frog_y AS DOUBLE
GLOBAL frog_w AS DOUBLE
GLOBAL frog_h AS DOUBLE

DIM goal_filled(GOAL_COUNT) AS INTEGER
DIM goal_x(GOAL_COUNT) AS DOUBLE
DIM goal_y(GOAL_COUNT) AS DOUBLE
DIM goal_w(GOAL_COUNT) AS DOUBLE
DIM goal_h(GOAL_COUNT) AS DOUBLE

DIM car_x(CAR_COUNT) AS DOUBLE
DIM car_y(CAR_COUNT) AS DOUBLE
DIM car_dx(CAR_COUNT) AS DOUBLE
DIM car_w(CAR_COUNT) AS DOUBLE
DIM car_h(CAR_COUNT) AS DOUBLE

DIM log_x(LOG_COUNT) AS DOUBLE
DIM log_y(LOG_COUNT) AS DOUBLE
DIM log_dx(LOG_COUNT) AS DOUBLE
DIM log_w(LOG_COUNT) AS DOUBLE
DIM log_h(LOG_COUNT) AS DOUBLE

SUB InitArt()
    ' Frog (Def 0)
    SPRITE DEF 0, 24, 24
    SPRITE PALETTE 0, 1,  20,  20,  20
    SPRITE PALETTE 0, 2, 120, 240,  90
    SPRITE PALETTE 0, 3, 230, 255, 200
    SPRITE PALETTE 0, 4, 255, 255, 255
    SPRITE BEGIN 0
    GCLS 0
    RECT 4, 8, 16, 12, 2, 1
    CIRCLEF 8, 8, 3, 2
    CIRCLEF 16, 8, 3, 2
    PSET 8, 7, 4 : PSET 16, 7, 4
    GLINE 8, 18, 6, 22, 3
    GLINE 16, 18, 18, 22, 3
    SPRITE END

    ' Car (Def 1)
    SPRITE DEF 1, 36, 22
    SPRITE PALETTE 1, 1,  20,  20,  20
    SPRITE PALETTE 1, 2, 255, 120,  90
    SPRITE PALETTE 1, 3, 180, 240, 255
    SPRITE PALETTE 1, 4, 255, 230, 120
    SPRITE BEGIN 1
    GCLS 0
    RECT 2, 8, 32, 10, 2, 1
    RECT 8, 4, 18, 8, 2, 1
    RECT 10, 6, 14, 4, 3, 1
    CIRCLEF 8, 20, 2, 1 : CIRCLEF 28, 20, 2, 1
    PSET 34, 11, 4
    SPRITE END

    ' Log (Def 2)
    SPRITE DEF 2, 64, 22
    SPRITE PALETTE 2, 1,  50,  20,   0
    SPRITE PALETTE 2, 2, 130,  80,  30
    SPRITE PALETTE 2, 3, 170, 120,  60
    SPRITE BEGIN 2
    GCLS 0
    RECT 0, 4, 64, 14, 2, 1
    GLINE 2, 6, 62, 6, 3
    GLINE 2, 16, 62, 16, 1
    SPRITE END

    ' Home frog marker (Def 3)
    SPRITE DEF 3, 24, 24
    SPRITE PALETTE 3, 1,  20, 120,  20
    SPRITE PALETTE 3, 2, 200, 255, 180
    SPRITE BEGIN 3
    GCLS 0
    CIRCLEF 12, 12, 9, 1
    CIRCLEF 8, 10, 2, 2 : CIRCLEF 16, 10, 2, 2
    SPRITE END

    ' Life icon (Def 4)
    SPRITE DEF 4, 14, 14
    SPRITE PALETTE 4, 1, 110, 220, 90
    SPRITE BEGIN 4
    GCLS 0
    CIRCLEF 7, 7, 6, 1
    SPRITE END
END SUB

SUB InitSounds()
    SOUND VOLUME 1.0
    MUSIC VOLUME 1.0

    SOUND ZAP 1, 650, 0.40       ' hop
    SOUND ZAP 2, 200, 0.65       ' hit
    SOUND EXPLODE 3, 0.45, 0.70  ' drown/splat
    SOUND ZAP 4, 880, 0.55       ' home reached

    MUSIC LOAD 10, "T:ToaderWin\nM:4/4\nL:1/16\nV:0.7\nK:C\nQ:150\nC E G C6 G E C"
END SUB

SUB SetupGoals()
    SHARED goal_x, goal_y, goal_w, goal_h, goal_filled
    DIM i AS INTEGER
    goal_w() = 44
    goal_h() = 26
    goal_y() = 42
    goal_filled() = 0
    FOR i = 1 TO GOAL_COUNT
        goal_x(i) = 58 + (i - 1) * 116
        SPRITE HIDE 300 + i
    NEXT i
END SUB

SUB SetupTraffic()
    SHARED car_x, car_y, car_dx, car_w, car_h
    SHARED log_x, log_y, log_dx, log_w, log_h
    DIM i AS INTEGER

    ' Road lanes: y 256, 320, 384
    car_w() = 36
    car_h() = 22

    car_y(1)=256 : car_x(1)=20  : car_dx(1)= 2.6
    car_y(2)=256 : car_x(2)=220 : car_dx(2)= 2.6
    car_y(3)=256 : car_x(3)=420 : car_dx(3)= 2.6
    car_y(4)=256 : car_x(4)=620 : car_dx(4)= 2.6

    car_y(5)=320 : car_x(5)=80  : car_dx(5)=-3.2
    car_y(6)=320 : car_x(6)=250 : car_dx(6)=-3.2
    car_y(7)=320 : car_x(7)=420 : car_dx(7)=-3.2
    car_y(8)=320 : car_x(8)=590 : car_dx(8)=-3.2

    car_y(9)=384 : car_x(9)=40  : car_dx(9)= 2.1
    car_y(10)=384: car_x(10)=230: car_dx(10)= 2.1
    car_y(11)=384: car_x(11)=420: car_dx(11)= 2.1
    car_y(12)=384: car_x(12)=610: car_dx(12)= 2.1

    FOR i = 1 TO CAR_COUNT
        SPRITE 100 + i, 1, car_x(i), car_y(i)
        SPRITE SHOW 100 + i
    NEXT i

    ' River lanes: y 120, 152, 184 (frog must ride logs)
    log_w() = 64
    log_h() = 22

    log_y(1)=120 : log_x(1)=0   : log_dx(1)= 1.6
    log_y(2)=120 : log_x(2)=210 : log_dx(2)= 1.6
    log_y(3)=120 : log_x(3)=420 : log_dx(3)= 1.6

    log_y(4)=152 : log_x(4)=80  : log_dx(4)=-2.4
    log_y(5)=152 : log_x(5)=260 : log_dx(5)=-2.4
    log_y(6)=152 : log_x(6)=440 : log_dx(6)=-2.4
    log_y(7)=152 : log_x(7)=620 : log_dx(7)=-2.4

    log_y(8)=184 : log_x(8)=30  : log_dx(8)= 1.9
    log_y(9)=184 : log_x(9)=260 : log_dx(9)= 1.9
    log_y(10)=184: log_x(10)=490: log_dx(10)= 1.9

    FOR i = 1 TO LOG_COUNT
        SPRITE 200 + i, 2, log_x(i), log_y(i)
        SPRITE SHOW 200 + i
    NEXT i
END SUB

SUB ResetFrog()
    SHARED frog_x, frog_y, frog_w, frog_h, timer_frames
    frog_w = 24
    frog_h = 24
    frog_x = 320 - 12
    frog_y = 432
    timer_frames = 900
    SPRITE FROG_SPRITE, 0, frog_x, frog_y
    SPRITE SHOW FROG_SPRITE
END SUB

SUB ResetGame()
    SHARED score, lives, level, frogs_home, game_state
    score = 0
    lives = 3
    level = 1
    frogs_home = 0
    game_state = STATE_INTRO

    CALL SetupGoals()
    CALL SetupTraffic()
    CALL ResetFrog()
END SUB

FUNCTION AABB(ax AS DOUBLE, ay AS DOUBLE, aw AS DOUBLE, ah AS DOUBLE, bx AS DOUBLE, by AS DOUBLE, bw AS DOUBLE, bh AS DOUBLE)
    IF ax + aw <= bx THEN RETURN 0
    IF ax >= bx + bw THEN RETURN 0
    IF ay + ah <= by THEN RETURN 0
    IF ay >= by + bh THEN RETURN 0
    RETURN 1
END FUNCTION

SUB LoseLife(play_sfx AS INTEGER)
    SHARED lives, game_state
    lives = lives - 1
    IF play_sfx = 1 THEN SOUND PLAY 3, 0.85
    IF lives <= 0 THEN
        game_state = STATE_GAMEOVER
    ELSE
        CALL ResetFrog()
    END IF
END SUB

SUB UpdatePlayer()
    SHARED frog_x, frog_y
    DIM k AS INTEGER

    k = GINKEY()
    IF k = 123 THEN frog_x = frog_x - TILE
    IF k = 124 THEN frog_x = frog_x + TILE
    IF k = 126 THEN frog_y = frog_y - TILE
    IF k = 125 THEN frog_y = frog_y + TILE

    IF k = 123 OR k = 124 OR k = 125 OR k = 126 THEN
        SOUND PLAY 1, 0.6
    END IF

    IF frog_x < 0 THEN frog_x = 0
    IF frog_x > 640 - frog_w THEN frog_x = 640 - frog_w
    IF frog_y < 42 THEN frog_y = 42
    IF frog_y > 432 THEN frog_y = 432

    SPRITE POS FROG_SPRITE, frog_x, frog_y
END SUB

SUB UpdateCarsAndLogs()
    SHARED car_x, car_y, car_dx
    SHARED log_x, log_y, log_dx
    DIM i AS INTEGER

    FOR i = 1 TO CAR_COUNT
        car_x(i) = car_x(i) + car_dx(i)
        IF car_dx(i) > 0 AND car_x(i) > 680 THEN car_x(i) = -60
        IF car_dx(i) < 0 AND car_x(i) < -60 THEN car_x(i) = 680
        SPRITE POS 100 + i, car_x(i), car_y(i)
    NEXT i

    FOR i = 1 TO LOG_COUNT
        log_x(i) = log_x(i) + log_dx(i)
        IF log_dx(i) > 0 AND log_x(i) > 700 THEN log_x(i) = -90
        IF log_dx(i) < 0 AND log_x(i) < -90 THEN log_x(i) = 700
        SPRITE POS 200 + i, log_x(i), log_y(i)
    NEXT i
END SUB

SUB CheckGoalReached()
    SHARED frog_x, frog_y, frog_w, frog_h
    SHARED goal_x, goal_y, goal_w, goal_h, goal_filled
    SHARED frogs_home, score, game_state
    DIM i AS INTEGER

    IF frog_y > 72 THEN EXIT SUB

    FOR i = 1 TO GOAL_COUNT
        IF AABB(frog_x, frog_y, frog_w, frog_h, goal_x(i), goal_y(i), goal_w(i), goal_h(i)) THEN
            IF goal_filled(i) = 0 THEN
                goal_filled(i) = 1
                frogs_home = frogs_home + 1
                score = score + 100
                SOUND PLAY 4, 0.8

                SPRITE 300 + i, 3, goal_x(i) + 10, goal_y(i) + 1
                SPRITE SHOW 300 + i

                IF frogs_home >= GOAL_COUNT THEN
                    game_state = STATE_WIN
                    MUSIC PLAY 10, 1.0
                ELSE
                    CALL ResetFrog()
                END IF
            ELSE
                CALL LoseLife(1)
            END IF
            EXIT SUB
        END IF
    NEXT i

    ' Reached top water but missed any goal slot
    CALL LoseLife(1)
END SUB

SUB CheckCollisions()
    SHARED frog_x, frog_y, frog_w, frog_h
    SHARED car_x, car_y, car_w, car_h
    SHARED log_x, log_y, log_w, log_h, log_dx
    SHARED score
    DIM i AS INTEGER
    DIM on_log AS INTEGER

    ' Road zone
    IF frog_y >= 256 AND frog_y <= 405 THEN
        FOR i = 1 TO CAR_COUNT
            IF AABB(frog_x, frog_y, frog_w, frog_h, car_x(i), car_y(i), car_w(i), car_h(i)) THEN
                SOUND PLAY 2, 0.8
                CALL LoseLife(1)
                EXIT SUB
            END IF
        NEXT i
    END IF

    ' River zone
    IF frog_y >= 112 AND frog_y <= 207 THEN
        on_log = 0
        FOR i = 1 TO LOG_COUNT
            IF AABB(frog_x, frog_y, frog_w, frog_h, log_x(i), log_y(i), log_w(i), log_h(i)) THEN
                on_log = 1
                frog_x = frog_x + log_dx(i)
                IF frog_x < -20 OR frog_x > 640 - frog_w + 20 THEN
                    CALL LoseLife(1)
                    EXIT SUB
                END IF
                SPRITE POS FROG_SPRITE, frog_x, frog_y
                EXIT FOR
            END IF
        NEXT i

        IF on_log = 0 THEN
            CALL LoseLife(1)
            EXIT SUB
        END IF
    END IF

    ' Goal row
    IF frog_y <= 72 THEN
        CALL CheckGoalReached()
        EXIT SUB
    END IF

    ' Survival points for advancing upward
    IF frog_y < 432 THEN score = score + 1
END SUB

SUB DrawBackground()
    ' HUD bar
    RECT 0, 0, 640, 32, 1, 1

    ' Goal bank strip
    RECT 0, 32, 640, 48, 2, 1

    ' Safe strip
    RECT 0, 80, 640, 48, 10, 1

    ' Water
    RECT 0, 112, 640, 96, 9, 1

    ' Safe strip (wider bank so no moving logs appear in it)
    RECT 0, 208, 640, 48, 10, 1

    ' Road
    RECT 0, 256, 640, 160, 8, 1

    ' Start strip
    RECT 0, 416, 640, 64, 10, 1

    ' Lane markers on road
    GLINE 0, 288, 640, 288, 7
    GLINE 0, 352, 640, 352, 7

    ' Draw empty goal pockets
    DIM i AS INTEGER
    FOR i = 1 TO GOAL_COUNT
        RECT goal_x(i), goal_y(i), goal_w(i), goal_h(i), 6, 0
    NEXT i
END SUB

SUB DrawHUD()
    SHARED score, lives, level, timer_frames, game_state, frogs_home
    DIM i AS INTEGER

    DRAWTEXT 8, 8, "TOADER", 15, 1
    DRAWTEXT 130, 8, "SCORE: " & STR$(score), 15, 1
    DRAWTEXT 300, 8, "LIVES:", 15, 1
    DRAWTEXT 430, 8, "HOME: " & STR$(frogs_home) & "/" & STR$(GOAL_COUNT), 15, 1

    FOR i = 1 TO lives
        SPRITE 400 + i, 4, 360 + (i - 1) * 18, 8
        SPRITE SHOW 400 + i
    NEXT i
    FOR i = lives + 1 TO 5
        SPRITE HIDE 400 + i
    NEXT i

    IF game_state = STATE_PLAYING THEN
        DRAWTEXT 545, 8, "TIME: " & STR$(INT(timer_frames / 30)), 14, 1
    ELSEIF game_state = STATE_INTRO THEN
        DRAWTEXT 160, 220, "ARROWS MOVE THE FROG TO THE TOP GOALS", 11, 0
        DRAWTEXT 180, 248, "AVOID CARS, RIDE LOGS, FILL ALL 5 HOMES", 10, 0
        DRAWTEXT 238, 280, "PRESS ANY KEY TO START", 14, 0
    ELSEIF game_state = STATE_GAMEOVER THEN
        DRAWTEXT 250, 220, "GAME OVER", 12, 0
        DRAWTEXT 215, 248, "PRESS ANY KEY TO RESTART", 14, 0
    ELSEIF game_state = STATE_WIN THEN
        DRAWTEXT 268, 220, "YOU WIN!", 10, 0
        DRAWTEXT 215, 248, "PRESS ANY KEY TO PLAY AGAIN", 14, 0
    END IF
END SUB

' -------------------------------------------------------------------------
' Boot
' -------------------------------------------------------------------------
CALL InitArt()
CALL InitSounds()
CALL ResetGame()

DIM quit_game AS INTEGER
DIM key_pressed AS INTEGER
quit_game = 0

DO
    GCLS 0

    IF GKEYDOWN(53) THEN
        quit_game = 1
        EXIT DO
    END IF

    CALL DrawBackground()

    IF game_state = STATE_INTRO THEN
        CALL UpdateCarsAndLogs()
        CALL DrawHUD()
        key_pressed = GINKEY()
        IF key_pressed > 0 AND key_pressed <> 53 THEN
            game_state = STATE_PLAYING
            CALL ResetFrog()
        END IF

    ELSEIF game_state = STATE_PLAYING THEN
        timer_frames = timer_frames - 1
        IF timer_frames <= 0 THEN CALL LoseLife(1)

        CALL UpdateCarsAndLogs()
        CALL UpdatePlayer()
        CALL CheckCollisions()
        CALL DrawHUD()

    ELSEIF game_state = STATE_GAMEOVER THEN
        CALL UpdateCarsAndLogs()
        CALL DrawHUD()
        key_pressed = GINKEY()
        IF key_pressed > 0 AND key_pressed <> 53 THEN
            CALL ResetGame()
        END IF

    ELSEIF game_state = STATE_WIN THEN
        CALL UpdateCarsAndLogs()
        CALL DrawHUD()
        key_pressed = GINKEY()
        IF key_pressed > 0 AND key_pressed <> 53 THEN
            CALL ResetGame()
        END IF
    END IF

    FLIP
    VSYNC
LOOP UNTIL quit_game = 1

SCREENSAVE "/tmp/toader_demo.png"
PRINT "TOADER DEMO COMPLETE: /tmp/toader_demo.png"
