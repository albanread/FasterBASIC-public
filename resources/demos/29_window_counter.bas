REM Window counter demo
WINDOW DEFINE 1, "Counter", 120, 120, 320, 200
    WINDOW LABEL 11, "Count: 0", 20, 20, 200, 24
    WINDOW BUTTON 10, "Increment", 20, 60, 120, 28
    WINDOW BUTTON 12, "Reset", 160, 60, 80, 28
END WINDOW
WINDOW SHOW 1
count = 0
running = 1
DO WHILE running
    status = WINDOW EVENT(win, ctl)
    IF status = 1 THEN
        IF ctl = 0 THEN
            running = 0
        ELSEIF ctl = 10 THEN
            count = count + 1
            WINDOW LABEL 1, 11, "Count: " + STR$(count), 20, 20, 200, 24
        ELSEIF ctl = 12 THEN
            count = 0
            WINDOW LABEL 1, 11, "Count: 0", 20, 20, 200, 24
        END IF
    END IF
    SLEEP 0.05
LOOP
WINDOW SHUTDOWN
