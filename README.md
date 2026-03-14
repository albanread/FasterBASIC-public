# FasterBASIC

Welcome to the public source repository for **FasterBASIC**.

## What is FasterBASIC?
FasterBASIC is a modern, high-performance dialect of the classic BASIC programming language. It is designed to be fast, expressive, and easy to use while providing a robust set of modern development tools and language features.

Key features include:
* **High-Performance Compiler:** A natively compiled toolchain written in Zig, capable of JIT execution and Ahead-Of-Time binary compilation. The AOT compiler logic is seamlessly integrated into Zig, enabling native macOS `.app` bundle output.

#### Powered by Zig
FasterBASIC is built upon and integrated tightly with the [Zig programming language](https://ziglang.org/). We owe a massive debt of gratitude to the Zig project and its vibrant community for providing the exceptional toolchain and language that makes this high-performance BASIC dialect possible.
* **EdAlone Development Environment:** A lightweight, dedicated graphical IDE complete with smart typing assistance, a built-in terminal, and visual diagnostic tools.
* **Modern Language Capabilities:** Brings traditional BASIC into the modern era with classes and objects, complex numbers, advanced array processing, and robust data structures.
* **Rich Multimedia Integration:** First-class support for canvas drawing, sprite management, and an interactive audio event system.

## About This Repository
This repository is the **Clean Public Mirror** for the FasterBASIC project. 

Because the internal development repository contains massive LLVM toolchains, gigabytes of local build environment caches, and complex build harnesses, it is not well-suited for a standard public Git host. To make the code easily accessible, this repository acts as a clean, text-only publication of the project's source code and resources.

### Repository Structure
* `/compiler/` - The core FasterBASIC compiler (`zfb2026B`) built with and integrated into Zig, alongside its internal documentation.
* `/editor/` - Source code for `EdAlone`, the FasterBASIC text editor, interacting natively with macOS graphics and audio APIs.
* `/resources/` - A comprehensive collection of FasterBASIC documentation, demo programs, tutorials, and language articles.

---
*Note: This repository is updated via an automated sync from the internal development monorepo.*
