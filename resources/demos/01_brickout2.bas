' =========================================================================
' BrickOut 2 Demo (Sprite + Sound + Powerups)
' =========================================================================

APPNAME "BrickOut 2 Demo"
SCREEN 640, 480, 2
SCREENTITLE "BrickOut 2 Demo"

CONSTANT STATE_INTRO = 0
CONSTANT STATE_PLAYING = 1
CONSTANT STATE_WIN = 2
CONSTANT STATE_GAMEOVER = 3

CONSTANT BRICK_COLS = 10
CONSTANT BRICK_ROWS = 6
CONSTANT BRICK_MAX = 60
CONSTANT DROP_MAX = 8

GLOBAL paddle_x AS DOUBLE
GLOBAL paddle_y AS DOUBLE
GLOBAL paddle_w AS DOUBLE
GLOBAL paddle_h AS DOUBLE
GLOBAL paddle_speed AS DOUBLE
GLOBAL paddle_expand_timer AS INTEGER

GLOBAL ball_x AS DOUBLE
GLOBAL ball_y AS DOUBLE
GLOBAL ball_dx AS DOUBLE
GLOBAL ball_dy AS DOUBLE
GLOBAL ball_size AS DOUBLE
GLOBAL ball_stuck AS INTEGER

GLOBAL score AS INTEGER
GLOBAL lives AS INTEGER
GLOBAL level AS INTEGER
GLOBAL bricks_left AS INTEGER
GLOBAL game_state AS INTEGER
GLOBAL combo AS INTEGER
GLOBAL max_combo AS INTEGER

DIM brick_alive(BRICK_MAX) AS INTEGER
DIM brick_hp(BRICK_MAX) AS INTEGER
DIM brick_kind(BRICK_MAX) AS INTEGER ' 0 = normal, 1 = steel (unbreakable)
DIM brick_x(BRICK_MAX) AS DOUBLE
DIM brick_y(BRICK_MAX) AS DOUBLE
DIM brick_w(BRICK_MAX) AS DOUBLE
DIM brick_h(BRICK_MAX) AS DOUBLE

DIM drop_active(DROP_MAX) AS INTEGER
DIM drop_type(DROP_MAX) AS INTEGER ' 1 = wide paddle, 2 = extra life
DIM drop_x(DROP_MAX) AS DOUBLE
DIM drop_y(DROP_MAX) AS DOUBLE
DIM drop_dy(DROP_MAX) AS DOUBLE

SUB InitArt()
  ' Paddle (Def 0)
  SPRITE DEF 0, 72, 12
  SPRITE PALETTE 0, 1, 20, 20, 20
  SPRITE PALETTE 0, 2, 160, 220, 255
  SPRITE PALETTE 0, 3, 255, 255, 255
  SPRITE BEGIN 0
  GCLS 0
  RECT 0, 2, 72, 8, 2, 1
  GLINE 0, 1, 71, 1, 3
  GLINE 0, 10, 71, 10, 1
  SPRITE END

  ' Ball (Def 1)
  SPRITE DEF 1, 12, 12
  SPRITE PALETTE 1, 1, 255, 255, 255
  SPRITE PALETTE 1, 2, 255, 230, 120
  SPRITE BEGIN 1
  GCLS 0
  CIRCLEF 6, 6, 5, 1
  PSET 4, 4, 2 : PSET 5, 4, 2
  SPRITE END

  ' Brick weak (Def 2)
  SPRITE DEF 2, 56, 18
  SPRITE PALETTE 2, 1, 10, 10, 10
  SPRITE PALETTE 2, 2, 100, 180, 255
  SPRITE PALETTE 2, 3, 220, 245, 255
  SPRITE BEGIN 2
  GCLS 0
  RECT 0, 0, 56, 18, 2, 1
  GLINE 0, 0, 55, 0, 3
  GLINE 0, 17, 55, 17, 1
  SPRITE END

  ' Brick medium (Def 3)
  SPRITE DEF 3, 56, 18
  SPRITE PALETTE 3, 1, 10, 10, 10
  SPRITE PALETTE 3, 2, 255, 165, 80
  SPRITE PALETTE 3, 3, 255, 220, 150
  SPRITE BEGIN 3
  GCLS 0
  RECT 0, 0, 56, 18, 2, 1
  GLINE 0, 0, 55, 0, 3
  GLINE 0, 17, 55, 17, 1
  SPRITE END

  ' Brick strong (Def 4)
  SPRITE DEF 4, 56, 18
  SPRITE PALETTE 4, 1, 10, 10, 10
  SPRITE PALETTE 4, 2, 230, 80, 80
  SPRITE PALETTE 4, 3, 255, 170, 170
  SPRITE BEGIN 4
  GCLS 0
  RECT 0, 0, 56, 18, 2, 1
  GLINE 0, 0, 55, 0, 3
  GLINE 0, 17, 55, 17, 1
  SPRITE END

  ' Brick steel (Def 5)
  SPRITE DEF 5, 56, 18
  SPRITE PALETTE 5, 1, 10, 10, 10
  SPRITE PALETTE 5, 2, 130, 130, 150
  SPRITE PALETTE 5, 3, 220, 220, 240
  SPRITE BEGIN 5
  GCLS 0
  RECT 0, 0, 56, 18, 2, 1
  GLINE 0, 0, 55, 0, 3
  GLINE 0, 17, 55, 17, 1
  GLINE 8, 9, 47, 9, 1
  SPRITE END

  ' Drop: wide paddle (Def 6)
  SPRITE DEF 6, 14, 14
  SPRITE PALETTE 6, 1, 255, 220, 80
  SPRITE PALETTE 6, 2, 90, 60, 20
  SPRITE BEGIN 6
  GCLS 0
  RECT 1, 1, 12, 12, 1, 1
  GLINE 1, 1, 12, 1, 2
  GLINE 1, 12, 12, 12, 2
  SPRITE END

  ' Drop: extra life (Def 7)
  SPRITE DEF 7, 14, 14
  SPRITE PALETTE 7, 1, 120, 255, 140
  SPRITE PALETTE 7, 2, 20, 70, 20
  SPRITE BEGIN 7
  GCLS 0
  CIRCLEF 7, 7, 6, 1
  PSET 7, 4, 2 : GLINE 7, 4, 7, 10, 2 : GLINE 4, 7, 10, 7, 2
  SPRITE END
END SUB

SUB InitSounds()
  SOUND VOLUME 1.0
  MUSIC VOLUME 1.0

  ' Ball / wall taps
  SOUND ZAP 1, 420, 0.45
  ' Paddle hit
  SOUND SHOOT 2, 0.45, 0.60
  ' Brick hit / break
  SOUND ZAP 3, 240, 0.65
  SOUND EXPLODE 4, 0.35, 0.45
  ' Lose life
  SOUND BIGEXPLODE 5, 0.55, 0.70
  ' Powerup collect
  SOUND ZAP 6, 640, 0.55
  ' Steel ping
  SOUND ZAP 7, 120, 0.42

  ' Win sting
  MUSIC LOAD 10, "T:Win\nM:4/4\nL:1/16\nV:0.7\nK:C\nQ:140\nC E G C6 E6 G6"
END SUB

SUB ClearDrops()
  SHARED drop_active
  DIM i AS INTEGER
  drop_active() = 0
  FOR i = 1 TO DROP_MAX
    SPRITE HIDE 300 + i
  NEXT i
END SUB

SUB SetPaddleSize(new_width AS DOUBLE)
  SHARED paddle_w, paddle_x
  DIM sx AS DOUBLE

  paddle_w = new_width
  sx = paddle_w / 72.0
  SPRITE SCALE 1, sx, 1.0

  IF paddle_x < 0 THEN paddle_x = 0
  IF paddle_x > 640 - paddle_w THEN paddle_x = 640 - paddle_w
END SUB

SUB BrickToSprite(idx AS INTEGER)
  SHARED brick_hp, brick_kind, brick_x, brick_y
  DIM def_id AS INTEGER

  IF brick_kind(idx) = 1 THEN
    def_id = 5
  ELSE
    def_id = 2
    IF brick_hp(idx) = 2 THEN def_id = 3
    IF brick_hp(idx) >= 3 THEN def_id = 4
  END IF

  SPRITE 100 + idx, def_id, brick_x(idx), brick_y(idx)
  SPRITE SHOW 100 + idx
END SUB

SUB BuildLevel()
  SHARED brick_alive, brick_hp, brick_kind, brick_x, brick_y, brick_w, brick_h, bricks_left, level
  DIM idx AS INTEGER
  DIM c AS INTEGER
  DIM r AS INTEGER
  DIM hp AS INTEGER

  brick_alive() = 0
  brick_hp() = 0
  brick_kind() = 0
  bricks_left = 0

  idx = 0
  FOR r = 0 TO BRICK_ROWS - 1
    FOR c = 0 TO BRICK_COLS - 1
      idx = idx + 1

      brick_alive(idx) = 1
      brick_x(idx) = 24 + c * 60
      brick_y(idx) = 70 + r * 24
      brick_w(idx) = 56
      brick_h(idx) = 18

      ' Steel bricks appear from level 2 onward in a fixed pattern.
      IF level >= 2 AND ((r + c + level) MOD 5 = 0) THEN
        brick_kind(idx) = 1
        brick_hp(idx) = 99
      ELSE
        hp = 1 + INT(r / 2) + INT((level - 1) / 2)
        IF hp > 4 THEN hp = 4
        brick_hp(idx) = hp
        bricks_left = bricks_left + 1
      END IF

      CALL BrickToSprite(idx)
    NEXT c
  NEXT r
END SUB

SUB SpawnDrop(px AS DOUBLE, py AS DOUBLE)
  SHARED drop_active, drop_type, drop_x, drop_y, drop_dy
  DIM i AS INTEGER
  DIM kind AS INTEGER

  ' ~25% chance to spawn a drop
  IF RND() > 0.25 THEN EXIT SUB

  kind = 1
  IF RND() < 0.35 THEN kind = 2

  FOR i = 1 TO DROP_MAX
    IF drop_active(i) = 0 THEN
      drop_active(i) = 1
      drop_type(i) = kind
      drop_x(i) = px + 21
      drop_y(i) = py + 2
      drop_dy(i) = 2.3

      IF kind = 1 THEN
        SPRITE 300 + i, 6, drop_x(i), drop_y(i)
      ELSE
        SPRITE 300 + i, 7, drop_x(i), drop_y(i)
      END IF
      SPRITE SHOW 300 + i
      EXIT FOR
    END IF
  NEXT i
END SUB

SUB ApplyDrop(kind AS INTEGER)
  SHARED lives, paddle_expand_timer

  IF kind = 1 THEN
    CALL SetPaddleSize(104)
    paddle_expand_timer = 900
    SOUND PLAY 6, 0.8
  ELSEIF kind = 2 THEN
    lives = lives + 1
    IF lives > 6 THEN lives = 6
    SOUND PLAY 6, 0.8
  END IF
END SUB

SUB UpdateDrops()
  SHARED drop_active, drop_type, drop_x, drop_y, drop_dy
  SHARED paddle_x, paddle_y, paddle_w, paddle_h
  DIM i AS INTEGER

  FOR i = 1 TO DROP_MAX
    IF drop_active(i) = 1 THEN
      drop_y(i) = drop_y(i) + drop_dy(i)
      SPRITE POS 300 + i, drop_x(i), drop_y(i)

      IF drop_y(i) > 490 THEN
        drop_active(i) = 0
        SPRITE HIDE 300 + i
      ELSEIF drop_x(i) + 14 > paddle_x AND drop_x(i) < paddle_x + paddle_w THEN
        IF drop_y(i) + 14 > paddle_y AND drop_y(i) < paddle_y + paddle_h THEN
          drop_active(i) = 0
          SPRITE HIDE 300 + i
          CALL ApplyDrop(drop_type(i))
        END IF
      END IF
    END IF
  NEXT i
END SUB

SUB ResetBall()
  SHARED paddle_x, paddle_y, paddle_w
  SHARED ball_x, ball_y, ball_dx, ball_dy, ball_size, ball_stuck

  ball_stuck = 1
  ball_size = 12
  ball_x = paddle_x + (paddle_w / 2) - (ball_size / 2)
  ball_y = paddle_y - ball_size - 2
  ball_dx = 2.4 + (level - 1) * 0.25
  ball_dy = -(3.6 + (level - 1) * 0.2)

  SPRITE 2, 1, ball_x, ball_y
  SPRITE SHOW 2
END SUB

SUB ResetGame()
  SHARED paddle_x, paddle_y, paddle_h, paddle_speed, paddle_expand_timer
  SHARED score, lives, level, game_state, combo, max_combo

  paddle_h = 12
  paddle_x = (640 - 72) / 2
  paddle_y = 440
  paddle_speed = 6.0
  paddle_expand_timer = 0

  score = 0
  lives = 3
  level = 1
  combo = 0
  max_combo = 0
  game_state = STATE_INTRO

  SPRITE 1, 0, paddle_x, paddle_y
  CALL SetPaddleSize(72)
  SPRITE SHOW 1

  CALL BuildLevel()
  CALL ClearDrops()
  CALL ResetBall()
END SUB

SUB StartNextRound()
  SHARED level, game_state, combo
  level = level + 1
  combo = 0
  CALL BuildLevel()
  CALL ClearDrops()
  CALL ResetBall()
  game_state = STATE_PLAYING
END SUB

SUB UpdatePaddle()
  SHARED paddle_x, paddle_y, paddle_w, paddle_speed
  SHARED paddle_expand_timer

  IF GKEYDOWN(123) THEN paddle_x = paddle_x - paddle_speed
  IF GKEYDOWN(124) THEN paddle_x = paddle_x + paddle_speed

  IF paddle_x < 0 THEN paddle_x = 0
  IF paddle_x > 640 - paddle_w THEN paddle_x = 640 - paddle_w

  IF paddle_expand_timer > 0 THEN
    paddle_expand_timer = paddle_expand_timer - 1
    IF paddle_expand_timer = 0 THEN
      CALL SetPaddleSize(72)
    END IF
  END IF

  SPRITE POS 1, paddle_x, paddle_y
END SUB

SUB UpdateBall()
  SHARED paddle_x, paddle_y, paddle_w, paddle_h
  SHARED ball_x, ball_y, ball_dx, ball_dy, ball_size, ball_stuck
  SHARED brick_alive, brick_hp, brick_kind, brick_x, brick_y, brick_w, brick_h, bricks_left
  SHARED score, lives, level, game_state, combo, max_combo, paddle_expand_timer

  DIM prev_x AS DOUBLE
  DIM prev_y AS DOUBLE
  DIM i AS INTEGER
  DIM key_pressed AS INTEGER
  DIM hit_x AS DOUBLE
  DIM paddle_center AS DOUBLE
  DIM ball_center AS DOUBLE
  DIM points AS INTEGER

  ' Ready-to-launch state
  IF ball_stuck = 1 THEN
    ball_x = paddle_x + (paddle_w / 2) - (ball_size / 2)
    ball_y = paddle_y - ball_size - 2
    SPRITE POS 2, ball_x, ball_y

    key_pressed = GINKEY()
    IF key_pressed = 49 THEN
      ball_stuck = 0
    END IF
    EXIT SUB
  END IF

  prev_x = ball_x
  prev_y = ball_y

  ball_x = ball_x + ball_dx
  ball_y = ball_y + ball_dy

  ' Walls
  IF ball_x <= 0 THEN
    ball_x = 0
    ball_dx = ABS(ball_dx)
    IF NOT SOUNDPLAYING(1) THEN SOUND PLAY 1, 0.8
  ELSEIF ball_x >= 640 - ball_size THEN
    ball_x = 640 - ball_size
    ball_dx = -ABS(ball_dx)
    IF NOT SOUNDPLAYING(1) THEN SOUND PLAY 1, 0.8
  END IF

  IF ball_y <= 32 THEN
    ball_y = 32
    ball_dy = ABS(ball_dy)
    IF NOT SOUNDPLAYING(1) THEN SOUND PLAY 1, 0.8
  END IF

  ' Missed ball
  IF ball_y > 480 THEN
    lives = lives - 1
    combo = 0
    SOUND PLAY 5, 0.9
    IF lives <= 0 THEN
      game_state = STATE_GAMEOVER
      EXIT SUB
    END IF
    CALL SetPaddleSize(72)
    paddle_expand_timer = 0
    CALL ClearDrops()
    CALL ResetBall()
    EXIT SUB
  END IF

  ' Paddle collision
  IF ball_dy > 0 THEN
    IF ball_x + ball_size > paddle_x AND ball_x < paddle_x + paddle_w THEN
      IF ball_y + ball_size >= paddle_y AND ball_y <= paddle_y + paddle_h THEN
        ball_y = paddle_y - ball_size - 1
        paddle_center = paddle_x + (paddle_w / 2)
        ball_center = ball_x + (ball_size / 2)
        hit_x = (ball_center - paddle_center) / (paddle_w / 2)
        ball_dx = hit_x * 4.8
        ball_dy = -ABS(ball_dy)
        combo = 0
        SOUND PLAY 2, 0.8
      END IF
    END IF
  END IF

  ' Brick collisions (only one brick per frame)
  FOR i = 1 TO BRICK_MAX
    IF brick_alive(i) = 1 THEN
      IF ball_x + ball_size > brick_x(i) AND ball_x < brick_x(i) + brick_w(i) THEN
        IF ball_y + ball_size > brick_y(i) AND ball_y < brick_y(i) + brick_h(i) THEN
          ' Bounce direction from previous position
          IF prev_x + ball_size <= brick_x(i) OR prev_x >= brick_x(i) + brick_w(i) THEN
            ball_dx = -ball_dx
          ELSE
            ball_dy = -ball_dy
          END IF

          IF brick_kind(i) = 1 THEN
            SOUND PLAY 7, 0.75
          ELSE
            brick_hp(i) = brick_hp(i) - 1
            score = score + 10 * level
            SOUND PLAY 3, 0.75

            IF brick_hp(i) <= 0 THEN
              brick_alive(i) = 0
              bricks_left = bricks_left - 1
              combo = combo + 1
              IF combo > max_combo THEN max_combo = combo
              points = (20 * level) + (combo * 2)
              score = score + points
              SPRITE HIDE 100 + i
              SOUND PLAY 4, 0.7
              CALL SpawnDrop(brick_x(i), brick_y(i))
            ELSE
              CALL BrickToSprite(i)
            END IF
          END IF

          EXIT FOR
        END IF
      END IF
    END IF
  NEXT i

  SPRITE POS 2, ball_x, ball_y
END SUB

SUB DrawHUD()
  SHARED score, lives, level, game_state, bricks_left, combo, max_combo, paddle_expand_timer

  RECT 0, 0, 640, 30, 1, 1
  DRAWTEXT 10, 8, "BRICKOUT 2", 15, 1
  DRAWTEXT 145, 8, "SCORE: " & STR$(score), 15, 1
  DRAWTEXT 300, 8, "LIVES: " & STR$(lives), 15, 1
  DRAWTEXT 390, 8, "LV: " & STR$(level), 15, 1
  DRAWTEXT 450, 8, "LEFT: " & STR$(bricks_left), 15, 1
  DRAWTEXT 545, 8, "COMBO: " & STR$(combo), 15, 1

  IF paddle_expand_timer > 0 AND game_state = STATE_PLAYING THEN
    DRAWTEXT 12, 40, "WIDE PADDLE", 14, 0
  END IF

  IF game_state = STATE_INTRO THEN
    DRAWTEXT 142, 200, "LEFT/RIGHT MOVE  -  SPACE LAUNCH  -  ESC QUIT", 11, 0
    DRAWTEXT 158, 224, "FEATURES: STEEL BRICKS, COMBO BONUS, POWERUPS", 10, 0
    DRAWTEXT 205, 252, "YELLOW = WIDE PADDLE, GREEN = EXTRA LIFE", 14, 0
    DRAWTEXT 250, 286, "PRESS ANY KEY TO START", 14, 0
  ELSEIF game_state = STATE_GAMEOVER THEN
    DRAWTEXT 250, 220, "GAME OVER", 12, 0
    DRAWTEXT 218, 248, "PRESS ANY KEY TO RESTART", 14, 0
  ELSEIF game_state = STATE_WIN THEN
    DRAWTEXT 242, 220, "ROUND CLEAR!", 10, 0
    DRAWTEXT 218, 248, "PRESS ANY KEY FOR NEXT ROUND", 14, 0
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

  IF game_state = STATE_INTRO THEN
    CALL DrawHUD()
    CALL UpdatePaddle()
    CALL ResetBall()
    key_pressed = GINKEY()
    IF key_pressed > 0 AND key_pressed <> 53 THEN
      game_state = STATE_PLAYING
    END IF

  ELSEIF game_state = STATE_PLAYING THEN
    CALL UpdatePaddle()
    CALL UpdateBall()
    CALL UpdateDrops()
    CALL DrawHUD()

    IF bricks_left <= 0 THEN
      game_state = STATE_WIN
      combo = 0
      MUSIC PLAY 10, 1.0
    END IF

  ELSEIF game_state = STATE_GAMEOVER THEN
    CALL DrawHUD()
    key_pressed = GINKEY()
    IF key_pressed > 0 AND key_pressed <> 53 THEN
      CALL ResetGame()
    END IF

  ELSEIF game_state = STATE_WIN THEN
    CALL DrawHUD()
    key_pressed = GINKEY()
    IF key_pressed > 0 AND key_pressed <> 53 THEN
      CALL StartNextRound()
    END IF
  END IF

  FLIP
  VSYNC
LOOP UNTIL quit_game = 1

SCREENSAVE "/tmp/brickout2_demo.png"
PRINT "BRICKOUT 2 DEMO COMPLETE: /tmp/brickout2_demo.png"
