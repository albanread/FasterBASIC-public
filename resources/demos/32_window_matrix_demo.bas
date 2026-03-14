' ── window_matrix_demo.bas ───────────────────────────────────────────────────
' Displays three 3×3 matrices A, B, C in WINDOW MATRIX views.
' Toolbar buttons apply MAT operations (A*B, TRN, INV, ZER, IDN) → C.
' Status bar reports the last operation performed.
' ─────────────────────────────────────────────────────────────────────────────

APPNAME "Matrix Workbench"

DIM A(3,3) AS DOUBLE
DIM B(3,3) AS DOUBLE
DIM C(3,3) AS DOUBLE

' ── Initialise A ─────────────────────────────────────────────────────────────
A(1,1) = 1 : A(1,2) = 2 : A(1,3) = 3
A(2,1) = 0 : A(2,2) = 4 : A(2,3) = 5
A(3,1) = 1 : A(3,2) = 0 : A(3,3) = 6

' ── Initialise B ─────────────────────────────────────────────────────────────
B(1,1) = 7 : B(1,2) = 8 : B(1,3) = 0
B(2,1) = 1 : B(2,2) = 2 : B(2,3) = 3
B(3,1) = 4 : B(3,2) = 0 : B(3,3) = 5

PrintAll("Initial state")

' ── C starts as identity ─────────────────────────────────────────────────────
MAT C = IDN

' ── Menu definition ─────────────────────────────────────────────────────────
MENU DEFINE
  MENU "Matrix"
  ITEM 501, "A = B * C", "M"
  ITEM 502, "A = C * B", "Shift+M"
  ITEM 503, "A = B + C", "A"
  ITEM 504, "A = B - C", "S"
  SEPARATOR
  ITEM 505, "A = TRN(B)", "T"
  ITEM 506, "A = TRN(C)", "Shift+T"
  ITEM 507, "A = INV(B)", "I"
  ITEM 508, "A = INV(C)", "Shift+I"
  ITEM 509, "A = ZER", "Z"
  SEPARATOR
  ITEM 510, "B = IDN", "Ctrl+B"
  ITEM 511, "B = ZER", "Ctrl+Shift+B"
  ITEM 512, "C = IDN", "D"
  ITEM 513, "C = ZER", "Ctrl+Shift+C"
  ITEM 514, "Copy B → C", "Ctrl+Right"
  ITEM 515, "Copy C → B", "Ctrl+Left"
  SEPARATOR
  ITEM 599, "Quit", "Cmd+Q"
  END MENU
END DEFINE

' ── Layout constants ─────────────────────────────────────────────────────────
WIN = 1
W_WIDE = 980
W_TALL = 380
M_X1 = 12
M_X2 = 324
M_X3 = 636
M_W = 300
M_LY = 38 ' label Y
M_MY = 58 ' matrix view Y
M_MH = 220 ' matrix view height

' ── Window definition ────────────────────────────────────────────────────────
WINDOW DEFINE WIN, "Matrix Workbench — Ed FasterBASIC", 80, 80, W_WIDE, W_TALL
  WINDOW TOOLBAR 10, "B*C→A|TRN B→A|INV B→A|ZER A|IDN C", 0, 2, W_WIDE, 28

  WINDOW LABEL 20, "Matrix A  (result)", M_X1, M_LY, M_W, 18
  WINDOW MATRIX 21, A(), M_X1, M_MY, M_W, M_MH

  WINDOW LABEL 30, "Matrix B  (input)", M_X2, M_LY, M_W, 18
  WINDOW MATRIX 31, B(), M_X2, M_MY, M_W, M_MH

  WINDOW LABEL 40, "Matrix C  (input)", M_X3, M_LY, M_W, 18
  WINDOW MATRIX 41, C(), M_X3, M_MY, M_W, M_MH

  WINDOW STATUSBAR 50, "Ready — use toolbar or Matrix menu||3×3 matrices", 0, 304, W_WIDE, 22
END WINDOW

WINDOW SHOW WIN

running = 1

DO WHILE running
  ' Handle menu commands first
  evm = MENU EVENT()
  IF evm <> 0 THEN
    SELECT CASE evm
    CASE 501 ' A = B * C  (MATMUL)
      MAT A = B * C
      WINDOW MATRIX WIN, 21, A(), M_X1, M_MY, M_W, M_MH
      WINDOW SET TEXT WIN, 50, "A = B * C  (matrix multiply)", "Matrix Workbench", ""
      PrintAll "A = B * C"

    CASE 502 ' A = C * B (show non-commutativity)
      MAT A = C * B
      WINDOW MATRIX WIN, 21, A(), M_X1, M_MY, M_W, M_MH
      WINDOW SET TEXT WIN, 50, "A = C * B  (swapped multiply)", "Matrix Workbench", ""
      PrintAll "A = C * B"

    CASE 503 ' A = B + C
      MAT A = B + C
      WINDOW MATRIX WIN, 21, A(), M_X1, M_MY, M_W, M_MH
      WINDOW SET TEXT WIN, 50, "A = B + C  (matrix add)", "Matrix Workbench", ""
      PrintAll "A = B + C"

    CASE 504 ' A = B - C
      MAT A = B - C
      WINDOW MATRIX WIN, 21, A(), M_X1, M_MY, M_W, M_MH
      WINDOW SET TEXT WIN, 50, "A = B - C  (matrix subtract)", "Matrix Workbench", ""
      PrintAll "A = B - C"

    CASE 505 ' A = TRN(B)
      MAT A = TRN(B)
      WINDOW MATRIX WIN, 21, A(), M_X1, M_MY, M_W, M_MH
      WINDOW SET TEXT WIN, 50, "A = TRN(B)  (transpose of B)", "Matrix Workbench", ""
      PrintAll "A = TRN(B)"

    CASE 506 ' A = TRN(C)
      MAT A = TRN(C)
      WINDOW MATRIX WIN, 21, A(), M_X1, M_MY, M_W, M_MH
      WINDOW SET TEXT WIN, 50, "A = TRN(C)  (transpose of C)", "Matrix Workbench", ""
      PrintAll "A = TRN(C)"

    CASE 507 ' A = INV(B)
      MAT A = INV(B)
      WINDOW MATRIX WIN, 21, A(), M_X1, M_MY, M_W, M_MH
      WINDOW SET TEXT WIN, 50, "A = INV(B)  (inverse of B)", "Matrix Workbench", ""
      PrintAll "A = INV(B)"

    CASE 508 ' A = INV(C)
      MAT A = INV(C)
      WINDOW MATRIX WIN, 21, A(), M_X1, M_MY, M_W, M_MH
      WINDOW SET TEXT WIN, 50, "A = INV(C)  (inverse of C)", "Matrix Workbench", ""
      PrintAll "A = INV(C)"

    CASE 509 ' ZER → A
      MAT A = ZER
      WINDOW MATRIX WIN, 21, A(), M_X1, M_MY, M_W, M_MH
      WINDOW SET TEXT WIN, 50, "A = ZER  (zero matrix)", "Matrix Workbench", ""

    CASE 510 ' IDN → B
      MAT B = IDN
      WINDOW MATRIX WIN, 31, B(), M_X2, M_MY, M_W, M_MH
      WINDOW SET TEXT WIN, 50, "B = IDN  (identity matrix)", "Matrix Workbench", ""
      PrintAll "B = IDN"

    CASE 511 ' ZER → B
      MAT B = ZER
      WINDOW MATRIX WIN, 31, B(), M_X2, M_MY, M_W, M_MH
      WINDOW SET TEXT WIN, 50, "B = ZER  (zero matrix)", "Matrix Workbench", ""
      PrintAll "B = ZER"

    CASE 512 ' IDN → C
      MAT C = IDN
      WINDOW MATRIX WIN, 41, C(), M_X3, M_MY, M_W, M_MH
      WINDOW SET TEXT WIN, 50, "C = IDN  (identity matrix)", "Matrix Workbench", ""
      PrintAll "C = IDN"

    CASE 513 ' ZER → C
      MAT C = ZER
      WINDOW MATRIX WIN, 41, C(), M_X3, M_MY, M_W, M_MH
      WINDOW SET TEXT WIN, 50, "C = ZER  (zero matrix)", "Matrix Workbench", ""
      PrintAll "C = ZER"

    CASE 514 ' Copy B into C
      MAT C = B
      WINDOW MATRIX WIN, 41, C(), M_X3, M_MY, M_W, M_MH
      WINDOW SET TEXT WIN, 50, "C = B  (copy)", "Matrix Workbench", ""
      PrintAll "C = B"

    CASE 515 ' Copy C into B
      MAT B = C
      WINDOW MATRIX WIN, 31, B(), M_X2, M_MY, M_W, M_MH
      WINDOW SET TEXT WIN, 50, "B = C  (copy)", "Matrix Workbench", ""
      PrintAll "B = C"

    CASE 599 ' Quit
      running = 0
    END SELECT
  END IF

  ev = WINDOW EVENT(ev_win, ev_ctl)

  IF ev = 2 AND ev_win = WIN THEN
    ' Matrix cell edited by the user — write the new value into the BASIC array
    r% = WINDOW MATRIX ROW
    c% = WINDOW MATRIX COL
    v = WINDOW MATRIX VAL
    IF ev_ctl = 31 THEN B(r%, c%) = v
    IF ev_ctl = 41 THEN C(r%, c%) = v
  END IF

  IF ev = 1 AND ev_win = WIN THEN
    SELECT CASE ev_ctl

    CASE 0 ' window closed
      running = 0

    CASE 10 ' A = B * C  (MATMUL)
      MAT A = B * C
      WINDOW MATRIX WIN, 21, A(), M_X1, M_MY, M_W, M_MH
      WINDOW SET TEXT WIN, 50, "A = B * C  (matrix multiply)", "Matrix Workbench", ""
      PrintAll "A = B * C"

    CASE 11 ' A = TRN(B)
      MAT A = TRN(B)
      WINDOW MATRIX WIN, 21, A(), M_X1, M_MY, M_W, M_MH
      WINDOW SET TEXT WIN, 50, "A = TRN(B)  (transpose of B)", "Matrix Workbench", ""
      PrintAll "A = TRN(B)"

    CASE 12 ' A = INV(B)
      MAT A = INV(B)
      WINDOW MATRIX WIN, 21, A(), M_X1, M_MY, M_W, M_MH
      WINDOW SET TEXT WIN, 50, "A = INV(B)  (inverse of B)", "Matrix Workbench", ""
      PrintAll "A = INV(B)"

    CASE 13 ' ZER → A
      MAT A = ZER
      WINDOW MATRIX WIN, 21, A(), M_X1, M_MY, M_W, M_MH
      WINDOW SET TEXT WIN, 50, "A = ZER  (zero matrix)", "Matrix Workbench", ""

    CASE 14 ' IDN → C (identity useful for B*C sanity checks)
      MAT C = IDN
      WINDOW MATRIX WIN, 41, C(), M_X3, M_MY, M_W, M_MH
      WINDOW SET TEXT WIN, 50, "C = IDN  (identity matrix)", "Matrix Workbench", ""
      PrintAll "C = IDN"

    END SELECT
  END IF

  SLEEP 0.016
LOOP

MENU RESET
WINDOW SHUTDOWN

SUB PrintAll(op AS STRING)
  SHARED A
  SHARED B
  SHARED C
  PRINT "=== " & op & " ==="
  PRINT "B:"
  PRINT "  " & STR$(B(1,1)) & "  " & STR$(B(1,2)) & "  " & STR$(B(1,3))
  PRINT "  " & STR$(B(2,1)) & "  " & STR$(B(2,2)) & "  " & STR$(B(2,3))
  PRINT "  " & STR$(B(3,1)) & "  " & STR$(B(3,2)) & "  " & STR$(B(3,3))
  PRINT "C:"
  PRINT "  " & STR$(C(1,1)) & "  " & STR$(C(1,2)) & "  " & STR$(C(1,3))
  PRINT "  " & STR$(C(2,1)) & "  " & STR$(C(2,2)) & "  " & STR$(C(2,3))
  PRINT "  " & STR$(C(3,1)) & "  " & STR$(C(3,2)) & "  " & STR$(C(3,3))
  PRINT "A (result):"
  PRINT "  " & STR$(A(1,1)) & "  " & STR$(A(1,2)) & "  " & STR$(A(1,3))
  PRINT "  " & STR$(A(2,1)) & "  " & STR$(A(2,2)) & "  " & STR$(A(2,3))
  PRINT "  " & STR$(A(3,1)) & "  " & STR$(A(3,2)) & "  " & STR$(A(3,3))
  PRINT ""
END SUB