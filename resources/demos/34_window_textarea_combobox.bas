' Demo: TEXTAREA and COMBOBOX controls
' Matches the event style of the other window demos (numeric win/ctl IDs).

APPNAME "Editor Demo"

WINDOW DEFINE 1, "Editor Demo", 50, 50, 500, 400
    WINDOW LABEL    1, "Notes:", 10, 10, 80, 24
    WINDOW TEXTAREA 2, "", 10, 40, 460, 200
    WINDOW LABEL    3, "Font:", 10, 260, 80, 24
    WINDOW COMBOBOX 4, "Arial|Helvetica|Times New Roman|Courier|Georgia", 90, 256, 200, 26
    WINDOW LABEL    5, "Event:", 10, 310, 80, 24
    WINDOW LABEL    6, "(none)", 90, 310, 380, 24
    WINDOW BUTTON   7, "Clear", 10, 350, 80, 30
END WINDOW

WINDOW SHOW 1

running = 1

DO WHILE running
    SLEEP 0.016

    status = WINDOW EVENT(win, ctl)
    IF status = 1 THEN
        IF win = 1 THEN
            SELECT CASE ctl
                CASE 0
                    ' Window closed
                    running = 0

                CASE 2
                    ' Textarea changed — show character count
                    t$ = WINDOW TEXT$(1, 2)
                    WINDOW SET TEXT 1, 6, "Textarea: " + STR$(LEN(t$)) + " chars"

                CASE 4
                    ' Combobox selection changed — show selected index
                    sel = WINDOW VALUE(1, 4)
                    WINDOW SET TEXT 1, 6, "Combobox index: " + STR$(sel)

                CASE 7
                    ' Clear button clicked
                    WINDOW SET TEXT 1, 2, ""
                    WINDOW SET TEXT 1, 6, "Cleared"
            END SELECT
        END IF
    END IF
LOOP

WINDOW SHUTDOWN
