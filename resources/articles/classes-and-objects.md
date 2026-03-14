# Classes and Objects in FasterBASIC

*Object-oriented programming for BASIC — classes, inheritance, constructors, and virtual dispatch, all in familiar syntax.*

---

## Introduction

FasterBASIC includes a full **CLASS & Object System** that brings object-oriented programming to BASIC without sacrificing simplicity. You can define classes with fields and methods, build inheritance hierarchies, override methods with virtual dispatch, and manage object lifetimes automatically.

If you've used classes in Python, Java, or Visual Basic, you'll feel right at home — but everything still looks and feels like BASIC.

---

## Your First Class

A class is defined with `CLASS ... END CLASS`. Fields are declared directly, and methods are defined inline:

```
CLASS Greeter
    Name AS STRING
    Volume AS INTEGER

    CONSTRUCTOR(n AS STRING)
        ME.Name = n
        ME.Volume = 1
    END CONSTRUCTOR

    METHOD Hello() AS STRING
        IF ME.Volume > 5 THEN
            RETURN "HELLO, " + ME.Name + "!!!"
        ELSE
            RETURN "Hello, " + ME.Name + "."
        END IF
    END METHOD
END CLASS

DIM g AS Greeter = NEW Greeter("World")
PRINT g.Hello()
' Output: Hello, World.
```

Key points:
- **Fields** are declared with `Name AS Type` (no `DIM` keyword inside the class body)
- **`ME`** refers to the current object instance (like `self` or `this` in other languages)
- **`NEW ClassName(args)`** creates a new instance and calls the constructor
- **Methods** can return values with `AS Type` and `RETURN`

---

## Fields

Fields define the data stored in each object instance. Every field gets a default value of zero/empty when the object is created:

```
CLASS Player
    Name AS STRING
    Score AS INTEGER
    Health AS DOUBLE
    Active AS INTEGER
END CLASS

DIM p AS Player = NEW Player()
PRINT p.Name            ' (empty string)
PRINT p.Score           ' 0
PRINT p.Health          ' 0.0
```

Supported field types:

| Type | Description |
|------|-------------|
| `INTEGER` | 32-bit signed integer |
| `LONG` | 64-bit signed integer |
| `SINGLE` | 32-bit float |
| `DOUBLE` | 64-bit float |
| `STRING` | String (managed) |
| `BYTE`, `SHORT` | Small integer types |
| *ClassName* | Reference to another class instance |

---

## Constructors

A constructor initializes a new object. It runs automatically when you call `NEW`:

```
CLASS Rectangle
    Width AS DOUBLE
    Height AS DOUBLE

    CONSTRUCTOR(w AS DOUBLE, h AS DOUBLE)
        ME.Width = w
        ME.Height = h
    END CONSTRUCTOR

    METHOD Area() AS DOUBLE
        RETURN ME.Width * ME.Height
    END METHOD
END CLASS

DIM r AS Rectangle = NEW Rectangle(10.0, 5.0)
PRINT "Area: "; r.Area()
' Output: Area: 50
```

### Zero-Argument Constructors

If your constructor takes no arguments, you still need the parentheses on `NEW`:

```
CLASS Counter
    Count AS INTEGER

    CONSTRUCTOR()
        ME.Count = 0
    END CONSTRUCTOR

    METHOD Increment()
        ME.Count = ME.Count + 1
    END METHOD

    METHOD GetCount() AS INTEGER
        RETURN ME.Count
    END METHOD
END CLASS

DIM c AS Counter = NEW Counter()
c.Increment()
c.Increment()
c.Increment()
PRINT "Count: "; c.GetCount()
' Output: Count: 3
```

### No Constructor

If you don't define a constructor at all, objects are simply zero-initialized. You can set fields after creation:

```
CLASS Point
    X AS INTEGER
    Y AS INTEGER
END CLASS

DIM p AS Point = NEW Point()
p.X = 10
p.Y = 20
PRINT p.X; ", "; p.Y
' Output: 10, 20
```

---

## Methods

Methods are functions that belong to a class. They access the object's fields through `ME`:

```
CLASS Circle
    Radius AS DOUBLE

    CONSTRUCTOR(r AS DOUBLE)
        ME.Radius = r
    END CONSTRUCTOR

    METHOD Area() AS DOUBLE
        RETURN 3.14159265 * ME.Radius * ME.Radius
    END METHOD

    METHOD Circumference() AS DOUBLE
        RETURN 2.0 * 3.14159265 * ME.Radius
    END METHOD

    METHOD Describe() AS STRING
        RETURN "Circle(r=" + STR$(ME.Radius) + ")"
    END METHOD

    METHOD Scale(factor AS DOUBLE)
        ME.Radius = ME.Radius * factor
    END METHOD
END CLASS

DIM c AS Circle = NEW Circle(5.0)
PRINT c.Describe()
PRINT "Area: "; c.Area()
c.Scale(2.0)
PRINT "After scaling: "; c.Describe()
```

### Methods That Return Values

Add `AS Type` after the parameter list:

```
METHOD FullName() AS STRING
    RETURN ME.First + " " + ME.Last
END METHOD
```

### Methods That Don't Return Values

Omit the `AS Type`:

```
METHOD Reset()
    ME.Count = 0
END METHOD
```

### Methods With Parameters

```
METHOD MoveTo(newX AS INTEGER, newY AS INTEGER)
    ME.X = newX
    ME.Y = newY
END METHOD
```

---

## Inheritance

Classes can extend other classes with `EXTENDS`. The child class inherits all fields and methods from the parent:

```
CLASS Animal
    Name AS STRING
    Legs AS INTEGER

    CONSTRUCTOR(n AS STRING, l AS INTEGER)
        ME.Name = n
        ME.Legs = l
    END CONSTRUCTOR

    METHOD Speak() AS STRING
        RETURN "..."
    END METHOD

    METHOD Describe() AS STRING
        RETURN ME.Name + " (" + STR$(ME.Legs) + " legs)"
    END METHOD
END CLASS

CLASS Dog EXTENDS Animal
    Breed AS STRING

    CONSTRUCTOR(name AS STRING, breed AS STRING)
        SUPER(name, 4)
        ME.Breed = breed
    END CONSTRUCTOR

    METHOD Speak() AS STRING
        RETURN "Woof!"
    END METHOD
END CLASS

CLASS Cat EXTENDS Animal
    Indoor AS INTEGER

    CONSTRUCTOR(name AS STRING, indoor AS INTEGER)
        SUPER(name, 4)
        ME.Indoor = indoor
    END CONSTRUCTOR

    METHOD Speak() AS STRING
        RETURN "Meow!"
    END METHOD
END CLASS
```

Key points:

- **`EXTENDS`** declares the parent class
- **`SUPER(args)`** calls the parent constructor — must be in the child's constructor
- **Method override** — just define a method with the same name in the child class
- Child classes inherit all fields and methods from the parent
- You can add new fields and methods in the child

### Using Inherited Classes

```
DIM rex AS Dog = NEW Dog("Rex", "Labrador")
PRINT rex.Describe()      ' inherited from Animal
PRINT rex.Speak()          ' overridden in Dog
PRINT rex.Breed            ' own field

' Output:
'   Rex (4 legs)
'   Woof!
'   Labrador
```

### Multi-Level Inheritance

You can extend a class that itself extends another:

```
CLASS GuideDog EXTENDS Dog
    Handler AS STRING

    CONSTRUCTOR(name AS STRING, handler AS STRING)
        SUPER(name, "Labrador")
        ME.Handler = handler
    END CONSTRUCTOR

    METHOD Describe() AS STRING
        RETURN ME.Name + " (guide dog for " + ME.Handler + ")"
    END METHOD
END CLASS

DIM g AS GuideDog = NEW GuideDog("Buddy", "Alice")
PRINT g.Describe()    ' GuideDog's version
PRINT g.Speak()       ' inherited from Dog
```

---

## Virtual Dispatch (Polymorphism)

When you call a method on an object, FasterBASIC calls the **most specific version** — the one defined on the object's actual class, not the variable's declared type. This is called virtual dispatch:

```
DIM a AS Animal

a = NEW Dog("Rex", "Lab")
PRINT a.Speak()        ' "Woof!" — calls Dog's Speak, not Animal's

a = NEW Cat("Mimi", 1)
PRINT a.Speak()        ' "Meow!" — calls Cat's Speak
```

This works because every object carries a pointer to its class's **vtable** (virtual method table). The runtime looks up the correct method at the point of call.

### Why This Matters

Virtual dispatch lets you write code that works with any class in a hierarchy without knowing the specific type:

```
' A function that works with ANY Animal
FUNCTION DescribeAnimal(a AS Animal) AS STRING
    DescribeAnimal = a.Describe() + " says " + a.Speak()
END FUNCTION

DIM dog AS Dog = NEW Dog("Rex", "Lab")
DIM cat AS Cat = NEW Cat("Whiskers", 0)

PRINT DescribeAnimal(dog)    ' "Rex (4 legs) says Woof!"
PRINT DescribeAnimal(cat)    ' "Whiskers (4 legs) says Meow!"
```

---

## Type Checking with IS

The `IS` operator checks whether an object is an instance of a specific class. It respects inheritance — a Dog IS an Animal:

```
DIM d AS Dog = NEW Dog("Rex", "Lab")

PRINT d IS Dog       ' 1 (true)
PRINT d IS Animal    ' 1 (true — Dog extends Animal)
PRINT d IS Cat       ' 0 (false)
```

### Checking for NOTHING

An uninitialized or deleted object reference is `NOTHING`. Check for it with `IS NOTHING`:

```
DIM p AS Animal
PRINT p IS NOTHING     ' 1 (true — not yet assigned)

p = NEW Dog("Spot", "Beagle")
PRINT p IS NOTHING     ' 0 (false — assigned)
```

---

## Destructors

A destructor runs automatically when an object is cleaned up. Use it for logging, cleanup, or resource management:

```
CLASS Connection
    Host AS STRING

    CONSTRUCTOR(h AS STRING)
        ME.Host = h
        PRINT "Connected to "; h
    END CONSTRUCTOR

    DESTRUCTOR()
        PRINT "Disconnected from "; ME.Host
    END DESTRUCTOR
END CLASS

DIM c AS Connection = NEW Connection("example.com")
' ... use the connection ...
DELETE c
' Output:
'   Connected to example.com
'   Disconnected from example.com
```

### DELETE

`DELETE` explicitly destroys an object, calls its destructor, and sets the variable to `NOTHING`:

```
DELETE c
PRINT c IS NOTHING    ' 1 (true)
```

### Automatic Cleanup with SAMM

By default, FasterBASIC's **Scope-Aware Memory Manager** (SAMM) automatically cleans up objects when they go out of scope. You don't need to call `DELETE` manually in most cases — it's there for when you want explicit control.

---

## Object References (Pointer Semantics)

Class instances use **reference semantics** — assigning one object variable to another doesn't copy the object; both variables point to the same object:

```
DIM p1 AS Animal = NEW Animal("Rex", 4)
DIM p2 AS Animal
p2 = p1                ' p2 now points to the SAME object

p2.Name = "Buddy"
PRINT p1.Name          ' "Buddy" — same object!
```

This is different from UDTs (`TYPE ... END TYPE`), which use value semantics and are copied on assignment.

---

## Deferred Construction

You don't have to create an object immediately. Declare the variable, then assign later:

```
DIM player AS Character

IF difficulty = "easy" THEN
    player = NEW Warrior("Tank", 200)
ELSE
    player = NEW Mage("Gandalf", 50)
END IF

PRINT player.Describe()
```

Before assignment, the variable is `NOTHING` — always check with `IS NOTHING` if you're unsure.

---

## Initialising Fields with WITH

When you need to set fields that have non-trivial values — especially nested class fields that require their own constructor arguments — attach a `WITH` block directly to the `DIM` line:

```
CLASS Engine
    Horsepower AS INTEGER
    CONSTRUCTOR(hp AS INTEGER)
        ME.Horsepower = hp
    END CONSTRUCTOR
END CLASS

CLASS Car
    Brand  AS STRING
    Motor  AS Engine

    CONSTRUCTOR(b AS STRING)
        ME.Brand = b
    END CONSTRUCTOR
END CLASS

DIM c AS Car("Tesla") WITH
    .Motor = NEW Engine(670)
END WITH

PRINT c.Brand + " " + STR$(c.Motor.Horsepower) + " HP"
' Output: Tesla 670 HP
```

The `WITH` block runs immediately after construction.  You can set any number of fields and call methods in the same block:

```
DIM c AS Car("BMW") WITH
    .Motor    = NEW Engine(330)
    .Motor.Horsepower = 335   ' fine-tune after assignment
END WITH
```

You can also use `WITH` as a standalone statement to configure an existing variable or descend into a sub-object:

```
WITH c.Motor
    .Horsepower = 400
END WITH
```

See [WITH…END WITH](with.md) for the complete reference.

---

## Object Fields (Composition)

A class field can be another class instance, enabling composition:

```
CLASS Engine
    Horsepower AS INTEGER

    CONSTRUCTOR(hp AS INTEGER)
        ME.Horsepower = hp
    END CONSTRUCTOR
END CLASS

CLASS Car
    Brand AS STRING
    Motor AS Engine

    CONSTRUCTOR(b AS STRING, hp AS INTEGER)
        ME.Brand = b
        ME.Motor = NEW Engine(hp)
    END CONSTRUCTOR

    METHOD Describe() AS STRING
        RETURN ME.Brand + " (" + STR$(ME.Motor.Horsepower) + " HP)"
    END METHOD
END CLASS

DIM c AS Car = NEW Car("Tesla", 670)
PRINT c.Describe()
' Output: Tesla (670 HP)
```

---

## Factory Functions

Functions can create and return class instances. SAMM automatically manages the object's lifetime across scope boundaries:

```
FUNCTION CreateAnimal(species AS STRING) AS Animal
    IF species = "dog" THEN
        CreateAnimal = NEW Dog("Rex", "Mixed")
    ELSE
        CreateAnimal = NEW Cat("Mimi", 1)
    END IF
END FUNCTION

DIM pet AS Animal = CreateAnimal("dog")
PRINT pet.Speak()
' Output: Woof!
```

---

## Quick Reference

| Feature | Syntax |
|---------|--------|
| Define a class | `CLASS Name ... END CLASS` |
| Field | `FieldName AS Type` |
| Constructor | `CONSTRUCTOR(params) ... END CONSTRUCTOR` |
| Destructor | `DESTRUCTOR() ... END DESTRUCTOR` |
| Method | `METHOD Name(params) AS Type ... END METHOD` |
| Create instance | `DIM x AS ClassName = NEW ClassName(args)` |
| Create with inline init | `DIM x AS ClassName(args) WITH … END WITH` |
| Init existing variable | `WITH x … END WITH` |
| Access field | `x.FieldName` |
| Call method | `x.MethodName(args)` |
| Inherit | `CLASS Child EXTENDS Parent` |
| Call parent constructor | `SUPER(args)` |
| Type check | `x IS ClassName` |
| Null check | `x IS NOTHING` |
| Delete | `DELETE x` |
| Self reference | `ME` |

---

## Common Patterns

### The Builder Pattern

```
CLASS QueryBuilder
    Query AS STRING

    CONSTRUCTOR()
        ME.Query = ""
    END CONSTRUCTOR

    METHOD Select(fields AS STRING) AS QueryBuilder
        ME.Query = "SELECT " + fields
        RETURN ME
    END METHOD

    METHOD From(table AS STRING) AS QueryBuilder
        ME.Query = ME.Query + " FROM " + table
        RETURN ME
    END METHOD

    METHOD Build() AS STRING
        RETURN ME.Query
    END METHOD
END CLASS
```

### The Template Method Pattern

```
CLASS Report
    Title AS STRING

    METHOD Header() AS STRING
        RETURN "=== " + ME.Title + " ==="
    END METHOD

    METHOD Body() AS STRING
        RETURN "(no content)"
    END METHOD

    METHOD Generate() AS STRING
        RETURN ME.Header() + CHR$(10) + ME.Body()
    END METHOD
END CLASS

CLASS SalesReport EXTENDS Report
    Total AS DOUBLE

    CONSTRUCTOR(t AS DOUBLE)
        ME.Title = "Sales Report"
        ME.Total = t
    END CONSTRUCTOR

    METHOD Body() AS STRING
        RETURN "Total sales: $" + STR$(ME.Total)
    END METHOD
END CLASS
```

---

## Tips

1. **Always initialize fields in the constructor** — fields default to zero/empty, but explicit initialization makes your intent clear.

2. **Use SAMM (Scope-Aware Memory Manager)** — automatic memory management prevents leaks and dangling references. It's on by default.

3. **Put specific classes before general ones in MATCH TYPE** — when matching on class types in a list, the first matching arm wins. Put `CASE Dog` before `CASE Animal`.

4. **Prefer composition over deep inheritance** — a Car that HAS an Engine is often clearer than a Car that IS a Vehicle that IS a Machine.

5. **Keep classes focused** — a class should do one thing well. If it's getting too big, break it into smaller classes.

---

## Further Reading

- [Simple Classes](simple_classes.md) — the short guide: auto-construction, implicit ME, arrays, and WITH
- [WITH…END WITH](with.md) — full reference for the object initialiser block
- [Lists and MATCH TYPE](lists-and-match-type.md) — store objects in heterogeneous lists and dispatch on their class at runtime
- [NEON SIMD Support](neon-simd-support.md) — automatic vectorization for UDT types