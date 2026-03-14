# Review: FasterBASIC – Modern Power in Classic Syntax

Thank you for purchasing FasterBASIC - (joking) - FasterBASIC is free and open.
FasterBASIC is a compiler that generates high-performance native machine code quickly.

This compiler is under development consider this an alpha release, it is free for use at your own risk, although we aim to make it as safe as we can.
Not recommended for use in nuclear reactors or medical equipment, or safety critical systems.

Normally you running FasterBASIC using the provided editor.  And once happy you can build a program.

FasterBASIC can run the code your Grandparents wrote, while also making full use of your powerful new 21st century hardware.

We believe that people should be able to program their computers, themselves.

So we provide this easy to use fully documented language complete with a full help system that means you can work on your programs with the Internet turned-off.

Modern GUI apps are just not simple.
So we provide an editor environment and a graphics window you can use.


## 1. True Object-Oriented Programming
FasterBASIC introduces a simple class system that feels natural alongside standard `DIM` and `PRINT` statements.
- **Classes & Inheritance**: You can define classes with `CLASS ... END CLASS`, fields, methods, and constructors. It supports single inheritance (`EXTENDS`) and virtual dispatch (polymorphism).
- **Memory Management**: We dont collect garbage here, we use **SAMM** (Scope-Aware Memory Manager). Objects are automatically cleaned up when they go out of scope, freeing developers from manual `DELETE` calls while avoiding the pauses of a garbage collector.
- **Syntactic Sugar**: Keywords like `ME` (similar to `this` or `self`) and `SUPER` make OOP logic clear and readable.

## 2. Safe Concurrency with Workers
 Instead of dangerous threads with shared state (and imponderable race conditions that come with them), FasterBASIC uses the safe **Actor Model**.
- **Workers**: Defined with `WORKER ... END WORKER`, these are isolated functions that run on separate OS threads.
- **Isolation**: Workers cannot access global variables. Data is passed in by value and returned by value.
- **Spawn & Await**: The syntax `SPAWN WorkerName(args)` returns a handle, which can later be resolved with `AWAIT handle`. This makes parallel processing (like background calculations) safe and predictable.
- **Common use cases**: A typical bounce scenario where the parent (the main program) sends a message to a Worker, and the worker sends the same object back, is optimized.


## 3. High-Performance Arrays (SIMD)
FasterBASIC includes a powerful engine for array mathematics that leverages **NEON SIMD** instructions on ARM64 processors.
- **Vectorized Math**: Expressions like `arrC = arrA + arrB * 2.0` operate on entire arrays at once. The compiler lowers these to SIMD instructions, processing multiple elements per CPU cycle.
- **Reduction & Broadcast**: It supports reduction functions (e.g., `MAX(arr)`) and scalar broadcasting (adding a single number to every element of an array) without writing loops.
- **Performance**: For heavy number-crunching (physics, image processing), this offers performance comparable to optimized C code.

## 4. Modern Type System & Pattern Matching
While it supports traditional types (`INTEGER`, `DOUBLE`, `STRING`), the language adds modern flexibility:
- **Lists**: `LIST OF ANY` allows for heterogeneous collections of objects.
- **Pattern Matching**: The `MATCH TYPE` statement is a type-safe switch for objects. It allows you to inspect an object's runtime type (e.g., `CASE Dog`, `CASE Cat`) and executes the specific block for that type. This works hand-in-hand with the class system.

## 5. Traditional Roots
FasterBASIC is not ashamed it respects its BASIC heritage:
- **Proud to be BASIC**: Goes out of its way to support all the classic BASIC features we remember.
- **File I/O**: It supports the classic `OPEN "file.txt" FOR OUTPUT AS #1` syntax, including `BINARY` and `RANDOM` access modes.
- **UDTs**: User-Defined Types (`TYPE ... END TYPE`) are present for C-struct-like data organization with value semantics.

## 6. The Zig-Based Compiler
The compiler itself, is written in Zig, this is a modern safe language.
- **Architecture**: It uses a multi-pass design (Lexing → Parsing → Semantic Analysis → CFG Construction → Code Generation).
- **Backend**: It emits LLVM, which is then compiled to machine code. This allows the compile to create code that is nearly as fast as C.
- **JIT Compilation**:  JIT compilation, allows BASIC code to be compiled and run immediately in memory.

## Hope
We hope that FasterBASIC bridges the gap between the simplicity of BASIC and the performance/safety of modern systemm. 
By enforcing isolation in workers, providing automatic memory management, and compiling to native code, BASIC can be a surprisingly robust platform for development, proving that BASIC is far from dead—it just needed an upgrade.