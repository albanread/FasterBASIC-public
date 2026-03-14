// ─── Ed Graphics — Core State & Primitives ──────────────────────────────────
//
// This module implements the retro graphics system for FasterBASIC:
//
//   • GraphicsState: 8 indexed-colour buffers, palettes, scroll, input
//   • GfxCommandRing: lock-free SPSC ring for JIT → main thread commands
//   • Drawing primitives: PSET, LINE, RECT, CIRCLE, ELLIPSE, TRIANGLE, etc.
//   • Blit operations: BLIT (transparent), BLITSOLID, BLITSCALE, BLITFLIP
//   • Text rendering via built-in CP437 bitmap fonts
//   • Palette management: per-line (indices 2–15) + global (indices 16–255)
//   • Palette animation effect slot management (GPU-side state machine)
//
// All drawing primitives write directly into shared MTLBuffer contents
// (MTLStorageModeShared). The GPU only reads these buffers during rendering.
//
// Thread safety:
//   • The JIT thread writes pixels/palettes via direct shared memory.
//   • Commands requiring main-thread dispatch go through GfxCommandRing.
//   • Input state is read via atomic loads (main thread writes atomically).

const std = @import("std");
pub const sprite = @import("sprite.zig");

// ── Window lifecycle (defined in ed_graphics_bridge.m) ──────────────────
// gfx_create_window_sync  — dispatch_sync to main thread; blocks the
//                           caller until the window is created and
//                           buffer pointers are set.
// gfx_destroy_window_async — dispatch_async to main thread; returns
//                            immediately (SCREENCLOSE doesn't need to
//                            wait — the program is about to exit).
extern fn gfx_create_window_sync(w: u16, h: u16, scale: u16) callconv(.c) void;
extern fn gfx_destroy_window_async() callconv(.c) void;
const font = @import("ed_graphics_font.zig");
const Allocator = std.mem.Allocator;

// Frame-based timer tick — defined in runtime/messaging.zig, exported as C-callable.
// Called once per VSYNC to drive AFTER/EVERY n FRAMES SEND timers.
extern fn timer_tick_frame() callconv(.c) void;

// ─── Constants ──────────────────────────────────────────────────────────────

pub const MAX_RESOLUTION_W: u16 = 1920;
pub const MAX_RESOLUTION_H: u16 = 1080;
pub const NUM_BUFFERS: u32 = 8;
pub const MAX_PALETTE_EFFECTS: u32 = 32;
pub const MAX_COLLISION_SOURCES: u32 = 64;
pub const GFX_COMMAND_RING_SIZE: u32 = 4096; // Must be power of 2
pub const MENU_EVENT_RING_SIZE: u32 = 128;
pub const MIN_OVERSCAN: u16 = 64;

// ─── Colour Types ───────────────────────────────────────────────────────────

pub const RGBA32 = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub const TRANSPARENT = RGBA32{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const BLACK = RGBA32{ .r = 0, .g = 0, .b = 0, .a = 255 };
    pub const WHITE = RGBA32{ .r = 255, .g = 255, .b = 255, .a = 255 };

    pub fn init(r: u8, g: u8, b: u8) RGBA32 {
        return .{ .r = r, .g = g, .b = b, .a = 255 };
    }

    pub fn pack(self: RGBA32) u32 {
        return @as(u32, self.r) |
            (@as(u32, self.g) << 8) |
            (@as(u32, self.b) << 16) |
            (@as(u32, self.a) << 24);
    }

    pub fn unpack(v: u32) RGBA32 {
        return .{
            .r = @truncate(v),
            .g = @truncate(v >> 8),
            .b = @truncate(v >> 16),
            .a = @truncate(v >> 24),
        };
    }
};

/// Per-scanline palette: 16 RGBA32 entries (indices 0–15).
pub const LineColours = [16]RGBA32;

// ─── Palette Effect (GPU-side, must match graphics.metal PaletteEffect) ─────

pub const PaletteEffectType = enum(u32) {
    none = 0,
    cycle = 1,
    fade = 2,
    pulse = 3,
    gradient = 4,
    strobe = 5,
};

pub const EFFECT_FLAG_PER_LINE: u32 = 1 << 0;
pub const EFFECT_FLAG_ACTIVE: u32 = 1 << 1;
pub const EFFECT_FLAG_ONE_SHOT: u32 = 1 << 2;

pub const PaletteEffect = extern struct {
    effect_type: u32,
    flags: u32,
    index_start: u32,
    index_end: u32,
    line_start: u32,
    line_end: u32,
    speed: f32,
    phase: f32,
    colour_a: [4]u8,
    colour_b: [4]u8,
    direction: i32,
    _pad: [1]u32,

    pub fn empty() PaletteEffect {
        return std.mem.zeroes(PaletteEffect);
    }
};

// ─── Collision Source ────────────────────────────────────────────────────────

pub const CollisionSource = struct {
    buffer: u3,
    x: i16,
    y: i16,
    w: u16,
    h: u16,
};

// ─── Command Queue ──────────────────────────────────────────────────────────

pub const GfxCommandType = enum(u8) {
    // Window management (main thread dispatch)
    create_window = 0,
    destroy_window = 1,
    set_title = 2,
    set_screen_mode = 3,

    // Frame control
    flip = 4,
    set_scroll = 5,

    // Palette effects (write to shared buffer + notify GPU)
    install_effect = 6,
    stop_effect = 7,
    stop_all_effects = 8,
    pause_effect = 9,
    resume_effect = 10,

    // GPU dispatch
    collision_dispatch = 11,
    collision_single = 12,

    // Sprite system
    sprite_upload = 15,

    // Menu system
    menu_reset = 16,
    menu_define = 17,
    menu_add_item = 18,
    menu_add_separator = 19,
    menu_set_checked = 20,
    menu_set_enabled = 21,
    menu_rename = 22,
    set_app_name = 23,

    // Synchronisation
    commit_fence = 13,
    wait_gpu = 14,
};

pub const GfxCommand = struct {
    cmd_type: GfxCommandType,
    fence_id: u32,
    payload: [56]u8,

    pub fn init(cmd_type: GfxCommandType) GfxCommand {
        return .{
            .cmd_type = cmd_type,
            .fence_id = 0,
            .payload = std.mem.zeroes([56]u8),
        };
    }
};

/// Payload for create_window command.
pub const CreateWindowPayload = extern struct {
    width: u16,
    height: u16,
    scale_hint: u16,
    _pad: u16,
};

/// Payload for set_scroll command.
pub const SetScrollPayload = extern struct {
    scroll_x: i16,
    scroll_y: i16,
};

/// Payload for set_title command.
/// Payload for set_title command — string data is copied inline (max 52 bytes).
pub const SetTitlePayload = extern struct {
    len: u32, // string length (capped at 52)
    data: [52]u8, // inline string data
};

/// Payload for install_effect command.
pub const InstallEffectPayload = extern struct {
    slot: u8,
    _pad: [3]u8,
    effect: PaletteEffect,
};

/// Payload for stop/pause/resume effect.
pub const SlotPayload = extern struct {
    slot: u8,
};

/// Payload for collision_single.
pub const CollisionSinglePayload = extern struct {
    buf_a: u8,
    buf_b: u8,
    _pad: [2]u8,
    ax: i16,
    ay: i16,
    bx: i16,
    by: i16,
    w: u16,
    h: u16,
};

pub const MenuDefinePayload = extern struct {
    menu_id: u8,
    title_len: u8,
    title: [30]u8,
};

pub const MenuItemPayload = extern struct {
    menu_id: u8,
    _pad0: u8,
    item_id: u16,
    label_len: u8,
    shortcut_len: u8,
    flags: u16,
    label: [24]u8,
    shortcut: [8]u8,
};

pub const MenuStatePayload = extern struct {
    item_id: u16,
    state: u8,
    _pad0: u8,
};

pub const MenuRenamePayload = extern struct {
    item_id: u16,
    label_len: u8,
    _pad0: u8,
    label: [30]u8,
};

pub const GfxCommandRing = struct {
    buffer: [GFX_COMMAND_RING_SIZE]GfxCommand,
    write_pos: std.atomic.Value(u32),
    read_pos: std.atomic.Value(u32),

    pub fn init() GfxCommandRing {
        return .{
            .buffer = undefined,
            .write_pos = std.atomic.Value(u32).init(0),
            .read_pos = std.atomic.Value(u32).init(0),
        };
    }

    /// Enqueue a command (JIT thread — single producer).
    /// Returns false if the ring is full.
    pub fn enqueue(self: *GfxCommandRing, cmd: GfxCommand) bool {
        const w = self.write_pos.load(.acquire);
        const r = self.read_pos.load(.acquire);
        const next_w = (w + 1) % GFX_COMMAND_RING_SIZE;
        if (next_w == r) return false; // Full
        self.buffer[w] = cmd;
        self.write_pos.store(next_w, .release);
        return true;
    }

    /// Dequeue a command (main thread — single consumer).
    /// Returns null if the ring is empty.
    pub fn dequeue(self: *GfxCommandRing) ?GfxCommand {
        const r = self.read_pos.load(.acquire);
        const w = self.write_pos.load(.acquire);
        if (r == w) return null; // Empty
        const cmd = self.buffer[r];
        self.read_pos.store((r + 1) % GFX_COMMAND_RING_SIZE, .release);
        return cmd;
    }

    /// Check if the ring is empty.
    pub fn isEmpty(self: *GfxCommandRing) bool {
        return self.read_pos.load(.acquire) == self.write_pos.load(.acquire);
    }
};

// ─── Input Ring Buffer ──────────────────────────────────────────────────────

pub fn RingBuffer(comptime T: type, comptime N: u32) type {
    return struct {
        data: [N]T = std.mem.zeroes([N]T),
        head: u32 = 0, // write position
        tail: u32 = 0, // read position

        const Self = @This();

        pub fn push(self: *Self, item: T) void {
            const next = (self.head + 1) % N;
            if (next == self.tail) {
                // Full — overwrite oldest
                self.tail = (self.tail + 1) % N;
            }
            self.data[self.head] = item;
            self.head = next;
        }

        pub fn pop(self: *Self) ?T {
            if (self.head == self.tail) return null;
            const item = self.data[self.tail];
            self.tail = (self.tail + 1) % N;
            return item;
        }

        pub fn empty(self: *const Self) bool {
            return self.head == self.tail;
        }
    };
}

pub const MenuEventRing = struct {
    data: [MENU_EVENT_RING_SIZE]u16 = std.mem.zeroes([MENU_EVENT_RING_SIZE]u16),
    head: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    tail: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn push(self: *MenuEventRing, item_id: u16) void {
        const h = self.head.load(.acquire);
        const t = self.tail.load(.acquire);
        const next_h = (h + 1) % MENU_EVENT_RING_SIZE;
        if (next_h == t) {
            self.tail.store((t + 1) % MENU_EVENT_RING_SIZE, .release);
        }
        self.data[h] = item_id;
        self.head.store(next_h, .release);
    }

    pub fn pop(self: *MenuEventRing) ?u16 {
        const t = self.tail.load(.acquire);
        const h = self.head.load(.acquire);
        if (t == h) return null;
        const value = self.data[t];
        self.tail.store((t + 1) % MENU_EVENT_RING_SIZE, .release);
        return value;
    }

    pub fn clear(self: *MenuEventRing) void {
        const h = self.head.load(.acquire);
        self.tail.store(h, .release);
    }
};

// ─── Controller State ───────────────────────────────────────────────────────

pub const ControllerState = struct {
    connected: bool = false,
    axes: [6]f32 = [_]f32{0} ** 6,
    buttons: u32 = 0, // bitmask

    pub fn getAxis(self: *const ControllerState, axis: u8) f32 {
        if (axis >= 6) return 0;
        return self.axes[axis];
    }

    pub fn getButton(self: *const ControllerState, btn: u8) bool {
        if (btn >= 32) return false;
        return (self.buttons & (@as(u32, 1) << @intCast(btn))) != 0;
    }
};

// ─── PAR Table ──────────────────────────────────────────────────────────────

const PAREntry = struct {
    w: u16,
    h: u16,
    par_num: u16,
    par_den: u16,
};

const par_table = [_]PAREntry{
    .{ .w = 320, .h = 200, .par_num = 5, .par_den = 6 },
    .{ .w = 640, .h = 200, .par_num = 5, .par_den = 12 },
    .{ .w = 640, .h = 400, .par_num = 5, .par_den = 6 },
};

// ─── Screen Mode ────────────────────────────────────────────────────────────

pub const ScreenMode = enum(u8) {
    normal = 0,
    square = 1,
    crt = 2,
};

// ─── Graphics State ─────────────────────────────────────────────────────────

pub const GraphicsState = struct {
    // ── Resolution ──
    width: u16 = 0,
    height: u16 = 0,
    buf_width: u16 = 0,
    buf_height: u16 = 0,
    overscan_x: u16 = 0,
    overscan_y: u16 = 0,

    // ── Buffers ──
    buffers: [NUM_BUFFERS]?[]u8 = [_]?[]u8{null} ** NUM_BUFFERS,
    target: u3 = 1, // Current drawing target (default: back buffer)
    front: u1 = 0, // Current front buffer (0 or 1)

    // ── Scroll ──
    scroll_x: i16 = 0,
    scroll_y: i16 = 0,

    // ── Palettes (pointers into shared MTLBuffer contents) ──
    line_palette: ?[*]LineColours = null,
    line_palette_len: u32 = 0,
    global_palette: ?*[240]RGBA32 = null,

    // ── Palette Animation (GPU state machine — shared MTLBuffer) ──
    palette_effects: ?*[MAX_PALETTE_EFFECTS]PaletteEffect = null,
    frame_counter: u32 = 0,

    // ── Sprite System ──
    sprites: sprite.SpriteBank = .{},

    // ── Sprite Canvas Draw Target ──
    // When sprite_canvas_buf is non-null, all drawing primitives redirect
    // into the sprite's staging buffer instead of a screen pixel buffer.
    // Pixel values are clamped to 0–15 (sprite palette indices).
    sprite_canvas_buf: ?[]u8 = null,
    sprite_canvas_w: u16 = 0,
    sprite_canvas_h: u16 = 0,
    sprite_canvas_id: i16 = -1, // which sprite ID we're targeting (-1 = off)
    sprite_frame_x: u16 = 0,
    sprite_frame_y: u16 = 0,
    sprite_frame_w: u16 = 0,
    sprite_frame_h: u16 = 0,

    // ── Collision (shared MTLBuffer — GPU writes, CPU reads) ──
    collision_sources: [MAX_COLLISION_SOURCES]CollisionSource = undefined,
    collision_count: u8 = 0,
    collision_flags: ?[*]u32 = null,

    // ── PAR correction ──
    par_numerator: u16 = 1,
    par_denominator: u16 = 1,
    par_enabled: bool = true,
    screen_mode: ScreenMode = .normal,

    // ── Input State (atomics, main thread writes, JIT reads) ──
    key_state: [256]std.atomic.Value(u8) = blk: {
        var arr: [256]std.atomic.Value(u8) = undefined;
        for (&arr) |*v| {
            v.* = std.atomic.Value(u8).init(0);
        }
        break :blk arr;
    },
    key_buffer: RingBuffer(u32, 64) = .{},
    mouse_x: std.atomic.Value(i16) = std.atomic.Value(i16).init(0),
    mouse_y: std.atomic.Value(i16) = std.atomic.Value(i16).init(0),
    mouse_buttons: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    mouse_scroll: std.atomic.Value(i16) = std.atomic.Value(i16).init(0),
    menu_events: MenuEventRing = .{},
    controllers: [4]ControllerState = [_]ControllerState{.{}} ** 4,

    // ── Command Queue (JIT → main thread) ──
    command_ring: GfxCommandRing = GfxCommandRing.init(),
    next_fence_id: u32 = 1,
    last_completed_fence: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    // ── Lifecycle ──
    active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // ── Sync ──
    // These are signalled by the MTKView completion handler on the main thread.
    // The JIT thread waits on them for VSYNC/GWAIT/SCREEN.
    vsync_mutex: std.Thread.Mutex = .{},
    vsync_cond: std.Thread.Condition = .{},
    vsync_signalled: bool = false,

    gpu_wait_mutex: std.Thread.Mutex = .{},
    gpu_wait_cond: std.Thread.Condition = .{},
    gpu_wait_signalled: bool = false,

    // ─── Command Queue Helpers ──────────────────────────────────────

    pub fn enqueueCommand(self: *GraphicsState, cmd: GfxCommand) void {
        // Spin if full (should never happen in practice)
        while (!self.command_ring.enqueue(cmd)) {
            std.atomic.spinLoopHint();
        }
    }

    /// GCOMMIT — flush queue, insert fence, return fence_id (non-blocking).
    pub fn commit(self: *GraphicsState) u32 {
        const fence_id = self.next_fence_id;
        self.next_fence_id +%= 1;
        var cmd = GfxCommand.init(.commit_fence);
        cmd.fence_id = fence_id;
        self.enqueueCommand(cmd);
        return fence_id;
    }

    /// GWAIT — block until GPU completes all pending work.
    pub fn waitGpu(self: *GraphicsState) void {
        _ = self.commit();
        const cmd = GfxCommand.init(.wait_gpu);
        self.enqueueCommand(cmd);

        self.gpu_wait_mutex.lock();
        defer self.gpu_wait_mutex.unlock();
        while (!self.gpu_wait_signalled) {
            self.gpu_wait_cond.wait(&self.gpu_wait_mutex);
        }
        self.gpu_wait_signalled = false;
    }

    /// VSYNC — commit pending commands, block until next frame presented.
    pub fn vsync(self: *GraphicsState) void {
        // Sync sprite instance data to GPU buffers before the frame is submitted.
        // This is the natural synchronisation point: the JIT thread is about to
        // block, so writing to shared buffers is safe.
        self.sprites.updateAndSync();
        self.frame_counter +%= 1;

        _ = self.commit();

        self.vsync_mutex.lock();
        defer self.vsync_mutex.unlock();
        while (!self.vsync_signalled) {
            self.vsync_cond.wait(&self.vsync_mutex);
        }
        self.vsync_signalled = false;
    }

    /// WAIT FRAMES n — suspend the JIT thread for exactly `n` display frames.
    ///
    /// The JIT thread commits any pending GPU commands and then sleeps on
    /// WAIT FRAMES n — sleep the calling thread for n * 16 ms (one 60 Hz frame).
    pub fn waitFrames(self: *GraphicsState, n: u32) void {
        if (n == 0) return;
        // Sync sprite state before sleeping, otherwise the render loop sees stale
        // or invisible sprites for the duration of the sleep.
        self.sprites.updateAndSync();
        self.frame_counter +%= n;

        _ = self.commit();
        std.Thread.sleep(@as(u64, n) * 16_000_000);
    }

    /// GFENCEDONE — poll whether a fence has completed (non-blocking).
    pub fn fenceDone(self: *GraphicsState, fence_id: u32) bool {
        const completed = self.last_completed_fence.load(.acquire);
        // Handle wraparound: completed >= fence_id (mod 2^32)
        const diff = completed -% fence_id;
        return diff < 0x80000000;
    }

    /// Signal VSYNC completion (called from main thread / completion handler).
    /// Also ticks frame-based timers (AFTER/EVERY n FRAMES SEND).
    pub fn signalVsync(self: *GraphicsState) void {
        // Tick frame-based timers before signalling waiters, so that
        // any messages pushed by frame timers are visible to the JIT
        // thread when it wakes from VSYNC.
        timer_tick_frame();

        self.vsync_mutex.lock();
        defer self.vsync_mutex.unlock();
        self.vsync_signalled = true;
        self.vsync_cond.signal();
    }

    /// Signal GPU wait completion (called from main thread / completion handler).
    pub fn signalGpuWait(self: *GraphicsState) void {
        self.gpu_wait_mutex.lock();
        defer self.gpu_wait_mutex.unlock();
        self.gpu_wait_signalled = true;
        self.gpu_wait_cond.signal();
    }

    /// Reset synchronisation primitives after a forced stop.
    ///
    /// When SIGALRM fires while the JIT thread holds one of the sync
    /// mutexes (vsync, gpu_wait, creation), siglongjmp unwinds the
    /// stack without executing `defer mutex.unlock()`.  The mutex is
    /// left permanently locked and the next run deadlocks.
    ///
    /// This function reinitialises all three mutex/condition pairs so
    /// the next program starts with clean state.  It is called from
    /// the JIT thread *after* basic_jit_exec returns with exit code 124
    /// (forced stop).
    pub fn resetSync(self: *GraphicsState) void {
        self.vsync_mutex = .{};
        self.vsync_cond = .{};
        self.vsync_signalled = false;

        self.gpu_wait_mutex = .{};
        self.gpu_wait_cond = .{};
        self.gpu_wait_signalled = false;
    }

    // ─── Sprite Canvas Draw Target ──────────────────────────────────

    /// SPRITE BEGIN id — redirect all drawing commands into sprite `id`'s
    /// staging buffer.  Drawing coordinates are sprite-local (0,0 = top-left)
    /// and colours are masked to 0–15.  Call endSpriteCanvas() to restore the
    /// normal screen target.  Returns false if the sprite is not yet defined.
    pub fn beginSpriteCanvas(self: *GraphicsState, id: u16) bool {
        const bank = &self.sprites;
        if (id >= sprite.MAX_DEFINITIONS) return false;
        const def = &bank.definitions[id];
        if (!def.active) return false;

        const pixel_count: usize = @as(usize, def.width) * @as(usize, def.height);
        const staging = bank.staging_buffer orelse return false;
        if (pixel_count > bank.staging_buffer_size) return false;

        self.sprite_canvas_buf = staging[0..pixel_count];
        self.sprite_canvas_w = def.width;
        self.sprite_canvas_h = def.height;
        self.sprite_canvas_id = @intCast(id);
        self.sprite_frame_x = 0;
        self.sprite_frame_y = 0;
        self.sprite_frame_w = def.width;
        self.sprite_frame_h = def.height;
        return true;
    }

    /// SPRITE END — restore normal screen drawing after a beginSpriteCanvas()
    /// call.  Automatically flushes the staged pixels to the GPU atlas via the
    /// command queue (equivalent to SPRITE COMMIT id).
    pub fn endSpriteCanvas(self: *GraphicsState) void {
        const id = self.sprite_canvas_id;
        self.sprite_canvas_buf = null;
        self.sprite_canvas_w = 0;
        self.sprite_canvas_h = 0;
        self.sprite_canvas_id = -1;
        self.sprite_frame_x = 0;
        self.sprite_frame_y = 0;
        self.sprite_frame_w = 0;
        self.sprite_frame_h = 0;

        if (id < 0) return; // Was not in canvas mode — nothing to commit.

        // Enqueue atlas upload (sprite_upload) now that drawing is finished.
        const uid: u16 = @intCast(id);
        if (uid >= sprite.MAX_DEFINITIONS) return;
        if (!self.sprites.definitions[uid].active) return;
        const entries = self.sprites.gpu_atlas_entries orelse return;
        const entry = entries[uid];
        const def = &self.sprites.definitions[uid];
        var cmd = GfxCommand.init(.sprite_upload);
        const pixel_count: usize = @as(usize, def.width) * @as(usize, def.height);
        // Snapshot pixels NOW on the JIT thread before any subsequent SPRITE BEGIN
        // can overwrite the shared staging buffer.
        var pixel_ptr: u64 = 0;
        if (pixel_count > 0) {
            if (self.sprites.staging_buffer) |staging| {
                if (pixel_count <= @as(usize, self.sprites.staging_buffer_size)) {
                    const snap = std.c.malloc(pixel_count);
                    if (snap) |s| {
                        const dst: [*]u8 = @ptrCast(s);
                        @memcpy(dst[0..pixel_count], staging[0..pixel_count]);
                        pixel_ptr = @intFromPtr(s);
                    }
                }
            }
        }
        const payload = sprite.SpriteUploadPayload{
            .atlas_x = @intCast(entry.atlas_x),
            .atlas_y = @intCast(entry.atlas_y),
            .width = def.width,
            .height = def.height,
            .pixel_ptr = pixel_ptr,
        };
        @memcpy(cmd.payload[0..@sizeOf(sprite.SpriteUploadPayload)], std.mem.asBytes(&payload));
        self.enqueueCommand(cmd);
    }

    // ─── FLIP ───────────────────────────────────────────────────────

    /// Enqueue FLIP command — swap front/back buffer.
    pub fn flip(self: *GraphicsState) void {
        self.front ^= 1;
        // Default target follows the new back buffer
        self.target = self.front ^ 1;
        self.enqueueCommand(GfxCommand.init(.flip));
    }

    // ─── Buffer Access ──────────────────────────────────────────────

    /// Get a pointer to the target buffer pixel data.
    /// When a sprite canvas is active, returns the sprite staging buffer instead.
    fn getTargetBuffer(self: *GraphicsState) ?[]u8 {
        if (self.sprite_canvas_buf) |buf| return buf;
        return self.buffers[self.target];
    }

    /// Get the buffer stride (buf_width).
    fn stride(self: *const GraphicsState) u32 {
        return @as(u32, self.buf_width);
    }

    /// Effective drawing width — sprite canvas width when active, else screen buffer width.
    inline fn drawWidth(self: *const GraphicsState) i32 {
        return if (self.sprite_canvas_buf != null)
            @intCast(self.sprite_frame_w)
        else
            @intCast(self.buf_width);
    }

    /// Effective drawing height — sprite canvas height when active, else screen buffer height.
    inline fn drawHeight(self: *const GraphicsState) i32 {
        return if (self.sprite_canvas_buf != null)
            @intCast(self.sprite_frame_h)
        else
            @intCast(self.buf_height);
    }

    /// Effective stride — sprite canvas width when active, else screen buffer width.
    inline fn drawStride(self: *const GraphicsState) u32 {
        return if (self.sprite_canvas_buf != null)
            @as(u32, self.sprite_canvas_w)
        else
            @as(u32, self.buf_width);
    }

    /// Convert (x, y) to buffer offset, returns null if out of bounds.
    /// When a sprite canvas is active, uses sprite dimensions for clipping and stride.
    inline fn pixelOffset(self: *const GraphicsState, x: i32, y: i32) ?u32 {
        if (x < 0 or y < 0) return null;
        const ux: u32 = @intCast(x);
        const uy: u32 = @intCast(y);
        if (self.sprite_canvas_buf != null) {
            if (ux >= self.sprite_frame_w or uy >= self.sprite_frame_h) return null;
            const global_x = ux + self.sprite_frame_x;
            const global_y = uy + self.sprite_frame_y;
            return global_y * @as(u32, self.sprite_canvas_w) + global_x;
        }
        if (ux >= self.buf_width or uy >= self.buf_height) return null;
        return uy * self.stride() + ux;
    }

    // ─── Resolution / Overscan ──────────────────────────────────────

    /// Calculate overscan dimensions for a given logical resolution.
    pub fn calcOverscan(w: u16, h: u16) struct { bw: u16, bh: u16, ox: u16, oy: u16 } {
        // 10% extra on each side, minimum 64px total margin
        var ox = w / 10;
        if (ox < MIN_OVERSCAN / 2) ox = MIN_OVERSCAN / 2;
        // Round up to multiple of 16 for GPU alignment
        ox = (ox + 15) & ~@as(u16, 15);

        var oy = h / 10;
        if (oy < MIN_OVERSCAN / 2) oy = MIN_OVERSCAN / 2;
        oy = (oy + 15) & ~@as(u16, 15);

        return .{
            .bw = w + ox * 2,
            .bh = h + oy * 2,
            .ox = ox,
            .oy = oy,
        };
    }

    /// Clear all buffer/palette pointers (set to null/empty).
    ///
    /// Called when the ObjC bridge releases the shared MTLBuffers
    /// (window close, buffer reallocation) so that the Zig side does
    /// not hold dangling pointers into freed GPU memory.
    pub fn clearBufferPointers(self: *GraphicsState) void {
        for (&self.buffers) |*b| {
            b.* = null;
        }
        self.line_palette = null;
        self.line_palette_len = 0;
        self.global_palette = null;
        self.palette_effects = null;
        self.collision_flags = null;
    }

    /// Set the resolution and calculate overscan.
    pub fn setResolution(self: *GraphicsState, w: u16, h: u16) void {
        const ov = calcOverscan(w, h);
        self.width = w;
        self.height = h;
        self.buf_width = ov.bw;
        self.buf_height = ov.bh;
        self.overscan_x = ov.ox;
        self.overscan_y = ov.oy;
        self.scroll_x = 0;
        self.scroll_y = 0;
        self.target = 1;
        self.front = 0;
        self.determinePAR();
    }

    /// Set the buffer pointers from shared MTLBuffer contents.
    /// Called after the ObjC bridge allocates shared buffers.
    pub fn setBufferPointer(self: *GraphicsState, index: u3, ptr: [*]u8, size: usize) void {
        self.buffers[index] = ptr[0..size];
    }

    /// Set the palette pointers from shared MTLBuffer contents.
    pub fn setLinePalettePointer(self: *GraphicsState, ptr: [*]LineColours, len: u32) void {
        self.line_palette = ptr;
        self.line_palette_len = len;
    }

    pub fn setGlobalPalettePointer(self: *GraphicsState, ptr: *[240]RGBA32) void {
        self.global_palette = ptr;
    }

    pub fn setPaletteEffectsPointer(self: *GraphicsState, ptr: *[MAX_PALETTE_EFFECTS]PaletteEffect) void {
        self.palette_effects = ptr;
    }

    pub fn setCollisionFlagsPointer(self: *GraphicsState, ptr: [*]u32) void {
        self.collision_flags = ptr;
    }

    // ─── PAR Correction ─────────────────────────────────────────────

    pub fn determinePAR(self: *GraphicsState) void {
        if (!self.par_enabled or self.screen_mode == .square) {
            self.par_numerator = 1;
            self.par_denominator = 1;
            return;
        }
        for (par_table) |entry| {
            if (entry.w == self.width and entry.h == self.height) {
                self.par_numerator = entry.par_num;
                self.par_denominator = entry.par_den;
                return;
            }
        }
        // Default: square pixels
        self.par_numerator = 1;
        self.par_denominator = 1;
    }

    // ─── Default Palettes ───────────────────────────────────────────

    pub fn initDefaultPalettes(self: *GraphicsState) void {
        self.initDefaultLinePalette();
        self.initDefaultGlobalPalette();
    }

    fn initDefaultLinePalette(self: *GraphicsState) void {
        const pal = self.line_palette orelse return;

        const default_line: LineColours = .{
            RGBA32.TRANSPARENT, // 0: always transparent
            RGBA32.BLACK, // 1: always black
            RGBA32.WHITE, // 2: white
            RGBA32.init(255, 0, 0), // 3: red
            RGBA32.init(0, 255, 0), // 4: green
            RGBA32.init(0, 0, 255), // 5: blue
            RGBA32.init(255, 255, 0), // 6: yellow
            RGBA32.init(0, 255, 255), // 7: cyan
            RGBA32.init(255, 0, 255), // 8: magenta
            RGBA32.init(255, 128, 0), // 9: orange
            RGBA32.init(170, 0, 0), // 10: dark red
            RGBA32.init(0, 170, 0), // 11: dark green
            RGBA32.init(0, 0, 170), // 12: dark blue
            RGBA32.init(170, 170, 170), // 13: grey
            RGBA32.init(85, 85, 85), // 14: dark grey
            RGBA32.init(200, 200, 200), // 15: light grey
        };

        for (0..self.line_palette_len) |i| {
            pal[i] = default_line;
        }
    }

    fn initDefaultGlobalPalette(self: *GraphicsState) void {
        const gpal = self.global_palette orelse return;

        // Indices 16–231: 6×6×6 RGB colour cube (xterm-256 style)
        // Maps to gpal[0..215] (since gpal index = palette_index - 16)
        var idx: usize = 0;
        for (0..6) |ri| {
            for (0..6) |gi| {
                for (0..6) |bi| {
                    const component = [_]u8{ 0, 51, 102, 153, 204, 255 };
                    gpal[idx] = RGBA32.init(component[ri], component[gi], component[bi]);
                    idx += 1;
                }
            }
        }

        // Indices 232–255: 24-step greyscale ramp
        // Maps to gpal[216..239]
        for (0..24) |i| {
            const v: u8 = @intCast(i * 10 + 8);
            gpal[216 + i] = RGBA32.init(v, v, v);
        }
    }

    // ─── Palette Access ─────────────────────────────────────────────

    /// Set a global palette entry (indices 16–255).
    /// Indices 0 and 1 are fixed; calls with index < 16 are ignored.
    pub fn setPalette(self: *GraphicsState, index: u8, r: u8, g: u8, b: u8) void {
        if (index < 16) return; // Per-line palette or fixed
        const gpal = self.global_palette orelse return;
        gpal[index - 16] = RGBA32.init(r, g, b);
    }

    /// Set a per-line palette entry (indices 2–15 for a specific scanline).
    pub fn setLinePalette(self: *GraphicsState, scan_line: u16, index: u8, r: u8, g: u8, b: u8) void {
        if (index < 2 or index > 15) return; // 0 and 1 are fixed
        const pal = self.line_palette orelse return;
        if (scan_line >= self.line_palette_len) return;
        pal[scan_line][index] = RGBA32.init(r, g, b);
    }

    /// Get a global palette entry as packed u32.
    pub fn getPalette(self: *const GraphicsState, index: u8) u32 {
        if (index == 0) return RGBA32.TRANSPARENT.pack();
        if (index == 1) return RGBA32.BLACK.pack();
        if (index < 16) {
            // Return line 0's value as representative
            const pal = self.line_palette orelse return 0;
            return pal[0][index].pack();
        }
        const gpal = self.global_palette orelse return 0;
        return gpal[index - 16].pack();
    }

    /// Get a per-line palette entry as packed u32.
    pub fn getLinePalette(self: *const GraphicsState, scan_line: u16, index: u8) u32 {
        if (index == 0) return RGBA32.TRANSPARENT.pack();
        if (index == 1) return RGBA32.BLACK.pack();
        if (index > 15) return self.getPalette(index);
        const pal = self.line_palette orelse return 0;
        if (scan_line >= self.line_palette_len) return 0;
        return pal[scan_line][index].pack();
    }

    /// Reset all palettes to defaults.
    pub fn resetPalette(self: *GraphicsState) void {
        self.initDefaultPalettes();
    }

    // ─── Palette Effects ────────────────────────────────────────────

    /// Install a palette animation effect (enqueues via command queue).
    pub fn installEffect(self: *GraphicsState, slot: u5, effect: PaletteEffect) void {
        var cmd = GfxCommand.init(.install_effect);
        var payload: InstallEffectPayload = undefined;
        payload.slot = slot;
        payload._pad = [_]u8{0} ** 3;
        payload.effect = effect;
        @memcpy(cmd.payload[0..@sizeOf(InstallEffectPayload)], std.mem.asBytes(&payload));
        self.enqueueCommand(cmd);
    }

    /// Stop a specific effect slot.
    pub fn stopEffect(self: *GraphicsState, slot: u5) void {
        var cmd = GfxCommand.init(.stop_effect);
        cmd.payload[0] = slot;
        self.enqueueCommand(cmd);
    }

    /// Stop all palette effects.
    pub fn stopAllEffects(self: *GraphicsState) void {
        self.enqueueCommand(GfxCommand.init(.stop_all_effects));
    }

    /// Pause an effect.
    pub fn pauseEffect(self: *GraphicsState, slot: u5) void {
        var cmd = GfxCommand.init(.pause_effect);
        cmd.payload[0] = slot;
        self.enqueueCommand(cmd);
    }

    /// Resume a paused effect.
    pub fn resumeEffect(self: *GraphicsState, slot: u5) void {
        var cmd = GfxCommand.init(.resume_effect);
        cmd.payload[0] = slot;
        self.enqueueCommand(cmd);
    }

    // ─── Drawing Primitives (direct shared memory writes) ───────────

    /// PSET — plot a single pixel.
    /// In sprite canvas mode the colour is masked to 0–15 (atlas palette indices).
    pub fn pset(self: *GraphicsState, x: i32, y: i32, c: u8) void {
        const buf = self.getTargetBuffer() orelse return;
        const off = self.pixelOffset(x, y) orelse return;
        buf[off] = if (self.sprite_canvas_buf != null) (c & 0x0F) else c;
    }

    /// PGET — read the palette index of a pixel.
    pub fn pget(self: *GraphicsState, x: i32, y: i32) u8 {
        const buf = self.getTargetBuffer() orelse return 0;
        const off = self.pixelOffset(x, y) orelse return 0;
        return buf[off];
    }

    /// GCLS — clear the current target buffer to a colour index.
    pub fn clear(self: *GraphicsState, colour: u8) void {
        const buf = self.getTargetBuffer() orelse return;
        const col = if (self.sprite_canvas_buf != null) (colour & 0x0F) else colour;

        if (self.sprite_canvas_buf != null) {
            // Only clear the active frame viewport
            var y: u32 = 0;
            while (y < self.sprite_frame_h) : (y += 1) {
                const global_y = y + self.sprite_frame_y;
                const row_start = global_y * @as(u32, self.sprite_canvas_w) + self.sprite_frame_x;
                @memset(buf[row_start .. row_start + self.sprite_frame_w], col);
            }
        } else {
            @memset(buf, col);
        }
    }

    /// LINE — draw a line using Bresenham's algorithm.
    pub fn line(self: *GraphicsState, x1: i32, y1: i32, x2: i32, y2: i32, c: u8) void {
        var x = x1;
        var y = y1;
        const dx = if (x2 > x1) x2 - x1 else x1 - x2;
        const dy = if (y2 > y1) y2 - y1 else y1 - y2;
        const sx: i32 = if (x1 < x2) 1 else -1;
        const sy: i32 = if (y1 < y2) 1 else -1;
        var err = dx - dy;

        while (true) {
            self.pset(x, y, c);
            if (x == x2 and y == y2) break;
            const e2 = err * 2;
            if (e2 > -dy) {
                err -= dy;
                x += sx;
            }
            if (e2 < dx) {
                err += dx;
                y += sy;
            }
        }
    }

    /// RECT — draw a rectangle (filled or outlined).
    pub fn rect(self: *GraphicsState, x1: i32, y1: i32, x2: i32, y2: i32, c: u8, filled: bool) void {
        const left = @min(x1, x2);
        const right = @max(x1, x2);
        const top = @min(y1, y2);
        const bottom = @max(y1, y2);

        if (filled) {
            self.hlineFill(left, right, top, bottom, c);
        } else {
            // Top and bottom edges
            self.hline(left, right, top, c);
            self.hline(left, right, bottom, c);
            // Left and right edges
            var y = top + 1;
            while (y < bottom) : (y += 1) {
                self.pset(left, y, c);
                self.pset(right, y, c);
            }
        }
    }

    /// Internal: draw a horizontal line.
    fn hline(self: *GraphicsState, x1: i32, x2: i32, y: i32, c: u8) void {
        const buf = self.getTargetBuffer() orelse return;
        if (y < 0 or y >= self.drawHeight()) return;
        const left = @max(x1, 0);
        const right = @min(x2, self.drawWidth() - 1);
        if (left > right) return;

        const ul: u32 = @intCast(left);
        const ur: u32 = @intCast(right);
        const uy: u32 = @intCast(y);
        const s = self.drawStride();

        var start: u32 = 0;
        var end: u32 = 0;

        if (self.sprite_canvas_buf != null) {
            const global_y = uy + self.sprite_frame_y;
            const global_x_start = ul + self.sprite_frame_x;
            const global_x_end = ur + self.sprite_frame_x;
            start = global_y * s + global_x_start;
            end = global_y * s + global_x_end + 1;
        } else {
            start = uy * s + ul;
            end = uy * s + ur + 1;
        }

        const col = if (self.sprite_canvas_buf != null) (c & 0x0F) else c;
        @memset(buf[start..end], col);
    }

    /// Internal: fill a rectangular region with horizontal lines.
    fn hlineFill(self: *GraphicsState, left: i32, right: i32, top: i32, bottom: i32, c: u8) void {
        var y = top;
        while (y <= bottom) : (y += 1) {
            self.hline(left, right, y, c);
        }
    }

    /// CIRCLE — draw a circle using the midpoint algorithm.
    pub fn circle(self: *GraphicsState, cx: i32, cy: i32, r: i32, c: u8, filled: bool) void {
        if (r <= 0) {
            self.pset(cx, cy, c);
            return;
        }
        var x: i32 = 0;
        var y: i32 = r;
        var d: i32 = 1 - r;

        if (filled) {
            while (x <= y) {
                self.hline(cx - x, cx + x, cy + y, c);
                self.hline(cx - x, cx + x, cy - y, c);
                self.hline(cx - y, cx + y, cy + x, c);
                self.hline(cx - y, cx + y, cy - x, c);
                if (d < 0) {
                    d += 2 * x + 3;
                } else {
                    d += 2 * (x - y) + 5;
                    y -= 1;
                }
                x += 1;
            }
        } else {
            while (x <= y) {
                self.pset(cx + x, cy + y, c);
                self.pset(cx - x, cy + y, c);
                self.pset(cx + x, cy - y, c);
                self.pset(cx - x, cy - y, c);
                self.pset(cx + y, cy + x, c);
                self.pset(cx - y, cy + x, c);
                self.pset(cx + y, cy - x, c);
                self.pset(cx - y, cy - x, c);
                if (d < 0) {
                    d += 2 * x + 3;
                } else {
                    d += 2 * (x - y) + 5;
                    y -= 1;
                }
                x += 1;
            }
        }
    }

    /// ELLIPSE — draw an ellipse.
    pub fn ellipse(self: *GraphicsState, cx: i32, cy: i32, rx: i32, ry: i32, c: u8, filled: bool) void {
        if (rx <= 0 and ry <= 0) {
            self.pset(cx, cy, c);
            return;
        }
        if (rx == ry) {
            self.circle(cx, cy, rx, c, filled);
            return;
        }

        // Midpoint ellipse algorithm
        var x: i64 = 0;
        var y: i64 = @intCast(ry);
        const a: i64 = @intCast(rx);
        const b: i64 = @intCast(ry);
        const a2 = a * a;
        const b2 = b * b;

        // Region 1
        var dx: i64 = 2 * b2 * x;
        var dy: i64 = 2 * a2 * y;
        var d1: i64 = b2 - a2 * b + @divTrunc(a2, 4);

        while (dx < dy) {
            if (filled) {
                self.hline(cx - @as(i32, @intCast(x)), cx + @as(i32, @intCast(x)), cy + @as(i32, @intCast(y)), c);
                self.hline(cx - @as(i32, @intCast(x)), cx + @as(i32, @intCast(x)), cy - @as(i32, @intCast(y)), c);
            } else {
                const xi: i32 = @intCast(x);
                const yi: i32 = @intCast(y);
                self.pset(cx + xi, cy + yi, c);
                self.pset(cx - xi, cy + yi, c);
                self.pset(cx + xi, cy - yi, c);
                self.pset(cx - xi, cy - yi, c);
            }
            if (d1 < 0) {
                x += 1;
                dx = 2 * b2 * x;
                d1 += dx + b2;
            } else {
                x += 1;
                y -= 1;
                dx = 2 * b2 * x;
                dy = 2 * a2 * y;
                d1 += dx - dy + b2;
            }
        }

        // Region 2
        var d2: i64 = b2 * (2 * x + 1) * (2 * x + 1) + 4 * a2 * (y - 1) * (y - 1) - 4 * a2 * b2;
        d2 = @divTrunc(d2, 4);

        while (y >= 0) {
            if (filled) {
                self.hline(cx - @as(i32, @intCast(x)), cx + @as(i32, @intCast(x)), cy + @as(i32, @intCast(y)), c);
                self.hline(cx - @as(i32, @intCast(x)), cx + @as(i32, @intCast(x)), cy - @as(i32, @intCast(y)), c);
            } else {
                const xi: i32 = @intCast(x);
                const yi: i32 = @intCast(y);
                self.pset(cx + xi, cy + yi, c);
                self.pset(cx - xi, cy + yi, c);
                self.pset(cx + xi, cy - yi, c);
                self.pset(cx - xi, cy - yi, c);
            }
            if (d2 > 0) {
                y -= 1;
                dy = 2 * a2 * y;
                d2 -= dy + a2;
            } else {
                y -= 1;
                x += 1;
                dx = 2 * b2 * x;
                dy = 2 * a2 * y;
                d2 += dx - dy + a2;
            }
        }
    }

    /// TRIANGLE — draw a triangle (filled or outlined).
    pub fn triangle(self: *GraphicsState, x1: i32, y1: i32, x2: i32, y2: i32, x3: i32, y3: i32, c: u8, filled: bool) void {
        if (filled) {
            self.fillTriangle(x1, y1, x2, y2, x3, y3, c);
        } else {
            self.line(x1, y1, x2, y2, c);
            self.line(x2, y2, x3, y3, c);
            self.line(x3, y3, x1, y1, c);
        }
    }

    /// Internal: filled triangle via scanline rasterisation.
    fn fillTriangle(self: *GraphicsState, x1: i32, y1: i32, x2: i32, y2: i32, x3: i32, y3: i32, c: u8) void {
        // Sort vertices by y-coordinate
        var vx = [3]i32{ x1, x2, x3 };
        var vy = [3]i32{ y1, y2, y3 };

        // Simple bubble sort (3 elements)
        if (vy[0] > vy[1]) {
            std.mem.swap(i32, &vx[0], &vx[1]);
            std.mem.swap(i32, &vy[0], &vy[1]);
        }
        if (vy[1] > vy[2]) {
            std.mem.swap(i32, &vx[1], &vx[2]);
            std.mem.swap(i32, &vy[1], &vy[2]);
        }
        if (vy[0] > vy[1]) {
            std.mem.swap(i32, &vx[0], &vx[1]);
            std.mem.swap(i32, &vy[0], &vy[1]);
        }

        const total_height = vy[2] - vy[0];
        if (total_height == 0) {
            // Degenerate: horizontal line
            self.hline(@min(vx[0], @min(vx[1], vx[2])), @max(vx[0], @max(vx[1], vx[2])), vy[0], c);
            return;
        }

        // Scan from top to bottom
        var y = vy[0];
        while (y <= vy[2]) : (y += 1) {
            const second_half = y > vy[1] or vy[1] == vy[0];
            const segment_height = if (second_half) vy[2] - vy[1] else vy[1] - vy[0];
            if (segment_height == 0) continue;

            const alpha_num = y - vy[0];
            const beta_num = if (second_half) y - vy[1] else y - vy[0];

            var a_x = vx[0] + @divTrunc(alpha_num * (vx[2] - vx[0]), total_height);
            var b_x: i32 = undefined;
            if (second_half) {
                b_x = vx[1] + @divTrunc(beta_num * (vx[2] - vx[1]), segment_height);
            } else {
                b_x = vx[0] + @divTrunc(beta_num * (vx[1] - vx[0]), segment_height);
            }

            if (a_x > b_x) std.mem.swap(i32, &a_x, &b_x);
            self.hline(a_x, b_x, y, c);
        }
    }

    /// FILLAREA — flood fill from seed point.
    /// Uses a scanline-based algorithm with an explicit stack.
    pub fn fillArea(self: *GraphicsState, x: i32, y: i32, c: u8) void {
        const buf = self.getTargetBuffer() orelse return;
        const off = self.pixelOffset(x, y) orelse return;
        const target_colour = buf[off];
        const col = if (self.sprite_canvas_buf != null) (c & 0x0F) else c;
        if (target_colour == col) return; // Already the fill colour

        // Explicit stack for flood fill (avoids recursion)
        const max_stack = 4096;
        var stack: [max_stack]struct { x: i32, y: i32 } = undefined;
        var sp: u32 = 0;

        stack[0] = .{ .x = x, .y = y };
        sp = 1;

        const bw: i32 = self.drawWidth();
        const bh: i32 = self.drawHeight();
        const s = self.drawStride();

        while (sp > 0) {
            sp -= 1;
            const pt = stack[sp];
            var sx = pt.x;
            const sy = pt.y;

            if (sy < 0 or sy >= bh) continue;

            // Find the leftmost pixel in this scanline
            while (sx > 0) {
                const prev_off = @as(u32, @intCast(sy)) * s + @as(u32, @intCast(sx - 1));
                if (buf[prev_off] != target_colour) break;
                sx -= 1;
            }

            var span_up = false;
            var span_down = false;

            while (sx < bw) {
                const cur_off = @as(u32, @intCast(sy)) * s + @as(u32, @intCast(sx));
                if (buf[cur_off] != target_colour) break;
                buf[cur_off] = col;

                // Check above
                if (sy > 0) {
                    const above_off = @as(u32, @intCast(sy - 1)) * s + @as(u32, @intCast(sx));
                    if (buf[above_off] == target_colour) {
                        if (!span_up and sp < max_stack) {
                            stack[sp] = .{ .x = sx, .y = sy - 1 };
                            sp += 1;
                            span_up = true;
                        }
                    } else {
                        span_up = false;
                    }
                }

                // Check below
                if (sy < bh - 1) {
                    const below_off = @as(u32, @intCast(sy + 1)) * s + @as(u32, @intCast(sx));
                    if (buf[below_off] == target_colour) {
                        if (!span_down and sp < max_stack) {
                            stack[sp] = .{ .x = sx, .y = sy + 1 };
                            sp += 1;
                            span_down = true;
                        }
                    } else {
                        span_down = false;
                    }
                }

                sx += 1;
            }
        }
    }

    /// GSCROLL — shift buffer contents by (dx, dy), fill exposed edges.
    pub fn scrollBuffer(self: *GraphicsState, dx: i32, dy: i32, fill_c: u8) void {
        const buf = self.getTargetBuffer() orelse return;
        const w: i32 = @intCast(self.buf_width);
        const h: i32 = @intCast(self.buf_height);
        const s = self.stride();

        if (@abs(dx) >= @as(u32, @intCast(w)) or @abs(dy) >= @as(u32, @intCast(h))) {
            // Scrolled completely off — just fill
            @memset(buf, fill_c);
            return;
        }

        // Copy in the correct order to avoid overwriting source data
        if (dy > 0) {
            // Scrolling down — copy from bottom to top
            var y: i32 = h - 1;
            while (y >= 0) : (y -= 1) {
                const src_y = y - dy;
                if (src_y < 0 or src_y >= h) {
                    // Fill row
                    const row_start: u32 = @intCast(y);
                    @memset(buf[row_start * s .. row_start * s + @as(u32, @intCast(w))], fill_c);
                } else {
                    self.scrollRow(buf, y, src_y, dx, fill_c, w, s);
                }
            }
        } else {
            // Scrolling up or no vertical scroll — copy from top to bottom
            var y: i32 = 0;
            while (y < h) : (y += 1) {
                const src_y = y - dy;
                if (src_y < 0 or src_y >= h) {
                    const row_start: u32 = @intCast(y);
                    @memset(buf[row_start * s .. row_start * s + @as(u32, @intCast(w))], fill_c);
                } else {
                    self.scrollRow(buf, y, src_y, dx, fill_c, w, s);
                }
            }
        }
    }

    fn scrollRow(_: *GraphicsState, buf: []u8, dst_y: i32, src_y: i32, dx: i32, fill_c: u8, w: i32, s: u32) void {
        const dst_start: u32 = @intCast(dst_y);
        const src_start: u32 = @intCast(src_y);

        if (dx > 0) {
            // Scrolling right — copy right to left within row
            const copy_w: u32 = @intCast(w - dx);
            const dst_off = dst_start * s + @as(u32, @intCast(dx));
            const src_off = src_start * s;
            // Use a temporary approach: memmove semantics
            std.mem.copyBackwards(u8, buf[dst_off .. dst_off + copy_w], buf[src_off .. src_off + copy_w]);
            // Fill the left edge
            @memset(buf[dst_start * s .. dst_start * s + @as(u32, @intCast(dx))], fill_c);
        } else if (dx < 0) {
            // Scrolling left — copy left to right within row
            const adx: u32 = @intCast(-dx);
            const copy_w: u32 = @intCast(w + dx);
            const dst_off = dst_start * s;
            const src_off = src_start * s + adx;
            std.mem.copyForwards(u8, buf[dst_off .. dst_off + copy_w], buf[src_off .. src_off + copy_w]);
            // Fill the right edge
            const fill_start = dst_start * s + copy_w;
            @memset(buf[fill_start .. fill_start + adx], fill_c);
        } else {
            // No horizontal scroll — just copy the row
            if (dst_y != src_y) {
                const uw: u32 = @intCast(w);
                @memcpy(buf[dst_start * s .. dst_start * s + uw], buf[src_start * s .. src_start * s + uw]);
            }
        }
    }

    // ─── Blit Operations ────────────────────────────────────────────

    /// BLIT — copy region with index 0 as transparent.
    pub fn blit(self: *GraphicsState, dst: u3, dx: i32, dy: i32, src: u3, sx: i32, sy: i32, w: i32, h: i32) void {
        const src_buf = self.buffers[src] orelse return;
        const dst_buf = self.buffers[dst] orelse return;
        const s = self.stride();
        const bw: i32 = @intCast(self.buf_width);
        const bh: i32 = @intCast(self.buf_height);

        var row: i32 = 0;
        while (row < h) : (row += 1) {
            const src_y = sy + row;
            const dst_y = dy + row;
            if (src_y < 0 or src_y >= bh or dst_y < 0 or dst_y >= bh) continue;

            var col: i32 = 0;
            while (col < w) : (col += 1) {
                const src_x = sx + col;
                const dst_x = dx + col;
                if (src_x < 0 or src_x >= bw or dst_x < 0 or dst_x >= bw) continue;

                const src_off = @as(u32, @intCast(src_y)) * s + @as(u32, @intCast(src_x));
                const pixel = src_buf[src_off];
                if (pixel != 0) { // Index 0 = transparent
                    const dst_off = @as(u32, @intCast(dst_y)) * s + @as(u32, @intCast(dst_x));
                    dst_buf[dst_off] = pixel;
                }
            }
        }
    }

    /// BLITSOLID — copy region including index 0 (all pixels).
    pub fn blitSolid(self: *GraphicsState, dst: u3, dx: i32, dy: i32, src: u3, sx: i32, sy: i32, w: i32, h: i32) void {
        const src_buf = self.buffers[src] orelse return;
        const dst_buf = self.buffers[dst] orelse return;
        const s = self.stride();
        const bw: i32 = @intCast(self.buf_width);
        const bh: i32 = @intCast(self.buf_height);

        var row: i32 = 0;
        while (row < h) : (row += 1) {
            const src_y = sy + row;
            const dst_y = dy + row;
            if (src_y < 0 or src_y >= bh or dst_y < 0 or dst_y >= bh) continue;

            // Clip horizontal range
            var cl: i32 = 0;
            var cr: i32 = w;
            if (sx + cl < 0) cl = -sx;
            if (dx + cl < 0) cl = -dx;
            if (sx + cr > bw) cr = bw - sx;
            if (dx + cr > bw) cr = bw - dx;
            if (cl >= cr) continue;

            const src_off = @as(u32, @intCast(src_y)) * s + @as(u32, @intCast(sx + cl));
            const dst_off = @as(u32, @intCast(dst_y)) * s + @as(u32, @intCast(dx + cl));
            const copy_len: u32 = @intCast(cr - cl);
            @memcpy(dst_buf[dst_off .. dst_off + copy_len], src_buf[src_off .. src_off + copy_len]);
        }
    }

    /// BLITSCALE — scaled blit with nearest-neighbour interpolation.
    pub fn blitScale(self: *GraphicsState, dst: u3, dst_x: i32, dst_y: i32, dw: i32, dh: i32, src: u3, src_x: i32, src_y: i32, sw: i32, sh: i32) void {
        const src_buf = self.buffers[src] orelse return;
        const dst_buf = self.buffers[dst] orelse return;
        const s = self.stride();
        const bw: i32 = @intCast(self.buf_width);
        const bh: i32 = @intCast(self.buf_height);

        if (dw <= 0 or dh <= 0 or sw <= 0 or sh <= 0) return;

        var dy: i32 = 0;
        while (dy < dh) : (dy += 1) {
            const out_y = dst_y + dy;
            if (out_y < 0 or out_y >= bh) continue;
            const sample_y = src_y + @divTrunc(dy * sh, dh);
            if (sample_y < 0 or sample_y >= bh) continue;

            var dx: i32 = 0;
            while (dx < dw) : (dx += 1) {
                const out_x = dst_x + dx;
                if (out_x < 0 or out_x >= bw) continue;
                const sample_x = src_x + @divTrunc(dx * sw, dw);
                if (sample_x < 0 or sample_x >= bw) continue;

                const src_off = @as(u32, @intCast(sample_y)) * s + @as(u32, @intCast(sample_x));
                const pixel = src_buf[src_off];
                if (pixel != 0) {
                    const dst_off = @as(u32, @intCast(out_y)) * s + @as(u32, @intCast(out_x));
                    dst_buf[dst_off] = pixel;
                }
            }
        }
    }

    /// BLITFLIP — blit with horizontal/vertical flip.
    /// mode: 1 = horizontal, 2 = vertical, 3 = both.
    pub fn blitFlip(self: *GraphicsState, dst: u3, dx: i32, dy: i32, src: u3, sx: i32, sy: i32, w: i32, h: i32, mode: u8) void {
        const src_buf = self.buffers[src] orelse return;
        const dst_buf = self.buffers[dst] orelse return;
        const s = self.stride();
        const bw: i32 = @intCast(self.buf_width);
        const bh: i32 = @intCast(self.buf_height);

        const flip_h = (mode & 1) != 0;
        const flip_v = (mode & 2) != 0;

        var row: i32 = 0;
        while (row < h) : (row += 1) {
            const src_row = if (flip_v) sy + (h - 1 - row) else sy + row;
            const dst_row = dy + row;
            if (src_row < 0 or src_row >= bh or dst_row < 0 or dst_row >= bh) continue;

            var col: i32 = 0;
            while (col < w) : (col += 1) {
                const src_col = if (flip_h) sx + (w - 1 - col) else sx + col;
                const dst_col = dx + col;
                if (src_col < 0 or src_col >= bw or dst_col < 0 or dst_col >= bw) continue;

                const src_off = @as(u32, @intCast(src_row)) * s + @as(u32, @intCast(src_col));
                const pixel = src_buf[src_off];
                if (pixel != 0) {
                    const dst_off = @as(u32, @intCast(dst_row)) * s + @as(u32, @intCast(dst_col));
                    dst_buf[dst_off] = pixel;
                }
            }
        }
    }

    // ─── Text Rendering ─────────────────────────────────────────────

    /// DRAWTEXT — render a string at pixel (x, y) using the built-in font.
    ///
    /// The input slice is UTF-8.  ASCII bytes (0x00–0x7F) map directly to
    /// the CP437 font table.  Multi-byte UTF-8 sequences are decoded and
    /// mapped to the closest CP437 equivalent where one exists (e.g.
    /// U+2014 em dash → 0x2D '-').  Unmapped codepoints render as '?'.
    /// Malformed continuation bytes are silently skipped so a stray
    /// high byte never produces a garbage glyph.
    pub fn drawText(self: *GraphicsState, x: i32, y: i32, text: []const u8, c: u8, font_id: u1) void {
        const font_h: i32 = @intCast(font.getFontHeight(font_id));
        var cx: i32 = x;
        var i: usize = 0;

        while (i < text.len) {
            const b = text[i];

            var glyph_byte: u8 = undefined;

            if (b < 0x80) {
                // Plain ASCII — direct CP437 lookup.
                glyph_byte = b;
                i += 1;
            } else {
                // Decode a multi-byte UTF-8 sequence.
                const decoded = utf8Decode(text[i..]);
                i += decoded.len;
                glyph_byte = unicodeToCp437(decoded.codepoint);
            }

            const glyph = font.getGlyph(glyph_byte, font_id);

            var row: i32 = 0;
            while (row < font_h) : (row += 1) {
                const row_byte = glyph[@intCast(row)];
                if (row_byte == 0) continue; // Skip empty rows

                inline for (0..8) |bit| {
                    if (row_byte & (@as(u8, 0x80) >> bit) != 0) {
                        self.pset(cx + @as(i32, bit), y + row, c);
                    }
                }
            }

            cx += font.FONT_WIDTH;
        }
    }

    // ─── UTF-8 helpers for drawText ─────────────────────────────────

    const Utf8Decoded = struct { codepoint: u21, len: u3 };

    /// Decode one UTF-8 codepoint starting at `s[0]`.
    /// Returns the codepoint and the number of bytes consumed.
    /// On malformed input returns U+FFFD and advances 1 byte.
    fn utf8Decode(s: []const u8) Utf8Decoded {
        if (s.len == 0) return .{ .codepoint = 0xFFFD, .len = 1 };
        const b0 = s[0];

        if (b0 < 0x80) return .{ .codepoint = b0, .len = 1 };

        if (b0 & 0xE0 == 0xC0) {
            // 2-byte sequence
            if (s.len < 2 or (s[1] & 0xC0 != 0x80))
                return .{ .codepoint = 0xFFFD, .len = 1 };
            const cp: u21 = (@as(u21, b0 & 0x1F) << 6) | (s[1] & 0x3F);
            return .{ .codepoint = cp, .len = 2 };
        }

        if (b0 & 0xF0 == 0xE0) {
            // 3-byte sequence
            if (s.len < 3 or (s[1] & 0xC0 != 0x80) or (s[2] & 0xC0 != 0x80))
                return .{ .codepoint = 0xFFFD, .len = 1 };
            const cp: u21 = (@as(u21, b0 & 0x0F) << 12) |
                (@as(u21, s[1] & 0x3F) << 6) |
                (s[2] & 0x3F);
            return .{ .codepoint = cp, .len = 3 };
        }

        if (b0 & 0xF8 == 0xF0) {
            // 4-byte sequence
            if (s.len < 4 or (s[1] & 0xC0 != 0x80) or (s[2] & 0xC0 != 0x80) or (s[3] & 0xC0 != 0x80))
                return .{ .codepoint = 0xFFFD, .len = 1 };
            const cp: u21 = (@as(u21, b0 & 0x07) << 18) |
                (@as(u21, s[1] & 0x3F) << 12) |
                (@as(u21, s[2] & 0x3F) << 6) |
                (s[3] & 0x3F);
            return .{ .codepoint = cp, .len = 4 };
        }

        // Stray continuation byte or invalid lead — skip it.
        return .{ .codepoint = 0xFFFD, .len = 1 };
    }

    /// Map a Unicode codepoint to the best CP437 byte.
    /// Codepoints 0x00–0x7F pass through directly (ASCII).
    /// A selection of common Unicode characters are mapped to their
    /// CP437 equivalents.  Everything else becomes '?' (0x3F).
    fn unicodeToCp437(cp: u21) u8 {
        // ASCII pass-through
        if (cp < 0x80) return @truncate(cp);

        return switch (cp) {
            // Latin-1 Supplement (U+00A0–U+00FF) → CP437
            0x00A0 => 0xFF, // non-breaking space → CP437 NBSP
            0x00A1 => 0xAD, // ¡
            0x00A2 => 0x9B, // ¢
            0x00A3 => 0x9C, // £
            0x00A5 => 0x9D, // ¥
            0x00AA => 0xA6, // ª
            0x00AB => 0xAE, // «
            0x00AC => 0xAA, // ¬
            0x00B0 => 0xF8, // °
            0x00B1 => 0xF1, // ±
            0x00B2 => 0xFD, // ²
            0x00B5 => 0xE6, // µ
            0x00B7 => 0xFA, // ·
            0x00BA => 0xA7, // º
            0x00BB => 0xAF, // »
            0x00BC => 0xAC, // ¼
            0x00BD => 0xAB, // ½
            0x00BF => 0xA8, // ¿
            0x00C4 => 0x8E, // Ä
            0x00C5 => 0x8F, // Å
            0x00C6 => 0x92, // Æ
            0x00C7 => 0x80, // Ç
            0x00C9 => 0x90, // É
            0x00D1 => 0xA5, // Ñ
            0x00D6 => 0x99, // Ö
            0x00DC => 0x9A, // Ü
            0x00DF => 0xE1, // ß
            0x00E0 => 0x85, // à
            0x00E1 => 0xA0, // á
            0x00E2 => 0x83, // â
            0x00E4 => 0x84, // ä
            0x00E5 => 0x86, // å
            0x00E6 => 0x91, // æ
            0x00E7 => 0x87, // ç
            0x00E8 => 0x8A, // è
            0x00E9 => 0x82, // é
            0x00EA => 0x88, // ê
            0x00EB => 0x89, // ë
            0x00EC => 0x8D, // ì
            0x00ED => 0xA1, // í
            0x00EE => 0x8C, // î
            0x00EF => 0x8B, // ï
            0x00F1 => 0xA4, // ñ
            0x00F2 => 0x95, // ò
            0x00F3 => 0xA2, // ó
            0x00F4 => 0x93, // ô
            0x00F6 => 0x94, // ö
            0x00F7 => 0xF6, // ÷
            0x00F9 => 0x97, // ù
            0x00FA => 0xA3, // ú
            0x00FB => 0x96, // û
            0x00FC => 0x81, // ü
            0x00FF => 0x98, // ÿ

            // Greek letters used in maths/science
            0x0393 => 0xE2, // Γ
            0x0398 => 0xE9, // Θ
            0x03A3 => 0xE4, // Σ
            0x03A6 => 0xE8, // Φ
            0x03A9 => 0xEA, // Ω
            0x03B1 => 0xE0, // α
            0x03B4 => 0xEB, // δ
            0x03B5 => 0xEE, // ε
            0x03C0 => 0xE3, // π
            0x03C3 => 0xE5, // σ
            0x03C4 => 0xE7, // τ
            0x03C6 => 0xED, // φ

            // Dashes — map to CP437 hyphen-minus
            0x2012 => 0x2D, // figure dash → -
            0x2013 => 0x2D, // en dash → -
            0x2014 => 0x2D, // em dash → -
            0x2015 => 0x2D, // horizontal bar → -

            // Quotation marks
            0x2018 => 0x60, // ' left single → `
            0x2019 => 0x27, // ' right single → '
            0x201C => 0x22, // " left double → "
            0x201D => 0x22, // " right double → "

            // Bullets and ellipsis
            0x2022 => 0x07, // • bullet → CP437 bullet
            0x2026 => 0x2E, // … ellipsis → .

            // Arrows
            0x2190 => 0x1B, // ← leftward
            0x2191 => 0x18, // ↑ upward
            0x2192 => 0x1A, // → rightward
            0x2193 => 0x19, // ↓ downward
            0x2194 => 0x1D, // ↔ left-right
            0x2195 => 0x12, // ↕ up-down

            // Box drawing (single lines)
            0x2500 => 0xC4, // ─
            0x2502 => 0xB3, // │
            0x250C => 0xDA, // ┌
            0x2510 => 0xBF, // ┐
            0x2514 => 0xC0, // └
            0x2518 => 0xD9, // ┘
            0x251C => 0xC3, // ├
            0x2524 => 0xB4, // ┤
            0x252C => 0xC2, // ┬
            0x2534 => 0xC1, // ┴
            0x253C => 0xC5, // ┼

            // Box drawing (double lines)
            0x2550 => 0xCD, // ═
            0x2551 => 0xBA, // ║
            0x2552 => 0xD5, // ╒
            0x2553 => 0xD6, // ╓
            0x2554 => 0xC9, // ╔
            0x2555 => 0xB8, // ╕
            0x2556 => 0xB7, // ╖
            0x2557 => 0xBB, // ╗
            0x2558 => 0xD4, // ╘
            0x2559 => 0xD3, // ╙
            0x255A => 0xC8, // ╚
            0x255B => 0xBE, // ╛
            0x255C => 0xBD, // ╜
            0x255D => 0xBC, // ╝
            0x255E => 0xC6, // ╞
            0x255F => 0xC7, // ╟
            0x2560 => 0xCC, // ╠
            0x2561 => 0xB5, // ╡
            0x2562 => 0xB6, // ╢
            0x2563 => 0xB9, // ╣
            0x2564 => 0xD1, // ╤
            0x2565 => 0xD2, // ╥
            0x2566 => 0xCB, // ╦
            0x2567 => 0xCF, // ╧
            0x2568 => 0xD0, // ╨
            0x2569 => 0xCA, // ╩
            0x256A => 0xD8, // ╪
            0x256B => 0xD7, // ╫
            0x256C => 0xCE, // ╬

            // Block elements
            0x2580 => 0xDF, // ▀ upper half
            0x2584 => 0xDC, // ▄ lower half
            0x2588 => 0xDB, // █ full block
            0x258C => 0xDD, // ▌ left half
            0x2590 => 0xDE, // ▐ right half
            0x2591 => 0xB0, // ░ light shade
            0x2592 => 0xB1, // ▒ medium shade
            0x2593 => 0xB2, // ▓ dark shade

            // Misc symbols
            0x221A => 0xFB, // √
            0x221E => 0xEC, // ∞
            0x2219 => 0xF9, // ∙
            0x2248 => 0xF7, // ≈
            0x2260 => 0xF0, // ≠  (approx — CP437 has ≡ not ≠, but close)
            0x2264 => 0xF3, // ≤
            0x2265 => 0xF2, // ≥
            0x2310 => 0xA9, // ⌐
            0x2320 => 0xF4, // ⌠
            0x2321 => 0xF5, // ⌡
            0x25A0 => 0xFE, // ■

            // Replacement character itself
            0xFFFD => '?',

            // Everything else → '?'
            else => '?',
        };
    }

    /// Return the pixel width of a string (UTF-8 aware — counts codepoints,
    /// not bytes, so multi-byte sequences count as one glyph width).
    pub fn textWidth(text: []const u8) u32 {
        var count: u32 = 0;
        var i: usize = 0;
        while (i < text.len) {
            const b = text[i];
            if (b < 0x80) {
                i += 1;
            } else {
                const decoded = utf8Decode(text[i..]);
                i += decoded.len;
            }
            count += 1;
        }
        return count * font.FONT_WIDTH;
    }

    /// Return the pixel height of a font.
    pub fn textHeight(font_id: u1) u32 {
        return font.getFontHeight(font_id);
    }

    // ─── Collision ──────────────────────────────────────────────────

    /// Set up batch collision testing.
    pub fn collideSetup(self: *GraphicsState, n: u8) void {
        self.collision_count = if (n > MAX_COLLISION_SOURCES) @intCast(MAX_COLLISION_SOURCES) else n;
    }

    /// Define a collision source.
    pub fn collideSrc(self: *GraphicsState, i: u8, buf_id: u3, x: i16, y: i16, w: u16, h: u16) void {
        if (i >= self.collision_count) return;
        self.collision_sources[i] = .{
            .buffer = buf_id,
            .x = x,
            .y = y,
            .w = w,
            .h = h,
        };
    }

    /// Dispatch batch collision test (enqueue GPU dispatch).
    pub fn collideTest(self: *GraphicsState) void {
        self.enqueueCommand(GfxCommand.init(.collision_dispatch));
    }

    /// Read batch collision result.
    pub fn collideResult(self: *GraphicsState, i: u8, j: u8) bool {
        const flags = self.collision_flags orelse return false;
        if (i >= self.collision_count or j >= self.collision_count) return false;

        // Triangular matrix indexing
        const a: u32 = @min(i, j);
        const b: u32 = @max(i, j);
        if (a == b) return false;
        const idx = b * (b - 1) / 2 + a;
        return flags[idx] != 0;
    }

    /// Single-pair collision dispatch (via command queue).
    pub fn collideSingle(self: *GraphicsState, buf_a: u3, ax: i16, ay: i16, buf_b: u3, bx: i16, by: i16, w: u16, h: u16) void {
        var cmd = GfxCommand.init(.collision_single);
        var payload: CollisionSinglePayload = undefined;
        payload.buf_a = buf_a;
        payload.buf_b = buf_b;
        payload._pad = [_]u8{0} ** 2;
        payload.ax = ax;
        payload.ay = ay;
        payload.bx = bx;
        payload.by = by;
        payload.w = w;
        payload.h = h;
        @memcpy(cmd.payload[0..@sizeOf(CollisionSinglePayload)], std.mem.asBytes(&payload));
        self.enqueueCommand(cmd);
    }

    // ─── Input Helpers ──────────────────────────────────────────────

    pub fn keyDown(self: *GraphicsState, keycode: u8) bool {
        return self.key_state[keycode].load(.acquire) != 0;
    }

    pub fn inkey(self: *GraphicsState) u32 {
        return self.key_buffer.pop() orelse 0;
    }

    pub fn mouseX(self: *GraphicsState) i16 {
        return self.mouse_x.load(.acquire);
    }

    pub fn mouseY(self: *GraphicsState) i16 {
        return self.mouse_y.load(.acquire);
    }

    pub fn mouseButton(self: *GraphicsState) u8 {
        return self.mouse_buttons.load(.acquire);
    }

    pub fn mouseScroll(self: *GraphicsState) i16 {
        return self.mouse_scroll.swap(0, .acq_rel);
    }

    pub fn joyCount(self: *const GraphicsState) u8 {
        var count: u8 = 0;
        for (self.controllers) |ctrl| {
            if (ctrl.connected) count += 1;
        }
        return count;
    }

    pub fn joyAxis(self: *const GraphicsState, controller: u8, axis: u8) f32 {
        if (controller >= 4) return 0;
        return self.controllers[controller].getAxis(axis);
    }

    pub fn joyButton(self: *const GraphicsState, controller: u8, btn: u8) bool {
        if (controller >= 4) return false;
        return self.controllers[controller].getButton(btn);
    }

    // ─── Queries ────────────────────────────────────────────────────

    pub fn isActive(self: *const GraphicsState) bool {
        return self.active.load(.acquire);
    }

    pub fn frontBuffer(self: *const GraphicsState) u1 {
        return self.front;
    }

    pub fn screenWidth(self: *const GraphicsState) u16 {
        return self.width;
    }

    pub fn screenHeight(self: *const GraphicsState) u16 {
        return self.height;
    }

    pub fn bufferWidth(self: *const GraphicsState) u16 {
        return self.buf_width;
    }

    pub fn bufferHeight(self: *const GraphicsState) u16 {
        return self.buf_height;
    }

    // ─── SCREEN / SCREENCLOSE Commands ──────────────────────────────

    /// SCREEN — create (or recreate) the graphics window.
    ///
    /// Dispatches window creation synchronously to the main thread via
    /// `gfx_create_window_sync`.  Blocks the calling thread until the
    /// window is fully created and buffer pointers are set.
    pub fn screen(self: *GraphicsState, w: u16, h: u16, scale_hint: u16) void {
        // Clamp resolution
        const cw = @min(w, MAX_RESOLUTION_W);
        const ch = @min(h, MAX_RESOLUTION_H);
        const cw2 = @max(cw, 160);
        const ch2 = @max(ch, 100);

        self.setResolution(cw2, ch2);

        // Synchronously create the window on the main thread.
        // This blocks until the window is ready and buffer pointers are set.
        gfx_create_window_sync(cw2, ch2, scale_hint);
        self.active.store(true, .release);

        // Populate the default CGA-like palette now that shared buffers exist
        self.initDefaultPalettes();

        // Reset sprite system for the new window
        self.sprites.reset();

        // Fresh menu scope per SCREEN invocation.
        self.menuReset();
    }

    /// SCREENCLOSE — close the graphics window.
    pub fn screenClose(self: *GraphicsState) void {
        self.menuReset();
        self.active.store(false, .release);
        gfx_destroy_window_async();
    }

    /// SCREENTITLE — set window title (enqueue command).
    pub fn screenTitle(self: *GraphicsState, ptr: [*]const u8, len: u32) void {
        var cmd = GfxCommand.init(.set_title);
        var payload: SetTitlePayload = undefined;
        const copy_len: u32 = @min(len, 52);
        payload.len = copy_len;
        payload.data = std.mem.zeroes([52]u8);
        @memcpy(payload.data[0..copy_len], ptr[0..copy_len]);
        @memcpy(cmd.payload[0..@sizeOf(SetTitlePayload)], std.mem.asBytes(&payload));
        self.enqueueCommand(cmd);
    }

    /// APPNAME — set application/menu name (enqueue command).
    pub fn appName(self: *GraphicsState, ptr: [*]const u8, len: u32) void {
        var cmd = GfxCommand.init(.set_app_name);
        var payload: SetTitlePayload = undefined;
        const copy_len: u32 = @min(len, 52);
        payload.len = copy_len;
        payload.data = std.mem.zeroes([52]u8);
        @memcpy(payload.data[0..copy_len], ptr[0..copy_len]);
        @memcpy(cmd.payload[0..@sizeOf(SetTitlePayload)], std.mem.asBytes(&payload));
        self.enqueueCommand(cmd);
    }

    /// SCREENMODE — set display mode.
    pub fn screenModeSet(self: *GraphicsState, mode: ScreenMode) void {
        self.screen_mode = mode;
        self.determinePAR();
        var cmd = GfxCommand.init(.set_screen_mode);
        cmd.payload[0] = @intFromEnum(mode);
        self.enqueueCommand(cmd);
    }

    /// SETSCROLL — set hardware scroll offset (enqueue command).
    pub fn setScroll(self: *GraphicsState, sx: i16, sy: i16) void {
        self.scroll_x = sx;
        self.scroll_y = sy;
        var cmd = GfxCommand.init(.set_scroll);
        var payload: SetScrollPayload = undefined;
        payload.scroll_x = sx;
        payload.scroll_y = sy;
        @memcpy(cmd.payload[0..@sizeOf(SetScrollPayload)], std.mem.asBytes(&payload));
        self.enqueueCommand(cmd);
    }

    pub fn menuReset(self: *GraphicsState) void {
        self.menu_events.clear();
        self.enqueueCommand(GfxCommand.init(.menu_reset));
    }

    pub fn menuDefine(self: *GraphicsState, menu_id: u8, title: []const u8) void {
        var cmd = GfxCommand.init(.menu_define);
        var payload: MenuDefinePayload = .{
            .menu_id = menu_id,
            .title_len = @intCast(@min(title.len, 30)),
            .title = std.mem.zeroes([30]u8),
        };
        @memcpy(payload.title[0..payload.title_len], title[0..payload.title_len]);
        @memcpy(cmd.payload[0..@sizeOf(MenuDefinePayload)], std.mem.asBytes(&payload));
        self.enqueueCommand(cmd);
    }

    pub fn menuAddItem(self: *GraphicsState, menu_id: u8, item_id: u16, label: []const u8, shortcut: []const u8, flags: u16) void {
        var cmd = GfxCommand.init(.menu_add_item);
        var payload: MenuItemPayload = .{
            .menu_id = menu_id,
            ._pad0 = 0,
            .item_id = item_id,
            .label_len = @intCast(@min(label.len, 24)),
            .shortcut_len = @intCast(@min(shortcut.len, 8)),
            .flags = flags,
            .label = std.mem.zeroes([24]u8),
            .shortcut = std.mem.zeroes([8]u8),
        };
        @memcpy(payload.label[0..payload.label_len], label[0..payload.label_len]);
        @memcpy(payload.shortcut[0..payload.shortcut_len], shortcut[0..payload.shortcut_len]);
        @memcpy(cmd.payload[0..@sizeOf(MenuItemPayload)], std.mem.asBytes(&payload));
        self.enqueueCommand(cmd);
    }

    pub fn menuAddSeparator(self: *GraphicsState, menu_id: u8) void {
        var cmd = GfxCommand.init(.menu_add_separator);
        cmd.payload[0] = menu_id;
        self.enqueueCommand(cmd);
    }

    pub fn menuSetChecked(self: *GraphicsState, item_id: u16, checked: bool) void {
        var cmd = GfxCommand.init(.menu_set_checked);
        const payload = MenuStatePayload{ .item_id = item_id, .state = if (checked) 1 else 0, ._pad0 = 0 };
        @memcpy(cmd.payload[0..@sizeOf(MenuStatePayload)], std.mem.asBytes(&payload));
        self.enqueueCommand(cmd);
    }

    pub fn menuSetEnabled(self: *GraphicsState, item_id: u16, enabled: bool) void {
        var cmd = GfxCommand.init(.menu_set_enabled);
        const payload = MenuStatePayload{ .item_id = item_id, .state = if (enabled) 1 else 0, ._pad0 = 0 };
        @memcpy(cmd.payload[0..@sizeOf(MenuStatePayload)], std.mem.asBytes(&payload));
        self.enqueueCommand(cmd);
    }

    pub fn menuRename(self: *GraphicsState, item_id: u16, label: []const u8) void {
        var cmd = GfxCommand.init(.menu_rename);
        var payload: MenuRenamePayload = .{
            .item_id = item_id,
            .label_len = @intCast(@min(label.len, 30)),
            ._pad0 = 0,
            .label = std.mem.zeroes([30]u8),
        };
        @memcpy(payload.label[0..payload.label_len], label[0..payload.label_len]);
        @memcpy(cmd.payload[0..@sizeOf(MenuRenamePayload)], std.mem.asBytes(&payload));
        self.enqueueCommand(cmd);
    }

    pub fn menuPushEvent(self: *GraphicsState, item_id: u16) void {
        if (item_id == 0) return;
        self.menu_events.push(item_id);
    }

    pub fn menuNext(self: *GraphicsState) u16 {
        return self.menu_events.pop() orelse 0;
    }
};

// ─── Global State ───────────────────────────────────────────────────────────
//
// Single global instance. Only one graphics window is supported at a time.
// This is accessed from both the JIT thread (drawing/commands) and the
// main thread (command drain, input events).

pub var g_state: GraphicsState = .{};

// ─── C-callable Bridge Accessors ────────────────────────────────────────────
//
// These are called from ed_graphics_bridge.m to communicate with Zig.

/// Called by the ObjC bridge to dequeue the next command.
/// Returns null-sentinel when the queue is empty.
export fn gfx_dequeue_command(out_type: *u8, out_fence: *u32, out_payload: [*]u8) callconv(.c) i32 {
    const cmd = g_state.command_ring.dequeue() orelse return 0;
    out_type.* = @intFromEnum(cmd.cmd_type);
    out_fence.* = cmd.fence_id;
    @memcpy(out_payload[0..56], &cmd.payload);
    return 1;
}

/// Called by the ObjC bridge after shared buffers are allocated.
export fn gfx_set_pixel_buffer(index: i32, ptr: ?*anyopaque, size: u64) callconv(.c) void {
    if (index < 0 or index >= NUM_BUFFERS) return;
    const p = ptr orelse return;
    const raw: [*]u8 = @ptrCast(p);
    g_state.setBufferPointer(@intCast(@as(u32, @intCast(index))), raw, @intCast(size));
}

/// Called by the ObjC bridge after palette buffer is allocated.
export fn gfx_set_line_palette(ptr: ?*anyopaque, count: u32) callconv(.c) void {
    const p = ptr orelse return;
    g_state.setLinePalettePointer(@ptrCast(@alignCast(p)), count);
}

/// Called by the ObjC bridge after global palette buffer is allocated.
export fn gfx_set_global_palette(ptr: ?*anyopaque) callconv(.c) void {
    const p = ptr orelse return;
    g_state.setGlobalPalettePointer(@ptrCast(@alignCast(p)));
}

/// Called by the ObjC bridge after palette effects buffer is allocated.
export fn gfx_set_palette_effects(ptr: ?*anyopaque) callconv(.c) void {
    const p = ptr orelse return;
    g_state.setPaletteEffectsPointer(@ptrCast(@alignCast(p)));
}

/// Called by the ObjC bridge after collision flags buffer is allocated.
export fn gfx_set_collision_flags(ptr: ?*anyopaque) callconv(.c) void {
    const p = ptr orelse return;
    g_state.setCollisionFlagsPointer(@ptrCast(@alignCast(p)));
}

/// Called by the ObjC bridge to signal VSYNC completion.
export fn gfx_signal_vsync() callconv(.c) void {
    g_state.signalVsync();
}

/// Called by the ObjC bridge to signal GPU wait completion.
export fn gfx_signal_gpu_wait() callconv(.c) void {
    g_state.signalGpuWait();
}

/// Called by the ObjC bridge to update completed fence.
export fn gfx_update_fence(fence_id: u32) callconv(.c) void {
    g_state.last_completed_fence.store(fence_id, .release);
}

/// Called by the ObjC bridge to set key state.
export fn gfx_set_key_state(keycode: u8, pressed: i32) callconv(.c) void {
    g_state.key_state[keycode].store(if (pressed != 0) 1 else 0, .release);
    if (pressed != 0) {
        g_state.key_buffer.push(@as(u32, keycode));
    }
}

/// Called by the ObjC bridge to update mouse position.
export fn gfx_set_mouse_state(x: i16, y: i16, buttons: u8) callconv(.c) void {
    g_state.mouse_x.store(x, .release);
    g_state.mouse_y.store(y, .release);
    g_state.mouse_buttons.store(buttons, .release);
}

/// Called by the ObjC bridge to add scroll delta.
export fn gfx_add_mouse_scroll(delta: i16) callconv(.c) void {
    const old = g_state.mouse_scroll.load(.acquire);
    g_state.mouse_scroll.store(old +| delta, .release);
}

/// Called by ObjC menu actions to enqueue a menu event.
export fn gfx_menu_push_event(item_id: u16) callconv(.c) void {
    g_state.menuPushEvent(item_id);
}

/// Called by ObjC side when window/menu scope is torn down.
export fn gfx_menu_clear_events() callconv(.c) void {
    g_state.menu_events.clear();
}

/// Reset graphics sync state after a forced stop (SIGALRM / siglongjmp).
/// Called from the JIT runner after basic_jit_exec returns with exit code 124.
export fn gfx_reset_sync() callconv(.c) void {
    g_state.resetSync();
}

/// Clear Zig-side buffer/palette pointers so they don't dangle after
/// the ObjC bridge releases the underlying MTLBuffers.
/// Called from releaseBuffers (reconfigure path) and gfx_mark_closed.
export fn gfx_clear_buffer_pointers() callconv(.c) void {
    g_state.clearBufferPointers();
    g_state.sprites.clearBufferPointers();
}

/// Called by the ObjC bridge to set sprite system GPU buffer pointers.
export fn gfx_set_sprite_buffers(
    atlas_entries: ?*anyopaque,
    instances_buf: ?*anyopaque,
    palettes_buf: ?*anyopaque,
    uniforms_buf: ?*anyopaque,
) callconv(.c) void {
    g_state.sprites.setBufferPointers(atlas_entries, instances_buf, palettes_buf, uniforms_buf);
}

/// Called by the ObjC bridge to set the sprite staging buffer pointer.
export fn gfx_set_sprite_staging(ptr: ?*anyopaque, size: u32) callconv(.c) void {
    g_state.sprites.setStagingBuffer(ptr, size);
}

/// Called by the ObjC bridge to set the sprite output dimensions in the
/// sprite uniforms (done once during buffer allocation).
export fn gfx_set_sprite_output_size(w: u32, h: u32) callconv(.c) void {
    if (g_state.sprites.gpu_uniforms) |uniforms| {
        uniforms.output_width = w;
        uniforms.output_height = h;
    }
}

/// Called from the JIT thread to sync sprite instance data to GPU buffers.
/// Invoked during VSYNC before the GPU frame is submitted.
export fn gfx_sprite_sync() callconv(.c) void {
    g_state.sprites.updateAndSync();
}

/// Called by the ObjC bridge to mark the window as closed.
export fn gfx_mark_closed() callconv(.c) void {
    g_state.active.store(false, .release);
    // Clear buffer pointers so we don't hold dangling references
    // into the freed MTLBuffer memory.
    g_state.clearBufferPointers();
    // Wake up any JIT thread blocked in waitVsync / waitGpuComplete
    g_state.signalVsync();
    g_state.signalGpuWait();
}

/// Return resolution info for the ObjC bridge.
export fn gfx_get_resolution(out_w: *u16, out_h: *u16, out_bw: *u16, out_bh: *u16, out_ox: *u16, out_oy: *u16) callconv(.c) void {
    out_w.* = g_state.width;
    out_h.* = g_state.height;
    out_bw.* = g_state.buf_width;
    out_bh.* = g_state.buf_height;
    out_ox.* = g_state.overscan_x;
    out_oy.* = g_state.overscan_y;
}

/// Return collision sources for the GPU dispatch.
export fn gfx_get_collision_source(i: u8, out_buf: *u8, out_x: *i16, out_y: *i16, out_w: *u16, out_h: *u16) callconv(.c) i32 {
    if (i >= g_state.collision_count) return 0;
    const src = g_state.collision_sources[i];
    out_buf.* = src.buffer;
    out_x.* = src.x;
    out_y.* = src.y;
    out_w.* = src.w;
    out_h.* = src.h;
    return 1;
}

/// Return collision count.
export fn gfx_get_collision_count() callconv(.c) u8 {
    return g_state.collision_count;
}

/// Return front buffer index.
export fn gfx_get_front_buffer() callconv(.c) u8 {
    return @as(u8, g_state.front);
}

/// Return scroll offset.
export fn gfx_get_scroll(out_x: *i16, out_y: *i16) callconv(.c) void {
    out_x.* = g_state.scroll_x;
    out_y.* = g_state.scroll_y;
}

/// Return PAR info.
export fn gfx_get_par(out_num: *u16, out_den: *u16) callconv(.c) void {
    out_num.* = g_state.par_numerator;
    out_den.* = g_state.par_denominator;
}

/// Called by the ObjC bridge to update game controller state.
/// controller: 0–3, connected: 0/1, axes: pointer to 6 floats, buttons: bitmask
export fn gfx_set_controller_state(controller: u8, connected: i32, axes: [*]const f32, buttons: u32) callconv(.c) void {
    if (controller >= 4) return;
    g_state.controllers[controller].connected = (connected != 0);
    for (0..6) |i| {
        g_state.controllers[controller].axes[i] = axes[i];
    }
    g_state.controllers[controller].buttons = buttons;
}

/// Called by the ObjC bridge to mark a controller as disconnected.
export fn gfx_set_controller_disconnected(controller: u8) callconv(.c) void {
    if (controller >= 4) return;
    g_state.controllers[controller].connected = false;
    g_state.controllers[controller].axes = [_]f32{0} ** 6;
    g_state.controllers[controller].buttons = 0;
}
