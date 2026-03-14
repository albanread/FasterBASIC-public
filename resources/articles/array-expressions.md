# Array Expressions in FasterBASIC

*Whole-array operations — write `C() = A() + B()` and let the compiler handle the loop, the SIMD, and the details.*

---

## Introduction

A modern Mac contains vector and matrix processors, FasterBASIC provides many functions that use this 'supercomputer' level hardware.

Note that FasterBASIC auto vectorizes regular code, when applicable,
so ordinary looking problems may also be enhanced with NEON SIMD.

Additionall FasterBASIC supports **array expressions** — arithmetic and assignment operations that apply to every element of an array in a single statement. Instead of writing a FOR loop to add two arrays element by element, you write:

```basic
C() = A() + B()
```

The compiler generates a tight, vectorized loop behind the scenes. On ARM64, it emits NEON SIMD instructions that process multiple elements per clock cycle. On all platforms, it eliminates the boilerplate and lets you focus on what you're computing, not how to loop over it.

If you've used array operations in Fortran, MATLAB, or NumPy, you'll feel right at home. The difference is that this is compiled BASIC, producing native machine code.

Note that in many cases these operations, generate function calls.
This will not always be faster for small arrays, will certainly be faster for very large arrays, and will also lead to clear compact code in all circumstances.

Note FasterBASIC also supports MAT matrix commands that operate on arrays, the difference is that MAT implements matrix operations on 2d arrays, array expressions implement vector operations on 1d arrays.


---

## The Basics

### Syntax

The `()` suffix marks a variable as a whole-array reference. Any array declared with `DIM` can be used this way:

```basic
DIM A(100) AS SINGLE
DIM B(100) AS SINGLE
DIM C(100) AS SINGLE

' Element-wise addition — applies to every element
C() = A() + B()
```

This is equivalent to:

```basic
FOR i = 0 TO 100
  C(i) = A(i) + B(i)
NEXT i
```

But the array expression form is shorter, clearer, and gives the compiler more freedom to optimize.

### Why the Parentheses?

The empty `()` is intentional. It makes array operations visually distinct from scalar operations:

```basic
x = a + b        ' scalar: adds two numbers
C() = A() + B()  ' array: adds every element of A to every element of B
```

There's never any ambiguity about what's happening.

---

## Supported Operations

### Element-Wise Arithmetic

All four arithmetic operators work element by element across entire arrays:

```basic
DIM A(1000) AS SINGLE
DIM B(1000) AS SINGLE
DIM C(1000) AS SINGLE

C() = A() + B()    ' addition
C() = A() - B()    ' subtraction
C() = A() * B()    ' multiplication
C() = A() / B()    ' division
```

Each operation produces a result array where element `i` is the result of applying the operator to `A(i)` and `B(i)`.

### Array Copy

Copy the entire contents of one array to another:

```basic
DIM source(500) AS INTEGER
DIM dest(500) AS INTEGER

dest() = source()
```

This copies every element. On ARM64, it uses 128-bit NEON loads and stores, copying 4 integers (or 4 floats, or 2 doubles) per instruction.

### Scalar Broadcast

Combine an array with a scalar value. The scalar is applied to every element:

```basic
DIM temperatures(365) AS SINGLE
DIM adjusted(365) AS SINGLE

' Add a constant to every element
adjusted() = temperatures() + 1.5

' Scale every element
adjusted() = temperatures() * 1.8

' Scalar on the left works too
adjusted() = 32.0 + temperatures() * 1.8
```

### Array Fill

Assign a single value to every element of an array:

```basic
DIM scores(100) AS INTEGER
DIM weights(100) AS SINGLE

scores() = 0          ' zero the entire array
weights() = 1.0       ' fill with 1.0
```

This is much faster than a loop, especially for large arrays. The compiler uses NEON to broadcast the value across a 128-bit register and store 4 (or more) elements at once.

### Negation

Negate every element:

```basic
DIM velocity(100) AS SINGLE
DIM reversed(100) AS SINGLE

reversed() = -velocity()
```

### Fused Multiply-Add (FMA)

The compiler detects compound `A() + B() * C()` patterns and emits fused multiply-add instructions on ARM64, which are both faster and more numerically accurate than separate multiply and add:

```basic
DIM A(100) AS SINGLE
DIM B(100) AS SINGLE
DIM C(100) AS SINGLE
DIM D(100) AS SINGLE

D() = A() + B() * C()   ' fused multiply-add (FMLA)
D() = B() * C() + A()   ' commuted form — also uses FMLA
```

FMA works with `SINGLE`, `DOUBLE`, and `INTEGER` arrays. On ARM64 with NEON, the SINGLE path compiles to a single `fmla v28.4s, v29.4s, v30.4s` instruction per 4-element chunk.

---

## Reduction Functions

Reduction functions collapse an entire array down to a single scalar value:

```basic
DIM A(99) AS SINGLE

total! = SUM(A())       ' sum of all elements
mx! = MAX(A())          ' maximum element
mn! = MIN(A())          ' minimum element
avg! = AVG(A())         ' arithmetic mean
```

```basic
DIM A(99) AS SINGLE
DIM B(99) AS SINGLE

dp! = DOT(A(), B())     ' dot product: SUM(A(i) * B(i))
```

Reductions work with all numeric types — `BYTE`, `SHORT`, `INTEGER`, `LONG`, `SINGLE`, and `DOUBLE`. The return type matches the element type of the source array.

Note on indexing: FasterBASIC arrays are logically 1-based for user data. Reduction functions operate on indices `1..N` and intentionally exclude index `0`.

On macOS, `DOUBLE` reductions (`SUM`, `AVG`, `DOT`, `MAX`, `MIN`) use Apple Accelerate/vDSP runtime entry points for bulk evaluation once arrays are large enough to amortize call overhead; small arrays use scalar loops. Other numeric types and platforms use the compiler’s scalar reduction path.

### 2D Row/Column Reductions

For 2D arrays, you can reduce along one axis using row/column intrinsics:

```basic
DIM M(3, 3) AS DOUBLE

r! = SUMROW(M(), 2)   ' sum of row 2
c! = SUMCOL(M(), 3)   ' sum of column 3
mr! = MAXROW(M(), 2)  ' max element in row 2
mc! = MAXCOL(M(), 1)  ' max element in column 1
```

These follow the same 1-based indexing convention as normal 2D array element access.

For 2D reductions, row/column index `0` is likewise excluded from the reduction domain.

### 2D Matrix Multiply

`MATMUL` computes matrix multiplication for 2D arrays:

```basic
DIM A(2, 3) AS DOUBLE
DIM B(3, 2) AS DOUBLE
DIM C(2, 2) AS DOUBLE

C() = MATMUL(A(), B(), 2, 2, 3)   ' C[m,n] = A[m,k] * B[k,n]
```

Argument order is `MATMUL(A(), B(), m, n, k)` where:
- `A` is `m x k`
- `B` is `k x n`
- destination is `m x n`

### Scalar MAX / MIN

`MAX` and `MIN` are overloaded. With one array argument they perform a reduction; with two scalar arguments they return the larger or smaller value:

```basic
mx! = MAX(A())       ' array reduction — maximum element of A
mx% = MAX(10, 20)    ' scalar — returns 20

mn! = MIN(A())       ' array reduction — minimum element of A
mn% = MIN(10, 20)    ' scalar — returns 10
```

---

## Unary Array Functions

Element-wise application of math functions to every element of an array:

```basic
DIM A(100) AS SINGLE
DIM B(100) AS SINGLE

B() = ABS(A())    ' absolute value of every element
B() = SQR(A())    ' square root of every element
B() = EXP(A())    ' e^x for every element
B() = LOG(A())    ' natural log of every element
B() = SIN(A())    ' sine of every element
B() = COS(A())    ' cosine of every element
B() = TAN(A())    ' tangent of every element
B() = ATAN(A())   ' arctangent of every element
B() = SINH(A())   ' hyperbolic sine of every element
B() = COSH(A())   ' hyperbolic cosine of every element
B() = TANH(A())   ' hyperbolic tangent of every element
```

`ABS` uses NEON `fabs` for floating-point arrays and a branch-based integer absolute value for integer arrays. `SQR` converts through `sqrt` (double precision) and truncates back for `SINGLE`.

`SIN`, `COS`, `TAN`, `ATAN`, `SINH`, `COSH`, `TANH`, `EXP`, `LOG`, and `SQR`/`SQRT` support whole-array expressions. On macOS, large `DOUBLE` unary array math uses Apple Accelerate/vForce through the runtime for high-throughput bulk evaluation, while small arrays stay on scalar loops.

All unary array functions in this section work with numeric arrays; peak vForce throughput is currently on `DOUBLE` arrays.

## Binary Math Array Functions

Some two-argument math functions also support whole-array expressions:

```basic
DIM A(100) AS DOUBLE
DIM B(100) AS DOUBLE
DIM C(100) AS DOUBLE

C() = POW(A(), B())      ' element-wise power
C() = POW(A(), 2.0)      ' array/scalar power
C() = POW(2.0, B())      ' scalar/array power

C() = ATAN2(A(), B())    ' element-wise atan2(y, x)
C() = ATAN2(A(), 1.0)    ' array/scalar atan2
C() = ATAN2(1.0, B())    ' scalar/array atan2

C() = HYPOT(A(), B())    ' element-wise sqrt(A^2 + B^2)
C() = HYPOT(A(), 4.0)    ' array/scalar hypot
C() = HYPOT(3.0, B())    ' scalar/array hypot
```

On macOS, `DOUBLE` `POW(A(), B())` and `ATAN2(A(), B())` use Accelerate/vForce bulk paths. `HYPOT` whole-array forms use an Accelerate (vDSP + vForce) bulk path for large arrays. Mixed array/scalar forms are supported with runtime scalar fallback.

### Additional Accelerated Whole-Array Patterns

On macOS, large `DOUBLE` arrays also have specialized bulk paths for:

```basic
C() = A() * 1.25 + 3.5        ' affine transform
C() = 3.5 + A() * 1.25        ' commuted affine form
C() = A() * 1.25 - 3.5        ' affine with negative bias
C() = 3.5 - A() * 1.25        ' affine with negative scale

C() = CLAMP(A(), -1.0, 1.0)   ' per-element clamp to [lo, hi]
```

Small arrays use scalar loops to avoid call overhead.

---

## Supported Array Types

Array expressions work with all numeric array types:

| Element Type | Size | Elements per NEON Register | SIMD Benefit |
|---|---|---|---|
| `BYTE` | 8-bit | 16 | Excellent |
| `SHORT` | 16-bit | 8 | Excellent |
| `INTEGER` | 32-bit | 4 | Very good |
| `SINGLE` | 32-bit float | 4 | Very good |
| `LONG` | 64-bit | 2 | Good |
| `DOUBLE` | 64-bit float | 2 | Good |
| SIMD-eligible UDT | 128-bit | 1 | Good |

Smaller types pack more elements into each NEON register, so `BYTE` and `SHORT` arrays see the biggest throughput gains.

### BYTE and SHORT Arrays

`BYTE` (8-bit) and `SHORT` (16-bit) arrays are fully supported with correct sub-word memory operations. The compiler uses `storeb`/`loadsb` for BYTE and `storeh`/`loadsh` for SHORT to avoid corrupting adjacent elements — a common pitfall when 32-bit store instructions are used on packed sub-word data.

NEON vectorization uses `.16b` arrangement for BYTE (16 elements per register) and `.8h` arrangement for SHORT (8 elements per register):

```basic
DIM pixels(1023) AS BYTE
DIM mask(1023) AS BYTE
DIM result(1023) AS BYTE

result() = pixels() + mask()   ' processes 16 bytes per NEON iteration
```

### UDT Arrays

Array expressions also work with arrays of SIMD-eligible User-Defined Types (UDTs that have all fields the same numeric type):

```basic
TYPE Vec4
  X AS SINGLE
  Y AS SINGLE
  Z AS SINGLE
  W AS SINGLE
END TYPE

DIM positions(1000) AS Vec4
DIM velocities(1000) AS Vec4

' Add velocity to position for every element
positions() = positions() + velocities()
```

Each `Vec4` fits in one 128-bit NEON register. The loop processes one complete vector per iteration with a single `fadd v0.4s, v0.4s, v1.4s` instruction.

### String Arrays

String arrays (`STRING$`) are **not supported** for array expressions. Strings use reference counting and variable-length storage, which don't map to SIMD operations.

---

## Complete Examples

### Example 1: Vector Addition

```basic
' Add two float arrays
DIM A(100) AS SINGLE
DIM B(100) AS SINGLE
DIM C(100) AS SINGLE

' Initialize
FOR i = 0 TO 100
  A(i) = i * 1.5
  B(i) = i * 0.5
NEXT i

' Array expression — one line instead of a loop
C() = A() + B()

' Verify
PRINT "C(0) = "; C(0)     ' 0.0
PRINT "C(10) = "; C(10)   ' 20.0
PRINT "C(100) = "; C(100) ' 200.0
```

### Example 2: Scaling and Offset

```basic
' Convert Celsius to Fahrenheit for an entire dataset
DIM celsius(365) AS SINGLE
DIM fahrenheit(365) AS SINGLE

' ... populate celsius() with daily temperatures ...

' One expression does the entire conversion
fahrenheit() = celsius() * 1.8 + 32.0
```

### Example 3: Physics Simulation with FMA

```basic
TYPE Vec4
  X AS SINGLE
  Y AS SINGLE
  Z AS SINGLE
  W AS SINGLE
END TYPE

DIM pos(10000) AS Vec4
DIM vel(10000) AS Vec4
DIM acc(10000) AS Vec4

' ... initialize particles ...

' Euler integration with fused multiply-add
' vel += acc * dt,  pos += vel * dt
DIM dt AS SINGLE
dt = 0.016

' These compile to FMLA NEON instructions
vel() = vel() + acc() * dt
pos() = pos() + vel() * dt

' Damping
vel() = vel() * 0.99
```

### Example 4: Image Processing

```basic
' Brighten an image stored as byte pixel values
DIM pixels(1920 * 1080) AS BYTE
DIM brightened(1920 * 1080) AS BYTE

brightened() = pixels() + 20   ' NEON processes 16 pixels per cycle

' Compute statistics
DIM image(1920 * 1080) AS SINGLE
avgBrightness! = AVG(image())
maxBrightness! = MAX(image())
minBrightness! = MIN(image())
```

### Example 5: Signal Processing

```basic
DIM signal(8191) AS SINGLE
DIM kernel(8191) AS SINGLE

' Dot product (correlation at zero lag)
correlation! = DOT(signal(), kernel())

' Root mean square
DIM squared(8191) AS SINGLE
squared() = signal() * signal()
rms! = SQR(SUM(squared()) / 8192)

' Absolute value for envelope detection
DIM envelope(8191) AS SINGLE
envelope() = ABS(signal())
```

### Example 6: Array Initialization Patterns

```basic
DIM data(1000) AS DOUBLE

' Zero everything
data() = 0

' Fill with a sentinel value
data() = -1.0

' Copy from a template
DIM template(1000) AS DOUBLE
' ... set up template ...
data() = template()
```

---

## How It Works

When the compiler encounters an array expression like `C() = A() + B()`, it:

1. **Verifies compatibility** — all arrays must have the same element type and compatible dimensions
2. **Checks SIMD eligibility** — determines whether the element type maps to NEON registers
3. **Emits a vectorized loop** — generates a pointer-based loop that processes elements in bulk
4. **Emits a scalar remainder loop** — handles leftover elements when the array length isn't a multiple of the SIMD lane count

On ARM64, the generated loop uses NEON 128-bit registers. For `SINGLE` arrays, this processes 4 elements per iteration:

```
loop:
    ldr   q28, [src_a], #16     ; load 4 floats from A
    ldr   q29, [src_b], #16     ; load 4 floats from B
    fadd  v28.4s, v28.4s, v29.4s ; add all 4 in parallel
    str   q28, [dest], #16      ; store 4 results to C
    cmp   dest, end
    b.lt  loop
```

For FMA expressions like `D() = A() + B() * C()`, the compiler loads three vectors and emits:

```
    ldr   q28, [src_a], #16
    ldr   q29, [src_b], #16
    ldr   q30, [src_c], #16
    fmla  v28.4s, v29.4s, v30.4s  ; v28 += v29 * v30
    str   q28, [dest], #16
```

The fused multiply-add is a single instruction with no intermediate rounding.

### Comparison with FOR Loops

The compiler also vectorizes explicit FOR loops that follow recognizable patterns:

```basic
' These produce the same machine code:

' Array expression
C() = A() + B()

' Explicit FOR loop (auto-vectorized)
FOR i = 0 TO 100
  C(i) = A(i) + B(i)
NEXT i
```

The array expression form is preferred because:
- It's shorter and more readable
- It communicates intent more clearly
- The compiler doesn't need to analyze loop structure to find the pattern
- There's no risk of accidental loop-carried dependencies

---

## Rules and Constraints

### Arrays Must Be Compatible

All arrays in an expression must have the same element type:

```basic
DIM A(100) AS SINGLE
DIM B(100) AS DOUBLE

' ERROR: mismatched types
C() = A() + B()
```

### Division by Zero

Array division follows the same rules as scalar division. For integer arrays, division by zero in any element will cause a runtime error. For floating-point arrays, division by zero produces infinity or NaN per IEEE 754 rules.

### In-Place Operations

You can use the same array on both sides of the assignment:

```basic
DIM A(100) AS SINGLE

A() = A() + 1.0      ' increment every element
A() = A() * 2.0      ' double every element
A() = A() * A()      ' square every element
```

This is safe because the compiler processes elements sequentially (or in non-overlapping SIMD chunks).

### Integer Division

Integer division truncates toward zero, just like scalar integer division in BASIC:

```basic
DIM A(10) AS INTEGER
DIM B(10) AS INTEGER
DIM C(10) AS INTEGER

' Integer division — results are truncated
C() = A() / B()    ' same as C(i) = A(i) \ B(i) for each element
```

> **Note:** NEON hardware integer division is only available for floating-point lanes. For integer arrays, the compiler uses a scalar fallback for division. Addition, subtraction, and multiplication still use NEON.

---

## Performance

### Throughput Gains

The speedup depends on the element type and operation:

| Element Type | Elements per NEON Op | Theoretical Speedup |
|---|---|---|
| `BYTE` | 16 | Up to 16× |
| `SHORT` | 8 | Up to 8× |
| `INTEGER` / `SINGLE` | 4 | Up to 4× |
| `LONG` / `DOUBLE` | 2 | Up to 2× |

Real-world gains are typically 60–80% of theoretical due to memory bandwidth limits.

### When to Use Array Expressions

Array expressions shine when:
- **Large arrays** — the overhead of the loop setup is amortized over many elements
- **Simple operations** — arithmetic on contiguous arrays maps perfectly to SIMD
- **Hot loops** — replacing inner-loop array operations with expressions saves instruction count

For small arrays (under ~16 elements), the overhead of setting up the SIMD loop may exceed the benefit. The compiler will fall back to scalar code when appropriate.

### Disabling SIMD

If you need to disable NEON acceleration (for debugging or compatibility testing), set the environment variable before compilation:

```bash
ENABLE_NEON_LOOP=0 ./fbc_qbe program.bas
```

The compiler will generate scalar loops instead. The array expression syntax still works — only the generated code changes.

---

## Quick Reference

### Array Operations

| Expression | Meaning |
|---|---|
| `C() = A() + B()` | Element-wise addition |
| `C() = A() - B()` | Element-wise subtraction |
| `C() = A() * B()` | Element-wise multiplication |
| `C() = A() / B()` | Element-wise division |
| `B() = A()` | Whole-array copy |
| `B() = A() + 5` | Scalar broadcast (add 5 to every element) |
| `B() = A() * 2.0` | Scalar broadcast (multiply every element by 2) |
| `A() = 0` | Fill entire array with zero |
| `A() = value` | Fill entire array with value |
| `B() = -A()` | Negate every element |
| `A() = A() + 1` | In-place increment |
| `D() = A() + B() * C()` | Fused multiply-add |

### Reduction Functions

| Expression | Meaning |
|---|---|
| `x = SUM(A())` | Sum of all elements |
| `x = MAX(A())` | Maximum element |
| `x = MIN(A())` | Minimum element |
| `x = AVG(A())` | Arithmetic mean |
| `x = DOT(A(), B())` | Dot product |
| `x = SUMROW(M(), r)` | Sum of row `r` in 2D array `M` |
| `x = SUMCOL(M(), c)` | Sum of column `c` in 2D array `M` |
| `x = MAXROW(M(), r)` | Maximum value in row `r` |
| `x = MAXCOL(M(), c)` | Maximum value in column `c` |
| `C() = MATMUL(A(), B(), m, n, k)` | Matrix multiply (`A[m,k] * B[k,n]`) |
| `x = MAX(a, b)` | Scalar maximum of two values |
| `x = MIN(a, b)` | Scalar minimum of two values |

### Unary Array Functions

| Expression | Meaning |
|---|---|
| `B() = ABS(A())` | Absolute value of every element |
| `B() = SQR(A())` | Square root of every element |
| `B() = EXP(A())` | Exponential ($e^x$) of every element |
| `B() = LOG(A())` | Natural logarithm of every element |
| `B() = SIN(A())` | Sine of every element |
| `B() = COS(A())` | Cosine of every element |
| `B() = TAN(A())` | Tangent of every element |
| `B() = ATAN(A())` | Arctangent of every element |
| `B() = SINH(A())` | Hyperbolic sine of every element |
| `B() = COSH(A())` | Hyperbolic cosine of every element |
| `B() = TANH(A())` | Hyperbolic tangent of every element |

### Binary Math Array Functions

| Expression | Meaning |
|---|---|
| `C() = POW(A(), B())` | Element-wise power |
| `C() = POW(A(), s)` | Array/scalar power |
| `C() = POW(s, B())` | Scalar/array power |
| `C() = ATAN2(Y(), X())` | Element-wise `atan2(y, x)` |
| `C() = ATAN2(Y(), s)` | Array/scalar `atan2` |
| `C() = ATAN2(s, X())` | Scalar/array `atan2` |
| `C() = HYPOT(A(), B())` | Element-wise `sqrt(A^2 + B^2)` |
| `C() = HYPOT(A(), s)` | Array/scalar hypot |
| `C() = HYPOT(s, B())` | Scalar/array hypot |
| `C() = A() * k + b` | Affine transform |
| `C() = CLAMP(A(), lo, hi)` | Clamp each element to `[lo, hi]` |

---

## Implementation Status

All features described in this article are **fully implemented and tested**:

| Feature | Status | NEON Acceleration |
|---|---|---|
| Element-wise +, -, *, / | ✅ Complete | ✅ All numeric types |
| Array copy | ✅ Complete | ✅ All types |
| Scalar broadcast | ✅ Complete | ✅ All numeric types |
| Array fill | ✅ Complete | ✅ All numeric types |
| Negation | ✅ Complete | ✅ All numeric types |
| BYTE arrays (`.16b`) | ✅ Complete | ✅ 16 elements/register |
| SHORT arrays (`.8h`) | ✅ Complete | ✅ 8 elements/register |
| UDT arrays (Vec4, Vec2D) | ✅ Complete | ✅ Per-UDT |
| Fused multiply-add (FMA) | ✅ Complete | ✅ SINGLE/DOUBLE |
| SUM() reduction | ✅ Complete | ✅ macOS Accelerate/vDSP (bulk `DOUBLE` path), scalar fallback otherwise |
| MAX() reduction | ✅ Complete | ✅ macOS Accelerate/vDSP (bulk `DOUBLE` path), scalar fallback otherwise |
| MIN() reduction | ✅ Complete | ✅ macOS Accelerate/vDSP (bulk `DOUBLE` path), scalar fallback otherwise |
| AVG() reduction | ✅ Complete | ✅ macOS Accelerate/vDSP (bulk `DOUBLE` path), scalar fallback otherwise |
| DOT() product | ✅ Complete | ✅ macOS Accelerate/vDSP (bulk `DOUBLE` path), scalar fallback otherwise |
| SUMROW()/MAXROW() 2D reductions | ✅ Complete | ✅ `DOUBLE` rows can use runtime bulk reduction path; scalar fallback otherwise |
| SUMCOL()/MAXCOL() 2D reductions | ✅ Complete | Scalar loop |
| MATMUL() 2D matrix multiply | ✅ Complete | ✅ macOS Accelerate/BLAS (`dgemm`) for large `DOUBLE`; scalar fallback otherwise |
| ABS() element-wise | ✅ Complete | ✅ Float types |
| SQR()/SQRT() element-wise | ✅ Complete | ✅ macOS Accelerate/vForce (bulk `DOUBLE` path) |
| EXP()/LOG() element-wise | ✅ Complete | ✅ macOS Accelerate/vForce (bulk `DOUBLE` path) |
| SIN()/COS()/TAN() element-wise | ✅ Complete | ✅ macOS Accelerate/vForce (bulk `DOUBLE` path) |
| ATAN() element-wise | ✅ Complete | ✅ macOS Accelerate/vForce (bulk `DOUBLE` path) |
| SINH()/COSH()/TANH() element-wise | ✅ Complete | ✅ macOS Accelerate/vForce (bulk `DOUBLE` path) |
| POW() whole-array forms | ✅ Complete | ✅ macOS Accelerate/vForce for array/array `DOUBLE`; scalar fallback otherwise |
| ATAN2() whole-array forms | ✅ Complete | ✅ macOS Accelerate/vForce for array/array `DOUBLE`; scalar fallback otherwise |
| HYPOT() whole-array forms | ✅ Complete | ✅ macOS Accelerate (vDSP + vForce) for `DOUBLE`; scalar fallback otherwise |
| Affine `A()*k+b` whole-array pattern | ✅ Complete | ✅ macOS Accelerate/vDSP (`vDSP_vsmsaD`) for large `DOUBLE` arrays |
| CLAMP() whole-array form | ✅ Complete | ✅ macOS Accelerate/vDSP (`vDSP_vclipD`) for large `DOUBLE` arrays |
| Scalar MAX(a, b) / MIN(a, b) | ✅ Complete | — |

The test suite (`tests/array_expr/`) contains 7 test files covering all operations, edge cases, NEON opcodes, UDT types, and the features listed above.

---

## Compatibility

| Platform | SIMD Acceleration | Scalar Fallback |
|---|---|---|
| macOS ARM64 (Apple Silicon) | ✅ NEON + ✅ Accelerate/vForce (bulk unary/binary math `DOUBLE`) + ✅ Accelerate/vDSP (bulk reduction `DOUBLE`) | ✅ |
| Linux ARM64 | ✅ NEON | ✅ |
| x86_64 (Intel/AMD) | ❌ (future SSE/AVX) | ✅ |
| RISC-V | ❌ (future RVV) | ✅ |

Array expressions work on all platforms. SIMD acceleration is currently available on ARM64 only. On other platforms, the compiler generates an efficient scalar loop.

---

## Tips

1. **Use `()` consistently** — always include the empty parentheses to make array operations obvious in your code.

2. **Prefer array expressions over FOR loops** — the compiler can vectorize both, but array expressions are clearer and easier to optimize.

3. **Keep element types consistent** — don't mix `SINGLE` and `DOUBLE` arrays in the same expression. Convert first if needed.

4. **Use `SINGLE` for best throughput** — 32-bit floats pack 4 per NEON register versus 2 for `DOUBLE`. Use `SINGLE` unless you need the precision.

5. **Use `BYTE` for massive throughput** — 8-bit elements pack 16 per NEON register. Ideal for image processing and byte-level data.

6. **Exploit FMA** — when you need `A + B * C`, write it as a single expression. The compiler will emit a fused multiply-add with no intermediate rounding.

7. **Array fill is fast** — `A() = 0` is significantly faster than a FOR loop for zeroing large arrays.

8. **Check your types** — array expressions require matching element types. The compiler will report an error if types don't match.

9. **Use reductions** — `SUM(A())`, `MAX(A())`, and friends are cleaner and less error-prone than hand-written accumulator loops.

---

## Further Reading

- [NEON SIMD Support](neon-simd-support.md) — how automatic vectorization works under the hood
- [Classes and Objects](classes-and-objects.md) — UDTs that benefit from SIMD
- [Quick Reference](../docs/FasterBASIC_QuickRef.md) — complete syntax reference