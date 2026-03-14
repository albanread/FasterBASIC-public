# Simple Classes in FasterBASIC

*The short guide — classes without ceremony.*

---

If you've read the full [Classes and Objects](classes-and-objects.md) article, you know everything that's *possible*. This guide covers what you'll actually do *most of the time*, with the simplest syntax possible.

---

## The Simplest Class

```
CLASS Point
    X AS INTEGER
    Y AS INTEGER
END CLASS
```

That's it. No constructor needed. Just declare the fields.

Use it:

```
DIM p AS Point
p.X = 10
p.Y = 20
PRINT p.X; ", "; p.Y
' Output: 10, 20
```

`DIM p AS Point` automatically creates a ready-to-use `Point` object. You don't need `NEW Point()`.

---

## Adding a Constructor

A constructor lets you set fields at creation time:

```
CLASS Point
    X AS INTEGER
    Y AS INTEGER

    CONSTRUCTOR(x AS INTEGER, y AS INTEGER)
        X = x
        Y = y
    END CONSTRUCTOR
END CLASS
```

Notice: inside a method or constructor, you can write just `X` instead of `ME.X`. FasterBASIC resolves bare field names to the current object automatically.

Use it with arguments:

```
DIM p AS Point(3, 7)
PRINT p.X; ", "; p.Y
' Output: 3, 7
```

`DIM p AS Point(3, 7)` is shorthand for `DIM p AS Point = NEW Point(3, 7)`. The parenthesised arguments go directly on the `DIM` line.

---

## Adding Methods

Methods are functions that belong to the class. They can read and set fields without `ME.`:

```
CLASS Rectangle
    Width  AS DOUBLE
    Height AS DOUBLE

    CONSTRUCTOR(w AS DOUBLE, h AS DOUBLE)
        Width  = w
        Height = h
    END CONSTRUCTOR

    METHOD Area() AS DOUBLE
        RETURN Width * Height
    END METHOD

    METHOD Describe() AS STRING
        RETURN STR$(Width) + " x " + STR$(Height)
    END METHOD
END CLASS

DIM r AS Rectangle(4.0, 3.0)
PRINT r.Describe()        ' 4 x 3
PRINT "Area: "; r.Area()  ' Area: 12
```

---

## Nullary (No-Argument) Constructors

If your constructor takes no arguments, `DIM` creates the object for you automatically:

```
CLASS Counter
    Count AS INTEGER

    CONSTRUCTOR()
        Count = 0
    END CONSTRUCTOR

    METHOD Increment()
        Count = Count + 1
    END METHOD

    METHOD Value() AS INTEGER
        RETURN Count
    END METHOD
END CLASS

DIM c AS Counter       ' automatically constructed — no NEW needed
c.Increment()
c.Increment()
PRINT c.Value()        ' 2
```

---

## Classes That Contain Other Classes

A field can be another class. If that inner class has a nullary constructor, it is built automatically when the outer object is created:

```
CLASS Engine
    Horsepower AS INTEGER

    CONSTRUCTOR()
        Horsepower = 100
    END CONSTRUCTOR
END CLASS

CLASS Car
    Brand  AS STRING
    Motor  AS Engine

    CONSTRUCTOR(b AS STRING)
        Brand = b
    END CONSTRUCTOR

    METHOD Describe() AS STRING
        RETURN Brand + " (" + STR$(Motor.Horsepower) + " HP)"
    END METHOD
END CLASS

DIM c AS Car("Toyota")
PRINT c.Describe()    ' Toyota (100 HP)
```

`Motor` is created automatically as part of building the `Car` — you don't write `Motor = NEW Engine()` anywhere.

---

## Arrays of Classes

Declare an array of class instances with the usual `DIM arr(n) AS ClassName` syntax. Every element is constructed automatically:

```
CLASS Slot
    Value AS INTEGER

    CONSTRUCTOR()
        Value = 0
    END CONSTRUCTOR
END CLASS

DIM slots(5) AS Slot

FOR i = 1 TO 5
    slots(i).Value = i * 10
NEXT i

FOR i = 1 TO 5
    PRINT slots(i).Value
NEXT i
' Output: 10, 20, 30, 40, 50
```

### Arrays with Constructor Arguments

If every element should start with the same arguments, put them on the `DIM` line:

```
CLASS Sensor
    Threshold AS DOUBLE

    CONSTRUCTOR(t AS DOUBLE)
        Threshold = t
    END CONSTRUCTOR
END CLASS

DIM sensors(4) AS Sensor(0.5)   ' each Sensor is constructed with threshold = 0.5

FOR i = 1 TO 4
    PRINT sensors(i).Threshold
NEXT i
' Output: 0.5  0.5  0.5  0.5
```

---

## Inheritance in One Paragraph

Use `EXTENDS` to build on an existing class. Override any method simply by defining it in the child. Call the parent's constructor with `SUPER(...)`:

```
CLASS Animal
    Name AS STRING

    CONSTRUCTOR(n AS STRING)
        Name = n
    END CONSTRUCTOR

    METHOD Speak() AS STRING
        RETURN "..."
    END METHOD
END CLASS

CLASS Dog EXTENDS Animal
    CONSTRUCTOR(n AS STRING)
        SUPER(n)
    END CONSTRUCTOR

    METHOD Speak() AS STRING
        RETURN "Woof!"
    END METHOD
END CLASS

DIM d AS Dog("Rex")
PRINT d.Name          ' Rex   (inherited field)
PRINT d.Speak()       ' Woof! (overridden method)
```

---

## ME — When You Do Need It

Inside a method, bare names resolve to fields automatically. You only need `ME` when:

- There is a **name clash** between a parameter and a field:

```
METHOD SetName(Name AS STRING)
    ME.Name = Name    ' ME.Name = field, Name = parameter
END METHOD
```

- You are **returning the object itself** (e.g. for method chaining):

```
METHOD Reset() AS Counter
    Count = 0
    RETURN ME
END METHOD
```

Otherwise, just write the field name directly.

---

## Initialising Fields with WITH

When a class has fields that need values other than their defaults — especially nested class fields — attach a `WITH` block directly to the `DIM` line:

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

The `WITH` block runs immediately after construction. You can set any number of fields and call methods:

```
DIM ctr AS Counter WITH
    .Add(5)
    .Add(3)
END WITH
PRINT ctr.Value()    ' 8
```

You can also use `WITH` on its own — useful when you want to configure an existing variable or descend into a sub-object:

```
WITH c.Food
    .Calories = 120
END WITH
```

See [WITH…END WITH](with.md) for the full reference.

---

## Automatic Cleanup

FasterBASIC's memory manager (SAMM) cleans up objects when they go out of scope. You don't need to free anything manually. If you want to clean up early, use `DELETE`:

```
DELETE c     ' destructor runs, c becomes NOTHING
```

---

## Quick-Reference Cheat Sheet

| What you want | Syntax |
|---|---|
| Declare and auto-create | `DIM x AS MyClass` |
| Declare with arguments | `DIM x AS MyClass(arg1, arg2)` |
| Array, auto-create each | `DIM arr(n) AS MyClass` |
| Array with same args each | `DIM arr(n) AS MyClass(arg)` |
| Access a field | `x.Field` |
| Call a method | `x.Method(args)` |
| Field inside method/ctor | `Field` *(bare name, no ME needed)* |
| Refer to self explicitly | `ME` |
| Check if nothing | `x IS NOTHING` |
| Inherit | `CLASS Child EXTENDS Parent` |
| Call parent constructor | `SUPER(args)` |
| Destroy early | `DELETE x` |
| Initialise fields after construction | `WITH x ... END WITH` |
| Init inline on DIM | `DIM x AS Type(args) WITH ... END WITH` |

---

## What to Read Next

- [Classes and Objects](classes-and-objects.md) — full reference: virtual dispatch, type checking, destructors, factory functions, and more patterns.
- [WITH…END WITH](with.md) — full reference for the object initialiser block.
- [User-Defined Types](user-defined-types.md) — plain `TYPE` structs (value semantics, no methods) for lightweight data records.
- [Lists and MATCH TYPE](lists-and-match-type.md) — store objects of different classes in a single list and dispatch on type at runtime.