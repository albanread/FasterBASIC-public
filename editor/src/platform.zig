//! Ed Platform Interface — C ABI types shared between Zig and the ObjC Metal bridge
//!
//! This module defines the data structures and function signatures that cross
//! the Zig ↔ Objective-C boundary. The ObjC bridge (ed_metal_bridge.m) implements
//! the platform side; the Zig core (ed_main.zig) implements the callback side.
//!
//! All structs use `extern` layout for C ABI compatibility.
//! All function pointers use `callconv(.c)` for safe interop.

const std = @import("std");
const theme = @import("ed_theme.zig");
const Colour = theme.Colour;

// ─── Shared Render Types ────────────────────────────────────────────────────

/// A single glyph instance for instanced rendering. One per visible character.
/// Packed tightly for GPU upload (28 bytes per instance).
pub const GlyphInstance = extern struct {
    /// Screen position in pixels (top-left of cell).
    pos_x: f32,
    pos_y: f32,
    /// Glyph atlas UV coordinate in pixels (top-left of glyph in atlas).
    uv_x: f32,
    uv_y: f32,
    /// Foreground colour (RGBA).
    fg: [4]u8,
    /// Background colour (RGBA).
    bg: [4]u8,
    /// Flags: bit 0 = underline, bit 1 = bold, bit 2 = cursor, bit 3 = strikethrough,
    /// bit 4 = wavy underline (error), bit 5 = selection, bit 6 = inverse.
    flags: u32,

    pub const FLAG_UNDERLINE: u32 = 1 << 0;
    pub const FLAG_BOLD: u32 = 1 << 1;
    pub const FLAG_CURSOR: u32 = 1 << 2;
    pub const FLAG_STRIKETHROUGH: u32 = 1 << 3;
    pub const FLAG_WAVY_UNDERLINE: u32 = 1 << 4;
    pub const FLAG_SELECTION: u32 = 1 << 5;
    pub const FLAG_INVERSE: u32 = 1 << 6;

    /// Create a glyph instance from components.
    pub fn make(
        px: f32,
        py: f32,
        ux: f32,
        uy: f32,
        fg_colour: Colour,
        bg_colour: Colour,
        f: u32,
    ) GlyphInstance {
        return .{
            .pos_x = px,
            .pos_y = py,
            .uv_x = ux,
            .uv_y = uy,
            .fg = fg_colour.toBytes(),
            .bg = bg_colour.toBytes(),
            .flags = f,
        };
    }
};

/// Uniform data passed to the vertex shader each frame.
pub const EdUniforms = extern struct {
    /// Viewport dimensions in pixels.
    viewport_width: f32,
    viewport_height: f32,
    /// Monospaced character cell dimensions in pixels.
    cell_width: f32,
    cell_height: f32,
    /// Glyph atlas texture dimensions in pixels.
    atlas_width: f32,
    atlas_height: f32,
    /// Time in seconds (for cursor blink, animations).
    time: f32,
    /// Effects mode: 0=none, 1=crt, 2=scanlines.
    effects_mode: f32 = 0,
};

/// Frame data passed from Zig to ObjC each render frame.
pub const EdFrameData = extern struct {
    /// Pointer to the glyph instance array.
    instances: ?[*]const GlyphInstance,
    /// Number of glyph instances to render.
    instance_count: u32,
    /// Padding for alignment.
    _pad0: u32 = 0,
    /// Uniform data for the vertex shader.
    uniforms: EdUniforms,
    /// Clear colour for the background (RGBA, 0.0–1.0).
    clear_r: f32,
    clear_g: f32,
    clear_b: f32,
    clear_a: f32,
};

/// Glyph atlas metrics returned from the platform after atlas creation.
pub const GlyphAtlasInfo = extern struct {
    /// Width of the atlas texture in pixels.
    atlas_width: f32,
    atlas_height: f32,
    /// Width/height of a single character cell in pixels.
    cell_width: f32,
    cell_height: f32,
    /// Number of columns in the atlas grid.
    cols: u32,
    /// Number of rows in the atlas grid.
    rows: u32,
    /// The first code point in the atlas (typically 0x20 = space).
    first_codepoint: u32,
    /// Total number of glyphs in the atlas.
    glyph_count: u32,
    /// Font ascent in pixels (distance from baseline to top of cell).
    ascent: f32,
    /// Font descent in pixels (distance from baseline to bottom of cell).
    descent: f32,
    /// Font leading (extra line spacing) in pixels.
    leading: f32,
    /// Padding.
    _pad: f32 = 0,
};

// ─── Key / Mouse Event Types ────────────────────────────────────────────────

/// Keyboard modifier flags (matches macOS NSEventModifierFlags layout).
pub const Modifiers = packed struct(u32) {
    /// Shift key is held.
    shift: bool = false,
    /// Control key is held.
    ctrl: bool = false,
    /// Alt/Option key is held.
    alt: bool = false,
    /// Cmd/Super key is held.
    cmd: bool = false,
    /// Caps Lock is active.
    caps_lock: bool = false,
    /// Function key is held.
    fn_key: bool = false,
    _pad: u26 = 0,

    pub const NONE = Modifiers{};

    pub fn hasShift(self: Modifiers) bool {
        return self.shift;
    }
    pub fn hasCtrl(self: Modifiers) bool {
        return self.ctrl;
    }
    pub fn hasAlt(self: Modifiers) bool {
        return self.alt;
    }
    pub fn hasCmd(self: Modifiers) bool {
        return self.cmd;
    }
    pub fn cmdOnly(self: Modifiers) bool {
        return self.cmd and !self.shift and !self.ctrl and !self.alt;
    }
    pub fn cmdShift(self: Modifiers) bool {
        return self.cmd and self.shift and !self.ctrl and !self.alt;
    }
    pub fn ctrlOnly(self: Modifiers) bool {
        return self.ctrl and !self.cmd and !self.shift and !self.alt;
    }
    pub fn altOnly(self: Modifiers) bool {
        return self.alt and !self.cmd and !self.shift and !self.ctrl;
    }
    pub fn shiftOnly(self: Modifiers) bool {
        return self.shift and !self.cmd and !self.ctrl and !self.alt;
    }
    pub fn none(self: Modifiers) bool {
        return !self.shift and !self.ctrl and !self.alt and !self.cmd;
    }
};

/// Key event passed from ObjC to Zig.
pub const KeyEvent = extern struct {
    /// The Unicode code point of the character typed (0 if non-printable).
    codepoint: u32,
    /// The virtual key code (macOS kVK_* constants).
    keycode: u16,
    /// Modifier flags.
    modifiers: Modifiers,
    /// Non-zero if this is a key-repeat event.
    is_repeat: u8,
    _pad: u8 = 0,
};

/// Mouse button identifiers.
pub const MouseButton = enum(u8) {
    left = 0,
    right = 1,
    middle = 2,
    other = 3,
};

/// Mouse event passed from ObjC to Zig.
pub const MouseEvent = extern struct {
    /// Position in pixels (relative to the view, top-left origin).
    x: f32,
    y: f32,
    /// Scroll deltas (for scroll events).
    scroll_dx: f32,
    scroll_dy: f32,
    /// Which button.
    button: MouseButton,
    /// Click count (1 = single, 2 = double, 3 = triple).
    click_count: u8,
    _pad: [2]u8 = .{ 0, 0 },
};

/// Window event type.
pub const WindowEventType = enum(u32) {
    resized = 0,
    moved = 1,
    focus_gained = 2,
    focus_lost = 3,
    close_requested = 4,
    dpi_changed = 5,
};

/// Window event passed from ObjC to Zig.
pub const WindowEvent = extern struct {
    event_type: WindowEventType,
    /// New width/height in pixels (for resize events).
    width: f32,
    height: f32,
    /// Scale factor (for DPI change events).
    scale: f32,
};

// ─── Virtual Key Codes (macOS kVK_* constants) ──────────────────────────────

pub const VK = struct {
    pub const RETURN: u16 = 0x24;
    pub const TAB: u16 = 0x30;
    pub const SPACE: u16 = 0x31;
    pub const DELETE: u16 = 0x33; // Backspace
    pub const ESCAPE: u16 = 0x35;
    pub const FORWARD_DELETE: u16 = 0x75;
    pub const HOME: u16 = 0x73;
    pub const END: u16 = 0x77;
    pub const PAGE_UP: u16 = 0x74;
    pub const PAGE_DOWN: u16 = 0x79;
    pub const LEFT_ARROW: u16 = 0x7B;
    pub const RIGHT_ARROW: u16 = 0x7C;
    pub const DOWN_ARROW: u16 = 0x7D;
    pub const UP_ARROW: u16 = 0x7E;

    pub const F1: u16 = 0x7A;
    pub const F2: u16 = 0x78;
    pub const F3: u16 = 0x63;
    pub const F4: u16 = 0x76;
    pub const F5: u16 = 0x60;
    pub const F6: u16 = 0x61;
    pub const F7: u16 = 0x62;
    pub const F8: u16 = 0x64;
    pub const F9: u16 = 0x65;
    pub const F10: u16 = 0x6D;
    pub const F11: u16 = 0x67;
    pub const F12: u16 = 0x6F;

    pub const A: u16 = 0x00;
    pub const B: u16 = 0x0B;
    pub const C: u16 = 0x08;
    pub const D: u16 = 0x02;
    pub const E: u16 = 0x0E;
    pub const F: u16 = 0x03;
    pub const G: u16 = 0x05;
    pub const H: u16 = 0x04;
    pub const I: u16 = 0x22;
    pub const J: u16 = 0x26;
    pub const K: u16 = 0x28;
    pub const L: u16 = 0x25;
    pub const M: u16 = 0x2E;
    pub const N: u16 = 0x2D;
    pub const O: u16 = 0x1F;
    pub const P: u16 = 0x23;
    pub const Q: u16 = 0x0C;
    pub const R: u16 = 0x0F;
    pub const S: u16 = 0x01;
    pub const T: u16 = 0x11;
    pub const U: u16 = 0x20;
    pub const V: u16 = 0x09;
    pub const W: u16 = 0x0D;
    pub const X: u16 = 0x07;
    pub const Y: u16 = 0x10;
    pub const Z: u16 = 0x06;

    pub const GRAVE: u16 = 0x32; // backtick `
    pub const MINUS: u16 = 0x1B;
    pub const EQUAL: u16 = 0x18;
    pub const LEFT_BRACKET: u16 = 0x21;
    pub const RIGHT_BRACKET: u16 = 0x1E;
    pub const BACKSLASH: u16 = 0x2A;
    pub const SEMICOLON: u16 = 0x29;
    pub const QUOTE: u16 = 0x27;
    pub const COMMA: u16 = 0x2B;
    pub const PERIOD: u16 = 0x2F;
    pub const SLASH: u16 = 0x2C;
};

// ─── Callback Function Pointer Types (Zig → ObjC calls back into Zig) ──────
//
// These are the C function signatures that the ObjC bridge calls into.
// They are implemented as `export fn` in ed_main.zig.

/// Called each frame to build render data. Returns the frame data to draw.
pub const FrameCallbackFn = *const fn (dt: f64) callconv(.c) EdFrameData;

/// Called when a key is pressed.
pub const KeyCallbackFn = *const fn (*const KeyEvent) callconv(.c) void;

/// Called when a key is released.
pub const KeyUpCallbackFn = *const fn (*const KeyEvent) callconv(.c) void;

/// Called for text input (IME-aware, provides the final composed string).
pub const TextCallbackFn = *const fn (codepoint: u32) callconv(.c) void;

/// Called on mouse button down.
pub const MouseDownCallbackFn = *const fn (*const MouseEvent) callconv(.c) void;

/// Called on mouse button up.
pub const MouseUpCallbackFn = *const fn (*const MouseEvent) callconv(.c) void;

/// Called on mouse movement.
pub const MouseMovedCallbackFn = *const fn (x: f32, y: f32) callconv(.c) void;

/// Called on scroll / trackpad gesture.
pub const ScrollCallbackFn = *const fn (dx: f32, dy: f32) callconv(.c) void;

/// Called on window events (resize, focus, close, etc.).
pub const WindowCallbackFn = *const fn (*const WindowEvent) callconv(.c) void;

/// The full set of callbacks the ObjC bridge needs.
pub const EdCallbacks = extern struct {
    on_frame: ?FrameCallbackFn = null,
    on_key_down: ?KeyCallbackFn = null,
    on_key_up: ?KeyUpCallbackFn = null,
    on_text_input: ?TextCallbackFn = null,
    on_mouse_down: ?MouseDownCallbackFn = null,
    on_mouse_up: ?MouseUpCallbackFn = null,
    on_mouse_moved: ?MouseMovedCallbackFn = null,
    on_scroll: ?ScrollCallbackFn = null,
    on_window_event: ?WindowCallbackFn = null,
};

// ─── Platform Functions (Zig calls into ObjC) ──────────────────────────────
//
// These are implemented in ed_metal_bridge.m and declared as extern here.

pub extern fn ed_platform_init(
    width: c_int,
    height: c_int,
    title: [*:0]const u8,
    font_name: [*:0]const u8,
    font_size: f32,
    callbacks: *const EdCallbacks,
) callconv(.c) c_int;

/// Enter the NSApplication run loop. This never returns.
pub extern fn ed_platform_run() callconv(.c) void;

/// Request the window to redraw (triggers a frame callback).
pub extern fn ed_platform_request_redraw() callconv(.c) void;

/// Set the window title.
pub extern fn ed_platform_set_title(title: [*:0]const u8) callconv(.c) void;

/// Get the glyph atlas info (available after ed_platform_init).
pub extern fn ed_platform_get_atlas_info() callconv(.c) GlyphAtlasInfo;

/// Get the current window width in pixels.
pub extern fn ed_platform_get_width() callconv(.c) f32;

/// Get the current window height in pixels.
pub extern fn ed_platform_get_height() callconv(.c) f32;

/// Get the current display scale factor (retina = 2.0).
pub extern fn ed_platform_get_scale() callconv(.c) f32;

/// Copy text to the system clipboard (UTF-8, null-terminated).
pub extern fn ed_platform_clipboard_set(text: [*:0]const u8) callconv(.c) void;

/// Get text from the system clipboard. Returns null if empty.
/// The caller must free the returned string with ed_platform_clipboard_free.
pub extern fn ed_platform_clipboard_get() callconv(.c) ?[*:0]const u8;

/// Free a clipboard string previously returned by ed_platform_clipboard_get.
pub extern fn ed_platform_clipboard_free(text: [*:0]const u8) callconv(.c) void;

/// Show a native Open File dialog. Returns a path (caller must free with
/// ed_platform_free_path) or null if the user cancelled.
pub extern fn ed_platform_open_file_dialog() callconv(.c) ?[*:0]const u8;

/// Show a native Save File dialog with a suggested filename. Returns the
/// chosen path (caller must free with ed_platform_free_path) or null if
/// the user cancelled.
pub extern fn ed_platform_save_file_dialog(suggested_name: ?[*:0]const u8) callconv(.c) ?[*:0]const u8;

/// Show a native Save Executable dialog with a suggested output path.
/// Returns the chosen path (caller must free with ed_platform_free_path)
/// or null if the user cancelled.
pub extern fn ed_platform_save_build_dialog(suggested_name: ?[*:0]const u8) callconv(.c) ?[*:0]const u8;

/// Free a path string returned by ed_platform_open_file_dialog or
/// ed_platform_save_file_dialog / ed_platform_save_build_dialog.
pub extern fn ed_platform_free_path(path: [*:0]const u8) callconv(.c) void;

/// Show a "Save changes?" confirmation dialog. Returns:
///   1 = Save, 0 = Don't Save, -1 = Cancel.
pub extern fn ed_platform_confirm_save_dialog(filename: ?[*:0]const u8) callconv(.c) c_int;

/// Show a native compiler settings dialog.
/// Returns: 1 = Save, 2 = Use Defaults, 0 = Cancel.
/// Any returned strings must be freed with ed_platform_free_path.
pub extern fn ed_platform_compiler_settings_dialog(
    current_path: ?[*:0]const u8,
    current_options: ?[*:0]const u8,
    out_path: *?[*:0]const u8,
    out_options: *?[*:0]const u8,
) callconv(.c) c_int;

/// Set the mouse cursor style.
///   0 = arrow (default)
///   1 = vertical resize (up/down arrows, for splitter dragging)
pub extern fn ed_platform_set_cursor(style: u8) callconv(.c) void;

/// Cursor style constants.
pub const CURSOR_ARROW: u8 = 0;
pub const CURSOR_RESIZE_VERTICAL: u8 = 1;

// ─── Glyph Atlas Helpers ────────────────────────────────────────────────────

/// Given a code point, return the UV coordinates (in pixels) in the glyph atlas.
/// This assumes a simple grid layout starting at `first_codepoint`.
/// Returns (0, 0) for code points not in the atlas.
pub fn codepointToAtlasUV(cp: u32, info: GlyphAtlasInfo) struct { u: f32, v: f32 } {
    if (cp < info.first_codepoint or cp >= info.first_codepoint + info.glyph_count) {
        // Not in atlas — return the space glyph (first cell) as fallback
        return .{ .u = 0, .v = 0 };
    }
    const idx = cp - info.first_codepoint;
    const col = idx % info.cols;
    const row = idx / info.cols;
    return .{
        .u = @as(f32, @floatFromInt(col)) * info.cell_width,
        .v = @as(f32, @floatFromInt(row)) * info.cell_height,
    };
}

// ─── Tests ──────────────────────────────────────────────────────────────────

test "GlyphInstance is 28 bytes" {
    try std.testing.expectEqual(@as(usize, 28), @sizeOf(GlyphInstance));
}

test "Modifiers packed struct is 4 bytes" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Modifiers));
}

test "Modifiers.none works" {
    const m = Modifiers{};
    try std.testing.expect(m.none());
    try std.testing.expect(!m.hasShift());
    try std.testing.expect(!m.hasCmd());
}

test "Modifiers.cmdOnly works" {
    const m = Modifiers{ .cmd = true };
    try std.testing.expect(m.cmdOnly());
    try std.testing.expect(!m.none());
    try std.testing.expect(!m.cmdShift());
}

test "codepointToAtlasUV basic ASCII" {
    const info = GlyphAtlasInfo{
        .atlas_width = 160,
        .atlas_height = 120,
        .cell_width = 10,
        .cell_height = 20,
        .cols = 16,
        .rows = 6,
        .first_codepoint = 0x20,
        .glyph_count = 95,
        .ascent = 14,
        .descent = 4,
        .leading = 2,
    };

    // Space (0x20) should be at (0, 0)
    const space = codepointToAtlasUV(0x20, info);
    try std.testing.expectApproxEqAbs(@as(f32, 0), space.u, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0), space.v, 0.01);

    // 'A' (0x41) = index 0x21 = 33, col = 33 % 16 = 1, row = 33 / 16 = 2
    const a = codepointToAtlasUV('A', info);
    try std.testing.expectApproxEqAbs(@as(f32, 10), a.u, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 40), a.v, 0.01);
}

test "KeyEvent extern struct layout" {
    // Verify the struct has no unexpected padding that would break C interop
    const ke = KeyEvent{
        .codepoint = 'A',
        .keycode = VK.A,
        .modifiers = Modifiers{ .cmd = true },
        .is_repeat = 0,
    };
    try std.testing.expectEqual(@as(u32, 'A'), ke.codepoint);
    try std.testing.expectEqual(VK.A, ke.keycode);
    try std.testing.expect(ke.modifiers.hasCmd());
}

test "EdFrameData can be zero-initialised" {
    const frame = std.mem.zeroes(EdFrameData);
    try std.testing.expectEqual(@as(u32, 0), frame.instance_count);
    try std.testing.expect(frame.instances == null);
}
