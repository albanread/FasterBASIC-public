# FasterBASIC Integration Changes

This document summarizes the Zig-side changes made to integrate FasterBASIC into this repository.

It distinguishes between:

- committed changes visible in `git log`
- current integration work visible in the tracked worktree diff

## Evidence Base

The list below was derived from:

- `git log` for the relevant Zig integration files
- the current tracked worktree diff
- the current source tree in the integration touchpoints

## What Git History Records

Because this repository was moved, not all original FasterBASIC commit hashes are reachable in the current local history.

In the current repository, the reachable git history on the integration touchpoints shows this overlapping commit:

- `89c5a5c9` - `Add local compiler rebuild support`

Despite the generic commit message, this commit overlaps the FasterBASIC import and integration surface in this repo snapshot. On the FasterBASIC touchpoints, it includes:

- `build.zig`
- `src/dev.zig`
- `src/main.zig`
- `src/Compilation.zig`
- `src/Compilation/Config.zig`
- `src/link/Lld.zig`
- `src/link/MachO.zig`
- `lib/compiler/build_runner.zig`
- the full `lib/compiler/basic/` tree
- `tools/basic-smoke.sh`

On those paths, the commit adds 71 files and approximately 107,108 lines.

## Stable Zig 0.15.2 Port Status

As of 2026-03-07, the repository also contains a separate in-progress port of the FasterBASIC integration onto a clean Zig `0.15.2` source checkout.

This work is taking place in:

- `tmp/stable-zig-0.15.2/zig-0.15.2-git`

The purpose of that branch is to move the integration off the earlier unstable Zig base and onto a reproducible, source-built stable compiler.

### Toolchain baseline completed

The stable baseline has been built successfully from source.

Completed work:

- downloaded official Zig `0.15.2` source
- built LLVM/Clang/LLD/libc++/libc++abi/libunwind from source into `deps/llvm20-install`
- rebuilt Zig `0.15.2` against that custom LLVM install
- validated the resulting binary with:
	- `zig version` -> `0.15.2`
	- `zig env` -> successful
	- `otool -L` -> only `libSystem` remains dynamically linked on macOS

Reproducible helper scripts were added for this phase:

- `scripts/build-llvm20-static.sh`
- `scripts/build-zig0152-stable.sh`

### Current stable-port worktree state

The stable checkout currently contains imported FasterBASIC sources plus an in-progress compiler integration layer.

Current modified paths in the stable checkout include:

- `build.zig`
- `src/main.zig`
- `src/dev.zig`
- `src/Compilation.zig`
- `src/link/Lld.zig`
- `src/link/MachO.zig`
- `lib/compiler/basic/`
- `src/libs/basic_runtime.zig`
- `tools/basic-smoke.sh`

### What is already done in the stable port

The following work has already been completed on top of the stable baseline:

- imported the full `lib/compiler/basic/` tree
- imported `src/libs/basic_runtime.zig`
- imported `tools/basic-smoke.sh`
- connected `build.zig` to a `basic_compiler` module using the custom LLVM headers
- restored the `zig basic` CLI path and BASIC-specific file classification in the stable compiler sources
- started porting the `Compilation.zig` and linker-side integration needed for BASIC object handling and runtime linkage

### What remains before this port is complete

The stable `0.15.2` port is not finished yet.

The next phase is to complete and validate the compiler-side BASIC pipeline on the stable branch, including:

- finalizing `Compilation.zig` integration
- validating linker inclusion of BASIC objects and the BASIC runtime
- rebuilding the stable checkout after the new integration patches
- running smoke tests against the stable `zig basic` command

Separately, the earlier repository history referenced by this document shows one explicit FasterBASIC integration commit:

- `c6fa8516` - `Add FasterBASIC compiler as 'zig basic' command`

That commit records these changes:

### 1. Imported the FasterBASIC compiler and runtime tree

Added the full compiler pipeline under `lib/compiler/basic/`, including:

- lexer, parser, token, AST, semantic analysis, CFG
- LLVM code generation and JIT support
- runtime Zig and C sources
- CLI-facing FasterBASIC entrypoints

Representative files from that commit include:

- `lib/compiler/basic/compiler_llvm.zig`
- `lib/compiler/basic/fbc_cli.zig`
- `lib/compiler/basic/main.zig`
- `lib/compiler/basic/runtime/basic_runtime.c`
- `lib/compiler/basic/runtime/worker_runtime.c`
- `lib/compiler/basic/runtime/hashmap_runtime.c`

### 2. Added a new compiler feature flag for BASIC

In `src/dev.zig`:

- added `basic_command` as a recognized feature
- enabled it in the development environments that support the integrated command

### 3. Added the `zig basic` top-level command

In `src/main.zig`:

- added `basic` to the CLI help text
- added command dispatch so `zig basic` routes through the compiler command path

## What The Current Worktree Shows

The deeper integration work is largely present as tracked modifications in the current worktree rather than as a long series of committed history entries.

These changes are the substantive Zig integration layer.

## Detailed Zig Integration Changes

### 1. CLI and source-file classification

Files:

- `src/main.zig`

Changes:

- adds `basic` to the command surface
- treats `.bas` as a recognized source-file class
- rejects BASIC input from `zig cc` / `zig c++` and directs users to `zig basic`
- adds a `basic_source_files` collection to the module creation path
- propagates BASIC ownership metadata across module creation
- sets `any_basic_source_files` in resolved compile options

Concrete behaviors present in the file include:

- dispatching `zig basic` through `buildOutputType`
- appending BASIC files during argument parsing
- tracking BASIC source ownership boundaries across CLI modules

### 2. BASIC-aware compilation configuration

Files:

- `src/Compilation/Config.zig`

Changes:

- adds `any_basic_source_files: bool` to resolved configuration
- adds the corresponding option field in `Options`
- threads the value through config resolution

This is the compiler-global flag used to indicate that BASIC sources participate in the current compilation.

### 3. New BASIC source/object types in the core compilation engine

Files:

- `src/Compilation.zig`

Changes:

- imports the integrated BASIC compiler module
- imports the BASIC runtime builder module
- adds `basic_source_files` to `Compilation.CreateOptions`
- adds `BasicSourceFile`
- adds `BasicObject`
- adds `basic_object_table`
- adds `basic_object_work_queue`
- adds `failed_basic_objects`
- adds `basic_runtime_lib`
- adds `basic_runtime` to queued misc jobs

This makes BASIC objects a first-class peer of C objects in the compilation engine rather than an external tool invocation.

### 4. BASIC object cache hashing and file tracking

Files:

- `src/Compilation.zig`

Changes:

- adds `hashBasicSource(...)` to cache helpers
- hashes BASIC source paths and BASIC extra flags
- registers BASIC source files as filesystem inputs
- includes BASIC inputs in the non-incremental cache manifest

This means BASIC object generation participates in the same cache and invalidation flow as the existing C object pipeline.

### 5. BASIC object creation during `Compilation.create`

Files:

- `src/Compilation.zig`

Changes:

- allocates a `BasicObject` for every input BASIC file
- stores those objects in `basic_object_table`
- marks the BASIC runtime as a queued prelink dependency when building an executable or dynamic library with BASIC inputs

### 6. Parallel BASIC compilation jobs

Files:

- `src/Compilation.zig`

Changes:

- enqueues all BASIC objects before work execution
- spawns `workerUpdateBasicObject`
- runs BASIC compilation on the compiler thread pool

This mirrors the existing queue-based compilation structure used for C inputs.

### 7. In-process BASIC-to-object compilation

Files:

- `src/Compilation.zig`

Changes inside `updateBasicObject(...)`:

- requires LLVM support to be present in the compiler build
- reads the BASIC source file
- computes the LLVM target triple from the Zig target
- maps Zig optimize modes to BASIC optimization levels
- determines whether the current BASIC source owns the final entrypoint
- calls `basic_compiler.compileToObject(...)`
- optionally emits LLVM IR via `basic_compiler.compileToIR(...)`
- optionally emits assembly via `basic_compiler.compileToAsm(...)`
- reports BASIC diagnostics back through Zig `ErrorBundle` infrastructure

This is the heart of the integration: BASIC code is compiled in-process by Zig rather than by shelling out to a separate compiler.

### 8. BASIC error lifecycle integration

Files:

- `src/Compilation.zig`

Changes:

- stores failures in `failed_basic_objects`
- clears/retries BASIC object state as needed
- merges BASIC compilation failures into `getAllErrorsAlloc(...)`
- deinitializes BASIC error bundles during compiler teardown

### 9. Automatic build of a BASIC runtime static library

Files:

- `src/Compilation.zig`
- `src/libs/basic_runtime.zig`
- `lib/compiler/basic/runtime/runtime_entry.zig`

Changes:

- adds a dedicated prelink task for building the BASIC runtime
- builds a static library rooted at `compiler/basic/runtime/runtime_entry.zig`
- compiles runtime C sources into that library
- stores the result in `basic_runtime_lib`
- queues the produced artifact for linking

The runtime library builder currently includes these runtime C sources:

- `basic_runtime.c`
- `worker_runtime.c`
- `hashmap_runtime.c`
- `runtime_shims.c`
- `basic_worker_bridge.c`
- `graphics_audio_stubs.c`
- `aot_main_wrapper.c`

The `runtime_entry.zig` module forces the required Zig runtime units into the build so the resulting static library is complete enough for integrated linking.

### 10. Linker garbage-collection and size tuning for BASIC builds

Files:

- `src/main.zig`
- `src/libs/basic_runtime.zig`

Changes:

- enables `function_sections` by default for BASIC builds
- enables `data_sections` by default for BASIC builds
- defaults `linker_gc_sections` to `true` when BASIC sources are present
- builds the BASIC runtime archive with section-splitting enabled
- sets `skip_linker_dependencies = true` for the runtime sub-compilation

This is the binary-size optimization layer that allows dead-stripping of unused BASIC runtime code.

### 11. macOS framework auto-linking for BASIC runtime math

Files:

- `src/main.zig`

Changes:

- auto-adds standard framework search paths on macOS if BASIC sources are present
- auto-links `Accelerate` so BASIC math/runtime features work without extra flags

### 12. Build-system import of the BASIC compiler module

Files:

- `build.zig`

Changes:

- creates `basic_compiler_mod`
- roots it at `lib/compiler/basic/compiler_llvm.zig`
- adds `deps/llvm21-install/include` as an include path
- imports it into the main compiler module as `basic_compiler`

Without this, the integrated compiler code in `src/Compilation.zig` would not be able to call into the FasterBASIC pipeline.

### 13. `std.Build.Module` support for BASIC source files

Files:

- `lib/std/Build/Module.zig`

Changes:

- adds a new `LinkObject` variant: `basic_source_file`
- defines `BasicSourceFile` in the build API layer
- adds `addBasicSourceFile(...)`

This is the core build API change that allows Zig build scripts to express BASIC inputs directly.

### 14. `std.Build.Step.Compile` support for BASIC source files

Files:

- `lib/std/Build/Step/Compile.zig`

Changes:

- adds `Compile.addBasicSourceFile(...)`
- forwards BASIC sources from the build API to the root module
- teaches CLI argument generation how to pass BASIC source files through
- forwards BASIC source flags via `-cflags ... --`
- marks BASIC link objects as a reason the module needs CLI arguments

This is what makes a build script pattern like `exe.addBasicSourceFile(...)` possible.

### 15. Build-runner dependency propagation for BASIC files

Files:

- `lib/compiler/build_runner.zig`

Changes:

- adds `basic_source_file` handling in step dependency creation

That ensures BASIC source files participate in build graph dependency tracking.

### 16. Mach-O linker integration

Files:

- `src/link/MachO.zig`

Changes:

- includes `basic_object_table` alongside `c_object_table`
- opens BASIC-produced object files as linker inputs
- includes the BASIC runtime archive during input classification
- includes BASIC objects and runtime in linker argv dumping/debug output

### 17. LLD integration across archive, COFF, ELF, and WASM paths

Files:

- `src/link/Lld.zig`

Changes:

- includes BASIC-produced object files in archive linking
- includes the BASIC runtime artifact in archive linking
- includes BASIC-produced objects in COFF linking
- includes the BASIC runtime artifact in COFF linking
- includes BASIC-produced objects in ELF linking
- includes the BASIC runtime artifact in ELF linking
- includes BASIC-produced objects in WASM linking
- includes the BASIC runtime artifact in WASM linking
- uses a BASIC object path as a fallback object source in code paths that previously assumed only C objects

### 18. Supporting FasterBASIC development utilities

Files currently present or added around the integration flow:

- `runbas.sh`
- `tools/basic-smoke.sh`

These are not core Zig compiler modifications, but they are part of the practical integration workflow used to validate the BASIC pipeline and runtime.

## Current Scope Of Tracked Zig-Side Modifications

At the time this file was created, the tracked Zig-side diff summary for the core integration files was approximately:

- `src/Compilation.zig`: large integration patch adding BASIC object compilation flow
- `src/main.zig`: CLI, classification, default linker/runtime behavior
- `src/link/Lld.zig`: BASIC object/runtime linker plumbing across multiple backends
- `src/link/MachO.zig`: BASIC object/runtime linker plumbing for Mach-O
- `lib/std/Build/Module.zig`: BASIC source build API
- `lib/std/Build/Step/Compile.zig`: BASIC source compile-step plumbing
- `build.zig`: import and wire the BASIC compiler module
- `lib/compiler/build_runner.zig`: dependency tracking for BASIC sources
- `src/Compilation/Config.zig`: compiler-global BASIC presence flag

## Important Note About History Completeness

This repository does not currently show a long, granular chain of committed FasterBASIC integration commits.

Based on the reachable git history and current worktree state:

- the current repository shows one overlapping repo-local commit: `89c5a5c9`
- the initial `zig basic` command import is committed
- the `c6fa8516` hash referenced above comes from earlier pre-migration history rather than the current reachable local graph
- much of the deeper Zig integration exists as current tracked modifications
- some supporting files also exist as untracked integration artifacts

So this document is the most specific reconstruction available from the repository itself, but it is not a substitute for a missing fine-grained commit series.