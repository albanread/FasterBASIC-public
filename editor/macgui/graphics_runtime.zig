// ─── Graphics Runtime — JIT-Callable Exports ────────────────────────────────
//
// C-callable functions with callconv(.c) that are resolved by
// dlsym(RTLD_DEFAULT, ...) at JIT link time, just like the existing
// basic_* runtime symbols in the runtime/ directory.
//
// All arguments use f64 because FasterBASIC's default numeric type is
// DOUBLE, and the JIT calling convention passes everything as doubles.
// The runtime functions convert to integers internally.
//
// Functions that write pixels or palettes operate directly on shared
// MTLBuffer contents via the global GraphicsState. Functions that need
// GPU dispatch or main-thread execution enqueue commands into the
// GfxCommandRing.
//
// Thread safety: these functions are called from the JIT worker thread.
// Drawing ops are direct shared-memory writes (safe because JIT only
// writes the back buffer / content buffers). Command-queue ops use the
// lock-free SPSC ring.

const std = @import("std");
const gfx = @import("ed_graphics");
const sprite = gfx.sprite;
const image_mgr = @import("image_manager.zig");

// ─── AOT AppKit initialization ──────────────────────────────────────────────
// External functions from aot_appkit_init.m
extern fn aot_appkit_init_if_needed() void;
extern fn aot_appkit_process_events() void;
extern fn gfx_dialog_reset_bridge() callconv(.c) void;
extern fn gfx_dialog_begin_bridge(dialog_id: u16) callconv(.c) void;
extern fn gfx_dialog_set_title_bridge(ptr: ?[*]const u8, len: u32) callconv(.c) void;
extern fn gfx_dialog_set_message_bridge(ptr: ?[*]const u8, len: u32) callconv(.c) void;
extern fn gfx_dialog_add_label_bridge(ptr: ?[*]const u8, len: u32) callconv(.c) void;
extern fn gfx_dialog_add_textfield_bridge(control_id: u16, label_ptr: ?[*]const u8, label_len: u32, default_ptr: ?[*]const u8, default_len: u32) callconv(.c) void;
extern fn gfx_dialog_add_securefield_bridge(control_id: u16, label_ptr: ?[*]const u8, label_len: u32, default_ptr: ?[*]const u8, default_len: u32) callconv(.c) void;
extern fn gfx_dialog_add_textarea_bridge(control_id: u16, label_ptr: ?[*]const u8, label_len: u32, default_ptr: ?[*]const u8, default_len: u32) callconv(.c) void;
extern fn gfx_dialog_add_numberfield_bridge(control_id: u16, label_ptr: ?[*]const u8, label_len: u32, default_value: f64, min_value: f64, max_value: f64, step: f64) callconv(.c) void;
extern fn gfx_dialog_add_slider_bridge(control_id: u16, label_ptr: ?[*]const u8, label_len: u32, min_value: f64, max_value: f64, default_value: f64) callconv(.c) void;
extern fn gfx_dialog_add_filepicker_bridge(control_id: u16, label_ptr: ?[*]const u8, label_len: u32, default_ptr: ?[*]const u8, default_len: u32) callconv(.c) void;
extern fn gfx_dialog_add_checkbox_bridge(control_id: u16, label_ptr: ?[*]const u8, label_len: u32, checked: u8) callconv(.c) void;
extern fn gfx_dialog_add_radio_bridge(control_id: u16, group_id: u16, label_ptr: ?[*]const u8, label_len: u32, selected: u8) callconv(.c) void;
extern fn gfx_dialog_add_dropdown_bridge(control_id: u16, label_ptr: ?[*]const u8, label_len: u32, options_ptr: ?[*]const u8, options_len: u32, default_index: i32) callconv(.c) void;
extern fn gfx_dialog_add_button_bridge(control_id: u16, label_ptr: ?[*]const u8, label_len: u32, flags: u8) callconv(.c) void;
extern fn gfx_dialog_end_bridge() callconv(.c) void;
extern fn gfx_dialog_show_bridge(dialog_id: u16) callconv(.c) u16;
extern fn gfx_dialog_get_text_bridge(control_id: u16) callconv(.c) [*:0]const u8;
extern fn gfx_dialog_get_checked_bridge(control_id: u16) callconv(.c) u8;
extern fn gfx_dialog_get_selection_bridge(control_id: u16) callconv(.c) i32;
extern fn gfx_dialog_set_text_bridge(control_id: u16, ptr: ?[*]const u8, len: u32) callconv(.c) void;
extern fn gfx_dialog_set_number_bridge(control_id: u16, value: f64) callconv(.c) void;
extern fn gfx_dialog_set_checked_bridge(control_id: u16, on: u8) callconv(.c) void;
extern fn gfx_dialog_set_selection_bridge(control_id: u16, index: i32) callconv(.c) void;
extern fn string_new_utf8(cstr: [*:0]const u8) callconv(.c) ?*anyopaque;

// ─── Window system bridge functions ─────────────────────────────────────────
extern fn gfx_window_define_bridge(id: u16, title_ptr: ?[*]const u8, title_len: u32, x: u16, y: u16, w: u16, h: u16) callconv(.c) void;
extern fn gfx_window_control_bridge(win_id: u16, kind: u8, ctl_id: u16, label_ptr: ?[*]const u8, label_len: u32, x: u16, y: u16, w: u16, h: u16) callconv(.c) void;
extern fn gfx_window_show_bridge(id: u16) callconv(.c) void;
extern fn gfx_window_hide_bridge(id: u16) callconv(.c) void;
extern fn gfx_window_close_bridge(id: u16) callconv(.c) void;
extern fn gfx_window_shutdown_bridge() callconv(.c) void;
extern fn gfx_window_poll_bridge(win_out: *u16, ctl_out: *u16) callconv(.c) u8;
extern fn gfx_window_get_text_bridge(win_id: u16, ctl_id: u16) callconv(.c) [*:0]const u8;
extern fn gfx_window_set_text_bridge(win_id: u16, ctl_id: u16, text_ptr: ?[*]const u8, text_len: u32) callconv(.c) void;
extern fn gfx_window_set_enabled_bridge(win_id: u16, ctl_id: u16, enabled: u8) callconv(.c) void;
extern fn gfx_window_set_title_bridge(win_id: u16, title_ptr: ?[*]const u8, title_len: u32) callconv(.c) void;
extern fn gfx_window_get_checked_bridge(win_id: u16, ctl_id: u16) callconv(.c) u8;
extern fn gfx_window_ranged_control_bridge(win_id: u16, kind: u8, ctl_id: u16, min: f64, max: f64, x: u16, y: u16, w: u16, h: u16) callconv(.c) void;
extern fn gfx_window_matrix_control_bridge(win_id: u16, ctl_id: u16, rows: i32, cols: i32, data: ?[*]f64, x: u16, y: u16, w: u16, h: u16) callconv(.c) void;
extern fn gfx_window_matrix_last_row_bridge() callconv(.c) f64;
extern fn gfx_window_matrix_last_col_bridge() callconv(.c) f64;
extern fn gfx_window_matrix_last_val_bridge() callconv(.c) f64;
extern fn gfx_window_get_value_bridge(win_id: u16, ctl_id: u16) callconv(.c) f64;
extern fn gfx_window_set_value_bridge(win_id: u16, ctl_id: u16, value: f64) callconv(.c) void;
extern fn gfx_window_canvas_dispatch_bridge(win_id: u16, ctl_id: u16, data_ptr: ?[*]const u8, data_len: u32) callconv(.c) void;
extern fn gfx_window_canvas_set_virtualsize_bridge(win_id: u16, ctl_id: u16, virtual_w: f64, virtual_h: f64) callconv(.c) void;
extern fn gfx_window_canvas_set_viewport_bridge(win_id: u16, ctl_id: u16, x: f64, y: f64) callconv(.c) void;
extern fn gfx_window_canvas_set_resolution_bridge(win_id: u16, ctl_id: u16, logical_w: f64, logical_h: f64) callconv(.c) void;
extern fn gfx_window_canvas_op_bridge(win_id: u16, ctl_id: u16, op: u8, args: [*]const f64, count: u32, text_ptr: ?[*]const u8, text_len: u32) callconv(.c) void;
extern fn gfx_image_write_png_bridge(path_ptr: ?[*]const u8, path_len: u32, rgba_ptr: ?[*]const u8, width: u32, height: u32, stride: u32) callconv(.c) u8;
extern fn gfx_image_read_png_bridge(path_ptr: ?[*]const u8, path_len: u32, out_w: *u32, out_h: *u32) callconv(.c) ?[*]u8;

const GraphicsState = gfx.GraphicsState;
const PaletteEffect = gfx.PaletteEffect;
const EFFECT_FLAG_ACTIVE = gfx.EFFECT_FLAG_ACTIVE;
const EFFECT_FLAG_PER_LINE = gfx.EFFECT_FLAG_PER_LINE;
const EFFECT_FLAG_ONE_SHOT = gfx.EFFECT_FLAG_ONE_SHOT;

// ─── Helpers ────────────────────────────────────────────────────────────────

inline fn toI32(v: f64) i32 {
    return @intFromFloat(v);
}

inline fn toU8(v: f64) u8 {
    if (std.math.isNan(v)) return 0;
    const i: i32 = @intFromFloat(v);
    if (i < 0) return 0;
    if (i > 255) return 255;
    return @intCast(i);
}

inline fn toU8FromI32(v: i32) u8 {
    if (v < 0) return 0;
    if (v > 255) return 255;
    return @intCast(v);
}

inline fn toU16(v: f64) u16 {
    if (std.math.isNan(v)) return 0;
    const i: i32 = @intFromFloat(v);
    if (i < 0) return 0;
    if (i > 65535) return 65535;
    return @intCast(i);
}

inline fn toU32(v: f64) u32 {
    if (v < 0) return 0;
    if (v > 4294967295.0) return 4294967295;
    return @intFromFloat(v);
}

inline fn toI16(v: f64) i16 {
    const i: i32 = @intFromFloat(v);
    if (i < -32768) return -32768;
    if (i > 32767) return 32767;
    return @intCast(i);
}

inline fn toU3(v: f64) u3 {
    const i: i32 = @intFromFloat(v);
    if (i < 0) return 0;
    if (i > 7) return 7;
    return @intCast(i);
}

inline fn toU5(v: f64) u5 {
    const i: i32 = @intFromFloat(v);
    if (i < 0) return 0;
    if (i > 31) return 31;
    return @intCast(i);
}

inline fn toU1(v: f64) u1 {
    const i: i32 = @intFromFloat(v);
    return if (i != 0) 1 else 0;
}

inline fn toBool(v: f64) bool {
    return @as(i32, @intFromFloat(v)) != 0;
}

fn state() *GraphicsState {
    return &gfx.g_state;
}

// ─── StringDescriptor Access ────────────────────────────────────────────────
//
// FasterBASIC passes strings as StringDescriptor* (opaque pointer).
// We need to extract the UTF-8 data for SCREENTITLE, SCREENMODE, DRAWTEXT.

const StringDescriptor = extern struct {
    data: ?*anyopaque,
    length: i64,
    capacity: i64,
    refcount: i32,
    encoding: u8,
    dirty: u8,
    _padding: [2]u8,
    utf8_cache: ?[*]u8,
};

extern fn string_to_utf8(desc: *const anyopaque) [*:0]const u8;

fn getStringSlice(desc: ?*const anyopaque) []const u8 {
    const d = desc orelse return "";
    const cstr = string_to_utf8(d);
    return std.mem.sliceTo(cstr, 0);
}

// ═══════════════════════════════════════════════════════════════════════════
// Window Control (enqueue commands → main thread)
// ═══════════════════════════════════════════════════════════════════════════

export fn gfx_screen(width: f64, height: f64, scale: f64) callconv(.c) void {
    // Initialize AppKit if needed (AOT mode)
    aot_appkit_init_if_needed();

    state().screen(toU16(width), toU16(height), toU16(scale));
}

export fn gfx_screen_close() callconv(.c) void {
    state().screenClose();
}

export fn gfx_screen_title(desc: ?*const anyopaque) callconv(.c) void {
    const slice = getStringSlice(desc);
    if (slice.len == 0) return;
    state().screenTitle(slice.ptr, @intCast(slice.len));
}

export fn gfx_app_name(desc: ?*const anyopaque) callconv(.c) void {
    const slice = getStringSlice(desc);
    if (slice.len == 0) return;
    aot_appkit_init_if_needed();
    state().appName(slice.ptr, @intCast(slice.len));
}

export fn gfx_screen_mode(desc: ?*const anyopaque) callconv(.c) void {
    const slice = getStringSlice(desc);
    if (slice.len == 0) return;

    // Compare mode string (case-insensitive)
    var buf: [16]u8 = undefined;
    const upper_len = @min(slice.len, buf.len);
    for (0..upper_len) |i| {
        buf[i] = std.ascii.toUpper(slice[i]);
    }
    const upper = buf[0..upper_len];

    if (std.mem.eql(u8, upper, "SQUARE")) {
        state().screenModeSet(.square);
    } else if (std.mem.eql(u8, upper, "CRT")) {
        state().screenModeSet(.crt);
    } else {
        state().screenModeSet(.normal);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Drawing State
// ═══════════════════════════════════════════════════════════════════════════

export fn gfx_set_target(buffer: f64) callconv(.c) void {
    state().target = toU3(buffer);
}

// ═══════════════════════════════════════════════════════════════════════════
// Drawing Primitives (direct shared memory writes — no queue)
// ═══════════════════════════════════════════════════════════════════════════

export fn gfx_pset(x: f64, y: f64, c: f64) callconv(.c) void {
    state().pset(toI32(x), toI32(y), toU8(c));
}

// Integer fast path for PSET (avoids f64 conversion in hot loops).
export fn gfx_pset_i32(x: i32, y: i32, c: i32) callconv(.c) void {
    state().pset(x, y, toU8FromI32(c));
}

export fn gfx_pget(x: f64, y: f64) callconv(.c) f64 {
    return @floatFromInt(state().pget(toI32(x), toI32(y)));
}

export fn gfx_line(x1: f64, y1: f64, x2: f64, y2: f64, c: f64) callconv(.c) void {
    state().line(toI32(x1), toI32(y1), toI32(x2), toI32(y2), toU8(c));
}

export fn gfx_rect(x: f64, y: f64, w: f64, h: f64, c: f64, filled: f64) callconv(.c) void {
    const ix = toI32(x);
    const iy = toI32(y);
    state().rect(ix, iy, ix + toI32(w), iy + toI32(h), toU8(c), toBool(filled));
}

export fn gfx_circle(cx: f64, cy: f64, r: f64, c: f64, filled: f64) callconv(.c) void {
    state().circle(toI32(cx), toI32(cy), toI32(r), toU8(c), toBool(filled));
}

export fn gfx_ellipse(cx: f64, cy: f64, rx: f64, ry: f64, c: f64, filled: f64) callconv(.c) void {
    state().ellipse(toI32(cx), toI32(cy), toI32(rx), toI32(ry), toU8(c), toBool(filled));
}

export fn gfx_triangle(x1: f64, y1: f64, x2: f64, y2: f64, x3: f64, y3: f64, c: f64, filled: f64) callconv(.c) void {
    state().triangle(toI32(x1), toI32(y1), toI32(x2), toI32(y2), toI32(x3), toI32(y3), toU8(c), toBool(filled));
}

export fn gfx_fill_area(x: f64, y: f64, c: f64) callconv(.c) void {
    state().fillArea(toI32(x), toI32(y), toU8(c));
}

export fn gfx_cls(c: f64) callconv(.c) void {
    state().clear(toU8(c));
}

export fn gfx_scroll_buffer(dx: f64, dy: f64, fill: f64) callconv(.c) void {
    state().scrollBuffer(toI32(dx), toI32(dy), toU8(fill));
}

// ═══════════════════════════════════════════════════════════════════════════
// Blit Operations (direct shared memory — index 0 always transparent)
// ═══════════════════════════════════════════════════════════════════════════

export fn gfx_blit(dst: f64, dx: f64, dy: f64, src: f64, sx: f64, sy: f64, w: f64, h: f64) callconv(.c) void {
    state().blit(toU3(dst), toI32(dx), toI32(dy), toU3(src), toI32(sx), toI32(sy), toI32(w), toI32(h));
}

export fn gfx_blit_solid(dst: f64, dx: f64, dy: f64, src: f64, sx: f64, sy: f64, w: f64, h: f64) callconv(.c) void {
    state().blitSolid(toU3(dst), toI32(dx), toI32(dy), toU3(src), toI32(sx), toI32(sy), toI32(w), toI32(h));
}

export fn gfx_blit_scale(dst: f64, dx: f64, dy: f64, dw: f64, dh: f64, src: f64, sx: f64, sy: f64, sw: f64, sh: f64) callconv(.c) void {
    state().blitScale(toU3(dst), toI32(dx), toI32(dy), toI32(dw), toI32(dh), toU3(src), toI32(sx), toI32(sy), toI32(sw), toI32(sh));
}

export fn gfx_blit_flip(dst: f64, dx: f64, dy: f64, src: f64, sx: f64, sy: f64, w: f64, h: f64, mode: f64) callconv(.c) void {
    state().blitFlip(toU3(dst), toI32(dx), toI32(dy), toU3(src), toI32(sx), toI32(sy), toI32(w), toI32(h), toU8(mode));
}

// ═══════════════════════════════════════════════════════════════════════════
// Palette (direct shared memory writes)
// ═══════════════════════════════════════════════════════════════════════════

export fn gfx_palette(index: f64, r: f64, g: f64, b: f64) callconv(.c) void {
    state().setPalette(toU8(index), toU8(r), toU8(g), toU8(b));
}

export fn gfx_line_palette(line_f: f64, index: f64, r: f64, g: f64, b: f64) callconv(.c) void {
    state().setLinePalette(toU16(line_f), toU8(index), toU8(r), toU8(g), toU8(b));
}

export fn gfx_reset_palette() callconv(.c) void {
    state().resetPalette();
}

export fn gfx_palette_get(index: f64) callconv(.c) f64 {
    return @floatFromInt(state().getPalette(toU8(index)));
}

export fn gfx_line_palette_get(line_f: f64, index: f64) callconv(.c) f64 {
    return @floatFromInt(state().getLinePalette(toU16(line_f), toU8(index)));
}

// ═══════════════════════════════════════════════════════════════════════════
// Palette Animation (enqueue commands → GPU)
// ═══════════════════════════════════════════════════════════════════════════

// ── PALCYCLE ──────────────────────────────────────────────────────────────
// Global form:   PALCYCLE slot, start, end, speed, direction
//   Rotates global palette entries start..end (indices 16–255) each frame.
// Per-line form: PALCYCLE slot, index, lineStart, lineEnd, speed, direction
//   Rotates per-line palette entry `index` (2–15) across scanlines ls..le.

export fn gfx_pal_cycle(slot: f64, start: f64, end_idx: f64, speed: f64, direction: f64) callconv(.c) void {
    var effect = PaletteEffect.empty();
    effect.effect_type = @intFromEnum(gfx.PaletteEffectType.cycle);
    effect.flags = EFFECT_FLAG_ACTIVE;
    effect.index_start = @intCast(toU8(start));
    effect.index_end = @intCast(toU8(end_idx));
    effect.speed = @floatCast(speed);
    effect.direction = toI32(direction);
    if (effect.direction == 0) effect.direction = 1;
    state().installEffect(toU5(slot), effect);
}

// Per-line PALCYCLE: cycles a single per-line index (2–15) across a scanline band.
export fn gfx_pal_cycle_lines(slot: f64, index: f64, ls: f64, le: f64, speed: f64, direction: f64) callconv(.c) void {
    var effect = PaletteEffect.empty();
    effect.effect_type = @intFromEnum(gfx.PaletteEffectType.cycle);
    effect.flags = EFFECT_FLAG_ACTIVE | EFFECT_FLAG_PER_LINE;
    effect.index_start = @intCast(toU8(index));
    effect.index_end = @intCast(toU8(index));
    effect.line_start = @intCast(toU16(ls));
    effect.line_end = @intCast(toU16(le));
    effect.speed = @floatCast(speed);
    effect.direction = toI32(direction);
    if (effect.direction == 0) effect.direction = 1;
    state().installEffect(toU5(slot), effect);
}

// ── PALFADE ───────────────────────────────────────────────────────────────
// Global form:   PALFADE slot, index, speed, r1,g1,b1, r2,g2,b2
//   Fades a single global palette entry (index 16–255) from colour A to B.
// Per-line form: PALFADE slot, index, lineStart, lineEnd, speed, r1,g1,b1, r2,g2,b2
//   Fades per-line palette entry `index` (2–15) across scanlines ls..le.

export fn gfx_pal_fade(slot: f64, index: f64, speed: f64, r1: f64, g1: f64, b1: f64, r2: f64, g2: f64, b2: f64) callconv(.c) void {
    var effect = PaletteEffect.empty();
    effect.effect_type = @intFromEnum(gfx.PaletteEffectType.fade);
    effect.flags = EFFECT_FLAG_ACTIVE | EFFECT_FLAG_ONE_SHOT;
    effect.index_start = @intCast(toU8(index));
    effect.index_end = @intCast(toU8(index));
    effect.colour_a = .{ toU8(r1), toU8(g1), toU8(b1), 255 };
    effect.colour_b = .{ toU8(r2), toU8(g2), toU8(b2), 255 };
    effect.speed = @floatCast(speed);
    state().installEffect(toU5(slot), effect);
}

// Per-line PALFADE: fades a per-line palette entry across a scanline band.
export fn gfx_pal_fade_lines(slot: f64, index: f64, ls: f64, le: f64, speed: f64, r1: f64, g1: f64, b1: f64, r2: f64, g2: f64, b2: f64) callconv(.c) void {
    var effect = PaletteEffect.empty();
    effect.effect_type = @intFromEnum(gfx.PaletteEffectType.fade);
    effect.flags = EFFECT_FLAG_ACTIVE | EFFECT_FLAG_ONE_SHOT | EFFECT_FLAG_PER_LINE;
    effect.index_start = @intCast(toU8(index));
    effect.index_end = @intCast(toU8(index));
    effect.line_start = @intCast(toU16(ls));
    effect.line_end = @intCast(toU16(le));
    effect.colour_a = .{ toU8(r1), toU8(g1), toU8(b1), 255 };
    effect.colour_b = .{ toU8(r2), toU8(g2), toU8(b2), 255 };
    effect.speed = @floatCast(speed);
    state().installEffect(toU5(slot), effect);
}

// ── PALPULSE ──────────────────────────────────────────────────────────────
// Global form:   PALPULSE slot, index, speed, r1,g1,b1, r2,g2,b2
//   Pulses a single global palette entry (index 16–255) between colours A and B.
// Per-line form: PALPULSE slot, index, lineStart, lineEnd, speed, r1,g1,b1, r2,g2,b2
//   Pulses per-line palette entry `index` (2–15) across scanlines ls..le.

export fn gfx_pal_pulse(slot: f64, index: f64, speed: f64, r1: f64, g1: f64, b1: f64, r2: f64, g2: f64, b2: f64) callconv(.c) void {
    var effect = PaletteEffect.empty();
    effect.effect_type = @intFromEnum(gfx.PaletteEffectType.pulse);
    effect.flags = EFFECT_FLAG_ACTIVE;
    effect.index_start = @intCast(toU8(index));
    effect.index_end = @intCast(toU8(index));
    effect.colour_a = .{ toU8(r1), toU8(g1), toU8(b1), 255 };
    effect.colour_b = .{ toU8(r2), toU8(g2), toU8(b2), 255 };
    effect.speed = @floatCast(speed);
    state().installEffect(toU5(slot), effect);
}

// Per-line PALPULSE: pulses a per-line palette entry across a scanline band.
export fn gfx_pal_pulse_lines(slot: f64, index: f64, ls: f64, le: f64, speed: f64, r1: f64, g1: f64, b1: f64, r2: f64, g2: f64, b2: f64) callconv(.c) void {
    var effect = PaletteEffect.empty();
    effect.effect_type = @intFromEnum(gfx.PaletteEffectType.pulse);
    effect.flags = EFFECT_FLAG_ACTIVE | EFFECT_FLAG_PER_LINE;
    effect.index_start = @intCast(toU8(index));
    effect.index_end = @intCast(toU8(index));
    effect.line_start = @intCast(toU16(ls));
    effect.line_end = @intCast(toU16(le));
    effect.colour_a = .{ toU8(r1), toU8(g1), toU8(b1), 255 };
    effect.colour_b = .{ toU8(r2), toU8(g2), toU8(b2), 255 };
    effect.speed = @floatCast(speed);
    state().installEffect(toU5(slot), effect);
}

// ── PALGRADIENT ───────────────────────────────────────────────────────────
// PALGRADIENT slot, index, lineStart, lineEnd, r1,g1,b1, r2,g2,b2
//   Fills per-line palette entry `index` (2–15) with a smooth colour gradient
//   interpolated from colour A at lineStart to colour B at lineEnd.
//   Applied every frame — static effect, no phase advancement.

export fn gfx_pal_gradient(slot: f64, idx: f64, ls: f64, le: f64, r1: f64, g1: f64, b1: f64, r2: f64, g2: f64, b2: f64) callconv(.c) void {
    var effect = PaletteEffect.empty();
    effect.effect_type = @intFromEnum(gfx.PaletteEffectType.gradient);
    effect.flags = EFFECT_FLAG_ACTIVE | EFFECT_FLAG_PER_LINE;
    effect.index_start = @intCast(toU8(idx));
    effect.index_end = @intCast(toU8(idx));
    effect.line_start = @intCast(toU16(ls));
    effect.line_end = @intCast(toU16(le));
    effect.colour_a = .{ toU8(r1), toU8(g1), toU8(b1), 255 };
    effect.colour_b = .{ toU8(r2), toU8(g2), toU8(b2), 255 };
    state().installEffect(toU5(slot), effect);
}

// ── PALSTROBE ─────────────────────────────────────────────────────────────
// Global form:   PALSTROBE slot, index, onFrames, offFrames, r1,g1,b1, r2,g2,b2
//   Strobes a single global palette entry (index 16–255) between colours A and B.
// Per-line form: PALSTROBE slot, index, lineStart, lineEnd, onFrames, offFrames, r1,g1,b1, r2,g2,b2
//   Strobes per-line palette entry `index` (2–15) across scanlines ls..le.

export fn gfx_pal_strobe(slot: f64, index: f64, on: f64, off: f64, r1: f64, g1: f64, b1: f64, r2: f64, g2: f64, b2: f64) callconv(.c) void {
    var effect = PaletteEffect.empty();
    effect.effect_type = @intFromEnum(gfx.PaletteEffectType.strobe);
    effect.flags = EFFECT_FLAG_ACTIVE;
    effect.index_start = @intCast(toU8(index));
    effect.index_end = @intCast(toU8(index));
    effect.colour_a = .{ toU8(r1), toU8(g1), toU8(b1), 255 };
    effect.colour_b = .{ toU8(r2), toU8(g2), toU8(b2), 255 };
    effect.speed = @floatCast(on); // on_frames
    effect.phase = @floatCast(off); // off_frames (reuse phase field for storage)
    state().installEffect(toU5(slot), effect);
}

// Per-line PALSTROBE: strobes a per-line palette entry across a scanline band.
export fn gfx_pal_strobe_lines(slot: f64, index: f64, ls: f64, le: f64, on: f64, off: f64, r1: f64, g1: f64, b1: f64, r2: f64, g2: f64, b2: f64) callconv(.c) void {
    var effect = PaletteEffect.empty();
    effect.effect_type = @intFromEnum(gfx.PaletteEffectType.strobe);
    effect.flags = EFFECT_FLAG_ACTIVE | EFFECT_FLAG_PER_LINE;
    effect.index_start = @intCast(toU8(index));
    effect.index_end = @intCast(toU8(index));
    effect.line_start = @intCast(toU16(ls));
    effect.line_end = @intCast(toU16(le));
    effect.colour_a = .{ toU8(r1), toU8(g1), toU8(b1), 255 };
    effect.colour_b = .{ toU8(r2), toU8(g2), toU8(b2), 255 };
    effect.speed = @floatCast(on); // on_frames
    effect.phase = @floatCast(off); // off_frames (reuse phase field for storage)
    state().installEffect(toU5(slot), effect);
}

export fn gfx_pal_stop(slot: f64) callconv(.c) void {
    state().stopEffect(toU5(slot));
}

export fn gfx_pal_stop_all() callconv(.c) void {
    state().stopAllEffects();
}

export fn gfx_pal_pause(slot: f64) callconv(.c) void {
    state().pauseEffect(toU5(slot));
}

export fn gfx_pal_resume(slot: f64) callconv(.c) void {
    state().resumeEffect(toU5(slot));
}

// ═══════════════════════════════════════════════════════════════════════════
// Text (direct shared memory writes)
// ═══════════════════════════════════════════════════════════════════════════

export fn gfx_draw_text(x: f64, y: f64, desc: ?*const anyopaque, c: f64, font_id: f64) callconv(.c) f64 {
    const slice = getStringSlice(desc);
    if (slice.len == 0) return x;
    const w = GraphicsState.textWidth(slice);
    state().drawText(toI32(x), toI32(y), slice, toU8(c), toU1(font_id));
    return x + @as(f64, @floatFromInt(w));
}

export fn gfx_draw_text_int(x: f64, y: f64, val: i64, c: f64, font_id: f64) callconv(.c) f64 {
    var buf: [32]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "{}", .{val}) catch return x;
    const w = GraphicsState.textWidth(str);
    state().drawText(toI32(x), toI32(y), str, toU8(c), toU1(font_id));
    return x + @as(f64, @floatFromInt(w));
}

export fn gfx_draw_text_double(x: f64, y: f64, val: f64, c: f64, font_id: f64) callconv(.c) f64 {
    var buf: [64]u8 = undefined;
    // Format double, avoiding scientific notation if possible for "natural" look
    const str = std.fmt.bufPrint(&buf, "{d}", .{val}) catch return x;
    const w = GraphicsState.textWidth(str);
    state().drawText(toI32(x), toI32(y), str, toU8(c), toU1(font_id));
    return x + @as(f64, @floatFromInt(w));
}

export fn gfx_text_width(desc: ?*const anyopaque, _: f64) callconv(.c) f64 {
    const slice = getStringSlice(desc);
    return @floatFromInt(GraphicsState.textWidth(slice));
}

export fn gfx_text_height(font_id: f64) callconv(.c) f64 {
    return @floatFromInt(GraphicsState.textHeight(toU1(font_id)));
}

// ═══════════════════════════════════════════════════════════════════════════
// Frame Control (enqueue commands + sync)
// ═══════════════════════════════════════════════════════════════════════════

export fn gfx_flip() callconv(.c) void {
    state().flip();
}

export fn gfx_vsync() callconv(.c) void {
    state().vsync();

    // Process AppKit events if in AOT mode
    aot_appkit_process_events();
}

/// WAIT FRAMES n — suspend the JIT thread for exactly n display frames.
/// The JIT thread blocks on a condition variable; the main thread decrements
/// the counter once per vsync and signals when it reaches zero.
export fn gfx_wait_frames(n: f64) callconv(.c) void {
    const count: u32 = if (n >= 1.0) @intFromFloat(@min(n, 1_000_000.0)) else 0;
    state().waitFrames(count);
}

export fn gfx_set_scroll(sx: f64, sy: f64) callconv(.c) void {
    state().setScroll(toI16(sx), toI16(sy));
}

// ═══════════════════════════════════════════════════════════════════════════
// Menu System (enqueue commands + event polling)
// ═══════════════════════════════════════════════════════════════════════════

export fn gfx_menu_reset() callconv(.c) void {
    state().menuReset();
}

export fn gfx_menu_add_menu(menu_id: f64, title_desc: ?*const anyopaque) callconv(.c) void {
    const title = getStringSlice(title_desc);
    state().menuDefine(toU8(menu_id), title);
}

export fn gfx_menu_add_item(menu_id: f64, item_id: f64, label_desc: ?*const anyopaque, shortcut_desc: ?*const anyopaque, flags: f64) callconv(.c) void {
    const label = getStringSlice(label_desc);
    const shortcut = getStringSlice(shortcut_desc);
    const f: u16 = @intCast(toU32(flags) & 0xFFFF);
    state().menuAddItem(toU8(menu_id), toU16(item_id), label, shortcut, f);
}

export fn gfx_menu_add_separator(menu_id: f64) callconv(.c) void {
    state().menuAddSeparator(toU8(menu_id));
}

export fn gfx_menu_set_checked(item_id: f64, on: f64) callconv(.c) void {
    state().menuSetChecked(toU16(item_id), toBool(on));
}

export fn gfx_menu_set_enabled(item_id: f64, on: f64) callconv(.c) void {
    state().menuSetEnabled(toU16(item_id), toBool(on));
}

export fn gfx_menu_rename(item_id: f64, label_desc: ?*const anyopaque) callconv(.c) void {
    const label = getStringSlice(label_desc);
    state().menuRename(toU16(item_id), label);
}

export fn gfx_menu_next() callconv(.c) f64 {
    return @floatFromInt(state().menuNext());
}

// ═══════════════════════════════════════════════════════════════════════════
// Dialog System (main-thread bridge wrappers)
// ═══════════════════════════════════════════════════════════════════════════

export fn gfx_dialog_reset() callconv(.c) void {
    gfx_dialog_reset_bridge();
}

export fn gfx_dialog_begin(dialog_id: f64) callconv(.c) void {
    gfx_dialog_begin_bridge(toU16(dialog_id));
}

export fn gfx_dialog_set_title(title_desc: ?*const anyopaque) callconv(.c) void {
    const title = getStringSlice(title_desc);
    gfx_dialog_set_title_bridge(if (title.len > 0) title.ptr else null, @intCast(title.len));
}

export fn gfx_dialog_set_message(message_desc: ?*const anyopaque) callconv(.c) void {
    const msg = getStringSlice(message_desc);
    gfx_dialog_set_message_bridge(if (msg.len > 0) msg.ptr else null, @intCast(msg.len));
}

export fn gfx_dialog_add_label(text_desc: ?*const anyopaque) callconv(.c) void {
    const text = getStringSlice(text_desc);
    gfx_dialog_add_label_bridge(if (text.len > 0) text.ptr else null, @intCast(text.len));
}

export fn gfx_dialog_add_textfield(control_id: f64, label_desc: ?*const anyopaque, default_desc: ?*const anyopaque) callconv(.c) void {
    const label = getStringSlice(label_desc);
    const def = getStringSlice(default_desc);
    gfx_dialog_add_textfield_bridge(toU16(control_id), if (label.len > 0) label.ptr else null, @intCast(label.len), if (def.len > 0) def.ptr else null, @intCast(def.len));
}

export fn gfx_dialog_add_securefield(control_id: f64, label_desc: ?*const anyopaque, default_desc: ?*const anyopaque) callconv(.c) void {
    const label = getStringSlice(label_desc);
    const def = getStringSlice(default_desc);
    gfx_dialog_add_securefield_bridge(toU16(control_id), if (label.len > 0) label.ptr else null, @intCast(label.len), if (def.len > 0) def.ptr else null, @intCast(def.len));
}

export fn gfx_dialog_add_textarea(control_id: f64, label_desc: ?*const anyopaque, default_desc: ?*const anyopaque) callconv(.c) void {
    const label = getStringSlice(label_desc);
    const def = getStringSlice(default_desc);
    gfx_dialog_add_textarea_bridge(toU16(control_id), if (label.len > 0) label.ptr else null, @intCast(label.len), if (def.len > 0) def.ptr else null, @intCast(def.len));
}

export fn gfx_dialog_add_numberfield(control_id: f64, label_desc: ?*const anyopaque, default_value: f64, min_value: f64, max_value: f64, step: f64) callconv(.c) void {
    const label = getStringSlice(label_desc);
    gfx_dialog_add_numberfield_bridge(toU16(control_id), if (label.len > 0) label.ptr else null, @intCast(label.len), default_value, min_value, max_value, step);
}

export fn gfx_dialog_add_slider(control_id: f64, label_desc: ?*const anyopaque, min_value: f64, max_value: f64, default_value: f64) callconv(.c) void {
    const label = getStringSlice(label_desc);
    gfx_dialog_add_slider_bridge(toU16(control_id), if (label.len > 0) label.ptr else null, @intCast(label.len), min_value, max_value, default_value);
}

export fn gfx_dialog_add_filepicker(control_id: f64, label_desc: ?*const anyopaque, default_desc: ?*const anyopaque) callconv(.c) void {
    const label = getStringSlice(label_desc);
    const def = getStringSlice(default_desc);
    gfx_dialog_add_filepicker_bridge(toU16(control_id), if (label.len > 0) label.ptr else null, @intCast(label.len), if (def.len > 0) def.ptr else null, @intCast(def.len));
}

export fn gfx_dialog_add_checkbox(control_id: f64, label_desc: ?*const anyopaque, checked: f64) callconv(.c) void {
    const label = getStringSlice(label_desc);
    gfx_dialog_add_checkbox_bridge(toU16(control_id), if (label.len > 0) label.ptr else null, @intCast(label.len), if (toBool(checked)) 1 else 0);
}

export fn gfx_dialog_add_radio(control_id: f64, group_id: f64, label_desc: ?*const anyopaque, selected: f64) callconv(.c) void {
    const label = getStringSlice(label_desc);
    gfx_dialog_add_radio_bridge(toU16(control_id), toU16(group_id), if (label.len > 0) label.ptr else null, @intCast(label.len), if (toBool(selected)) 1 else 0);
}

export fn gfx_dialog_add_dropdown(control_id: f64, label_desc: ?*const anyopaque, options_desc: ?*const anyopaque, default_index: f64) callconv(.c) void {
    const label = getStringSlice(label_desc);
    const options = getStringSlice(options_desc);
    gfx_dialog_add_dropdown_bridge(toU16(control_id), if (label.len > 0) label.ptr else null, @intCast(label.len), if (options.len > 0) options.ptr else null, @intCast(options.len), toI32(default_index));
}

export fn gfx_dialog_add_button(control_id: f64, label_desc: ?*const anyopaque, flags: f64) callconv(.c) void {
    const label = getStringSlice(label_desc);
    gfx_dialog_add_button_bridge(toU16(control_id), if (label.len > 0) label.ptr else null, @intCast(label.len), @intCast(toU32(flags) & 0xFF));
}

export fn gfx_dialog_end() callconv(.c) void {
    gfx_dialog_end_bridge();
}

export fn gfx_dialog_show(dialog_id: f64) callconv(.c) f64 {
    return @floatFromInt(gfx_dialog_show_bridge(toU16(dialog_id)));
}

export fn gfx_dialog_get_text(control_id: f64) callconv(.c) ?*anyopaque {
    const cstr = gfx_dialog_get_text_bridge(toU16(control_id));
    return string_new_utf8(cstr);
}

export fn gfx_dialog_get_checked(control_id: f64) callconv(.c) f64 {
    return if (gfx_dialog_get_checked_bridge(toU16(control_id)) != 0) 1.0 else 0.0;
}

export fn gfx_dialog_get_selection(control_id: f64) callconv(.c) f64 {
    return @floatFromInt(gfx_dialog_get_selection_bridge(toU16(control_id)));
}

export fn gfx_dialog_set_text(control_id: f64, value_desc: ?*const anyopaque) callconv(.c) void {
    const value = getStringSlice(value_desc);
    gfx_dialog_set_text_bridge(toU16(control_id), if (value.len > 0) value.ptr else null, @intCast(value.len));
}

export fn gfx_dialog_set_number(control_id: f64, value: f64) callconv(.c) void {
    gfx_dialog_set_number_bridge(toU16(control_id), value);
}

export fn gfx_dialog_set_checked(control_id: f64, on: f64) callconv(.c) void {
    gfx_dialog_set_checked_bridge(toU16(control_id), if (toBool(on)) 1 else 0);
}

export fn gfx_dialog_set_selection(control_id: f64, index: f64) callconv(.c) void {
    gfx_dialog_set_selection_bridge(toU16(control_id), toI32(index));
}

// ═══════════════════════════════════════════════════════════════════════════
// Synchronisation
// ═══════════════════════════════════════════════════════════════════════════

export fn gfx_commit() callconv(.c) f64 {
    return @floatFromInt(state().commit());
}

export fn gfx_wait() callconv(.c) void {
    state().waitGpu();
}

export fn gfx_fence() callconv(.c) f64 {
    // Return the most recently issued fence id
    return @floatFromInt(state().next_fence_id -% 1);
}

export fn gfx_fence_done(fence_id: f64) callconv(.c) f64 {
    return if (state().fenceDone(@intFromFloat(fence_id))) 1.0 else 0.0;
}

// ═══════════════════════════════════════════════════════════════════════════
// Collision Detection (enqueue GPU dispatch)
// ═══════════════════════════════════════════════════════════════════════════

export fn gfx_collide(ba: f64, ax: f64, ay: f64, bb: f64, bx: f64, by: f64, w: f64, h: f64) callconv(.c) f64 {
    // Single-pair collision: dispatch, commit, wait, read result
    const s = state();

    // Set up as a 2-source batch
    s.collideSetup(2);
    s.collideSrc(0, toU3(ba), toI16(ax), toI16(ay), toU16(w), toU16(h));
    s.collideSrc(1, toU3(bb), toI16(bx), toI16(by), toU16(w), toU16(h));
    s.collideTest();
    _ = s.commit();
    s.waitGpu();

    return if (s.collideResult(0, 1)) 1.0 else 0.0;
}

export fn gfx_collide_setup(n: f64) callconv(.c) void {
    state().collideSetup(toU8(n));
}

export fn gfx_collide_src(i: f64, buf: f64, x: f64, y: f64, w: f64, h: f64) callconv(.c) void {
    state().collideSrc(toU8(i), toU3(buf), toI16(x), toI16(y), toU16(w), toU16(h));
}

export fn gfx_collide_test() callconv(.c) void {
    state().collideTest();
}

export fn gfx_collide_result(i: f64, j: f64) callconv(.c) f64 {
    return if (state().collideResult(toU8(i), toU8(j))) 1.0 else 0.0;
}

// ═══════════════════════════════════════════════════════════════════════════
// Input (read atomic state — no queue)
// ═══════════════════════════════════════════════════════════════════════════

export fn gfx_inkey() callconv(.c) f64 {
    return @floatFromInt(state().inkey());
}

export fn gfx_keydown(keycode: f64) callconv(.c) f64 {
    return if (state().keyDown(toU8(keycode))) 1.0 else 0.0;
}

export fn gfx_mousex() callconv(.c) f64 {
    return @floatFromInt(state().mouseX());
}

export fn gfx_mousey() callconv(.c) f64 {
    return @floatFromInt(state().mouseY());
}

export fn gfx_mousebutton() callconv(.c) f64 {
    return @floatFromInt(state().mouseButton());
}

export fn gfx_mousescroll() callconv(.c) f64 {
    return @floatFromInt(state().mouseScroll());
}

export fn gfx_joy_count() callconv(.c) f64 {
    return @floatFromInt(state().joyCount());
}

export fn gfx_joy_axis(controller: f64, axis: f64) callconv(.c) f64 {
    return @floatCast(state().joyAxis(toU8(controller), toU8(axis)));
}

export fn gfx_joy_button(controller: f64, button: f64) callconv(.c) f64 {
    return if (state().joyButton(toU8(controller), toU8(button))) 1.0 else 0.0;
}

// ═══════════════════════════════════════════════════════════════════════════
// Queries
// ═══════════════════════════════════════════════════════════════════════════

export fn gfx_screen_width() callconv(.c) f64 {
    return @floatFromInt(state().screenWidth());
}

export fn gfx_screen_height() callconv(.c) f64 {
    return @floatFromInt(state().screenHeight());
}

export fn gfx_screen_active() callconv(.c) f64 {
    return if (state().isActive()) 1.0 else 0.0;
}

export fn gfx_front_buffer() callconv(.c) f64 {
    return @floatFromInt(state().frontBuffer());
}

export fn gfx_buffer_width() callconv(.c) f64 {
    return @floatFromInt(state().bufferWidth());
}

export fn gfx_buffer_height() callconv(.c) f64 {
    return @floatFromInt(state().bufferHeight());
}

/// GBASE(bufferno) -- return raw pointer to pixel buffer as integer.
/// bufferno: 0=front(A), 1=back(B), 2..7=extra buffers.
/// Returns 0 if the buffer is not allocated.
/// The pixel at logical (x, y) is at offset  y * GBUFFERWIDTH() + x.
export fn gfx_buffer_base(n: f64) callconv(.c) u64 {
    const idx = @as(u3, @intFromFloat(@max(0, @min(7, n))));
    const buf = state().buffers[idx] orelse return 0;
    return @intFromPtr(buf.ptr);
}

// ─── Force-retain all export fn symbols ─────────────────────────────────────
//
// The Zig linker dead-strips `export fn` symbols that aren't referenced from
// C/ObjC code, even with rdynamic = true.  The JIT linker resolves these at
// runtime via dlsym(RTLD_DEFAULT, …), so they MUST survive linking.
//
// Taking the address of each function in a `comptime` block that is
// reachable from the root source file prevents the linker from removing them.

comptime {
    const refs = .{
        // Window control
        &gfx_screen,
        &gfx_screen_close,
        &gfx_screen_title,
        &gfx_app_name,
        &gfx_screen_mode,
        &gfx_set_target,
        // Drawing primitives
        &gfx_pset,
        &gfx_pget,
        &gfx_line,
        &gfx_rect,
        &gfx_circle,
        &gfx_ellipse,
        &gfx_triangle,
        &gfx_fill_area,
        &gfx_cls,
        &gfx_scroll_buffer,
        // Blit operations
        &gfx_blit,
        &gfx_blit_solid,
        &gfx_blit_scale,
        &gfx_blit_flip,
        // Palette
        &gfx_palette,
        &gfx_line_palette,
        &gfx_reset_palette,
        &gfx_palette_get,
        &gfx_line_palette_get,
        // Palette effects
        &gfx_pal_cycle,
        &gfx_pal_cycle_lines,
        &gfx_pal_fade,
        &gfx_pal_fade_lines,
        &gfx_pal_pulse,
        &gfx_pal_pulse_lines,
        &gfx_pal_gradient,
        &gfx_pal_strobe,
        &gfx_pal_strobe_lines,
        &gfx_pal_stop,
        &gfx_pal_stop_all,
        &gfx_pal_pause,
        &gfx_pal_resume,
        // Text
        &gfx_draw_text,
        &gfx_text_width,
        &gfx_text_height,
        // Frame control
        &gfx_flip,
        &gfx_vsync,
        &gfx_set_scroll,
        // Menu system
        &gfx_menu_reset,
        &gfx_menu_add_menu,
        &gfx_menu_add_item,
        &gfx_menu_add_separator,
        &gfx_menu_set_checked,
        &gfx_menu_set_enabled,
        &gfx_menu_rename,
        &gfx_menu_next,
        // Dialog system
        &gfx_dialog_reset,
        &gfx_dialog_begin,
        &gfx_dialog_set_title,
        &gfx_dialog_set_message,
        &gfx_dialog_add_label,
        &gfx_dialog_add_textfield,
        &gfx_dialog_add_securefield,
        &gfx_dialog_add_textarea,
        &gfx_dialog_add_numberfield,
        &gfx_dialog_add_slider,
        &gfx_dialog_add_filepicker,
        &gfx_dialog_add_checkbox,
        &gfx_dialog_add_radio,
        &gfx_dialog_add_dropdown,
        &gfx_dialog_add_button,
        &gfx_dialog_end,
        &gfx_dialog_show,
        &gfx_dialog_get_text,
        &gfx_dialog_get_checked,
        &gfx_dialog_get_selection,
        &gfx_dialog_set_text,
        &gfx_dialog_set_number,
        &gfx_dialog_set_checked,
        &gfx_dialog_set_selection,
        // Sync
        &gfx_commit,
        &gfx_wait,
        &gfx_fence,
        &gfx_fence_done,
        // Collision
        &gfx_collide,
        &gfx_collide_setup,
        &gfx_collide_src,
        &gfx_collide_test,
        &gfx_collide_result,
        // Input
        &gfx_inkey,
        &gfx_keydown,
        &gfx_mousex,
        &gfx_mousey,
        &gfx_mousebutton,
        &gfx_mousescroll,
        &gfx_joy_count,
        &gfx_joy_axis,
        &gfx_joy_button,
        // Query
        &gfx_screen_width,
        &gfx_screen_height,
        &gfx_screen_active,
        &gfx_front_buffer,
        &gfx_buffer_width,
        &gfx_buffer_height,
        &gfx_buffer_base,
        // Sprites — definition
        &gfx_sprite_load,
        &gfx_sprite_def,
        &gfx_sprite_data,
        &gfx_sprite_palette,
        &gfx_sprite_std_pal,
        &gfx_sprite_frames,
        // Sprites — instance
        &gfx_sprite,
        &gfx_sprite_pos,
        &gfx_sprite_move,
        &gfx_sprite_rot,
        &gfx_sprite_scale,
        &gfx_sprite_anchor,
        &gfx_sprite_show,
        &gfx_sprite_hide,
        &gfx_sprite_flip,
        &gfx_sprite_alpha,
        &gfx_sprite_frame,
        &gfx_sprite_animate,
        &gfx_sprite_priority,
        &gfx_sprite_blend,
        &gfx_sprite_remove,
        &gfx_sprite_remove_all,
        // Sprites — effects
        &gfx_sprite_fx,
        &gfx_sprite_fx_param,
        &gfx_sprite_fx_colour,
        &gfx_sprite_glow,
        &gfx_sprite_outline,
        &gfx_sprite_shadow,
        &gfx_sprite_tint,
        &gfx_sprite_flash,
        &gfx_sprite_fx_off,
        // Sprites — palette override
        &gfx_sprite_pal_override,
        &gfx_sprite_pal_reset,
        // Sprites — queries
        &gfx_sprite_x,
        &gfx_sprite_y,
        &gfx_sprite_get_rot,
        &gfx_sprite_visible,
        &gfx_sprite_get_frame,
        &gfx_sprite_hit,
        &gfx_sprite_count,
        // Sprites — collision
        &gfx_sprite_collide,
        &gfx_sprite_overlap,
        // Screen save
        &gfx_screensave,
    };
    _ = refs;
}

// ═══════════════════════════════════════════════════════════════════════════
// Sprite System — GPU-Driven Sprite Commands
// ═══════════════════════════════════════════════════════════════════════════
//
// All sprite rendering is GPU-side.  These functions only update lightweight
// CPU-side descriptors (a few field writes per call).  The descriptors are
// synced to the GPU shared buffer once per frame during VSYNC.

// ─── Sprite Helpers ─────────────────────────────────────────────────────────

inline fn sprites() *sprite.SpriteBank {
    return &state().sprites;
}

fn enqueueUpload(atlas_x: u16, atlas_y: u16, w: u16, h: u16, pixel_ptr: u64) void {
    var cmd = gfx.GfxCommand.init(.sprite_upload);
    var payload: sprite.SpriteUploadPayload = .{
        .atlas_x = atlas_x,
        .atlas_y = atlas_y,
        .width = w,
        .height = h,
        .pixel_ptr = pixel_ptr,
    };
    @memcpy(cmd.payload[0..@sizeOf(sprite.SpriteUploadPayload)], std.mem.asBytes(&payload));
    state().enqueueCommand(cmd);
}

// ─── Sprite Definition Commands ─────────────────────────────────────────────

/// SPRITELOAD id, filename$
/// Load a .sprtz file into definition slot `id`.
export fn gfx_sprite_load(id: f64, desc: ?*const anyopaque) callconv(.c) void {
    const slot = toU16(id);
    if (slot >= sprite.MAX_DEFINITIONS) return;
    const path = getStringSlice(desc);
    if (path.len == 0) return;

    // Read the file
    const file_data = std.fs.cwd().readFileAlloc(std.heap.page_allocator, path, 1024 * 1024) catch return;
    defer std.heap.page_allocator.free(file_data);

    // Parse SPRTZ format
    if (file_data.len < 16) return;

    // Validate magic "SPTZ"
    if (!std.mem.eql(u8, file_data[0..4], "SPTZ")) return;

    const version = std.mem.readInt(u16, file_data[4..6], .little);
    if (version != 1 and version != 2) return;

    const width: u16 = file_data[6];
    const height: u16 = file_data[7];
    if (width == 0 or height == 0) return;
    if (width > sprite.MAX_SPRITE_SIZE or height > sprite.MAX_SPRITE_SIZE) return;

    const uncompressed_size = std.mem.readInt(u32, file_data[8..12], .little);
    const compressed_size = std.mem.readInt(u32, file_data[12..16], .little);
    _ = uncompressed_size;

    // Build palette
    var palette: [16]gfx.RGBA32 = undefined;
    palette[0] = gfx.RGBA32.TRANSPARENT;
    palette[1] = gfx.RGBA32.BLACK;

    var offset: usize = 16;

    if (version == 1) {
        // v1: 14 RGB entries for indices 2–15 (42 bytes)
        if (file_data.len < offset + 42) return;
        for (2..16) |i| {
            palette[i] = .{
                .r = file_data[offset],
                .g = file_data[offset + 1],
                .b = file_data[offset + 2],
                .a = 255,
            };
            offset += 3;
        }
    } else {
        // v2: palette mode byte
        if (file_data.len < offset + 1) return;
        const mode = file_data[offset];
        offset += 1;
        if (mode == 0xFF) {
            // Custom palette
            if (file_data.len < offset + 42) return;
            for (2..16) |i| {
                palette[i] = .{
                    .r = file_data[offset],
                    .g = file_data[offset + 1],
                    .b = file_data[offset + 2],
                    .a = 255,
                };
                offset += 3;
            }
        } else if (mode < 32) {
            // Standard palette — use default colours for now
            // TODO: implement sprite_palettes.zig lookup
            for (2..16) |i| {
                palette[i] = gfx.RGBA32.WHITE;
            }
        } else {
            return; // Invalid palette mode
        }
    }

    // Decompress pixel data (zlib / deflate)
    if (file_data.len < offset + compressed_size) return;
    const compressed = file_data[offset .. offset + compressed_size];
    const pixel_count: u32 = @as(u32, width) * @as(u32, height);

    var pixel_buf: [256 * 256]u8 = undefined;
    if (pixel_count > pixel_buf.len) return;

    // Zig 0.15: use std.compress.flate with Container.zlib
    var input_reader: std.Io.Reader = .fixed(compressed);
    var window_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&input_reader, .zlib, &window_buf);
    var output_writer: std.Io.Writer = .fixed(pixel_buf[0..pixel_count]);
    decompress.reader.streamExact(&output_writer, pixel_count) catch return;

    // Load into sprite bank
    if (!sprites().loadDefinition(slot, pixel_buf[0..pixel_count], width, height, palette)) return;

    // Get atlas rect from the definition for the upload command
    if (sprites().gpu_atlas_entries) |entries| {
        const entry = entries[slot];
        // pixel_buf is on the stack — malloc a copy so the upload command owns it.
        var pixel_ptr: u64 = 0;
        if (std.c.malloc(pixel_count)) |snapshot| {
            @memcpy(@as([*]u8, @ptrCast(snapshot))[0..pixel_count], pixel_buf[0..pixel_count]);
            pixel_ptr = @intFromPtr(snapshot);
        }
        enqueueUpload(@intCast(entry.atlas_x), @intCast(entry.atlas_y), width, height, pixel_ptr);
    }
}

/// SPRITEDEF id, width, height
/// Create an empty sprite definition.
export fn gfx_sprite_def(id: f64, w: f64, h: f64) callconv(.c) void {
    const slot = toU16(id);
    const width = toU16(w);
    const height = toU16(h);

    if (!sprites().defineEmpty(slot, width, height)) return;

    // Enqueue upload of zeroed pixels (pixel_ptr=0 → bridge skips blit;
    // the atlas region is already zeroed so transparent is correct until
    // SPRITE DATA + SPRITE COMMIT fills the pixels)
    if (sprites().gpu_atlas_entries) |entries| {
        const entry = entries[slot];
        enqueueUpload(@intCast(entry.atlas_x), @intCast(entry.atlas_y), width, height, 0);
    }
}

/// SPRITEDATA id, x, y, colourIndex
/// Set a single pixel in a sprite definition.
/// Writes to the CPU-side staging buffer only — does NOT enqueue a GPU
/// upload.  Call SPRITE COMMIT id after finishing all SPRITEDATA calls
/// to flush the staging buffer to the atlas in a single GPU operation.
export fn gfx_sprite_data(id: f64, x: f64, y: f64, c: f64) callconv(.c) void {
    sprites().setPixel(toU16(id), toU16(x), toU16(y), toU8(c));
}

/// SPRITE COMMIT id
/// Flush the staging buffer for sprite definition `id` to the GPU atlas
/// texture.  Call this once after all SPRITEDATA calls for a definition.
export fn gfx_sprite_commit(id: f64) callconv(.c) void {
    const slot = toU16(id);
    if (slot >= sprite.MAX_DEFINITIONS) return;
    if (!sprites().definitions[slot].active) return;
    if (sprites().gpu_atlas_entries) |entries| {
        const entry = entries[slot];
        const def = &sprites().definitions[slot];
        // Snapshot the staging buffer now (on the JIT thread) so the upload
        // command carries its own pixel data.  The staging buffer may be
        // reused by the next SPRITE DATA calls for a different definition
        // before the main thread drains the command queue.
        const nbytes: usize = @as(usize, def.width) * @as(usize, def.height);
        var pixel_ptr: u64 = 0;
        if (sprites().staging_buffer) |staging| {
            if (std.c.malloc(nbytes)) |snapshot| {
                @memcpy(@as([*]u8, @ptrCast(snapshot))[0..nbytes], staging[0..nbytes]);
                pixel_ptr = @intFromPtr(snapshot);
            }
        }
        enqueueUpload(@intCast(entry.atlas_x), @intCast(entry.atlas_y), def.width, def.height, pixel_ptr);
    }
}

/// SPRITE ROW row, c0, c1, ...
/// Copy up to `count` bytes from `data` into the active sprite canvas staging
/// buffer at row `row`.  Pixels beyond the sprite width are ignored; pixels
/// not covered by `data` are left at their current value (transparent after
/// GCLS 0 or SPRITE DEF).  Values are masked to 0-15 (palette indices).
/// Must be called between SPRITE BEGIN / SPRITE END.
export fn gfx_sprite_row(row: f64, data: [*]const u8, count: f64) callconv(.c) void {
    const gs = state();
    const buf = gs.sprite_canvas_buf orelse return;
    const w = @as(usize, gs.sprite_canvas_w);
    const fw = @as(usize, gs.sprite_frame_w);
    const fh = @as(usize, gs.sprite_frame_h);
    const fx = @as(usize, gs.sprite_frame_x);
    const fy = @as(usize, gs.sprite_frame_y);

    const r = @as(usize, @intFromFloat(row));
    if (r >= fh) return;

    const n = @min(@as(usize, @intFromFloat(count)), fw);
    const base = (fy + r) * w + fx;
    for (0..n) |x| {
        buf[base + x] = data[x] & 0x0F;
    }
}

/// SPRITE BEGIN id
/// Redirect all drawing commands (PSET, LINE, RECT, CIRCLE, GCLS, etc.) into
/// sprite definition `id`'s staging buffer.  Coordinates are sprite-local:
/// (0,0) is the top-left pixel of the sprite; the sprite's width/height form
/// the drawing bounds.  Colour values are masked to 0–15 (atlas palette
/// indices).  Call SPRITE END to commit the pixels to the GPU atlas and
/// restore normal screen drawing.
export fn gfx_sprite_begin(id: f64) callconv(.c) void {
    _ = state().beginSpriteCanvas(toU16(id));
}

/// SPRITE END
/// Finish drawing into the current sprite canvas, upload the staged pixels to
/// the GPU atlas, and restore normal screen drawing.  Equivalent to calling
/// SPRITE COMMIT followed by SPRITE BEGIN -1.
export fn gfx_sprite_end() callconv(.c) void {
    state().endSpriteCanvas();
}

/// SPRITEPALETTE id, index, r, g, b
/// Set a palette colour for a sprite definition.
export fn gfx_sprite_palette(id: f64, idx: f64, r: f64, g: f64, b: f64) callconv(.c) void {
    sprites().setPaletteColour(toU16(id), toU8(idx), toU8(r), toU8(g), toU8(b));
}

/// SPRITESTDPAL id, paletteID
/// Assign a standard palette to a sprite definition.
export fn gfx_sprite_std_pal(id: f64, pal_id: f64) callconv(.c) void {
    _ = id;
    _ = pal_id;
    // TODO: implement when sprite_palettes.zig is created
}

/// SPRITEFRAMES id, frameW, frameH, count
/// Declare animation strip layout.
export fn gfx_sprite_frames(id: f64, fw: f64, fh: f64, count: f64) callconv(.c) void {
    sprites().setFrames(toU16(id), toU16(fw), toU16(fh), toU16(count));
}

/// SPRITE FRAME n (inside SPRITE BEGIN)
/// Set the active viewport for drawing to a specific frame.
export fn gfx_sprite_set_frame(frame: f64) callconv(.c) void {
    const gs = state();
    if (gs.sprite_canvas_buf == null) return;

    const id = @as(u16, @intCast(gs.sprite_canvas_id));
    const def = &gs.sprites.definitions[id];

    const f = @as(u16, @intFromFloat(frame));
    if (f >= def.frame_count) return;

    // Calculate grid position (assuming horizontal strip for now, or wrapping if needed)
    // The current implementation of setFrames assumes a horizontal strip if frame_w < width
    const frames_per_row = if (def.frame_w > 0) def.width / def.frame_w else 1;
    if (frames_per_row == 0) return;

    const col = f % frames_per_row;
    const row = f / frames_per_row;

    gs.sprite_frame_x = col * def.frame_w;
    gs.sprite_frame_y = row * def.frame_h;
    gs.sprite_frame_w = def.frame_w;
    gs.sprite_frame_h = def.frame_h;
}

// ─── Sprite Instance Commands ───────────────────────────────────────────────

/// SPRITE instance, defID, x, y
/// Create/place a sprite instance.
export fn gfx_sprite(inst: f64, def: f64, x: f64, y: f64) callconv(.c) void {
    sprites().placeInstance(toU16(inst), toU16(def), @floatCast(x), @floatCast(y));
}

/// SPRITEPOS instance, x, y
/// Set sprite position.
export fn gfx_sprite_pos(inst: f64, x: f64, y: f64) callconv(.c) void {
    if (sprites().getInstance(toU16(inst))) |s| {
        s.x = @floatCast(x);
        s.y = @floatCast(y);
    }
}

/// SPRITEMOVE instance, dx, dy
/// Relative move.
export fn gfx_sprite_move(inst: f64, dx: f64, dy: f64) callconv(.c) void {
    if (sprites().getInstance(toU16(inst))) |s| {
        s.x += @as(f32, @floatCast(dx));
        s.y += @as(f32, @floatCast(dy));
    }
}

/// SPRITEROT instance, angle_degrees
/// Set rotation in degrees (converted to radians internally).
export fn gfx_sprite_rot(inst: f64, angle_deg: f64) callconv(.c) void {
    if (sprites().getInstance(toU16(inst))) |s| {
        s.rotation = @as(f32, @floatCast(angle_deg * std.math.pi / 180.0));
    }
}

/// SPRITESCALE instance, sx, sy
/// Set scale factors.
export fn gfx_sprite_scale(inst: f64, sx: f64, sy: f64) callconv(.c) void {
    if (sprites().getInstance(toU16(inst))) |s| {
        s.scale_x = @floatCast(sx);
        s.scale_y = @floatCast(sy);
    }
}

/// SPRITEANCHOR instance, ax, ay
/// Set rotation/scale pivot point (0–1, default 0.5 = centre).
export fn gfx_sprite_anchor(inst: f64, ax: f64, ay: f64) callconv(.c) void {
    if (sprites().getInstance(toU16(inst))) |s| {
        s.anchor_x = @floatCast(ax);
        s.anchor_y = @floatCast(ay);
    }
}

/// SPRITESHOW instance
export fn gfx_sprite_show(inst: f64) callconv(.c) void {
    if (sprites().getInstance(toU16(inst))) |s| {
        s.visible = true;
    }
}

/// SPRITEHIDE instance
export fn gfx_sprite_hide(inst: f64) callconv(.c) void {
    if (sprites().getInstance(toU16(inst))) |s| {
        s.visible = false;
    }
}

/// SPRITEFLIP instance, h, v
export fn gfx_sprite_flip(inst: f64, h: f64, v: f64) callconv(.c) void {
    if (sprites().getInstance(toU16(inst))) |s| {
        s.flip_h = toBool(h);
        s.flip_v = toBool(v);
    }
}

/// SPRITEALPHA instance, alpha (0.0–1.0)
export fn gfx_sprite_alpha(inst: f64, a: f64) callconv(.c) void {
    if (sprites().getInstance(toU16(inst))) |s| {
        s.alpha = @floatCast(std.math.clamp(a, 0.0, 1.0));
    }
}

/// SPRITEFRAME instance, frame
export fn gfx_sprite_frame(inst: f64, frame: f64) callconv(.c) void {
    if (sprites().getInstance(toU16(inst))) |s| {
        s.frame = toU16(frame);
    }
}

/// SPRITEANIMATE instance, speed (frames per tick, 0=manual)
export fn gfx_sprite_animate(inst: f64, speed: f64) callconv(.c) void {
    if (sprites().getInstance(toU16(inst))) |s| {
        s.anim_speed = @floatCast(@max(speed, 0.0));
    }
}

/// SPRITEPRIORITY instance, priority (lower = behind)
export fn gfx_sprite_priority(inst: f64, pri: f64) callconv(.c) void {
    if (sprites().getInstance(toU16(inst))) |s| {
        s.priority = toU32(pri);
    }
}

/// SPRITEBLEND instance, mode (0=normal, 1=additive)
export fn gfx_sprite_blend(inst: f64, mode: f64) callconv(.c) void {
    if (sprites().getInstance(toU16(inst))) |s| {
        s.additive = toBool(mode);
    }
}

/// SPRITEREMOVE instance
export fn gfx_sprite_remove(inst: f64) callconv(.c) void {
    sprites().removeInstance(toU16(inst));
}

/// SPRITEREMOVEALL
export fn gfx_sprite_remove_all() callconv(.c) void {
    sprites().removeAll();
}

// ─── Sprite Effect Commands ─────────────────────────────────────────────────

/// SPRITEFX instance, type (0–6)
export fn gfx_sprite_fx(inst: f64, fx_type: f64) callconv(.c) void {
    if (sprites().getInstance(toU16(inst))) |s| {
        const t: u8 = toU8(fx_type);
        s.effect_type = if (t <= 6) @enumFromInt(t) else .none;
    }
}

/// SPRITEFXPARAM instance, param1, param2
export fn gfx_sprite_fx_param(inst: f64, p1: f64, p2: f64) callconv(.c) void {
    if (sprites().getInstance(toU16(inst))) |s| {
        s.effect_param1 = @floatCast(p1);
        s.effect_param2 = @floatCast(p2);
    }
}

/// SPRITEFXCOLOUR instance, r, g, b, a
export fn gfx_sprite_fx_colour(inst: f64, r: f64, g: f64, b: f64, a: f64) callconv(.c) void {
    if (sprites().getInstance(toU16(inst))) |s| {
        s.effect_colour = .{ .r = toU8(r), .g = toU8(g), .b = toU8(b), .a = toU8(a) };
    }
}

/// SPRITEGLOW instance, radius, intensity, r, g, b
/// Shorthand: sets effect type to glow with params and colour.
export fn gfx_sprite_glow(inst: f64, radius: f64, intensity: f64, r: f64, g: f64, b: f64) callconv(.c) void {
    if (sprites().getInstance(toU16(inst))) |s| {
        s.effect_type = .glow;
        s.effect_param1 = @floatCast(@max(radius, 1.0));
        s.effect_param2 = @floatCast(std.math.clamp(intensity, 0.0, 10.0));
        s.effect_colour = .{ .r = toU8(r), .g = toU8(g), .b = toU8(b), .a = 255 };
    }
}

/// SPRITEOUTLINE instance, thickness, r, g, b
export fn gfx_sprite_outline(inst: f64, thickness: f64, r: f64, g: f64, b: f64) callconv(.c) void {
    if (sprites().getInstance(toU16(inst))) |s| {
        s.effect_type = .outline;
        s.effect_param1 = @floatCast(@max(thickness, 1.0));
        s.effect_param2 = 0;
        s.effect_colour = .{ .r = toU8(r), .g = toU8(g), .b = toU8(b), .a = 255 };
    }
}

/// SPRITESHADOW instance, offsetX, offsetY, r, g, b, a
export fn gfx_sprite_shadow(inst: f64, ox: f64, oy: f64, r: f64, g: f64, b: f64, a: f64) callconv(.c) void {
    if (sprites().getInstance(toU16(inst))) |s| {
        s.effect_type = .shadow;
        s.effect_param1 = @floatCast(ox);
        s.effect_param2 = @floatCast(oy);
        s.effect_colour = .{ .r = toU8(r), .g = toU8(g), .b = toU8(b), .a = toU8(a) };
    }
}

/// SPRITETINT instance, factor, r, g, b
export fn gfx_sprite_tint(inst: f64, factor: f64, r: f64, g: f64, b: f64) callconv(.c) void {
    if (sprites().getInstance(toU16(inst))) |s| {
        s.effect_type = .tint;
        s.effect_param1 = @floatCast(std.math.clamp(factor, 0.0, 1.0));
        s.effect_param2 = 0;
        s.effect_colour = .{ .r = toU8(r), .g = toU8(g), .b = toU8(b), .a = 255 };
    }
}

/// SPRITEFLASH instance, speed, r, g, b
export fn gfx_sprite_flash(inst: f64, speed: f64, r: f64, g: f64, b: f64) callconv(.c) void {
    if (sprites().getInstance(toU16(inst))) |s| {
        s.effect_type = .flash;
        s.effect_param1 = @floatCast(@max(speed, 1.0));
        s.effect_param2 = 0;
        s.effect_colour = .{ .r = toU8(r), .g = toU8(g), .b = toU8(b), .a = 255 };
    }
}

/// SPRITEFXOFF instance
/// Clear all effects from an instance.
export fn gfx_sprite_fx_off(inst: f64) callconv(.c) void {
    if (sprites().getInstance(toU16(inst))) |s| {
        s.effect_type = .none;
        s.effect_param1 = 0;
        s.effect_param2 = 0;
        s.effect_colour = gfx.RGBA32.WHITE;
    }
}

// ─── Sprite Palette Override Commands ───────────────────────────────────────

/// SPRITEPALOVERRIDE instance, defID
/// Make this instance use another definition's palette.
export fn gfx_sprite_pal_override(inst: f64, def_id: f64) callconv(.c) void {
    const did = toU16(def_id);
    if (did >= sprite.MAX_DEFINITIONS) return;
    if (!sprites().definitions[did].active) return;

    if (sprites().getInstance(toU16(inst))) |s| {
        // palette_override is 1-based: 0 = use definition palette,
        // N = use palette at index (N-1)
        s.palette_override = sprites().definitions[did].palette_index + 1;
    }
}

/// SPRITEPALRESET instance
/// Reset to definition's own palette.
export fn gfx_sprite_pal_reset(inst: f64) callconv(.c) void {
    if (sprites().getInstance(toU16(inst))) |s| {
        s.palette_override = 0;
    }
}

// ─── Sprite Query Functions ─────────────────────────────────────────────────

/// SPRITEX(instance) → SINGLE
export fn gfx_sprite_x(inst: f64) callconv(.c) f64 {
    if (sprites().getInstance(toU16(inst))) |s| {
        return @as(f64, s.x);
    }
    return 0;
}

/// SPRITEY(instance) → SINGLE
export fn gfx_sprite_y(inst: f64) callconv(.c) f64 {
    if (sprites().getInstance(toU16(inst))) |s| {
        return @as(f64, s.y);
    }
    return 0;
}

/// SPRITEROT(instance) → SINGLE (degrees)
export fn gfx_sprite_get_rot(inst: f64) callconv(.c) f64 {
    if (sprites().getInstance(toU16(inst))) |s| {
        return @as(f64, s.rotation) * 180.0 / std.math.pi;
    }
    return 0;
}

/// SPRITEVISIBLE(instance) → INTEGER
export fn gfx_sprite_visible(inst: f64) callconv(.c) f64 {
    if (sprites().getInstance(toU16(inst))) |s| {
        return if (s.visible) 1.0 else 0.0;
    }
    return 0;
}

/// SPRITEFRAME(instance) → INTEGER
export fn gfx_sprite_get_frame(inst: f64) callconv(.c) f64 {
    if (sprites().getInstance(toU16(inst))) |s| {
        return @as(f64, @floatFromInt(s.frame));
    }
    return 0;
}

/// SPRITEHIT(a, b) → INTEGER
/// Returns 1 if bounding boxes of instances a and b overlap.
export fn gfx_sprite_hit(a: f64, b: f64) callconv(.c) f64 {
    return if (sprites().testCollision(toU16(a), toU16(b))) 1.0 else 0.0;
}

/// SPRITECOUNT → INTEGER
/// Returns the number of active sprite instances.
export fn gfx_sprite_count() callconv(.c) f64 {
    return @floatFromInt(sprites().activeInstanceCount());
}

// ─── Sprite Collision Commands ──────────────────────────────────────────────

/// SPRITECOLLIDE instance, group
/// Assign a collision group (0 = no group).
export fn gfx_sprite_collide(inst: f64, group: f64) callconv(.c) void {
    if (sprites().getInstance(toU16(inst))) |s| {
        s.collision_group = toU8(group);
    }
}

/// SPRITEOVERLAP(groupA, groupB) → INTEGER
/// Returns 1 if any instance in groupA overlaps any in groupB.
export fn gfx_sprite_overlap(grp_a: f64, grp_b: f64) callconv(.c) f64 {
    return if (sprites().testGroupCollision(toU8(grp_a), toU8(grp_b))) 1.0 else 0.0;
}

// ─── Screen Save ────────────────────────────────────────────────────────────

/// Platform hook: does GPU readback + PNG write on the main thread.
extern fn gfx_screensave_png(path: [*:0]const u8) callconv(.c) void;

/// SCREENSAVE path$
/// Snapshots the rendered GPU output texture to a PNG file.
export fn gfx_screensave(path_desc: ?*const anyopaque) callconv(.c) void {
    const d = path_desc orelse return;
    const path_cstr = string_to_utf8(d);
    gfx_screensave_png(path_cstr);
}

// ─── Window System ──────────────────────────────────────────────────────────

/// WINDOW DEFINE id, "Title", x, y, w, h
export fn gfx_window_define(id: f64, title: ?*const anyopaque, x: f64, y: f64, w: f64, h: f64) callconv(.c) void {
    // WINDOW-only programs may never call SCREEN/APPNAME first.
    // Ensure AppKit is initialized before creating NSWindow objects.
    aot_appkit_init_if_needed();
    const title_slice = if (title) |d| std.mem.span(string_to_utf8(d)) else "";
    gfx_window_define_bridge(toU16(id), title_slice.ptr, @intCast(title_slice.len), toU16(x), toU16(y), toU16(w), toU16(h));
}

/// WINDOW BUTTON/TEXTFIELD/LABEL win_id, kind, ctl_id, "Text", x, y, w, h
export fn gfx_window_control(win_id: f64, kind: f64, ctl_id: f64, text: ?*const anyopaque, x: f64, y: f64, w: f64, h: f64) callconv(.c) void {
    const text_slice = if (text) |d| std.mem.span(string_to_utf8(d)) else "";
    gfx_window_control_bridge(toU16(win_id), toU8(kind), toU16(ctl_id), text_slice.ptr, @intCast(text_slice.len), toU16(x), toU16(y), toU16(w), toU16(h));
}

/// WINDOW SHOW id
export fn gfx_window_show(id: f64) callconv(.c) void {
    gfx_window_show_bridge(toU16(id));
}

/// WINDOW HIDE id
export fn gfx_window_hide(id: f64) callconv(.c) void {
    gfx_window_hide_bridge(toU16(id));
}

/// WINDOW CLOSE id
export fn gfx_window_close(id: f64) callconv(.c) void {
    gfx_window_close_bridge(toU16(id));
}

/// WINDOW SHUTDOWN
export fn gfx_window_shutdown() callconv(.c) void {
    gfx_window_shutdown_bridge();
}

// ─── Image Manager ─────────────────────────────────────────────────────────

/// IMAGE DEFINE id, width, height [, format]
/// format currently supports: 1 = RGBA8
export fn gfx_image_define(id: f64, width: f64, height: f64, format: f64) callconv(.c) f64 {
    const format_u8 = toU8(format);
    const img_format: image_mgr.ImageFormat = switch (format_u8) {
        1 => .rgba8,
        else => return 0.0,
    };
    const ok = image_mgr.define(toU16(id), toU32(width), toU32(height), img_format);
    return if (ok) 1.0 else 0.0;
}

/// IMAGE DESTROY id
export fn gfx_image_destroy(id: f64) callconv(.c) void {
    image_mgr.destroy(toU16(id));
}

/// IMAGE CLEAR
export fn gfx_image_clear() callconv(.c) void {
    image_mgr.clear();
}

/// IMAGE EXISTS(id) -> 0 or 1
export fn gfx_image_exists(id: f64) callconv(.c) f64 {
    return if (image_mgr.exists(toU16(id))) 1.0 else 0.0;
}

/// IMAGE WIDTH(id) -> width, 0 if missing
export fn gfx_image_width(id: f64) callconv(.c) f64 {
    const info = image_mgr.getInfo(toU16(id)) orelse return 0.0;
    return @floatFromInt(info.width);
}

/// IMAGE HEIGHT(id) -> height, 0 if missing
export fn gfx_image_height(id: f64) callconv(.c) f64 {
    const info = image_mgr.getInfo(toU16(id)) orelse return 0.0;
    return @floatFromInt(info.height);
}

/// IMAGE SETRGBA id, ptr, len [, stride]
/// ptr points to packed RGBA8 bytes in row-major order.
export fn gfx_image_set_rgba(id: f64, data_ptr: f64, data_len: f64, stride: f64) callconv(.c) f64 {
    const ptr_usize: usize = @intFromFloat(data_ptr);
    if (ptr_usize == 0) return 0.0;
    const src: [*]const u8 = @ptrFromInt(ptr_usize);
    const ok = image_mgr.setPixelsRgba8(toU16(id), src, toU32(data_len), toU32(stride));
    return if (ok) 1.0 else 0.0;
}

/// IMAGE LOAD id, filename$
/// Loads a PNG from disk, auto-creates/resizes the image buffer, and fills it.
export fn gfx_image_load(id: f64, path_desc: ?*const anyopaque) callconv(.c) f64 {
    const slice = if (path_desc) |d| std.mem.span(string_to_utf8(d)) else "";
    if (slice.len == 0) return 0.0;
    var w: u32 = 0;
    var h: u32 = 0;
    const pixels_maybe = gfx_image_read_png_bridge(slice.ptr, @intCast(slice.len), &w, &h);
    const pixels = pixels_maybe orelse return 0.0;
    defer std.c.free(pixels);
    if (w == 0 or h == 0) return 0.0;
    _ = image_mgr.define(toU16(id), w, h, .rgba8);
    const byte_count: usize = @as(usize, w) * @as(usize, h) * 4;
    const ok = image_mgr.setPixelsRgba8(toU16(id), pixels, byte_count, w * 4);
    return if (ok) 1.0 else 0.0;
}

/// IMAGE SAVE id, filename$
export fn gfx_image_save(id: f64, path_desc: ?*const anyopaque) callconv(.c) f64 {
    const slice = if (path_desc) |d| std.mem.span(string_to_utf8(d)) else "";
    if (slice.len == 0) return 0.0;
    const ok = image_mgr.savePng(toU16(id), slice.ptr, slice.len, gfx_image_write_png_bridge);
    return if (ok) 1.0 else 0.0;
}

/// IMAGE EFFECT id, effect_name$, p1, p2, p3, p4
export fn gfx_image_effect(id: f64, effect_desc: ?*const anyopaque, p1: f64, p2: f64, p3: f64, p4: f64) callconv(.c) f64 {
    const slice = if (effect_desc) |d| std.mem.span(string_to_utf8(d)) else "";
    if (slice.len == 0) return 0.0;
    const ok = image_mgr.applyEffectByName(toU16(id), slice.ptr, slice.len, p1, p2, p3, p4);
    return if (ok) 1.0 else 0.0;
}

/// Apply a packed canvas command buffer directly onto IMAGE id.
export fn gfx_image_apply_batch_raw(id: f64, data: ?*const anyopaque, len: f64) callconv(.c) f64 {
    const ptr = if (data) |p| @as([*]const u8, @ptrCast(p)) else return 0.0;
    if (len <= 0.0) return 0.0;
    const ok = image_mgr.applyBatch(toU16(id), ptr, toU32(len));
    return if (ok) 1.0 else 0.0;
}

/// IMAGE RGBA pointer (read-only), 0 if missing.
export fn gfx_image_get_rgba_ptr(id: f64) callconv(.c) f64 {
    const view = image_mgr.getRgbaView(toU16(id)) orelse return 0.0;
    const addr: usize = @intFromPtr(view.ptr);
    return @floatFromInt(addr);
}

/// IMAGE RGBA stride in bytes, 0 if missing.
export fn gfx_image_get_stride(id: f64) callconv(.c) f64 {
    const view = image_mgr.getRgbaView(toU16(id)) orelse return 0.0;
    return @floatFromInt(view.stride);
}

/// WINDOW EVENT(win_out, ctl_out) -> event_code
///
/// Note: BASIC JIT runs on a worker thread; the bridge writes on the main
/// thread. We pass aligned temporaries to ObjC and then memcpy back to the
/// user pointers to avoid misaligned stores (UBSan was firing on JIT).
export fn gfx_window_poll(win_out: ?*f64, ctl_out: ?*f64) callconv(.c) f64 {
    if (win_out == null or ctl_out == null) return 0.0;

    // Aligned temporaries on this stack frame; ObjC writes here as u16.
    var w: u16 = 0;
    var c: u16 = 0;
    const res_u8 = gfx_window_poll_bridge(&w, &c);

    const w_f64: f64 = @floatFromInt(w);
    const c_f64: f64 = @floatFromInt(c);

    // Copy back to caller buffers with memcpy to tolerate unaligned pointers
    // the JIT may hand us.
    const win_dest: *[8]u8 = @ptrCast(win_out.?);
    const ctl_dest: *[8]u8 = @ptrCast(ctl_out.?);
    @memcpy(win_dest, std.mem.asBytes(&w_f64));
    @memcpy(ctl_dest, std.mem.asBytes(&c_f64));

    return @floatFromInt(res_u8);
}

/// WINDOW TEXT$(win_id, ctl_id) -> string
export fn gfx_window_get_text(win_id: f64, ctl_id: f64) callconv(.c) ?*anyopaque {
    const cstr = gfx_window_get_text_bridge(toU16(win_id), toU16(ctl_id));
    return string_new_utf8(cstr);
}

/// WINDOW SET TEXT win_id, ctl_id, text$
export fn gfx_window_set_text(win_id: f64, ctl_id: f64, text: ?*const anyopaque) callconv(.c) void {
    const text_slice = if (text) |d| std.mem.span(string_to_utf8(d)) else "";
    gfx_window_set_text_bridge(toU16(win_id), toU16(ctl_id), text_slice.ptr, @intCast(text_slice.len));
}

/// WINDOW SET ENABLED win_id, ctl_id, flag
export fn gfx_window_set_enabled(win_id: f64, ctl_id: f64, enabled: f64) callconv(.c) void {
    gfx_window_set_enabled_bridge(toU16(win_id), toU16(ctl_id), if (enabled != 0.0) @as(u8, 1) else @as(u8, 0));
}

/// WINDOW SET TITLE win_id, title$
export fn gfx_window_set_title(win_id: f64, title: ?*const anyopaque) callconv(.c) void {
    const title_slice = if (title) |d| std.mem.span(string_to_utf8(d)) else "";
    gfx_window_set_title_bridge(toU16(win_id), title_slice.ptr, @intCast(title_slice.len));
}

/// WINDOW CHECKED(win_id, ctl_id) -> 0 or 1
export fn gfx_window_get_checked(win_id: f64, ctl_id: f64) callconv(.c) f64 {
    const result = gfx_window_get_checked_bridge(toU16(win_id), toU16(ctl_id));
    return @floatFromInt(result);
}

/// WINDOW SLIDER/PROGRESS win_id, kind, ctl_id, min, max, x, y, w, h
export fn gfx_window_ranged_control(win_id: f64, kind: f64, ctl_id: f64, min: f64, max: f64, x: f64, y: f64, w: f64, h: f64) callconv(.c) void {
    gfx_window_ranged_control_bridge(toU16(win_id), toU8(kind), toU16(ctl_id), min, max, toU16(x), toU16(y), toU16(w), toU16(h));
}

/// WINDOW MATRIX win_id, ctl_id, rows, cols, data_ptr, x, y, w, h
/// Passes the live 2D double array pointer so the NSTableView can read and write back to it.
export fn gfx_window_matrix_control(win_id: f64, ctl_id: f64, rows: f64, cols: f64, data: ?*anyopaque, x: f64, y: f64, w: f64, h: f64) callconv(.c) void {
    const data_f64: ?[*]f64 = if (data) |d| @ptrCast(@alignCast(d)) else null;
    gfx_window_matrix_control_bridge(toU16(win_id), toU16(ctl_id), @intFromFloat(rows), @intFromFloat(cols), data_f64, toU16(x), toU16(y), toU16(w), toU16(h));
}

/// WINDOW MATRIX ROW — row (1-based) of the last matrix cell-edit event
export fn gfx_window_matrix_last_row() callconv(.c) f64 {
    return gfx_window_matrix_last_row_bridge();
}

/// WINDOW MATRIX COL — column (1-based) of the last matrix cell-edit event
export fn gfx_window_matrix_last_col() callconv(.c) f64 {
    return gfx_window_matrix_last_col_bridge();
}

/// WINDOW MATRIX VAL — new value entered in the last matrix cell-edit event
export fn gfx_window_matrix_last_val() callconv(.c) f64 {
    return gfx_window_matrix_last_val_bridge();
}

/// WINDOW VALUE(win_id, ctl_id) -> numeric value (slider pos, popup index, etc.)
export fn gfx_window_get_value(win_id: f64, ctl_id: f64) callconv(.c) f64 {
    return gfx_window_get_value_bridge(toU16(win_id), toU16(ctl_id));
}

/// WINDOW SET VALUE win_id, ctl_id, value
export fn gfx_window_set_value(win_id: f64, ctl_id: f64, value: f64) callconv(.c) void {
    gfx_window_set_value_bridge(toU16(win_id), toU16(ctl_id), value);
}

/// Pack four 0-255 colour components into a single f64 used by the canvas
/// wire format.  A defaults to 255 when not supplied; the compiler fills it in.
export fn gfx_canvas_pack_color(r: f64, g: f64, b: f64, a: f64) callconv(.c) f64 {
    const clamp = struct {
        inline fn do(v: f64) u32 {
            if (v <= 0.0) return 0;
            if (v >= 255.0) return 255;
            return @intFromFloat(v);
        }
    };
    const argb: u32 = (clamp.do(a) << 24) | (clamp.do(r) << 16) | (clamp.do(g) << 8) | clamp.do(b);
    return @floatFromInt(argb);
}

// ─── Canvas batch buffer ─────────────────────────────────────────────────────
//
// Thread-local staging area used by WINDOW CANVAS BEGIN … END.  Every canvas
// statement serialises into this buffer; zero Objective-C bridge calls are made
// per-op.  WINDOW CANVAS END dispatches the completed buffer in one bridge call.
//
// Wire format (per record, same as the canvasDispatch ObjC parser expects):
//   [0]    op        : u8
//   [1]    count     : u8   (number of f64 args that follow)
//   [2..3] text_len  : u16le (UTF-8 byte count; 0 for non-text ops)
//   [4..]  args      : count × 8 bytes (f64, little-endian)
//   [...]  text      : text_len bytes (UTF-8, no NUL terminator)

const CANVAS_BUF_CAP: usize = 131072; // 128 KiB

threadlocal var canvas_buf_storage: [CANVAS_BUF_CAP]u8 = undefined;
threadlocal var canvas_buf_len: usize = 0;

/// When true, each canvas flush prints a human-readable decode to stderr.
/// Set by gfx_canvas_dump_enable(), called when --dump-canvas is active.
var canvas_dump_enabled: bool = false;

export fn gfx_canvas_dump_enable() callconv(.c) void {
    canvas_dump_enabled = true;
}

/// Number of f64 arguments stored per non-poly op code.
inline fn canvasOpArgCount(op: u8) u8 {
    return switch (op) {
        0 => 0, // clear
        1 => 1, // color
        2 => 1, // linewidth
        3 => 2, // text: x, y
        4 => 7, // image: id, x, y, w, h, alpha, blend
        5 => 4, // line
        6 => 5, // rect
        7 => 4, // circle
        8 => 5, // ellipse
        9 => 7, // triangle
        12 => 1, // paper
        13 => 1, // fill
        14 => 0, // nofill
        15 => 6, // arc
        16 => 4, // image_set_dest: x, y, w, h
        17 => 4, // image_set_src: sx, sy, sw, sh
        18 => 2, // image_set_blend: alpha, mode
        19 => 1, // image_place: id
        20 => 2, // path_move
        21 => 2, // path_line
        22 => 4, // path_curve
        23 => 6, // path_bezier
        24 => 5, // path_arc
        25 => 0, // path_close
        26 => 0, // path_fill
        27 => 0, // path_stroke
        else => 0,
    };
}

/// Reset the thread-local staging buffer.  Emitted at WINDOW CANVAS BEGIN.
export fn gfx_canvas_buf_reset() callconv(.c) void {
    if (canvas_dump_enabled)
        std.debug.print("─── CANVAS BEGIN (reset) ───\n", .{});
    canvas_buf_len = 0;
}

/// Append a single non-poly canvas op to the staging buffer.
/// Signature mirrors gfx_window_canvas_op (minus win_id / ctl_id) so the
/// codegen substitution is a straight swap.
export fn gfx_canvas_buf_append(
    op: f64,
    a0: f64,
    a1: f64,
    a2: f64,
    a3: f64,
    a4: f64,
    a5: f64,
    a6: f64,
) callconv(.c) void {
    const op_id: u8 = @intFromFloat(op);
    const arg_arr = [7]f64{ a0, a1, a2, a3, a4, a5, a6 };
    const count: u8 = canvasOpArgCount(op_id);

    // For TEXT (op 3), a2 carries a StringDescriptor* bit-cast to f64.
    var text_slice: []const u8 = &.{};
    if (op_id == 3) {
        const raw: usize = @intFromFloat(a2);
        if (raw != 0) {
            text_slice = getStringSlice(@ptrFromInt(raw));
        }
    }
    const text_len: u16 = @intCast(@min(text_slice.len, 0xFFFF));

    const needed: usize = 4 + @as(usize, count) * 8 + text_len;
    if (canvas_buf_len + needed > CANVAS_BUF_CAP) return; // silently drop if full

    const base = canvas_buf_len;
    canvas_buf_storage[base + 0] = op_id;
    canvas_buf_storage[base + 1] = count;
    canvas_buf_storage[base + 2] = @intCast(text_len & 0xFF);
    canvas_buf_storage[base + 3] = @intCast(text_len >> 8);
    var off: usize = base + 4;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const bits: u64 = @bitCast(arg_arr[i]);
        std.mem.writeInt(u64, canvas_buf_storage[off..][0..8], bits, .little);
        off += 8;
    }
    if (text_len > 0) {
        @memcpy(canvas_buf_storage[off..][0..text_len], text_slice[0..text_len]);
    }
    canvas_buf_len = base + needed;
}

/// Append a POLYLINE (op 10) or POLYGON (op 11) by reading coordinates
/// directly from the BASIC array at call time.  All x/y pairs are inlined
/// into the buffer so the dispatch buffer is self-contained.
/// `pts_bits`  — array base pointer encoded as f64 (sitofp of the usize).
/// `num_pts`   — number of POINT elements (each element is two f64: x, y).
export fn gfx_canvas_buf_append_poly(op: f64, pts_bits: f64, num_pts: f64) callconv(.c) void {
    const op_id: u8 = @intFromFloat(op);
    const ptr_usize: usize = @intFromFloat(pts_bits);
    const num_points: u32 = @intFromFloat(num_pts);
    if (ptr_usize == 0 or num_points == 0) return;

    const coords: [*]const f64 = @ptrFromInt(ptr_usize);

    // Serialise in chunks of ≤127 points (254 doubles) to keep count within u8.
    const CHUNK: u32 = 127;
    var emitted: u32 = 0;
    while (emitted < num_points) {
        const chunk: u32 = @min(num_points - emitted, CHUNK);
        const count: u8 = @intCast(chunk * 2);
        const needed: usize = 4 + @as(usize, count) * 8;
        if (canvas_buf_len + needed > CANVAS_BUF_CAP) break;

        const base = canvas_buf_len;
        canvas_buf_storage[base + 0] = op_id;
        canvas_buf_storage[base + 1] = count;
        canvas_buf_storage[base + 2] = 0;
        canvas_buf_storage[base + 3] = 0; // text_len = 0
        var off: usize = base + 4;
        var i: u32 = 0;
        while (i < chunk * 2) : (i += 1) {
            const v = coords[emitted * 2 + i];
            const bits: u64 = @bitCast(v);
            std.mem.writeInt(u64, canvas_buf_storage[off..][0..8], bits, .little);
            off += 8;
        }
        canvas_buf_len = base + needed;
        emitted += chunk;
    }
}

/// Decode and pretty-print the current staging buffer to stderr.
fn dumpCanvasBuf(win: u16, ctl: u16) void {
    const data = canvas_buf_storage[0..canvas_buf_len];
    std.debug.print("\n─── CANVAS FLUSH  win={d} ctl={d}  bytes={d} ───\n", .{ win, ctl, data.len });

    const OpName = struct {
        fn get(op: u8) []const u8 {
            return switch (op) {
                0 => "CLEAR",
                1 => "COLOR",
                2 => "LINEWIDTH",
                3 => "TEXT",
                4 => "IMAGE",
                5 => "LINE",
                6 => "RECT",
                7 => "CIRCLE",
                8 => "ELLIPSE",
                9 => "TRIANGLE",
                10 => "POLYLINE",
                11 => "POLYGON",
                12 => "PAPER",
                13 => "FILL",
                14 => "NOFILL",
                15 => "ARC",
                20 => "PATH_MOVE",
                21 => "PATH_LINE",
                22 => "PATH_CURVE",
                23 => "PATH_BEZIER",
                24 => "PATH_ARC",
                25 => "PATH_CLOSE",
                26 => "PATH_FILL",
                27 => "PATH_STROKE",
                else => "???",
            };
        }
    };

    const ArgLabels = struct {
        fn get(op: u8, idx: u8) []const u8 {
            return switch (op) {
                1, 12, 13 => switch (idx) {
                    0 => "color",
                    else => "?",
                },
                2 => switch (idx) {
                    0 => "w",
                    else => "?",
                },
                3 => switch (idx) {
                    0 => "x",
                    1 => "y",
                    else => "?",
                },
                4 => switch (idx) {
                    0 => "id",
                    1 => "x",
                    2 => "y",
                    3 => "w",
                    4 => "h",
                    5 => "alpha",
                    6 => "blend",
                    7 => "sx",
                    8 => "sy",
                    9 => "sw",
                    10 => "sh",
                    else => "?",
                },
                5 => switch (idx) {
                    0 => "x1",
                    1 => "y1",
                    2 => "x2",
                    3 => "y2",
                    else => "?",
                },
                6 => switch (idx) {
                    0 => "x",
                    1 => "y",
                    2 => "w",
                    3 => "h",
                    4 => "fill",
                    else => "?",
                },
                7 => switch (idx) {
                    0 => "cx",
                    1 => "cy",
                    2 => "r",
                    3 => "fill",
                    else => "?",
                },
                8 => switch (idx) {
                    0 => "cx",
                    1 => "cy",
                    2 => "rx",
                    3 => "ry",
                    4 => "fill",
                    else => "?",
                },
                9 => switch (idx) {
                    0 => "x1",
                    1 => "y1",
                    2 => "x2",
                    3 => "y2",
                    4 => "x3",
                    5 => "y3",
                    6 => "fill",
                    else => "?",
                },
                15 => switch (idx) {
                    0 => "cx",
                    1 => "cy",
                    2 => "r",
                    3 => "start",
                    4 => "end",
                    5 => "fill",
                    else => "?",
                },
                20, 21 => switch (idx) {
                    0 => "x",
                    1 => "y",
                    else => "?",
                },
                22 => switch (idx) {
                    0 => "cx",
                    1 => "cy",
                    2 => "x2",
                    3 => "y2",
                    else => "?",
                },
                23 => switch (idx) {
                    0 => "cx1",
                    1 => "cy1",
                    2 => "cx2",
                    3 => "cy2",
                    4 => "x2",
                    5 => "y2",
                    else => "?",
                },
                24 => switch (idx) {
                    0 => "cx",
                    1 => "cy",
                    2 => "r",
                    3 => "start",
                    4 => "end",
                    else => "?",
                },
                else => "a",
            };
        }
    };

    var pos: usize = 0;
    var rec: usize = 0;
    while (pos + 4 <= data.len) : (rec += 1) {
        const op = data[pos];
        const count = data[pos + 1];
        const tlen: u16 = @as(u16, data[pos + 2]) | (@as(u16, data[pos + 3]) << 8);
        pos += 4;

        std.debug.print("  [{d:0>2}] {s:-<12}", .{ rec, OpName.get(op) });

        var i: u8 = 0;
        while (i < count and pos + 8 <= data.len) : (i += 1) {
            const bits = std.mem.readInt(u64, data[pos..][0..8], .little);
            const v: f64 = @bitCast(bits);
            pos += 8;

            const lbl = ArgLabels.get(op, i);

            // Color args: decode ARGB u32 → hex + components
            const is_color_op = (op == 1 or op == 12 or op == 13);
            const is_fill_flag = switch (op) {
                6 => i == 4,
                7 => i == 3,
                8 => i == 4,
                9 => i == 6,
                15 => i == 5,
                else => false,
            };

            if (is_color_op) {
                const argb: u32 = @intFromFloat(v);
                const a = (argb >> 24) & 0xFF;
                const r = (argb >> 16) & 0xFF;
                const g = (argb >> 8) & 0xFF;
                const b = argb & 0xFF;
                std.debug.print("  {s}=#FF{X:0>2}{X:0>2}{X:0>2}  (a={d} r={d} g={d} b={d})", .{ lbl, r, g, b, a, r, g, b });
            } else if (is_fill_flag) {
                std.debug.print("  {s}={s}", .{ lbl, if (v != 0.0) "yes" else "no" });
            } else {
                std.debug.print("  {s}={d:.1}", .{ lbl, v });
            }
        }

        if (tlen > 0 and pos + tlen <= data.len) {
            std.debug.print("  \"{s}\"", .{data[pos..][0..tlen]});
            pos += tlen;
        }

        std.debug.print("\n", .{});
    }
    std.debug.print("─────────────────────────────────────────\n", .{});
}

/// Dispatch the completed staging buffer to the canvas view and reset.
/// Emitted at WINDOW CANVAS END.
export fn gfx_canvas_buf_flush(win_id: f64, ctl_id: f64) callconv(.c) void {
    if (canvas_buf_len == 0) return;
    if (canvas_dump_enabled) dumpCanvasBuf(toU16(win_id), toU16(ctl_id));
    gfx_window_canvas_dispatch_bridge(
        toU16(win_id),
        toU16(ctl_id),
        &canvas_buf_storage,
        @intCast(canvas_buf_len),
    );
    canvas_buf_len = 0;
}

/// Apply the currently packed canvas-format staging buffer to an IMAGE id.
/// Used by WINDOW IMAGE BEGIN … END so image drawing reuses the same encoder.
export fn gfx_image_buf_flush(image_id: f64) callconv(.c) void {
    if (canvas_buf_len == 0) return;
    _ = image_mgr.applyBatch(toU16(image_id), &canvas_buf_storage, canvas_buf_len);
    canvas_buf_len = 0;
}

// ─── Canvas bridge wrappers ───────────────────────────────────────────────

/// Submit a serialized canvas command buffer to the native view.
/// `data` points to a packed byte buffer; `len` is the byte length.
export fn gfx_window_canvas_dispatch(win_id: f64, ctl_id: f64, data: ?*const anyopaque, len: f64) callconv(.c) void {
    const ptr = if (data) |p| @as([*]const u8, @ptrCast(p)) else null;
    gfx_window_canvas_dispatch_bridge(toU16(win_id), toU16(ctl_id), ptr, toU32(len));
}

/// Set the scrollable virtual document size for a canvas control.
export fn gfx_window_canvas_set_virtualsize(win_id: f64, ctl_id: f64, virtual_w: f64, virtual_h: f64) callconv(.c) void {
    gfx_window_canvas_set_virtualsize_bridge(toU16(win_id), toU16(ctl_id), virtual_w, virtual_h);
}

/// Pan the visible viewport of a canvas control.
export fn gfx_window_canvas_set_viewport(win_id: f64, ctl_id: f64, x: f64, y: f64) callconv(.c) void {
    gfx_window_canvas_set_viewport_bridge(toU16(win_id), toU16(ctl_id), x, y);
}

/// Define the logical resolution (coordinate scaling) for a canvas control.
export fn gfx_window_canvas_set_resolution(win_id: f64, ctl_id: f64, logical_w: f64, logical_h: f64) callconv(.c) void {
    gfx_window_canvas_set_resolution_bridge(toU16(win_id), toU16(ctl_id), logical_w, logical_h);
}

/// Dispatch a single canvas operation immediately. Arguments beyond the expected
/// count for the opcode are ignored; missing args default to 0.
export fn gfx_window_canvas_op(
    win_id: f64,
    ctl_id: f64,
    op: f64,
    a0: f64,
    a1: f64,
    a2: f64,
    a3: f64,
    a4: f64,
    a5: f64,
    a6: f64,
) callconv(.c) void {
    var args = [_]f64{ a0, a1, a2, a3, a4, a5, a6 };
    const op_id: u8 = @as(u8, @intFromFloat(op));

    // TEXT uses the third argument as a StringDescriptor*; convert to UTF-8
    // so the bridge can render it.
    var text_ptr: ?[*]const u8 = null;
    var text_len: u32 = 0;
    if (op_id == 3) { // text
        const raw_ptr = @as(usize, @intFromFloat(a2));
        if (raw_ptr != 0) {
            const desc_ptr = @as(?*const anyopaque, @ptrFromInt(raw_ptr));
            const slice = getStringSlice(desc_ptr);
            text_ptr = slice.ptr;
            text_len = @intCast(slice.len);
        }
    }

    gfx_window_canvas_op_bridge(
        toU16(win_id),
        toU16(ctl_id),
        op_id,
        &args,
        7,
        text_ptr,
        text_len,
    );
}
