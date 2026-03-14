# fbzig — FasterBASIC inside the Zig Compiler

**fbzig** is a fork of the [Zig compiler](https://github.com/ziglang/zig) that adds
FasterBASIC as a first-class language in the Zig toolchain.

The goal is a single binary — `zig` — that can compile BASIC, Zig, and C/C++
programs to native executables on multiple architectures, sharing the same LLVM
backend, linker, and standard toolchain infrastructure, with all three languages
able to interoperate in the same build — producing one executable from a mix of
`.zig`, `.bas`, and `.c` source files.

---

## Current Status

As of 2026-03-07, there are two distinct states to be aware of in this repository:

1. The main FasterBASIC-integrated tree documents the existing integration surface and historical work.
2. A separate clean Zig `0.15.2` port is in progress under `tmp/stable-zig-0.15.2/zig-0.15.2-git`.

The stable-port effort exists because the earlier integration base was using an unstable Zig revision. The current objective is to carry the FasterBASIC integration onto a source-built stable compiler baseline.

### Stable toolchain baseline

That baseline work is complete:

- official Zig `0.15.2` source was downloaded and built
- LLVM 20, Clang, LLD, libc++, libc++abi, and libunwind were rebuilt from source into `deps/llvm20-install`
- Zig `0.15.2` was rebuilt against that controlled toolchain
- the resulting compiler was validated successfully with `zig version` and `zig env`

On macOS, the rebuilt `zig` binary now links only against `libSystem` dynamically; the vendored LLVM/Clang/LLD/C++ stack is supplied from the custom source build rather than Homebrew packages.

### Stable-port implementation status

The stable checkout already contains these imported or modified pieces:

- imported `lib/compiler/basic/`
- imported `src/libs/basic_runtime.zig`
- imported `tools/basic-smoke.sh`
- `build.zig` wiring for the `basic_compiler` module
- in-progress edits to `src/main.zig`, `src/dev.zig`, `src/Compilation.zig`, `src/link/Lld.zig`, and `src/link/MachO.zig`

This means the toolchain migration phase is complete, while the compiler-integration phase is still in progress.

### Immediate next phase

The next implementation phase is to finish and validate the stable `0.15.2` BASIC pipeline:

- complete the remaining `Compilation.zig` integration work
- confirm linker-side handling of BASIC objects and BASIC runtime archives
- rebuild the stable checkout with the new patches
- run smoke tests against the stable `zig basic` path

---

## Concept

The Zig compiler is already a multi-language toolchain:

| Command | Language |
|---|---|
| `zig build-exe` | Zig |
| `zig cc` / `zig c++` | C / C++ (via Clang/Aro) |
| `zig translate-c` | C → Zig transpiler |
| `zig rc` | Windows Resource files (via Resinator) |

**fbzig adds:**

| Command | Language |
|---|---|
| `zig basic` | FasterBASIC |
| `zig build-exe main.zig engine.bas renderer.c` | Mixed Zig + BASIC + C |

FasterBASIC is a structured, modern BASIC dialect with:
- Full type system (INTEGER, DOUBLE, STRING, arrays, user types, classes)
- Concurrency (WORKER / SPAWN / AWAIT)
- Native graphics, audio, and sprite APIs
- LLVM-native code generation via LLJIT (in-process) or AOT (native executable)
- A memory manager (SAMM — Scope-Aware Memory Manager) with automatic cleanup

---

## Repository Structure

```
fbzig/
  src/
    main.zig              ← Zig CLI entry point — 'zig basic' dispatch added here
    dev.zig               ← Feature flags — basic_command added here
    Compilation.zig       ← Core compilation engine — BasicObject/work queue added here (deep integration)
    Compilation/
      Config.zig          ← any_basic_source_files flag added here (deep integration)
    link/
      MachO.zig           ← basic_object_table hooks added here (deep integration)
      Lld.zig             ← basic_object_table hooks added here (deep integration)
    ...                   ← All standard Zig compiler source (otherwise unchanged)

  lib/
    compiler/
      basic/              ← FasterBASIC compiler pipeline
        compiler_llvm.zig ← Compiler module root (re-exports all stages)
        lexer.zig         ← Lexical analysis
        token.zig         ← Token types and locations
        parser.zig        ← Recursive descent parser → AST
        ast.zig           ← AST node definitions
        ast_optimize.zig  ← Constant folding, dead-code elim on AST
        semantic.zig      ← Semantic analysis, type checking, symbol table
        cfg.zig           ← Control-flow graph construction
        llvm_c.zig        ← LLVM C API bindings (@cImport)
        llvm_state.zig    ← LLVM module / context / builder lifetime
        llvm_builder.zig  ← LLVM IR emission helpers
        llvm_codegen.zig  ← Main code generator (AST → LLVM IR)
        llvm_jit.zig      ← LLJIT in-process execution
        llvm_runtime.zig  ← Runtime function registration
        codegen_helpers.zig
        codegen_types.zig
        jit_shared.zig    ← Shared-memory JIT channel (used by Ed editor)
        runtime/          ← BASIC runtime library (C + Zig)
      aro/                ← Zig's existing C frontend (unchanged)
      translate-c/        ← Zig's existing C→Zig transpiler (unchanged)
      resinator/          ← Zig's existing RC compiler (unchanged)
      ...

  build.zig               ← Zig's build system (LLVM deps wired here; basic module added for deep integration)
```

---

## Architecture: Deep Integration

BASIC is compiled the same way C is compiled — as a first-class
input type to the `Compilation` engine, producing a `.o` file that the existing
linker backends consume directly.

The `zig` binary already has all of LLVM statically linked into it (via `build.zig`
lines `mod.addIncludePath(llvm_include_dir)` / `mod.addLibraryPath(llvm_lib_dir)` /
`addCMakeLibraryList(llvm_libraries)`). When the BASIC pipeline modules
(`llvm_codegen.zig`, `llvm_state.zig`, etc.) are compiled as part of that same
binary, `@cImport("llvm-c/Core.h")` resolves naturally and every `LLVM*` symbol is
already present.

The pattern follows how C source files are handled today:

```
CSourceFile  →  c_object_work_queue  →  workerUpdateCObject
                                              │  (spawns zig clang, produces .o)
                                              ▼
                                       c_object_table  →  linker backends

BasicSourceFile → basic_object_work_queue → workerUpdateBasicObject
                                              │  (in-process pipeline, produces .o)
                                              ▼
                                       basic_object_table → linker backends
```

`workerUpdateBasicObject` runs the entire pipeline in-process on a thread-pool
worker — the same thread pool used by Zig and C compilation. It calls:

```
LLVMState.init()
  → Lexer → Parser → SemanticAnalyzer → ASTOptimizer → CFGBuilder
  → CodeGenerator.generateWithProgram()
  → LLVMTargetMachineEmitToFile()   ← emits .o to cache
```

The `.o` lands in `basic_object_table`. Every linker backend (`MachO.zig`,
`Lld.zig`, etc.) already iterates `c_object_table.keys()` to collect objects for
linking — an identical loop over `basic_object_table.keys()` is all that is needed
in each backend.

### Mixed-language build example

With deep integration complete, a mixed build looks like this — entirely inside
the normal Zig toolchain, no special flags:

```bash
# Command line — one exe from three languages:
zig build-exe main.zig engine.bas renderer.c -O2 -target aarch64-linux-gnu -o game

# build.zig — same thing via the build system:
const root_module = b.createModule(.{
  .root_source_file = b.path("main.zig"),
  .target = target,
  .optimize = optimize,
});
const exe = b.addExecutable(.{ .name = "game", .root_module = root_module });
exe.addBasicSourceFile(.{ .file = b.path("engine.bas") });
exe.addCSourceFile(.{ .file = b.path("renderer.c"), .flags = &.{"-O2"} });
```

All three pipelines run concurrently on the thread pool. All three produce `.o`
files with compatible ABI for the target. LLD/MachO links them in one pass. The
same target triple, optimisation level, and linker flags apply to all of them.

### Files that were changed for deep integration

| File | Change |
|---|---|
| `src/Compilation.zig` | Add `BasicSourceFile`, `BasicObject`, `basic_object_work_queue`, `basic_object_table`, `workerUpdateBasicObject`, `updateBasicObject` (~200 lines) |
| `src/Compilation/Config.zig` | Add `any_basic_source_files: bool` |
| `src/main.zig` | Change `zig basic` dispatch from `jitCmd` to `buildOutputType`; add `.bas` to `FileExt` and `classifyFileExt` |
| `src/link/MachO.zig` | Add `basic_object_table` loop alongside existing `c_object_table` loop |
| `src/link/Lld.zig` | Same |
| `src/link/Plan9.zig`, `src/link/Coff.zig` | Same |
| `build.zig` | Add `basic` pipeline module; runtime C files via `addCSourceFiles` |

The pipeline modules in `lib/compiler/basic/` are used as-is. No changes to
`lexer.zig`, `parser.zig`, `semantic.zig`, `cfg.zig`, `llvm_codegen.zig`, etc.

---

## How It Works (Current State & Recent Optimisations)

We have successfully completed deep integration of the `zig basic` compilation process.

### Test Automation & Corpus
The corpus of FasterBASIC tests in `basic/*.bas` and `basic/fails/*.bas` has been fully validated against the zig-integrated runtime. We fixed missing imports and duplicated symbols in `lib/compiler/basic/runtime/runtime_entry.zig`. 
To ensure ongoing stability, we introduced:
- `tools/basic-smoke.sh`: An automated test suite runner that asserts expected `PASS` and `FAIL` compilation behaviors across the 71-file test corpus.
- `runbas.sh`: A straightforward, single-file runner designed for quick iterative development.

### Linker GC & Binary Size Optimisation
Initially, `zig basic` executables suffered from code bloat (e.g., a simple HELLO.BAS was ~923KB) because the entire BASIC runtime—including unused heavy subsystems like SAMM (Scope-Aware Memory Manager), hash maps, and array math—was statically linked into every binary.

We implemented strict dead-code stripping natively via the Zig compiler API.
By patching `src/main.zig` and `src/libs/basic_runtime.zig` to enforce:
- `function_sections = true` (`-ffunction-sections`)
- `data_sections = true` (`-fdata-sections`)
- `linker_gc_sections = true` (macOS `-dead_strip` / ELF `--gc-sections`)

Executable sizes dropped by approximately **50%** (e.g., ~432KB for HELLO.BAS). The linker now successfully prunes unused runtime features (like `_array_qsort_*` or `_hashmap_clear`) organically.

*Note: A future pass may target remaining SAMM lifecycle hooks that currently evade the linker GC.*

### Compiler Pipeline

```
.bas source
    │
    ▼  lexer.zig
Token stream
    │
    ▼  parser.zig
AST (Abstract Syntax Tree)
    │
    ▼  ast_optimize.zig
Optimised AST (constant folding, dead-code elimination)
    │
    ▼  semantic.zig
Symbol table + validated AST
    │
    ▼  cfg.zig
Control-Flow Graph
    │
    ▼  llvm_codegen.zig
LLVM IR module
    │
    ▼  LLVM optimisation passes (-O0 … -O3)
    │
    ├──▶ LLJIT (in-process execution)              --jit / --run
    └──▶ LLVMTargetMachineEmitToFile → .o file
              │
              └──▶ linker (MachO/LLD/COFF)  →  native executable
```

### Modes

| Flag | What happens |
|---|---|
| `zig basic input.bas -o prog` | AOT compile → native executable |
| `zig basic input.bas --jit` | JIT compile and run in-process |
| `zig basic input.bas --run` | JIT run, pass remaining args to program |
| `zig basic input.bas -i` | Emit LLVM IR to stdout |
| `zig basic input.bas -i -o out.ll` | Write LLVM IR to file |
| `zig basic --help` | Show full usage |

### Optimisation

| Flag | LLVM passes |
|---|---|
| `-O0` | `default<O0>` |
| `-O1` | `default<O1>` (JIT default) |
| `-O2` | `default<O2>` (AOT default) |
| `-O3` | `default<O3>` |
| `--no-optimize` | `default<O0>` |

---

## Runtime

The BASIC runtime is a set of Zig and C modules that are compiled into the
executable alongside the generated code. They provide:

| Module | Responsibility |
|---|---|
| `samm_core`, `samm_pool`, `samm_scope` | SAMM memory manager — automatic scope-based cleanup |
| `memory_mgmt` | Object allocation / deallocation |
| `string_ops`, `string_utf32`, `string_pool` | String operations and interning |
| `array_ops`, `array_descriptor_runtime` | Array allocation and bounds checking |
| `list_ops` | Dynamic lists |
| `math_ops` | Math builtins (SIN, COS, LOG, etc.) |
| `io_ops`, `io_ops_format`, `terminal_io` | PRINT, INPUT, file I/O |
| `binary_io` | Binary file I/O |
| `class_runtime` | User-defined types and classes |
| `conversion_ops` | Type coercion (INT↔DOUBLE↔STRING) |
| `fbc_bridge` | Runtime ABI bridge between BASIC and C |
| `marshalling` | Cross-language data marshalling |
| `messaging` | WORKER message passing (SEND/RECEIVE) |
| `basic_data` | Built-in data constants |
| `hashmap_runtime` | Hash map (used by SELECT/MATCH) |
| `basic_runtime.c` | Core C runtime functions |
| `worker_runtime.c` | Worker thread management |
| `runtime_shims.c` | Platform compatibility shims |

---

## SAMM — Scope-Aware Memory Manager

SAMM is the BASIC runtime's memory model. It eliminates the need for explicit
`DELETE` in most cases by automatically releasing objects when their enclosing
scope exits.

Key properties:
- **Scope stack** — each `SUB`/`FUNCTION`/block pushes a scope; on exit, all
  objects allocated in that scope are freed.
- **Bloom filter** — fast per-scope object membership test, O(1) average.
- **Background worker** — deferred cleanup runs on a low-priority thread to avoid
  stalling the main program.
- **Retain/release** for long-lived objects that escape their scope (assigned to
  globals, passed to workers, etc.).
- **Double-free protection** — the bloom filter catches accidental double-frees.

---

## Relationship to Ed-BASIC

[Ed-BASIC](../Ed-BASIC/) is the graphical editor + compiler that originated this
compiler. fbzig takes only the compiler pipeline from Ed-BASIC (no editor, no Metal
rendering, no AppKit UI) and integrates it into the Zig toolchain.

```
Ed-BASIC (this stays as-is)
  Ed editor (Metal/AppKit GUI)
  fbc_cli.zig          ─── copied ──▶  fbzig/lib/compiler/basic/fbc_cli.zig
  compiler pipeline    ─── copied ──▶  fbzig/lib/compiler/basic/*.zig
  runtime/             ─── copied ──▶  fbzig/lib/compiler/basic/runtime/

fbzig (this repo)
  Zig compiler + toolchain
  + zig basic command
  + FasterBASIC pipeline
```

Ed-BASIC continues to develop independently. Periodically, compiler improvements
are synced into fbzig by re-copying the relevant files.

---

## Development Plan

The development history now has two tracks:

- the original integration phases on the earlier Zig base
- the active stable-port phases for Zig `0.15.2`

### Stable Port Phases

#### Phase S1 — Stable Toolchain Baseline ✅ Complete

- [x] download official Zig `0.15.2` source
- [x] build LLVM 20, Clang, LLD, libc++, libc++abi, and libunwind from source into `deps/llvm20-install`
- [x] rebuild Zig `0.15.2` against that controlled toolchain
- [x] validate the resulting compiler with `zig version` and `zig env`
- [x] confirm the macOS binary links only against `libSystem` dynamically

#### Phase S2 — Stable Compiler Port In Progress

- [x] import `lib/compiler/basic/` into the clean stable checkout
- [x] import `src/libs/basic_runtime.zig`
- [x] import `tools/basic-smoke.sh`
- [x] wire `build.zig` to the `basic_compiler` module using the custom LLVM headers
- [ ] finish `src/main.zig` stable CLI integration for `zig basic` and BASIC file ownership flow
- [ ] finish `src/Compilation.zig` stable BASIC object/runtime pipeline integration
- [ ] finish linker-side inclusion of BASIC objects and BASIC runtime archives
- [ ] rebuild the stable checkout with the new integration patches

#### Phase S3 — Stable Validation

- [ ] verify `zig basic hello.bas -o hello && ./hello` on the stable `0.15.2` branch
- [ ] verify mixed Zig + BASIC + C linking on the stable branch
- [ ] run `tools/basic-smoke.sh` against the stable branch compiler
- [ ] document any API or behavior differences between the legacy integration and the stable port

#### Phase S4 — Runtime Packaging

- [ ] ship prebuilt BASIC runtime archives for supported release targets
- [ ] use a shipped runtime archive by default and only do late runtime compilation when no matching archive is available
- [ ] keep source-runtime compilation as a developer fallback path

Current fast-path workflow on macOS:

- run `tools/build-macguiruntime-prebuilt.sh` to build `macgui/prebuilt/libmacguiruntime-macos-<arch>.a`
- run `cmake --build build-local --target stage3-macgui-runtime-prebuilt -j 8` or `ZIG_REBUILD_MODE=prebuilt-runtime ./rebuild.sh` to rebuild the archive and sync it into `build-local/stage3/lib/zig/macgui/prebuilt/`
- set `MACGUI_RUNTIME_ARCHES="aarch64 x86_64"` before that command to refresh both shipped macOS runtime archives in one pass

### Legacy Integration Phases

### Phase 1 — Plumbing ✅ Complete
- [x] Fork ziglang/zig as fbzig
- [x] Copy Ed-BASIC compiler pipeline into `lib/compiler/basic/`
- [x] Add `zig basic` command dispatch in `src/main.zig`
- [x] Add `basic_command` feature flag in `src/dev.zig`
- [x] Stub/isolate AppKit-specific externs in `fbc_cli.zig` (`runWithAppKit` is a no-op)
- [x] Build `build/stage3/bin/zig` successfully (zig 0.16.0)

### Phase 2 — Deep Integration ✅ Complete

> BASIC is a first-class input type in `Compilation.zig`,
> exactly parallel to how `.c` files are handled. This enables mixed
> Zig + BASIC + C builds in a single executable.

- [x] Add `BasicSourceFile` struct and `any_basic_source_files` to `src/Compilation/Config.zig`
- [x] Add `BasicObject`, `basic_object_work_queue`, `basic_object_table` to `src/Compilation.zig`
- [x] Implement `updateBasicObject` — runs the full pipeline in-process, emits `.o` to cache
- [x] Add `basic_object_table` iteration in linker backends (`MachO.zig`, `Lld.zig`, etc.)
- [x] Add `basic` pipeline module to `build.zig` (so LLVM headers resolve and runtime C files compile)
- [x] Add dispatch in `src/main.zig` via `buildOutputType`
- [x] Add `.bas` to `FileExt` and `classifyFileExt` in `src/main.zig`
- [x] Verify: `zig basic hello.bas -o hello && ./hello`
- [x] Verify: `zig build-exe main.zig engine.bas -o prog` (mixed Zig + BASIC)

### Phase 3 — C Interop ✅ Complete
- [x] `zig build-exe main.zig engine.bas renderer.c -o prog` (Zig + BASIC + C in one exe)
- [x] BASIC `EXTERN` declaration calls a Zig or C function across the ABI boundary
- [x] Zig calls exported BASIC functions via `extern` declarations
- [x] C calls exported BASIC functions via normal C `extern` declarations

### Phase 4 — Build System Integration ✅ Complete On Legacy Branch
- [x] `exe.addBasicSourceFile()` method in `std.Build.Step.Compile`
- [x] `build.zig` scanner recognises `.bas` files in module source lists
- [x] Cross-compilation: `zig build-exe -target aarch64-linux-gnu main.zig engine.bas`
  Verified with `./build/stage3/bin/zig build-exe -target aarch64-linux-gnu -fPIC tmp/phase3/main.zig tmp/phase3/engine.bas tmp/phase3/renderer.c -OReleaseSafe -femit-bin=tmp/phase3/prog_aarch64 --cache-dir tmp/phase3/cache-cross1 --zig-lib-dir /Volumes/xb/fbzig/lib`.
  Resulting artifacts are target-correct ELF files (`tmp/phase3/prog_aarch64` and cached `engine.o` are both `ELF 64-bit LSB aarch64`).

### Phase 5 — Toolchain Features
- [ ] `zig basic fmt` — BASIC source formatter
- [ ] `zig basic ast-check` — fast syntax check without full compilation
- [ ] `zig basic translate` — transpile BASIC to Zig (experimental)
- [ ] LSP integration (reuse Ed's symbol index for IDE support)

### Phase 6 — Platform Portability
- [ ] Linux x86_64 support (remove any remaining macOS-specific guards)
- [ ] Windows support
- [ ] All LLVM-supported architectures inherit automatically (aarch64, riscv64, wasm32, etc.)

---

## Building fbzig

> **Prerequisites:** LLVM 21, CMake, a C/C++ compiler.
> A pre-built LLVM 21 install is already present in `deps/llvm21-install/`.

```bash
# The build directory and stage3 binary already exist:
#   build/stage3/bin/zig  (zig 0.16.0)

# To rebuild from scratch:
cd build
cmake .. -DZIG_STATIC_LLVM=ON \
         -DCMAKE_BUILD_TYPE=Release \
         -DLLVM_DIR=../deps/llvm21-install/lib/cmake/llvm \
         -DLLVM_CONFIG_EXE=../deps/llvm21-install/bin/llvm-config
make -j$(nproc)
```

## BASIC Smoke Tests

Run the curated BASIC integration smoke suite:

```bash
./tools/basic-smoke.sh
```

This script compiles all `basic/*.bas` (expected pass) and validates the current
baseline expectations under `basic/fails/*.bas`.


Examples that now work:

```bash
./zig basic hello.bas -o hello && ./hello
./zig build-exe main.zig engine.bas renderer.c -o program
```

## Raspberry Pi ARM32 Cross-Build (Verified)

The mixed Zig+BASIC+C path is verified for ARM32 Linux targets used by Raspberry Pi.

Use `arm` as the architecture and specify the Pi generation via `-mcpu=...`.
Do not use `armv7a` / `armv6kz` as architecture tokens in `-target`.

Known-good command pattern:

```bash
./build/stage3/bin/zig build-exe \
  -target arm-linux-gnueabihf -mcpu=arm1176jzf_s -lc -fPIC \
  tmp/phase3/main.zig tmp/phase3/engine.bas tmp/phase3/renderer.c \
  -OReleaseSafe -femit-bin=tmp/phase3/prog_rpi
```

Verified target/cpu combinations:

- `-target arm-linux-gnueabihf -mcpu=arm1176jzf_s` (Pi 1 / Zero style)
- `-target arm-linux-gnueabihf -mcpu=cortex_a7` (Pi 2 style)
- `-target arm-linux-gnueabi -mcpu=arm1176jzf_s`
- `-target arm-linux-musleabihf -mcpu=arm1176jzf_s`

Verification result: produced ARM EABI5 ELF executables and ARM32 ELF BASIC objects (`engine.o`).

---

## Key Design Decisions

**Why deep integration?**
Deep integration treats `.bas` exactly like `.c` in `Compilation.zig`, so Zig,
BASIC, and C modules compile to object files under one compilation graph and link
together in one executable. This avoids duplicating LLVM toolchain state, keeps
target/optimisation/link settings consistent across languages, and enables direct
cross-language symbol interop (BASIC `EXTERN`, Zig `extern`, and C `extern`) in a
single linker pass.

**Why copy files rather than a submodule?**
Ed-BASIC's compiler files are tightly coupled to Ed's build system and some
platform externs. Copying allows us to make fbzig-specific adaptations without
forking Ed-BASIC. A sync script keeps them in step.

**Why keep Ed-BASIC separate?**
Ed-BASIC has a full GUI editor, live JIT execution, audio, Metal graphics, and
macOS-specific platform code that is deliberately out of scope for fbzig. They
share a compiler pipeline but serve different purposes.
