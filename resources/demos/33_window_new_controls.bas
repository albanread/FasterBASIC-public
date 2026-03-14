' Demo: New Window Controls — Popup, Slider, Progress, SecureField
' Shows all four new controls introduced alongside the existing ones.


APPNAME "New Controls Demo"

' ── Define the window ──────────────────────────────────────────────
WINDOW DEFINE 1, "New Controls Demo", 100, 100, 420, 360
  WINDOW LABEL    1, "Pick a colour:", 20, 20, 150, 22
  WINDOW POPUP    2, "Red|Green|Blue|Yellow|Cyan|Magenta", 180, 20, 200, 25

  WINDOW LABEL    3, "Volume:", 20, 65, 80, 22
  WINDOW SLIDER   4, 0, 100, 110, 62, 270, 22

  WINDOW LABEL    5, "Progress:", 20, 110, 80, 22
  WINDOW PROGRESS 6, 0, 100, 110, 107, 270, 16

  WINDOW LABEL    7, "Password:", 20, 150, 80, 22
  WINDOW SECUREFIELD 8, "Enter password", 110, 147, 200, 25

  WINDOW BUTTON   9, "Apply",  20, 200, 100, 30
  WINDOW BUTTON  10, "Reset", 135, 200, 100, 30
  WINDOW BUTTON  11, "Quit",  250, 200, 100, 30

  WINDOW LABEL   12, "Ready.", 20, 250, 360, 22
END WINDOW

' Pre-select sensible defaults
WINDOW SET VALUE 1, 4, 50         ' Slider at mid-point
WINDOW SET VALUE 1, 6, 25         ' Progress bar at 25%
WINDOW SET VALUE 1, 2, 1          ' Select "Green" (index 1)

WINDOW SHOW 1

' ── Event loop ─────────────────────────────────────────────────────
DIM win%, ctl%, running%
running% = 1
DO WHILE running%
  SLEEP 0.016
  IF WINDOW EVENT(win%, ctl%) THEN
    PRINT "Event detected! Win:"; win%; " Ctl:"; ctl%
    IF win% = 0 AND ctl% = 0 THEN
      ' Window closed by user
      running% = 0
    ELSEIF win% = 1 THEN
      SELECT CASE ctl%
        CASE 4
          PRINT "Slider move!"
          ' Slider moved — mirror value to progress bar immediately
          DIM svol%
          svol% = WINDOW VALUE(1, 4)
          PRINT svol%
          WINDOW SET VALUE 1, 6, svol%
          WINDOW SET TEXT 1, 12, "Slider: " + STR$(svol%)

        CASE 9
          ' Apply: mirror slider to progress and show status
          DIM vol%
          vol% = WINDOW VALUE(1, 4)
          WINDOW SET VALUE 1, 6, vol%
          PRINT "vol";vol%
          DIM colour$
          colour$ = WINDOW TEXT$(1, 2)
          DIM msg$
          msg$ = "Colour: " + colour$ + "  Volume: " + STR$(vol%) + "%"
          WINDOW SET TEXT 1, 12, msg$

        CASE 10
          ' Reset everything
          WINDOW SET VALUE 1, 4, 0
          WINDOW SET VALUE 1, 6, 0
          WINDOW SET VALUE 1, 2, 0
          WINDOW SET TEXT  1, 12, "Reset."

        CASE 11
          running% = 0
      END SELECT
    END IF
  END IF
LOOP

WINDOW CLOSE 1
WINDOW SHUTDOWN
