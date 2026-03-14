# Complex Numbers in FasterBASIC

*Built-in `COMPLEX` values with fast arithmetic, array expressions, and SIMD acceleration where available.*

---

## Overview

FasterBASIC now includes a built-in `COMPLEX` type and helper functions:

- `CMPLX(re, im)` — construct a complex value
- `REAL(z)` — extract real part
- `IMAG(z)` — extract imaginary part
- `CONJ(z)` — complex conjugate
- `ABSZ(z)` — magnitude (modulus)
- `ARG(z)` — phase angle in radians
- `POLAR(r, theta)` — construct from polar coordinates

This lets you write direct mathematical code for fractals, DSP, and 2D transforms without manually managing `Re`/`Im` fields.

---

## Basic Usage

```basic
DIM z AS COMPLEX
DIM w AS COMPLEX
DIM u AS COMPLEX

z = CMPLX(1.0, 2.0)
w = CMPLX(3.0, 4.0)

u = z + w
PRINT REAL(u), IMAG(u)   ' 4, 6

u = z * w
PRINT REAL(u), IMAG(u)   ' -5, 10
```

Complex values support `+`, `-`, `*`, and `/`.

---

## Complex Intrinsics

### Conjugate: `CONJ`

```basic
DIM z AS COMPLEX
DIM w AS COMPLEX

z = CMPLX(1.5, -0.25)
w = CONJ(z)
PRINT REAL(w), IMAG(w)   ' 1.5, 0.25
```

### Magnitude: `ABSZ`

```basic
DIM z AS COMPLEX
z = CMPLX(3.0, 4.0)
PRINT ABSZ(z)            ' 5
```

### Phase Angle: `ARG`

```basic
DIM z AS COMPLEX
z = CMPLX(0.0, 1.0)
PRINT ARG(z)             ' ~1.57079632679 (pi/2)
```

### Polar Construction: `POLAR`

```basic
DIM z AS COMPLEX
z = POLAR(2.0, 1.57079632679)
PRINT REAL(z), IMAG(z)   ' ~0, 2
```

---

## Scalar + Complex Promotion

Scalars automatically promote to complex with zero imaginary part:

```basic
DIM z AS COMPLEX
DIM u AS COMPLEX

z = CMPLX(1.0, 2.0)
u = z + 2.0
PRINT REAL(u), IMAG(u)   ' 3, 2

u = 2.0 * z
PRINT REAL(u), IMAG(u)   ' 2, 4
```

---

## Whole-Array Complex Expressions

`COMPLEX` works with array expressions too:

```basic
DIM a(4) AS COMPLEX
DIM b(4) AS COMPLEX
DIM c(4) AS COMPLEX

FOR i = 0 TO 3
  a(i) = CMPLX(i * 1.0, i * 0.5)
  b(i) = CMPLX(1.0, 0.0)
NEXT i

c() = a() * a() + b()
PRINT REAL(c(2)), IMAG(c(2))   ' 4, 4
```

This style is ideal for iterative numeric kernels (for example Mandelbrot updates).

---

## Mandelbrot Pattern

A typical Mandelbrot iteration can now be written naturally:

```basic
z() = z() * z() + c()
```

Using `COMPLEX` arrays keeps the source compact and maps well to FasterBASIC’s whole-array optimizer.

---

## Performance Notes

- Canonical `COMPLEX` layout is optimized in codegen.
- On ARM64, LLVM lowers vector operations to NEON (`q`/`v` registers) where possible.
- Safe scalar fallback paths are retained for portability and non-vectorizable cases.

So you get speed where available without losing correctness on other paths.

---

## Tips

- Use `REAL()`/`IMAG()` at boundaries (I/O, checks, plotting), not in the hottest inner loop.
- Keep calculations in `COMPLEX` form as long as possible.
- Prefer whole-array expressions (`z() = ...`) for throughput.
