// ─── Ed Graphics — Zig Unit Tests ───────────────────────────────────────────
//
// Pure-Zig tests for GraphicsState that exercise every drawing primitive,
// palette management, blit operations, command ring, SCREENTITLE payload
// copying, buffer lifecycle (set / clear / set again), and edge-case
// clipping — all without touching ObjC, Metal, GCD, or the JIT.
//
// Each test allocates its own backing buffers with std.testing.allocator
// and wires them into a fresh GraphicsState via the public setBufferPointer /
// setLinePalettePointer / setGlobalPalettePointer / etc. API.  This is
// exactly what the ObjC bridge does with MTLBuffer.contents pointers, so
// any crash or UB here is a real bug in the state machine.

const std = @import("std");
const gfx = @import("ed_graphics.zig");

const GraphicsState = gfx.GraphicsState;
const GfxCommand = gfx.GfxCommand;
const GfxCommandType = gfx.GfxCommandType;
const GfxCommandRing = gfx.GfxCommandRing;
const RGBA32 = gfx.RGBA32;
const LineColours = gfx.LineColours;
const SetTitlePayload = gfx.SetTitlePayload;
const SetScrollPayload = gfx.SetScrollPayload;
const CreateWindowPayload = gfx.CreateWindowPayload;
const PaletteEffect = gfx.PaletteEffect;
const InstallEffectPayload = gfx.InstallEffectPayload;
const NUM_BUFFERS = gfx.NUM_BUFFERS;
const MAX_PALETTE_EFFECTS = gfx.MAX_PALETTE_EFFECTS;
const MAX_COLLISION_SOURCES = gfx.MAX_COLLISION_SOURCES;
const ScreenMode = gfx.ScreenMode;
const CollisionSinglePayload = gfx.CollisionSinglePayload;
const RingBuffer = gfx.RingBuffer;

const testing = std.testing;
const allocator = testing.allocator;

// ═══════════════════════════════════════════════════════════════════════════
// Test Harness — allocate backing memory that mimics MTLBuffer.contents
// ═══════════════════════════════════════════════════════════════════════════

const TestBuffers = struct {
    state: GraphicsState,
    pixel_bufs: [NUM_BUFFERS][]u8,
    line_pal_buf: []LineColours,
    global_pal_buf: *[240]RGBA32,
    effects_buf: *[MAX_PALETTE_EFFECTS]PaletteEffect,
    collision_buf: []u32,

    fn init(w: u16, h: u16) !TestBuffers {
        var self: TestBuffers = undefined;
        self.state = .{};
        self.state.setResolution(w, h);

        const buf_size: usize = @as(usize, self.state.buf_width) * @as(usize, self.state.buf_height);

        // Allocate pixel buffers
        for (0..NUM_BUFFERS) |i| {
            self.pixel_bufs[i] = try allocator.alloc(u8, buf_size);
            @memset(self.pixel_bufs[i], 0);
            self.state.setBufferPointer(@intCast(i), self.pixel_bufs[i].ptr, buf_size);
        }

        // Allocate line palette
        self.line_pal_buf = try allocator.alloc(LineColours, self.state.buf_height);
        @memset(self.line_pal_buf, std.mem.zeroes(LineColours));
        self.state.setLinePalettePointer(self.line_pal_buf.ptr, self.state.buf_height);

        // Allocate global palette
        const gpal_bytes = try allocator.alloc(u8, @sizeOf([240]RGBA32));
        @memset(gpal_bytes, 0);
        self.global_pal_buf = @ptrCast(@alignCast(gpal_bytes.ptr));
        self.state.setGlobalPalettePointer(self.global_pal_buf);

        // Allocate palette effects
        const eff_bytes = try allocator.alloc(u8, @sizeOf([MAX_PALETTE_EFFECTS]PaletteEffect));
        @memset(eff_bytes, 0);
        self.effects_buf = @ptrCast(@alignCast(eff_bytes.ptr));
        self.state.setPaletteEffectsPointer(self.effects_buf);

        // Allocate collision flags
        self.collision_buf = try allocator.alloc(u32, 256);
        @memset(self.collision_buf, 0);
        self.state.setCollisionFlagsPointer(self.collision_buf.ptr);

        self.state.active.store(true, .release);
        self.state.initDefaultPalettes();

        return self;
    }

    fn deinit(self: *TestBuffers) void {
        for (0..NUM_BUFFERS) |i| {
            allocator.free(self.pixel_bufs[i]);
        }
        allocator.free(self.line_pal_buf);
        const gpal_slice: [*]u8 = @ptrCast(self.global_pal_buf);
        allocator.free(gpal_slice[0..@sizeOf([240]RGBA32)]);
        const eff_slice: [*]u8 = @ptrCast(self.effects_buf);
        allocator.free(eff_slice[0..@sizeOf([MAX_PALETTE_EFFECTS]PaletteEffect)]);
        allocator.free(self.collision_buf);
    }

    /// Read a pixel from a specific buffer at logical coordinates.
    fn readPixel(self: *TestBuffers, buf_idx: u3, x: u16, y: u16) u8 {
        const s: usize = self.state.buf_width;
        const off = @as(usize, y) * s + @as(usize, x);
        return self.pixel_bufs[buf_idx][off];
    }

    /// Read a pixel from the current target buffer.
    fn readTarget(self: *TestBuffers, x: u16, y: u16) u8 {
        return self.readPixel(self.state.target, x, y);
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Resolution & Overscan
// ═══════════════════════════════════════════════════════════════════════════

test "calcOverscan — 320x200 gets minimum 32px overscan each side" {
    const ov = GraphicsState.calcOverscan(320, 200);
    // 10% of 320 = 32, 10% of 200 = 20 → clamped to MIN_OVERSCAN/2 = 32
    try testing.expect(ov.ox >= 32);
    try testing.expect(ov.oy >= 32);
    // Overscan must be 16-aligned
    try testing.expectEqual(@as(u16, 0), ov.ox % 16);
    try testing.expectEqual(@as(u16, 0), ov.oy % 16);
    // Buffer dimensions include overscan on both sides
    try testing.expectEqual(320 + ov.ox * 2, ov.bw);
    try testing.expectEqual(200 + ov.oy * 2, ov.bh);
}

test "calcOverscan — 1920x1080 uses 10% overscan" {
    const ov = GraphicsState.calcOverscan(1920, 1080);
    // 10% of 1920 = 192 → round up to 16-aligned = 192
    try testing.expect(ov.ox >= 192);
    try testing.expect(ov.oy >= 108);
    try testing.expectEqual(@as(u16, 0), ov.ox % 16);
    try testing.expectEqual(@as(u16, 0), ov.oy % 16);
}

test "calcOverscan — minimum resolution 160x100" {
    const ov = GraphicsState.calcOverscan(160, 100);
    try testing.expect(ov.bw >= 160);
    try testing.expect(ov.bh >= 100);
}

test "setResolution sets dimensions and resets state" {
    var s: GraphicsState = .{};
    s.setResolution(320, 200);
    try testing.expectEqual(@as(u16, 320), s.width);
    try testing.expectEqual(@as(u16, 200), s.height);
    try testing.expect(s.buf_width > 320);
    try testing.expect(s.buf_height > 200);
    try testing.expectEqual(@as(i16, 0), s.scroll_x);
    try testing.expectEqual(@as(i16, 0), s.scroll_y);
    try testing.expectEqual(@as(u3, 1), s.target);
    try testing.expectEqual(@as(u1, 0), s.front);
}

// ═══════════════════════════════════════════════════════════════════════════
// Buffer Pointer Lifecycle
// ═══════════════════════════════════════════════════════════════════════════

test "clearBufferPointers nulls everything" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    // Verify pointers are non-null after init
    for (0..NUM_BUFFERS) |i| {
        try testing.expect(tb.state.buffers[i] != null);
    }
    try testing.expect(tb.state.line_palette != null);
    try testing.expect(tb.state.global_palette != null);
    try testing.expect(tb.state.palette_effects != null);
    try testing.expect(tb.state.collision_flags != null);

    // Clear
    tb.state.clearBufferPointers();

    for (0..NUM_BUFFERS) |i| {
        try testing.expectEqual(@as(?[]u8, null), tb.state.buffers[i]);
    }
    try testing.expectEqual(@as(?[*]LineColours, null), tb.state.line_palette);
    try testing.expectEqual(@as(u32, 0), tb.state.line_palette_len);
    try testing.expectEqual(@as(?*[240]RGBA32, null), tb.state.global_palette);
    try testing.expectEqual(@as(?*[MAX_PALETTE_EFFECTS]PaletteEffect, null), tb.state.palette_effects);
    try testing.expectEqual(@as(?[*]u32, null), tb.state.collision_flags);
}

test "drawing after clearBufferPointers does not crash (null guard)" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.clearBufferPointers();

    // All these should silently return (orelse return paths)
    tb.state.pset(10, 10, 5);
    try testing.expectEqual(@as(u8, 0), tb.state.pget(10, 10));
    tb.state.clear(7);
    tb.state.line(0, 0, 100, 100, 3);
    tb.state.rect(0, 0, 50, 50, 4, false);
    tb.state.circle(50, 50, 10, 5, false);
    tb.state.ellipse(50, 50, 20, 10, 6, false);
    tb.state.triangle(10, 10, 50, 50, 90, 10, 7, false);
    tb.state.drawText(0, 0, "Hello", 1, 0);
    tb.state.blit(0, 0, 0, 1, 0, 0, 10, 10);
    tb.state.blitSolid(0, 0, 0, 1, 0, 0, 10, 10);
}

test "re-set buffer pointers after clear (simulates window re-open)" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    // Draw a pixel
    tb.state.pset(10, 10, 42);
    try testing.expectEqual(@as(u8, 42), tb.state.pget(10, 10));

    // Simulate window close
    tb.state.clearBufferPointers();
    try testing.expectEqual(@as(u8, 0), tb.state.pget(10, 10));

    // Simulate window re-open: re-point to same backing memory
    const buf_size: usize = @as(usize, tb.state.buf_width) * @as(usize, tb.state.buf_height);
    for (0..NUM_BUFFERS) |i| {
        @memset(tb.pixel_bufs[i], 0); // Fresh buffers
        tb.state.setBufferPointer(@intCast(i), tb.pixel_bufs[i].ptr, buf_size);
    }
    tb.state.setLinePalettePointer(tb.line_pal_buf.ptr, tb.state.buf_height);
    tb.state.setGlobalPalettePointer(tb.global_pal_buf);
    tb.state.setPaletteEffectsPointer(tb.effects_buf);
    tb.state.setCollisionFlagsPointer(tb.collision_buf.ptr);

    // Drawing should work again
    tb.state.pset(10, 10, 99);
    try testing.expectEqual(@as(u8, 99), tb.state.pget(10, 10));
}

// ═══════════════════════════════════════════════════════════════════════════
// PSET / PGET
// ═══════════════════════════════════════════════════════════════════════════

test "pset and pget basic" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.pset(0, 0, 1);
    try testing.expectEqual(@as(u8, 1), tb.state.pget(0, 0));

    tb.state.pset(100, 50, 255);
    try testing.expectEqual(@as(u8, 255), tb.state.pget(100, 50));

    // Overwrite
    tb.state.pset(100, 50, 42);
    try testing.expectEqual(@as(u8, 42), tb.state.pget(100, 50));
}

test "pset clipping — negative coords" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    // These must not crash (out-of-bounds → silently ignored)
    tb.state.pset(-1, 0, 1);
    tb.state.pset(0, -1, 1);
    tb.state.pset(-100, -100, 1);
}

test "pset clipping — beyond buffer dimensions" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    // buf_width/buf_height include overscan, but coords beyond buf dims
    // should still be rejected
    const bw: i32 = @intCast(tb.state.buf_width);
    const bh: i32 = @intCast(tb.state.buf_height);

    tb.state.pset(bw, 0, 1); // one past right edge
    tb.state.pset(0, bh, 1); // one past bottom edge
    tb.state.pset(bw + 100, bh + 100, 1);
    tb.state.pset(32767, 32767, 1);

    // pget out of bounds returns 0
    try testing.expectEqual(@as(u8, 0), tb.state.pget(-1, 0));
    try testing.expectEqual(@as(u8, 0), tb.state.pget(0, -1));
    try testing.expectEqual(@as(u8, 0), tb.state.pget(bw, 0));
    try testing.expectEqual(@as(u8, 0), tb.state.pget(0, bh));
}

test "pset writes to correct target buffer" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    // Default target is 1
    try testing.expectEqual(@as(u3, 1), tb.state.target);
    tb.state.pset(5, 5, 42);

    // Should be in buffer 1
    try testing.expectEqual(@as(u8, 42), tb.readPixel(1, 5, 5));
    // Should NOT be in buffer 0
    try testing.expectEqual(@as(u8, 0), tb.readPixel(0, 5, 5));

    // Switch target
    tb.state.target = 4;
    tb.state.pset(5, 5, 99);
    try testing.expectEqual(@as(u8, 99), tb.readPixel(4, 5, 5));
    // Buffer 1 unchanged
    try testing.expectEqual(@as(u8, 42), tb.readPixel(1, 5, 5));
}

// ═══════════════════════════════════════════════════════════════════════════
// GCLS (clear)
// ═══════════════════════════════════════════════════════════════════════════

test "clear fills target buffer" {
    var tb = try TestBuffers.init(160, 100);
    defer tb.deinit();

    tb.state.clear(17);

    // Check a few spots
    try testing.expectEqual(@as(u8, 17), tb.state.pget(0, 0));
    try testing.expectEqual(@as(u8, 17), tb.state.pget(50, 50));
    try testing.expectEqual(@as(u8, 17), tb.state.pget(159, 99));

    // Other buffers untouched
    try testing.expectEqual(@as(u8, 0), tb.readPixel(0, 50, 50));
}

// ═══════════════════════════════════════════════════════════════════════════
// LINE
// ═══════════════════════════════════════════════════════════════════════════

test "line — horizontal" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.line(10, 50, 20, 50, 3);

    // All pixels on the line should be colour 3
    var x: i32 = 10;
    while (x <= 20) : (x += 1) {
        try testing.expectEqual(@as(u8, 3), tb.state.pget(x, 50));
    }
    // Pixel before and after should be 0
    try testing.expectEqual(@as(u8, 0), tb.state.pget(9, 50));
    try testing.expectEqual(@as(u8, 0), tb.state.pget(21, 50));
}

test "line — vertical" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.line(50, 10, 50, 20, 7);

    var y: i32 = 10;
    while (y <= 20) : (y += 1) {
        try testing.expectEqual(@as(u8, 7), tb.state.pget(50, y));
    }
}

test "line — diagonal" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.line(0, 0, 10, 10, 5);

    // Bresenham diagonal: all (i, i) for i in 0..10 should be set
    var i: i32 = 0;
    while (i <= 10) : (i += 1) {
        try testing.expectEqual(@as(u8, 5), tb.state.pget(i, i));
    }
}

test "line — clipping to buffer bounds" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    // Line that extends outside the buffer — should not crash
    tb.state.line(-50, -50, 500, 500, 2);
    tb.state.line(500, 0, -500, 199, 2);

    // Just verify we survived
    try testing.expect(true);
}

test "line — single point" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.line(50, 50, 50, 50, 9);
    try testing.expectEqual(@as(u8, 9), tb.state.pget(50, 50));
}

// ═══════════════════════════════════════════════════════════════════════════
// RECT
// ═══════════════════════════════════════════════════════════════════════════

test "rect — outlined" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.rect(10, 10, 20, 20, 4, false);

    // Corners
    try testing.expectEqual(@as(u8, 4), tb.state.pget(10, 10));
    try testing.expectEqual(@as(u8, 4), tb.state.pget(20, 10));
    try testing.expectEqual(@as(u8, 4), tb.state.pget(10, 20));
    try testing.expectEqual(@as(u8, 4), tb.state.pget(20, 20));

    // Top edge mid
    try testing.expectEqual(@as(u8, 4), tb.state.pget(15, 10));
    // Interior should be empty
    try testing.expectEqual(@as(u8, 0), tb.state.pget(15, 15));
}

test "rect — filled" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.rect(10, 10, 20, 20, 6, true);

    // Interior should be filled
    try testing.expectEqual(@as(u8, 6), tb.state.pget(15, 15));
    try testing.expectEqual(@as(u8, 6), tb.state.pget(10, 10));
    try testing.expectEqual(@as(u8, 6), tb.state.pget(20, 20));

    // Just outside should be empty
    try testing.expectEqual(@as(u8, 0), tb.state.pget(9, 10));
    try testing.expectEqual(@as(u8, 0), tb.state.pget(21, 10));
}

test "rect — clipping" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    // Partially out of bounds
    tb.state.rect(-5, -5, 5, 5, 3, true);
    // In-bounds portion should be filled
    try testing.expectEqual(@as(u8, 3), tb.state.pget(0, 0));
    try testing.expectEqual(@as(u8, 3), tb.state.pget(5, 5));

    // Fully out of bounds
    tb.state.rect(-100, -100, -50, -50, 3, true);
}

// ═══════════════════════════════════════════════════════════════════════════
// CIRCLE
// ═══════════════════════════════════════════════════════════════════════════

test "circle — small outlined" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.circle(50, 50, 5, 8, false);

    // Points on the circle (midpoint algorithm)
    // Top: (50, 45)
    try testing.expectEqual(@as(u8, 8), tb.state.pget(50, 45));
    // Bottom: (50, 55)
    try testing.expectEqual(@as(u8, 8), tb.state.pget(50, 55));
    // Left: (45, 50)
    try testing.expectEqual(@as(u8, 8), tb.state.pget(45, 50));
    // Right: (55, 50)
    try testing.expectEqual(@as(u8, 8), tb.state.pget(55, 50));

    // Centre should be empty
    try testing.expectEqual(@as(u8, 0), tb.state.pget(50, 50));
}

test "circle — filled" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.circle(50, 50, 10, 3, true);

    // Centre should be filled
    try testing.expectEqual(@as(u8, 3), tb.state.pget(50, 50));
    // Edges should be filled
    try testing.expectEqual(@as(u8, 3), tb.state.pget(50, 40));
    try testing.expectEqual(@as(u8, 3), tb.state.pget(50, 60));
    // Well outside should be empty
    try testing.expectEqual(@as(u8, 0), tb.state.pget(50, 38));
}

test "circle — zero radius is a point" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.circle(50, 50, 0, 15, false);
    try testing.expectEqual(@as(u8, 15), tb.state.pget(50, 50));
}

test "circle — clipping near edges" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    // Circle at edge — should not crash
    tb.state.circle(0, 0, 20, 5, true);
    tb.state.circle(319, 199, 20, 5, true);
    tb.state.circle(-10, -10, 5, 5, false);
}

// ═══════════════════════════════════════════════════════════════════════════
// ELLIPSE
// ═══════════════════════════════════════════════════════════════════════════

test "ellipse — outlined" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.ellipse(100, 100, 20, 10, 4, false);

    // Top/bottom of ellipse
    try testing.expectEqual(@as(u8, 4), tb.state.pget(100, 90));
    try testing.expectEqual(@as(u8, 4), tb.state.pget(100, 110));
    // Left/right
    try testing.expectEqual(@as(u8, 4), tb.state.pget(80, 100));
    try testing.expectEqual(@as(u8, 4), tb.state.pget(120, 100));
}

test "ellipse — clipping" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.ellipse(-10, 100, 30, 20, 2, true);
    tb.state.ellipse(300, 190, 30, 20, 2, false);
}

// ═══════════════════════════════════════════════════════════════════════════
// TRIANGLE
// ═══════════════════════════════════════════════════════════════════════════

test "triangle — outlined" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.triangle(50, 10, 10, 90, 90, 90, 5, false);

    // Vertices should be set
    try testing.expectEqual(@as(u8, 5), tb.state.pget(50, 10));
    try testing.expectEqual(@as(u8, 5), tb.state.pget(10, 90));
    try testing.expectEqual(@as(u8, 5), tb.state.pget(90, 90));
}

test "triangle — filled" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.triangle(50, 10, 10, 90, 90, 90, 7, true);

    // Centre of triangle should be filled
    try testing.expectEqual(@as(u8, 7), tb.state.pget(50, 60));
    // Bottom edge should be filled
    try testing.expectEqual(@as(u8, 7), tb.state.pget(50, 90));
}

test "triangle — degenerate horizontal line" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.triangle(10, 50, 50, 50, 90, 50, 3, true);
    // Should draw a horizontal line
    try testing.expectEqual(@as(u8, 3), tb.state.pget(10, 50));
    try testing.expectEqual(@as(u8, 3), tb.state.pget(50, 50));
    try testing.expectEqual(@as(u8, 3), tb.state.pget(90, 50));
}

// ═══════════════════════════════════════════════════════════════════════════
// BLIT / BLITSOLID
// ═══════════════════════════════════════════════════════════════════════════

test "blitSolid — copy entire buffer" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    // Draw something into buffer 4
    tb.state.target = 4;
    tb.state.clear(16);
    tb.state.pset(10, 10, 42);

    // Copy buffer 4 into target (buffer 1)
    tb.state.target = 1;
    const bw: i32 = @intCast(tb.state.buf_width);
    const bh: i32 = @intCast(tb.state.buf_height);
    tb.state.blitSolid(1, 0, 0, 4, 0, 0, bw, bh);

    // Target should now have buffer 4's content
    try testing.expectEqual(@as(u8, 16), tb.readPixel(1, 0, 0));
    try testing.expectEqual(@as(u8, 42), tb.readPixel(1, 10, 10));
}

test "blitSolid — copy sub-region" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    // Fill buffer 4 with colour 5
    tb.state.target = 4;
    tb.state.clear(5);

    // Copy a 10x10 region from buffer 4 to buffer 1 at offset (20, 20)
    tb.state.target = 1;
    tb.state.blitSolid(1, 20, 20, 4, 0, 0, 10, 10);

    // Region should be filled
    try testing.expectEqual(@as(u8, 5), tb.readPixel(1, 20, 20));
    try testing.expectEqual(@as(u8, 5), tb.readPixel(1, 29, 29));
    // Just outside should be empty
    try testing.expectEqual(@as(u8, 0), tb.readPixel(1, 19, 20));
    try testing.expectEqual(@as(u8, 0), tb.readPixel(1, 30, 20));
}

test "blit — transparent copy (colour 0 is transparent)" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    // Fill target with colour 10 (background)
    tb.state.target = 1;
    tb.state.clear(10);

    // Buffer 2: some pixels with colour, some with 0 (transparent)
    tb.state.target = 2;
    tb.state.clear(0);
    tb.state.pset(5, 5, 20); // non-transparent

    // Blit buffer 2 onto buffer 1 — only non-zero pixels should copy
    tb.state.target = 1;
    tb.state.blit(1, 0, 0, 2, 0, 0, 10, 10);

    // (5,5) should have colour 20 (from buffer 2)
    try testing.expectEqual(@as(u8, 20), tb.readPixel(1, 5, 5));
    // (0,0) should still have colour 10 (background, because buffer 2 had 0 there)
    try testing.expectEqual(@as(u8, 10), tb.readPixel(1, 0, 0));
}

test "blit — clipping when source/dest extend beyond buffer" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    // Source buffer
    tb.state.target = 3;
    tb.state.clear(7);

    // Blit with negative offsets and huge dimensions — should not crash
    tb.state.target = 1;
    tb.state.blit(1, -5, -5, 3, -5, -5, 500, 500);
    tb.state.blitSolid(1, -5, -5, 3, -5, -5, 500, 500);
}

test "blit — null source buffer does not crash" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.clearBufferPointers();
    tb.state.blit(0, 0, 0, 1, 0, 0, 10, 10);
    tb.state.blitSolid(0, 0, 0, 1, 0, 0, 10, 10);
}

// ═══════════════════════════════════════════════════════════════════════════
// DRAWTEXT
// ═══════════════════════════════════════════════════════════════════════════

test "drawText — renders pixels" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.drawText(0, 0, "A", 15, 0);

    // The letter 'A' in the CP437 8x8 font should set some pixels
    // in the first 8x8 area. We can't check the exact pattern without
    // knowing the font data, but we can verify that *some* pixel was
    // written.
    var found: bool = false;
    var y: u16 = 0;
    while (y < 8) : (y += 1) {
        var x: u16 = 0;
        while (x < 8) : (x += 1) {
            if (tb.readTarget(x, y) == 15) {
                found = true;
                break;
            }
        }
        if (found) break;
    }
    try testing.expect(found);
}

test "drawText — empty string is a no-op" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.drawText(0, 0, "", 15, 0);
    // Buffer should still be all zeros
    try testing.expectEqual(@as(u8, 0), tb.state.pget(0, 0));
}

test "drawText — off-screen does not crash" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.drawText(-100, -100, "Hello World", 5, 0);
    tb.state.drawText(500, 500, "Hello World", 5, 0);
    tb.state.drawText(0, 0, "This is a very long string that might exceed the buffer width if it were ever that long but we just want to test clipping", 5, 0);
}

test "textWidth and textHeight" {
    try testing.expectEqual(@as(u32, 40), GraphicsState.textWidth("Hello"));
    try testing.expectEqual(@as(u32, 0), GraphicsState.textWidth(""));
    try testing.expect(GraphicsState.textHeight(0) > 0);
    try testing.expect(GraphicsState.textHeight(1) > 0);
    try testing.expect(GraphicsState.textHeight(1) > GraphicsState.textHeight(0));
}

// ═══════════════════════════════════════════════════════════════════════════
// FLIP
// ═══════════════════════════════════════════════════════════════════════════

test "flip swaps front and target buffers" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    try testing.expectEqual(@as(u1, 0), tb.state.front);
    try testing.expectEqual(@as(u3, 1), tb.state.target);

    tb.state.flip();
    try testing.expectEqual(@as(u1, 1), tb.state.front);
    try testing.expectEqual(@as(u3, 0), tb.state.target);

    tb.state.flip();
    try testing.expectEqual(@as(u1, 0), tb.state.front);
    try testing.expectEqual(@as(u3, 1), tb.state.target);
}

// ═══════════════════════════════════════════════════════════════════════════
// Palette Management
// ═══════════════════════════════════════════════════════════════════════════

test "initDefaultPalettes sets non-zero data" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    // Line palette: index 2 (white) should be (255, 255, 255, 255)
    const lp = tb.state.line_palette.?;
    const row0 = lp[0];
    try testing.expectEqual(@as(u8, 255), row0[2].r);
    try testing.expectEqual(@as(u8, 255), row0[2].g);
    try testing.expectEqual(@as(u8, 255), row0[2].b);

    // Index 0 should be transparent
    try testing.expectEqual(@as(u8, 0), row0[0].a);

    // Index 1 should be black (opaque)
    try testing.expectEqual(@as(u8, 0), row0[1].r);
    try testing.expectEqual(@as(u8, 0), row0[1].g);
    try testing.expectEqual(@as(u8, 0), row0[1].b);
    try testing.expectEqual(@as(u8, 255), row0[1].a);
}

test "setPalette — global palette entries" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    // Set palette index 16 (first global entry)
    tb.state.setPalette(16, 12, 34, 56);

    const gpal = tb.state.global_palette.?;
    try testing.expectEqual(@as(u8, 12), gpal[0].r);
    try testing.expectEqual(@as(u8, 34), gpal[0].g);
    try testing.expectEqual(@as(u8, 56), gpal[0].b);

    // Set palette index 255 (last global entry → index 239)
    tb.state.setPalette(255, 100, 200, 50);
    try testing.expectEqual(@as(u8, 100), gpal[239].r);
    try testing.expectEqual(@as(u8, 200), gpal[239].g);
    try testing.expectEqual(@as(u8, 50), gpal[239].b);
}

test "setPalette — indices below 16 are ignored" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    // These should be no-ops (per-line palette, not settable via setPalette)
    tb.state.setPalette(0, 255, 255, 255);
    tb.state.setPalette(1, 255, 255, 255);
    tb.state.setPalette(15, 255, 255, 255);
}

test "setPalette — null global palette does not crash" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.global_palette = null;
    tb.state.setPalette(16, 1, 2, 3);
}

test "setLinePalette — per-line colours" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.setLinePalette(0, 3, 128, 64, 32);
    const lp = tb.state.line_palette.?;
    try testing.expectEqual(@as(u8, 128), lp[0][3].r);
    try testing.expectEqual(@as(u8, 64), lp[0][3].g);
    try testing.expectEqual(@as(u8, 32), lp[0][3].b);
}

test "getPalette returns correct values" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.setPalette(20, 11, 22, 33);
    const c = RGBA32.unpack(tb.state.getPalette(20));
    try testing.expectEqual(@as(u8, 11), c.r);
    try testing.expectEqual(@as(u8, 22), c.g);
    try testing.expectEqual(@as(u8, 33), c.b);
}

test "resetPalette restores defaults" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    // Change a palette entry
    tb.state.setPalette(16, 0, 0, 0);

    // Reset
    tb.state.resetPalette();

    // Should be back to the default 6×6×6 cube value
    // Index 16 → gpal[0] → first entry of colour cube (0,0,0) → black
    // Actually index 16 in the 6×6×6 cube = R=0, G=2, B=4 → (0, 102, 204)
    // Let's just verify it's not (0,0,0) anymore... wait, (0,0,0) IS the first cube entry.
    // Let's check index 17 instead, which should be (0, 0, 51)
    tb.state.setPalette(17, 255, 255, 255);
    tb.state.resetPalette();
    const c = RGBA32.unpack(tb.state.getPalette(17));
    try testing.expectEqual(@as(u8, 0), c.r);
    try testing.expectEqual(@as(u8, 0), c.g);
    try testing.expectEqual(@as(u8, 51), c.b);
}

// ═══════════════════════════════════════════════════════════════════════════
// Palette Effects
// ═══════════════════════════════════════════════════════════════════════════

test "installEffect enqueues install_effect command" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    var effect = PaletteEffect.empty();
    effect.effect_type = @intFromEnum(gfx.PaletteEffectType.cycle);
    effect.flags = gfx.EFFECT_FLAG_ACTIVE;
    effect.index_start = 16;
    effect.index_end = 31;
    effect.speed = 1.0;

    tb.state.installEffect(0, effect);

    // The command should be in the ring, not directly in the effects buffer
    const cmd = tb.state.command_ring.dequeue().?;
    try testing.expectEqual(GfxCommandType.install_effect, cmd.cmd_type);

    // Decode payload
    var payload: InstallEffectPayload = undefined;
    @memcpy(std.mem.asBytes(&payload), cmd.payload[0..@sizeOf(InstallEffectPayload)]);
    try testing.expectEqual(@as(u8, 0), payload.slot);
    try testing.expectEqual(@intFromEnum(gfx.PaletteEffectType.cycle), payload.effect.effect_type);
    try testing.expectEqual(gfx.EFFECT_FLAG_ACTIVE, payload.effect.flags);
    try testing.expectEqual(@as(u32, 16), payload.effect.index_start);
    try testing.expectEqual(@as(u32, 31), payload.effect.index_end);
}

test "stopEffect enqueues stop_effect command" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.stopEffect(3);

    const cmd = tb.state.command_ring.dequeue().?;
    try testing.expectEqual(GfxCommandType.stop_effect, cmd.cmd_type);
    try testing.expectEqual(@as(u8, 3), cmd.payload[0]);
}

test "stopAllEffects enqueues stop_all_effects command" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.stopAllEffects();

    const cmd = tb.state.command_ring.dequeue().?;
    try testing.expectEqual(GfxCommandType.stop_all_effects, cmd.cmd_type);
}

// ═══════════════════════════════════════════════════════════════════════════
// Command Ring
// ═══════════════════════════════════════════════════════════════════════════

test "GfxCommandRing — enqueue and dequeue" {
    var ring = GfxCommandRing.init();
    try testing.expect(ring.isEmpty());

    var cmd = GfxCommand.init(.flip);
    cmd.fence_id = 42;
    try testing.expect(ring.enqueue(cmd));

    try testing.expect(!ring.isEmpty());

    const dequeued = ring.dequeue().?;
    try testing.expectEqual(GfxCommandType.flip, dequeued.cmd_type);
    try testing.expectEqual(@as(u32, 42), dequeued.fence_id);

    try testing.expect(ring.isEmpty());
    try testing.expectEqual(@as(?GfxCommand, null), ring.dequeue());
}

test "GfxCommandRing — FIFO ordering" {
    var ring = GfxCommandRing.init();

    // Enqueue 3 commands
    var c1 = GfxCommand.init(.flip);
    c1.fence_id = 1;
    var c2 = GfxCommand.init(.set_scroll);
    c2.fence_id = 2;
    var c3 = GfxCommand.init(.commit_fence);
    c3.fence_id = 3;

    try testing.expect(ring.enqueue(c1));
    try testing.expect(ring.enqueue(c2));
    try testing.expect(ring.enqueue(c3));

    // Dequeue in order
    try testing.expectEqual(GfxCommandType.flip, ring.dequeue().?.cmd_type);
    try testing.expectEqual(GfxCommandType.set_scroll, ring.dequeue().?.cmd_type);
    try testing.expectEqual(GfxCommandType.commit_fence, ring.dequeue().?.cmd_type);
    try testing.expectEqual(@as(?GfxCommand, null), ring.dequeue());
}

test "GfxCommandRing — full ring returns false" {
    var ring = GfxCommandRing.init();

    // Fill the ring (capacity is GFX_COMMAND_RING_SIZE - 1)
    var i: u32 = 0;
    while (i < gfx.GFX_COMMAND_RING_SIZE - 1) : (i += 1) {
        var cmd = GfxCommand.init(.flip);
        cmd.fence_id = i;
        try testing.expect(ring.enqueue(cmd));
    }

    // One more should fail
    try testing.expect(!ring.enqueue(GfxCommand.init(.flip)));

    // Dequeue one, then enqueue should succeed again
    _ = ring.dequeue();
    try testing.expect(ring.enqueue(GfxCommand.init(.flip)));
}

// ═══════════════════════════════════════════════════════════════════════════
// SCREENTITLE — Command Payload Copying
// ═══════════════════════════════════════════════════════════════════════════

/// Decode a SetTitlePayload from a raw command payload byte array,
/// avoiding alignment issues with @ptrCast on [56]u8.
fn decodeSetTitlePayload(raw: *const [56]u8) SetTitlePayload {
    var payload: SetTitlePayload = undefined;
    @memcpy(std.mem.asBytes(&payload), raw[0..@sizeOf(SetTitlePayload)]);
    return payload;
}

test "screenTitle — short string copied inline" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    const title = "Hello World";
    tb.state.screenTitle(title.ptr, @intCast(title.len));

    // Dequeue the command
    const cmd = tb.state.command_ring.dequeue().?;
    try testing.expectEqual(GfxCommandType.set_title, cmd.cmd_type);

    // Verify payload
    const payload = decodeSetTitlePayload(&cmd.payload);
    try testing.expectEqual(@as(u32, @intCast(title.len)), payload.len);
    try testing.expect(std.mem.eql(u8, title, payload.data[0..title.len]));
}

test "screenTitle — UTF-8 em dash copied correctly" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    const title = "Test 06 \xe2\x80\x94 Frame Loop"; // "Test 06 — Frame Loop"
    tb.state.screenTitle(title.ptr, @intCast(title.len));

    const cmd = tb.state.command_ring.dequeue().?;
    const payload = decodeSetTitlePayload(&cmd.payload);
    try testing.expectEqual(@as(u32, @intCast(title.len)), payload.len);
    try testing.expect(std.mem.eql(u8, title, payload.data[0..title.len]));
}

test "screenTitle — max length (52 bytes) works" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    const title = "ABCDEFGHIJKLMNOPQRSTUVWXYZ" ++ "abcdefghijklmnopqrstuvwxyz"; // 52 bytes
    try testing.expectEqual(@as(usize, 52), title.len);
    tb.state.screenTitle(title.ptr, @intCast(title.len));

    const cmd = tb.state.command_ring.dequeue().?;
    const payload = decodeSetTitlePayload(&cmd.payload);
    try testing.expectEqual(@as(u32, 52), payload.len);
    try testing.expect(std.mem.eql(u8, title, payload.data[0..52]));
}

test "screenTitle — truncates to 52 bytes" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    const title = "This is a very long title string that exceeds the 52 byte maximum and should be truncated";
    try testing.expect(title.len > 52);
    tb.state.screenTitle(title.ptr, @intCast(title.len));

    const cmd = tb.state.command_ring.dequeue().?;
    const payload = decodeSetTitlePayload(&cmd.payload);
    try testing.expectEqual(@as(u32, 52), payload.len);
    try testing.expect(std.mem.eql(u8, title[0..52], payload.data[0..52]));
}

test "screenTitle — payload is a deep copy (source can be freed)" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    // Allocate a string on the heap, copy into it, then free it
    const buf = try allocator.alloc(u8, 16);
    @memcpy(buf, "Dynamic Title!!!");
    tb.state.screenTitle(buf.ptr, @intCast(buf.len));
    allocator.free(buf);

    // The command should still contain the correct data
    const cmd = tb.state.command_ring.dequeue().?;
    const payload = decodeSetTitlePayload(&cmd.payload);
    try testing.expectEqual(@as(u32, 16), payload.len);
    try testing.expect(std.mem.eql(u8, "Dynamic Title!!!", payload.data[0..16]));
}

// ═══════════════════════════════════════════════════════════════════════════
// SETSCROLL — Command Payload
// ═══════════════════════════════════════════════════════════════════════════

test "setScroll enqueues command with correct payload" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.setScroll(42, -10);

    try testing.expectEqual(@as(i16, 42), tb.state.scroll_x);
    try testing.expectEqual(@as(i16, -10), tb.state.scroll_y);

    const cmd = tb.state.command_ring.dequeue().?;
    try testing.expectEqual(GfxCommandType.set_scroll, cmd.cmd_type);

    var payload: SetScrollPayload = undefined;
    @memcpy(std.mem.asBytes(&payload), cmd.payload[0..@sizeOf(SetScrollPayload)]);
    try testing.expectEqual(@as(i16, 42), payload.scroll_x);
    try testing.expectEqual(@as(i16, -10), payload.scroll_y);
}

// ═══════════════════════════════════════════════════════════════════════════
// SCREENMODE
// ═══════════════════════════════════════════════════════════════════════════

test "screenModeSet changes mode and enqueues command" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.screenModeSet(.crt);
    try testing.expectEqual(ScreenMode.crt, tb.state.screen_mode);

    const cmd = tb.state.command_ring.dequeue().?;
    try testing.expectEqual(GfxCommandType.set_screen_mode, cmd.cmd_type);
    try testing.expectEqual(@as(u8, @intFromEnum(ScreenMode.crt)), cmd.payload[0]);
}

test "screenModeSet square disables PAR" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.screenModeSet(.square);
    try testing.expectEqual(@as(u16, 1), tb.state.par_numerator);
    try testing.expectEqual(@as(u16, 1), tb.state.par_denominator);
}

// ═══════════════════════════════════════════════════════════════════════════
// Input State (atomics — verify read helpers)
// ═══════════════════════════════════════════════════════════════════════════

test "keyDown reads atomic key state" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    try testing.expect(!tb.state.keyDown(53));

    tb.state.key_state[53].store(1, .release);
    try testing.expect(tb.state.keyDown(53));

    tb.state.key_state[53].store(0, .release);
    try testing.expect(!tb.state.keyDown(53));
}

test "mouse state" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.mouse_x.store(100, .release);
    tb.state.mouse_y.store(50, .release);
    tb.state.mouse_buttons.store(1, .release);
    tb.state.mouse_scroll.store(3, .release);

    try testing.expectEqual(@as(i16, 100), tb.state.mouseX());
    try testing.expectEqual(@as(i16, 50), tb.state.mouseY());
    try testing.expectEqual(@as(u8, 1), tb.state.mouseButton());
    try testing.expectEqual(@as(i16, 3), tb.state.mouseScroll());
}

// ═══════════════════════════════════════════════════════════════════════════
// Accessor helpers
// ═══════════════════════════════════════════════════════════════════════════

test "screenWidth and screenHeight" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    try testing.expectEqual(@as(u16, 320), tb.state.screenWidth());
    try testing.expectEqual(@as(u16, 200), tb.state.screenHeight());
}

test "bufferWidth and bufferHeight include overscan" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    try testing.expect(tb.state.bufferWidth() > 320);
    try testing.expect(tb.state.bufferHeight() > 200);
}

test "isActive reflects atomic flag" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    try testing.expect(tb.state.isActive());
    tb.state.active.store(false, .release);
    try testing.expect(!tb.state.isActive());
}

test "frontBuffer returns current front" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    try testing.expectEqual(@as(u1, 0), tb.state.frontBuffer());
    tb.state.flip();
    try testing.expectEqual(@as(u1, 1), tb.state.frontBuffer());
}

// ═══════════════════════════════════════════════════════════════════════════
// Commit / Fence
// ═══════════════════════════════════════════════════════════════════════════

test "commit enqueues fence command with incrementing IDs" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    const f1 = tb.state.commit();
    const f2 = tb.state.commit();

    try testing.expect(f2 > f1);

    const c1 = tb.state.command_ring.dequeue().?;
    try testing.expectEqual(GfxCommandType.commit_fence, c1.cmd_type);
    try testing.expectEqual(f1, c1.fence_id);

    const c2 = tb.state.command_ring.dequeue().?;
    try testing.expectEqual(GfxCommandType.commit_fence, c2.cmd_type);
    try testing.expectEqual(f2, c2.fence_id);
}

test "fenceDone reflects completed fence" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    const f1 = tb.state.commit();
    try testing.expect(!tb.state.fenceDone(f1));

    // Simulate GPU completion
    tb.state.last_completed_fence.store(f1, .release);
    try testing.expect(tb.state.fenceDone(f1));
}

// ═══════════════════════════════════════════════════════════════════════════
// Collision Setup
// ═══════════════════════════════════════════════════════════════════════════

test "collideSetup sets collision count" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.collideSetup(4);
    try testing.expectEqual(@as(u8, 4), tb.state.collision_count);

    tb.state.collideSetup(0);
    try testing.expectEqual(@as(u8, 0), tb.state.collision_count);
}

test "collideSrc adds collision sources" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.collideSetup(2);
    tb.state.collideSrc(0, 0, 10, 20, 32, 32);
    try testing.expectEqual(@as(i16, 10), tb.state.collision_sources[0].x);
    try testing.expectEqual(@as(i16, 20), tb.state.collision_sources[0].y);
}

// ═══════════════════════════════════════════════════════════════════════════
// RGBA32
// ═══════════════════════════════════════════════════════════════════════════

test "RGBA32 init" {
    const c = RGBA32.init(10, 20, 30);
    try testing.expectEqual(@as(u8, 10), c.r);
    try testing.expectEqual(@as(u8, 20), c.g);
    try testing.expectEqual(@as(u8, 30), c.b);
    try testing.expectEqual(@as(u8, 255), c.a);
}

test "RGBA32 pack and unpack" {
    const c = RGBA32.init(0xAA, 0xBB, 0xCC);
    const packed_val = c.pack();
    const unpacked = RGBA32.unpack(packed_val);

    try testing.expectEqual(c.r, unpacked.r);
    try testing.expectEqual(c.g, unpacked.g);
    try testing.expectEqual(c.b, unpacked.b);
    try testing.expectEqual(c.a, unpacked.a);
}

test "RGBA32 constants" {
    try testing.expectEqual(@as(u8, 0), RGBA32.TRANSPARENT.a);
    try testing.expectEqual(@as(u8, 0), RGBA32.BLACK.r);
    try testing.expectEqual(@as(u8, 255), RGBA32.BLACK.a);
    try testing.expectEqual(@as(u8, 255), RGBA32.WHITE.r);
    try testing.expectEqual(@as(u8, 255), RGBA32.WHITE.g);
    try testing.expectEqual(@as(u8, 255), RGBA32.WHITE.b);
}

// ═══════════════════════════════════════════════════════════════════════════
// Scroll Buffer
// ═══════════════════════════════════════════════════════════════════════════

test "scrollBuffer — horizontal scroll" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    // Draw a vertical line at x=10
    var y: i32 = 0;
    while (y < 200) : (y += 1) {
        tb.state.pset(10, y, 5);
    }

    // Scroll right by 5 pixels
    tb.state.scrollBuffer(5, 0, 0);

    // The line should now be at x=15
    try testing.expectEqual(@as(u8, 5), tb.state.pget(15, 100));
    // x=10 should be cleared (filled with colour 0)
    try testing.expectEqual(@as(u8, 0), tb.state.pget(10, 100));
}

test "scrollBuffer — vertical scroll" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    // Draw a horizontal line at y=10
    var x: i32 = 0;
    while (x < 320) : (x += 1) {
        tb.state.pset(x, 10, 7);
    }

    // Scroll down by 5 pixels
    tb.state.scrollBuffer(0, 5, 0);

    // The line should now be at y=15
    try testing.expectEqual(@as(u8, 7), tb.state.pget(100, 15));
    // y=10 should be cleared
    try testing.expectEqual(@as(u8, 0), tb.state.pget(100, 10));
}

// ═══════════════════════════════════════════════════════════════════════════
// Full Lifecycle Simulation (mimics what 06_frame_loop.bas does)
// ═══════════════════════════════════════════════════════════════════════════

test "full lifecycle — open, draw, flip, draw, close, reopen" {
    // === Phase 1: First "SCREEN" ===
    var tb = try TestBuffers.init(320, 200);

    // SCREENTITLE
    tb.state.screenTitle("Test 06", 7);
    const title_cmd = tb.state.command_ring.dequeue().?;
    try testing.expectEqual(GfxCommandType.set_title, title_cmd.cmd_type);

    // PALETTE 16, 12, 12, 30
    tb.state.setPalette(16, 12, 12, 30);
    // PALETTE 17, 255, 200, 60
    tb.state.setPalette(17, 255, 200, 60);

    // SETTARGET 4; GCLS 16
    tb.state.target = 4;
    tb.state.clear(16);
    try testing.expectEqual(@as(u8, 16), tb.readPixel(4, 50, 50));

    // Draw starfield dots
    tb.state.pset(100, 50, 21);
    tb.state.pset(200, 100, 22);
    try testing.expectEqual(@as(u8, 21), tb.readPixel(4, 100, 50));

    // Switch back to target buffer 1
    tb.state.target = 1;

    // Simulate a few frames
    var frame: u32 = 0;
    while (frame < 10) : (frame += 1) {
        // BLITSOLID 4 → target
        tb.state.blitSolid(tb.state.target, 0, 0, 4, 0, 0, @intCast(tb.state.buf_width), @intCast(tb.state.buf_height));

        // Draw diamond (simplified)
        const ix: i32 = 160;
        const iy: i32 = 100;
        tb.state.line(ix, iy - 6, ix + 5, iy, 18);
        tb.state.line(ix + 5, iy, ix, iy + 6, 18);
        tb.state.line(ix, iy + 6, ix - 5, iy, 18);
        tb.state.line(ix - 5, iy, ix, iy - 6, 18);
        tb.state.pset(ix, iy, 21);

        // Orbiting dots
        tb.state.circle(ix + 12, iy, 2, 19, true);
        tb.state.circle(ix - 6, iy + 10, 2, 20, true);
        tb.state.circle(ix - 6, iy - 10, 2, 17, true);

        // HUD text
        tb.state.drawText(4, 4, "Test 06: Frame Loop", 23, 0);
        tb.state.drawText(4, 190, "ESC to exit", 22, 0);

        // FLIP
        tb.state.flip();

        // Drain flip command from ring
        const flip_cmd = tb.state.command_ring.dequeue();
        try testing.expect(flip_cmd != null);
        try testing.expectEqual(GfxCommandType.flip, flip_cmd.?.cmd_type);
    }

    // Verify starfield was copied to target
    try testing.expectEqual(@as(u8, 16), tb.readPixel(tb.state.target, 0, 0));

    // === Phase 2: "SCREENCLOSE" ===
    tb.state.active.store(false, .release);
    tb.state.clearBufferPointers();

    // Drawing after close is safe
    tb.state.pset(0, 0, 1);
    try testing.expectEqual(@as(u8, 0), tb.state.pget(0, 0));

    // === Phase 3: Re-open (simulate new "SCREEN" call) ===
    tb.state.setResolution(320, 200);

    const buf_size: usize = @as(usize, tb.state.buf_width) * @as(usize, tb.state.buf_height);
    for (0..NUM_BUFFERS) |i| {
        @memset(tb.pixel_bufs[i], 0);
        tb.state.setBufferPointer(@intCast(i), tb.pixel_bufs[i].ptr, buf_size);
    }
    @memset(tb.line_pal_buf, std.mem.zeroes(LineColours));
    tb.state.setLinePalettePointer(tb.line_pal_buf.ptr, tb.state.buf_height);
    tb.state.setGlobalPalettePointer(tb.global_pal_buf);
    tb.state.setPaletteEffectsPointer(tb.effects_buf);
    tb.state.setCollisionFlagsPointer(tb.collision_buf.ptr);
    tb.state.active.store(true, .release);
    tb.state.initDefaultPalettes();

    // Drawing should work again
    tb.state.pset(50, 50, 99);
    try testing.expectEqual(@as(u8, 99), tb.state.pget(50, 50));
    tb.state.circle(100, 100, 15, 8, true);
    try testing.expectEqual(@as(u8, 8), tb.state.pget(100, 100));

    // Clean up
    tb.deinit();
}

// ═══════════════════════════════════════════════════════════════════════════
// Stress: rapid clear + draw cycles (simulates game loop)
// ═══════════════════════════════════════════════════════════════════════════

test "stress — 100 frames of clear, draw, flip" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    var frame: u32 = 0;
    while (frame < 100) : (frame += 1) {
        tb.state.clear(0);

        // Draw various primitives
        tb.state.pset(@intCast(frame % 320), @intCast(frame % 200), 5);
        tb.state.line(0, 0, @intCast(frame % 320), @intCast(frame % 200), 3);
        tb.state.rect(10, 10, 50, 50, 4, @as(u1, @intCast(frame % 2)) != 0);
        tb.state.circle(100, 100, @intCast(5 + frame % 20), 8, false);
        tb.state.drawText(0, 0, "Frame", 15, 0);

        tb.state.flip();

        // Drain commands
        while (tb.state.command_ring.dequeue()) |_| {}
    }

    try testing.expect(true);
}

// ═══════════════════════════════════════════════════════════════════════════
// Edge case: all 8 buffers used simultaneously
// ═══════════════════════════════════════════════════════════════════════════

test "all 8 buffers independently addressable" {
    var tb = try TestBuffers.init(160, 100);
    defer tb.deinit();

    // Write a distinct colour to each buffer
    var i: u3 = 0;
    while (true) {
        tb.state.target = i;
        tb.state.pset(0, 0, @as(u8, i) + 10);
        if (i == 7) break;
        i += 1;
    }

    // Verify each buffer has the correct value
    i = 0;
    while (true) {
        try testing.expectEqual(@as(u8, i) + 10, tb.readPixel(i, 0, 0));
        if (i == 7) break;
        i += 1;
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Edge case: blit from/to same buffer
// ═══════════════════════════════════════════════════════════════════════════

test "blitSolid from buffer to itself (overlapping copy)" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    // Draw a small pattern
    tb.state.pset(0, 0, 42);
    tb.state.pset(1, 0, 43);
    tb.state.pset(0, 1, 44);

    // Copy from (0,0) to (10,10) within the same buffer
    tb.state.blitSolid(tb.state.target, 10, 10, tb.state.target, 0, 0, 5, 5);

    // Original should still be there
    try testing.expectEqual(@as(u8, 42), tb.readTarget(0, 0));
    // Copy should be at new location
    try testing.expectEqual(@as(u8, 42), tb.readTarget(10, 10));
    try testing.expectEqual(@as(u8, 43), tb.readTarget(11, 10));
    try testing.expectEqual(@as(u8, 44), tb.readTarget(10, 11));
}

// ═══════════════════════════════════════════════════════════════════════════
// Edge case: resetSync reinitialises mutex/cond state
// ═══════════════════════════════════════════════════════════════════════════

test "resetSync reinitialises sync primitives" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    // Set some sync state
    tb.state.vsync_signalled = true;
    tb.state.gpu_wait_signalled = true;

    tb.state.resetSync();

    try testing.expect(!tb.state.vsync_signalled);
    try testing.expect(!tb.state.gpu_wait_signalled);
}

// ═══════════════════════════════════════════════════════════════════════════
// Game controller state
// ═══════════════════════════════════════════════════════════════════════════

test "joyCount returns number of connected controllers" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    try testing.expectEqual(@as(u8, 0), tb.state.joyCount());

    tb.state.controllers[0].connected = true;
    try testing.expectEqual(@as(u8, 1), tb.state.joyCount());

    tb.state.controllers[2].connected = true;
    try testing.expectEqual(@as(u8, 2), tb.state.joyCount());
}

// ═══════════════════════════════════════════════════════════════════════════
// BLITSCALE
// ═══════════════════════════════════════════════════════════════════════════

test "blitScale — 2× upscale" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    // Draw a 2x2 pattern into buffer 2
    tb.state.target = 2;
    tb.state.pset(0, 0, 10);
    tb.state.pset(1, 0, 11);
    tb.state.pset(0, 1, 12);
    tb.state.pset(1, 1, 13);

    // Scale 2x2 → 4x4 into buffer 1
    tb.state.target = 1;
    tb.state.blitScale(1, 0, 0, 4, 4, 2, 0, 0, 2, 2);

    // Each source pixel should map to a 2x2 block
    try testing.expectEqual(@as(u8, 10), tb.readPixel(1, 0, 0));
    try testing.expectEqual(@as(u8, 10), tb.readPixel(1, 1, 0));
    try testing.expectEqual(@as(u8, 10), tb.readPixel(1, 0, 1));
    try testing.expectEqual(@as(u8, 10), tb.readPixel(1, 1, 1));

    try testing.expectEqual(@as(u8, 11), tb.readPixel(1, 2, 0));
    try testing.expectEqual(@as(u8, 11), tb.readPixel(1, 3, 0));

    try testing.expectEqual(@as(u8, 12), tb.readPixel(1, 0, 2));
    try testing.expectEqual(@as(u8, 12), tb.readPixel(1, 1, 3));

    try testing.expectEqual(@as(u8, 13), tb.readPixel(1, 2, 2));
    try testing.expectEqual(@as(u8, 13), tb.readPixel(1, 3, 3));
}

test "blitScale — downscale 4x4 to 2x2" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    // Draw a 4x4 block of colour 7 into buffer 3
    tb.state.target = 3;
    tb.state.rect(0, 0, 3, 3, 7, true);

    // Scale 4x4 → 2x2 into buffer 1
    tb.state.target = 1;
    tb.state.blitScale(1, 10, 10, 2, 2, 3, 0, 0, 4, 4);

    try testing.expectEqual(@as(u8, 7), tb.readPixel(1, 10, 10));
    try testing.expectEqual(@as(u8, 7), tb.readPixel(1, 11, 10));
    try testing.expectEqual(@as(u8, 7), tb.readPixel(1, 10, 11));
    try testing.expectEqual(@as(u8, 7), tb.readPixel(1, 11, 11));
    // Outside the dest rect should be empty
    try testing.expectEqual(@as(u8, 0), tb.readPixel(1, 12, 10));
}

test "blitScale — transparency (index 0 not copied)" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    // Fill target with background colour
    tb.state.target = 1;
    tb.state.clear(5);

    // Buffer 2: some transparent, some opaque
    tb.state.target = 2;
    tb.state.pset(0, 0, 0); // transparent
    tb.state.pset(1, 0, 20); // opaque

    // Scale 2x1 → 4x2 into buffer 1
    tb.state.target = 1;
    tb.state.blitScale(1, 0, 0, 4, 2, 2, 0, 0, 2, 1);

    // Left half was index 0 → background preserved
    try testing.expectEqual(@as(u8, 5), tb.readPixel(1, 0, 0));
    try testing.expectEqual(@as(u8, 5), tb.readPixel(1, 1, 0));
    // Right half was index 20 → overwritten
    try testing.expectEqual(@as(u8, 20), tb.readPixel(1, 2, 0));
    try testing.expectEqual(@as(u8, 20), tb.readPixel(1, 3, 0));
}

test "blitScale — zero/negative dimensions are no-op" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.target = 2;
    tb.state.clear(9);

    tb.state.target = 1;
    tb.state.blitScale(1, 0, 0, 0, 10, 2, 0, 0, 10, 10);
    tb.state.blitScale(1, 0, 0, 10, 0, 2, 0, 0, 10, 10);
    tb.state.blitScale(1, 0, 0, 10, 10, 2, 0, 0, 0, 10);
    tb.state.blitScale(1, 0, 0, 10, 10, 2, 0, 0, 10, 0);
    tb.state.blitScale(1, 0, 0, -5, 10, 2, 0, 0, 10, 10);

    // Buffer 1 should still be all zeros
    try testing.expectEqual(@as(u8, 0), tb.readPixel(1, 0, 0));
}

test "blitScale — clipping at buffer edges" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.target = 2;
    tb.state.clear(15);

    // Scale into a region that extends past buffer bounds — should not crash
    tb.state.target = 1;
    const bw: i32 = @intCast(tb.state.buf_width);
    const bh: i32 = @intCast(tb.state.buf_height);
    tb.state.blitScale(1, bw - 5, bh - 5, 20, 20, 2, 0, 0, 10, 10);
    tb.state.blitScale(1, -10, -10, 20, 20, 2, 0, 0, 10, 10);
}

test "blitScale — null buffers do not crash" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.clearBufferPointers();
    tb.state.blitScale(0, 0, 0, 10, 10, 1, 0, 0, 5, 5);
}

// ═══════════════════════════════════════════════════════════════════════════
// BLITFLIP
// ═══════════════════════════════════════════════════════════════════════════

test "blitFlip — horizontal flip" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    // Draw a 4-pixel row: [10, 11, 12, 13] in buffer 2
    tb.state.target = 2;
    tb.state.pset(0, 0, 10);
    tb.state.pset(1, 0, 11);
    tb.state.pset(2, 0, 12);
    tb.state.pset(3, 0, 13);

    // H-flip (mode 1) into buffer 1
    tb.state.target = 1;
    tb.state.blitFlip(1, 0, 0, 2, 0, 0, 4, 1, 1);

    // Should be reversed: [13, 12, 11, 10]
    try testing.expectEqual(@as(u8, 13), tb.readPixel(1, 0, 0));
    try testing.expectEqual(@as(u8, 12), tb.readPixel(1, 1, 0));
    try testing.expectEqual(@as(u8, 11), tb.readPixel(1, 2, 0));
    try testing.expectEqual(@as(u8, 10), tb.readPixel(1, 3, 0));
}

test "blitFlip — vertical flip" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    // Draw a column: row0=10, row1=11, row2=12 in buffer 2
    tb.state.target = 2;
    tb.state.pset(0, 0, 10);
    tb.state.pset(0, 1, 11);
    tb.state.pset(0, 2, 12);

    // V-flip (mode 2) into buffer 1
    tb.state.target = 1;
    tb.state.blitFlip(1, 0, 0, 2, 0, 0, 1, 3, 2);

    // Should be reversed vertically: [12, 11, 10]
    try testing.expectEqual(@as(u8, 12), tb.readPixel(1, 0, 0));
    try testing.expectEqual(@as(u8, 11), tb.readPixel(1, 0, 1));
    try testing.expectEqual(@as(u8, 10), tb.readPixel(1, 0, 2));
}

test "blitFlip — both H+V flip (180° rotation)" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    // Draw a 2x2 grid:
    //   [10, 11]
    //   [12, 13]
    tb.state.target = 2;
    tb.state.pset(0, 0, 10);
    tb.state.pset(1, 0, 11);
    tb.state.pset(0, 1, 12);
    tb.state.pset(1, 1, 13);

    // HV-flip (mode 3) into buffer 1
    tb.state.target = 1;
    tb.state.blitFlip(1, 0, 0, 2, 0, 0, 2, 2, 3);

    // 180° rotation:
    //   [13, 12]
    //   [11, 10]
    try testing.expectEqual(@as(u8, 13), tb.readPixel(1, 0, 0));
    try testing.expectEqual(@as(u8, 12), tb.readPixel(1, 1, 0));
    try testing.expectEqual(@as(u8, 11), tb.readPixel(1, 0, 1));
    try testing.expectEqual(@as(u8, 10), tb.readPixel(1, 1, 1));
}

test "blitFlip — mode 0 is normal copy (no flip)" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.target = 2;
    tb.state.pset(0, 0, 10);
    tb.state.pset(1, 0, 11);

    tb.state.target = 1;
    tb.state.blitFlip(1, 0, 0, 2, 0, 0, 2, 1, 0);

    try testing.expectEqual(@as(u8, 10), tb.readPixel(1, 0, 0));
    try testing.expectEqual(@as(u8, 11), tb.readPixel(1, 1, 0));
}

test "blitFlip — transparency (index 0 not copied)" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.target = 1;
    tb.state.clear(99);

    // Buffer 2: transparent + opaque
    tb.state.target = 2;
    tb.state.pset(0, 0, 0); // transparent
    tb.state.pset(1, 0, 42); // opaque

    // H-flip: the opaque pixel moves to position 0
    tb.state.target = 1;
    tb.state.blitFlip(1, 0, 0, 2, 0, 0, 2, 1, 1);

    // Position 0 gets the flipped opaque pixel (42)
    try testing.expectEqual(@as(u8, 42), tb.readPixel(1, 0, 0));
    // Position 1 was transparent in source → background preserved
    try testing.expectEqual(@as(u8, 99), tb.readPixel(1, 1, 0));
}

test "blitFlip — clipping at buffer edges" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.target = 3;
    tb.state.clear(7);

    // Flip into regions extending past edges — should not crash
    tb.state.target = 1;
    tb.state.blitFlip(1, -5, -5, 3, 0, 0, 20, 20, 1);
    tb.state.blitFlip(1, -5, -5, 3, 0, 0, 20, 20, 2);
    tb.state.blitFlip(1, -5, -5, 3, 0, 0, 20, 20, 3);

    const bw: i32 = @intCast(tb.state.buf_width);
    const bh: i32 = @intCast(tb.state.buf_height);
    tb.state.blitFlip(1, bw - 2, bh - 2, 3, 0, 0, 20, 20, 1);
}

test "blitFlip — null buffers do not crash" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.clearBufferPointers();
    tb.state.blitFlip(0, 0, 0, 1, 0, 0, 10, 10, 1);
}

// ═══════════════════════════════════════════════════════════════════════════
// FILLAREA (flood fill)
// ═══════════════════════════════════════════════════════════════════════════

test "fillArea — fills enclosed region" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    // Draw a rectangular border with colour 5
    tb.state.rect(10, 10, 30, 30, 5, false);

    // Flood fill the interior from centre with colour 9
    tb.state.fillArea(20, 20, 9);

    // Interior should be filled
    try testing.expectEqual(@as(u8, 9), tb.state.pget(20, 20));
    try testing.expectEqual(@as(u8, 9), tb.state.pget(15, 15));
    try testing.expectEqual(@as(u8, 9), tb.state.pget(25, 25));
    try testing.expectEqual(@as(u8, 9), tb.state.pget(11, 11));
    try testing.expectEqual(@as(u8, 9), tb.state.pget(29, 29));

    // Border should be unchanged
    try testing.expectEqual(@as(u8, 5), tb.state.pget(10, 10));
    try testing.expectEqual(@as(u8, 5), tb.state.pget(30, 10));

    // Exterior should be unchanged (still 0)
    try testing.expectEqual(@as(u8, 0), tb.state.pget(5, 5));
    try testing.expectEqual(@as(u8, 0), tb.state.pget(35, 35));
}

test "fillArea — same colour is a no-op" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    // Fill with colour 7
    tb.state.clear(7);

    // fillArea with same colour should be a no-op
    tb.state.fillArea(50, 50, 7);

    // Should still be 7
    try testing.expectEqual(@as(u8, 7), tb.state.pget(50, 50));
}

test "fillArea — out-of-bounds seed is no-op" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    // Should not crash
    tb.state.fillArea(-10, -10, 5);
    tb.state.fillArea(5000, 5000, 5);
}

test "fillArea — fills up to different colour boundary" {
    var tb = try TestBuffers.init(160, 100);
    defer tb.deinit();

    // Draw a closed rectangle as boundary
    tb.state.rect(20, 20, 60, 60, 3, false);

    // Fill interior
    tb.state.fillArea(40, 40, 8);

    // Interior should be colour 8
    try testing.expectEqual(@as(u8, 8), tb.state.pget(40, 40));
    try testing.expectEqual(@as(u8, 8), tb.state.pget(21, 21));
    try testing.expectEqual(@as(u8, 8), tb.state.pget(59, 59));

    // Border should be untouched
    try testing.expectEqual(@as(u8, 3), tb.state.pget(20, 40));
    try testing.expectEqual(@as(u8, 3), tb.state.pget(60, 40));

    // Outside the rectangle should still be 0
    try testing.expectEqual(@as(u8, 0), tb.state.pget(10, 10));
    try testing.expectEqual(@as(u8, 0), tb.state.pget(70, 70));
}

test "fillArea — null buffer does not crash" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.clearBufferPointers();
    tb.state.fillArea(10, 10, 5);
}

// ═══════════════════════════════════════════════════════════════════════════
// ELLIPSE — filled
// ═══════════════════════════════════════════════════════════════════════════

test "ellipse — filled" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.ellipse(100, 100, 20, 10, 6, true);

    // Centre should be filled
    try testing.expectEqual(@as(u8, 6), tb.state.pget(100, 100));
    // Points on axes should be filled
    try testing.expectEqual(@as(u8, 6), tb.state.pget(100, 90)); // top
    try testing.expectEqual(@as(u8, 6), tb.state.pget(100, 110)); // bottom
    try testing.expectEqual(@as(u8, 6), tb.state.pget(80, 100)); // left
    try testing.expectEqual(@as(u8, 6), tb.state.pget(120, 100)); // right
    // Interior point should be filled
    try testing.expectEqual(@as(u8, 6), tb.state.pget(110, 100));

    // Well outside should be empty
    try testing.expectEqual(@as(u8, 0), tb.state.pget(100, 85));
    try testing.expectEqual(@as(u8, 0), tb.state.pget(125, 100));
}

test "ellipse — zero radii is a point" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.ellipse(50, 50, 0, 0, 14, false);
    try testing.expectEqual(@as(u8, 14), tb.state.pget(50, 50));
}

test "ellipse — equal radii delegates to circle" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    // When rx == ry, ellipse delegates to circle
    tb.state.ellipse(50, 50, 10, 10, 3, true);
    try testing.expectEqual(@as(u8, 3), tb.state.pget(50, 50));
    try testing.expectEqual(@as(u8, 3), tb.state.pget(50, 40));
    try testing.expectEqual(@as(u8, 3), tb.state.pget(50, 60));
}

// ═══════════════════════════════════════════════════════════════════════════
// getLinePalette
// ═══════════════════════════════════════════════════════════════════════════

test "getLinePalette — returns per-line colour" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    // Set a specific line palette entry
    tb.state.setLinePalette(5, 3, 128, 64, 32);

    const pal_val = tb.state.getLinePalette(5, 3);
    const c = RGBA32.unpack(pal_val);
    try testing.expectEqual(@as(u8, 128), c.r);
    try testing.expectEqual(@as(u8, 64), c.g);
    try testing.expectEqual(@as(u8, 32), c.b);
}

test "getLinePalette — index 0 returns transparent" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    const pal_val = tb.state.getLinePalette(0, 0);
    const c = RGBA32.unpack(pal_val);
    try testing.expectEqual(@as(u8, 0), c.a);
}

test "getLinePalette — index 1 returns black" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    const pal_val = tb.state.getLinePalette(0, 1);
    const c = RGBA32.unpack(pal_val);
    try testing.expectEqual(@as(u8, 0), c.r);
    try testing.expectEqual(@as(u8, 0), c.g);
    try testing.expectEqual(@as(u8, 0), c.b);
    try testing.expectEqual(@as(u8, 255), c.a);
}

test "getLinePalette — index >= 16 delegates to global palette" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.setPalette(20, 50, 60, 70);
    const pal_val = tb.state.getLinePalette(0, 20);
    const c = RGBA32.unpack(pal_val);
    try testing.expectEqual(@as(u8, 50), c.r);
    try testing.expectEqual(@as(u8, 60), c.g);
    try testing.expectEqual(@as(u8, 70), c.b);
}

test "getLinePalette — out-of-range scanline returns 0" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    const pal_val = tb.state.getLinePalette(9999, 3);
    try testing.expectEqual(@as(u32, 0), pal_val);
}

test "getLinePalette — null palette returns 0" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.line_palette = null;
    const pal_val = tb.state.getLinePalette(0, 3);
    try testing.expectEqual(@as(u32, 0), pal_val);
}

// ═══════════════════════════════════════════════════════════════════════════
// Palette Effects — pause / resume
// ═══════════════════════════════════════════════════════════════════════════

test "pauseEffect enqueues pause_effect command" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.pauseEffect(2);

    const cmd = tb.state.command_ring.dequeue().?;
    try testing.expectEqual(GfxCommandType.pause_effect, cmd.cmd_type);
    try testing.expectEqual(@as(u8, 2), cmd.payload[0]);
}

test "resumeEffect enqueues resume_effect command" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.resumeEffect(7);

    const cmd = tb.state.command_ring.dequeue().?;
    try testing.expectEqual(GfxCommandType.resume_effect, cmd.cmd_type);
    try testing.expectEqual(@as(u8, 7), cmd.payload[0]);
}

// ═══════════════════════════════════════════════════════════════════════════
// Collision — collideTest, collideResult, collideSingle
// ═══════════════════════════════════════════════════════════════════════════

test "collideTest enqueues collision_dispatch command" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.collideTest();

    const cmd = tb.state.command_ring.dequeue().?;
    try testing.expectEqual(GfxCommandType.collision_dispatch, cmd.cmd_type);
}

test "collideResult — reads triangular matrix" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.collideSetup(4);

    // Simulate GPU writing collision between source 0 and source 2
    // Triangular index for (0, 2): a=0, b=2 → idx = 2*(2-1)/2 + 0 = 1
    const flags = tb.state.collision_flags.?;
    flags[1] = 1;

    try testing.expect(tb.state.collideResult(0, 2));
    try testing.expect(tb.state.collideResult(2, 0)); // symmetric
    try testing.expect(!tb.state.collideResult(0, 1));
    try testing.expect(!tb.state.collideResult(1, 2));
}

test "collideResult — same index returns false" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.collideSetup(2);
    try testing.expect(!tb.state.collideResult(0, 0));
    try testing.expect(!tb.state.collideResult(1, 1));
}

test "collideResult — out-of-range returns false" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.collideSetup(2);
    try testing.expect(!tb.state.collideResult(0, 5));
    try testing.expect(!tb.state.collideResult(5, 0));
}

test "collideResult — null flags returns false" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.collideSetup(2);
    tb.state.collision_flags = null;
    try testing.expect(!tb.state.collideResult(0, 1));
}

test "collideSingle enqueues collision_single command with payload" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.collideSingle(2, 10, 20, 3, 50, 60, 32, 32);

    const cmd = tb.state.command_ring.dequeue().?;
    try testing.expectEqual(GfxCommandType.collision_single, cmd.cmd_type);

    var payload: CollisionSinglePayload = undefined;
    @memcpy(std.mem.asBytes(&payload), cmd.payload[0..@sizeOf(CollisionSinglePayload)]);
    try testing.expectEqual(@as(u3, 2), payload.buf_a);
    try testing.expectEqual(@as(u3, 3), payload.buf_b);
    try testing.expectEqual(@as(i16, 10), payload.ax);
    try testing.expectEqual(@as(i16, 20), payload.ay);
    try testing.expectEqual(@as(i16, 50), payload.bx);
    try testing.expectEqual(@as(i16, 60), payload.by);
    try testing.expectEqual(@as(u16, 32), payload.w);
    try testing.expectEqual(@as(u16, 32), payload.h);
}

test "collideSetup clamps to MAX_COLLISION_SOURCES" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.collideSetup(255);
    try testing.expectEqual(@as(u8, @intCast(MAX_COLLISION_SOURCES)), tb.state.collision_count);
}

test "collideSrc — out-of-range index is ignored" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.collideSetup(2);
    // Index 5 > count of 2 — should be silently ignored
    tb.state.collideSrc(5, 0, 10, 20, 32, 32);
    // Verify source 0 is still default
    try testing.expectEqual(@as(i16, 0), tb.state.collision_sources[0].x);
}

// ═══════════════════════════════════════════════════════════════════════════
// INKEY (key ring buffer)
// ═══════════════════════════════════════════════════════════════════════════

test "inkey — returns 0 when buffer empty" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    try testing.expectEqual(@as(u32, 0), tb.state.inkey());
}

test "inkey — returns pushed keys in FIFO order" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.key_buffer.push(65); // 'A'
    tb.state.key_buffer.push(66); // 'B'
    tb.state.key_buffer.push(67); // 'C'

    try testing.expectEqual(@as(u32, 65), tb.state.inkey());
    try testing.expectEqual(@as(u32, 66), tb.state.inkey());
    try testing.expectEqual(@as(u32, 67), tb.state.inkey());
    try testing.expectEqual(@as(u32, 0), tb.state.inkey()); // empty
}

test "inkey — ring buffer wraps and overwrites oldest" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    // Push more than the ring buffer capacity (64)
    var i: u32 = 0;
    while (i < 70) : (i += 1) {
        tb.state.key_buffer.push(i + 100);
    }

    // Oldest entries should have been overwritten
    // After 70 pushes into a 64-entry ring, the oldest 6 are lost
    // First pop should return entry 106 (the 7th push: index 6)
    const first = tb.state.inkey();
    try testing.expect(first > 100); // sanity
    try testing.expectEqual(@as(u32, 107), first);
}

// ═══════════════════════════════════════════════════════════════════════════
// Joystick — joyAxis / joyButton
// ═══════════════════════════════════════════════════════════════════════════

test "joyAxis — returns axis value" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.controllers[0].connected = true;
    tb.state.controllers[0].axes[0] = 0.75;
    tb.state.controllers[0].axes[1] = -0.5;

    try testing.expectApproxEqAbs(@as(f32, 0.75), tb.state.joyAxis(0, 0), 0.001);
    try testing.expectApproxEqAbs(@as(f32, -0.5), tb.state.joyAxis(0, 1), 0.001);
}

test "joyAxis — out-of-range controller returns 0" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    try testing.expectApproxEqAbs(@as(f32, 0.0), tb.state.joyAxis(4, 0), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), tb.state.joyAxis(255, 0), 0.001);
}

test "joyAxis — out-of-range axis returns 0" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.controllers[0].connected = true;
    tb.state.controllers[0].axes[0] = 1.0;

    try testing.expectApproxEqAbs(@as(f32, 0.0), tb.state.joyAxis(0, 6), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), tb.state.joyAxis(0, 255), 0.001);
}

test "joyButton — returns button state from bitmask" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.controllers[1].connected = true;
    tb.state.controllers[1].buttons = 0b0000_0101; // buttons 0 and 2 pressed

    try testing.expect(tb.state.joyButton(1, 0));
    try testing.expect(!tb.state.joyButton(1, 1));
    try testing.expect(tb.state.joyButton(1, 2));
    try testing.expect(!tb.state.joyButton(1, 3));
}

test "joyButton — out-of-range controller returns false" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    try testing.expect(!tb.state.joyButton(4, 0));
    try testing.expect(!tb.state.joyButton(255, 0));
}

test "joyButton — out-of-range button returns false" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.controllers[0].connected = true;
    tb.state.controllers[0].buttons = 0xFFFFFFFF;

    try testing.expect(!tb.state.joyButton(0, 32));
    try testing.expect(!tb.state.joyButton(0, 255));
}

test "joyCount — counts only connected controllers" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.controllers[0].connected = true;
    tb.state.controllers[1].connected = false;
    tb.state.controllers[2].connected = true;
    tb.state.controllers[3].connected = true;

    try testing.expectEqual(@as(u8, 3), tb.state.joyCount());
}

// ═══════════════════════════════════════════════════════════════════════════
// determinePAR
// ═══════════════════════════════════════════════════════════════════════════

test "determinePAR — 320x200 gets 5:6 PAR" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.par_enabled = true;
    tb.state.screen_mode = .normal;
    tb.state.determinePAR();

    try testing.expectEqual(@as(u16, 5), tb.state.par_numerator);
    try testing.expectEqual(@as(u16, 6), tb.state.par_denominator);
}

test "determinePAR — unknown resolution gets square pixels" {
    var tb = try TestBuffers.init(800, 600);
    defer tb.deinit();

    tb.state.par_enabled = true;
    tb.state.screen_mode = .normal;
    tb.state.determinePAR();

    try testing.expectEqual(@as(u16, 1), tb.state.par_numerator);
    try testing.expectEqual(@as(u16, 1), tb.state.par_denominator);
}

test "determinePAR — square mode forces 1:1" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.par_enabled = true;
    tb.state.screen_mode = .square;
    tb.state.determinePAR();

    try testing.expectEqual(@as(u16, 1), tb.state.par_numerator);
    try testing.expectEqual(@as(u16, 1), tb.state.par_denominator);
}

test "determinePAR — par_enabled false forces 1:1" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.par_enabled = false;
    tb.state.screen_mode = .normal;
    tb.state.determinePAR();

    try testing.expectEqual(@as(u16, 1), tb.state.par_numerator);
    try testing.expectEqual(@as(u16, 1), tb.state.par_denominator);
}

test "determinePAR — 640x200 gets 5:12 PAR" {
    var s: GraphicsState = .{};
    s.setResolution(640, 200);
    s.par_enabled = true;
    s.screen_mode = .normal;
    s.determinePAR();

    try testing.expectEqual(@as(u16, 5), s.par_numerator);
    try testing.expectEqual(@as(u16, 12), s.par_denominator);
}

test "determinePAR — 640x400 gets 5:6 PAR" {
    var s: GraphicsState = .{};
    s.setResolution(640, 400);
    s.par_enabled = true;
    s.screen_mode = .normal;
    s.determinePAR();

    try testing.expectEqual(@as(u16, 5), s.par_numerator);
    try testing.expectEqual(@as(u16, 6), s.par_denominator);
}

// ═══════════════════════════════════════════════════════════════════════════
// scrollBuffer — additional cases
// ═══════════════════════════════════════════════════════════════════════════

test "scrollBuffer — diagonal scroll" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    // Draw a single pixel
    tb.state.pset(50, 50, 11);

    // Scroll diagonally right+down by (3, 4)
    tb.state.scrollBuffer(3, 4, 0);

    // Pixel should have moved
    try testing.expectEqual(@as(u8, 11), tb.state.pget(53, 54));
    // Original position should be cleared
    try testing.expectEqual(@as(u8, 0), tb.state.pget(50, 50));
}

test "scrollBuffer — negative direction (scroll left+up)" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.pset(50, 50, 22);

    // Scroll left and up
    tb.state.scrollBuffer(-5, -3, 0);

    try testing.expectEqual(@as(u8, 22), tb.state.pget(45, 47));
    try testing.expectEqual(@as(u8, 0), tb.state.pget(50, 50));
}

test "scrollBuffer — fill colour for exposed edges" {
    var tb = try TestBuffers.init(160, 100);
    defer tb.deinit();

    tb.state.clear(7);

    // Scroll right by 10 with fill colour 33
    tb.state.scrollBuffer(10, 0, 33);

    // The left edge (exposed by scroll) should be fill colour
    try testing.expectEqual(@as(u8, 33), tb.state.pget(0, 50));
    try testing.expectEqual(@as(u8, 33), tb.state.pget(5, 50));
    try testing.expectEqual(@as(u8, 33), tb.state.pget(9, 50));

    // Beyond the fill edge should have original content
    try testing.expectEqual(@as(u8, 7), tb.state.pget(10, 50));
}

test "scrollBuffer — scroll larger than buffer clears entirely" {
    var tb = try TestBuffers.init(160, 100);
    defer tb.deinit();

    tb.state.clear(42);

    // Scroll by more than buffer dimensions
    const bw: i32 = @intCast(tb.state.buf_width);
    tb.state.scrollBuffer(bw + 10, 0, 99);

    // Entire buffer should be fill colour
    try testing.expectEqual(@as(u8, 99), tb.state.pget(0, 0));
    try testing.expectEqual(@as(u8, 99), tb.state.pget(80, 50));
}

test "scrollBuffer — zero scroll is a no-op" {
    var tb = try TestBuffers.init(160, 100);
    defer tb.deinit();

    tb.state.pset(10, 10, 55);
    tb.state.scrollBuffer(0, 0, 0);
    try testing.expectEqual(@as(u8, 55), tb.state.pget(10, 10));
}

// ═══════════════════════════════════════════════════════════════════════════
// mouseScroll — verify swap-and-reset semantics
// ═══════════════════════════════════════════════════════════════════════════

test "mouseScroll resets to zero after read" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    tb.state.mouse_scroll.store(5, .release);
    try testing.expectEqual(@as(i16, 5), tb.state.mouseScroll());
    // Second read should return 0 (swap semantics)
    try testing.expectEqual(@as(i16, 0), tb.state.mouseScroll());
}

// ═══════════════════════════════════════════════════════════════════════════
// waitGpu — basic state test (non-blocking path)
// ═══════════════════════════════════════════════════════════════════════════

test "waitGpu enqueues wait_gpu command" {
    var tb = try TestBuffers.init(320, 200);
    defer tb.deinit();

    // Pre-signal so waitGpu doesn't block
    tb.state.gpu_wait_signalled = true;

    tb.state.waitGpu();

    // waitGpu calls commit() first, which enqueues a commit_fence
    const fence_cmd = tb.state.command_ring.dequeue().?;
    try testing.expectEqual(GfxCommandType.commit_fence, fence_cmd.cmd_type);

    // Then it enqueues the actual wait_gpu command
    const wait_cmd = tb.state.command_ring.dequeue().?;
    try testing.expectEqual(GfxCommandType.wait_gpu, wait_cmd.cmd_type);
}

// ═══════════════════════════════════════════════════════════════════════════
// RingBuffer (generic) — additional coverage
// ═══════════════════════════════════════════════════════════════════════════

test "RingBuffer — empty initially" {
    var rb: RingBuffer(u32, 64) = .{};
    try testing.expect(rb.empty());
    try testing.expectEqual(@as(?u32, null), rb.pop());
}

test "RingBuffer — push and pop single item" {
    var rb: RingBuffer(u32, 64) = .{};
    rb.push(42);
    try testing.expect(!rb.empty());
    try testing.expectEqual(@as(?u32, 42), rb.pop());
    try testing.expect(rb.empty());
}

test "RingBuffer — FIFO order preserved" {
    var rb: RingBuffer(u32, 64) = .{};
    rb.push(1);
    rb.push(2);
    rb.push(3);
    try testing.expectEqual(@as(?u32, 1), rb.pop());
    try testing.expectEqual(@as(?u32, 2), rb.pop());
    try testing.expectEqual(@as(?u32, 3), rb.pop());
}

test "RingBuffer — overflow overwrites oldest" {
    var rb: RingBuffer(u8, 4) = .{};
    rb.push(10);
    rb.push(20);
    rb.push(30);
    // Ring has capacity for 3 items (N-1), so next push overwrites oldest
    rb.push(40);

    // Oldest (10) was overwritten
    try testing.expectEqual(@as(?u8, 20), rb.pop());
    try testing.expectEqual(@as(?u8, 30), rb.pop());
    try testing.expectEqual(@as(?u8, 40), rb.pop());
    try testing.expectEqual(@as(?u8, null), rb.pop());
}

// ═══════════════════════════════════════════════════════════════════════════
// Extern stubs (satisfy linker for test binary)
// ═══════════════════════════════════════════════════════════════════════════

// ed_graphics.zig declares these externs; we must provide them so the
// test binary links.  They are never actually called in these tests
// because we bypass screen() / screenClose() and drive GraphicsState
// directly.

export fn gfx_create_window_sync(_: u16, _: u16, _: u16) callconv(.c) void {}
export fn gfx_destroy_window_async() callconv(.c) void {}
export fn timer_tick_frame() callconv(.c) void {}
