# User-Defined Types in FasterBASIC

*Value types with a proper constructor — define your data, CREATE it in one line, and let the compiler handle the layout, the copies, and the SIMD.*

---

## Introduction

FasterBASIC supports **User-Defined Types** (UDTs) — composite value types that group related fields into a single named structure. A UDT is declared once with `TYPE ... END TYPE` and then used like any built-in type: you can DIM variables, access fields with dot notation, pass them to functions, store them in arrays, and perform element-wise arithmetic on them.

With the new **`CREATE`** expression, you can now initialize a UDT in a single statement instead of assigning each field one by one. CREATE is to TYPEs what NEW is to CLASSes — but for stack-allocated value types rather than heap-allocated objects.

```
TYPE TPoint
  X AS INTEGER
  Y AS INTEGER
END TYPE

DIM P AS TPoint = CREATE TPoint(10, 20)
PRINT P.X   ' 10
PRINT P.Y   ' 20
```

No more boilerplate. One line, all fields initialized, type-checked at compile time.

---

## Defining a Type

A TYPE declaration lists the fields and their types. Field types can be any built-in type or another UDT:

```
TYPE TPerson
  Name AS STRING
  Age AS INTEGER
END TYPE

TYPE TVec3
  X AS DOUBLE
  Y AS DOUBLE
  Z AS DOUBLE
END TYPE

TYPE TColor
  R AS SINGLE
  G AS SINGLE
  B AS SINGLE
  A AS SINGLE
END TYPE

TYPE TRect
  TopLeft AS TPoint
  BottomRight AS TPoint
END TYPE
```

A few conventions worth noting:

- **T-prefixed names** (TPoint, TPerson, TVec3) are recommended to keep type names visually distinct from variable names and to avoid any chance of clashing with built-in keywords. This is a convention, not a requirement.
- **Nested UDTs** work naturally. `TRect` contains two `TPoint` fields, and the compiler handles the layout automatically.
- **All built-in numeric types** are supported: INTEGER, LONG, SINGLE, DOUBLE, BYTE, SHORT. STRING fields store managed string descriptors with automatic reference counting.

---

## CREATE — The Value-Type Constructor

### Before CREATE

Without CREATE, initializing a UDT required declaring the variable and then assigning each field individually:

```
DIM P AS TPoint
P.X = 10
P.Y = 20
```

This works, but it's verbose — especially for types with many fields — and the variable briefly exists in a partially initialized state between the DIM and the last assignment.

### With CREATE (Positional)

CREATE initializes all fields in one expression:

```
DIM P AS TPoint = CREATE TPoint(10, 20)
```

Arguments are positional, mapped to fields in declaration order. The compiler verifies that the argument count matches the field count and applies type coercion where necessary (for example, a double literal stored into a SINGLE field is automatically narrowed with `truncd`).

### With CREATE (Named Fields)

For types with many fields, positional arguments become hard to read. Named-field syntax makes the intent explicit and allows fields in any order:

```
DIM P AS TPerson = CREATE TPerson(Name := "Alice", Age := 30)
```

Each argument is written as `FieldName := Expression`. The compiler resolves each name against the TYPE definition and stores the value at the correct offset regardless of the order you write them.

**Reordering** — fields can appear in any order:

```
DIM P AS TPoint = CREATE TPoint(Y := 20, X := 10)
' P.X = 10, P.Y = 20 — same as CREATE TPoint(10, 20)
```

**Partial initialization** — you can omit fields. Unmentioned fields are zero-initialized (0 for numeric types, empty string for STRING):

```
DIM P AS TPoint = CREATE TPoint(X := 50)
' P.X = 50, P.Y = 0

DIM Per AS TPerson = CREATE TPerson(Name := "Charlie")
' Per.Name = "Charlie", Per.Age = 0

DIM Per2 AS TPerson = CREATE TPerson(Age := 40)
' Per2.Name = "", Per2.Age = 40
```

**Zero-initialization** — `CREATE TypeName()` with no arguments zero-initializes all fields:

```
DIM Origin AS TPoint = CREATE TPoint()
' Origin.X = 0, Origin.Y = 0
```

**Expressions** — named-field values can be any expression, not just literals:

```
DIM A AS INTEGER = 5
DIM B AS INTEGER = 7
DIM P AS TPoint = CREATE TPoint(Y := B + 3, X := A * 2)
' P.X = 10, P.Y = 10
```

**Consistency rule** — you cannot mix positional and named arguments in the same CREATE call. The compiler reports an error if you try:

```
' OK — all positional
DIM P1 AS TPoint = CREATE TPoint(10, 20)

' OK — all named
DIM P2 AS TPoint = CREATE TPoint(X := 10, Y := 20)

' ERROR — mixed positional and named
' DIM P3 AS TPoint = CREATE TPoint(10, Y := 20)
```

### CREATE vs NEW

FasterBASIC has two constructor-style expressions, each for a different kind of type:

| | `CREATE` | `NEW` |
|---|---|---|
| **Used with** | TYPE (value types) | CLASS (reference types) |
| **Allocation** | Stack (or global data section) | Heap |
| **Semantics** | Value — copied on assignment | Reference — shared on assignment |
| **Lifetime** | Automatic (scope-based) | Managed by SAMM (GC) |
| **Syntax** | `CREATE TPoint(10, 20)` | `NEW Greeter("World")` |

The rule is simple: if you defined it with `TYPE`, use `CREATE`. If you defined it with `CLASS`, use `NEW`.

---

## Using CREATE

### DIM with Initializer

The most common pattern — declare and initialize in one statement. Works with both positional and named syntax:

```
DIM V AS TVec3 = CREATE TVec3(1.5, 2.5, 3.5)
DIM C AS TColor = CREATE TColor(1.0, 0.5, 0.25, 1.0)
DIM P AS TPerson = CREATE TPerson("Alice", 30)

' Named equivalents:
DIM V2 AS TVec3 = CREATE TVec3(X := 1.5, Y := 2.5, Z := 3.5)
DIM P2 AS TPerson = CREATE TPerson(Name := "Alice", Age := 30)
```

### Assignment

CREATE works in plain assignment too, not just DIM:

```
DIM Q AS TPoint
Q = CREATE TPoint(100, 200)

' Re-assign with new values
Q = CREATE TPoint(300, 400)
```

### Nested UDT Member Assignment

You can CREATE directly into a nested UDT field:

```
DIM R AS TRect
R.TopLeft = CREATE TPoint(0, 0)
R.BottomRight = CREATE TPoint(640, 480)
```

The compiler emits a field-by-field copy from the CREATE temporary into the nested field — no pointer aliasing, no surprises.

### Expression Arguments

CREATE arguments can be any expression, not just literals:

```
DIM A AS INTEGER = 5
DIM B AS INTEGER = 7
DIM EP AS TPoint = CREATE TPoint(A * 2, B + 3)
' EP.X = 10, EP.Y = 10
```

String expressions, function calls, and member accesses all work:

```
DIM first$ AS STRING = "Bob"
DIM last$ AS STRING = "Smith"
DIM P AS TPerson = CREATE TPerson(first$ + " " + last$, 25)
' P.Name = "Bob Smith"

DIM V AS TVec3 = CREATE TVec3(SIN(0), COS(0), SQR(4))
' V.X = 0, V.Y = 1, V.Z = 2

DIM Origin AS TPoint = CREATE TPoint(0, 0)
DIM Offset AS TPoint = CREATE TPoint(Origin.X + 50, Origin.Y + 75)
```

### Multiple Instances

Create as many instances as you like — each is independent:

```
DIM P1 AS TPerson = CREATE TPerson("Charlie", 40)
DIM P2 AS TPerson = CREATE TPerson("Diana", 35)

' Modifying one doesn't affect the other
P1.Age = 41
PRINT P2.Age   ' still 35
```

---

## Field Access and Assignment

Fields are accessed with dot notation. Nested fields chain naturally:

```
DIM R AS TRect
R.TopLeft = CREATE TPoint(10, 20)
R.BottomRight = CREATE TPoint(100, 200)

PRINT R.TopLeft.X       ' 10
PRINT R.BottomRight.Y   ' 200

R.TopLeft.X = 15        ' modify a nested field
```

---

## Value Semantics

UDTs are **value types**. Assignment copies all fields — the two variables are independent after the copy:

```
DIM Src AS TPoint = CREATE TPoint(42, 99)
DIM Dst AS TPoint
Dst = Src

Dst.X = 999
PRINT Src.X   ' still 42 — Src is unmodified
PRINT Dst.X   ' 999
```

String fields are reference-counted. When you copy a UDT containing strings, the string's reference count is incremented — the string data itself is shared until one side modifies it. This is handled automatically.

---

## UDT Arithmetic

For UDTs whose fields are all the same numeric type (no strings, no nested UDTs), the compiler supports **element-wise arithmetic** on whole UDT values:

```
TYPE TVec4
  X AS INTEGER
  Y AS INTEGER
  Z AS INTEGER
  W AS INTEGER
END TYPE

DIM A AS TVec4, B AS TVec4, C AS TVec4
A = CREATE TVec4(1, 2, 3, 4)
B = CREATE TVec4(10, 20, 30, 40)

C = A + B   ' C = (11, 22, 33, 44)
C = A - B   ' element-wise subtraction
C = A * B   ' element-wise multiplication
C = A / B   ' element-wise division (float types only)
```

The compiler detects the pattern and emits field-by-field arithmetic. On ARM64, if the UDT is SIMD-eligible (≤128 bits, uniform numeric fields), it automatically emits **NEON vector instructions** that process all fields in parallel — typically 3–4× fewer instructions than scalar code.

See the [NEON SIMD Support](neon-simd-support.md) article for details on which types qualify and how to check.

---

## Equality Comparison

UDTs support **field-by-field equality comparison** with the `=` and `<>` operators. The compiler generates short-circuit evaluation — as soon as a field mismatch is found, remaining fields are skipped:

```
DIM A AS TPoint = CREATE TPoint(10, 20)
DIM B AS TPoint = CREATE TPoint(10, 20)
DIM C AS TPoint = CREATE TPoint(99, 20)

IF A = B THEN PRINT "equal"       ' prints "equal"
IF A <> C THEN PRINT "different"  ' prints "different"
```

All field types are handled correctly:

- **Numeric fields** (INTEGER, LONG, SINGLE, DOUBLE, BYTE, SHORT) use the appropriate QBE comparison for their type.
- **String fields** are compared by value via `string_compare` — two strings with the same content are equal even if they are different objects.
- **Nested UDTs** are compared recursively, field by field, with the same short-circuit behavior.

```
TYPE TPerson
  Name AS STRING
  Age AS INTEGER
END TYPE

DIM P1 AS TPerson = CREATE TPerson("Alice", 30)
DIM P2 AS TPerson = CREATE TPerson("Alice", 30)
DIM P3 AS TPerson = CREATE TPerson("Bob", 30)

IF P1 = P2 THEN PRINT "same person"    ' true — same name and age
IF P1 <> P3 THEN PRINT "different"     ' true — name differs
```

Nested UDT comparison works naturally:

```
TYPE TRect
  TopLeft AS TPoint
  BottomRight AS TPoint
END TYPE

DIM R1 AS TRect
R1.TopLeft = CREATE TPoint(0, 0)
R1.BottomRight = CREATE TPoint(100, 200)

DIM R2 AS TRect
R2.TopLeft = CREATE TPoint(0, 0)
R2.BottomRight = CREATE TPoint(100, 200)

IF R1 = R2 THEN PRINT "same rect"   ' true — all nested fields match
```

Copy semantics are preserved — a copied UDT compares equal to the original, and modifying the copy makes them unequal:

```
DIM Src AS TPoint = CREATE TPoint(42, 99)
DIM Dst AS TPoint
Dst = Src

IF Src = Dst THEN PRINT "equal after copy"   ' true

Dst.X = 999
IF Src <> Dst THEN PRINT "different after modify"  ' true
```

---

## PRINT Whole UDT

You can `PRINT` an entire UDT value. The compiler generates a debug-friendly representation showing the type name and all field values:

```
DIM P AS TPoint = CREATE TPoint(10, 20)
PRINT P
' Output: TPoint(10, 20)
```

String fields are printed with surrounding double-quotes:

```
DIM Per AS TPerson = CREATE TPerson("Alice", 30)
PRINT Per
' Output: TPerson("Alice", 30)
```

Mixed-type UDTs show each field in its natural format:

```
TYPE TMixed
  ID AS INTEGER
  Label AS STRING
  Score AS DOUBLE
END TYPE

DIM M AS TMixed = CREATE TMixed(42, "hello", 3.14)
PRINT M
' Output: TMixed(42, "hello", 3.14)
```

Nested UDTs are printed recursively:

```
DIM R AS TRect
R.TopLeft = CREATE TPoint(0, 0)
R.BottomRight = CREATE TPoint(640, 480)
PRINT R
' Output: TRect(TPoint(0, 0), TPoint(640, 480))
```

PRINT works inline with other items as you'd expect:

```
PRINT "Position: "; P
' Output: Position: TPoint(10, 20)
```

This is especially useful during development and debugging — no more writing per-field PRINT statements to inspect UDT values.

---

## Arrays of UDTs

UDTs work naturally in arrays:

```
DIM Points(100) AS TPoint

FOR I = 0 TO 100
  Points(I) = CREATE TPoint(I * 10, I * 20)
NEXT I

PRINT Points(5).X   ' 50
PRINT Points(5).Y   ' 100
```

Array elements support member access and assignment:

```
Points(0).X = 999
Points(50) = CREATE TPoint(42, 42)
```

Whole-array operations work on UDT arrays too — see the [Array Expressions](array-expressions.md) article.

---

## Passing UDTs to Functions

UDTs are passed to FUNCTION and SUB **by reference** (the compiler passes a pointer internally). This means modifications inside the function affect the caller's variable:

```
SUB MoveRight(P AS TPoint, Amount AS INTEGER)
  P.X = P.X + Amount
END SUB

DIM Pos AS TPoint = CREATE TPoint(10, 20)
MoveRight Pos, 5
PRINT Pos.X   ' 15
```

Functions can return UDTs:

```
FUNCTION MakePoint(X AS INTEGER, Y AS INTEGER) AS TPoint
  DIM P AS TPoint = CREATE TPoint(X, Y)
  RETURN P
END FUNCTION
```

---

## SIMD Auto-Detection

When you define a UDT whose fields are all the same numeric type and the total size fits in a 128-bit NEON register, the compiler prints a diagnostic at compile time:

```
[SIMD] Detected NEON-eligible type: TPoint [2s] (2×32b, D-reg, int)
[SIMD] Detected NEON-eligible type: TColor [4s] (4×32b, Q-reg, float)
```

This means bulk copies and arithmetic on these types will use NEON instructions automatically. You don't need to do anything special — just define your types and use them normally.

Eligible configurations include:

| Layout | Example | Register |
|--------|---------|----------|
| 2 × 32-bit int | `TPoint` (X, Y AS INTEGER) | D-register (64-bit) |
| 4 × 32-bit int | `TVec4` (X, Y, Z, W AS INTEGER) | Q-register (128-bit) |
| 4 × 32-bit float | `TColor` (R, G, B, A AS SINGLE) | Q-register (128-bit) |
| 2 × 64-bit float | `TComplex` (Re, Im AS DOUBLE) | Q-register (128-bit) |
| 3 × 32-bit (padded) | `TVec3` (X, Y, Z AS SINGLE) | Q-register (padded to 4 lanes) |

---

## Complete Example

Here's a small program that uses CREATE throughout:

```
TYPE TPlayer
  Name AS STRING
  Score AS INTEGER
  Health AS DOUBLE
END TYPE

TYPE TPoint
  X AS INTEGER
  Y AS INTEGER
END TYPE

TYPE TGameState
  Player AS TPlayer
  Position AS TPoint
  Level AS INTEGER
END TYPE

' Initialize everything with CREATE
DIM Pos AS TPoint = CREATE TPoint(100, 200)
DIM Hero AS TPlayer = CREATE TPlayer("Adventurer", 0, 100.0)

' Modify fields as the game progresses
Hero.Score = Hero.Score + 50
Pos = CREATE TPoint(Pos.X + 10, Pos.Y)

PRINT Hero.Name; " at ("; Pos.X; ","; Pos.Y; ")"
PRINT "Score: "; Hero.Score
PRINT "Health: "; Hero.Health

' Copy the player for a saved state
DIM SavedHero AS TPlayer
SavedHero = Hero

Hero.Health = Hero.Health - 25.0
PRINT "Current health: "; Hero.Health    ' 75.0
PRINT "Saved health: "; SavedHero.Health ' 100.0 (independent copy)
```

---

## Expression Completeness: UDTs vs Arrays

FasterBASIC's array expression system is mature and comprehensive. UDT expressions cover the most important operations but have some gaps compared to arrays. Here's the current status:

### What Works

| Feature | UDTs | Arrays | Notes |
|---------|:----:|:------:|-------|
| Declaration | ✅ | ✅ | `TYPE ... END TYPE` / `DIM A(N)` |
| Field/element access | ✅ | ✅ | `P.X` / `A(i)` |
| Field/element assignment | ✅ | ✅ | `P.X = 10` / `A(i) = 10` |
| Whole-value copy | ✅ | ✅ | `B = A` / `B() = A()` |
| CREATE / fill | ✅ | ✅ | `CREATE TPoint(1,2)` / `A() = 0` |
| Element-wise `+` `-` `*` `/` | ✅ | ✅ | Numeric-only UDTs |
| Equality comparison (`=`, `<>`) | ✅ | — | Field-by-field with short-circuit |
| PRINT whole value | ✅ | — | `TypeName(field1, field2, ...)` |
| Nested types | ✅ | — | `TRect` containing `TPoint` fields |
| NEON acceleration | ✅ | ✅ | Auto-detected for eligible layouts |
| Pass to FUNCTION/SUB | ✅ | ✅ | UDTs by reference |
| Return from FUNCTION | ✅ | — | UDTs can be returned |
| DIM with initializer | ✅ | ✅ | `DIM P AS T = CREATE T(...)` |
| String fields with refcounting | ✅ | ✅ | Automatic retain/release |

### Gaps (Not Yet Implemented)

| Feature | UDTs | Arrays | Notes |
|---------|:----:|:------:|-------|
| Named-field CREATE | ✅ | — | `CREATE TPoint(X := 10, Y := 20)` |
| Default/optional fields | ✅ | — | Unmentioned fields zero-init'd |
| Scalar broadcast | ❌ | ✅ | Arrays support `A() = A() * 2`; no UDT equivalent |
| Negation | ❌ | ✅ | Arrays support `B() = -A()`; no UDT equivalent |
| Reduction (SUM, MAX, MIN) | ❌ | ✅ | Not applicable to mixed-type UDTs |
| Unary functions (ABS, SQR) | ❌ | ✅ | Arrays support `B() = ABS(A())`; no UDT equivalent |
| SWAP | ❌ | ✅ | `SWAP A, B` not yet UDT-aware |
| FOR EACH over UDT arrays | ❌ | ❌ | Not yet supported for either |
| CREATE as function argument | ❌ | — | `Call(CREATE TPoint(1,2))` — not yet |

### Analysis

The most impactful remaining gaps for day-to-day programming are:

1. **Scalar broadcast arithmetic** — `P = P * 2` to scale all numeric fields by a constant would be a natural extension of the existing element-wise arithmetic. The infrastructure is already there from array scalar broadcast.

2. **SWAP** — Swapping two UDT variables requires a temporary and three copies today. A UDT-aware SWAP would be cleaner and, for SIMD-eligible types, could use register-based swaps.

The element-wise arithmetic, NEON acceleration, equality comparison, PRINT, and named-field CREATE are now on par with (or ahead of) arrays for the operations they support. The remaining gaps are mainly in convenience features (SWAP, broadcast).

---

## Quick Reference

### Type Declaration

```
TYPE TName
  Field1 AS INTEGER
  Field2 AS STRING
  Field3 AS DOUBLE
  Nested AS TOtherType
END TYPE
```

### CREATE Expression

```
' DIM with initializer (positional)
DIM V AS TName = CREATE TName(42, "hello", 3.14, otherValue)

' DIM with initializer (named fields — any order, partial OK)
DIM V AS TName = CREATE TName(Field2 := "hello", Field1 := 42)

' Zero-initialize all fields
DIM V AS TName = CREATE TName()

' Assignment
V = CREATE TName(99, "world", 2.71, otherValue)

' Nested member
R.TopLeft = CREATE TPoint(0, 0)
R.BottomRight = CREATE TPoint(X := 640, Y := 480)
```

### Field Access

```
PRINT V.Field1           ' read
V.Field2 = "updated"     ' write
PRINT R.TopLeft.X         ' nested read
R.TopLeft.X = 15          ' nested write
```

### Copy

```
DIM Copy AS TName
Copy = Original           ' field-by-field value copy
```

### Arithmetic (numeric-only UDTs)

```
C = A + B                 ' element-wise add
C = A - B                 ' element-wise subtract
C = A * B                 ' element-wise multiply
C = A / B                 ' element-wise divide (float types)
```

### Equality Comparison

```
IF A = B THEN ...         ' true if all fields match
IF A <> B THEN ...        ' true if any field differs
```

### PRINT

```
PRINT P                   ' TPoint(10, 20)
PRINT Per                 ' TPerson("Alice", 30)
PRINT R                   ' TRect(TPoint(0, 0), TPoint(640, 480))
PRINT "Pos: "; P          ' Pos: TPoint(10, 20)
```

### Arrays

```
DIM Items(100) AS TName
Items(0) = CREATE TName(1, "first", 0.0, otherValue)
PRINT Items(0).Field1
```

---

## Further Reading

- [WITH…END WITH](with.md) — initialise UDT fields in a clean block without repeating the variable name
- [Array Expressions](array-expressions.md) — whole-array operations with SIMD acceleration
- [NEON SIMD Support](neon-simd-support.md) — automatic ARM64 vectorization for eligible UDTs
- [Classes and Objects](classes-and-objects.md) — heap-allocated reference types with methods and inheritance