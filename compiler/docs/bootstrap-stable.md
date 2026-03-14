# Stable Zig 0.15.2 Bootstrap Notes

This document records the current reproducible process for bootstrapping the FasterBASIC port on top of a clean Zig `0.15.2` source tree.

It exists because the normal Zig `0.15.2` bootstrap path assumes the self-host step can be driven by `zig1.wasm`, while the FasterBASIC port adds an LLVM-backed module (`basic_compiler`) that `zig1.wasm` cannot import.

The result is a two-part process:

1. build a controlled LLVM 20 toolchain from source
2. rebuild Zig `0.15.2` against it, optionally using an external LLVM-enabled Zig binary to generate `zig2.c`

## Scope

Repository root:

- `/Volumes/xc/zfb2026`

Stable Zig source checkout:

- `/Volumes/xc/zfb2026/tmp/stable-zig-0.15.2/zig-0.15.2-git`

Custom LLVM install prefix:

- `/Volumes/xc/zfb2026/deps/llvm20-install`

## Why this process exists

The original FasterBASIC integration was done on an unstable Zig base.

The stable-port effort moves the integration onto official Zig `0.15.2`, but introduces a bootstrap problem:

- `src/Compilation.zig` imports `basic_compiler`
- `basic_compiler` depends on `@cImport` of `llvm-c/*.h`
- the stock `zig1.wasm` bootstrap compiler does not have LLVM extensions available
- therefore the normal `zig1 -> zig2.c` step fails once `src/main.zig` / `src/Compilation.zig` reference `basic_compiler`

That is why this repo now carries a custom external-bootstrap hook for the stable rebuild.

## Phase 1: Build controlled LLVM 20 from source

The prerequisite toolchain is built with:

- `scripts/build-llvm20-static.sh`

Current defaults in that script:

- LLVM version: `20.1.8`
- targets: `all`
- projects: `clang;lld`
- runtimes: `libcxx;libcxxabi;libunwind`
- shared libs: `OFF`
- `LLVM_ENABLE_ZSTD=OFF`
- `LLVM_ENABLE_LIBXML2=OFF`
- `LLVM_ENABLE_ZLIB=OFF`
- `LLVM_ENABLE_LIBEDIT=OFF`
- `LLVM_ENABLE_POLLY=OFF`

Typical invocation:

```bash
LLVM20_JOBS=12 ./scripts/build-llvm20-static.sh
```

Expected result:

- install prefix populated at `deps/llvm20-install`
- static `liblld*.a`, `libclang*.a`, `libc++.a`, `libc++abi.a`, `libunwind.a`

## Phase 2: Rebuild Zig 0.15.2 against custom LLVM

The stable rebuild script is:

- `scripts/build-zig0152-stable.sh`

It configures CMake with:

- `ZIG_USE_LLVM_CONFIG=OFF`
- `ZIG_SHARED_LLVM=OFF`
- `ZIG_STATIC_LLVM=ON`
- `CMAKE_PREFIX_PATH=$repo_root/deps/llvm20-install`

Typical clean invocation:

```bash
./scripts/build-zig0152-stable.sh
```

When this succeeds, it installs to:

- `tmp/stable-zig-0.15.2/zig-0.15.2-install-custom-llvm20`

## Phase 3: Problem introduced by FasterBASIC integration

Once the stable checkout includes FasterBASIC integration work, the self-host step starts failing during:

- generation of `zig2.c`

The stock bootstrap command looked like this in `CMakeLists.txt`:

```text
zig1 lib build-exe ... --dep build_options --dep aro -Mroot=src/main.zig -Mbuild_options=... -Maro=lib/compiler/aro/aro.zig
```

That is insufficient for the FasterBASIC port because `src/Compilation.zig` now needs:

- `--dep basic_compiler`
- `-Mbasic_compiler=lib/compiler/basic/compiler_llvm.zig`
- access to LLVM C headers

Even after adding those, `zig1.wasm` still cannot compile the LLVM-backed module because it was built without LLVM extensions.

## Phase 4: External bootstrap hook

To work around the `zig1.wasm` limitation, the stable checkout now carries a custom bootstrap override.

### CMake changes

In:

- `tmp/stable-zig-0.15.2/zig-0.15.2-git/CMakeLists.txt`

The build now defines:

```cmake
set(ZIG2_BOOTSTRAP_EXE "zig1" CACHE STRING "Executable used to generate zig2.c")
```

And the `zig2.c` custom command now uses:

```cmake
COMMAND ${ZIG2_BOOTSTRAP_EXE} ${BUILD_ZIG2_ARGS}
```

The `BUILD_ZIG2_ARGS` array was also extended with:

- `-I "${LLVM_INCLUDE_DIRS}"`
- `--dep "basic_compiler"`
- `"-Mbasic_compiler=lib/compiler/basic/compiler_llvm.zig"`

### bootstrap.c mirror update

For consistency, `bootstrap.c` was also updated to include:

- `--dep basic_compiler`
- `-Mbasic_compiler=lib/compiler/basic/compiler_llvm.zig`

### Rebuild script changes

`scripts/build-zig0152-stable.sh` now supports:

- `ZIG0152_BOOTSTRAP_ZIG`

When this variable is set, the script generates a wrapper in the build directory:

- `zig-bootstrap-wrapper.sh`

That wrapper:

- accepts Zig's internal `zig1 lib build-exe ...` calling convention
- treats the first positional arg as the Zig lib dir
- exports `ZIG_LIB_DIR`
- exports `C_INCLUDE_PATH=$llvm_prefix/include`
- execs the external Zig binary with the remaining args

The script then passes the wrapper into CMake via:

- `-DZIG2_BOOTSTRAP_EXE=$build_dir/zig-bootstrap-wrapper.sh`

## Phase 5: External bootstrap invocation

The currently preferred invocation is:

```bash
ZIG0152_BOOTSTRAP_ZIG="/Volumes/xc/zfb2026/tmp/stable-zig-0.15.2/zig-0.15.2-git/build-release-llvm20/stage3/bin/zig" \
./scripts/build-zig0152-stable.sh
```

This uses an existing LLVM-enabled Zig `0.15.2` binary to generate `zig2.c`, bypassing the `zig1.wasm` LLVM-extension limitation.

## What this solves

This process successfully moves the failure point forward from:

- `zig1.wasm` being unable to import `basic_compiler`

to:

- later C compilation of the generated `zig2.c`

That means the bootstrap-routing problem itself is solved well enough to continue iteration.

## Current blocker

At the time of writing, the remaining failure is in the manual C compile of generated `zig2.c`, not in module discovery or LLVM header discovery.

The current manual repro command is:

```bash
cd /Volumes/xc/zfb2026/tmp/stable-zig-0.15.2/zig-0.15.2-git/build-release-custom-llvm20 && \
/usr/bin/clang \
  -D_GNU_SOURCE -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS -D__STDC_LIMIT_MACROS \
  -I/Volumes/xc/zfb2026/tmp/stable-zig-0.15.2/zig-0.15.2-git/stage1 \
  -I/Volumes/xc/zfb2026/deps/llvm20-install/include \
  -O3 -DNDEBUG -arch arm64 -mmacosx-version-min=26.2 \
  -std=c99 -O0 -fno-sanitize=undefined -fno-stack-protector \
  -ferror-limit=5 \
  -c zig2.c -o /tmp/zig2-test.o
```

Use that command to inspect the current generated-C failure before changing any more bootstrap logic.

## Files involved in this process

Primary scripts:

- `scripts/build-llvm20-static.sh`
- `scripts/build-zig0152-stable.sh`

Stable checkout patches related to bootstrap:

- `tmp/stable-zig-0.15.2/zig-0.15.2-git/CMakeLists.txt`
- `tmp/stable-zig-0.15.2/zig-0.15.2-git/bootstrap.c`

Stable checkout FasterBASIC integration points that triggered the bootstrap issue:

- `tmp/stable-zig-0.15.2/zig-0.15.2-git/build.zig`
- `tmp/stable-zig-0.15.2/zig-0.15.2-git/src/main.zig`
- `tmp/stable-zig-0.15.2/zig-0.15.2-git/src/dev.zig`
- `tmp/stable-zig-0.15.2/zig-0.15.2-git/src/Compilation.zig`
- `tmp/stable-zig-0.15.2/zig-0.15.2-git/src/link/Lld.zig`
- `tmp/stable-zig-0.15.2/zig-0.15.2-git/src/link/MachO.zig`
- `tmp/stable-zig-0.15.2/zig-0.15.2-git/src/libs/basic_runtime.zig`
- `tmp/stable-zig-0.15.2/zig-0.15.2-git/lib/compiler/basic/`

## Practical replication checklist

1. Build LLVM 20 from source into `deps/llvm20-install`.
2. Confirm `deps/llvm20-install/include/llvm-c/Core.h` exists.
3. Confirm the stable Zig checkout contains the FasterBASIC integration edits.
4. Confirm `CMakeLists.txt` and `bootstrap.c` include `basic_compiler` in the bootstrap command.
5. Run the stable rebuild once with `ZIG0152_BOOTSTRAP_ZIG` set to an LLVM-enabled Zig binary.
6. If the build still fails, inspect `build-release-custom-llvm20/zig2.c` and rerun the manual `clang` compile above.

## Current status summary

Status as of 2026-03-07:

- controlled LLVM 20 build: working
- clean stable Zig `0.15.2` baseline rebuild: working
- FasterBASIC stable-port source integration: in progress
- external bootstrap routing for `basic_compiler`: implemented
- final generated-C bootstrap compile: still failing and is the next debugging target