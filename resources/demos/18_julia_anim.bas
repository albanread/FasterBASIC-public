' =========================================================================
' Julia Set Demo — Real-time Parameter Animation
' =========================================================================
'
' This demo showcases:
' - COMPLEX numbers for fractal generation
' - Real-time animation by shifting the "c" parameter
' - Double buffering via FLIP
' - Array-wide complex operations


APPNAME "Julia Set Animation - Complex Numbers"
SCREEN 640, 480, 2
SCREENTITLE "Julia Set Animation - Complex Numbers"

' Setup Palette (Global Indices 16-255)
' Using 16 indices starting at 16
PALETTE 0, 0, 0, 0
FOR i = 0 TO 15
  PALETTE 16 + i, (i * 15), 255 - (i * 15), 128 + (i * 8)
NEXT i

DIM W AS INTEGER = 640
DIM H AS INTEGER = 480
DIM max_iter AS INTEGER = 32

' View bounds
DIM min_re AS DOUBLE = -1.5
DIM max_re AS DOUBLE = 1.5
DIM min_im AS DOUBLE = -1.125
DIM max_im AS DOUBLE = 1.125

' Buffers
DIM cr(640) AS DOUBLE
DIM z(640) AS COMPLEX
DIM escaped(640) AS INTEGER

DIM x AS INTEGER
DIM y AS INTEGER

' Precompute X coordinates
FOR x = 1 TO W
  cr(x) = min_re + (x - 1) * (max_re - min_re) / (W - 1)
NEXT x

DIM angle AS DOUBLE = 0.0
DIM c AS COMPLEX
DIM it AS INTEGER
DIM ci AS DOUBLE
DIM frame AS INTEGER
DIM frame_limit AS INTEGER = 1200
DIM t_start AS LONG
DIM t_end AS LONG
DIM elapsed AS LONG

t_start = TIMER
frame = 0
DO
  ' Update the Julia constant based on time
  angle = angle + 0.05
  c = CMPLX(0.355 * COS(angle), 0.355 * SIN(angle * 0.5))

  FOR y = 0 TO H - 1
    ci = min_im + y * (max_im - min_im) / (H - 1)

    ' Initialize row
    FOR x = 1 TO W
      z(x) = CMPLX(cr(x), ci)
      escaped(x) = 0
    NEXT x

    ' Recurrence: z = z^2 + c
    FOR it = 1 TO max_iter
      z() = z() * z()
      z() = z() + c

      FOR x = 1 TO W
        IF escaped(x) = 0 THEN
          IF REAL(z(x))^2 + IMAG(z(x))^2 > 4.0 THEN
            escaped(x) = it
          END IF
        END IF
      NEXT x
    NEXT it

    ' Render row
    FOR x = 1 TO W
      IF escaped(x) = 0 THEN
        PSET x-1, y, 0
      ELSE
        PSET x-1, y, 16 + (escaped(x) MOD 16)
      END IF
    NEXT x
  NEXT y

  FLIP
  frame = frame + 1
  'IF frame MOD 60 = 0 THEN PRINT "Frame: "; frame
  IF frame >= frame_limit THEN EXIT DO
  IF GKEYDOWN(53) THEN EXIT DO ' Esc
LOOP
