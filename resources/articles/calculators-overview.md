# Interactive Calculators Overview

FasterBASIC includes a library of **Parameterized Calculators** designed for science, engineering, and statistical analysis. These are not just static examples; they are functional "mini-apps" you can use when you are cut off from the internet or standard tools.

## 🧮 How to use

Every calculator follows a strict "Parameter-First" design:

1.  **Locate**: Navigate to the `calculators/` directory in your workspace.
2.  **Edit**: Open any `.bas` file and look for the `PARAMS` block (usually at the top).
3.  **Run**: Execution is instantaneous via the FasterBASIC JIT.

```vb
' ── PARAMS ───────────────────────────────────────────────────────────────────
principal = 250000.0     ' Edit your value here
annual_rate = 0.045      ' Edit your value here
term_years = 30          ' Edit your value here
```

## 🏗️ Design Philosophy

Each file contains a `HelpMeta` header block that describes its mathematical domain, required prerequisites, units, and assumptions. This ensures that even if you aren't an expert in the field, you can understand the context of the calculation.

### Topics Covered:
-   **Financial/Core**: Mortgage payments, future value, depreciation, and daily tip/tax utilities.
-   **Travel/Nav**: Haversine distance (GPS coordinates) and time-distance-speed solvers.
-   **Statistics**: Mean/StdDev, Linear Regression, Poisson distributions, and Margin of Error research polls.
-   **Science**: Ideal Gas Law, Gravitational Force, Half-life decay, Climate (Heat Index/Dew Point), and Molecular masses.
-   **Engineering**: Resistor Dividers, Power/Torque gearing, Logic Gates, and Binary Data transfer times.

## 🎓 Learning with Calculators

Beyond their utility, these scripts are designed to teach:
-   **Numeric Stability**: How to handle precision and overflow in complex formulas.
-   **Formula Implementation**: Translating textbook mathematical notation into clean, modular BASIC code.
-   **Unit Discipline**: Handling SI vs. Imperial conversions within a single logic block.

Whether you are calculating the load on a cantilever beam or the probability of a rare event, the code is local, readable, and ready to solve.
