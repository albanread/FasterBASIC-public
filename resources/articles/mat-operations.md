# Matrix Operations (MAT) in Ed-BASIC

Ed FasterBASIC provides a powerful set of Matrix (`MAT`) operations that allow you to manipulate entire 1D and 2D arrays in a single line of code. Instead of writing nested `FOR...NEXT` loops to do math on arrays element-by-element, you can use `MAT` commands.

Under the hood, these operations (with large arrays) are hardware-accelerated using your Mac's native processing capabilities (Apple Accelerate). This means they run fast and are useful for 3D graphics, physics simulations, and heavy data processing.

FasterBASIC also supports array expressions, which are designed to accelerate one dimensional array operations.

There is some potential overlap, but they also complement each other, they may activate different hardware accellerators in your Mac 'supercomputer'.


These MAT functions are for Matrix operations, you may end up using both. MAT currently operates on `DOUBLE` arrays; dimension matrices as `DOUBLE` (e.g., `DIM A(10,10) AS DOUBLE`) to use MAT.


## Initialization: Setting Up Matrices

Before performing math, it's often useful to fill an entire array with specific baseline values.

```basic
DIM A(10, 10) AS DOUBLE
DIM B(10, 10) AS DOUBLE
DIM C(10, 10) AS DOUBLE

' Fill an array entirely with 0.0
MAT A = ZER

' Fill an array with a constant value (e.g., 5.5)
MAT B = CON(5.5)

' Create an Identity Matrix (1.0 on the diagonal, 0.0 elsewhere)
MAT C = IDN
```
*Note: A matrix must be dimensioned properly with `DIM` before you can apply `MAT` assignments to it.*

## Core Arithmetic

You can perform arithmetic on entire sets of numbers at once. The matrices must be the exact same size.

### Matrix Addition and Subtraction
Adds or subtracts corresponding elements from two arrays and stores the result in a third.

```basic
MAT C = A + B
MAT C = A - B
```

### Scalar Math
You can scale an entire matrix by a single number (a scalar). Every element in the array is multiplied by this value.

```basic
MAT C = A * 2.5
```

### Matrix Multiplication
Unlike scalar math, true matrix multiplication is the backbone of 3D graphics (like calculating rotations, scales, and translations). Ed-BASIC provides the `MATMUL` command for high-speed dot-product combinations of rows and columns.

```basic
' Multiplies matrix A by matrix B and stores the result in C
MATMUL A, B, C
```
*Note: For `MATMUL` to work, the number of columns in `A` must exactly match the number of rows in `B`.*

## Advanced Transformations

For complex mathematical operations—such as calculating inverted camera perspectives in 3D engines—Ed-BASIC provides native algebraic transformations:

### Transpose
Flips a matrix over its diagonal, switching its rows and columns.
```basic
MAT C = TRN(A)
```

### Inverse
Calculates the inverse of a matrix. If you multiply a matrix by its inverse, you get the Identity matrix (`IDN`). This is extremely valuable for reversing transformations (like moving from world-space back to local-space).
```basic
MAT C = INV(A)
```

## Performance and Acceleration

On macOS, MAT operations switch to Accelerate/LAPACK fast paths at certain sizes; smaller shapes stay scalar for lowest overhead. Current cutovers (all values inclusive):

- Fill (ZER/CON/IDN): vDSP `vclr`/`vfill` kicks in at 256 elements or more. Smaller fills stay scalar.
- Transpose (TRN): vDSP `mtrans` is used when rows×cols ≥ 1024. Rows are packed/unpacked internally so matrices with leading-dimension padding still transpose correctly. Smaller shapes use a scalar nested loop.
- Matrix multiply (MATMUL): cBLAS `dgemm` is used when m×n×k ≥ 4096 work; otherwise a scalar triple loop runs.
- Inverse (INV): LAPACK `dgetrf`/`dgetri` is used for square matrices of size ≥ 8. Smaller matrices use a Gauss–Jordan scalar inverse. Non-square matrices are rejected.

Leading-dimension expectations: MAT arrays are stored row-major with a stride equal to the second dimension declared at `DIM` time; all MAT helpers assume that stride and treat element indices as 1-based. The transpose fast path packs/unpacks so padded rows are handled, but destination arrays must be dimensioned with the correct row/column counts (and stride) up front.

If you run on non-macOS platforms, the same semantics apply but all operations use the scalar implementations.

## When to Use MAT Operations
*   **3D Graphics:** Use `MATMUL`, `TRN`, and `INV` to calculate camera projections, object rotations, and translations.
*   **Physics Engines:** Use scalar math (`MAT C = A * 0.98`) to quickly apply friction or gravity to thousands of particle velocities in one line.
*   **Image Processing:** Use `MAT C = A + B` to blend two grids of color values together instantly.
