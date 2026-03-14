' window_loan_payment.bas
' HelpMeta:
'   Domain: root
'   Tags: finance,loan,amortization,payment,window,menu
'   Prereqs: exponents,percent-rate conversion
'   Units: currency and years
'   Assumptions: fixed-rate fully amortized schedule
' Purpose:
'   Loan payment calculator using non-modal WINDOW controls
'   with a native menu bar for presets and actions.
' Inputs:
'   principal, APR %, years, payments/year
' Formula:
'   n = years * payments_per_year
'   r = (apr/100) / payments_per_year
'   payment = P*r / (1 - (1+r)^(-n))


APPNAME "Loan Payment Calculator"

DIM principal AS DOUBLE
DIM apr AS DOUBLE
DIM years AS DOUBLE
DIM ppy AS DOUBLE

DIM payment AS DOUBLE
DIM total_paid AS DOUBLE
DIM total_interest AS DOUBLE

principal = 300000
apr = 6.5
years = 30
ppy = 12

' ── Menu Bar ──────────────────────────────────────────────────────────
MENU DEFINE
  MENU "Loan"
  ITEM 301, "Calculate", "Cmd+Return"
  ITEM 302, "Reset Defaults", "Cmd+R"
  SEPARATOR
  ITEM 303, "Quit", "Cmd+Q"
  END MENU

  MENU "Presets"
  ITEM 401, "Starter Home ($200k, 30yr)", ""
  ITEM 402, "Family Home ($400k, 30yr)", ""
  ITEM 403, "Luxury ($800k, 15yr)", ""
  SEPARATOR
  ITEM 404, "Car Loan ($35k, 5yr)", ""
  ITEM 405, "Student Loan ($50k, 10yr)", ""
  END MENU

  MENU "View"
  ITEM 501, "Show Total Interest", "", CHECKED
  END MENU
END DEFINE

' ── Window Definition ─────────────────────────────────────────────────
WINDOW DEFINE 1, "Loan Payment Calculator", 100, 100, 420, 400
  ' Input Labels
  WINDOW LABEL 100, "Principal ($):", 20, 20, 120, 24
  WINDOW LABEL 101, "APR (%):", 20, 60, 120, 24
  WINDOW LABEL 102, "Years:", 20, 100, 120, 24
  WINDOW LABEL 103, "Payments/Year:", 20, 140, 120, 24

  ' Input TextFields
  WINDOW TEXTFIELD 10, STR$(principal), 150, 20, 220, 24
  WINDOW TEXTFIELD 11, STR$(apr), 150, 60, 220, 24
  WINDOW TEXTFIELD 12, STR$(years), 150, 100, 220, 24
  WINDOW TEXTFIELD 13, STR$(ppy), 150, 140, 220, 24

  ' Checkbox for extra detail (synced with View menu)
  WINDOW CHECKBOX 20, "Show total interest", 20, 180, 200, 24

  ' Buttons
  WINDOW BUTTON 1, "Calculate", 20, 215, 170, 28
  WINDOW BUTTON 2, "Reset Defaults", 200, 215, 170, 28

  ' Output Labels
  WINDOW LABEL 200, "Payment:", 20, 265, 120, 24
  WINDOW LABEL 201, "Total Paid:", 20, 305, 120, 24
  WINDOW LABEL 202, "Total Interest:", 20, 345, 120, 24

  ' Output Values (initially empty)
  WINDOW LABEL 210, "-", 150, 265, 220, 24
  WINDOW LABEL 211, "-", 150, 305, 220, 24
  WINDOW LABEL 212, "-", 150, 345, 220, 24
END WINDOW

WINDOW SHOW 1

show_interest = 1 ' tracks checkbox/menu sync

' ── Calculation SUB ───────────────────────────────────────────────────
SUB DoCalculate()
  SHARED principal, apr, years, ppy
  SHARED payment, total_paid, total_interest
  SHARED show_interest

  principal = VAL(WINDOW TEXT$(1, 10))
  apr = VAL(WINDOW TEXT$(1, 11))
  years = VAL(WINDOW TEXT$(1, 12))
  ppy = VAL(WINDOW TEXT$(1, 13))

  IF principal > 0 AND apr > 0 AND years > 0 AND ppy > 0 THEN
    n = years * ppy
    r = (apr / 100) / ppy
    payment = principal * r / (1 - (1 + r)^(-n))
    total_paid = payment * n
    total_interest = total_paid - principal

    WINDOW SET TEXT 1, 210, "$" + STR$(payment)
    WINDOW SET TEXT 1, 211, "$" + STR$(total_paid)

    IF show_interest = 1 THEN
      WINDOW SET TEXT 1, 212, "$" + STR$(total_interest)
    ELSE
      WINDOW SET TEXT 1, 212, "(enable in View menu)"
    END IF

    WINDOW SET TITLE 1, "Loan: $" + STR$(payment) + "/mo"
  ELSE
    WINDOW SET TEXT 1, 210, "Invalid Input"
    WINDOW SET TEXT 1, 211, "-"
    WINDOW SET TEXT 1, 212, "-"
  END IF
END SUB

' ── Reset SUB ─────────────────────────────────────────────────────────
SUB DoReset()
  SHARED principal, apr, years, ppy

  principal = 300000
  apr = 6.5
  years = 30
  ppy = 12

  WINDOW SET TEXT 1, 10, STR$(principal)
  WINDOW SET TEXT 1, 11, STR$(apr)
  WINDOW SET TEXT 1, 12, STR$(years)
  WINDOW SET TEXT 1, 13, STR$(ppy)

  WINDOW SET TEXT 1, 210, "-"
  WINDOW SET TEXT 1, 211, "-"
  WINDOW SET TEXT 1, 212, "-"
  WINDOW SET TITLE 1, "Loan Payment Calculator"
END SUB

' ── Apply a preset: fill fields and auto-calculate ────────────────────
SUB ApplyPreset(p AS DOUBLE, a AS DOUBLE, y AS DOUBLE, pp AS DOUBLE)
  WINDOW SET TEXT 1, 10, STR$(p)
  WINDOW SET TEXT 1, 11, STR$(a)
  WINDOW SET TEXT 1, 12, STR$(y)
  WINDOW SET TEXT 1, 13, STR$(pp)
  CALL DoCalculate()
END SUB

' ── Main Event Loop ───────────────────────────────────────────────────
running = 1

DO WHILE running
  ' ── Poll window events ────────────────────────────────────────────
  status = WINDOW EVENT(win, ctl)
  IF status = 1 THEN
    IF win = 1 THEN
      IF ctl = 0 THEN
        running = 0
      ELSEIF ctl = 1 THEN
        CALL DoCalculate()
      ELSEIF ctl = 2 THEN
        CALL DoReset()
      ELSEIF ctl = 20 THEN
        ' Checkbox toggled — sync menu checkmark
        show_interest = WINDOW CHECKED(1, 20)
        MENU CHECK 501, show_interest
        CALL DoCalculate()
      END IF
    END IF
  END IF

  ' ── Poll menu events ──────────────────────────────────────────────
  ev = MENU EVENT()
  IF ev <> 0 THEN
    SELECT CASE ev
      ' Loan menu
    CASE 301
      CALL DoCalculate()
    CASE 302
      CALL DoReset()
    CASE 303
      running = 0

      ' Presets menu
    CASE 401
      CALL ApplyPreset(200000, 6.75, 30, 12)
    CASE 402
      CALL ApplyPreset(400000, 6.5, 30, 12)
    CASE 403
      CALL ApplyPreset(800000, 5.5, 15, 12)
    CASE 404
      CALL ApplyPreset(35000, 7.9, 5, 12)
    CASE 405
      CALL ApplyPreset(50000, 5.0, 10, 12)

      ' View menu
    CASE 501
      show_interest = 1 - show_interest
      MENU CHECK 501, show_interest
      ' TODO: sync checkbox when WINDOW SET CHECKED is available
      CALL DoCalculate()
    END SELECT
  END IF

  SLEEP 0.05
LOOP

MENU RESET
WINDOW SHUTDOWN
PRINT "Done."
