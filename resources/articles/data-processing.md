# Data Processing in FasterBASIC

*Sort, rank, filter, and aggregate — everything you need to go from raw data to results.*

---

## Introduction

FasterBASIC gives you two complementary data structures for working with collections of values — **arrays** and **lists** — and a rich set of operations for each. Arrays offer contiguous, cache-friendly storage with SIMD-accelerated arithmetic. Lists offer dynamic growth, heterogeneous element types, and a method-call interface that reads like natural language.

This article covers the data processing capabilities of both, with a focus on sorting, indexing, ranking, and aggregation. Whether you're computing statistics over sensor readings, sorting a leaderboard, or building a frequency table, these tools are the foundation.

---

## Arrays vs Lists — Which One?

Before diving into the operations themselves, it helps to understand when to reach for each structure.

| | Arrays | Lists |
|---|---|---|
| **Size** | Fixed at `DIM` time | Dynamic — grows and shrinks |
| **Element access** | O(1) by index | O(n) by index (.GET) |
| **Element type** | Homogeneous (all same type) | Homogeneous *or* mixed (LIST OF ANY) |
| **SIMD arithmetic** | ✅ (array expressions) | ❌ |
| **Sorting** | `QSORT(arr())` | `list.SORT()` |
| **Sorted copy** | — (sort in-place or copy first) | `list.SORTED()` |
| **Index / argsort** | `INDEX(src(), dst())` | — |
| **Reductions** | `SUM()`, `MAX()`, `MIN()`, `AVG()`, `DOT()` | — |
| **Pattern matching** | ❌ | ✅ with `MATCH TYPE` |

**Rule of thumb:** reach for arrays when you know the size up front and want raw performance; reach for lists when you need a collection that grows or carries mixed types.

---

## Sorting Arrays

### QSORT — in-place quicksort

`QSORT` sorts an array in-place. It modifies the array directly and returns nothing.

```basic
DIM scores(10) AS INTEGER
scores(1) = 82 : scores(2) = 67 : scores(3) = 95 : scores(4) = 71 : scores(5) = 88
scores(6) = 59 : scores(7) = 91 : scores(8) = 74 : scores(9) = 83 : scores(10) = 66

QSORT(scores())                  ' ascending — lowest first
QSORT(scores(), DESCENDING)      ' highest first
QSORT(scores(), ASCENDING)       ' same as the default
```

`QSORT` works on `INTEGER`, `DOUBLE`, and `STRING` arrays. Strings are sorted lexicographically, which is alphabetical order for plain ASCII text.

```basic
DIM names(5) AS STRING
names(1) = "Diana" : names(2) = "Alice" : names(3) = "Eve"
names(4) = "Bob"   : names(5) = "Carol"

QSORT(names())
' names(1) = "Alice", names(5) = "Eve"
```

> **Note on indexing.** FasterBASIC arrays use 1-based indexing by default. `DIM a(N)` allocates elements at positions 1 through N. `QSORT` operates on exactly that range — the user-visible elements — and does not touch position 0.

### Choosing a direction

The `ASCENDING` and `DESCENDING` keywords control sort order:

```basic
DIM temps(7) AS DOUBLE
' ... fill temps ...

QSORT(temps())               ' ascending: coldest first
QSORT(temps(), DESCENDING)   ' descending: hottest first
```

---

## INDEX — Argsort / Indirect Sort

`INDEX` is FasterBASIC's argsort. Instead of rearranging the source array, it fills a second integer array with the *positions* of the source elements in sorted order. The source array is left completely untouched.

```basic
INDEX(src(), dst())             ' ascending
INDEX(src(), dst(), DESCENDING) ' descending
```

`dst(i)` holds the 1-based position in `src()` of the i-th smallest (or largest) element. After the call you can access the values in sorted order without modifying `src` at all:

```basic
DIM prices(5) AS DOUBLE
prices(1) = 9.99 : prices(2) = 4.49 : prices(3) = 14.99
prices(4) = 1.99 : prices(5) = 7.99

DIM order(5) AS INTEGER
INDEX(prices(), order())

' Print prices cheapest-first, source unchanged
FOR i = 1 TO 5
    PRINT prices(order(i))     ' 1.99, 4.49, 7.99, 9.99, 14.99
NEXT i
```

### Why INDEX matters

`QSORT` reorders the array, which means you lose the original positions. `INDEX` gives you a way to sort *logically* while preserving the original layout. This is essential when your data lives in parallel arrays — one for values, one for labels, one for timestamps — and you want to reorder all of them consistently without making copies.

---

## Sorting Lists

Lists are sorted via method calls on the list variable itself.

### .SORT() — in-place

Sorts the list in-place. The list is modified directly.

```basic
DIM temps AS LIST OF DOUBLE = LIST(36.6, 37.1, 35.9, 38.5, 37.4)

temps.SORT()                  ' ascending
temps.SORT(DESCENDING)        ' descending
temps.SORT(ASCENDING)         ' explicit ascending — same as default
```

### .SORTED() — non-destructive copy

Returns a new sorted list, leaving the original unchanged. Useful when you need both the original order and a sorted view.

```basic
DIM original AS LIST OF STRING = LIST("banana", "apple", "cherry")
DIM sorted AS LIST OF STRING
LET sorted = original.SORTED()

PRINT original.HEAD()    ' banana — unchanged
PRINT sorted.HEAD()      ' apple
```

```basic
DIM scores AS LIST OF INTEGER = LIST(85, 92, 78, 95, 88, 71)
DIM ranking AS LIST OF INTEGER
LET ranking = scores.SORTED(DESCENDING)

PRINT "Top score: "; ranking.HEAD()    ' 95
PRINT "Original: "; scores.HEAD()      ' 85 — untouched
```

### Supported list element types

`.SORT()` and `.SORTED()` work on `LIST OF INTEGER`, `LIST OF DOUBLE`, and `LIST OF STRING`. The same `ASCENDING`/`DESCENDING` keywords apply.

---

## Ranking and Indirect Access

A common data processing pattern is: *sort by one value, but refer back to the original positions.* `INDEX` is the direct tool for this with arrays.

### Leaderboard example

```basic
DIM score(6) AS INTEGER
score(1) = 85 : score(2) = 92 : score(3) = 78
score(4) = 95 : score(5) = 88 : score(6) = 71

DIM rank(6) AS INTEGER
INDEX(score(), rank(), DESCENDING)

' Print leaderboard: rank, original position, score
FOR place = 1 TO 6
    PRINT "Place "; place; ": player "; rank(place); " with "; score(rank(place)); " pts"
NEXT place

' Output:
'   Place 1: player 4 with 95 pts
'   Place 2: player 2 with 92 pts
'   Place 3: player 5 with 88 pts
'   Place 4: player 1 with 85 pts
'   Place 5: player 3 with 78 pts
'   Place 6: player 6 with 71 pts
```

### Sorting parallel arrays

When you have multiple arrays whose elements correspond by position (parallel arrays), `INDEX` lets you reorder all of them by one key without losing alignment:

```basic
' Parallel arrays: each index represents one product
DIM item_price(5) AS DOUBLE
DIM item_stock(5) AS INTEGER
DIM item_name(5) AS STRING

item_name(1) = "Bolt"   : item_price(1) = 0.05 : item_stock(1) = 500
item_name(2) = "Wrench" : item_price(2) = 12.99 : item_stock(2) = 42
item_name(3) = "Drill"  : item_price(3) = 89.99 : item_stock(3) = 8
item_name(4) = "Nail"   : item_price(4) = 0.02 : item_stock(4) = 2000
item_name(5) = "Hammer" : item_price(5) = 24.99 : item_stock(5) = 17

' Sort products by price (cheapest first)
DIM order(5) AS INTEGER
INDEX(item_price(), order())

PRINT "Products by price:"
FOR i = 1 TO 5
    PRINT "  "; item_name(order(i)); " — $"; item_price(order(i)); " ("; item_stock(order(i)); " in stock)"
NEXT i

' Output (sorted by price):
'   Nail    — $0.02 (2000 in stock)
'   Bolt    — $0.05 (500 in stock)
'   Wrench  — $12.99 (42 in stock)
'   Hammer  — $24.99 (17 in stock)
'   Drill   — $89.99 (8 in stock)
```

All three parallel arrays remain in their original order; only the index array is reordered.

---

## Aggregation and Reduction

Reduction functions collapse an entire array to a single scalar value. They are written as ordinary function calls — no loop required.

```basic
DIM readings(100) AS DOUBLE

total# = SUM(readings())       ' sum of all elements
high#  = MAX(readings())       ' maximum value
low#   = MIN(readings())       ' minimum value
mean#  = AVG(readings())       ' arithmetic mean
```

These work on all numeric array types: `BYTE`, `SHORT`, `INTEGER`, `LONG`, `SINGLE`, and `DOUBLE`.

### Dot product

`DOT(A(), B())` computes the inner product — the sum of element-wise products:

```basic
' Weighted score: each test has a weight
DIM test_score(3) AS DOUBLE
DIM test_weight(3) AS DOUBLE

test_score(1) = 88.0 : test_weight(1) = 0.20    ' quiz
test_score(2) = 74.0 : test_weight(2) = 0.30    ' midterm
test_score(3) = 91.0 : test_weight(3) = 0.50    ' final

DIM final_grade AS DOUBLE
final_grade = DOT(test_score(), test_weight())   ' 84.7
PRINT "Final grade: "; final_grade
```

### Normalisation

Combining reductions with array expressions gives you normalisation in two lines:

```basic
DIM data(200) AS DOUBLE

' Shift and scale to [0, 1]
DIM lo AS DOUBLE : lo = MIN(data())
DIM hi AS DOUBLE : hi = MAX(data())
DIM rng AS DOUBLE : rng = hi - lo

data() = data() - lo       ' shift minimum to 0
data() = data() / rng      ' scale maximum to 1
```

### Z-score standardisation

```basic
DIM vals(500) AS DOUBLE

DIM mu AS DOUBLE : mu = AVG(vals())
DIM total_sq AS DOUBLE

' Compute variance manually using array expressions
DIM temp(500) AS DOUBLE
temp() = vals() - mu          ' deviations
temp() = temp() * temp()      ' squared deviations
DIM variance AS DOUBLE : variance = AVG(temp())
DIM sigma AS DOUBLE : sigma = SQR(variance)

' Standardise in-place
vals() = vals() - mu
vals() = vals() / sigma
```

---

## Filtering

FasterBASIC does not have a single built-in filter operation, but filtering patterns are concise with a compact FOR loop or a list.

### Filter an array into a list

```basic
DIM readings(100) AS DOUBLE
' ... fill readings ...

DIM above_threshold AS LIST OF DOUBLE
DIM threshold AS DOUBLE : threshold = 98.6

FOR i = 1 TO 100
    IF readings(i) > threshold THEN
        above_threshold.APPEND(readings(i))
    END IF
NEXT i

PRINT "Values above threshold: "; above_threshold.LENGTH()
```

### Filter using INDEX (keep original positions)

`INDEX` gives you a natural way to focus on the top-k or bottom-k elements without rebuilding the array:

```basic
' Top 3 scores from a large array
DIM scores(50) AS INTEGER
' ... fill scores ...

DIM idx(50) AS INTEGER
INDEX(scores(), idx(), DESCENDING)

PRINT "Top 3:"
FOR i = 1 TO 3
    PRINT "  Position "; idx(i); ": "; scores(idx(i))
NEXT i
```

---

## Frequency Counts and Histograms

For discrete data, a histogram counts how often each value appears. With small integer ranges this is a simple indexed-array operation:

```basic
' Count how many times each score band appears (0-9, 10-19, ..., 90-100)
DIM scores(200) AS INTEGER
' ... fill scores ...

DIM bucket(10) AS INTEGER    ' bucket(1)=0-9, bucket(2)=10-19, ..., bucket(10)=90-99, bucket(11)=100

FOR i = 1 TO 200
    DIM b AS INTEGER
    b = scores(i) \ 10 + 1   ' integer divide to get bucket
    IF b > 10 THEN b = 10    ' clamp 100 into last bucket
    bucket(b) = bucket(b) + 1
NEXT i

' Print histogram
FOR band = 1 TO 10
    PRINT (band - 1) * 10; "-"; band * 10 - 1; ": "; bucket(band)
NEXT band
```

---

## Working with Sorted Data

Once data is sorted, several useful operations become trivial.

### Median

```basic
DIM vals(6) AS DOUBLE
vals(1) = 9
vals(2) = 1
vals(3) = 7
vals(4) = 3
vals(5) = 11
vals(6) = 5

QSORT(vals())

DIM n AS INTEGER : n = 6
DIM median AS DOUBLE
IF n MOD 2 = 1 THEN
    median = vals((n + 1) \ 2)          ' odd length: middle element
ELSE
    median = (vals(n \ 2) + vals(n \ 2 + 1)) / 2.0   ' even: average of two middle
END IF
PRINT "Median: "; median
' Prints: Median: 6
```

### Percentiles

```basic
' 90th percentile of a sorted array
DIM vals(1000) AS DOUBLE
QSORT(vals())

DIM p90_idx AS INTEGER
p90_idx = INT(1000 * 0.90)     ' index of 90th percentile
PRINT "P90: "; vals(p90_idx)
```

### Removing duplicates

After sorting, duplicates are adjacent and easy to skip:

```basic
DIM raw(200) AS INTEGER
QSORT(raw())

' Collect unique values into a list
DIM unique AS LIST OF INTEGER
unique.APPEND(raw(1))

FOR i = 2 TO 200
    IF raw(i) <> raw(i - 1) THEN
        unique.APPEND(raw(i))
    END IF
NEXT i

PRINT "Unique values: "; unique.LENGTH()
```

### Binary search (after QSORT)

Once an array is sorted, you can implement binary search for O(log n) lookups:

```basic
FUNCTION BSearch(arr() AS INTEGER, n AS INTEGER, target AS INTEGER) AS INTEGER
    DIM lo AS INTEGER : lo = 1
    DIM hi AS INTEGER : hi = n
    DIM mid AS INTEGER

    DO WHILE lo <= hi
        mid = (lo + hi) \ 2
        IF arr(mid) = target THEN
            BSearch = mid
            EXIT FUNCTION
        ELSE IF arr(mid) < target THEN
            lo = mid + 1
        ELSE
            hi = mid - 1
        END IF
    LOOP

    BSearch = -1    ' not found
END FUNCTION
```

---

## Complete Example: Student Grade Report

This example brings together sorting, indexing, reductions, and parallel arrays.

```basic

' -- Data --
DIM n AS INTEGER : n = 8

DIM name(8) AS STRING
DIM quiz(8)   AS DOUBLE
DIM midterm(8) AS DOUBLE
DIM final(8)   AS DOUBLE
DIM weighted(8) AS DOUBLE

name(1) = "Alice"   : quiz(1) = 92 : midterm(1) = 88 : final(1) = 91
name(2) = "Bob"     : quiz(2) = 74 : midterm(2) = 69 : final(2) = 73
name(3) = "Carol"   : quiz(3) = 85 : midterm(3) = 90 : final(3) = 87
name(4) = "Dan"     : quiz(4) = 60 : midterm(4) = 55 : final(4) = 58
name(5) = "Eve"     : quiz(5) = 95 : midterm(5) = 97 : final(5) = 96
name(6) = "Frank"   : quiz(6) = 78 : midterm(6) = 82 : final(6) = 80
name(7) = "Grace"   : quiz(7) = 88 : midterm(7) = 84 : final(7) = 86
name(8) = "Hiro"    : quiz(8) = 55 : midterm(8) = 62 : final(8) = 59

' -- Compute weighted score: 20% quiz, 30% midterm, 50% final --
FOR i = 1 TO n
    weighted(i) = quiz(i) * 0.20 + midterm(i) * 0.30 + final(i) * 0.50
NEXT i

' -- Class statistics --
PRINT "=== Class Statistics ==="
PRINT "Mean:   "; AVG(weighted())
PRINT "High:   "; MAX(weighted())
PRINT "Low:    "; MIN(weighted())

' -- Sort by weighted score (highest first) using INDEX --
DIM rank(8) AS INTEGER
INDEX(weighted(), rank(), DESCENDING)

PRINT ""
PRINT "=== Leaderboard ==="
FOR iplace = 1 TO n
    PRINT iplace; ". "; name(rank(iplace)); "  "; weighted(rank(iplace))
NEXT iplace

' -- Median (sort a copy) --
DIM sorted_w(8) AS DOUBLE
sorted_w() = weighted()          ' whole-array copy
QSORT(sorted_w())
DIM median AS DOUBLE
median = (sorted_w(4) + sorted_w(5)) / 2.0
PRINT ""
PRINT "Median: "; median

' -- Passing rate --
DIM passing AS INTEGER : passing = 0
FOR i = 1 TO n
    IF weighted(i) >= 60.0 THEN passing = passing + 1
NEXT i
PRINT "Passing (>=60): "; passing; " of "; n
```

---

## Complete Example: Temperature Log Analysis

```basic

' 24 hourly readings
DIM temp(24) AS DOUBLE
temp(1)  = 18.2 : temp(2)  = 17.8 : temp(3)  = 17.4 : temp(4)  = 17.1
temp(5)  = 16.9 : temp(6)  = 16.8 : temp(7)  = 17.0 : temp(8)  = 17.9
temp(9)  = 19.5 : temp(10) = 21.3 : temp(11) = 23.1 : temp(12) = 24.6
temp(13) = 25.8 : temp(14) = 26.7 : temp(15) = 26.9 : temp(16) = 26.5
temp(17) = 25.3 : temp(18) = 23.9 : temp(19) = 22.4 : temp(20) = 21.1
temp(21) = 20.3 : temp(22) = 19.6 : temp(23) = 18.9 : temp(24) = 18.4

' Basic statistics
PRINT "Min:  "; MIN(temp()); " °C"
PRINT "Max:  "; MAX(temp()); " °C"
PRINT "Mean: "; AVG(temp()); " °C"
PRINT "Range:"; MAX(temp()) - MIN(temp()); " °C"

' Find the hours with the 3 highest and 3 lowest temperatures
DIM order(24) AS INTEGER
INDEX(temp(), order(), DESCENDING)
PRINT ""
PRINT "Warmest hours:"
FOR j = 1 TO 3
    PRINT "  Hour "; order(j); ": "; temp(order(j)); " °C"
NEXT j

INDEX(temp(), order(), ASCENDING)
PRINT "Coldest hours:"
FOR j = 1 TO 3
    PRINT "  Hour "; order(j); ": "; temp(order(j)); " °C"
NEXT j

' Compute anomalies: how many degrees each hour deviates from the mean
DIM anomaly(24) AS DOUBLE
DIM mu AS DOUBLE : mu = AVG(temp())
anomaly() = temp() - mu                ' array expression: subtract scalar from every element

' Print hours more than 3 degrees above or below average
PRINT ""
PRINT "Hours more than 3 °C from mean ("; mu; " °C):"
FOR i = 1 TO 24
    IF ABS(anomaly(i)) > 3.0 THEN
        PRINT "  Hour "; i; ": "; temp(i); " °C ("; anomaly(i); ")"
    END IF
NEXT i
```

---

## Quick Reference

### Array Sorting and Indexing

| Statement | Effect |
|---|---|
| `QSORT(a())` | Sort array `a` in-place, ascending |
| `QSORT(a(), DESCENDING)` | Sort array `a` in-place, descending |
| `QSORT(a(), ASCENDING)` | Explicit ascending (same as default) |
| `INDEX(src(), dst())` | Fill `dst` with sorted positions of `src`, ascending |
| `INDEX(src(), dst(), DESCENDING)` | Fill `dst` with sorted positions of `src`, descending |

**Supported types:** `INTEGER`, `DOUBLE`, `STRING`

### Array Reductions

| Expression | Returns |
|---|---|
| `SUM(a())` | Sum of all elements |
| `MAX(a())` | Largest element |
| `MIN(a())` | Smallest element |
| `AVG(a())` | Arithmetic mean |
| `DOT(a(), b())` | Dot product (sum of element-wise products) |

### Whole-Array Expressions (for data transformation)

| Expression | Effect |
|---|---|
| `b() = a()` | Copy array `a` into `b` |
| `a() = value` | Fill every element of `a` with a scalar |
| `c() = a() + b()` | Element-wise addition |
| `a() = a() - mu` | Subtract scalar `mu` from every element |
| `a() = a() / rng` | Divide every element by scalar `rng` |
| `b() = ABS(a())` | Absolute value of every element |
| `b() = SQR(a())` | Square root of every element |

### List Sorting

| Expression | Effect |
|---|---|
| `list.SORT()` | Sort in-place, ascending |
| `list.SORT(DESCENDING)` | Sort in-place, descending |
| `LET copy = list.SORTED()` | Return new sorted list, ascending |
| `LET copy = list.SORTED(DESCENDING)` | Return new sorted list, descending |

**Supported types:** `LIST OF INTEGER`, `LIST OF DOUBLE`, `LIST OF STRING`

---

## Implementation Notes

### QSORT and INDEX internals

Both operations work on the user-visible portion of an array — elements 1 through N for a `DIM a(N)` declaration. Element 0 is never moved into the user-visible region.

`QSORT` uses an in-place quicksort implemented in the runtime. `INDEX` builds the position array without modifying the source, making it safe to call on any array you want to preserve.

### List sort implementation

`.SORT()` and `.SORTED()` use a stable merge sort over the linked-list atoms that back a `LIST`. The sort is stable: elements with equal values retain their relative order.

### Symbol availability

The runtime functions (`array_qsort_int`, `array_qsort_float`, `array_qsort_string`, `array_index_int`, `array_index_float`, `array_index_string`) are retained in the binary and available for JIT use. The compiler selects the correct typed variant based on the array's declared element type.

---

## Further Reading

- [Array Expressions](array-expressions.md) — element-wise arithmetic, fill, copy, FMA, and all reduction functions
- [NEON SIMD Support](neon-simd-support.md) — how the compiler vectorizes array expressions on ARM64
- [Lists and MATCH TYPE](lists-and-match-type.md) — dynamic collections, heterogeneous data, and type-safe dispatch
- [Workers: Safe Concurrency](workers.md) — parallel data processing across OS threads using the actor model