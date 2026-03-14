' Particle Swarm - Showcasing Array Expressions at Scale!
' ========================================================

APPNAME "Particle Swarm"
SCREEN 640, 480
SCREENTITLE "Interactive Vector Particle Swarm"

DIM N AS INTEGER
N = 10000

DIM px(10000) AS DOUBLE
DIM py(10000) AS DOUBLE
DIM vx(10000) AS DOUBLE
DIM vy(10000) AS DOUBLE
DIM cx(10000) AS DOUBLE
DIM cy(10000) AS DOUBLE

DIM i AS INTEGER

' Set up a beautiful plasma-ish color palette
FOR i = 17 TO 255
  DIM r AS INTEGER, g AS INTEGER, b AS INTEGER
  r = ABS(SIN(i * 0.05) * 255)
  g = ABS(SIN(i * 0.07 + 1.0) * 255)
  b = ABS(SIN(i * 0.09 + 2.0) * 255)
  PALETTE i, r, g, b
NEXT
PALETTE 16, 0, 0, 0 ' Black background

' Initialize particles into a ring
FOR i = 1 TO N
  DIM angle AS DOUBLE
  angle = (i * 6.28318) / N
  DIM r_init AS DOUBLE
  r_init = 100.0 + (i MOD 150)

  px(i) = 320.0 + COS(angle) * r_init
  py(i) = 240.0 + SIN(angle) * r_init

  vx(i) = -SIN(angle) * 3.0
  vy(i) = COS(angle) * 3.0
NEXT

DIM t AS DOUBLE
t = 0.0
DIM target_x AS DOUBLE
DIM target_y AS DOUBLE

DO
  t = t + 0.02

  DIM mx AS INTEGER
  DIM my AS INTEGER
  mx = GMOUSEX()
  my = GMOUSEY()

  IF mx > 0 AND my > 0 THEN
    target_x = mx
    target_y = my
  ELSE
    ' Automatic wandering target if mouse is outside
    target_x = 320.0 + SIN(t * 1.5) * 200.0
    target_y = 240.0 + COS(t * 1.1) * 150.0
  END IF

  ' Find displacement towards target for all particles
  cx() = target_x - px()
  cy() = target_y - py()

  ' Apply spiral gravity
  ' 1. A pull directly towards center
  vx() = vx() + cx() * 0.002
  vy() = vy() + cy() * 0.002

  ' 2. Tangential swirl
  vx() = vx() - cy() * 0.001
  vy() = vy() + cx() * 0.001

  ' Apply damping (friction) so they don't explode
  vx() = vx() * 0.95
  vy() = vy() * 0.95

  ' Update positions
  px() = px() + vx()
  py() = py() + vy()

  GCLS 16

  FOR i = 1 TO N
    ' Safety bounds to prevent integer overflow panic during graphics float casting
    DIM x AS DOUBLE
    DIM y AS DOUBLE
    x = px(i)
    y = py(i)

    IF x > -200 AND x < 1000 AND y > -200 AND y < 800 THEN
      DIM col AS INTEGER
      col = 17 + ABS(vx(i)) * 10 + ABS(vy(i)) * 10
      IF col > 255 THEN col = 255

      PSET x, y, col
    END IF
  NEXT

  FLIP
  VSYNC

LOOP UNTIL GKEYDOWN(53)
