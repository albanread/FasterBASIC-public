//! FasterBASIC Compiler — LLVM Backend (CLI sub-module)
//!
//! Command-line compiler interface, invoked from Ed's unified main when
//! compiler flags are detected on the command line.  Called via `cliMain()`.
//!
//! Pipeline:
//!   1. Read .bas source file
//!   2. Lex → token stream
//!   3. Parse → AST
//!   4. Semantic analysis → symbol table + validated AST
//!   5. AST optimization
//!   6. CFG construction
//!   7. LLVM IR generation
//!   8. LLVM optimization passes
//!   9. LLJIT in-process execution  OR  emit object + link → executable
//!
//! Usage (via the Ed binary):
//!   Ed input.bas --jit                JIT compile and execute in-process
//!   Ed input.bas -o program           Compile to named executable
//!   Ed input.bas -i                   Emit LLVM IR to stdout
//!   Ed input.bas -i -o output.ll      Emit LLVM IR to file
//!   Ed input.bas --show-il            Compile and print LLVM IR to stderr
//!   Ed input.bas --trace-ast          Dump the AST and exit
//!   Ed input.bas --trace-symbols      Dump the symbol table and exit
//!   Ed input.bas -v                   Verbose output
//!   Ed --help                         Show help
//!   Ed --version                      Show version
//!
//! When invoked with no flags (or only a filename), Ed opens the editor GUI.

const std = @import("std");
const jit_shared = @import("jit_shared.zig");
const posix = std.posix;

const compiler_llvm = @import("compiler_llvm");
const qbe_codegen = @import("qbe_codegen.zig");
const qbe = @import("qbe.zig");

const Lexer = compiler_llvm.Lexer;
const Token = compiler_llvm.Token;
const Tag = compiler_llvm.Tag;
const Parser = compiler_llvm.Parser;
const SemanticAnalyzer = compiler_llvm.SemanticAnalyzer;
const ASTOptimizer = compiler_llvm.ASTOptimizer;
const CFGBuilder = compiler_llvm.CFGBuilder;
const LLVMState = compiler_llvm.LLVMState;
const CodeGenerator = compiler_llvm.CodeGenerator;
const LLVMJit = compiler_llvm.LLVMJit;
const llvm = compiler_llvm.llvm_c;
const llvm_jit_mod = struct {
    pub const JitExecResult = compiler_llvm.JitExecResult;
};

const version_string = "Ed 0.2.0 (FasterBASIC LLVM Compiler)";

var g_shared_input: ?SharedInputFeeder = null;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

// ─── CLI Options ────────────────────────────────────────────────────────────

const OutputMode = enum {
    executable,
    il_only,
    jit,
};

const Backend = enum {
    llvm,
    qbe,
    luajit,
};

const Options = struct {
    input_path: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    mode: OutputMode = .executable,
    backend: Backend = .llvm,
    show_il: bool = false,
    trace_ast: bool = false,
    trace_symbols: bool = false,
    trace_cfg: bool = false,
    trace_abc: bool = false,
    trace_hashmaps: bool = false,
    track_string_leaks: bool = false,
    verbose: bool = false,
    show_help: bool = false,
    show_version: bool = false,
    show_tokens: bool = false,
    run_after_compile: bool = false,
    jit_verbose: bool = false,
    dump_canvas: bool = false,
    metrics: bool = false,
    play_chords: bool = false,
    safe_mode: bool = false,
    no_optimize: bool = false,
    fast_math_trig: bool = false,
    opt_level: []const u8 = "O1",
    cc_path: []const u8 = "cc",
    runtime_dir: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
    /// Arguments to pass to the JIT-compiled program (collected after
    /// the input file when --run is used).
    program_args: []const []const u8 = &.{},
    /// Name of a shared memory region used for --jit-shared.
    jit_shared_name: ?[]const u8 = null,
    /// Path to a folder for --batch-jit mode: recursively scan for .bas
    /// files and JIT-execute each one sequentially in a single process.
    batch_jit_path: ?[]const u8 = null,
    /// Stop batch-jit on first failure instead of continuing.
    batch_fail_fast: bool = false,
    /// Per-file timeout in seconds for batch-jit mode (0 = no timeout).
    batch_timeout: u32 = 30,
};

fn backendName(backend: Backend) []const u8 {
    return switch (backend) {
        .llvm => "llvm",
        .qbe => "qbe",
        .luajit => "luajit",
    };
}

fn parseArgs(allocator: std.mem.Allocator) Options {
    var opts = Options{};

    var args = std.process.args();
    _ = args.skip(); // skip argv[0]

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            opts.show_help = true;
            return opts;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            opts.show_version = true;
            return opts;
        } else if (std.mem.eql(u8, arg, "-o")) {
            opts.output_path = args.next() orelse {
                opts.error_message = "Missing argument for -o";
                return opts;
            };
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--il") or std.mem.eql(u8, arg, "--ir")) {
            opts.mode = .il_only;
        } else if (std.mem.eql(u8, arg, "--show-il") or std.mem.eql(u8, arg, "--show-ir")) {
            opts.show_il = true;
        } else if (std.mem.eql(u8, arg, "--trace-ast") or std.mem.eql(u8, arg, "-A")) {
            opts.trace_ast = true;
        } else if (std.mem.eql(u8, arg, "--trace-symbols") or std.mem.eql(u8, arg, "-S")) {
            opts.trace_symbols = true;
        } else if (std.mem.eql(u8, arg, "--trace-cfg") or std.mem.eql(u8, arg, "-G")) {
            opts.trace_cfg = true;
        } else if (std.mem.eql(u8, arg, "--trace-abc")) {
            opts.trace_abc = true;
        } else if (std.mem.eql(u8, arg, "--trace-hashmaps")) {
            opts.trace_hashmaps = true;
        } else if (std.mem.eql(u8, arg, "--track-leaks") or std.mem.eql(u8, arg, "--track-string-leaks")) {
            opts.track_string_leaks = true;
        } else if (std.mem.eql(u8, arg, "--play-chords")) {
            opts.play_chords = true;
        } else if (std.mem.eql(u8, arg, "--show-tokens")) {
            opts.show_tokens = true;
        } else if (std.mem.eql(u8, arg, "--jit") or std.mem.eql(u8, arg, "-J")) {
            opts.mode = .jit;
        } else if (std.mem.eql(u8, arg, "--jit-shared")) {
            opts.mode = .jit;
            opts.jit_shared_name = args.next() orelse {
                opts.error_message = "Missing shared memory name for --jit-shared";
                return opts;
            };
        } else if (std.mem.eql(u8, arg, "--jit-verbose")) {
            opts.mode = .jit;
            opts.jit_verbose = true;
        } else if (std.mem.eql(u8, arg, "--dump-canvas")) {
            opts.mode = .jit;
            opts.dump_canvas = true;
        } else if (std.mem.eql(u8, arg, "--metrics")) {
            opts.metrics = true;
        } else if (std.mem.eql(u8, arg, "--safe")) {
            opts.safe_mode = true;
        } else if (std.mem.eql(u8, arg, "--batch-jit")) {
            opts.batch_jit_path = args.next() orelse {
                opts.error_message = "Missing folder argument for --batch-jit";
                return opts;
            };
            opts.mode = .jit;
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            const val = args.next() orelse {
                opts.error_message = "Missing seconds argument for --timeout";
                return opts;
            };
            opts.batch_timeout = std.fmt.parseInt(u32, val, 10) catch {
                opts.error_message = "Invalid number for --timeout";
                return opts;
            };
        } else if (std.mem.eql(u8, arg, "--fail-fast")) {
            opts.batch_fail_fast = true;
        } else if (std.mem.eql(u8, arg, "--no-optimize")) {
            opts.no_optimize = true;
        } else if (std.mem.eql(u8, arg, "--fast-math-trig")) {
            opts.fast_math_trig = true;
        } else if (std.mem.eql(u8, arg, "-O0")) {
            opts.opt_level = "O0";
        } else if (std.mem.eql(u8, arg, "-O1")) {
            opts.opt_level = "O1";
        } else if (std.mem.eql(u8, arg, "-O2")) {
            opts.opt_level = "O2";
        } else if (std.mem.eql(u8, arg, "-O3")) {
            opts.opt_level = "O3";
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            opts.verbose = true;
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--run")) {
            opts.run_after_compile = true;
            opts.mode = .jit; // --run implies JIT mode
        } else if (std.mem.eql(u8, arg, "--cc")) {
            opts.cc_path = args.next() orelse {
                opts.error_message = "Missing argument for --cc";
                return opts;
            };
        } else if (std.mem.eql(u8, arg, "--runtime-dir")) {
            opts.runtime_dir = args.next() orelse {
                opts.error_message = "Missing argument for --runtime-dir";
                return opts;
            };
        } else if (std.mem.eql(u8, arg, "--be-llvm")) {
            opts.backend = .llvm;
        } else if (std.mem.eql(u8, arg, "--be-qbe")) {
            opts.backend = .qbe;
        } else if (std.mem.eql(u8, arg, "--be--luajit") or std.mem.eql(u8, arg, "--be-luajit")) {
            opts.backend = .luajit;
        } else if (arg.len > 0 and arg[0] == '-') {
            opts.error_message = arg;
            return opts;
        } else {
            // Positional argument: input file
            if (opts.input_path != null) {
                opts.error_message = "Multiple input files are not supported";
                return opts;
            }
            opts.input_path = arg;

            // In --run mode, everything after the input file is a
            // program argument — stop parsing compiler flags.
            if (opts.run_after_compile) {
                var prog_args: std.ArrayListUnmanaged([]const u8) = .{};
                // argv[0] for the program = the .bas source path
                prog_args.append(allocator, arg) catch {};
                while (args.next()) |parg| {
                    prog_args.append(allocator, parg) catch {};
                }
                opts.program_args = prog_args.toOwnedSlice(allocator) catch &.{};
                return opts;
            }
        }
    }

    return opts;
}

// ─── Help Text ──────────────────────────────────────────────────────────────

fn printHelp(writer: anytype) void {
    writer.print(
        \\{s}
        \\
        \\Usage: Ed [options] <input.bas>
        \\       Ed --run <input.bas> [program args...]
        \\       Ed [file.bas]                  (no flags → open editor)
        \\
        \\Compiles FasterBASIC source files to native executables via LLVM.
        \\When invoked with no flags, Ed opens the graphical editor.
        \\
        \\Output Modes:
        \\  (default)                Compile to native executable
        \\  -i, --ir                 Emit LLVM IR only
        \\  -J, --jit                JIT compile and execute in-process (LLJIT)
        \\  -r, --run                JIT compile and run, passing remaining args to program
        \\
        \\Options:
        \\  -o <path>                Output file path (default: derived from input)
        \\  -v, --verbose            Verbose compiler output
        \\  --safe                   Force safety features ON (array bounds checks, error tracking, cancellable loops, SAMM)
        \\  --no-optimize            Disable LLVM optimization passes
        \\  --fast-math-trig         Opt-in approximate trig for SIN/COS/TAN/POLAR
        \\  -O0, -O1, -O2, -O3      Set LLVM optimization level (default: -O1 for JIT, -O2 for AOT)
        \\  -h, --help               Show this help message
        \\  -V, --version            Show version information
        \\
        \\JIT Options:
        \\  --jit-verbose            JIT mode with diagnostic output
        \\  --dump-canvas            Decode and print every canvas flush to stderr (JIT)
        \\  --jit-shared <name>      Read source from shared memory and log output there
        \\  --metrics                Print phase timings and SAMM memory stats after JIT run
        \\  --batch-jit <folder>     Recursively find .bas files and JIT-execute each one
        \\  --fail-fast              Stop batch-jit on first failure
        \\  --timeout <secs>         Per-file timeout for batch-jit (default: 30, 0=none)
        \\
        \\Debug / Trace:
        \\  --show-ir                Print generated LLVM IR to stderr
        \\  --show-tokens            Print token stream to stderr
        \\  -A, --trace-ast          Dump the AST and exit
        \\  -S, --trace-symbols      Dump the symbol table and exit
        \\  -G, --trace-cfg          Dump CFG analysis and exit
        \\  --trace-abc              Dump ABC compiled stream details (MUSIC LOAD)
        \\  --trace-hashmaps         Log hashmap runtime calls (JIT)
        \\  --track-leaks            Enable string leak tracking (EDBASIC_TRACK_STRING_LEAKS=1)
        \\  --play-chords            Enable playback of ABC chord symbols ("C", "G7", ...)
        \\
        \\Toolchain:
        \\  --cc <path>              Path to the C compiler/linker (default: cc)
        \\  --runtime-dir <path>     Path to the BASIC runtime library sources
        \\
        \\Backends:
        \\  --be-llvm                Use the LLVM backend (default, implemented)
        \\  --be-qbe                 Select the QBE backend (planned)
        \\  --be--luajit             Select the LuaJIT backend (planned)
        \\
        \\LLVM Backend:
        \\  The currently implemented backend uses LLVM for code generation
        \\  and JIT execution. LLVM is linked dynamically from the system
        \\  installation.
        \\
        \\Examples:
        \\  Ed                               # Open the graphical editor
        \\  Ed hello.bas                     # Open hello.bas in the editor
        \\  Ed hello.bas --jit               # JIT compile and execute in-process
        \\  Ed hello.bas -o greet            # Compile hello.bas -> greet
        \\  Ed hello.bas -i                  # Print LLVM IR to stdout
        \\  Ed hello.bas -i -o hello.ll      # Write LLVM IR to hello.ll
        \\  Ed hello.bas --show-ir           # Compile and show IR on stderr
        \\  Ed --run hello.bas arg1 arg2     # JIT run with program arguments
        \\  Ed hello.bas --jit-verbose       # JIT with diagnostic report
        \\  Ed --batch-jit tests/            # JIT-execute all .bas files in folder
        \\  Ed --batch-jit tests/ --metrics  # Batch with per-file metrics
        \\
        \\
    , .{version_string}) catch {};
}

// ─── Source File Reading ────────────────────────────────────────────────────

fn readSourceFile(path: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    const source = try allocator.alloc(u8, stat.size);
    const n = try file.readAll(source);
    return source[0..n];
}

// ─── Output Path Derivation ────────────────────────────────────────────────

fn deriveOutputPath(input_path: []const u8, mode: OutputMode, allocator: std.mem.Allocator) ![]const u8 {
    const basename = std.fs.path.basename(input_path);
    const stem = std.fs.path.stem(basename);

    const ext: []const u8 = switch (mode) {
        .il_only => ".ll",
        .executable => "",
        .jit => "",
    };

    if (ext.len > 0) {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ stem, ext });
    } else {
        return std.fmt.allocPrint(allocator, "{s}", .{stem});
    }
}

// ─── Token Dump ─────────────────────────────────────────────────────────────

fn dumpTokens(tokens: []const Token, writer: anytype) void {
    writer.print("\n=== Token Stream ===\n", .{}) catch {};
    for (tokens) |tok| {
        writer.print("  [{d}:{d}] {s}", .{ tok.location.line, tok.location.column, @tagName(tok.tag) }) catch {};
        if (tok.lexeme.len > 0 and tok.lexeme.len <= 40) {
            writer.print(" '{s}'", .{tok.lexeme}) catch {};
        }
        writer.print("\n", .{}) catch {};
    }
    writer.print("=== End Token Stream ===\n\n", .{}) catch {};
}

// ─── AST Dump ───────────────────────────────────────────────────────────────

fn dumpAST(program: *const compiler_llvm.Program, writer: anytype) void {
    writer.print("\n=== AST ({d} lines) ===\n", .{program.lines.len}) catch {};
    for (program.lines, 0..) |line, i| {
        writer.print("Line {d}: ", .{i}) catch {};
        if (line.line_number > 0) {
            writer.print("[{d}] ", .{line.line_number}) catch {};
        }
        for (line.statements) |stmt| {
            writer.print("{s} ", .{@tagName(stmt.data)}) catch {};
        }
        writer.print("\n", .{}) catch {};
    }
    writer.print("=== End AST ===\n\n", .{}) catch {};
}

// ─── Symbol Table Dump ──────────────────────────────────────────────────────

fn dumpSymbolTable(sym_table: *const compiler_llvm.SymbolTable, writer: anytype) void {
    writer.print("\n=== Symbol Table ===\n", .{}) catch {};

    writer.print("\n  Functions ({d}):\n", .{sym_table.functions.count()}) catch {};
    var func_it = sym_table.functions.iterator();
    while (func_it.next()) |entry| {
        const fsym = entry.value_ptr;
        writer.print("    {s}", .{fsym.name}) catch {};
        if (fsym.parameters.len > 0) {
            writer.print("(", .{}) catch {};
            for (fsym.parameters, 0..) |p, i| {
                if (i > 0) writer.print(", ", .{}) catch {};
                writer.print("{s}", .{p}) catch {};
            }
        }
        writer.print("\n", .{}) catch {};
    }

    writer.print("\n  Variables ({d}):\n", .{sym_table.variables.count()}) catch {};
    var var_it = sym_table.variables.iterator();
    while (var_it.next()) |entry| {
        writer.print("    {s}\n", .{entry.key_ptr.*}) catch {};
    }

    writer.print("\n  Arrays ({d}):\n", .{sym_table.arrays.count()}) catch {};
    var arr_it = sym_table.arrays.iterator();
    while (arr_it.next()) |entry| {
        writer.print("    {s}\n", .{entry.key_ptr.*}) catch {};
    }

    writer.print("\n  Types ({d}):\n", .{sym_table.types.count()}) catch {};
    var type_it = sym_table.types.iterator();
    while (type_it.next()) |entry| {
        writer.print("    {s}\n", .{entry.key_ptr.*}) catch {};
    }

    writer.print("\n  Line Numbers ({d}):\n", .{sym_table.line_numbers.count()}) catch {};
    var ln_it = sym_table.line_numbers.iterator();
    while (ln_it.next()) |entry| {
        writer.print("    {d}\n", .{entry.key_ptr.*}) catch {};
    }

    writer.print("\n  Labels ({d}):\n", .{sym_table.labels.count()}) catch {};
    var label_it = sym_table.labels.iterator();
    while (label_it.next()) |entry| {
        writer.print("    {s}\n", .{entry.key_ptr.*}) catch {};
    }

    writer.print("=== End Symbol Table ===\n\n", .{}) catch {};
}

// ─── File Utilities ─────────────────────────────────────────────────────────

fn fileExists(path: []const u8) bool {
    const f = std.fs.cwd().openFile(path, .{}) catch return false;
    f.close();
    return true;
}

fn isBasicFile(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(ext, ".bas");
}

// ─── SAMM Stats ─────────────────────────────────────────────────────────────

const SAMMStats = extern struct {
    scopes_entered: u64,
    scopes_exited: u64,
    objects_allocated: u64,
    objects_freed: u64,
    objects_cleaned: u64,
    cleanup_batches: u64,
    double_free_attempts: u64,
    bloom_false_positives: u64,
    retain_calls: u64,
    total_bytes_allocated: u64,
    total_bytes_freed: u64,
    strings_tracked: u64,
    strings_cleaned: u64,
    current_scope_depth: u32,
    peak_scope_depth: u32,
    bloom_memory_bytes: u64,
    total_cleanup_time_ms: f64,
    background_worker_active: u32,
};

extern fn samm_get_stats(stats: *SAMMStats) callconv(.c) void;
extern fn msg_metrics_reset() callconv(.c) void;
extern fn basic_jit_arm_signals() callconv(.c) void;
extern fn basic_jit_disarm_signals() callconv(.c) void;
extern fn gfx_canvas_dump_enable() callconv(.c) void;
extern fn fbc_run_with_appkit(work: *const fn (*anyopaque) callconv(.c) void, context: *anyopaque) callconv(.c) void;
extern fn string_metrics_reset() callconv(.c) void;
extern fn string_metrics_get_assign_calls() callconv(.c) u64;
extern fn string_metrics_get_assign_from_temp() callconv(.c) u64;
extern fn string_metrics_get_retain_temp_clones() callconv(.c) u64;
extern fn string_metrics_get_release_temp_ignored() callconv(.c) u64;

// ─── Metrics Helpers ────────────────────────────────────────────────────────

fn nsToMs(ns: i128) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

fn phaseMs(start_ns: i128, end_ns: i128) f64 {
    return nsToMs(end_ns - start_ns);
}

fn pct(part_ms: f64, total_ms: f64) f64 {
    if (total_ms <= 0.0) return 0.0;
    return (part_ms / total_ms) * 100.0;
}

const MetricsTimes = struct {
    read_ms: f64,
    lex_ms: f64,
    parse_ms: f64,
    semantic_ms: f64,
    cfg_ms: f64,
    codegen_ms: f64,
    llvm_opt_ms: f64,
    llvm_jit_ms: f64,
    jit_exec_ms: f64,
    total_ms: f64,
};

fn shouldPrintStringMetrics() bool {
    if (getenv("EDBASIC_STRING_METRICS")) |v| {
        return v[0] != 0 and v[0] != '0';
    }
    return false;
}

fn printStringMetrics(writer: anytype) void {
    writer.print(
        "  string: assign={d}  from_temp={d}  temp_clone={d}  temp_release_ignored={d}\n",
        .{
            string_metrics_get_assign_calls(),
            string_metrics_get_assign_from_temp(),
            string_metrics_get_retain_temp_clones(),
            string_metrics_get_release_temp_ignored(),
        },
    ) catch {};
}

fn printMetrics(writer: anytype, backend: Backend, stats: SAMMStats, times: MetricsTimes) void {
    writer.print("\n", .{}) catch {};
    writer.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{}) catch {};
    writer.print("  fbc --metrics ({s} JIT)\n", .{backendName(backend)}) catch {};
    writer.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{}) catch {};
    writer.print("  Read source:         {d:.3} ms ({d:.1}%)\n", .{ times.read_ms, pct(times.read_ms, times.total_ms) }) catch {};
    writer.print("  Lexing:              {d:.3} ms ({d:.1}%)\n", .{ times.lex_ms, pct(times.lex_ms, times.total_ms) }) catch {};
    writer.print("  Parsing:             {d:.3} ms ({d:.1}%)\n", .{ times.parse_ms, pct(times.parse_ms, times.total_ms) }) catch {};
    writer.print("  Semantic analysis:   {d:.3} ms ({d:.1}%)\n", .{ times.semantic_ms, pct(times.semantic_ms, times.total_ms) }) catch {};
    writer.print("  CFG build:           {d:.3} ms ({d:.1}%)\n", .{ times.cfg_ms, pct(times.cfg_ms, times.total_ms) }) catch {};
    writer.print("  LLVM IR codegen:     {d:.3} ms ({d:.1}%)\n", .{ times.codegen_ms, pct(times.codegen_ms, times.total_ms) }) catch {};
    writer.print("  LLVM opt passes:     {d:.3} ms ({d:.1}%)\n", .{ times.llvm_opt_ms, pct(times.llvm_opt_ms, times.total_ms) }) catch {};
    writer.print("  LLJIT compile+link:  {d:.3} ms ({d:.1}%)\n", .{ times.llvm_jit_ms, pct(times.llvm_jit_ms, times.total_ms) }) catch {};
    writer.print("  JIT execute:         {d:.3} ms ({d:.1}%)\n", .{ times.jit_exec_ms, pct(times.jit_exec_ms, times.total_ms) }) catch {};
    writer.print("  TOTAL:               {d:.3} ms\n", .{times.total_ms}) catch {};

    const leaked_objects: i64 = @as(i64, @intCast(stats.objects_allocated)) - @as(i64, @intCast(stats.objects_freed + stats.objects_cleaned));
    const leaked_bytes: i64 = @as(i64, @intCast(stats.total_bytes_allocated)) - @as(i64, @intCast(stats.total_bytes_freed));

    writer.print("\n", .{}) catch {};
    writer.print("  SAMM Memory Manager\n", .{}) catch {};
    writer.print("  ----------------------------------------------------\n", .{}) catch {};
    writer.print("  Objects allocated:    {d}\n", .{stats.objects_allocated}) catch {};
    writer.print("  Objects freed (DEL):  {d}\n", .{stats.objects_freed}) catch {};
    writer.print("  Objects cleaned (bg): {d}\n", .{stats.objects_cleaned}) catch {};
    writer.print("  Strings tracked:      {d}\n", .{stats.strings_tracked}) catch {};
    writer.print("  Strings cleaned:      {d}\n", .{stats.strings_cleaned}) catch {};
    writer.print("  Bytes allocated:      {d}\n", .{stats.total_bytes_allocated}) catch {};
    writer.print("  Bytes freed:          {d}\n", .{stats.total_bytes_freed}) catch {};
    writer.print("  Leaked objects:       {d}\n", .{if (leaked_objects > 0) leaked_objects else 0}) catch {};
    writer.print("  Leaked bytes:         {d}\n", .{if (leaked_bytes > 0) leaked_bytes else 0}) catch {};
    writer.print("  Cleanup batches:      {d}\n", .{stats.cleanup_batches}) catch {};
    writer.print("  Cleanup time:         {d:.3} ms\n", .{stats.total_cleanup_time_ms}) catch {};
    writer.print("  Scope depth (cur/peak): {d}/{d}\n", .{ stats.current_scope_depth, stats.peak_scope_depth }) catch {};
    writer.print("  Bloom memory:         {d} bytes\n", .{stats.bloom_memory_bytes}) catch {};
    writer.print("  Background worker:    {s}\n", .{if (stats.background_worker_active != 0) "active" else "stopped"}) catch {};
    writer.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{}) catch {};
}

// ─── Batch JIT: scan a directory recursively for .bas files ─────────────────

fn scanBasicFilesRecursive(
    dir_path: []const u8,
    allocator: std.mem.Allocator,
) ![][]const u8 {
    var results: std.ArrayList([]const u8) = .empty;

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        stderr.print("Error: cannot open directory '{s}': {s}\n", .{ dir_path, @errorName(err) }) catch {};
        return results.toOwnedSlice(allocator) catch &[_][]const u8{};
    };
    defer dir.close();

    var walker = dir.walk(allocator) catch |err| {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        stderr.print("Error: cannot walk directory '{s}': {s}\n", .{ dir_path, @errorName(err) }) catch {};
        return results.toOwnedSlice(allocator) catch &[_][]const u8{};
    };
    defer walker.deinit();

    while (walker.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!isBasicFile(entry.path)) continue;

        const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.path }) catch continue;
        results.append(allocator, full_path) catch continue;
    }

    std.mem.sort([]const u8, results.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return results.toOwnedSlice(allocator) catch &[_][]const u8{};
}

// ─── LLVM JIT context for executing on a worker thread via AppKit ───────────

const JitExecContext = struct {
    jit: *LLVMJit,
    result: llvm_jit_mod.JitExecResult,

    fn workerFn(ctx_opaque: *anyopaque) callconv(.c) void {
        const self: *JitExecContext = @ptrCast(@alignCast(ctx_opaque));
        self.result = self.jit.executeMain();
    }
};

const PipeReaderCtx = struct {
    fd: posix.fd_t,
    buffer: []u8,
    write_ptr: *u32,
};

const SharedRedirect = struct {
    out_read_fd: posix.fd_t,
    err_read_fd: posix.fd_t,
    saved_stdout_fd: posix.fd_t,
    saved_stderr_fd: posix.fd_t,
    out_thread: ?std.Thread,
    err_thread: ?std.Thread,
    out_ctx: PipeReaderCtx,
    err_ctx: PipeReaderCtx,

    fn start(region: *jit_shared.SharedRegion) !SharedRedirect {
        const out_fds = posix.pipe() catch return error.PipeFailed;
        const err_fds = posix.pipe() catch return error.PipeFailed;

        var redirect = SharedRedirect{
            .out_read_fd = out_fds[0],
            .err_read_fd = err_fds[0],
            .saved_stdout_fd = -1,
            .saved_stderr_fd = -1,
            .out_thread = null,
            .err_thread = null,
            .out_ctx = .{ .fd = out_fds[0], .buffer = region.output, .write_ptr = &region.header.output_write },
            .err_ctx = .{ .fd = err_fds[0], .buffer = region.err, .write_ptr = &region.header.error_write },
        };

        redirect.saved_stdout_fd = posix.dup(posix.STDOUT_FILENO) catch return error.PipeFailed;
        redirect.saved_stderr_fd = posix.dup(posix.STDERR_FILENO) catch return error.PipeFailed;

        posix.dup2(out_fds[1], posix.STDOUT_FILENO) catch return error.PipeFailed;
        posix.dup2(err_fds[1], posix.STDERR_FILENO) catch return error.PipeFailed;

        posix.close(out_fds[1]);
        posix.close(err_fds[1]);

        return redirect;
    }

    fn startThreads(self: *SharedRedirect) void {
        self.out_thread = std.Thread.spawn(.{}, pipeReaderThreadMain, .{&self.out_ctx}) catch null;
        self.err_thread = std.Thread.spawn(.{}, pipeReaderThreadMain, .{&self.err_ctx}) catch null;
    }

    fn stop(self: *SharedRedirect) void {
        if (self.saved_stdout_fd >= 0) {
            posix.dup2(self.saved_stdout_fd, posix.STDOUT_FILENO) catch {};
            posix.close(self.saved_stdout_fd);
            self.saved_stdout_fd = -1;
        }
        if (self.saved_stderr_fd >= 0) {
            posix.dup2(self.saved_stderr_fd, posix.STDERR_FILENO) catch {};
            posix.close(self.saved_stderr_fd);
            self.saved_stderr_fd = -1;
        }

        if (self.out_thread) |t| t.join();
        if (self.err_thread) |t| t.join();
    }
};

const SharedInputFeeder = struct {
    write_fd: posix.fd_t,
    saved_stdin_fd: posix.fd_t,
    thread: ?std.Thread,
    stop: std.atomic.Value(bool),
    read_pos: u32,
    region: *jit_shared.SharedRegion,

    fn start(region: *jit_shared.SharedRegion) !SharedInputFeeder {
        const stdin_fds = posix.pipe() catch return error.PipeFailed;
        const read_fd = stdin_fds[0];
        const write_fd = stdin_fds[1];

        const saved_stdin_fd = posix.dup(posix.STDIN_FILENO) catch return error.PipeFailed;
        posix.dup2(read_fd, posix.STDIN_FILENO) catch return error.PipeFailed;
        posix.close(read_fd);

        const feeder = SharedInputFeeder{
            .write_fd = write_fd,
            .saved_stdin_fd = saved_stdin_fd,
            .thread = null,
            .stop = std.atomic.Value(bool).init(false),
            .read_pos = 0,
            .region = region,
        };

        return feeder;
    }

    fn startThread(self: *SharedInputFeeder) void {
        self.thread = std.Thread.spawn(.{}, sharedInputThreadMain, .{self}) catch null;
    }

    fn stopFeeder(self: *SharedInputFeeder) void {
        self.stop.store(true, .release);
        posix.close(self.write_fd);
        if (self.thread) |t| t.join();
        if (self.saved_stdin_fd >= 0) {
            posix.dup2(self.saved_stdin_fd, posix.STDIN_FILENO) catch {};
            posix.close(self.saved_stdin_fd);
            self.saved_stdin_fd = -1;
        }
    }
};

fn pipeReaderThreadMain(ctx: *PipeReaderCtx) void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = posix.read(ctx.fd, &buf) catch break;
        if (n == 0) break;
        jit_shared.ringWrite(ctx.buffer, ctx.write_ptr, buf[0..n]);
    }
    posix.close(ctx.fd);
}

fn sharedInputThreadMain(ctx: *SharedInputFeeder) void {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(std.heap.page_allocator);

    while (true) {
        if (ctx.stop.load(.acquire)) break;
        buf.clearRetainingCapacity();

        const write_pos = @atomicLoad(u32, &ctx.region.header.input_write, .acquire);
        jit_shared.ringRead(ctx.region.input, &ctx.read_pos, write_pos, &buf, std.heap.page_allocator);
        @atomicStore(u32, &ctx.region.header.input_read, ctx.read_pos, .release);

        if (buf.items.len > 0) {
            _ = posix.write(ctx.write_fd, buf.items) catch {};
        } else {
            std.Thread.sleep(10_000_000); // 10 ms
        }
    }
}

fn exitWith(code: u8, shared_redirect: *?SharedRedirect, shared_region: *?jit_shared.SharedRegion) noreturn {
    if (g_shared_input) |*input| {
        input.stopFeeder();
        g_shared_input = null;
    }
    if (shared_redirect.*) |*redirect| {
        redirect.stop();
        shared_redirect.* = null;
    }
    if (shared_region.*) |*region| {
        jit_shared.close(region);
        shared_region.* = null;
    }
    std.process.exit(code);
}

// ─── Batch JIT: compile and execute a single .bas file via LLVM ─────────────

const BatchResult = struct {
    ok: bool = false,
    exit_code: i32 = -1,
    compile_ms: f64 = 0,
    exec_ms: f64 = 0,
    error_phase: ?[]const u8 = null,
    timed_out: bool = false,
};

fn applySafeMode(analyzer: *SemanticAnalyzer) void {
    // Force safety-oriented compiler options regardless of source directives.
    analyzer.options.bounds_checking = true;
    analyzer.options.error_tracking = true;
    analyzer.options.cancellable_loops = true;
    analyzer.options.samm_enabled = true;

    analyzer.symbol_table.error_tracking = true;
    analyzer.symbol_table.cancellable_loops = true;
    analyzer.symbol_table.samm_enabled = true;
}

fn runSingleBatchFile(
    file_path: []const u8,
    gpa_alloc: std.mem.Allocator,
    backend: Backend,
    verbose: bool,
    jit_verbose: bool,
    show_metrics: bool,
    _timeout_secs: u32,
    safe_mode: bool,
    no_optimize: bool,
    fast_math_trig: bool,
) BatchResult {
    _ = verbose;
    _ = jit_verbose;
    _ = _timeout_secs;
    const stderr = std.fs.File.stderr().deprecatedWriter();

    var file_arena = std.heap.ArenaAllocator.init(gpa_alloc);
    defer file_arena.deinit();
    const allocator = file_arena.allocator();

    const t_file_start = std.time.nanoTimestamp();
    string_metrics_reset();

    // ── Read source ─────────────────────────────────────────────────
    const source = readSourceFile(file_path, allocator) catch |err| {
        stderr.print("  ERROR: cannot read '{s}': {s}\n", .{ file_path, @errorName(err) }) catch {};
        return .{ .error_phase = "read" };
    };

    // ── Lex ─────────────────────────────────────────────────────────
    var lex = Lexer.init(source, allocator);
    defer lex.deinit();
    lex.tokenize() catch {
        stderr.print("  ERROR: lexer failure\n", .{}) catch {};
        return .{ .error_phase = "lex" };
    };
    if (lex.hasErrors()) {
        for (lex.errors.items) |lerr| {
            stderr.print("  LEX {d}:{d}: {s}\n", .{ lerr.location.line, lerr.location.column, lerr.message }) catch {};
        }
        return .{ .error_phase = "lex" };
    }

    // ── Parse ───────────────────────────────────────────────────────
    var parser = Parser.init(lex.tokens.items, allocator);
    defer parser.deinit();
    var program = parser.parse() catch {
        stderr.print("  ERROR: parser failure\n", .{}) catch {};
        if (parser.hasErrors()) {
            for (parser.errors.items) |perr| {
                stderr.print("  PARSE {d}:{d}: {s}\n", .{ perr.location.line, perr.location.column, perr.message }) catch {};
            }
        }
        return .{ .error_phase = "parse" };
    };
    if (parser.hasErrors()) {
        for (parser.errors.items) |perr| {
            stderr.print("  PARSE {d}:{d}: {s}\n", .{ perr.location.line, perr.location.column, perr.message }) catch {};
        }
        return .{ .error_phase = "parse" };
    }

    // ── Semantic analysis ───────────────────────────────────────────
    var analyzer = SemanticAnalyzer.init(allocator);
    defer analyzer.deinit();
    if (safe_mode) applySafeMode(&analyzer);
    const sem_ok = analyzer.analyze(&program) catch {
        stderr.print("  ERROR: semantic analysis failure\n", .{}) catch {};
        return .{ .error_phase = "semantic" };
    };
    if (!sem_ok) {
        for (analyzer.errors.items) |serr| {
            stderr.print("  SEM {d}:{d}: [{s}] {s}\n", .{
                serr.location.line,
                serr.location.column,
                @tagName(serr.error_type),
                serr.message,
            }) catch {};
        }
        return .{ .error_phase = "semantic" };
    }

    if (analyzer.symbol_table.requires_graphics_mode) {
        program.build_mode = .graphics;
    }

    // ── AST optimization ────────────────────────────────────────────
    var ast_opt = ASTOptimizer.init(analyzer.getSymbolTable(), allocator);
    defer ast_opt.deinit();
    if (!no_optimize) {
        ast_opt.optimize(@constCast(&program)) catch {
            stderr.print("  ERROR: AST optimization failure\n", .{}) catch {};
            return .{ .error_phase = "ast_opt" };
        };
    }

    // ── CFG ─────────────────────────────────────────────────────────
    var cfg_builder = CFGBuilder.init(allocator);
    defer cfg_builder.deinit();
    const program_cfg = cfg_builder.buildFromProgram(&program) catch {
        stderr.print("  ERROR: CFG construction failure\n", .{}) catch {};
        return .{ .error_phase = "cfg" };
    };

    if (backend != .llvm) {
        stderr.print("  ERROR: backend '{s}' not implemented (only LLVM available)\n", .{backendName(backend)}) catch {};
        return .{ .error_phase = "backend" };
    }

    // ── LLVM IR codegen ─────────────────────────────────────────────
    var llvm_state = LLVMState.init("basic_module") catch {
        stderr.print("  ERROR: LLVM initialization failure\n", .{}) catch {};
        return .{ .error_phase = "codegen" };
    };

    var generator = CodeGenerator.init(allocator, &llvm_state);
    defer generator.deinit();
    generator.function_cfgs = &cfg_builder.function_cfgs;
    generator.semantic_symbols = &analyzer.symbol_table;
    generator.is_jit_mode = true; // JIT helper always uses "main" entry point
    generator.fast_math_trig = fast_math_trig;
    generator.enable_o3_hot_loop_expr_elision = false;
    generator.enable_o3_fast_array_inbounds_hints = false;
    generator.enable_o3_array_tbaa = false;
    generator.enable_o1_array_index_clamp = true;
    generator.enable_o0_array_index_trap = false;

    _ = generator.generateWithProgram(program_cfg, &program) catch {
        llvm_state.deinit();
        stderr.print("  ERROR: LLVM code generation failure\n", .{}) catch {};
        return .{ .error_phase = "codegen" };
    };

    // ── Verify module ───────────────────────────────────────────────
    {
        var verify_msg: [*c]u8 = null;
        if (llvm.LLVMVerifyModule(llvm_state.module, llvm.LLVMReturnStatusAction, &verify_msg) != 0) {
            if (verify_msg != null) {
                stderr.print("  ERROR: LLVM verification: {s}\n", .{std.mem.span(verify_msg)}) catch {};
                llvm.LLVMDisposeMessage(verify_msg);
            }
            llvm_state.deinit();
            return .{ .error_phase = "verify" };
        }
        if (verify_msg != null) llvm.LLVMDisposeMessage(verify_msg);
    }

    // ── Optimize ────────────────────────────────────────────────────
    if (!no_optimize) {
        if (llvm_state.target_machine) |tm| {
            const pass_opts = llvm.LLVMCreatePassBuilderOptions();
            defer llvm.LLVMDisposePassBuilderOptions(pass_opts);
            const pass_err = llvm.LLVMRunPasses(llvm_state.module, "default<O1>", tm, pass_opts);
            if (pass_err != null) {
                const err_msg = llvm.LLVMGetErrorMessage(pass_err);
                if (err_msg != null) llvm.LLVMDisposeErrorMessage(err_msg);
            }
        }
    }

    // ── LLJIT ───────────────────────────────────────────────────────
    var jit = LLVMJit.init() catch {
        llvm_state.deinit();
        stderr.print("  ERROR: LLJIT engine creation failed\n", .{}) catch {};
        return .{ .error_phase = "jit_init" };
    };

    jit.addProcessSymbols() catch {
        jit.deinit();
        llvm_state.deinit();
        stderr.print("  ERROR: Failed to register process symbols\n", .{}) catch {};
        return .{ .error_phase = "jit_symbols" };
    };

    jit.addModule(llvm_state.module, llvm_state.target_machine, null) catch {
        jit.deinit();
        if (!jit.took_module_ownership) llvm_state.deinit();
        stderr.print("  ERROR: Failed to add module to LLJIT\n", .{}) catch {};
        return .{ .error_phase = "jit_compile" };
    };

    // Module is now owned by LLJIT — dispose remaining state
    if (llvm_state.target_machine) |tm| {
        llvm.LLVMDisposeTargetMachine(tm);
        llvm_state.target_machine = null;
    }
    llvm.LLVMDisposeBuilder(llvm_state.builder);

    const t_before_exec = std.time.nanoTimestamp();

    // ── Execute ─────────────────────────────────────────────────────
    const exec_result = jit.executeMain();

    const t_after_exec = std.time.nanoTimestamp();

    const compile_ms = phaseMs(t_file_start, t_before_exec);
    const exec_ms = phaseMs(t_before_exec, t_after_exec);

    jit.deinit();

    // ── Per-file metrics ────────────────────────────────────────────
    if (show_metrics) {
        var samm_stats: SAMMStats = undefined;
        samm_get_stats(&samm_stats);

        const total_ms = phaseMs(t_file_start, t_after_exec);

        stderr.print("  compile={d:.3}ms  exec={d:.3}ms  total={d:.3}ms", .{ compile_ms, exec_ms, total_ms }) catch {};
        stderr.print("  samm_alloc={d}  samm_freed={d}", .{ samm_stats.objects_allocated, samm_stats.objects_freed + samm_stats.objects_cleaned }) catch {};

        const leaked: i64 = @as(i64, @intCast(samm_stats.objects_allocated)) - @as(i64, @intCast(samm_stats.objects_freed + samm_stats.objects_cleaned));
        if (leaked > 0) {
            stderr.print("  LEAKED={d}", .{leaked}) catch {};
        }
        stderr.print("\n", .{}) catch {};
    }

    if (shouldPrintStringMetrics()) {
        printStringMetrics(stderr);
    }

    if (exec_result.completed) {
        return .{
            .ok = exec_result.exit_code == 0,
            .exit_code = exec_result.exit_code,
            .compile_ms = compile_ms,
            .exec_ms = exec_ms,
            .error_phase = if (exec_result.exit_code != 0) "runtime" else null,
        };
    } else {
        stderr.print("  ERROR: JIT execution did not complete\n", .{}) catch {};
        return .{ .exit_code = -1, .compile_ms = compile_ms, .exec_ms = exec_ms, .error_phase = "exec" };
    }
}

// ─── LLVM IR to string helper ───────────────────────────────────────────────

fn llvmModuleToString(module: llvm.LLVMModuleRef) ?[]const u8 {
    const raw = llvm.LLVMPrintModuleToString(module);
    if (raw == null) return null;
    return std.mem.span(raw);
}

// ═══════════════════════════════════════════════════════════════════════════
// Main Entry Point
// ═══════════════════════════════════════════════════════════════════════════

pub fn cliMain() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const stderr = std.fs.File.stderr().deprecatedWriter();
    const stdout = std.fs.File.stdout().deprecatedWriter();
    var shared_region: ?jit_shared.SharedRegion = null;
    var shared_redirect: ?SharedRedirect = null;

    // Parse command-line arguments
    const opts = parseArgs(allocator);

    // Shared-memory JIT setup (if requested)
    if (opts.jit_shared_name) |name| {
        if (opts.batch_jit_path != null) {
            stderr.print("Error: --jit-shared cannot be used with --batch-jit\n", .{}) catch {};
            exitWith(1, &shared_redirect, &shared_region);
        }

        var name_buf: [256]u8 = undefined;
        if (name.len + 1 > name_buf.len) {
            stderr.print("Error: shared memory name too long\n", .{}) catch {};
            exitWith(1, &shared_redirect, &shared_region);
        }
        @memcpy(name_buf[0..name.len], name);
        name_buf[name.len] = 0;
        const name_z: [:0]const u8 = name_buf[0..name.len :0];

        shared_region = jit_shared.open(name_z) catch {
            stderr.print("Error: cannot open shared memory '{s}'\n", .{name}) catch {};
            exitWith(1, &shared_redirect, &shared_region);
        };

        shared_redirect = SharedRedirect.start(&shared_region.?) catch {
            stderr.print("Error: cannot redirect output to shared memory\n", .{}) catch {};
            exitWith(1, &shared_redirect, &shared_region);
        };
        if (shared_redirect) |*redirect| {
            redirect.startThreads();
        }

        g_shared_input = SharedInputFeeder.start(&shared_region.?) catch {
            stderr.print("Error: cannot redirect input from shared memory\n", .{}) catch {};
            exitWith(1, &shared_redirect, &shared_region);
        };
        if (g_shared_input) |*input| {
            input.startThread();
        }
    }

    // Handle --help
    if (opts.show_help) {
        printHelp(stdout);
        return;
    }

    // Handle --version
    if (opts.show_version) {
        stdout.print("{s}\n", .{version_string}) catch {};
        stdout.print("LLVM backend (dynamic, LLJIT)\n", .{}) catch {};
        stdout.print("Selected backend: {s}\n", .{backendName(opts.backend)}) catch {};
        stdout.print("Available backends: llvm (default, implemented), qbe (planned), luajit (planned)\n", .{}) catch {};
        return;
    }

    // Handle parse errors
    if (opts.error_message) |msg| {
        stderr.print("Error: {s}\n", .{msg}) catch {};
        stderr.print("Try 'Ed --help' for usage information.\n", .{}) catch {};
        exitWith(1, &shared_redirect, &shared_region);
    }

    // Trace switch propagated to codegen/runtime music blob paths.
    if (opts.trace_abc) {
        _ = setenv("ED_TRACE_ABC", "1", 1);
    }

    if (opts.trace_hashmaps) {
        _ = setenv("ED_TRACE_HASHMAPS", "1", 1);
    }

    if (opts.track_string_leaks) {
        _ = setenv("EDBASIC_TRACK_STRING_LEAKS", "1", 1);
    }

    // Toggle ABC chord-symbol playback (default is visual-only).
    if (opts.play_chords) {
        _ = setenv("ED_PLAY_CHORDS", "1", 1);
    }

    // ── Batch JIT mode ──────────────────────────────────────────────
    if (opts.batch_jit_path) |batch_dir| {
        if (opts.backend != .llvm) {
            stderr.print("Error: backend '{s}' not implemented for batch JIT (only LLVM available)\n", .{backendName(opts.backend)}) catch {};
            exitWith(1, &shared_redirect, &shared_region);
        }

        stderr.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{}) catch {};
        stderr.print("  fbc --batch-jit  {s}  ({s})\n", .{ batch_dir, backendName(opts.backend) }) catch {};
        stderr.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{}) catch {};

        const files = scanBasicFilesRecursive(batch_dir, allocator) catch |err| {
            stderr.print("Error: cannot scan '{s}': {s}\n", .{ batch_dir, @errorName(err) }) catch {};
            exitWith(1, &shared_redirect, &shared_region);
        };

        if (files.len == 0) {
            stderr.print("No .bas files found in '{s}'\n", .{batch_dir}) catch {};
            exitWith(1, &shared_redirect, &shared_region);
        }

        stderr.print("Found {d} .bas file(s)\n\n", .{files.len}) catch {};

        basic_jit_arm_signals();
        defer basic_jit_disarm_signals();

        const t_batch_start = std.time.nanoTimestamp();
        var passed: usize = 0;
        var failed: usize = 0;
        var total_compile_ms: f64 = 0;
        var total_exec_ms: f64 = 0;

        for (files, 0..) |file_path, i| {
            msg_metrics_reset();
            string_metrics_reset();

            stderr.print("[{d}/{d}] {s}\n", .{ i + 1, files.len, file_path }) catch {};

            const result = runSingleBatchFile(
                file_path,
                gpa.allocator(),
                opts.backend,
                opts.verbose,
                opts.jit_verbose,
                opts.metrics,
                opts.batch_timeout,
                opts.safe_mode,
                opts.no_optimize,
                opts.fast_math_trig,
            );

            total_compile_ms += result.compile_ms;
            total_exec_ms += result.exec_ms;

            if (result.ok) {
                stderr.print("  OK    {s}\n", .{file_path}) catch {};
                passed += 1;
            } else {
                if (result.timed_out) {
                    stderr.print("  TIMEOUT (>{d}s)  {s}\n", .{ opts.batch_timeout, file_path }) catch {};
                } else if (result.error_phase) |phase| {
                    stderr.print("  FAIL ({s}, exit={d})  {s}\n", .{ phase, result.exit_code, file_path }) catch {};
                } else {
                    stderr.print("  FAIL (exit={d})  {s}\n", .{ result.exit_code, file_path }) catch {};
                }
                failed += 1;
                if (opts.batch_fail_fast) {
                    stderr.print("\n--fail-fast: stopping after first failure\n", .{}) catch {};
                    break;
                }
            }
        }

        const t_batch_end = std.time.nanoTimestamp();
        const batch_total_ms = phaseMs(t_batch_start, t_batch_end);

        stderr.print("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{}) catch {};
        stderr.print("  Batch Summary ({s})\n", .{backendName(opts.backend)}) catch {};
        stderr.print("──────────────────────────────────────────────────────\n", .{}) catch {};
        stderr.print("  Files:     {d}\n", .{files.len}) catch {};
        stderr.print("  Passed:    {d}\n", .{passed}) catch {};
        stderr.print("  Failed:    {d}\n", .{failed}) catch {};
        stderr.print("  Compile:   {d:.3} ms\n", .{total_compile_ms}) catch {};
        stderr.print("  Execute:   {d:.3} ms\n", .{total_exec_ms}) catch {};
        stderr.print("  Total:     {d:.3} ms\n", .{batch_total_ms}) catch {};
        stderr.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{}) catch {};

        if (failed > 0) {
            exitWith(1, &shared_redirect, &shared_region);
        }
        return;
    }

    // Require input file
    const input_path = if (shared_region != null)
        "<shared>"
    else
        opts.input_path orelse {
            stderr.print("Error: no input file specified\n", .{}) catch {};
            stderr.print("Try 'Ed --help' for usage information.\n", .{}) catch {};
            exitWith(1, &shared_redirect, &shared_region);
        };

    // Validate input file extension
    if (shared_region == null and !isBasicFile(input_path)) {
        stderr.print("Warning: input file '{s}' does not have a .bas extension\n", .{input_path}) catch {};
    }

    if (opts.verbose or (opts.mode == .jit and opts.jit_verbose)) {
        stderr.print("{s}\n", .{version_string}) catch {};
        stderr.print("Input: {s}\n", .{input_path}) catch {};
        stderr.print("Mode: {s}\n", .{@tagName(opts.mode)}) catch {};
        stderr.print("Backend: {s}\n", .{backendName(opts.backend)}) catch {};
    }

    // ── Metrics timing ──────────────────────────────────────────────────
    const t_start_ns = std.time.nanoTimestamp();
    var t_after_read_ns: i128 = t_start_ns;
    var t_after_lex_ns: i128 = t_start_ns;
    var t_after_parse_ns: i128 = t_start_ns;
    var t_after_semantic_ns: i128 = t_start_ns;
    var t_after_cfg_ns: i128 = t_start_ns;
    var t_after_codegen_ns: i128 = t_start_ns;
    var t_after_opt_ns: i128 = t_start_ns;
    var t_after_jit_ns: i128 = t_start_ns;
    var t_after_exec_ns: i128 = t_start_ns;

    // ── Phase 1: Read source file ───────────────────────────────────────

    var source_owned: ?[]const u8 = null;
    const source: []const u8 = if (shared_region) |region|
        region.source[0..region.header.source_len]
    else blk: {
        const s = readSourceFile(input_path, allocator) catch |err| {
            stderr.print("Error: cannot open '{s}': {s}\n", .{ input_path, @errorName(err) }) catch {};
            exitWith(1, &shared_redirect, &shared_region);
        };
        source_owned = s;
        break :blk s;
    };
    defer if (source_owned) |s| allocator.free(s);

    if (opts.verbose) {
        stderr.print("Read {d} bytes from {s}\n", .{ source.len, input_path }) catch {};
    }
    t_after_read_ns = std.time.nanoTimestamp();

    // ── Phase 2: Lexical analysis ───────────────────────────────────────

    var lex = Lexer.init(source, allocator);
    defer lex.deinit();

    lex.tokenize() catch |err| {
        stderr.print("Error: lexer failure: {s}\n", .{@errorName(err)}) catch {};
        exitWith(1, &shared_redirect, &shared_region);
    };

    if (lex.hasErrors()) {
        stderr.print("Lexer errors in '{s}':\n", .{input_path}) catch {};
        for (lex.errors.items) |lerr| {
            stderr.print("  {d}:{d}: {s}\n", .{ lerr.location.line, lerr.location.column, lerr.message }) catch {};
        }
        exitWith(1, &shared_redirect, &shared_region);
    }

    if (opts.verbose) {
        stderr.print("Lexer: {d} tokens\n", .{lex.tokens.items.len}) catch {};
    }
    t_after_lex_ns = std.time.nanoTimestamp();

    if (opts.show_tokens) {
        dumpTokens(lex.tokens.items, stderr);
    }

    // ── Phase 3: Parsing ────────────────────────────────────────────────

    var parser = Parser.init(lex.tokens.items, allocator);
    defer parser.deinit();

    var program = parser.parse() catch |err| {
        stderr.print("Error: parser failure: {s}\n", .{@errorName(err)}) catch {};
        if (parser.hasErrors()) {
            for (parser.errors.items) |perr| {
                stderr.print("  {d}:{d}: {s}\n", .{ perr.location.line, perr.location.column, perr.message }) catch {};
            }
        }
        exitWith(1, &shared_redirect, &shared_region);
    };

    if (parser.hasErrors()) {
        stderr.print("Parse errors in '{s}':\n", .{input_path}) catch {};
        for (parser.errors.items) |perr| {
            stderr.print("  {d}:{d}: {s}\n", .{ perr.location.line, perr.location.column, perr.message }) catch {};
        }
        exitWith(1, &shared_redirect, &shared_region);
    }

    if (opts.verbose) {
        stderr.print("Parser: {d} program lines\n", .{program.lines.len}) catch {};
    }
    t_after_parse_ns = std.time.nanoTimestamp();

    // ── Debug: AST dump ─────────────────────────────────────────────────

    if (opts.trace_ast) {
        dumpAST(&program, stderr);
        return;
    }

    // ── Phase 4: Semantic analysis ──────────────────────────────────────

    var analyzer = SemanticAnalyzer.init(allocator);
    defer analyzer.deinit();
    if (opts.safe_mode) applySafeMode(&analyzer);

    const sem_ok = analyzer.analyze(&program) catch |err| {
        stderr.print("Error: semantic analysis failure: {s}\n", .{@errorName(err)}) catch {};
        exitWith(1, &shared_redirect, &shared_region);
    };

    if (!sem_ok) {
        stderr.print("Semantic errors in '{s}':\n", .{input_path}) catch {};
        for (analyzer.errors.items) |serr| {
            stderr.print("  {d}:{d}: [{s}] {s}\n", .{
                serr.location.line,
                serr.location.column,
                @tagName(serr.error_type),
                serr.message,
            }) catch {};
        }
        exitWith(1, &shared_redirect, &shared_region);
    }

    if (analyzer.symbol_table.requires_graphics_mode) {
        program.build_mode = .graphics;
    }

    // Print warnings
    for (analyzer.warnings.items) |warn| {
        stderr.print("Warning at {d}:{d}: {s}\n", .{
            warn.location.line,
            warn.location.column,
            warn.message,
        }) catch {};
    }

    if (opts.verbose) {
        stderr.print("Semantic analysis: OK ({d} warnings)\n", .{analyzer.warnings.items.len}) catch {};
    }
    t_after_semantic_ns = std.time.nanoTimestamp();

    // ── Debug: Symbol table dump ────────────────────────────────────────

    if (opts.trace_symbols) {
        dumpSymbolTable(analyzer.getSymbolTable(), stderr);
        return;
    }

    // ── Phase 4a: AST optimization ──────────────────────────────────────

    var ast_opt = ASTOptimizer.init(analyzer.getSymbolTable(), allocator);
    defer ast_opt.deinit();

    if (!opts.no_optimize) {
        ast_opt.optimize(@constCast(&program)) catch |err| {
            stderr.print("Error: AST optimization failure: {s}\n", .{@errorName(err)}) catch {};
            exitWith(1, &shared_redirect, &shared_region);
        };
    }

    if (opts.verbose and ast_opt.stats.total() > 0) {
        stderr.print("AST optimizer: {d} optimizations\n", .{ast_opt.stats.total()}) catch {};
    }

    // ── Phase 4b: Control Flow Graph construction ───────────────────────

    var cfg_builder = CFGBuilder.init(allocator);
    defer cfg_builder.deinit();

    const program_cfg = cfg_builder.buildFromProgram(&program) catch |err| {
        stderr.print("Error: CFG construction failure: {s}\n", .{@errorName(err)}) catch {};
        exitWith(1, &shared_redirect, &shared_region);
    };

    if (opts.verbose) {
        stderr.print("CFG: {d} blocks, {d} edges, {d} loops, {d} unreachable\n", .{
            program_cfg.numBlocks(),
            program_cfg.numEdges(),
            program_cfg.loops.items.len,
            program_cfg.unreachable_count,
        }) catch {};
    }
    t_after_cfg_ns = std.time.nanoTimestamp();

    // ── Debug: CFG dump ─────────────────────────────────────────────────

    if (opts.trace_cfg) {
        program_cfg.dump(stderr);

        var func_it = cfg_builder.function_cfgs.iterator();
        while (func_it.next()) |entry| {
            entry.value_ptr.dump(stderr);
        }

        return;
    }

    // Report unreachable code as warnings.
    if (program_cfg.unreachable_count > 0) {
        var unreachable_blocks: std.ArrayList(u32) = .empty;
        defer unreachable_blocks.deinit(allocator);
        program_cfg.getUnreachableBlocks(&unreachable_blocks, allocator) catch {};
        for (unreachable_blocks.items) |blk_idx| {
            const blk = program_cfg.getBlockConst(blk_idx);
            if (!blk.isEmpty()) {
                stderr.print("Warning: unreachable code at {d}:{d} (block {s})\n", .{
                    blk.loc.line,
                    blk.loc.column,
                    blk.name,
                }) catch {};
            }
        }
    }

    // ── Phase 5: Backend Code Generation ──────────────────────────────

    var llvm_state: LLVMState = undefined;

    switch (opts.backend) {
        .llvm => {
            llvm_state = LLVMState.init("basic_module") catch {
                stderr.print("Error: LLVM initialization failure\n", .{}) catch {};
                exitWith(1, &shared_redirect, &shared_region);
            };
            // NOTE: On success for JIT mode, the module is transferred to LLJIT.
            // We only call llvm_state.deinit() on error paths.

            var generator = CodeGenerator.init(allocator, &llvm_state);
            defer generator.deinit();
            generator.function_cfgs = &cfg_builder.function_cfgs;
            generator.semantic_symbols = &analyzer.symbol_table;
            generator.is_jit_mode = (opts.mode == .jit); // JIT uses "main"; AOT uses mode-dependent entry
            generator.fast_math_trig = opts.fast_math_trig;
            generator.enable_o3_hot_loop_expr_elision = !opts.no_optimize and std.mem.eql(u8, opts.opt_level, "O3");
            generator.enable_o3_fast_array_inbounds_hints = !opts.no_optimize and std.mem.eql(u8, opts.opt_level, "O3");
            generator.enable_o3_array_tbaa = !opts.no_optimize and std.mem.eql(u8, opts.opt_level, "O3");
            generator.enable_o1_array_index_clamp = std.mem.eql(u8, opts.opt_level, "O1");
            generator.enable_o0_array_index_trap = std.mem.eql(u8, opts.opt_level, "O0");

            _ = generator.generateWithProgram(program_cfg, &program) catch |err| {
                stderr.print("Error: LLVM code generation failure: {s}\n", .{@errorName(err)}) catch {};
                llvm_state.deinit();
                exitWith(1, &shared_redirect, &shared_region);
            };

            if (opts.verbose) {
                stderr.print("LLVM IR generation: OK\n", .{}) catch {};
            }
            t_after_codegen_ns = std.time.nanoTimestamp();

            // ── Verify module ───────────────────────────────────────────────────
            {
                var verify_msg: [*c]u8 = null;
                if (llvm.LLVMVerifyModule(llvm_state.module, llvm.LLVMReturnStatusAction, &verify_msg) != 0) {
                    if (verify_msg != null) {
                        stderr.print("Error: LLVM module verification failed:\n  {s}\n", .{std.mem.span(verify_msg)}) catch {};
                        llvm.LLVMDisposeMessage(verify_msg);
                    } else {
                        stderr.print("Error: LLVM module verification failed\n", .{}) catch {};
                    }
                    llvm_state.deinit();
                    exitWith(1, &shared_redirect, &shared_region);
                }
                if (verify_msg != null) llvm.LLVMDisposeMessage(verify_msg);
            }

            // ── Show LLVM IR (before optimization) if requested ─────────────────
            if (opts.show_il) {
                if (llvmModuleToString(llvm_state.module)) |ir_str| {
                    stderr.print("\n=== LLVM IR (pre-opt) ===\n{s}\n=== End LLVM IR ===\n\n", .{ir_str}) catch {};
                    llvm.LLVMDisposeMessage(@ptrCast(@constCast(ir_str.ptr)));
                }
            }

            // ── Phase 6: LLVM Optimization Passes ───────────────────────────────

            const opt_pass_str: [*:0]const u8 = if (opts.no_optimize)
                "default<O0>"
            else if (opts.mode == .jit) blk: {
                if (std.mem.eql(u8, opts.opt_level, "O0")) break :blk "default<O0>";
                if (std.mem.eql(u8, opts.opt_level, "O2")) break :blk "default<O2>";
                if (std.mem.eql(u8, opts.opt_level, "O3")) break :blk "default<O3>";
                break :blk "default<O1>"; // default for JIT
            } else blk: {
                if (std.mem.eql(u8, opts.opt_level, "O0")) break :blk "default<O0>";
                if (std.mem.eql(u8, opts.opt_level, "O1")) break :blk "default<O1>";
                if (std.mem.eql(u8, opts.opt_level, "O3")) break :blk "default<O3>";
                break :blk "default<O2>"; // default for AOT
            };

            if (llvm_state.target_machine) |tm| {
                const pass_opts = llvm.LLVMCreatePassBuilderOptions();
                defer llvm.LLVMDisposePassBuilderOptions(pass_opts);

                if (opts.verbose) {
                    stderr.print("Running LLVM passes: {s}\n", .{opt_pass_str}) catch {};
                }

                const pass_err = llvm.LLVMRunPasses(llvm_state.module, opt_pass_str, tm, pass_opts);
                if (pass_err != null) {
                    const err_msg = llvm.LLVMGetErrorMessage(pass_err);
                    if (err_msg != null) {
                        stderr.print("Warning: LLVM optimization pass error: {s}\n", .{std.mem.span(err_msg)}) catch {};
                        llvm.LLVMDisposeErrorMessage(err_msg);
                    }
                    // Non-fatal — we can still proceed with un-optimized IR
                }
            }
            t_after_opt_ns = std.time.nanoTimestamp();
        },
        .qbe => {
            var qbe_gen = qbe_codegen.CodeGenerator.init(allocator);
            defer qbe_gen.deinit();
            qbe_gen.function_cfgs = &cfg_builder.function_cfgs;

            const qbe_opts = qbe_codegen.GenerateOptions{
                .target_name = null,
                .emit_comments = true,
                .jit = opts.mode == .jit,
            };

            const il = qbe_gen.generateWithProgram(program_cfg, &program, qbe_opts) catch |err| {
                stderr.print("Error: QBE code generation failure: {s}\n", .{@errorName(err)}) catch {};
                exitWith(1, &shared_redirect, &shared_region);
            };

            t_after_codegen_ns = std.time.nanoTimestamp();

            if (opts.show_il or opts.mode == .il_only) {
                stderr.print("\n=== QBE IL (scaffold) ===\n{s}\n=== End QBE IL ===\n\n", .{il}) catch {};
            }

            if (opts.mode == .il_only) {
                t_after_opt_ns = std.time.nanoTimestamp();
                exitWith(0, &shared_redirect, &shared_region);
            }

            if (opts.mode == .jit) {
                var jit_result = qbe.compileILJit(allocator, il, qbe_opts.target_name) catch |err| {
                    stderr.print("Error: QBE JIT compilation failed: {s}\n", .{@errorName(err)}) catch {};
                    exitWith(1, &shared_redirect, &shared_region);
                };
                defer jit_result.deinit();

                t_after_opt_ns = std.time.nanoTimestamp();

                stderr.print("QBE JIT pipeline completed (execution not wired yet).\n", .{}) catch {};
                exitWith(0, &shared_redirect, &shared_region);
            } else {
                qbe.compileIL(il, "out.s", qbe_opts.target_name) catch |err| {
                    stderr.print("Error: QBE AOT emission failed: {s}\n", .{@errorName(err)}) catch {};
                    exitWith(1, &shared_redirect, &shared_region);
                };

                t_after_opt_ns = std.time.nanoTimestamp();

                stderr.print("QBE AOT emission completed to out.s (execution/link not wired yet).\n", .{}) catch {};
                exitWith(0, &shared_redirect, &shared_region);
            }
        },
        .luajit => {
            stderr.print("Error: backend '{s}' not implemented yet\n", .{backendName(opts.backend)}) catch {};
            exitWith(1, &shared_redirect, &shared_region);
        },
    }

    // ── Phase 7: Output ─────────────────────────────────────────────────

    switch (opts.mode) {
        .jit => {
            // ── JIT Mode: LLVM IR → LLJIT → execute in-process ──────────

            if (opts.verbose or opts.jit_verbose) {
                stderr.print("LLJIT: creating engine...\n", .{}) catch {};
            }

            // Create LLJIT engine
            var jit = LLVMJit.init() catch {
                llvm_state.deinit();
                stderr.print("Error: LLJIT engine creation failed\n", .{}) catch {};
                exitWith(1, &shared_redirect, &shared_region);
            };

            // Register process symbols (dlsym fallback for runtime functions)
            jit.addProcessSymbols() catch {
                jit.deinit();
                llvm_state.deinit();
                stderr.print("Error: Failed to register process symbols with LLJIT\n", .{}) catch {};
                exitWith(1, &shared_redirect, &shared_region);
            };

            // Transfer the module to LLJIT
            jit.addModule(llvm_state.module, llvm_state.target_machine, null) catch {
                jit.deinit();
                if (!jit.took_module_ownership) llvm_state.deinit();
                stderr.print("Error: Failed to add module to LLJIT\n", .{}) catch {};
                exitWith(1, &shared_redirect, &shared_region);
            };

            // Module is now owned by LLJIT — dispose remaining LLVM state
            if (llvm_state.target_machine) |tm| {
                llvm.LLVMDisposeTargetMachine(tm);
                llvm_state.target_machine = null;
            }
            llvm.LLVMDisposeBuilder(llvm_state.builder);

            t_after_jit_ns = std.time.nanoTimestamp();

            if (opts.verbose or opts.jit_verbose) {
                stderr.print("LLJIT: executing...\n", .{}) catch {};
            }

            // Execute via AppKit runner (needed for programs that use graphics)
            if (opts.dump_canvas) gfx_canvas_dump_enable();
            var exec_ctx = JitExecContext{
                .jit = &jit,
                .result = undefined,
            };
            string_metrics_reset();
            fbc_run_with_appkit(&JitExecContext.workerFn, @ptrCast(&exec_ctx));
            const exec_result = exec_ctx.result;
            t_after_exec_ns = std.time.nanoTimestamp();

            jit.deinit();

            // ── Metrics report ──────────────────────────────────────
            if (opts.metrics) {
                var samm_stats: SAMMStats = undefined;
                samm_get_stats(&samm_stats);

                const m_read = phaseMs(t_start_ns, t_after_read_ns);
                const m_lex = phaseMs(t_after_read_ns, t_after_lex_ns);
                const m_parse = phaseMs(t_after_lex_ns, t_after_parse_ns);
                const m_sem = phaseMs(t_after_parse_ns, t_after_semantic_ns);
                const m_cfg = phaseMs(t_after_semantic_ns, t_after_cfg_ns);
                const m_cg = phaseMs(t_after_cfg_ns, t_after_codegen_ns);
                const m_opt = phaseMs(t_after_codegen_ns, t_after_opt_ns);
                const m_jit = phaseMs(t_after_opt_ns, t_after_jit_ns);
                const m_exec = phaseMs(t_after_jit_ns, t_after_exec_ns);
                const m_total = phaseMs(t_start_ns, t_after_exec_ns);

                printMetrics(stderr, opts.backend, samm_stats, .{
                    .read_ms = m_read,
                    .lex_ms = m_lex,
                    .parse_ms = m_parse,
                    .semantic_ms = m_sem,
                    .cfg_ms = m_cfg,
                    .codegen_ms = m_cg,
                    .llvm_opt_ms = m_opt,
                    .llvm_jit_ms = m_jit,
                    .jit_exec_ms = m_exec,
                    .total_ms = m_total,
                });
            }

            if (shouldPrintStringMetrics()) {
                printStringMetrics(stderr);
            }

            if (exec_result.completed) {
                if (opts.verbose or opts.jit_verbose) {
                    stderr.print("LLJIT: exit code = {d}\n", .{exec_result.exit_code}) catch {};
                }
                if (exec_result.exit_code != 0) {
                    exitWith(@intCast(@as(u32, @bitCast(exec_result.exit_code)) & 0xFF), &shared_redirect, &shared_region);
                }
            } else {
                stderr.print("Error: JIT execution did not complete\n", .{}) catch {};
                exitWith(1, &shared_redirect, &shared_region);
            }
        },

        .il_only => {
            // ── Emit LLVM IR ────────────────────────────────────────────
            defer llvm_state.deinit();

            const ir_raw = llvm.LLVMPrintModuleToString(llvm_state.module);
            if (ir_raw == null) {
                stderr.print("Error: Failed to print LLVM IR\n", .{}) catch {};
                exitWith(1, &shared_redirect, &shared_region);
            }
            defer llvm.LLVMDisposeMessage(ir_raw);

            const ir_str = std.mem.span(ir_raw);

            if (opts.output_path) |out_path| {
                const out_file = std.fs.cwd().createFile(out_path, .{}) catch |err| {
                    stderr.print("Error: cannot create output file '{s}': {s}\n", .{ out_path, @errorName(err) }) catch {};
                    exitWith(1, &shared_redirect, &shared_region);
                };
                defer out_file.close();
                out_file.writeAll(ir_str) catch |err| {
                    stderr.print("Error: cannot write output file: {s}\n", .{@errorName(err)}) catch {};
                    exitWith(1, &shared_redirect, &shared_region);
                };
                if (opts.verbose) {
                    stderr.print("Wrote LLVM IR to {s}\n", .{out_path}) catch {};
                }
            } else {
                stdout.writeAll(ir_str) catch {};
            }
        },

        .executable => {
            // ── Full AOT compilation: LLVM IR → object → link → executable ──
            defer llvm_state.deinit();

            const output_path = opts.output_path orelse (deriveOutputPath(input_path, .executable, allocator) catch {
                stderr.print("Error: cannot derive output path\n", .{}) catch {};
                exitWith(1, &shared_redirect, &shared_region);
            });

            // Emit object file
            const obj_path = std.fmt.allocPrint(allocator, "/tmp/fbc_llvm_{d}.o", .{std.time.milliTimestamp()}) catch {
                stderr.print("Error: out of memory\n", .{}) catch {};
                exitWith(1, &shared_redirect, &shared_region);
            };
            defer allocator.free(obj_path);

            if (llvm_state.target_machine) |tm| {
                var path_buf: [512]u8 = undefined;
                if (obj_path.len >= path_buf.len - 1) {
                    stderr.print("Error: output path too long\n", .{}) catch {};
                    exitWith(1, &shared_redirect, &shared_region);
                }
                @memcpy(path_buf[0..obj_path.len], obj_path);
                path_buf[obj_path.len] = 0;
                const path_ptr: [*:0]u8 = path_buf[0..obj_path.len :0];

                var error_msg: [*c]u8 = null;
                if (llvm.LLVMTargetMachineEmitToFile(tm, llvm_state.module, path_ptr, llvm.LLVMObjectFile, &error_msg) != 0) {
                    if (error_msg != null) {
                        stderr.print("Error: LLVM object emission: {s}\n", .{std.mem.span(error_msg)}) catch {};
                        llvm.LLVMDisposeMessage(error_msg);
                    } else {
                        stderr.print("Error: LLVM object emission failed\n", .{}) catch {};
                    }
                    exitWith(1, &shared_redirect, &shared_region);
                }
            } else {
                stderr.print("Error: No LLVM target machine available for object emission\n", .{}) catch {};
                exitWith(1, &shared_redirect, &shared_region);
            }
            defer std.fs.cwd().deleteFile(obj_path) catch {};

            if (opts.verbose) {
                stderr.print("Emitted object file: {s}\n", .{obj_path}) catch {};
            }

            // ── Link → executable ───────────────────────────────────
            const is_console_mode = (program.build_mode == .console);

            if (opts.verbose) {
                stderr.print("Build mode: {s}\n", .{@tagName(program.build_mode)}) catch {};
            }

            var link_args: std.ArrayList([]const u8) = .empty;
            defer link_args.deinit(allocator);

            // We use generic system "zig c++" as the backend compiler/linker.
            var bundled_zig: ?[]const u8 = null;
            const exe_path_base = std.fs.selfExePathAlloc(allocator) catch null;
            if (exe_path_base) |ep2| {
                if (std.fs.path.dirname(ep2)) |exe_dir2| {
                    const maybe_zig = std.fmt.allocPrint(allocator, "{s}/zig_compiler/zig", .{exe_dir2}) catch null;
                    if (maybe_zig) |mz| {
                        if (fileExists(mz)) {
                            bundled_zig = mz;
                        } else {
                            allocator.free(mz);
                        }
                    }
                }
            }
            defer if (bundled_zig) |bz| allocator.free(bz);
            defer if (exe_path_base) |ep2| allocator.free(ep2);

            try link_args.append(allocator, if (bundled_zig != null) bundled_zig.? else "zig");
            try link_args.append(allocator, "c++");
            try link_args.append(allocator, "-O1");
            try link_args.append(allocator, "-o");
            try link_args.append(allocator, output_path);
            try link_args.append(allocator, obj_path);

            // Locate runtime libraries relative to our own executable
            const exe_path = std.fs.selfExePathAlloc(allocator) catch null;
            if (exe_path) |ep| {
                defer allocator.free(ep);
                if (std.fs.path.dirname(ep)) |exe_dir| {
                    // Zig runtime libraries (excluding graphics/audio/platform for console mode)
                    const core_runtime_libs = [_][]const u8{
                        "samm_pool",   "samm_scope",               "samm_core",
                        "memory_mgmt", "class_runtime",            "conversion_ops",
                        "string_ops",  "string_utf32",             "list_ops",
                        "string_pool", "array_descriptor_runtime", "math_ops",
                        "basic_data",  "fbc_bridge",               "io_ops_format",
                        "io_ops",      "binary_io",                "array_ops",
                        "marshalling", "messaging",                "terminal_io",
                    };

                    const graphics_runtime_libs = [_][]const u8{
                        "graphics_runtime", "audio_runtime", "fb_platform", "abc_parser",
                    };

                    // Link core runtime libraries
                    for (core_runtime_libs) |lib_name| {
                        const zig_lib_path = std.fmt.allocPrint(allocator, "{s}/../lib/lib{s}.a", .{ exe_dir, lib_name }) catch continue;
                        if (fileExists(zig_lib_path)) {
                            try link_args.append(allocator, zig_lib_path);
                            if (opts.verbose) {
                                stderr.print("  Using runtime lib: {s}\n", .{zig_lib_path}) catch {};
                            }
                        } else {
                            allocator.free(zig_lib_path);
                        }
                    }

                    // Link graphics/audio libraries only in graphics mode
                    if (!is_console_mode) {
                        for (graphics_runtime_libs) |lib_name| {
                            const zig_lib_path = std.fmt.allocPrint(allocator, "{s}/../lib/lib{s}.a", .{ exe_dir, lib_name }) catch continue;
                            if (fileExists(zig_lib_path)) {
                                try link_args.append(allocator, zig_lib_path);
                                if (opts.verbose) {
                                    stderr.print("  Using runtime lib: {s}\n", .{zig_lib_path}) catch {};
                                }
                            } else {
                                allocator.free(zig_lib_path);
                            }
                        }
                    }

                    // Runtime directory for C sources
                    const rt_dir = opts.runtime_dir orelse blk: {
                        const candidate = std.fmt.allocPrint(allocator, "{s}/../runtime", .{exe_dir}) catch break :blk null;
                        var d = std.fs.cwd().openDir(candidate, .{}) catch {
                            allocator.free(candidate);
                            break :blk null;
                        };
                        d.close();
                        break :blk candidate;
                    };

                    if (rt_dir) |dir| {
                        // Add include path
                        const inc_flag = std.fmt.allocPrint(allocator, "-I{s}", .{dir}) catch null;
                        if (inc_flag) |flag| {
                            try link_args.append(allocator, flag);
                        }

                        // Add runtime C sources (different based on build mode)
                        if (is_console_mode) {
                            // Console mode: minimal runtime, no AppKit threading
                            // Note: DO NOT include force_runtime_symbols.c in console mode
                            // because it defines basic_pset/etc. which conflict with stubs
                            const console_c_files = [_][]const u8{
                                "basic_runtime.c",
                                "worker_runtime.c",
                                "hashmap_runtime.c",
                                "runtime_shims.c",
                                "basic_worker_bridge.c",
                                "graphics_audio_stubs.c", // Stub implementations
                            };
                            for (console_c_files) |cf| {
                                const cf_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, cf }) catch continue;
                                if (fileExists(cf_path)) {
                                    try link_args.append(allocator, cf_path);
                                } else {
                                    allocator.free(cf_path);
                                }
                            }
                        } else {
                            // Graphics mode: full runtime with AppKit wrapper
                            const graphics_c_files = [_][]const u8{
                                "basic_runtime.c",
                                "worker_runtime.c",
                                "hashmap_runtime.c",
                                "runtime_shims.c",
                                "basic_worker_bridge.c",
                                "force_runtime_symbols.c",
                                "aot_main_wrapper.c", // AppKit main thread wrapper
                            };
                            for (graphics_c_files) |cf| {
                                const cf_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, cf }) catch continue;
                                if (fileExists(cf_path)) {
                                    try link_args.append(allocator, cf_path);
                                } else {
                                    allocator.free(cf_path);
                                }
                            }
                        }
                    }

                    // Add framework links for macOS (only in graphics mode)
                    if (!is_console_mode) {
                        const frameworks = [_][]const u8{
                            "Cocoa",          "Metal",
                            "MetalKit",       "CoreText",
                            "QuartzCore",     "UniformTypeIdentifiers",
                            "GameController", "AVFoundation",
                            "AudioToolbox",   "CoreMIDI",
                            "CoreAudio",      "Accelerate",
                            "WebKit",
                        };
                        for (frameworks) |fw| {
                            const fw_flag = std.fmt.allocPrint(allocator, "-framework", .{}) catch continue;
                            try link_args.append(allocator, fw_flag);
                            try link_args.append(allocator, fw);
                        }

                        // Link C++ standard library (needed by audio C++ code)
                        try link_args.append(allocator, "-lc++");
                    }
                }
            }

            // Always link libm
            try link_args.append(allocator, "-lm");

            if (opts.verbose) {
                stderr.print("Linking: ", .{}) catch {};
                for (link_args.items) |a| {
                    stderr.print("{s} ", .{a}) catch {};
                }
                stderr.print("\n", .{}) catch {};
            }

            var child = std.process.Child.init(link_args.items, allocator);
            child.stderr_behavior = .Pipe;
            child.stdout_behavior = .Pipe;
            try child.spawn();

            // Collect stderr/stdout before wait() to avoid pipe-buffer deadlocks
            var stdout_buf: std.ArrayList(u8) = .empty;
            defer stdout_buf.deinit(allocator);
            var stderr_buf: std.ArrayList(u8) = .empty;
            defer stderr_buf.deinit(allocator);
            child.collectOutput(allocator, &stdout_buf, &stderr_buf, 64 * 1024) catch {};

            const term = try child.wait();

            switch (term) {
                .Exited => |code| {
                    if (code == 0) {
                        stderr.print("Compiled: {s} → {s}\n", .{ input_path, output_path }) catch {};
                    } else {
                        stderr.print("Error: linker exited with status {d}\n", .{code}) catch {};
                        if (stderr_buf.items.len > 0) {
                            const trimmed = std.mem.trimRight(u8, stderr_buf.items, "\r\n ");
                            if (trimmed.len > 0) {
                                stderr.print("Linker output:\n{s}\n", .{trimmed}) catch {};
                            }
                        }
                        exitWith(1, &shared_redirect, &shared_region);
                    }
                },
                else => {
                    stderr.print("Error: linker process terminated abnormally\n", .{}) catch {};
                    if (stderr_buf.items.len > 0) {
                        const trimmed = std.mem.trimRight(u8, stderr_buf.items, "\r\n ");
                        if (trimmed.len > 0) {
                            stderr.print("Linker output:\n{s}\n", .{trimmed}) catch {};
                        }
                    }
                    exitWith(1, &shared_redirect, &shared_region);
                },
            }

            // Optionally run the compiled program
            if (opts.run_after_compile) {
                if (opts.verbose) {
                    stderr.print("Running ./{s}...\n", .{output_path}) catch {};
                }
                stderr.print("\n", .{}) catch {};

                const run_path = std.fmt.allocPrint(allocator, "./{s}", .{output_path}) catch {
                    stderr.print("Error: out of memory\n", .{}) catch {};
                    exitWith(1, &shared_redirect, &shared_region);
                };
                defer allocator.free(run_path);

                var run_child = std.process.Child.init(&.{run_path}, allocator);
                run_child.stderr_behavior = .Inherit;
                run_child.stdout_behavior = .Inherit;
                run_child.stdin_behavior = .Inherit;
                try run_child.spawn();
                const run_result = try run_child.wait();

                switch (run_result) {
                    .Exited => |code| {
                        if (code != 0) {
                            exitWith(@intCast(code), &shared_redirect, &shared_region);
                        }
                    },
                    else => {
                        exitWith(1, &shared_redirect, &shared_region);
                    },
                }
            }
        },
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "derive output path - executable" {
    const allocator = std.testing.allocator;
    const result = try deriveOutputPath("hello.bas", .executable, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "derive output path - il" {
    const allocator = std.testing.allocator;
    const result = try deriveOutputPath("hello.bas", .il_only, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello.ll", result);
}

test "derive output path - with directory" {
    const allocator = std.testing.allocator;
    const result = try deriveOutputPath("path/to/program.bas", .executable, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("program", result);
}

test "derive output path - no extension" {
    const allocator = std.testing.allocator;
    const result = try deriveOutputPath("myprogram", .executable, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("myprogram", result);
}

test "isBasicFile" {
    try std.testing.expect(isBasicFile("hello.bas"));
    try std.testing.expect(isBasicFile("hello.BAS"));
    try std.testing.expect(!isBasicFile("hello.txt"));
    try std.testing.expect(!isBasicFile("hello"));
}
