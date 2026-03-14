# NEON SIMD Support in FasterBASIC

*Automatic vectorization for ARM64 — write normal BASIC, get parallel hardware acceleration for free.*

---

## Introduction

FasterBASIC now supports **ARM64 NEON SIMD** (Single Instruction, Multiple Data) acceleration for User-Defined Types (UDTs). When you define a type whose fields are all the same numeric type — like a 3D vector, a color, or a complex number — the compiler automatically detects this and emits NEON instructions that operate on all fields simultaneously using 128-bit hardware registers.

You don't need to learn any new syntax or call special functions. Write your BASIC code normally, and FasterBASIC handles the rest.

---

## What Gets Accelerated?

Three categories of operations are automatically vectorized:

| Operation | What It Does | Speedup |
|-----------|-------------|---------|
| **Bulk Copy** | `B = A` for eligible UDTs | Up to 4× fewer instructions |
| **Element-Wise Arithmetic** | `C = A + B` on whole UDTs | Up to 3× fewer instructions |
| **Array Loop Vectorization** | `FOR` loops over UDT arrays | Up to 4–6× fewer instructions |

All three work transparently. The compiler chooses NEON when it's safe and beneficial, and falls back to scalar code otherwise.

---

## Getting Started

### 1. Build the Compiler

```
cd qbe_basic_integrated
./build_qbe_basic.sh
```

The integrated `fbc_qbe` compiler includes full NEON support on ARM64 targets (Apple Silicon, Raspberry Pi 4/5, AWS Graviton, etc.).

### 2. Write a SIMD-Eligible Type

A UDT qualifies for NEON acceleration when **all of its fields are the same numeric type** and the total size fits in a 128-bit register:

```
TYPE Vec4
    X AS INTEGER
    Y AS INTEGER
    Z AS INTEGER
    W AS INTEGER
END TYPE
```

That's it. The compiler classifies `Vec4` as SIMD-eligible automatically at compile time — no annotations, pragmas, or special keywords needed.

### 3. Use Normal BASIC Operations

```
DIM A AS Vec4, B AS Vec4, C AS Vec4

A.X = 10 : A.Y = 20 : A.Z = 30 : A.W = 40
B.X = 1  : B.Y = 2  : B.Z = 3  : B.W = 4

C = A + B

PRINT C.X; ","; C.Y; ","; C.Z; ","; C.W
' Output: 11, 22, 33, 44
```

Behind the scenes, `C = A + B` compiles to just four ARM64 instructions:

```
ldr  q28, [x0]              ; load all 4 fields of A into one 128-bit register
ldr  q29, [x1]              ; load all 4 fields of B
add  v28.4s, v28.4s, v29.4s ; add all 4 pairs in parallel
str  q28, [x2]              ; store all 4 fields of C
```

Without NEON, the same operation requires 12 separate instructions (4 loads + 4 loads + 4 adds, plus individual stores).

---

## Eligible UDT Types

The following type patterns are automatically recognized and mapped to NEON register configurations:

| Fields | Base Type | Example | NEON Arrangement | Register |
|--------|-----------|---------|------------------|----------|
| 2 | `DOUBLE` | Complex numbers | `v.2d` | Q (128-bit) |
| 2 | `LONG` / `ULONG` | 64-bit coordinate pairs | `v.2d` | Q (128-bit) |
| 4 | `INTEGER` | 3D/4D vectors, RGBA pixels | `v.4s` | Q (128-bit) |
| 4 | `SINGLE` | Float vectors, colors | `v.4s` | Q (128-bit) |
| 8 | `SHORT` | Packed small integers | `v.8h` | Q (128-bit) |
| 16 | `BYTE` | Pixel data, byte arrays | `v.16b` | Q (128-bit) |
| 2 | `INTEGER` / `SINGLE` | 2D vectors | `v.2s` | D (64-bit) |
| 3 | `INTEGER` / `SINGLE` | 3D vectors (auto-padded to 4 lanes) | `v.4s` | Q (128-bit) |

### Types That Do NOT Qualify

A UDT is **not** eligible for NEON when:

- It contains mixed types (e.g., `INTEGER` and `DOUBLE` fields together)
- It contains `STRING`, `UNICODE`, or other pointer-based types
- It contains nested UDTs
- Its total size exceeds 128 bits (16 bytes)

In these cases, the compiler silently uses standard scalar code — your program still works correctly, just without SIMD acceleration.

---

## Complete Examples

### Example 1: Bulk UDT Copy

The simplest NEON optimization — copying an entire UDT in a single load/store pair instead of field by field:

```
TYPE Vec2D
    X AS DOUBLE
    Y AS DOUBLE
END TYPE

DIM source AS Vec2D
DIM dest AS Vec2D

source.X = 3.14159
source.Y = 2.71828

' This assignment uses a NEON 128-bit load + store
dest = source

PRINT "Copied: "; dest.X; ", "; dest.Y
' Output: Copied: 3.14159, 2.71828
```

**What the compiler generates:** 2 instructions (load Q register, store Q register) instead of 4 scalar instructions.

### Example 2: Element-Wise Arithmetic

All four basic arithmetic operations are supported for whole-UDT expressions:

```
TYPE Vec4F
    X AS SINGLE
    Y AS SINGLE
    Z AS SINGLE
    W AS SINGLE
END TYPE

DIM A AS Vec4F, B AS Vec4F, C AS Vec4F

A.X = 10.0 : A.Y = 20.0 : A.Z = 30.0 : A.W = 40.0
B.X = 2.0  : B.Y = 4.0  : B.Z = 5.0  : B.W = 8.0

' Addition — uses NEON fadd v28.4s, v28.4s, v29.4s
C = A + B
PRINT "Add: "; C.X; ","; C.Y; ","; C.Z; ","; C.W
' Output: Add: 12.0, 24.0, 35.0, 48.0

' Subtraction — uses NEON fsub
C = A - B
PRINT "Sub: "; C.X; ","; C.Y; ","; C.Z; ","; C.W
' Output: Sub: 8.0, 16.0, 25.0, 32.0

' Multiplication — uses NEON fmul
C = A * B
PRINT "Mul: "; C.X; ","; C.Y; ","; C.Z; ","; C.W
' Output: Mul: 20.0, 80.0, 150.0, 320.0

' Division — uses NEON fdiv (float types only)
C = A / B
PRINT "Div: "; C.X; ","; C.Y; ","; C.Z; ","; C.W
' Output: Div: 5.0, 5.0, 6.0, 5.0
```

**Supported operators:**

| Operator | Integer UDTs | Float UDTs |
|----------|:----------:|:----------:|
| `+` | ✅ | ✅ |
| `-` | ✅ | ✅ |
| `*` | ✅ | ✅ |
| `/` | scalar fallback | ✅ |

Integer division has no direct NEON instruction, so it falls back to scalar code automatically.

### Example 3: Self-Assignment Arithmetic

The compiler correctly handles operations where the result is stored back into one of the operands:

```
TYPE Vec4
    X AS INTEGER
    Y AS INTEGER
    Z AS INTEGER
    W AS INTEGER
END TYPE

DIM position AS Vec4
DIM velocity AS Vec4

position.X = 100 : position.Y = 200 : position.Z = 300 : position.W = 0
velocity.X = 5   : velocity.Y = -3  : velocity.Z = 1   : velocity.W = 0

' Update position in-place — safe even though source and dest overlap
position = position + velocity

PRINT position.X; ","; position.Y; ","; position.Z; ","; position.W
' Output: 105, 197, 301, 0
```

### Example 4: Array Loop Vectorization

The biggest performance win comes from array loops. When the compiler detects a `FOR` loop that performs element-wise operations on arrays of SIMD-eligible UDTs, it vectorizes the entire loop:

```
TYPE Vec4
    X AS INTEGER
    Y AS INTEGER
    Z AS INTEGER
    W AS INTEGER
END TYPE

DIM positions(999) AS Vec4
DIM velocities(999) AS Vec4

' Initialize arrays
FOR i% = 0 TO 999
    positions(i%).X = i% * 10
    positions(i%).Y = i% * 20
    positions(i%).Z = i% * 30
    positions(i%).W = i% * 40
    velocities(i%).X = 1
    velocities(i%).Y = 2
    velocities(i%).Z = 3
    velocities(i%).W = 4
NEXT i%

' This loop is automatically vectorized with NEON
' Each iteration: 4 instructions instead of 16
FOR i% = 0 TO 999
    positions(i%) = positions(i%) + velocities(i%)
NEXT i%

' Verify
PRINT positions(5).X; ","; positions(5).Y; ","; positions(5).Z; ","; positions(5).W
' Output: 51, 102, 153, 204
```

**Generated assembly for the inner loop:**

```
ldr   q28, [x1, x3]          ; load positions(i) — all 4 fields at once
ldr   q29, [x2, x3]          ; load velocities(i)
add   v28.4s, v28.4s, v29.4s ; parallel add across all 4 lanes
str   q28, [x1, x3]          ; store result back to positions(i)
add   x3, x3, #16            ; advance to next element
cmp   x3, x4
b.lt  .Lloop
```

That's **4 data instructions per iteration** versus 16 with scalar code — a **4× reduction**.

### Example 5: Double-Precision Complex Arithmetic

NEON works with `DOUBLE` types too, using the `v.2d` (two 64-bit lane) arrangement:

```
TYPE Complex
    Real AS DOUBLE
    Imag AS DOUBLE
END TYPE

DIM A AS Complex, B AS Complex, C AS Complex

A.Real = 3.0 : A.Imag = 4.0
B.Real = 1.0 : B.Imag = 2.0

' Complex addition — NEON fadd v.2d
C = A + B
PRINT "Sum: "; C.Real; " + "; C.Imag; "i"
' Output: Sum: 4.0 + 6.0i

' Complex subtraction
C = A - B
PRINT "Diff: "; C.Real; " + "; C.Imag; "i"
' Output: Diff: 2.0 + 2.0i
```

---

## Performance Impact

### Instruction Count Reduction

| Operation | Scalar Instructions | NEON Instructions | Speedup |
|-----------|:------------------:|:-----------------:|:-------:|
| Copy Vec4 (4×32-bit) | 8 | 2 | **4×** |
| Copy Vec2D (2×64-bit) | 4 | 2 | **2×** |
| Add Vec4 | 12 | 4 | **3×** |
| Add Vec4 in array loop | 16/iteration | 4/iteration | **4×** |
| Add Vec4 array (×2 unroll) | 16/iteration | 2.5/iteration | **6.4×** |

### Real-World Scenario

For a typical particle system updating 1,000 `Vec4` elements per frame:

| Path | Data Instructions | Loop Overhead | Total |
|------|:-----------------:|:------------:|:-----:|
| Scalar | ~16,000 | ~3,000 | ~19,000 |
| NEON | ~4,000 | ~3,000 | ~7,000 |
| NEON + unroll | ~2,500 | ~1,500 | ~4,000 |

That's up to **4.75× fewer instructions** for a hot loop — a meaningful improvement for games, simulations, and data processing.

---

## The Kill-Switch: Disabling NEON

Every NEON optimization can be individually disabled via environment variables. This is useful for debugging, benchmarking, or verifying that your program produces correct results on both paths.

| Environment Variable | Default | Controls |
|---------------------|---------|----------|
| `ENABLE_NEON_COPY` | `1` (enabled) | Bulk UDT copy via NEON |
| `ENABLE_NEON_ARITH` | `1` (enabled) | Element-wise arithmetic via NEON |
| `ENABLE_NEON_LOOPS` | `1` (enabled) | Array loop vectorization via NEON |

### Usage

```
# Compile normally (NEON enabled by default)
./fbc_qbe -o myprogram mycode.bas

# Compile with NEON arithmetic disabled — scalar fallback used
ENABLE_NEON_ARITH=0 ./fbc_qbe -o myprogram_scalar mycode.bas

# Compile with ALL NEON disabled
ENABLE_NEON_COPY=0 ENABLE_NEON_ARITH=0 ENABLE_NEON_LOOP=0 ./fbc_qbe -o myprogram_nonneon mycode.bas
```

Both binaries should produce identical output. If they don't, that's a bug — please report it!

---

## Verifying NEON Is Active

You can inspect the generated assembly to confirm NEON instructions are being emitted:

```
# Generate assembly output
./fbc_qbe -c -o output.s mycode.bas

# Look for NEON instructions
grep -E 'ldr\s+q2[89]|str\s+q2[89]|add\s+v2[89]|fadd\s+v2[89]|fmul\s+v2[89]|fdiv\s+v2[89]' output.s
```

If you see instructions referencing `q28`, `q29`, `v28`, or `v29` with arrangement suffixes like `.4s` or `.2d`, NEON vectorization is active.

### Running the NEON Test Suite

FasterBASIC ships with a comprehensive NEON test suite (19 test files, 244 assertions):

```
# Run all NEON tests
./scripts/run_neon_tests.sh

# Run with assembly verification
./scripts/run_neon_tests.sh --asm

# Run with kill-switch validation
./scripts/run_neon_tests.sh --killswitch

# Run everything
./scripts/run_neon_tests.sh --all
```

---

## How It Works Under the Hood

The NEON pipeline has three stages:

### Stage 1: SIMD Classification (Semantic Analysis)

When the compiler processes a `TYPE...END TYPE` declaration, it checks whether all fields share the same base numeric type and whether the total size fits in a NEON register. If so, it attaches a `SIMDInfo` descriptor to the type symbol containing the lane count, arrangement (`.4s`, `.2d`, etc.), and register width.

### Stage 2: Pattern Detection (Code Generation)

During code generation, the `ASTEmitter` checks every UDT assignment:

- **Is it a plain copy?** → Emit `neonldr` + `neonstr` (bulk copy)
- **Is it a binary expression (`A + B`, `A * B`, etc.) where both operands are the same SIMD-eligible UDT?** → Emit `neonldr` + `neonldr2` + `neonadd`/`neonsub`/`neonmul`/`neondiv` + `neonstr`
- **Is it inside a `FOR` loop over arrays of SIMD-eligible UDTs?** → Vectorize the entire loop

If none of these patterns match, the compiler falls through to the standard scalar path.

### Stage 3: NEON Code Emission (QBE Backend)

The QBE backend recognizes custom NEON opcodes in the intermediate language and emits the corresponding ARM64 NEON assembly instructions. The compiler reserves registers V28–V30 as dedicated NEON scratch registers, keeping them out of the general register allocator.

The generated NEON instructions go through the same optimization pipeline as all other code, with special care taken to ensure:

- NEON stores are recognized as memory writes by the load eliminator and alias analysis
- MADD (multiply-add) fusion does not clobber registers that are live across basic blocks
- Register allocation respects the reserved V28–V30 range

---

## Common Patterns and Best Practices

### ✅ Do: Use Uniform Types

All fields should be the same base type for NEON eligibility:

```
' GOOD — all INTEGER, maps to v.4s
TYPE Vec4
    X AS INTEGER
    Y AS INTEGER
    Z AS INTEGER
    W AS INTEGER
END TYPE

' GOOD — all SINGLE, maps to v.4s (float)
TYPE Color
    R AS SINGLE
    G AS SINGLE
    B AS SINGLE
    A AS SINGLE
END TYPE

' GOOD — all DOUBLE, maps to v.2d
TYPE Complex
    Real AS DOUBLE
    Imag AS DOUBLE
END TYPE
```

### ❌ Don't: Mix Types

```
' NOT SIMD-eligible — mixed types
TYPE Record
    ID AS INTEGER
    Value AS DOUBLE
    Name AS STRING
END TYPE
```

This type will still work perfectly, but all operations will use scalar code.

### ✅ Do: Use Whole-UDT Expressions

```
' GOOD — detected as vectorizable
C = A + B
D = A * B
positions(i%) = positions(i%) + velocities(i%)
```

### ❌ Don't: Expect Field-Level Expressions to Vectorize

```
' Not vectorized (individual field assignments, not a whole-UDT expression)
C.X = A.X + B.X
C.Y = A.Y + B.Y
C.Z = A.Z + B.Z
C.W = A.W + B.W
```

While these produce correct results, the compiler currently only vectorizes whole-UDT binary expressions (`C = A + B`). Write your code using whole-UDT operations to get the NEON benefit.

### ✅ Do: Keep Loop Bodies Simple

```
' GOOD — pure element-wise operation, vectorizable
FOR i% = 0 TO 999
    result(i%) = source_a(i%) + source_b(i%)
NEXT i%
```

### ❌ Don't: Put Function Calls or Branches in Vectorized Loops

```
' NOT vectorized — contains a function call
FOR i% = 0 TO 999
    result(i%) = transform(source_a(i%)) + source_b(i%)
NEXT i%
```

Function calls may clobber the NEON scratch registers, so loops with calls use scalar code.

---

## Platform Compatibility

| Platform | NEON Support | Notes |
|----------|:----------:|-------|
| macOS ARM64 (Apple Silicon) | ✅ | Full support |
| Linux ARM64 (Raspberry Pi 4/5, Graviton) | ✅ | Full support |
| macOS x86_64 (Intel Mac) | — | Scalar fallback (future: SSE/AVX) |
| Linux x86_64 | — | Scalar fallback (future: SSE/AVX) |
| RISC-V 64 | — | Scalar fallback (future: RVV) |

On non-ARM64 platforms, the SIMD classification still runs (so the compiler reports the same diagnostics), but no NEON instructions are emitted. Your programs will compile and run correctly everywhere — just without the SIMD speedup.

---

## Troubleshooting

### "My UDT isn't being vectorized"

Check that:
1. All fields are the **same** base type (`INTEGER`, `SINGLE`, `DOUBLE`, etc.)
2. There are no `STRING`, `UNICODE`, or nested UDT fields
3. The total size is ≤ 16 bytes (128 bits)
4. You're targeting ARM64 (compile on an Apple Silicon Mac or ARM Linux)
5. The kill-switch environment variable isn't set to `0`

### "Results differ between NEON and scalar paths"

This is a bug. Run the kill-switch test to confirm:

```
# Compile with NEON
./fbc_qbe -o test_neon mycode.bas

# Compile without NEON
ENABLE_NEON_COPY=0 ENABLE_NEON_ARITH=0 ENABLE_NEON_LOOP=0 ./fbc_qbe -o test_scalar mycode.bas

# Compare output
diff <(./test_neon) <(./test_scalar)
```

If the outputs differ, please file an issue with the test case.

### "Float comparisons are fragile"

When comparing floating-point results, use tolerance-based checks instead of exact equality:

```
' Fragile — may fail due to floating-point representation
IF result.X = 3.14159 THEN PRINT "PASS"

' Robust — allows for floating-point imprecision
IF result.X > 3.141 AND result.X < 3.142 THEN PRINT "PASS"
```

This is general floating-point advice, not specific to NEON, but it becomes more visible when SINGLE-precision NEON lanes are compared against DOUBLE-precision literals.

---

## Further Reading

- **[Classes and Objects](classes-and-objects.md)** — The full CLASS system: fields, methods, inheritance, constructors, destructors, and virtual dispatch
- **[Lists and MATCH TYPE](lists-and-match-type.md)** — Heterogeneous collections and safe type dispatch for mixed-type data
- **[FasterBasicNeon.md](../FasterBasicNeon.md)** — Full technical design document with implementation details, QBE IL examples, and architecture diagrams
- **[tests/neon/](../tests/neon/)** — Complete NEON test suite (19 test files, 244 assertions)
- **[scripts/run_neon_tests.sh](../scripts/run_neon_tests.sh)** — Automated test runner with assembly verification and kill-switch testing
- **[README.md](../README.md)** — Project overview and quick start guide

---

*FasterBASIC NEON support was built on top of the QBE compiler backend with custom opcodes for NEON load, store, and arithmetic operations. The implementation spans the FasterBASIC frontend (pattern detection and IL emission) and the QBE backend (instruction selection and ARM64 code generation), with dedicated fixes for MADD fusion safety, UDT array-element copy semantics, and scalar fallback paths.*