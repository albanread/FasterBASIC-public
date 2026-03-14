# 2026-03-07 Stable-First Repo Plan

This section supersedes the older plan below.

The earlier document was written before the stable Zig `0.15.2` port was proven out. Since then, the situation has changed materially:

- the stable stage3 compiler under `tmp/stable-zig-0.15.2/zig-0.15.2-git` works
- `zig basic` works on that stable compiler
- the BASIC smoke suite passes on the stable stage3 compiler (`PASS=71 FAIL=0`)
- the macOS `Accelerate` auto-linking issue has been fixed in the stable integration

Because of that, the new repository should not be designed as a small sidecar harness around copied FasterBASIC pieces. The new repository should be a clean FasterBASIC-enabled Zig `0.15.2` source tree.

## Revised Objective

Create a clean repository that becomes the main development home for FasterBASIC on top of a stable Zig `0.15.2` compiler base.

The new repo must:

- use the stable `0.15.2` source tree as its compiler base
- include the working FasterBASIC integration from the stable port
- preserve `zig basic` as a first-class command
- preserve the BASIC runtime, smoke tests, and mixed-language integration
- avoid carrying transition clutter from this repo
- be reproducible from manifests and scripts rather than from memory

## New Source Of Truth

The correct source tree for the clean repo is:

- `tmp/stable-zig-0.15.2/zig-0.15.2-git`

Do not treat the older mixed repo root as the compiler baseline.

The current repo root still matters as a staging area for:

- `scripts/build-llvm20-static.sh`
- `scripts/build-zig0152-stable.sh`
- `docs/fbzig.md`
- `bootstrap-stable.md`
- `changes.md`
- `tests/basic/`
- `tests/basic-fails/`

But the actual compiler tree for the next repo should come from the stable `0.15.2` port.

## What Changes From The Old Plan

The old plan should be read as historical context only. These are the important corrections:

### 1. Base tree

Old assumption:

- extract a smaller repo around copied FasterBASIC code and a thin Zig integration harness

New decision:

- create a clean Zig `0.15.2` compiler repo with FasterBASIC integrated directly

### 2. Tests path

Old assumption:

- `basic/*.bas`
- `basic/fails/*.bas`

Current working layout:

- `tests/basic/`
- `tests/basic-fails/`

### 3. LLVM install reference

Old assumption:

- `deps/llvm21-install/`

Current stable working toolchain:

- `deps/llvm20-install/`

### 4. Toolchain policy

Old assumption:

- vendor a curated binary Zig/LLVM subset inside the repo

New decision:

- keep source, scripts, manifests, and docs in git
- recreate toolchains locally by script in ignored directories
- do not commit LLVM builds, Zig builds, stage3 binaries, or install trees by default

## Recommended Shape Of The New Repo

The clean repo should look like a real Zig compiler repo, not a detached harness:

```text
fbzig-stable/
  README.md
  LICENSE
  build.zig
  build.zig.zon
  src/
  lib/
    compiler/
      basic/
  test/
  tools/
    basic-smoke.sh
  docs/
    fbzig.md
    bootstrap-stable.md
    repo-plan.md
  scripts/
    build-llvm20-static.sh
    build-zig0152-stable.sh
    export-clean-repo.sh
    validate-smoke.sh
  manifests/
    source-snapshot.txt
    integration-files.txt
    keep-list.txt
    drop-list.txt
```

The new repo should keep the normal Zig tree structure and layer FasterBASIC into it.

## What Must Be In The New Repo

Keep these source and workflow components:

- the stable Zig `0.15.2` source base
- `lib/compiler/basic/` as a full tree
- `lib/compiler/basic/runtime/` as a full tree
- the working stable integration in:
  - `build.zig`
  - `src/main.zig`
  - `src/dev.zig`
  - `src/Compilation.zig`
  - `src/Compilation/Config.zig`
  - `src/link/Lld.zig`
  - `src/link/MachO.zig`
  - `src/libs/basic_runtime.zig`
  - `tools/basic-smoke.sh`
- the current BASIC corpus in:
  - `tests/basic/`
  - `tests/basic-fails/`
- the stable build scripts and bootstrap docs

## What Must Not Be In The New Repo

Exclude:

- `tmp/`
- `build/`
- `zig-out/`
- `.zig-cache/`
- LLVM source trees
- LLVM build trees
- generated BASIC binaries
- install trees and stage outputs
- machine-local scratch files

## Toolchain Policy

The clean repo should prefer reproducible local toolchain creation over committed binary payloads.

Commit:

- source
- scripts
- manifests
- docs

Do not commit by default:

- `deps/llvm20-install/`
- stage3 binaries
- install trees
- cached build products

If local toolchain directories are needed, keep them ignored and recreate them with scripts.

## Exact Plan

### Phase 0: Freeze the stable snapshot

Record:

1. the upstream Zig `0.15.2` base reference
2. the exact stable working tree snapshot
3. the list of touched stable integration files
4. the smoke-test result proving the stable compiler works

Deliverables:

- `manifests/source-snapshot.txt`
- `manifests/integration-files.txt`

### Phase 1: Seed the new repo from clean Zig `0.15.2`

Create the new repo from a clean Zig `0.15.2` source import.

This is the key change from the old plan.

### Phase 2: Copy the working stable FasterBASIC integration

Copy the working edits from:

- `tmp/stable-zig-0.15.2/zig-0.15.2-git`

At minimum:

- `build.zig`
- `src/main.zig`
- `src/dev.zig`
- `src/Compilation.zig`
- `src/Compilation/Config.zig`
- `src/link/Lld.zig`
- `src/link/MachO.zig`
- `src/libs/basic_runtime.zig`
- `lib/compiler/basic/`
- `tools/basic-smoke.sh`

### Phase 3: Copy the stable support scripts and docs

Copy or adapt:

- `scripts/build-llvm20-static.sh`
- `scripts/build-zig0152-stable.sh`
- `docs/fbzig.md`
- `bootstrap-stable.md`
- a trimmed stable-integration summary derived from `changes.md`

### Phase 4: Validate the new repo

Required validation:

1. build the stable stage3 compiler
2. confirm `zig version` is `0.15.2`
3. compile a BASIC program with `zig basic`
4. run the BASIC smoke suite
5. confirm smoke passes

### Phase 5: Only then tidy further

After the clean repo is proven working:

- trim docs
- simplify scripts
- tighten manifests
- decide whether to improve install-prefix behavior

## Acceptance Criteria

The clean repo is complete when:

- it is rooted in clean Zig `0.15.2` source
- it contains the full FasterBASIC compiler/runtime trees
- it contains the working stable integration files
- `zig basic` works from the rebuilt stage3 compiler
- the BASIC smoke suite passes
- no caches, builds, or LLVM source/build trees are tracked

## Immediate Next Actions

1. Freeze the exact stable source snapshot.
2. Create a new repo seeded from official Zig `0.15.2`.
3. Copy in the working stable FasterBASIC integration.
4. Copy in the stable scripts, docs, and smoke workflow.
5. Run a clean stage3 build in the new repo.
6. Run the BASIC smoke suite in the new repo.

---

Historical note: the original pre-stable extraction plan remains below for reference, but it should not drive the structure of the new repo now that the stable compiler path is working.

# FasterBASIC development repo extraction plan

## 1. Objective

Create a new, smaller repository that becomes the main day-to-day development home for FasterBASIC compiler work.

The new repo must:


This is **not** a cleanup plan for the current repo.
It is an extraction plan for creating a new repo from the current repo.


## 2. Outcome we want

At the end of this work, we should have a new repository that contains:

1. the FasterBASIC compiler pipeline source
2. the FasterBASIC runtime source
3. a thin Zig integration harness
4. a curated test corpus and smoke-test workflow
5. a pinned, minimal vendored Zig/LLVM install subset
6. scripts/manifests that make the extraction reproducible

The new repo should be small enough to clone and work in comfortably, but complete enough that FasterBASIC work does not drift away from real integrated behavior.


## 3. New repo shape

Recommended shape:

```text
fasterbasic-dev/
  README.md
  docs/
  manifests/
    copy-manifest.md
    keep-list.txt
    drop-list.txt
    llvm-subset.txt
    integration-files.txt
  scripts/
    export-from-fbzig.sh
    refresh-toolchain.sh
    validate-smoke.sh
  compiler/
    basic/                   # copied from lib/compiler/basic/
      runtime/               # copied from lib/compiler/basic/runtime/
  integration/
    zig/
      patches/
      files/
  tests/
    basic/
    basic-fails/
  toolchain/
    zig/
    llvm/
```

### Layout intent



## 4. What to copy from the current repo

The new repo should be created from a copy manifest, not from ad hoc manual selection.

### 4.1 Core compiler source: copy whole tree

Copy the full FasterBASIC compiler tree from:

```text
lib/compiler/basic/
```

That currently includes:


Rule: **copy this directory as a unit**.
Do not try to cherry-pick individual compiler modules in the first extraction.

### 4.2 Runtime source: copy whole tree

Copy the full runtime subtree from:

```text
lib/compiler/basic/runtime/
```

This currently includes Zig, C, and header files such as:

  - `basic_runtime.c`
  - `worker_runtime.c`
  - `hashmap_runtime.c`
  - `runtime_shims.c`
  - `basic_worker_bridge.c`
  - `graphics_audio_stubs.c`
  - `aot_main_wrapper.c`
  - `array_descriptor.h`
  - `basic_runtime.h`
  - `class_runtime.h`
  - `list_ops.h`
  - `samm_bridge.h`
  - `samm_pool.h`
  - `string_descriptor.h`
  - `string_pool.h`

Rule: **copy the runtime as a unit**.
The runtime is too coupled to safely trim during initial extraction.

### 4.3 Runtime build wrapper: copy directly

Copy:

```text
src/libs/basic_runtime.zig
```

Reason:


### 4.4 Smoke test script: copy directly

Copy:

```text
tools/basic-smoke.sh
```

Reason:


### 4.5 BASIC tests: copy curated set

Copy:

```text
basic/*.bas
basic/fails/*.bas
```

But move them into a cleaner layout in the new repo, for example:

```text
tests/basic/
tests/basic-fails/
```

Rule:


### 4.6 Documentation and helper scripts

Copy and adapt:


Do **not** copy general Zig fork documentation unless it directly supports FasterBASIC development.


## 5. Zig integration harness: what must be preserved

The new repo is not just a compiler dump.
It must preserve the integration surface that proves FasterBASIC still works inside the Zig-based flow.

Create an `integration/zig/` area that tracks these files from the current repo:

### 5.1 Compiler integration files


These are required because they currently carry:


### 5.2 Linker integration files


These must be tracked because mixed-language validation depends on BASIC-produced object files reaching the linker correctly.

### 5.3 Build-system integration files


These matter because they currently provide or participate in:


### 5.4 How to store the integration harness

Do **not** copy the entire Zig source tree into the new repo as the main working copy.

Instead, store the integration harness as one of:

1. patched copies of the touched files
2. a unified patchset against a pinned upstream/fbzig base
3. both patched files and a generated patch for review

Recommended initial approach:


That gives you both direct inspection and a re-applicable integration layer.


## 6. What must not be copied

These must be explicitly excluded from the new repo:

### 6.1 Build outputs and caches


### 6.2 LLVM source/build artifacts

Do not copy:


### 6.3 Full tool binaries that are not needed

Do not copy entire LLVM tool distributions unless proven necessary.

In particular, avoid carrying things like:


unless the new workflow actually depends on them.

### 6.4 Dirty local artifacts

Do not copy:



## 7. Toolchain packaging plan

The new repo may vendor toolchain artifacts, but only as a **curated install subset**.

### 7.1 LLVM policy

Keep only what the FasterBASIC/Zig workflow actually needs from the current install tree.

Expected shape:

```text
toolchain/llvm/
  include/
  lib/
  manifest.txt
```

Copy from the current repo's installed LLVM location, not from source/build trees.

Current source of truth:

```text
deps/llvm21-install/
```

### 7.2 What to keep from LLVM

Initial rule:


### 7.3 What not to keep from LLVM

Do not copy:


### 7.4 Zig policy

Keep a single pinned Zig binary/install subset sufficient to run the development and validation workflow.

Expected shape:

```text
toolchain/zig/
  bin/
  lib/
  manifest.txt
```

Do not vendor the entire current `build/` tree.
If a pinned `zig` executable is needed, copy only the executable and the lib data it depends on.


## 8. Exact extraction process

This is the part the previous version was missing.
The new repo should be created with a concrete, ordered extraction sequence.

### Phase 0: freeze the source snapshot

Before copying anything:

1. identify the source commit or working snapshot to export from
2. record the current file list for all FasterBASIC-related paths
3. decide whether untracked files are intentionally part of the export

Deliverable:


### Phase 1: create the new repo skeleton

Create the new repo with this minimum structure:

```text
README.md
docs/
manifests/
scripts/
compiler/basic/
integration/zig/files/
integration/zig/patches/
tests/basic/
tests/basic-fails/
toolchain/llvm/
toolchain/zig/
```

Deliverables:


### Phase 2: copy the compiler and runtime

Copy from current repo:


Deliverables:


### Phase 3: copy tests and smoke workflow

Copy:


Then update paths in the smoke script to the new repo layout.

Deliverables:


### Phase 4: capture Zig integration files

Copy touched Zig-side files into `integration/zig/files/`:


Then generate a patchset representing these changes against the chosen base.

Deliverables:


### Phase 5: create the curated toolchain subset

From the current repo:


Do **not** copy anything from:


Deliverables:


### Phase 6: add extraction and refresh scripts

Create:


These scripts should:


Deliverables:


### Phase 7: validate the new repo

Required validation:

1. BASIC smoke suite runs in the new repo
2. at least one `zig basic file.bas -femit-bin=...` style workflow works
3. mixed `Zig + BASIC + C` validation still works
4. no LLVM source/build trees exist in the new repo
5. no cache/build-output directories are tracked

Deliverables:



## 9. Copy manifest to produce

The extraction should produce these manifest files:


Each file should be explicit enough that another person can recreate the repo without reverse-engineering your decisions.


## 10. Acceptance criteria

The plan is complete when the new repo can satisfy all of these:

### Repo-content criteria


### Workflow criteria


### Maintenance criteria



## 11. Immediate next actions

These should be the first concrete tasks after plan approval:

1. write `manifests/keep-list.txt`
2. write `manifests/integration-files.txt`
3. write `manifests/drop-list.txt`
4. decide the exact destination layout for copied compiler files
5. create `scripts/export-from-fbzig.sh`
6. create the new repo skeleton
7. perform the first dry-run copy into the new repo
8. trim the LLVM/Zig subset after the first dry-run succeeds


## 12. Practical recommendation

Do the extraction in two passes:

### Pass 1: safe over-copy


Goal: get the new repo working quickly.

### Pass 2: deliberate trim


Goal: get the new repo clean without breaking it during initial extraction.

That is the safest way to create a new repo by copying from the current one without losing critical pieces.
