' =========================================================================
' Plasma Cloud — Vector Array Expressions + Sinusoidal Modulation
' =========================================================================
'
' This demo showcases:
' - Higher-order array expressions (sin, cos, adding arrays)
' - Palette cycling for classic plasma effect
' - Use of double-buffer FLIP

APPNAME "Plasma Cloud"
SCREEN 640, 480, 2
SCREENTITLE "Plasma Cloud - Vector Expressions"

' Setup a smooth rainbow palette (Global Indices 16-255)
FOR i = 0 TO 239
  DIM r AS INTEGER = (128 + 127 * SIN(i * 3.14159 / 120))
  DIM g AS INTEGER = (128 + 127 * SIN(i * 3.14159 / 120 + 2.0944))
  DIM b AS INTEGER = (128 + 127 * SIN(i * 3.14159 / 120 + 4.1888))
  PALETTE 16 + i, r, g, b
NEXT i

DIM W AS INTEGER = 640
DIM H AS INTEGER = 480
DIM t AS DOUBLE = 0.0
DIM irow(640) AS DOUBLE

' Pre-calculate static x-wave (1..640)
DIM x_wave(640) AS DOUBLE
FOR x = 1 TO W
  x_wave(x) = SIN(x / 120.0)
NEXT x

DO
  t = t + 0.1
  DIM phase1 AS DOUBLE = SIN(t * 0.5) * 50
  DIM phase2 AS DOUBLE = COS(t * 0.3) * 30

  FOR y = 0 TO H - 1
    ' Vectorized row generation:
    ' Combine x-waves, y-waves, and time phases in single expressions
    irow() = (x_wave() * 32) + (SIN((y + phase1) / 80.0) * 32) + (SIN((y + x_wave() * 10) / 60.0) * 32)

    FOR x = 1 TO W
      ' Map row value to 16..255 global palette index
      c = (128 + irow(x)) MOD 240
      PSET x - 1, y, 16 + c
    NEXT x
  NEXT y

  FLIP
  VSYNC
  IF GKEYDOWN(53) THEN EXIT DO ' Esc
LOOP
