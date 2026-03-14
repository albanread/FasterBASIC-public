REM Demo: TOOLBAR and STATUSBAR controls with multi-segment SET TEXT

WINDOW DEFINE 1, "Toolbar Demo", 80, 80, 640, 480
WINDOW LABEL 2, "Click toolbar buttons to update the status bar.", 20, 60, 480, 24
WINDOW TOOLBAR 10, "New|Open|Save|Quit", 20, 20, 320, 28
WINDOW STATUSBAR 20, "Ready||", 20, 270, 480, 24
END WINDOW

WINDOW SHOW 1
running = 1

' Seed the three status segments (left, middle, right)
WINDOW SET TEXT 1, 20, "Ready", "Toolbar demo", ""

do_count = 0

DO WHILE running
  SLEEP 0.016

  status = WINDOW EVENT(win, ctl)
  IF status = 1 THEN
    IF win = 1 THEN
      SELECT CASE ctl
      CASE 0
        ' Window closed
        running = 0

      CASE 10
        ' "New"
        do_count = do_count + 1
        WINDOW SET TEXT 1, 20, "New file created (#" + STR$(do_count) + ")", "Toolbar demo", ""

      CASE 11
        ' "Open"
        WINDOW SET TEXT 1, 20, "Open clicked", "Toolbar demo", ""

      CASE 12
        ' "Save"
        WINDOW SET TEXT 1, 20, "Saving...", "Toolbar demo", "Done"

      CASE 13
        ' "Quit"
        running = 0
        WINDOW SET TEXT 1, 20, "Goodbye", "Toolbar demo", "Exiting"
      END SELECT
    END IF
  END IF
LOOP

WINDOW SHUTDOWN
