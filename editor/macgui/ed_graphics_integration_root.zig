// ─── Integration Test Zig Root ──────────────────────────────────────────────
//
// Root module for the graphics integration test executable.
//
// Two responsibilities:
//
//   1. Force the Zig compiler to include ed_graphics.zig and
//      graphics_runtime.zig so their `export fn` symbols are
//      available to the ObjC test harness.
//
//   2. Expose a C-callable jit_compile_and_run() that takes a BASIC
//      source string, compiles it through the full JIT pipeline
//      (lex → parse → semantic → codegen → QBE → ARM64 → link),
//      and executes the resulting machine code.  The ObjC test
//      calls this from its worker thread — the same thread topology
//      as the real editor.

const std = @import("std");

// Pull in the graphics state + C-callable bridge accessors
pub const gfx = @import("ed_graphics.zig");

// Pull in the JIT-callable runtime wrappers (gfx_screen, gfx_pset, etc.)
pub const gfx_runtime = @import("graphics_runtime.zig");

// Force the compiler to retain all exported symbols from both modules.
comptime {
    _ = &gfx_runtime;
    _ = &gfx;
}

// ═══════════════════════════════════════════════════════════════════════════
// JIT compilation + execution — called from the ObjC test worker thread
// ═══════════════════════════════════════════════════════════════════════════

const compiler = @import("compiler.zig");
const jit_stubs = @import("jit_stubs.zig");

// Force retention of jit_stubs (contains the jump table builder)
comptime {
    _ = &jit_stubs;
}

/// Result codes returned to the ObjC caller.
const JitTestResult = enum(c_int) {
    ok = 0,
    compile_error = 1,
    link_error = 2,
    exec_error = 3,
    alloc_error = 4,
};

/// Compile a BASIC source string through the full JIT pipeline and
/// execute the resulting ARM64 code.
///
/// Returns 0 on success, non-zero on failure.  Diagnostics are printed
/// to stderr so the test harness can display them.
export fn jit_compile_and_run(source_ptr: [*]const u8, source_len: usize) callconv(.c) c_int {
    const source = source_ptr[0..source_len];

    // Use the general purpose allocator — it's the closest to what the
    // editor uses and will catch leaks in debug builds.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // ── Compile ─────────────────────────────────────────────────────
    var result = compiler.compile(alloc, source) catch |err| {
        std.debug.print("  [JIT] compile() returned error: {}\n", .{err});
        return @intFromEnum(JitTestResult.alloc_error);
    };
    defer result.deinit();

    // Check for compilation errors
    if (!result.ok()) {
        std.debug.print("  [JIT] Compilation failed ({d} error(s)):\n", .{result.errorCount()});
        for (result.errors.items) |diag| {
            std.debug.print("    Line {d}: {s}\n", .{ diag.line, diag.message });
        }
        return @intFromEnum(JitTestResult.compile_error);
    }

    // Check session was created
    var session = result.session orelse {
        std.debug.print("  [JIT] No session created (link failure)\n", .{});
        return @intFromEnum(JitTestResult.link_error);
    };

    // Print link stats
    const lr = session.link_result;
    std.debug.print("  [JIT] Linked: {d} jump-table, {d} dlsym, {d} unresolved\n", .{
        lr.stats.symbols_from_jump_table,
        lr.stats.symbols_from_dlsym,
        lr.stats.symbols_unresolved,
    });

    if (lr.stats.symbols_unresolved > 0) {
        std.debug.print("  [JIT] WARNING: {d} unresolved symbol(s)\n", .{lr.stats.symbols_unresolved});
    }

    // ── Execute ─────────────────────────────────────────────────────
    const exec_result = session.execute();

    if (!exec_result.completed) {
        std.debug.print("  [JIT] Execution did not complete\n", .{});
        return @intFromEnum(JitTestResult.exec_error);
    }

    if (exec_result.exit_code != 0) {
        std.debug.print("  [JIT] Exit code: {d}\n", .{exec_result.exit_code});
        // Exit code 124 = SIGALRM (forced stop), not a real error
        if (exec_result.exit_code == 124) {
            return @intFromEnum(JitTestResult.ok);
        }
        return @intFromEnum(JitTestResult.exec_error);
    }

    return @intFromEnum(JitTestResult.ok);
}

// The real test logic is in gfx_test_main() defined in
// ed_graphics_integration_test.m (ObjC).
extern fn gfx_test_main(argc: c_int, argv: [*]const [*:0]const u8) callconv(.c) c_int;

pub fn main() u8 {
    const argv_slice = std.os.argv;
    const argc: c_int = @intCast(argv_slice.len);
    const result = gfx_test_main(argc, @ptrCast(argv_slice.ptr));
    return if (result == 0) 0 else 1;
}
