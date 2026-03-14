# FasterBASIC Zig Compiler Design

This article provides a high-level overview of the experimental FasterBASIC compiler rewrite in Zig. This implementation aims to leverage Zig's improved safety, compile-time features, and explicit error handling to create a more robust and maintainable compiler infrastructure compared to the original C++ codebase.

## Architectural Overview

The Zig implementation follows a classic multi-pass compiler architecture.

### Compilation Pipeline

1.  **Read Source**: Loads the `.bas` file into memory.
2.  **Lexing**: Converts source text into a flat stream of tokens (`[]const Token`).
3.  **Parsing**: Converts the token stream into an Abstract Syntax Tree (AST).
4.  **Semantic Analysis**:
    *   Builds the symbol table.
    *   Resolves types (Type Checking).
    *   Validates variable and function usage.
5.  **CFG Construction**: Converts the AST into a Control Flow Graph of Basic Blocks.
6.  **Code Generation**: Walks the CFG to emit QBE Intermediate Language (IL).
7.  **Backend (External)**: Invokes QBE to generate assembly, then `cc`/`ld` to link.

## Component Breakdown

### 1. Lexer (`lexer.zig`)
The lexer produces a slice of `Token` structs. Unlike the C++ iterator approach, it generates all tokens upfront (or in large chunks), simplifying lookahead in the parser.
*   **Key Feature**: Source locations are preserved in every token for accurate error reporting.

### 2. Parser (`parser.zig`)
A recursive descent parser that constructs the AST.
*   **Precedence Climbing**: Used for efficient expression parsing.
*   **Memory Management**: Uses an `ast.Builder` which abstracts the allocation strategy (likely an arena allocator), enforcing strict lifetime management.
*   **Error Handling**: Uses Zig's error unions (`!Node`) rather than C++ exceptions. This makes failure paths explicit and prevents "invisible" crashes.

### 3. Semantic Analysis (`semantic.zig`)
This module is responsible for type correctness and scope management.
*   **Type System**: Types are represented by the `BaseType` tagged union (e.g., `.integer`, `.single`, `.string`, `.user_defined`).
*   **Symbol Table**: Uses `std.StringHashMap` to map identifiers to their definitions.
*   **Validation**: Checks for "variable not declared", "type mismatch", and validates function signatures.

### 4. CFG Builder (`cfg.zig`)
This is a major departure from the C++ version (which generated code directly from the AST).
*   **Basic Blocks**: The code is broken down into blocks of linear instructions.
*   **Edges**: Jump/Branch instructions define the edges between blocks.
*   **Control Structures**: High-level constructs like `IF`, `WHILE`, and `FOR` are lowered into raw control flow edges here. This simplifies the backend significantly.

### 5. Code Generator (`codegen.zig`)
The code generator takes the CFG and emits QBE IL.
*   **RPO Traversal**: content is emitted by walking the CFG in Reverse Post-Order.
*   **Type Mapping**: Maps `BaseType` semantic types to QBE types (`w`, `l`, `s`, `d`).
*   **State Management**: `FunctionContext` tracks stack slots for locals and parameters.

## Key Design Differences (vs C++)

| Feature | C++ Implementation | Zig Implementation |
| :--- | :--- | :--- |
| **Error Handling** | Exceptions (`try`/`catch`) | Error Unions (`!T`) + Diagnostics List |
| **Memory** | Smart Pointers / Manual `new` | Arena Allocators / Explicit `deinit` |
| **Parsing** | Iterator-based | Slice-based |
| **Codegen** | Recursive AST Walk | CFG-Driven (Linearized) |
| **Type Info** | Class Inheritance | Tagged Unions |

## Why Zig?

*   **Safety**: Spatial memory safety (slices) prevents buffer overflows.
*   **No Hidden Control Flow**: Lack of exceptions makes the compiler's own control flow easier to reason about.
*   **Build System**: Zig's build system replaces Makefiles/CMake, handling dependencies and cross-compilation internally.
