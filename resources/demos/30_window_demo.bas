REM Simple non-modal window demo (declarative controls)
WINDOW DEFINE 1, "Hello Window", 100, 100, 320, 200
    WINDOW BUTTON 10, "Click Me", 20, 20, 120, 28
    WINDOW LABEL 11, "Status: waiting", 20, 60, 200, 24
END WINDOW

WINDOW SHOW 1

running = 1

DO WHILE running
    status = WINDOW EVENT(win, ctl)
    IF status = 1 THEN
        IF ctl = 0 THEN
            running = 0   ' window closed
        ELSEIF ctl = 10 THEN
            WINDOW LABEL 1, 11, "Status: clicked!", 20, 60, 200, 24
        END IF
    END IF
    SLEEP 0.05
LOOP
WINDOW SHUTDOWN
