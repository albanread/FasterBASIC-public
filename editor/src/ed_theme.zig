//! Ed Theme Module — Colour Schemes for the FasterBASIC Editor
//!
//! Defines fifteen built-in themes inspired by classic and retro aesthetics:
//!   1. FasterBASIC     — the classic blue IDE (default)
//!   2. Neon            — modern dark with vibrant colours
//!   3. Retro           — monochrome amber-on-black terminal
//!   4. Retro CRT       — green phosphor with CRT effects
//!   5. Retro Amber CRT — warm amber phosphor with CRT effects
//!   6. Paper White     — clean monochrome: ink on paper, shades of grey
//!   7. Commodore 64    — the iconic 8-bit home computer palette
//!   8. Dracula         — beloved dark theme with pastel accents
//!   9. Monokai         — classic warm dark theme from Sublime Text
//!  10. Synthwave '84   — neon-soaked 80s retrowave with scanlines
//!  11. Tokyo Night     — deep midnight navy with cool neon accents
//!  12. Gruvbox Dark    — earthy dark scheme with amber/orange highlights
//!  13. Solarized Dark+ — calm teal/amber on deep cyan-black
//!  14. Nord Midnight   — cool polar night with frost accents
//!  15. One Dark Vibrant— punchy neon accents on charcoal
//!
//! Each theme provides colours for every UI element and syntax token category.
//! Colours are stored as RGBA u8 tuples for direct use in Metal instance data.

const std = @import("std");

// ─── Colour Type ────────────────────────────────────────────────────────────

/// RGBA colour with 8 bits per channel.
pub const Colour = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    /// Create a colour from a hex value (0xRRGGBB).
    pub fn hex(comptime val: u24) Colour {
        return .{
            .r = @intCast((val >> 16) & 0xFF),
            .g = @intCast((val >> 8) & 0xFF),
            .b = @intCast(val & 0xFF),
            .a = 255,
        };
    }

    /// Create a colour from a hex value with alpha (0xRRGGBBAA).
    pub fn hexA(comptime val: u32) Colour {
        return .{
            .r = @intCast((val >> 24) & 0xFF),
            .g = @intCast((val >> 16) & 0xFF),
            .b = @intCast((val >> 8) & 0xFF),
            .a = @intCast(val & 0xFF),
        };
    }

    /// Create from RGB u8 values.
    pub fn rgb(r: u8, g: u8, b: u8) Colour {
        return .{ .r = r, .g = g, .b = b, .a = 255 };
    }

    /// Create from RGBA u8 values.
    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Colour {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    /// Return as a [4]f32 suitable for Metal clear colour (0.0–1.0 range).
    pub fn toFloat4(self: Colour) [4]f32 {
        return .{
            @as(f32, @floatFromInt(self.r)) / 255.0,
            @as(f32, @floatFromInt(self.g)) / 255.0,
            @as(f32, @floatFromInt(self.b)) / 255.0,
            @as(f32, @floatFromInt(self.a)) / 255.0,
        };
    }

    /// Return as a packed [4]u8 for instance buffer.
    pub fn toBytes(self: Colour) [4]u8 {
        return .{ self.r, self.g, self.b, self.a };
    }

    /// Blend two colours (self over other) using self.a as the blend factor.
    pub fn blend(self: Colour, other: Colour) Colour {
        const sa: u16 = self.a;
        const inv_sa: u16 = 255 - sa;
        return .{
            .r = @intCast((@as(u16, self.r) * sa + @as(u16, other.r) * inv_sa) / 255),
            .g = @intCast((@as(u16, self.g) * sa + @as(u16, other.g) * inv_sa) / 255),
            .b = @intCast((@as(u16, self.b) * sa + @as(u16, other.b) * inv_sa) / 255),
            .a = 255,
        };
    }

    /// Lighten a colour by a factor (0.0 = no change, 1.0 = white).
    pub fn lighten(self: Colour, factor: f32) Colour {
        const f = std.math.clamp(factor, 0.0, 1.0);
        return .{
            .r = @intFromFloat(@as(f32, @floatFromInt(self.r)) + (@as(f32, 255.0) - @as(f32, @floatFromInt(self.r))) * f),
            .g = @intFromFloat(@as(f32, @floatFromInt(self.g)) + (@as(f32, 255.0) - @as(f32, @floatFromInt(self.g))) * f),
            .b = @intFromFloat(@as(f32, @floatFromInt(self.b)) + (@as(f32, 255.0) - @as(f32, @floatFromInt(self.b))) * f),
            .a = self.a,
        };
    }

    /// Darken a colour by a factor (0.0 = no change, 1.0 = black).
    pub fn darken(self: Colour, factor: f32) Colour {
        const f = 1.0 - std.math.clamp(factor, 0.0, 1.0);
        return .{
            .r = @intFromFloat(@as(f32, @floatFromInt(self.r)) * f),
            .g = @intFromFloat(@as(f32, @floatFromInt(self.g)) * f),
            .b = @intFromFloat(@as(f32, @floatFromInt(self.b)) * f),
            .a = self.a,
        };
    }

    /// Compare two colours for equality.
    pub fn eql(self: Colour, other: Colour) bool {
        return self.r == other.r and self.g == other.g and self.b == other.b and self.a == other.a;
    }
};

// ─── Syntax Token Categories ────────────────────────────────────────────────

/// Categories for syntax highlighting, mapped to colours in each theme.
pub const SyntaxCategory = enum(u8) {
    /// Default text / identifiers
    default,
    /// Language keywords (PRINT, DIM, LET, etc.)
    keyword,
    /// Control flow (IF, THEN, ELSE, FOR, WHILE, DO, SELECT, etc.)
    control_flow,
    /// Type keywords (INTEGER, DOUBLE, STRING, AS, TYPE, CLASS, etc.)
    type_keyword,
    /// Function/sub definitions (FUNCTION, SUB, END FUNCTION, METHOD, etc.)
    subroutine,
    /// Numeric literals (42, 3.14, &HFF, etc.)
    number,
    /// String literals ("Hello", etc.)
    string,
    /// Comments (REM, ' single-quote comments)
    comment,
    /// Operators (+, -, *, /, =, <>, AND, OR, NOT, etc.)
    operator,
    /// Type suffixes (%, !, #, $, @, &)
    type_suffix,
    /// Delimiters — parentheses, commas, colons, semicolons
    delimiter,
    /// Worker/concurrency keywords (WORKER, SPAWN, AWAIT, SEND, etc.)
    worker,
    /// Error / unknown tokens
    err,

    pub const COUNT = @typeInfo(SyntaxCategory).@"enum".fields.len;
};

// ─── Theme Effects ──────────────────────────────────────────────────────────

/// Visual effects that can be applied to the editor rendering.
pub const ThemeEffects = enum(u8) {
    none, // No effects, standard rendering
    crt, // Full CRT effect: curvature, scanlines, phosphor glow
    scanlines, // Scanlines only (lighter effect)
};

// ─── Theme ──────────────────────────────────────────────────────────────────

/// A complete colour theme for the editor.
pub const Theme = struct {
    name: []const u8,
    effects: ThemeEffects,

    // ── UI Elements ──────────────────────────────────────────────────────
    /// Main editor background
    editor_bg: Colour,
    /// Line number gutter background
    gutter_bg: Colour,
    /// Line number gutter text
    gutter_fg: Colour,
    /// Terminal pane background
    terminal_bg: Colour,
    /// Terminal pane default text
    terminal_fg: Colour,
    /// Status bar background
    status_bg: Colour,
    /// Status bar text
    status_fg: Colour,
    /// Current line highlight background
    current_line_bg: Colour,
    /// Selection background
    selection_bg: Colour,
    /// Selection foreground (text colour in selection)
    selection_fg: Colour,
    /// Cursor colour
    cursor: Colour,
    /// Find/search match highlight background
    match_bg: Colour,
    /// Error underline colour
    error_underline: Colour,
    /// Warning underline colour
    warning_underline: Colour,
    /// Title bar / top bar background
    title_bg: Colour,
    /// Title bar text
    title_fg: Colour,
    /// Divider / border lines
    divider: Colour,
    /// Scrollbar track
    scrollbar_track: Colour,
    /// Scrollbar thumb
    scrollbar_thumb: Colour,
    /// Find bar background
    find_bar_bg: Colour,
    /// Find bar text
    find_bar_fg: Colour,
    /// Inline rename highlight background
    rename_bg: Colour,

    // ── Syntax Colours (indexed by SyntaxCategory) ───────────────────────
    syntax: [SyntaxCategory.COUNT]Colour,

    /// Get the foreground colour for a syntax category.
    pub fn syntaxColour(self: *const Theme, cat: SyntaxCategory) Colour {
        return self.syntax[@intFromEnum(cat)];
    }
};

// ─── Theme ID ───────────────────────────────────────────────────────────────

pub const ThemeId = enum(u8) {
    fasterbasic,
    neon,
    retro,
    retro_crt,
    retro_amber_crt,
    paper_white,
    c64,
    dracula,
    monokai,
    synthwave,
    tokyo_night,
    gruvbox_dark,
    solarized_dark_plus,
    nord_midnight,
    one_dark_vibrant,

    pub fn next(self: ThemeId) ThemeId {
        return switch (self) {
            .fasterbasic => .neon,
            .neon => .retro,
            .retro => .retro_crt,
            .retro_crt => .retro_amber_crt,
            .retro_amber_crt => .paper_white,
            .paper_white => .c64,
            .c64 => .dracula,
            .dracula => .monokai,
            .monokai => .synthwave,
            .synthwave => .tokyo_night,
            .tokyo_night => .gruvbox_dark,
            .gruvbox_dark => .solarized_dark_plus,
            .solarized_dark_plus => .nord_midnight,
            .nord_midnight => .one_dark_vibrant,
            .one_dark_vibrant => .fasterbasic,
        };
    }

    pub fn name(self: ThemeId) []const u8 {
        return switch (self) {
            .fasterbasic => "FasterBASIC",
            .neon => "Neon",
            .retro => "Retro",
            .retro_crt => "Retro CRT",
            .retro_amber_crt => "Retro Amber CRT",
            .paper_white => "Paper White",
            .c64 => "Commodore 64",
            .dracula => "Dracula",
            .monokai => "Monokai",
            .synthwave => "Synthwave '84",
            .tokyo_night => "Tokyo Night",
            .gruvbox_dark => "Gruvbox Dark",
            .solarized_dark_plus => "Solarized Dark+",
            .nord_midnight => "Nord Midnight",
            .one_dark_vibrant => "One Dark Vibrant",
        };
    }
};

// ─── Built-in Themes ────────────────────────────────────────────────────────

/// Theme 1: Classic FasterBASIC — deep blue background, bright colours.
pub const THEME_FASTERBASIC = Theme{
    .name = "FasterBASIC",
    .effects = .none,

    // UI
    .editor_bg = Colour.hex(0x0000AA),
    .gutter_bg = Colour.hex(0x000080),
    .gutter_fg = Colour.hex(0x808080),
    .terminal_bg = Colour.hex(0xF2E7B8),
    .terminal_fg = Colour.hex(0x4F4427),
    .status_bg = Colour.hex(0x000080),
    .status_fg = Colour.hex(0xAAAAAA),
    .current_line_bg = Colour.hex(0x0000CC),
    .selection_bg = Colour.hex(0x555555),
    .selection_fg = Colour.hex(0xFFFFFF),
    .cursor = Colour.hex(0xFFFF55),
    .match_bg = Colour.hex(0xAA8800),
    .error_underline = Colour.hex(0xFF5555),
    .warning_underline = Colour.hex(0xFFFF55),
    .title_bg = Colour.hex(0x000080),
    .title_fg = Colour.hex(0xFFFFFF),
    .divider = Colour.hex(0x4444AA),
    .scrollbar_track = Colour.hex(0x000060),
    .scrollbar_thumb = Colour.hex(0x4444CC),
    .find_bar_bg = Colour.hex(0x000060),
    .find_bar_fg = Colour.hex(0xFFFFFF),
    .rename_bg = Colour.hex(0x004400),

    // Syntax
    .syntax = syntaxArray(.{
        .{ .default, Colour.hex(0xFFFFFF) },
        .{ .keyword, Colour.hex(0xFFFFFF) }, // bright white (bold implied)
        .{ .control_flow, Colour.hex(0xFFFF55) }, // bright yellow
        .{ .type_keyword, Colour.hex(0x55FFFF) }, // bright cyan
        .{ .subroutine, Colour.hex(0x55FF55) }, // bright green
        .{ .number, Colour.hex(0xFF55FF) }, // bright magenta
        .{ .string, Colour.hex(0xAA8800) }, // amber/brown
        .{ .comment, Colour.hex(0xAAAAAA) }, // grey
        .{ .operator, Colour.hex(0xC0C0C0) }, // light grey
        .{ .type_suffix, Colour.hex(0x44AAAA) }, // dark cyan
        .{ .delimiter, Colour.hex(0xC0C0C0) }, // light grey
        .{ .worker, Colour.hex(0x5555FF) }, // bright blue
        .{ .err, Colour.hex(0xFF5555) }, // bright red
    }),
};

/// Theme 2: Neon — deep navy with vibrant modern colours.
pub const THEME_NEON = Theme{
    .name = "Neon",
    .effects = .none,

    // UI
    .editor_bg = Colour.hex(0x1A1A2E),
    .gutter_bg = Colour.hex(0x141425),
    .gutter_fg = Colour.hex(0x4A4A6A),
    .terminal_bg = Colour.hex(0x0D0D1A),
    .terminal_fg = Colour.hex(0xCCCCCC),
    .status_bg = Colour.hex(0x141425),
    .status_fg = Colour.hex(0xE0E0E0),
    .current_line_bg = Colour.hex(0x1E1E38),
    .selection_bg = Colour.hex(0x3A3A5E),
    .selection_fg = Colour.hex(0xE0E0E0),
    .cursor = Colour.hex(0x00D4FF),
    .match_bg = Colour.rgba(0xFF, 0x8C, 0x00, 0x66),
    .error_underline = Colour.hex(0xFF3333),
    .warning_underline = Colour.hex(0xFFD700),
    .title_bg = Colour.hex(0x141425),
    .title_fg = Colour.hex(0xE0E0E0),
    .divider = Colour.hex(0x2A2A4E),
    .scrollbar_track = Colour.hex(0x141425),
    .scrollbar_thumb = Colour.hex(0x3A3A5E),
    .find_bar_bg = Colour.hex(0x1E1E38),
    .find_bar_fg = Colour.hex(0xE0E0E0),
    .rename_bg = Colour.hex(0x1A3A1A),

    // Syntax
    .syntax = syntaxArray(.{
        .{ .default, Colour.hex(0xE0E0E0) },
        .{ .keyword, Colour.hex(0x00D4FF) }, // cyan
        .{ .control_flow, Colour.hex(0xFFD700) }, // gold
        .{ .type_keyword, Colour.hex(0x20B2AA) }, // teal
        .{ .subroutine, Colour.hex(0x00FF88) }, // lime
        .{ .number, Colour.hex(0xFF69B4) }, // pink
        .{ .string, Colour.hex(0xFF8C00) }, // orange
        .{ .comment, Colour.hex(0x555577) }, // muted lavender
        .{ .operator, Colour.hex(0xAAAACC) }, // silver
        .{ .type_suffix, Colour.hex(0x668899) }, // slate
        .{ .delimiter, Colour.hex(0x8888AA) }, // grey
        .{ .worker, Colour.hex(0x4488FF) }, // electric blue
        .{ .err, Colour.hex(0xFF3333) }, // red
    }),
};

/// Theme 3: Retro — monochrome amber on black, like a vintage terminal.
pub const THEME_RETRO = Theme{
    .name = "Retro",
    .effects = .none,

    // UI
    .editor_bg = Colour.hex(0x1A1200),
    .gutter_bg = Colour.hex(0x141000),
    .gutter_fg = Colour.hex(0x5A4A00),
    .terminal_bg = Colour.hex(0x0D0A00),
    .terminal_fg = Colour.hex(0xCC8800),
    .status_bg = Colour.hex(0x141000),
    .status_fg = Colour.hex(0xFFAA00),
    .current_line_bg = Colour.hex(0x221800),
    .selection_bg = Colour.hex(0xFFAA00),
    .selection_fg = Colour.hex(0x1A1200),
    .cursor = Colour.hex(0xFFAA00),
    .match_bg = Colour.rgba(0xFF, 0x88, 0x00, 0x44),
    .error_underline = Colour.hex(0xFF4400),
    .warning_underline = Colour.hex(0xFFCC00),
    .title_bg = Colour.hex(0x141000),
    .title_fg = Colour.hex(0xFFAA00),
    .divider = Colour.hex(0x3A2800),
    .scrollbar_track = Colour.hex(0x141000),
    .scrollbar_thumb = Colour.hex(0x5A4A00),
    .find_bar_bg = Colour.hex(0x221800),
    .find_bar_fg = Colour.hex(0xFFAA00),
    .rename_bg = Colour.hex(0x2A2A00),

    // Syntax
    .syntax = syntaxArray(.{
        .{ .default, Colour.hex(0xFFAA00) }, // amber
        .{ .keyword, Colour.hex(0xFFCC00) }, // bright amber
        .{ .control_flow, Colour.hex(0xFFDD44) }, // light amber
        .{ .type_keyword, Colour.hex(0xCC8800) }, // dark amber
        .{ .subroutine, Colour.hex(0xFFCC00) }, // bright amber
        .{ .number, Colour.hex(0xFF8800) }, // orange-amber
        .{ .string, Colour.hex(0xDDAA44) }, // warm amber
        .{ .comment, Colour.hex(0x665500) }, // dim amber
        .{ .operator, Colour.hex(0xAA8800) }, // medium amber
        .{ .type_suffix, Colour.hex(0x886600) }, // muted amber
        .{ .delimiter, Colour.hex(0xAA8800) }, // medium amber
        .{ .worker, Colour.hex(0xFFBB00) }, // golden amber
        .{ .err, Colour.hex(0xFF4400) }, // red-amber
    }),
};

/// Theme 4: Retro CRT — green phosphor on black with authentic CRT effects.
pub const THEME_RETRO_CRT = Theme{
    .name = "Retro CRT",
    .effects = .crt,

    // UI
    .editor_bg = Colour.hex(0x001100),
    .gutter_bg = Colour.hex(0x000D00),
    .gutter_fg = Colour.hex(0x004400),
    .terminal_bg = Colour.hex(0x000800),
    .terminal_fg = Colour.hex(0x00FF00),
    .status_bg = Colour.hex(0x000D00),
    .status_fg = Colour.hex(0x00FF00),
    .current_line_bg = Colour.hex(0x002200),
    .selection_bg = Colour.hex(0x006600),
    .selection_fg = Colour.hex(0x00FF00),
    .cursor = Colour.hex(0x00FF00),
    .match_bg = Colour.hex(0x004400),
    .error_underline = Colour.hex(0xFF4400),
    .warning_underline = Colour.hex(0xFFAA00),
    .title_bg = Colour.hex(0x000D00),
    .title_fg = Colour.hex(0x00FF00),
    .divider = Colour.hex(0x003300),
    .scrollbar_track = Colour.hex(0x001100),
    .scrollbar_thumb = Colour.hex(0x004400),
    .find_bar_bg = Colour.hex(0x002200),
    .find_bar_fg = Colour.hex(0x00FF00),
    .rename_bg = Colour.hex(0x003300),

    // Syntax - classic green phosphor with subtle variations
    .syntax = syntaxArray(.{
        .{ .default, Colour.hex(0x00FF00) }, // bright green
        .{ .keyword, Colour.hex(0x00FF44) }, // light green
        .{ .control_flow, Colour.hex(0x00FF88) }, // cyan-green
        .{ .type_keyword, Colour.hex(0x00CC00) }, // medium green
        .{ .subroutine, Colour.hex(0x00FF44) }, // light green
        .{ .number, Colour.hex(0x44FF44) }, // lime green
        .{ .string, Colour.hex(0x88FF88) }, // pale green
        .{ .comment, Colour.hex(0x006600) }, // dim green
        .{ .operator, Colour.hex(0x00DD00) }, // bright green
        .{ .type_suffix, Colour.hex(0x00AA00) }, // dark green
        .{ .delimiter, Colour.hex(0x00DD00) }, // bright green
        .{ .worker, Colour.hex(0x00FFAA) }, // cyan-green
        .{ .err, Colour.hex(0xFF4400) }, // orange (error)
    }),
};

/// Theme 5: Retro Amber CRT — warm amber phosphor with authentic CRT effects.
pub const THEME_RETRO_AMBER_CRT = Theme{
    .name = "Retro Amber CRT",
    .effects = .crt,

    // UI
    .editor_bg = Colour.hex(0x1A1200),
    .gutter_bg = Colour.hex(0x141000),
    .gutter_fg = Colour.hex(0x5A4A00),
    .terminal_bg = Colour.hex(0x0D0A00),
    .terminal_fg = Colour.hex(0xFFAA00),
    .status_bg = Colour.hex(0x141000),
    .status_fg = Colour.hex(0xFFAA00),
    .current_line_bg = Colour.hex(0x2A2000),
    .selection_bg = Colour.hex(0x665500),
    .selection_fg = Colour.hex(0xFFDD88),
    .cursor = Colour.hex(0xFFBB00),
    .match_bg = Colour.hex(0x4A3A00),
    .error_underline = Colour.hex(0xFF4400),
    .warning_underline = Colour.hex(0xFFDD44),
    .title_bg = Colour.hex(0x141000),
    .title_fg = Colour.hex(0xFFAA00),
    .divider = Colour.hex(0x3A3000),
    .scrollbar_track = Colour.hex(0x1A1200),
    .scrollbar_thumb = Colour.hex(0x5A4A00),
    .find_bar_bg = Colour.hex(0x2A2000),
    .find_bar_fg = Colour.hex(0xFFAA00),
    .rename_bg = Colour.hex(0x3A3000),

    // Syntax - warm amber phosphor with variations
    .syntax = syntaxArray(.{
        .{ .default, Colour.hex(0xFFAA00) }, // bright amber
        .{ .keyword, Colour.hex(0xFFCC00) }, // golden amber
        .{ .control_flow, Colour.hex(0xFFDD44) }, // light amber
        .{ .type_keyword, Colour.hex(0xCC8800) }, // dark amber
        .{ .subroutine, Colour.hex(0xFFBB00) }, // warm amber
        .{ .number, Colour.hex(0xFF9900) }, // orange-amber
        .{ .string, Colour.hex(0xDDAA44) }, // pale amber
        .{ .comment, Colour.hex(0x665500) }, // dim amber
        .{ .operator, Colour.hex(0xDD9900) }, // medium amber
        .{ .type_suffix, Colour.hex(0xAA7700) }, // muted amber
        .{ .delimiter, Colour.hex(0xDD9900) }, // medium amber
        .{ .worker, Colour.hex(0xFFCC44) }, // bright gold
        .{ .err, Colour.hex(0xFF4400) }, // red-orange (error)
    }),
};

/// Theme 7: Commodore 64 — the iconic 8-bit home computer palette.
pub const THEME_C64 = Theme{
    .name = "Commodore 64",
    .effects = .none,

    // UI — C64 purple-blue background, light blue chrome
    .editor_bg = Colour.hex(0x40318D),
    .gutter_bg = Colour.hex(0x352879),
    .gutter_fg = Colour.hex(0x6C5EB5),
    .terminal_bg = Colour.hex(0x000000),
    .terminal_fg = Colour.hex(0x6C5EB5),
    .status_bg = Colour.hex(0x352879),
    .status_fg = Colour.hex(0x7869C4),
    .current_line_bg = Colour.hex(0x4A3C9A),
    .selection_bg = Colour.hex(0x6C5EB5),
    .selection_fg = Colour.hex(0x40318D),
    .cursor = Colour.hex(0x7869C4),
    .match_bg = Colour.rgba(0x6A, 0xBF, 0xC6, 0x66),
    .error_underline = Colour.hex(0x9F4E44),
    .warning_underline = Colour.hex(0xC9D487),
    .title_bg = Colour.hex(0x352879),
    .title_fg = Colour.hex(0x7869C4),
    .divider = Colour.hex(0x6C5EB5),
    .scrollbar_track = Colour.hex(0x352879),
    .scrollbar_thumb = Colour.hex(0x6C5EB5),
    .find_bar_bg = Colour.hex(0x4A3C9A),
    .find_bar_fg = Colour.hex(0x7869C4),
    .rename_bg = Colour.hex(0x5CAB5E),

    // Syntax — authentic C64 colour palette
    .syntax = syntaxArray(.{
        .{ .default, Colour.hex(0x7869C4) }, // light blue (C64 default text)
        .{ .keyword, Colour.hex(0xFFFFFF) }, // white
        .{ .control_flow, Colour.hex(0x6ABFC6) }, // cyan
        .{ .type_keyword, Colour.hex(0xA057A3) }, // purple
        .{ .subroutine, Colour.hex(0x5CAB5E) }, // green
        .{ .number, Colour.hex(0xC9D487) }, // yellow
        .{ .string, Colour.hex(0x9AE29B) }, // light green
        .{ .comment, Colour.hex(0x626262) }, // dark grey
        .{ .operator, Colour.hex(0xB2B2B2) }, // light grey
        .{ .type_suffix, Colour.hex(0x898989) }, // medium grey
        .{ .delimiter, Colour.hex(0xB2B2B2) }, // light grey
        .{ .worker, Colour.hex(0x6ABFC6) }, // cyan
        .{ .err, Colour.hex(0x9F4E44) }, // C64 red
    }),
};

/// Theme 8: Dracula — the beloved dark theme with pastel accent colours.
pub const THEME_DRACULA = Theme{
    .name = "Dracula",
    .effects = .none,

    // UI — deep purple-grey background
    .editor_bg = Colour.hex(0x282A36),
    .gutter_bg = Colour.hex(0x21222C),
    .gutter_fg = Colour.hex(0x6272A4),
    .terminal_bg = Colour.hex(0x1E1F29),
    .terminal_fg = Colour.hex(0xF8F8F2),
    .status_bg = Colour.hex(0x21222C),
    .status_fg = Colour.hex(0xF8F8F2),
    .current_line_bg = Colour.hex(0x44475A),
    .selection_bg = Colour.hex(0x44475A),
    .selection_fg = Colour.hex(0xF8F8F2),
    .cursor = Colour.hex(0xF8F8F2),
    .match_bg = Colour.rgba(0xFF, 0xB8, 0x6C, 0x55),
    .error_underline = Colour.hex(0xFF5555),
    .warning_underline = Colour.hex(0xF1FA8C),
    .title_bg = Colour.hex(0x21222C),
    .title_fg = Colour.hex(0xF8F8F2),
    .divider = Colour.hex(0x44475A),
    .scrollbar_track = Colour.hex(0x21222C),
    .scrollbar_thumb = Colour.hex(0x44475A),
    .find_bar_bg = Colour.hex(0x44475A),
    .find_bar_fg = Colour.hex(0xF8F8F2),
    .rename_bg = Colour.hex(0x2A4030),

    // Syntax — Dracula's signature pastels
    .syntax = syntaxArray(.{
        .{ .default, Colour.hex(0xF8F8F2) }, // foreground
        .{ .keyword, Colour.hex(0xFF79C6) }, // pink
        .{ .control_flow, Colour.hex(0xFF79C6) }, // pink
        .{ .type_keyword, Colour.hex(0x8BE9FD) }, // cyan
        .{ .subroutine, Colour.hex(0x50FA7B) }, // green
        .{ .number, Colour.hex(0xBD93F9) }, // purple
        .{ .string, Colour.hex(0xF1FA8C) }, // yellow
        .{ .comment, Colour.hex(0x6272A4) }, // comment blue-grey
        .{ .operator, Colour.hex(0xFF79C6) }, // pink
        .{ .type_suffix, Colour.hex(0x8BE9FD) }, // cyan
        .{ .delimiter, Colour.hex(0xF8F8F2) }, // foreground
        .{ .worker, Colour.hex(0xBD93F9) }, // purple
        .{ .err, Colour.hex(0xFF5555) }, // red
    }),
};

/// Theme 9: Monokai — the classic warm dark theme from Sublime Text.
pub const THEME_MONOKAI = Theme{
    .name = "Monokai",
    .effects = .none,

    // UI — warm charcoal background
    .editor_bg = Colour.hex(0x272822),
    .gutter_bg = Colour.hex(0x222318),
    .gutter_fg = Colour.hex(0x90908A),
    .terminal_bg = Colour.hex(0x1A1B16),
    .terminal_fg = Colour.hex(0xF8F8F2),
    .status_bg = Colour.hex(0x222318),
    .status_fg = Colour.hex(0xF8F8F2),
    .current_line_bg = Colour.hex(0x3E3D32),
    .selection_bg = Colour.hex(0x49483E),
    .selection_fg = Colour.hex(0xF8F8F2),
    .cursor = Colour.hex(0xF8F8F0),
    .match_bg = Colour.rgba(0xE6, 0xDB, 0x74, 0x55),
    .error_underline = Colour.hex(0xF92672),
    .warning_underline = Colour.hex(0xE6DB74),
    .title_bg = Colour.hex(0x222318),
    .title_fg = Colour.hex(0xF8F8F2),
    .divider = Colour.hex(0x49483E),
    .scrollbar_track = Colour.hex(0x222318),
    .scrollbar_thumb = Colour.hex(0x49483E),
    .find_bar_bg = Colour.hex(0x3E3D32),
    .find_bar_fg = Colour.hex(0xF8F8F2),
    .rename_bg = Colour.hex(0x3A4030),

    // Syntax — Monokai's warm, saturated palette
    .syntax = syntaxArray(.{
        .{ .default, Colour.hex(0xF8F8F2) }, // foreground
        .{ .keyword, Colour.hex(0xF92672) }, // pink-red
        .{ .control_flow, Colour.hex(0xF92672) }, // pink-red
        .{ .type_keyword, Colour.hex(0x66D9EF) }, // blue
        .{ .subroutine, Colour.hex(0xA6E22E) }, // green
        .{ .number, Colour.hex(0xAE81FF) }, // purple
        .{ .string, Colour.hex(0xE6DB74) }, // yellow
        .{ .comment, Colour.hex(0x75715E) }, // warm grey
        .{ .operator, Colour.hex(0xF92672) }, // pink-red
        .{ .type_suffix, Colour.hex(0x66D9EF) }, // blue
        .{ .delimiter, Colour.hex(0xF8F8F2) }, // foreground
        .{ .worker, Colour.hex(0xFD971F) }, // orange
        .{ .err, Colour.hex(0xF92672) }, // pink-red
    }),
};

/// Theme 10: Synthwave '84 — neon-soaked 80s retrowave aesthetics.
pub const THEME_SYNTHWAVE = Theme{
    .name = "Synthwave '84",
    .effects = .scanlines,

    // UI — deep purple twilight with neon accents
    .editor_bg = Colour.hex(0x262335),
    .gutter_bg = Colour.hex(0x1E1A2E),
    .gutter_fg = Colour.hex(0x585480),
    .terminal_bg = Colour.hex(0x181520),
    .terminal_fg = Colour.hex(0xF0E4FC),
    .status_bg = Colour.hex(0x1E1A2E),
    .status_fg = Colour.hex(0xF0E4FC),
    .current_line_bg = Colour.hex(0x34294F),
    .selection_bg = Colour.hex(0x463465),
    .selection_fg = Colour.hex(0xF0E4FC),
    .cursor = Colour.hex(0xFF7EDB),
    .match_bg = Colour.rgba(0xFF, 0x7E, 0xDB, 0x44),
    .error_underline = Colour.hex(0xFE4450),
    .warning_underline = Colour.hex(0xFEDE5D),
    .title_bg = Colour.hex(0x1E1A2E),
    .title_fg = Colour.hex(0xF0E4FC),
    .divider = Colour.hex(0x463465),
    .scrollbar_track = Colour.hex(0x1E1A2E),
    .scrollbar_thumb = Colour.hex(0x463465),
    .find_bar_bg = Colour.hex(0x34294F),
    .find_bar_fg = Colour.hex(0xF0E4FC),
    .rename_bg = Colour.hex(0x2A3A40),

    // Syntax — hot neon on dark purple
    .syntax = syntaxArray(.{
        .{ .default, Colour.hex(0xF0E4FC) }, // soft white-lavender
        .{ .keyword, Colour.hex(0xFF7EDB) }, // hot pink
        .{ .control_flow, Colour.hex(0xFEDE5D) }, // neon yellow
        .{ .type_keyword, Colour.hex(0x36F9F6) }, // electric cyan
        .{ .subroutine, Colour.hex(0x72F1B8) }, // neon mint
        .{ .number, Colour.hex(0xF97E72) }, // coral
        .{ .string, Colour.hex(0xFF8B39) }, // neon orange
        .{ .comment, Colour.hex(0x848BBD) }, // muted lavender
        .{ .operator, Colour.hex(0xFEDE5D) }, // neon yellow
        .{ .type_suffix, Colour.hex(0x36F9F6) }, // electric cyan
        .{ .delimiter, Colour.hex(0xB6B1CC) }, // cool grey
        .{ .worker, Colour.hex(0xFF7EDB) }, // hot pink
        .{ .err, Colour.hex(0xFE4450) }, // neon red
    }),
};

/// Theme 11: Tokyo Night — deep midnight navy with cool neon accents.
pub const THEME_TOKYO_NIGHT = Theme{
    .name = "Tokyo Night",
    .effects = .none,

    // UI — deep midnight navy, cool blue-grey chrome
    .editor_bg = Colour.hex(0x1A1B2E),
    .gutter_bg = Colour.hex(0x16213E),
    .gutter_fg = Colour.hex(0x3A3F5C),
    .terminal_bg = Colour.hex(0x11121D),
    .terminal_fg = Colour.hex(0xA9B1D6),
    .status_bg = Colour.hex(0x16213E),
    .status_fg = Colour.hex(0xA9B1D6),
    .current_line_bg = Colour.hex(0x24253C),
    .selection_bg = Colour.hex(0x2F3060),
    .selection_fg = Colour.hex(0xC0CAF5),
    .cursor = Colour.hex(0x7AA2F7),
    .match_bg = Colour.rgba(0xFF, 0x9E, 0x64, 0x55),
    .error_underline = Colour.hex(0xF7768E),
    .warning_underline = Colour.hex(0xFF9E64),
    .title_bg = Colour.hex(0x16213E),
    .title_fg = Colour.hex(0xA9B1D6),
    .divider = Colour.hex(0x292B45),
    .scrollbar_track = Colour.hex(0x16213E),
    .scrollbar_thumb = Colour.hex(0x2F3060),
    .find_bar_bg = Colour.hex(0x24253C),
    .find_bar_fg = Colour.hex(0xC0CAF5),
    .rename_bg = Colour.hex(0x1A3A30),

    // Syntax — cool-toned neon on deep navy
    .syntax = syntaxArray(.{
        .{ .default, Colour.hex(0xC0CAF5) }, // soft blue-white
        .{ .keyword, Colour.hex(0xBB9AF7) }, // lavender purple
        .{ .control_flow, Colour.hex(0xF7768E) }, // rose pink
        .{ .type_keyword, Colour.hex(0x2AC3DE) }, // bright teal
        .{ .subroutine, Colour.hex(0x7AA2F7) }, // electric blue
        .{ .number, Colour.hex(0xFF9E64) }, // warm orange
        .{ .string, Colour.hex(0x9ECE6A) }, // soft green
        .{ .comment, Colour.hex(0x565F89) }, // muted purple-grey
        .{ .operator, Colour.hex(0x89DDFF) }, // ice blue
        .{ .type_suffix, Colour.hex(0x73DACA) }, // seafoam teal
        .{ .delimiter, Colour.hex(0x7982B4) }, // cool grey-blue
        .{ .worker, Colour.hex(0xBB9AF7) }, // lavender purple
        .{ .err, Colour.hex(0xF7768E) }, // rose red
    }),
};

/// Theme 12: Gruvbox Dark — earthy dark background with warm amber accents.
pub const THEME_GRUVBOX_DARK = Theme{
    .name = "Gruvbox Dark",
    .effects = .none,

    // UI — warm dark greys with amber highlights
    .editor_bg = Colour.hex(0x282828),
    .gutter_bg = Colour.hex(0x3C3836),
    .gutter_fg = Colour.hex(0x928374),
    .terminal_bg = Colour.hex(0x1D2021),
    .terminal_fg = Colour.hex(0xEBDBB2),
    .status_bg = Colour.hex(0x3C3836),
    .status_fg = Colour.hex(0xEBDBB2),
    .current_line_bg = Colour.hex(0x32302F),
    .selection_bg = Colour.hex(0x504945),
    .selection_fg = Colour.hex(0xEBDBB2),
    .cursor = Colour.hex(0xFE8019),
    .match_bg = Colour.rgba(0xFA, 0xBD, 0x2F, 0x55),
    .error_underline = Colour.hex(0xFB4934),
    .warning_underline = Colour.hex(0xFABD2F),
    .title_bg = Colour.hex(0x3C3836),
    .title_fg = Colour.hex(0xEBDBB2),
    .divider = Colour.hex(0x504945),
    .scrollbar_track = Colour.hex(0x3C3836),
    .scrollbar_thumb = Colour.hex(0x665C54),
    .find_bar_bg = Colour.hex(0x3C3836),
    .find_bar_fg = Colour.hex(0xEBDBB2),
    .rename_bg = Colour.hex(0x2E2A28),

    // Syntax — canonical gruvbox palette
    .syntax = syntaxArray(.{
        .{ .default, Colour.hex(0xEBDBB2) }, // soft light fg
        .{ .keyword, Colour.hex(0xFABD2F) }, // warm yellow
        .{ .control_flow, Colour.hex(0xFE8019) }, // bright orange
        .{ .type_keyword, Colour.hex(0x8EC07C) }, // aqua/green
        .{ .subroutine, Colour.hex(0x83A598) }, // muted blue
        .{ .number, Colour.hex(0xD3869B) }, // soft purple
        .{ .string, Colour.hex(0xB8BB26) }, // olive green
        .{ .comment, Colour.hex(0x928374) }, // muted grey
        .{ .operator, Colour.hex(0x458588) }, // deep teal/blue
        .{ .type_suffix, Colour.hex(0x8EC07C) }, // aqua/green
        .{ .delimiter, Colour.hex(0xEBDBB2) }, // foreground
        .{ .worker, Colour.hex(0xFE8019) }, // bright orange
        .{ .err, Colour.hex(0xFB4934) }, // red error
    }),
};

/// Theme 13: Solarized Dark+ — calm teal/amber on deep cyan-black.
pub const THEME_SOLARIZED_DARK_PLUS = Theme{
    .name = "Solarized Dark+",
    .effects = .none,

    // UI — deep cyan-black with soft sand text
    .editor_bg = Colour.hex(0x002B36),
    .gutter_bg = Colour.hex(0x073642),
    .gutter_fg = Colour.hex(0x839496),
    .terminal_bg = Colour.hex(0x002B36),
    .terminal_fg = Colour.hex(0xEEE8D5),
    .status_bg = Colour.hex(0x073642),
    .status_fg = Colour.hex(0x93A1A1),
    .current_line_bg = Colour.hex(0x0A3A45),
    .selection_bg = Colour.hex(0x0D4F5A),
    .selection_fg = Colour.hex(0xEEE8D5),
    .cursor = Colour.hex(0xB58900),
    .match_bg = Colour.rgba(0xB5, 0x89, 0x00, 0x55),
    .error_underline = Colour.hex(0xDC322F),
    .warning_underline = Colour.hex(0xCB4B16),
    .title_bg = Colour.hex(0x073642),
    .title_fg = Colour.hex(0xEEE8D5),
    .divider = Colour.hex(0x0F3640),
    .scrollbar_track = Colour.hex(0x073642),
    .scrollbar_thumb = Colour.hex(0x0D4F5A),
    .find_bar_bg = Colour.hex(0x073642),
    .find_bar_fg = Colour.hex(0xEEE8D5),
    .rename_bg = Colour.hex(0x0B3C46),

    // Syntax — classic solarized accents
    .syntax = syntaxArray(.{
        .{ .default, Colour.hex(0xEEE8D5) }, // base2
        .{ .keyword, Colour.hex(0xB58900) }, // yellow/amber
        .{ .control_flow, Colour.hex(0xCB4B16) }, // orange
        .{ .type_keyword, Colour.hex(0x2AA198) }, // cyan
        .{ .subroutine, Colour.hex(0x268BD2) }, // blue
        .{ .number, Colour.hex(0xD33682) }, // magenta
        .{ .string, Colour.hex(0x859900) }, // green
        .{ .comment, Colour.hex(0x586E75) }, // base01
        .{ .operator, Colour.hex(0x93A1A1) }, // base1
        .{ .type_suffix, Colour.hex(0x2AA198) }, // cyan
        .{ .delimiter, Colour.hex(0x93A1A1) }, // base1
        .{ .worker, Colour.hex(0x268BD2) }, // blue
        .{ .err, Colour.hex(0xDC322F) }, // red
    }),
};

/// Theme 14: Nord Midnight — cool polar night with frost accents.
pub const THEME_NORD_MIDNIGHT = Theme{
    .name = "Nord Midnight",
    .effects = .none,

    // UI — polar night greys with frost highlights
    .editor_bg = Colour.hex(0x2E3440),
    .gutter_bg = Colour.hex(0x242933),
    .gutter_fg = Colour.hex(0x596273),
    .terminal_bg = Colour.hex(0x242933),
    .terminal_fg = Colour.hex(0xE5E9F0),
    .status_bg = Colour.hex(0x2E3440),
    .status_fg = Colour.hex(0xE5E9F0),
    .current_line_bg = Colour.hex(0x3B4252),
    .selection_bg = Colour.hex(0x434C5E),
    .selection_fg = Colour.hex(0xE5E9F0),
    .cursor = Colour.hex(0x88C0D0),
    .match_bg = Colour.rgba(0x88, 0xC0, 0xD0, 0x55),
    .error_underline = Colour.hex(0xBF616A),
    .warning_underline = Colour.hex(0xD08770),
    .title_bg = Colour.hex(0x2E3440),
    .title_fg = Colour.hex(0xE5E9F0),
    .divider = Colour.hex(0x3B4252),
    .scrollbar_track = Colour.hex(0x242933),
    .scrollbar_thumb = Colour.hex(0x434C5E),
    .find_bar_bg = Colour.hex(0x2E3440),
    .find_bar_fg = Colour.hex(0xE5E9F0),
    .rename_bg = Colour.hex(0x3A3F4A),

    // Syntax — frost palette with warm signals
    .syntax = syntaxArray(.{
        .{ .default, Colour.hex(0xE5E9F0) }, // snow
        .{ .keyword, Colour.hex(0x81A1C1) }, // blue
        .{ .control_flow, Colour.hex(0xD08770) }, // amber
        .{ .type_keyword, Colour.hex(0x88C0D0) }, // frost
        .{ .subroutine, Colour.hex(0x5E81AC) }, // deep blue
        .{ .number, Colour.hex(0xB48EAD) }, // purple
        .{ .string, Colour.hex(0xA3BE8C) }, // green
        .{ .comment, Colour.hex(0x616E88) }, // muted frost
        .{ .operator, Colour.hex(0x8FBCBB) }, // teal frost
        .{ .type_suffix, Colour.hex(0x8FBCBB) }, // teal frost
        .{ .delimiter, Colour.hex(0xD8DEE9) }, // pale frost
        .{ .worker, Colour.hex(0x81A1C1) }, // blue
        .{ .err, Colour.hex(0xBF616A) }, // red
    }),
};

/// Theme 15: One Dark Vibrant — punchy neon accents on charcoal.
pub const THEME_ONE_DARK_VIBRANT = Theme{
    .name = "One Dark Vibrant",
    .effects = .none,

    // UI — charcoal base with bright metal accents
    .editor_bg = Colour.hex(0x21252B),
    .gutter_bg = Colour.hex(0x1C1F24),
    .gutter_fg = Colour.hex(0x5C6370),
    .terminal_bg = Colour.hex(0x1C1F24),
    .terminal_fg = Colour.hex(0xE6E9EF),
    .status_bg = Colour.hex(0x1C1F24),
    .status_fg = Colour.hex(0xABB2BF),
    .current_line_bg = Colour.hex(0x2C313A),
    .selection_bg = Colour.hex(0x3A4049),
    .selection_fg = Colour.hex(0xE6E9EF),
    .cursor = Colour.hex(0x61AFEF),
    .match_bg = Colour.rgba(0xE5, 0xC0, 0x7B, 0x55),
    .error_underline = Colour.hex(0xE06C75),
    .warning_underline = Colour.hex(0xE5C07B),
    .title_bg = Colour.hex(0x1C1F24),
    .title_fg = Colour.hex(0xE6E9EF),
    .divider = Colour.hex(0x2C313A),
    .scrollbar_track = Colour.hex(0x1C1F24),
    .scrollbar_thumb = Colour.hex(0x3A4049),
    .find_bar_bg = Colour.hex(0x2C313A),
    .find_bar_fg = Colour.hex(0xE6E9EF),
    .rename_bg = Colour.hex(0x2A2F36),

    // Syntax — vibrant One Dark-inspired accents
    .syntax = syntaxArray(.{
        .{ .default, Colour.hex(0xE6E9EF) }, // base fg
        .{ .keyword, Colour.hex(0xC678DD) }, // magenta
        .{ .control_flow, Colour.hex(0xE06C75) }, // red
        .{ .type_keyword, Colour.hex(0x56B6C2) }, // cyan
        .{ .subroutine, Colour.hex(0x61AFEF) }, // blue
        .{ .number, Colour.hex(0xD19A66) }, // orange
        .{ .string, Colour.hex(0x98C379) }, // green
        .{ .comment, Colour.hex(0x7F848E) }, // muted grey
        .{ .operator, Colour.hex(0xE5C07B) }, // yellow
        .{ .type_suffix, Colour.hex(0x56B6C2) }, // cyan
        .{ .delimiter, Colour.hex(0xABB2BF) }, // soft grey
        .{ .worker, Colour.hex(0xC678DD) }, // magenta
        .{ .err, Colour.hex(0xE06C75) }, // red
    }),
};

// ─── Theme Lookup ───────────────────────────────────────────────────────────

/// Theme 6: Paper White — clean monochrome ink-on-paper with shades of grey.
pub const THEME_PAPER_WHITE = Theme{
    .name = "Paper White",
    .effects = .none,

    // UI — near-white page background, dark ink text, grey chrome
    .editor_bg = Colour.hex(0xF5F5F0), // warm paper white
    .gutter_bg = Colour.hex(0xE8E8E2), // slightly darker paper
    .gutter_fg = Colour.hex(0x999990), // mid-grey line numbers
    .terminal_bg = Colour.hex(0x1A1A1A), // near-black terminal
    .terminal_fg = Colour.hex(0xD8D8D0), // light grey terminal text
    .status_bg = Colour.hex(0x2A2A2A), // dark charcoal status bar
    .status_fg = Colour.hex(0xD0D0C8), // light grey status text
    .current_line_bg = Colour.hex(0xEAEAE4), // very subtle grey highlight
    .selection_bg = Colour.hex(0x2A2A2A), // dark ink selection
    .selection_fg = Colour.hex(0xF5F5F0), // paper white selected text
    .cursor = Colour.hex(0x1A1A1A), // black cursor
    .match_bg = Colour.rgba(0x80, 0x80, 0x78, 0x55), // grey match highlight
    .error_underline = Colour.hex(0x4A4A4A), // dark grey errors (no red)
    .warning_underline = Colour.hex(0x888880), // mid-grey warnings
    .title_bg = Colour.hex(0x2A2A2A), // dark charcoal title bar
    .title_fg = Colour.hex(0xF5F5F0), // paper white title text
    .divider = Colour.hex(0xC8C8C0), // light grey divider
    .scrollbar_track = Colour.hex(0xE0E0D8), // pale grey track
    .scrollbar_thumb = Colour.hex(0xA0A098), // mid-grey thumb
    .find_bar_bg = Colour.hex(0xE0E0D8), // pale grey find bar
    .find_bar_fg = Colour.hex(0x1A1A1A), // black find text
    .rename_bg = Colour.hex(0xD8D8D0), // light grey rename highlight

    // Syntax — all shades of grey/black on paper white
    .syntax = syntaxArray(.{
        .{ .default, Colour.hex(0x1A1A1A) }, // near-black body text
        .{ .keyword, Colour.hex(0x0A0A0A) }, // pure black keywords (bold implied)
        .{ .control_flow, Colour.hex(0x2A2A2A) }, // very dark grey control
        .{ .type_keyword, Colour.hex(0x404040) }, // dark grey types
        .{ .subroutine, Colour.hex(0x303030) }, // dark grey subs/funcs
        .{ .number, Colour.hex(0x585850) }, // medium-dark grey numbers
        .{ .string, Colour.hex(0x484840) }, // medium grey strings
        .{ .comment, Colour.hex(0xA0A098) }, // light grey comments
        .{ .operator, Colour.hex(0x383830) }, // dark grey operators
        .{ .type_suffix, Colour.hex(0x686860) }, // medium grey suffixes
        .{ .delimiter, Colour.hex(0x505048) }, // mid-dark grey delimiters
        .{ .worker, Colour.hex(0x202020) }, // very dark grey workers
        .{ .err, Colour.hex(0x1A1A1A) }, // black errors (underline distinguishes)
    }),
};

/// All built-in themes, indexed by ThemeId.
pub const THEMES = [_]*const Theme{
    &THEME_FASTERBASIC,
    &THEME_NEON,
    &THEME_RETRO,
    &THEME_RETRO_CRT,
    &THEME_RETRO_AMBER_CRT,
    &THEME_PAPER_WHITE,
    &THEME_C64,
    &THEME_DRACULA,
    &THEME_MONOKAI,
    &THEME_SYNTHWAVE,
    &THEME_TOKYO_NIGHT,
    &THEME_GRUVBOX_DARK,
    &THEME_SOLARIZED_DARK_PLUS,
    &THEME_NORD_MIDNIGHT,
    &THEME_ONE_DARK_VIBRANT,
};

/// Get a theme by its ID.
pub fn getTheme(id: ThemeId) *const Theme {
    return THEMES[@intFromEnum(id)];
}

// ─── Helper: Build syntax colour array from a struct literal ────────────────

fn syntaxArray(comptime entries: anytype) [SyntaxCategory.COUNT]Colour {
    var result: [SyntaxCategory.COUNT]Colour = undefined;
    // Fill with a default (magenta = "you forgot this category")
    for (&result) |*c| {
        c.* = Colour.hex(0xFF00FF);
    }
    inline for (entries) |entry| {
        const cat: SyntaxCategory = entry.@"0";
        const col: Colour = entry.@"1";
        result[@intFromEnum(cat)] = col;
    }
    return result;
}

// ─── Tests ──────────────────────────────────────────────────────────────────

test "Colour.hex creates correct colour" {
    const c = Colour.hex(0xFF8800);
    try std.testing.expectEqual(@as(u8, 0xFF), c.r);
    try std.testing.expectEqual(@as(u8, 0x88), c.g);
    try std.testing.expectEqual(@as(u8, 0x00), c.b);
    try std.testing.expectEqual(@as(u8, 0xFF), c.a);
}

test "Colour.toFloat4 normalises to 0-1 range" {
    const c = Colour.rgb(255, 128, 0);
    const f = c.toFloat4();
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), f[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.502), f[1], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), f[2], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), f[3], 0.01);
}

test "Colour.toBytes packs correctly" {
    const c = Colour.rgba(10, 20, 30, 40);
    const b = c.toBytes();
    try std.testing.expectEqual(@as(u8, 10), b[0]);
    try std.testing.expectEqual(@as(u8, 20), b[1]);
    try std.testing.expectEqual(@as(u8, 30), b[2]);
    try std.testing.expectEqual(@as(u8, 40), b[3]);
}

test "paper white theme has correct background" {
    const t = getTheme(.paper_white);
    try std.testing.expectEqualStrings("Paper White", t.name);
    // editor background should be near-white
    try std.testing.expect(t.editor_bg.r > 240);
    try std.testing.expect(t.editor_bg.g > 240);
    try std.testing.expect(t.editor_bg.b > 235);
    // cursor should be dark
    try std.testing.expect(t.cursor.r < 30);
    try std.testing.expect(t.cursor.g < 30);
    try std.testing.expect(t.cursor.b < 30);
}

test "theme lookup returns correct theme" {
    const qb = getTheme(.fasterbasic);
    try std.testing.expectEqualStrings("FasterBASIC", qb.name);

    const neon = getTheme(.neon);
    try std.testing.expectEqualStrings("Neon", neon.name);

    const retro = getTheme(.retro);
    try std.testing.expectEqualStrings("Retro", retro.name);

    const retro_crt = getTheme(.retro_crt);
    try std.testing.expectEqualStrings("Retro CRT", retro_crt.name);
    try std.testing.expectEqual(ThemeEffects.crt, retro_crt.effects);

    const retro_amber_crt = getTheme(.retro_amber_crt);
    try std.testing.expectEqualStrings("Retro Amber CRT", retro_amber_crt.name);
    try std.testing.expectEqual(ThemeEffects.crt, retro_amber_crt.effects);

    const paper_white = getTheme(.paper_white);
    try std.testing.expectEqualStrings("Paper White", paper_white.name);
    try std.testing.expectEqual(ThemeEffects.none, paper_white.effects);

    const c64 = getTheme(.c64);
    try std.testing.expectEqualStrings("Commodore 64", c64.name);
    try std.testing.expectEqual(ThemeEffects.none, c64.effects);

    const dracula = getTheme(.dracula);
    try std.testing.expectEqualStrings("Dracula", dracula.name);
    try std.testing.expectEqual(ThemeEffects.none, dracula.effects);

    const monokai = getTheme(.monokai);
    try std.testing.expectEqualStrings("Monokai", monokai.name);
    try std.testing.expectEqual(ThemeEffects.none, monokai.effects);

    const synthwave = getTheme(.synthwave);
    try std.testing.expectEqualStrings("Synthwave '84", synthwave.name);
    try std.testing.expectEqual(ThemeEffects.scanlines, synthwave.effects);

    const tokyo = getTheme(.tokyo_night);
    try std.testing.expectEqualStrings("Tokyo Night", tokyo.name);
    try std.testing.expectEqual(ThemeEffects.none, tokyo.effects);

    const gruvbox = getTheme(.gruvbox_dark);
    try std.testing.expectEqualStrings("Gruvbox Dark", gruvbox.name);
    try std.testing.expectEqual(ThemeEffects.none, gruvbox.effects);

    const solarized = getTheme(.solarized_dark_plus);
    try std.testing.expectEqualStrings("Solarized Dark+", solarized.name);
    try std.testing.expectEqual(ThemeEffects.none, solarized.effects);

    const nord = getTheme(.nord_midnight);
    try std.testing.expectEqualStrings("Nord Midnight", nord.name);
    try std.testing.expectEqual(ThemeEffects.none, nord.effects);

    const one_dark = getTheme(.one_dark_vibrant);
    try std.testing.expectEqualStrings("One Dark Vibrant", one_dark.name);
    try std.testing.expectEqual(ThemeEffects.none, one_dark.effects);
}

test "syntax colour lookup works for all categories" {
    const theme = getTheme(.fasterbasic);
    // Every category should have a non-magenta colour (magenta = uninitialised sentinel)
    const magenta = Colour.hex(0xFF00FF);
    inline for (std.meta.fields(SyntaxCategory)) |field| {
        const cat: SyntaxCategory = @enumFromInt(field.value);
        const c = theme.syntaxColour(cat);
        try std.testing.expect(!c.eql(magenta));
    }
}

test "ThemeId cycles correctly" {
    try std.testing.expectEqual(ThemeId.neon, ThemeId.fasterbasic.next());
    try std.testing.expectEqual(ThemeId.retro, ThemeId.neon.next());
    try std.testing.expectEqual(ThemeId.retro_crt, ThemeId.retro.next());
    try std.testing.expectEqual(ThemeId.retro_amber_crt, ThemeId.retro_crt.next());
    try std.testing.expectEqual(ThemeId.paper_white, ThemeId.retro_amber_crt.next());
    try std.testing.expectEqual(ThemeId.c64, ThemeId.paper_white.next());
    try std.testing.expectEqual(ThemeId.dracula, ThemeId.c64.next());
    try std.testing.expectEqual(ThemeId.monokai, ThemeId.dracula.next());
    try std.testing.expectEqual(ThemeId.synthwave, ThemeId.monokai.next());
    try std.testing.expectEqual(ThemeId.tokyo_night, ThemeId.synthwave.next());
    try std.testing.expectEqual(ThemeId.gruvbox_dark, ThemeId.tokyo_night.next());
    try std.testing.expectEqual(ThemeId.solarized_dark_plus, ThemeId.gruvbox_dark.next());
    try std.testing.expectEqual(ThemeId.nord_midnight, ThemeId.solarized_dark_plus.next());
    try std.testing.expectEqual(ThemeId.one_dark_vibrant, ThemeId.nord_midnight.next());
    try std.testing.expectEqual(ThemeId.fasterbasic, ThemeId.one_dark_vibrant.next());
}

test "Colour.lighten and darken" {
    const c = Colour.rgb(100, 100, 100);

    const lighter = c.lighten(0.5);
    try std.testing.expect(lighter.r > c.r);
    try std.testing.expect(lighter.g > c.g);

    const darker = c.darken(0.5);
    try std.testing.expect(darker.r < c.r);
    try std.testing.expect(darker.g < c.g);
}

test "Colour.blend" {
    const fg = Colour.rgba(255, 0, 0, 128);
    const bg = Colour.rgb(0, 0, 255);
    const blended = fg.blend(bg);
    // With ~50% alpha, red channel should be around 128, blue around 127
    try std.testing.expect(blended.r > 100 and blended.r < 160);
    try std.testing.expect(blended.b > 100 and blended.b < 160);
    try std.testing.expectEqual(@as(u8, 255), blended.a);
}
