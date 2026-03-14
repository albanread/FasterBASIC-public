// ─── Sprite Integration Test — Zig Root ─────────────────────────────────────
//
// Root module for the sprite integration test executable.
//
// Pulls in ed_graphics.zig and graphics_runtime.zig so their `export fn`
// symbols (gfx_sprite_def, gfx_sprite_show, gfx_sprite_rot, etc.) are
// available to the ObjC test harness.
//
// Build & run:
//
//   zig build test-sprites
//
// Requires a display — will exit 0 (skip) if no Metal device.

const std = @import("std");

// Pull in the graphics state + C-callable bridge accessors
pub const gfx = @import("ed_graphics.zig");

// Pull in the JIT-callable runtime wrappers (gfx_sprite_*, gfx_screen, etc.)
pub const gfx_runtime = @import("graphics_runtime.zig");

// Force the compiler to retain all exported symbols from both modules.
comptime {
    _ = &gfx_runtime;
    _ = &gfx;
}

// The test logic is in sprite_test_main() defined in
// ed_sprite_integration_test.m (ObjC).
extern fn sprite_test_main(argc: c_int, argv: [*]const [*:0]const u8) callconv(.c) c_int;

pub fn main() u8 {
    const argv_slice = std.os.argv;
    const argc: c_int = @intCast(argv_slice.len);
    const result = sprite_test_main(argc, @ptrCast(argv_slice.ptr));
    return if (result == 0) 0 else 1;
}
