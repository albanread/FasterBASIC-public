REM Two windows demo

APPNAME "Two Windows Demo"

WINDOW DEFINE 1, "Left Window", 80, 120, 300, 200
    WINDOW LABEL 11, "Left status", 20, 20, 200, 24
    WINDOW BUTTON 10, "Left Click", 20, 60, 120, 28
END WINDOW
WINDOW DEFINE 2, "Right Window", 420, 120, 300, 200
    WINDOW LABEL 21, "Right status", 20, 20, 200, 24
    WINDOW BUTTON 20, "Right Click", 20, 60, 120, 28
END WINDOW
WINDOW SHOW 1
WINDOW SHOW 2
running = 1
left_open = 1
right_open = 1
DO WHILE running
    status = WINDOW EVENT(win, ctl)
    IF status = 1 THEN
        IF win = 1 THEN
            IF ctl = 0 THEN
                left_open = 0
            ELSEIF ctl = 10 THEN
                WINDOW LABEL 1, 11, "Left clicked", 20, 20, 200, 24
            END IF
        ELSEIF win = 2 THEN
            IF ctl = 0 THEN
                right_open = 0
            ELSEIF ctl = 20 THEN
                WINDOW LABEL 2, 21, "Right clicked", 20, 20, 200, 24
            END IF
        END IF
    END IF
    IF left_open = 0 AND right_open = 0 THEN
        running = 0
    END IF
    SLEEP 0.05
LOOP
WINDOW SHUTDOWN
