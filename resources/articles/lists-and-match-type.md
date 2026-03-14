# Lists and MATCH TYPE in FasterBASIC

*Heterogeneous collections and safe type dispatch — store anything in a list, then handle each element by its actual type.*

---

## Introduction

FasterBASIC includes a **LIST** data structure — a dynamic, ordered collection that can hold integers, floats, strings, nested lists, and even class instances, all in the same list. Combined with **MATCH TYPE**, you get a safe, expressive way to process mixed-type data without manual type-tag bookkeeping.

If you've used pattern matching in Rust, Swift, or Scala, MATCH TYPE will feel familiar. If you haven't — it's just a smarter SELECT CASE that branches on the *type* of a value instead of its contents.

---

## Creating Lists

### Typed Lists

A list with a specific element type — all elements are the same type:

```
DIM numbers AS LIST OF INTEGER = LIST(10, 20, 30, 40, 50)
DIM names AS LIST OF STRING = LIST("Alice", "Bob", "Carol")
DIM temperatures AS LIST OF DOUBLE = LIST(36.6, 37.1, 38.5)
```

### Mixed Lists (LIST OF ANY)

A list that can hold elements of different types:

```
DIM mixed AS LIST OF ANY = LIST(42, "hello", 3.14, "world", 100)
```

LIST OF ANY is the key enabler for MATCH TYPE — each element carries a type tag at runtime so you can safely determine what it is.

### Empty Lists

```
DIM empty AS LIST OF INTEGER = LIST()
DIM emptyAny AS LIST OF ANY = LIST()
```

---

## List Operations

Lists support a rich set of operations via method-call syntax:

### Adding Elements

| Method | Description | Example |
|--------|-------------|---------|
| `.APPEND(value)` | Add to the end | `names.APPEND("Dave")` |
| `.PREPEND(value)` | Add to the front | `names.PREPEND("Zara")` |
| `.INSERT(index, value)` | Insert at position | `names.INSERT(2, "Eve")` |

### Removing Elements

| Method | Description | Returns |
|--------|-------------|---------|
| `.SHIFT()` | Remove and return the first element | The removed element |
| `.POP()` | Remove and return the last element | The removed element |
| `.REMOVE(index)` | Remove element at position | — |
| `.CLEAR()` | Remove all elements | — |

### Accessing Elements

| Method | Description |
|--------|-------------|
| `.HEAD()` | Return the first element (without removing) |
| `.GET(index)` | Return element at position |
| `.LENGTH()` | Return the number of elements |
| `.EMPTY()` | Return 1 if the list has no elements |

### Transforming

| Method | Description |
|--------|-------------|
| `.COPY()` | Return a shallow copy of the list |
| `.REVERSE()` | Return a reversed copy |
| `.REST()` | Return everything except the first element |

### Searching

| Method | Description |
|--------|-------------|
| `.CONTAINS(value)` | Return 1 if the value is in the list |
| `.INDEXOF(value)` | Return the position of the value (-1 if not found) |

### String Lists

| Method | Description |
|--------|-------------|
| `.JOIN(separator)` | Join all elements into a single string |

---

## Iterating with FOR EACH

The natural way to walk through a list is `FOR EACH`:

### Single-Variable Form

```
DIM colors AS LIST OF STRING = LIST("red", "green", "blue")

FOR EACH c IN colors
    PRINT c
NEXT c
```

Output:
```
red
green
blue
```

### Two-Variable Form (for LIST OF ANY)

When iterating over a LIST OF ANY, you can capture both the type tag and the raw value:

```
DIM mixed AS LIST OF ANY = LIST(42, "hello", 3.14)

FOR EACH T, E IN mixed
    PRINT "Type tag: "; T; " Value: "; E
NEXT T
```

The two-variable form is primarily useful with MATCH TYPE, which gives you a much cleaner way to dispatch on type.

---

## MATCH TYPE — Safe Type Dispatch

MATCH TYPE is the heart of working with heterogeneous data. It examines the runtime type of an expression and executes the first matching arm, binding the value to a correctly-typed variable:

```
DIM items AS LIST OF ANY = LIST(42, "hello", 3.14)

FOR EACH E IN items
    MATCH TYPE E
        CASE INTEGER n%
            PRINT "Integer: "; n%
        CASE STRING s$
            PRINT "String: "; s$
        CASE DOUBLE f#
            PRINT "Double: "; f#
    END MATCH
NEXT E
```

Output:
```
Integer: 42
String: hello
Double: 3.14
```

### How It Works

1. MATCH TYPE reads the **runtime type tag** of the expression
2. It walks the CASE arms **in order** and finds the first match
3. The matched value is loaded into the **binding variable** with the correct type
4. The arm's body executes with that variable in scope
5. After the arm body, execution jumps to `END MATCH`

Only **one arm** ever executes per MATCH TYPE — the first one that matches.

### Binding Variables

Each CASE arm declares a binding variable that exists only inside that arm's body. The variable name should use the appropriate BASIC type suffix:

| CASE Type | Suffix | Example |
|-----------|--------|---------|
| `CASE INTEGER` | `%` | `CASE INTEGER n%` |
| `CASE LONG` | `&` | `CASE LONG n&` |
| `CASE SINGLE` | `!` | `CASE SINGLE f!` |
| `CASE DOUBLE` | `#` | `CASE DOUBLE f#` |
| `CASE STRING` | `$` | `CASE STRING s$` |
| `CASE LIST` | (none) | `CASE LIST sub` |
| `CASE OBJECT` | (none) | `CASE OBJECT obj` |
| `CASE ClassName` | (none) | `CASE Dog d` |

The compiler validates that the suffix matches the declared type — `CASE INTEGER s$` is an error.

---

## Matching on Class Types

This is where MATCH TYPE becomes truly powerful. When your list contains class instances, you can match on the **specific class** — not just "is it an object?", but "is it a Dog? a Cat? a Vehicle?":

```
CLASS Animal
    Name AS STRING
    CONSTRUCTOR(n AS STRING)
        ME.Name = n
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

CLASS Cat EXTENDS Animal
    CONSTRUCTOR(n AS STRING)
        SUPER(n)
    END CONSTRUCTOR
    METHOD Speak() AS STRING
        RETURN "Meow!"
    END METHOD
END CLASS

' Build a list with different types of objects AND basic types
DIM things AS LIST OF ANY = LIST(NEW Dog("Rex"), 42, NEW Cat("Mimi"), "hello")

FOR EACH E IN things
    MATCH TYPE E
        CASE Dog d
            PRINT d.Name; " says "; d.Speak()
        CASE Cat c
            PRINT c.Name; " says "; c.Speak()
        CASE INTEGER n%
            PRINT "Number: "; n%
        CASE STRING s$
            PRINT "Text: "; s$
    END MATCH
NEXT E
```

Output:
```
Rex says Woof!
Number: 42
Mimi says Meow!
Text: hello
```

Inside each class-specific arm, the binding variable is fully typed — you can call methods and access fields directly.

### Inheritance-Aware Matching

Class matching respects the inheritance hierarchy. A `CASE Animal` arm will match **any** Animal — Dogs, Cats, and any other subclass:

```
DIM zoo AS LIST OF ANY = LIST(NEW Dog("Rex"), NEW Cat("Mimi"), NEW Dog("Spot"))

FOR EACH E IN zoo
    MATCH TYPE E
        CASE Animal a
            PRINT a.Name; " says "; a.Speak()
    END MATCH
NEXT E
```

Output:
```
Rex says Woof!
Mimi says Meow!
Spot says Woof!
```

Even though the variable `a` is typed as Animal, virtual dispatch ensures that each object's own `Speak()` method is called.

### Specific Before General

Because arms are checked in declaration order, put **specific** classes before **general** ones:

```
FOR EACH E IN zoo
    MATCH TYPE E
        CASE Dog d
            PRINT "Specifically a dog: "; d.Name
        CASE Animal a
            PRINT "Some other animal: "; a.Name
    END MATCH
NEXT E
```

Output:
```
Specifically a dog: Rex
Some other animal: Mimi
Specifically a dog: Spot
```

If you put `CASE Animal` first, it would catch everything and `CASE Dog` would never fire.

### Generic OBJECT Catch-All

`CASE OBJECT` matches **any** object regardless of class — it's the object equivalent of `CASE ELSE`:

```
DIM items AS LIST OF ANY = LIST(NEW Dog("Rex"), NEW Cat("Luna"), 99)

FOR EACH E IN items
    MATCH TYPE E
        CASE Dog d
            PRINT "Dog: "; d.Name
        CASE OBJECT obj
            PRINT "Some other object"
        CASE INTEGER n%
            PRINT "Number: "; n%
    END MATCH
NEXT E
```

Output:
```
Dog: Rex
Some other object
Number: 99
```

---

## CASE ELSE

`CASE ELSE` matches anything that no previous arm caught. It must be the **last** arm:

```
DIM data AS LIST OF ANY = LIST(42, "hello", 3.14, NEW Dog("Rex"))

FOR EACH E IN data
    MATCH TYPE E
        CASE INTEGER n%
            PRINT "Integer: "; n%
        CASE STRING s$
            PRINT "String: "; s$
        CASE ELSE
            PRINT "Something else"
    END MATCH
NEXT E
```

Output:
```
Integer: 42
String: hello
Something else
Something else
```

---

## Control Flow Inside Arms

MATCH TYPE arms are full statement blocks — you can use IF/ELSE, FOR loops, variable declarations, and any other BASIC statement:

```
DIM values AS LIST OF ANY = LIST(5, -3, "short", "a longer string")

FOR EACH E IN values
    MATCH TYPE E
        CASE INTEGER n%
            IF n% > 0 THEN
                PRINT n%; " is positive"
            ELSE
                PRINT n%; " is negative"
            END IF
        CASE STRING s$
            IF LEN(s$) > 5 THEN
                PRINT s$; " is long"
            ELSE
                PRINT s$; " is short"
            END IF
    END MATCH
NEXT E
```

Output:
```
5 is positive
-3 is negative
short is short
a longer string is long
```

---

## Practical Patterns

### Accumulation by Type

Count or sum elements by their type:

```
DIM data AS LIST OF ANY = LIST(5, "hi", 10, " ", 15, "world")
DIM intSum AS INTEGER = 0
DIM strConcat AS STRING = ""

FOR EACH E IN data
    MATCH TYPE E
        CASE INTEGER n%
            LET intSum = intSum + n%
        CASE STRING s$
            LET strConcat = strConcat + s$
    END MATCH
NEXT E

PRINT "Sum of integers: "; intSum
PRINT "Concatenated strings: "; strConcat
```

Output:
```
Sum of integers: 30
Concatenated strings: hi world
```

### Type Counting

```
DIM items AS LIST OF ANY = LIST(1, "a", 2.718, "b", 3, 1.414, "c")
DIM intCount AS INTEGER = 0
DIM strCount AS INTEGER = 0
DIM dblCount AS INTEGER = 0

FOR EACH E IN items
    MATCH TYPE E
        CASE INTEGER n%
            LET intCount = intCount + 1
        CASE STRING s$
            LET strCount = strCount + 1
        CASE DOUBLE f#
            LET dblCount = dblCount + 1
    END MATCH
NEXT E

PRINT "Integers: "; intCount; " Strings: "; strCount; " Doubles: "; dblCount
```

### Object Collection Processing

Process a heterogeneous list of class instances:

```
DIM pets AS LIST OF ANY = LIST(NEW Dog("Rex"), NEW Cat("Luna"), NEW Dog("Buddy"), NEW Cat("Mimi"))
DIM dogNames AS STRING = ""
DIM catNames AS STRING = ""

FOR EACH E IN pets
    MATCH TYPE E
        CASE Dog d
            IF LEN(dogNames) > 0 THEN
                LET dogNames = dogNames + ", " + d.Name
            ELSE
                LET dogNames = d.Name
            END IF
        CASE Cat c
            IF LEN(catNames) > 0 THEN
                LET catNames = catNames + ", " + c.Name
            ELSE
                LET catNames = c.Name
            END IF
    END MATCH
NEXT E

PRINT "Dogs: "; dogNames
PRINT "Cats: "; catNames
```

Output:
```
Dogs: Rex, Buddy
Cats: Luna, Mimi
```

### Multiple Match Blocks

You can have multiple MATCH TYPE blocks in the same loop, or process the same list multiple times with different match patterns:

```
DIM data AS LIST OF ANY = LIST(NEW Dog("Rex"), 42, NEW Cat("Luna"))

FOR EACH T, E IN data
    ' First match: class dispatch
    MATCH TYPE E
        CASE Dog d
            PRINT "Dog: "; d.Name
        CASE Cat c
            PRINT "Cat: "; c.Name
        CASE ELSE
            PRINT "Not a pet"
    END MATCH

    ' Second match: inheritance-based dispatch
    MATCH TYPE E
        CASE Animal a
            PRINT "  (is an animal: "; a.Speak(); ")"
        CASE ELSE
            PRINT "  (not an animal)"
    END MATCH
NEXT T
```

Output:
```
Dog: Rex
  (is an animal: Woof!)
Not a pet
  (not an animal)
Cat: Luna
  (is an animal: Meow!)
```

---

## ENDMATCH Syntax

You can use either `END MATCH` (two words) or `ENDMATCH` (one word) to close a MATCH TYPE block:

```
MATCH TYPE E
    CASE INTEGER n%
        PRINT n%
    CASE STRING s$
        PRINT s$
ENDMATCH
```

Both forms are equivalent.

---

## Supported CASE Types

The complete list of types you can match on:

| CASE | Matches | Atom Tag |
|------|---------|----------|
| `CASE INTEGER` | 32-bit integers | `ATOM_INT (1)` |
| `CASE LONG` | 64-bit integers | `ATOM_INT (1)` |
| `CASE SINGLE` | 32-bit floats | `ATOM_FLOAT (2)` |
| `CASE DOUBLE` | 64-bit floats | `ATOM_FLOAT (2)` |
| `CASE STRING` | Strings | `ATOM_STRING (3)` |
| `CASE LIST` | Nested lists | `ATOM_LIST (4)` |
| `CASE OBJECT` | Any object (any class) | `ATOM_OBJECT (5)` |
| `CASE *ClassName*` | Specific class (with inheritance) | `ATOM_OBJECT (5)` + `class_is_instance` |
| `CASE ELSE` | Anything not matched above | — |

Note that `INTEGER` and `LONG` share the same atom tag, as do `SINGLE` and `DOUBLE`. You cannot have both `CASE INTEGER` and `CASE LONG` in the same MATCH TYPE block — the compiler will report a duplicate arm error.

However, you **can** have multiple class-specific arms (`CASE Dog`, `CASE Cat`, `CASE Vehicle`) since each class is a distinct type.

---

## How MATCH TYPE Resolves Class Names

When the compiler encounters a `CASE` arm with an identifier that isn't a built-in type keyword, it uses the static type information it already knows:

1. **CLASS lookup** — the compiler checks its class registry. If the name matches a declared CLASS, the arm becomes a class-specific match. At runtime, `class_is_instance()` is called to check the object's class (walking the inheritance chain).

2. **TYPE (UDT) lookup** — if the name isn't a CLASS, the compiler checks for a user-defined TYPE. UDTs are value types and cannot currently be stored in LIST OF ANY, so UDT-specific arms are reserved for future variant/tagged-union support.

3. **Unknown name** — if the name isn't found as either a CLASS or TYPE, the compiler emits a warning and treats the arm as a generic OBJECT match.

This resolution happens at compile time — there's no string comparison at runtime. Class matching uses integer class IDs, which are fast.

---

## Tips and Best Practices

1. **Always put specific types before general types.** `CASE Dog` before `CASE Animal` before `CASE OBJECT` before `CASE ELSE`. The first match wins.

2. **Use CASE ELSE as a safety net.** If you don't cover all possible types and there's no CASE ELSE, unmatched elements are silently skipped. Add CASE ELSE to catch unexpected types during development.

3. **MATCH TYPE is safe.** Unlike manual type-tag inspection, MATCH TYPE fuses the type check and the typed binding — you can't accidentally read an integer as a string.

4. **Prefer single-variable FOR EACH for MATCH TYPE.** The simpler `FOR EACH E IN list` form works well with MATCH TYPE. The two-variable `FOR EACH T, E IN list` form is there when you need it, but MATCH TYPE makes the type tag variable (`T`) unnecessary.

5. **Class instances in lists need LIST OF ANY.** A typed list like `LIST OF INTEGER` can only hold integers. To mix objects and basic types, use `LIST OF ANY`.

6. **Empty lists are fine.** Iterating over an empty list simply executes zero iterations — no MATCH TYPE arms fire.

7. **You can have multiple MATCH TYPE blocks per iteration.** Each block is independent and evaluates the expression fresh.

---

## Quick Reference

```
' Create a mixed list
DIM stuff AS LIST OF ANY = LIST(42, "hello", NEW Dog("Rex"), 3.14)

' Add elements
stuff.APPEND(NEW Cat("Luna"))
stuff.PREPEND(99)

' Iterate and dispatch by type
FOR EACH E IN stuff
    MATCH TYPE E
        CASE INTEGER n%
            PRINT "Int: "; n%
        CASE STRING s$
            PRINT "Str: "; s$
        CASE Dog d
            PRINT "Dog: "; d.Name; " says "; d.Speak()
        CASE Cat c
            PRINT "Cat: "; c.Name; " says "; c.Speak()
        CASE DOUBLE f#
            PRINT "Dbl: "; f#
        CASE ELSE
            PRINT "Unknown type"
    END MATCH
NEXT E
```

---

## Further Reading

- [MATCH RECEIVE — Typed Message Dispatch](match-receive.md) — the same dispatch pattern applied to worker messages instead of list elements
- [Classes and Objects](classes-and-objects.md) — the full CLASS system: fields, methods, inheritance, constructors, destructors, and virtual dispatch
- [Workers: Safe Concurrency](workers.md) — the full worker system: SPAWN, AWAIT, SEND, RECEIVE, MARSHALL, and cooperative cancellation
- [NEON SIMD Support](neon-simd-support.md) — automatic vectorization for User-Defined Types