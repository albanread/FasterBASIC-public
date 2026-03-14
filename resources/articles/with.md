# WITH…END WITH in FasterBASIC

*Initialise, configure, and work with objects and UDTs without repeating the variable name.*

---

## Overview

The `WITH…END WITH` block lets you access all the fields and methods of a variable by writing just `.FieldName` instead of `variable.FieldName`.  It works with both CLASS instances and plain UDTs (`TYPE`).

There are two forms:

| Form | When to use |
|---|---|
| **Inline** — `DIM x AS Type(args) WITH … END WITH` | Initialise a variable immediately after it is declared |
| **Standalone** — `WITH variable … END WITH` | Work with a variable that already exists |

Both forms accept `.Field = expr` assignments, `.Method(args)` calls, and descend into sub-objects via `WITH variable.Field`.

---

## Inline form — `DIM … WITH`

Attach a `WITH` block directly to a `DIM` statement.  The block runs immediately after the object is constructed, before any other code can touch it.

```
CLASS Cat
    Name   AS STRING
    Age    AS INTEGER
    Weight AS DOUBLE

    CONSTRUCTOR(n AS STRING, age AS INTEGER)
        Name = n
        Age  = age
    END CONSTRUCTOR
END CLASS

DIM c AS Cat("Whiskers", 3) WITH
    .Weight = 4.2
END WITH

PRINT c.Name    ' Whiskers
PRINT c.Weight  ' 4.2
```

The `WITH` block is part of the same declaration — there is no window between construction and initialisation where the object is in a half-ready state.

### With a nullary constructor

If the class has a no-argument constructor, `DIM` already auto-constructs it.  You can still attach a `WITH` block to fill in the fields:

```
CLASS Point
    X AS INTEGER
    Y AS INTEGER
    CONSTRUCTOR()
        X = 0 : Y = 0
    END CONSTRUCTOR
END CLASS

DIM p AS Point WITH
    .X = 10
    .Y = 20
END WITH

PRINT p.X; ", "; p.Y    ' 10, 20
```

### Setting a nested class field

If your object has a class-typed field that needs its own constructor arguments, assign it inside the `WITH` block:

```
CLASS Food
    Name     AS STRING
    Calories AS INTEGER
    CONSTRUCTOR(n AS STRING)
        Name = n : Calories = 0
    END CONSTRUCTOR
END CLASS

CLASS Cat
    Name AS STRING
    Food AS Food
    CONSTRUCTOR(n AS STRING)
        Name = n
    END CONSTRUCTOR
END CLASS

DIM c AS Cat("Luna") WITH
    .Food = NEW Food("tuna")
END WITH

PRINT c.Name + " eats " + c.Food.Name    ' Luna eats tuna
```

### Calling methods inside the block

The `WITH` block is not limited to assignments — you can call methods too:

```
CLASS Counter
    Count AS INTEGER
    CONSTRUCTOR()
        Count = 0
    END CONSTRUCTOR
    METHOD Add(n AS INTEGER)
        Count = Count + n
    END METHOD
    METHOD Value() AS INTEGER
        RETURN Count
    END METHOD
END CLASS

DIM ctr AS Counter WITH
    .Add(5)
    .Add(3)
END WITH

PRINT ctr.Value()    ' 8
```

---

## Standalone form — `WITH variable`

Use the standalone form to configure an object that has already been declared or received from elsewhere.

```
DIM f AS Food = NEW Food("chicken")

WITH f
    .Calories  = 200
    .Name      = "grilled chicken"
END WITH

PRINT f.Name; " "; f.Calories    ' grilled chicken 200
```

### Syntax

```
WITH variableName
    .Field = expression
    .Method(arguments)
END WITH
```

- Every line inside the block that starts with `.` is resolved against `variableName`.
- Lines that do *not* start with `.` are ordinary statements — `PRINT`, `IF`, loops, and so on — and are emitted as-is.
- `END WITH` closes the block (also accepted: `ENDWITH` on one word).

---

## Descending into sub-objects — `WITH obj.Field`

Append a dotted path after the variable name to descend into a nested field:

```
WITH c.Food
    .Calories = 120
END WITH
```

This is equivalent to writing `c.Food.Calories = 120` but is cleaner when there are several assignments to make on the same sub-object.

You can descend as many levels as needed:

```
WITH order.Customer.Address
    .Street = "42 Turing Road"
    .City   = "Cambridge"
    .PostCode = "CB1 1AA"
END WITH
```

### Setting a nested class field then descending into it

A common pattern: assign the nested field inside the outer `WITH`, then configure it with a second `WITH`:

```
DIM c AS Cat("Mochi") WITH
    .Food = NEW Food("salmon")
END WITH

WITH c.Food
    .Calories = 120
    .Preferred = NEW Brand("Fancy Feast")
END WITH

PRINT c.Food.Name        ' salmon
PRINT c.Food.Calories    ' 120
PRINT c.Food.Preferred.Name   ' Fancy Feast
```

---

## WITH on arrays — `WITH arr(i)`

Use an index to descend into a specific element of a class array:

```
CLASS Sensor
    Label     AS STRING
    Threshold AS DOUBLE
    CONSTRUCTOR(lbl AS STRING)
        Label = lbl : Threshold = 0.0
    END CONSTRUCTOR
END CLASS

DIM sensors(3) AS Sensor("unknown")

WITH sensors(1)
    .Label     = "Temperature"
    .Threshold = 25.0
END WITH

WITH sensors(2)
    .Label     = "Humidity"
    .Threshold = 60.0
END WITH

PRINT sensors(1).Label; " "; sensors(1).Threshold    ' Temperature 25
PRINT sensors(2).Label; " "; sensors(2).Threshold    ' Humidity    60
```

---

## WITH on UDTs (`TYPE`)

`WITH` works identically for plain value-type records.  Because UDTs use value semantics, the `WITH` block modifies the variable in place:

```
TYPE TRect
    X AS INTEGER
    Y AS INTEGER
    W AS INTEGER
    H AS INTEGER
END TYPE

DIM r AS TRect

WITH r
    .X = 10
    .Y = 20
    .W = 100
    .H = 50
END WITH

PRINT r.X; r.Y; r.W; r.H    ' 10 20 100 50
```

---

## Using WITH with other statements inside the block

Ordinary statements are allowed inside a `WITH` block and run as normal code.  Only lines starting with `.` are resolved against the base variable:

```
WITH c
    .Name = "Pixel"
    PRINT "Configuring "; .Name    ' .Name here is just a field access expression
    IF someCondition THEN
        .Weight = 3.5
    ELSE
        .Weight = 4.0
    END IF
END WITH
```

---

## Comparison with VB.NET

FasterBASIC's `WITH` was inspired by VB.NET but goes further:

| Feature | VB.NET | FasterBASIC |
|---|---|---|
| Standalone `WITH var … END WITH` | ✓ | ✓ |
| Object initialiser on `Dim` | `With { .F = v }` — brace list, one line | `WITH … END WITH` — full block |
| Method calls in init block | ✗ | ✓ |
| Multi-statement block | ✗ (property list only) | ✓ |
| `WITH var.member` descent | ✗ | ✓ |
| Works with auto-constructed `DIM` | ✗ | ✓ |

VB.NET's `Dim x As New T With { .A = 1, .B = 2 }` is a **property initialiser list** — compile-time fixed, assignments only.  FasterBASIC's block is a **general initialisation scope** — you can call methods, write conditional logic, and descend into nested sub-objects.

---

## Quick reference

```
' ── Inline (attached to DIM) ─────────────────────────────────────────────
DIM x AS MyClass(args) WITH
    .Field = value
    .OtherField = value
    .Method(args)
END WITH

' ── Inline with nullary constructor ──────────────────────────────────────
DIM x AS MyClass WITH
    .Field = value
END WITH

' ── Standalone ───────────────────────────────────────────────────────────
WITH variable
    .Field = value
    .Method(args)
END WITH

' ── Descend into a sub-object ─────────────────────────────────────────────
WITH variable.SubField
    .Field = value
END WITH

' ── Array element ─────────────────────────────────────────────────────────
WITH variable(index)
    .Field = value
END WITH
```

---

## Tips

1. **Use inline `DIM … WITH` for construction** — it keeps the object fully initialised from the moment it is visible to the rest of the code.

2. **Use standalone `WITH` for reconfiguration** — change several fields of an existing object in one readable block rather than repeating the variable name on every line.

3. **Chain `WITH` blocks for deep nesting** — rather than writing `cat.Food.Preferred.Name = "x"`, assign `cat.Food.Preferred` in one block then descend with `WITH cat.Food.Preferred` to set its fields.

4. **Methods are fine inside `WITH`** — `.Add(5)`, `.Reset()`, `.Load("file")` all work exactly as if you had written `variable.Method(args)`.

5. **`WITH` works on UDTs too** — you do not need a class; any `TYPE` record benefits from the same syntax.

---

## Further reading

- [Simple Classes](simple_classes.md) — the short guide to classes, constructors, and auto-construction
- [Classes and Objects](classes-and-objects.md) — full class reference: inheritance, virtual dispatch, destructors, and more
- [User-Defined Types](user-defined-types.md) — plain `TYPE` records, `CREATE`, and value semantics