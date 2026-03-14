# Matrix Demo Guide

This note explains what the `MATRIX` window in `demos/32_window_matrix_demo.bas` shows, what happens when you click the toolbar buttons, and how the matrix multiplication `A = B * C` is computed.

## The matrices in the demo

- **A** (left): result matrix. Buttons write results here.
- **B** (middle): input matrix #1. You can edit its cells in the UI.
- **C** (right): input matrix #2. You can edit its cells in the UI.
- All three are 3×3 matrices (rows and columns are 1-based in the BASIC code and in the UI headers `[1]`, `[2]`, `[3]`).

## What `A = B * C` means

Matrix multiplication is not elementwise. Each cell of `A` is the dot product of a row of `B` with a column of `C`:

$$
A_{r,c} = \sum_{k=1}^{3} B_{r,k} \times C_{k,c}
$$

So:
- A’s first row uses **row 1 of B** against each column of C.
- A’s second row uses **row 2 of B** against each column of C.
- A’s third row uses **row 3 of B** against each column of C.

Expanded for 3×3:
- \(A_{1,1} = B_{1,1}C_{1,1} + B_{1,2}C_{2,1} + B_{1,3}C_{3,1}\)
- \(A_{1,2} = B_{1,1}C_{1,2} + B_{1,2}C_{2,2} + B_{1,3}C_{3,2}\)
- \(A_{1,3} = B_{1,1}C_{1,3} + B_{1,2}C_{2,3} + B_{1,3}C_{3,3}\)
- Similarly for rows 2 and 3.

Order matters: `B * C` is **not** the same as `C * B` in general. Swapping them would use rows of `C` with columns of `B` and produce a different result.

## Toolbar and Matrix menu

The toolbar covers the core operations; the Matrix menu adds more ways to combine or reset the three matrices. All operations rewrite the on-screen grids and print the arrays to the terminal.

- **A = B * C**: standard multiply (row of B with column of C). Use **B * C** to show normal order.
- **A = C * B**: swapped multiply to demonstrate non-commutativity (usually differs from B * C).
- **A = B + C** / **A = B - C**: elementwise add/subtract into A.
- **TRN B→A** / **TRN C→A**: transpose B or C into A (rows become columns). \(A_{r,c} = B_{c,r}\) or \(A_{r,c} = C_{c,r}\).
- **INV B→A** / **INV C→A**: inverse of B or C into A (only valid if the source matrix is invertible). For the default B, the determinant is 126, so the inverse the demo computes is:
	- row 1: 0.0794, -0.3175, 0.1905
	- row 2: 0.0556, 0.2778, -0.1667
	- row 3: -0.0635, 0.2540, 0.0476
	Multiplying that inverse by the original B yields the identity matrix (1s on the diagonal, 0 elsewhere), which is how you can sanity-check an inverse. The default C starts as identity, so INV C→A simply produces identity again.
- **ZER A**: fill A with zeros.
- **IDN B / IDN C**: make B or C identity (1s on the diagonal). Handy for sanity checks: `A = B * C` shows that multiplying by identity leaves the other matrix unchanged.
- **ZER B / ZER C**: zero-out the inputs.
- **Copy B → C / Copy C → B**: duplicate one input into the other for quick experiments.

## Editing values

- Click a cell in B or C, type a number, press Enter. The toolbar operations read the live values you enter.
- The printed console output (see the terminal) shows B, C, and A after each operation for quick verification.

## Quick mental check

- If B is the identity matrix, `A = B * C` yields A = C.
- If C is the identity matrix, `A = B * C` yields A = B.
- If both B and C are zero matrices, A stays zero.

That’s all you need to interpret the demo: `A = B * C` takes each **row of B** and multiplies it against each **column of C**, producing the 3×3 result shown in A.
