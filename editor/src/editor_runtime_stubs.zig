const std = @import("std");

// Editor-only compatibility exports for symbols that were previously
// provided by runtime libraries used by JIT/AOT execution.

pub export fn timer_tick_frame() callconv(.c) void {}

pub export fn string_new_utf8(cstr: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    const s = cstr orelse return null;
    return @ptrCast(@constCast(s));
}

pub export fn string_to_utf8(desc: *const anyopaque) callconv(.c) [*:0]const u8 {
    return @ptrCast(desc);
}
