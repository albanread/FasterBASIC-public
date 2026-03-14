//! Ed Main — Entry Point, Editor State, Frame Building, and Input Handling
//!
//! This is the central module of the Ed editor. It owns:
//!   - The editor state (buffer, cursor, scroll, mode, theme)
//!   - The frame callback (builds GlyphInstance arrays for Metal rendering)
//!   - Keyboard input dispatch (editing, navigation, commands)
//!   - The main() entry point that initialises the platform and runs
//!
//! All platform interaction goes through platform.zig (C ABI to ObjC bridge).
//! All text storage goes through ed_buffer.zig (rope with UTF-32).
//! All colours come from ed_theme.zig.

const std = @import("std");
const builtin = @import("builtin");
const buffer_mod = @import("ed_buffer.zig");
const theme_mod = @import("ed_theme.zig");
const platform = @import("platform.zig");
const terminal_mod = @import("ed_terminal.zig");
const jit_mod = @import("ed_jit.zig");
const format_mod = @import("ed_format.zig");
const baz_mod = @import("ed_baz.zig");
const symbols_mod = @import("ed_symbols.zig");
const keyword_help = @import("ed_keyword_help.zig");
const sa_mod = @import("smart_assist");

// Import graphics modules so their `export fn` symbols are linked into the
// binary.  The ObjC bridge (ed_graphics_bridge.m) and JIT-executed BASIC
// programs resolve these via dlsym(RTLD_DEFAULT, ...).
comptime {
    _ = @import("ed_graphics");
    _ = @import("graphics_runtime");
    _ = @import("audio_runtime");
    _ = @import("editor_runtime_stubs.zig");
}

// Graphics subsystem lifecycle (defined in ed_graphics_bridge.m).
// ed_graphics_init() starts a main-thread polling timer that drains the
// SPSC command ring and processes window creation/destruction commands.
// Must be called after ed_platform_init() but before ed_platform_run().
extern fn ed_graphics_init() callconv(.c) void;
extern fn ed_graphics_shutdown() callconv(.c) void;

const RopeBuffer = buffer_mod.RopeBuffer;
const Colour = theme_mod.Colour;
const SyntaxCategory = theme_mod.SyntaxCategory;
const Theme = theme_mod.Theme;
const ThemeId = theme_mod.ThemeId;
const GlyphInstance = platform.GlyphInstance;
const EdUniforms = platform.EdUniforms;
const EdFrameData = platform.EdFrameData;
const GlyphAtlasInfo = platform.GlyphAtlasInfo;
const KeyEvent = platform.KeyEvent;
const MouseEvent = platform.MouseEvent;
const WindowEvent = platform.WindowEvent;
const Modifiers = platform.Modifiers;
const VK = platform.VK;
const Terminal = terminal_mod.Terminal;
const JitRunner = jit_mod.JitRunner;
const SymbolIndex = symbols_mod.SymbolIndex;
const SymbolEntry = symbols_mod.SymbolEntry;
const SymbolKind = symbols_mod.SymbolKind;

extern fn platform_show_help(keyword: [*:0]const u8) void;
extern fn platform_show_report(title: [*c]const u8, html_body: [*c]const u8) callconv(.c) void;
extern fn platform_set_help_theme(theme_id: c_int) void;

// ─── Constants ──────────────────────────────────────────────────────────────

/// Maximum number of glyph instances per frame (generous for large viewports).
const MAX_INSTANCES: usize = 200_000;

/// Auto-closing pair characters.
const AUTO_CLOSE_PAIRS = [_][2]u32{
    .{ '(', ')' },
    .{ '[', ']' },
    .{ '{', '}' },
};
/// Matching bracket pairs for bracket matching highlight.
const BRACKET_OPEN = [_]u32{ '(', '[', '{' };
const BRACKET_CLOSE = [_]u32{ ')', ']', '}' };

/// Gutter width in characters (for line numbers + fold indicator).
const GUTTER_CHARS: usize = 7;

/// Maximum number of fold regions.
const MAX_FOLD_REGIONS: usize = 512;

/// A collapsible code region (start_line is visible with ▶, lines start_line+1..end_line are hidden).
const FoldRegion = struct {
    start_line: usize, // the opening line (e.g. SUB, FOR, IF)
    end_line: usize, // the closing line (e.g. END SUB, NEXT, END IF)
};

/// Scrollbar reserved width in pixels.
const SCROLLBAR_WIDTH: f32 = 14.0;

/// Status bar height in lines.
const STATUS_BAR_LINES: u32 = 1;

/// Terminal pane minimum height in lines.
const TERMINAL_MIN_LINES: u32 = 3;

/// Default terminal pane height in lines.
const TERMINAL_DEFAULT_LINES: u32 = 8;

/// Cursor blink period in seconds (on time).
const CURSOR_BLINK_ON: f64 = 0.53;

/// Cursor blink period in seconds (off time).
const CURSOR_BLINK_OFF: f64 = 0.53;

/// Tab width in spaces.
const TAB_WIDTH: usize = 2;

/// Auto-indent: number of spaces per indent level.
const INDENT_WIDTH: usize = 2;

/// Maximum length of find/replace query strings.
const FIND_MAX_LEN: usize = 256;

fn formatDurationSeconds(buf: []u8, ms: f64) []const u8 {
    return std.fmt.bufPrint(buf, "{d:.1}s", .{ms / 1000.0}) catch "0.0s";
}

// ─── Editor Mode ────────────────────────────────────────────────────────────

const EditorFocus = enum {
    editor,
    terminal,
    find_bar,
    replace_bar,
    symbol_overlay,
    autocomplete,
};

/// A position in the terminal's combined scrollback+grid coordinate space.
const TermSelPos = struct {
    line: usize, // combined line index (0..scrollback_count+rows)
    col: usize, // column index (0-based)

    /// Returns true if a comes before b in reading order.
    fn lessThan(a: TermSelPos, b: TermSelPos) bool {
        return a.line < b.line or (a.line == b.line and a.col < b.col);
    }

    fn eql(a: TermSelPos, b: TermSelPos) bool {
        return a.line == b.line and a.col == b.col;
    }
};

// ─── Overlay State ──────────────────────────────────────────────────────────

const OVERLAY_MAX_VISIBLE: usize = 16;
const OVERLAY_MAX_ITEMS: usize = 512;
const OVERLAY_FILTER_MAX: usize = 64;

const OverlayState = struct {
    /// Filtered item indices (into the source list).
    items: [OVERLAY_MAX_ITEMS]u32 = undefined,
    item_count: u16 = 0,

    /// Currently selected item (0-based index into `items`).
    selected: u16 = 0,

    /// Scroll offset (first visible item index).
    scroll: u16 = 0,

    /// Filter text typed by the user (codepoints for matching).
    filter: [OVERLAY_FILTER_MAX]u32 = undefined,
    filter_len: u16 = 0,

    /// Whether the overlay is currently visible.
    visible: bool = false,

    /// Screen position where the overlay should appear (in pixels).
    anchor_x: f32 = 0,
    anchor_y: f32 = 0,

    /// Cursor position when the overlay was opened (for autocomplete insertion).
    trigger_cursor: usize = 0,
    /// Column of the start of the prefix being completed.
    prefix_start_col: usize = 0,

    pub fn open(self: *OverlayState) void {
        self.selected = 0;
        self.scroll = 0;
        self.filter_len = 0;
        self.item_count = 0;
        self.visible = true;
    }

    pub fn close(self: *OverlayState) void {
        self.visible = false;
        self.filter_len = 0;
        self.item_count = 0;
    }

    pub fn appendFilter(self: *OverlayState, cp: u32) void {
        if (self.filter_len < OVERLAY_FILTER_MAX) {
            self.filter[self.filter_len] = cp;
            self.filter_len += 1;
        }
    }

    pub fn deleteFilter(self: *OverlayState) void {
        if (self.filter_len > 0) {
            self.filter_len -= 1;
        }
    }

    pub fn moveUp(self: *OverlayState) void {
        if (self.selected > 0) {
            self.selected -= 1;
            if (self.selected < self.scroll) {
                self.scroll = self.selected;
            }
        }
    }

    pub fn moveDown(self: *OverlayState) void {
        if (self.item_count > 0 and self.selected + 1 < self.item_count) {
            self.selected += 1;
            const max_visible: u16 = @intCast(OVERLAY_MAX_VISIBLE);
            if (self.selected >= self.scroll + max_visible) {
                self.scroll = self.selected - max_visible + 1;
            }
        }
    }

    pub fn selectedIndex(self: *const OverlayState) ?u32 {
        if (self.item_count == 0) return null;
        if (self.selected >= self.item_count) return null;
        return self.items[self.selected];
    }

    pub fn filterSlice(self: *const OverlayState) []const u32 {
        return self.filter[0..self.filter_len];
    }
};

// ─── Find State ─────────────────────────────────────────────────────────────

/// Information about an error on a specific line, used for highlighting.
const ErrorLineInfo = struct {
    /// 0-based line index in the buffer.
    line: usize,
    /// 0-based column index (0 if unknown).
    col: usize,
    /// Whether this is a warning (false = error).
    is_warning: bool,
    /// Short message text (fixed buffer, owned).
    message_buf: [256]u8,
    message_len: u16,

    pub fn message(self: *const ErrorLineInfo) []const u8 {
        return self.message_buf[0..self.message_len];
    }
};

const FindState = struct {
    /// The search query as code points.
    query: [FIND_MAX_LEN]u32 = [_]u32{0} ** FIND_MAX_LEN,
    query_len: usize = 0,

    /// The replace string as code points.
    replace: [FIND_MAX_LEN]u32 = [_]u32{0} ** FIND_MAX_LEN,
    replace_len: usize = 0,

    /// All match positions (buffer offsets of match starts).
    matches: std.ArrayListUnmanaged(usize) = .{},

    /// Index of the currently highlighted match (-1 = none).
    current_match: ?usize = null,

    /// Whether the find bar is visible.
    visible: bool = false,

    /// Whether the replace bar is visible (below the find bar).
    replace_visible: bool = false,

    /// Case-insensitive search.
    case_insensitive: bool = true,

    pub fn deinit(self: *FindState, allocator: std.mem.Allocator) void {
        self.matches.deinit(allocator);
    }

    pub fn clearMatches(self: *FindState, allocator: std.mem.Allocator) void {
        self.matches.clearRetainingCapacity();
        _ = allocator;
        self.current_match = null;
    }

    pub fn appendChar(self: *FindState, cp: u32) void {
        if (self.query_len < FIND_MAX_LEN) {
            self.query[self.query_len] = cp;
            self.query_len += 1;
        }
    }

    pub fn deleteChar(self: *FindState) void {
        if (self.query_len > 0) {
            self.query_len -= 1;
            self.query[self.query_len] = 0;
        }
    }

    pub fn appendReplaceChar(self: *FindState, cp: u32) void {
        if (self.replace_len < FIND_MAX_LEN) {
            self.replace[self.replace_len] = cp;
            self.replace_len += 1;
        }
    }

    pub fn deleteReplaceChar(self: *FindState) void {
        if (self.replace_len > 0) {
            self.replace_len -= 1;
            self.replace[self.replace_len] = 0;
        }
    }

    pub fn querySlice(self: *const FindState) []const u32 {
        return self.query[0..self.query_len];
    }

    pub fn replaceSlice(self: *const FindState) []const u32 {
        return self.replace[0..self.replace_len];
    }
};

// ─── Rename State ───────────────────────────────────────────────────────────

const RENAME_MAX_LEN = FIND_MAX_LEN;

const RenameState = struct {
    /// The original symbol name (codepoints, as found under cursor).
    old_name: [RENAME_MAX_LEN]u32 = [_]u32{0} ** RENAME_MAX_LEN,
    old_name_len: usize = 0,

    /// Buffer offset where the primary (edited) occurrence starts.
    primary_offset: usize = 0,

    /// Line and column of the primary occurrence (for rendering).
    primary_line: usize = 0,
    primary_col: usize = 0,

    /// All OTHER match positions (buffer offsets, excludes primary).
    matches: std.ArrayListUnmanaged(usize) = .{},

    /// Whether inline rename mode is active.
    visible: bool = false,

    pub fn deinit(self: *RenameState, allocator: std.mem.Allocator) void {
        self.matches.deinit(allocator);
    }

    pub fn open(self: *RenameState) void {
        self.visible = true;
    }

    pub fn close(self: *RenameState, allocator: std.mem.Allocator) void {
        self.visible = false;
        self.old_name_len = 0;
        self.primary_offset = 0;
        self.primary_line = 0;
        self.primary_col = 0;
        self.matches.clearRetainingCapacity();
        _ = allocator;
    }

    pub fn setOldName(self: *RenameState, word: []const u32) void {
        const copy_len = @min(word.len, RENAME_MAX_LEN);
        for (word[0..copy_len], 0..) |cp, i| {
            self.old_name[i] = cp;
        }
        self.old_name_len = copy_len;
    }

    pub fn oldNameSlice(self: *const RenameState) []const u32 {
        return self.old_name[0..self.old_name_len];
    }

    /// Compute the current length of the word at primary_offset by scanning
    /// forward in the buffer until a non-ident character is reached.
    /// Includes a trailing BASIC type suffix ($, %, !, #, &) if present.
    pub fn currentWordLen(self: *const RenameState, buffer: *const RopeBuffer) usize {
        const buf_len = buffer.length();
        if (self.primary_offset >= buf_len) return 0;
        var end = self.primary_offset;
        while (end < buf_len) {
            const cp = buffer.charAt(end) orelse break;
            if (!isIdentChar(cp)) {
                // Check for trailing type suffix
                if (cp == '$' or cp == '%' or cp == '!' or cp == '#' or cp == '&') {
                    end += 1;
                }
                break;
            }
            end += 1;
        }
        return end - self.primary_offset;
    }

    /// Read the current word at primary_offset from the buffer.
    pub fn readCurrentWord(self: *const RenameState, buffer: *const RopeBuffer, out: []u32) usize {
        const wlen = self.currentWordLen(buffer);
        const copy_len = @min(wlen, out.len);
        for (0..copy_len) |i| {
            out[i] = buffer.charAt(self.primary_offset + i) orelse ' ';
        }
        return copy_len;
    }
};

// ─── Undo Entry ─────────────────────────────────────────────────────────────

const UndoEntry = struct {
    /// Position where the edit occurred.
    pos: usize,
    /// Text that was deleted (empty for pure inserts).
    deleted: []u32,
    /// Text that was inserted (empty for pure deletes).
    inserted: []u32,
    /// Cursor position before the edit (for restoring).
    cursor_before: usize,
    /// Timestamp of this edit (for coalescing).
    timestamp: f64,

    pub fn deinit(self: *UndoEntry, allocator: std.mem.Allocator) void {
        if (self.deleted.len > 0) allocator.free(self.deleted);
        if (self.inserted.len > 0) allocator.free(self.inserted);
    }
};

// ─── Editor State ───────────────────────────────────────────────────────────

const EditorState = struct {
    /// The text buffer (rope, UTF-32).
    buffer: RopeBuffer,

    /// Cursor position as a code point offset into the buffer.
    cursor: usize,

    /// Desired column (for up/down navigation to maintain column position).
    desired_col: ?usize,

    /// Selection anchor (if non-null, there is an active selection from anchor..cursor).
    selection_anchor: ?usize,

    /// Vertical scroll offset in lines (top visible line).
    scroll_line: usize,

    /// Horizontal scroll offset in columns.
    scroll_col: usize,

    /// Current theme.
    theme_id: ThemeId,

    /// Which pane has focus.
    focus: EditorFocus,

    /// Whether the file has been modified since last save.
    modified: bool,

    /// Current file path (null for untitled).
    file_path: ?[]const u8,

    /// Time since start in seconds.
    time: f64,

    /// Whether the cursor is in the "visible" phase of its blink cycle.
    cursor_visible: bool,

    /// Time accumulator for cursor blink.
    cursor_blink_timer: f64,

    /// Window has input focus.
    window_focused: bool,

    /// Viewport dimensions (updated on resize).
    viewport_width: f32,
    viewport_height: f32,
    viewport_scale: f32,

    /// Cached atlas info (set after platform init).
    atlas: GlyphAtlasInfo,

    /// Terminal pane height in lines.
    terminal_lines: u32,

    /// Terminal pane height before a Run expanded it (so we can restore).
    terminal_lines_before_run: u32,

    /// Terminal pane visible.
    terminal_visible: bool,

    /// Terminal is in full-screen mode (fills entire window).
    terminal_fullscreen: bool,

    /// Terminal lines before fullscreen was toggled (to restore).
    terminal_lines_before_fullscreen: u32,

    /// Terminal scroll offset into scrollback (0 = showing live bottom, >0 = scrolled up).
    terminal_scroll_offset: usize,

    /// Whether the terminal is auto-scrolled to the bottom (tracks new output).
    terminal_pinned_to_bottom: bool,

    /// Tracks the current cursor style so we only call the platform when it changes.
    cursor_is_resize: bool,

    /// Splitter drag state: true while the user is dragging the editor/terminal divider.
    splitter_dragging: bool,

    /// The mouse Y position (in pixels) where the splitter drag started.
    splitter_drag_start_y: f32,

    /// The terminal_lines value when the splitter drag started.
    splitter_drag_start_lines: u32,

    /// Terminal pane (cell grid with VT100 support).
    terminal: Terminal,

    /// Find bar state.
    find_state: FindState,

    /// Rename bar state.
    rename_state: RenameState,

    /// Undo stack.
    undo_stack: std.ArrayListUnmanaged(UndoEntry),

    /// Redo stack.
    redo_stack: std.ArrayListUnmanaged(UndoEntry),

    /// Instance buffer (reused each frame).
    instances: []GlyphInstance,

    /// Allocator.
    allocator: std.mem.Allocator,

    /// JIT runner for in-process compile & execute.
    jit_runner: JitRunner,

    /// LLVM optimization level for JIT execution (0-3, default 1).
    jit_opt_level: u8,

    /// Opt-in fast trig lowering for SIN/COS/TAN/POLAR (default off).
    jit_fast_math_trig: bool,

    /// Lines with errors from the last compilation (0-based line indices).
    /// Used for gutter markers and line background highlighting.
    error_lines: std.ArrayListUnmanaged(ErrorLineInfo),

    /// Symbol index — extracted declarations for go-to-def, outline, autocomplete.
    symbol_index: SymbolIndex,

    /// Whether the symbol index needs rebuilding (set on edits, cleared after rebuild).
    symbols_dirty: bool,

    /// Overlay state for symbol outline popup (Ctrl+O).
    symbol_overlay: OverlayState,

    /// Overlay state for autocomplete popup (Ctrl+Space / dot-trigger).
    autocomplete_overlay: OverlayState,

    /// Whether the autocomplete overlay is in dot-completion mode
    /// (showing fields/methods for `identifier.` rather than global completions).
    dot_mode: bool,

    /// Whether the autocomplete overlay is in type-completion mode
    /// (showing available types after `AS `).
    type_mode: bool,

    /// Whether the autocomplete overlay is in sprite-subcommand mode
    /// (showing SPRITE subcommands after `SPRITE `).
    sprite_mode: bool,

    /// Whether the autocomplete overlay is in sound-subcommand mode
    /// (showing SOUND subcommands after `SOUND `).
    sound_mode: bool,

    /// Whether the autocomplete overlay is in music-subcommand mode
    /// (showing MUSIC subcommands after `MUSIC `).
    music_mode: bool,

    /// Whether the autocomplete overlay is in vs-subcommand mode
    /// (showing VS subcommands after `VS `).
    vs_mode: bool,

    /// Dot/type-completion items populated when dot_mode or type_mode is true.
    dot_completions: [symbols_mod.MAX_DOT_COMPLETIONS]symbols_mod.DotCompletion,

    /// Number of valid entries in `dot_completions`.
    dot_completion_count: u16,

    /// Terminal selection anchor (where the mouse-down occurred).
    term_sel_anchor: ?TermSelPos,

    /// Terminal selection end (where the mouse is currently / was released).
    term_sel_end: ?TermSelPos,

    /// Whether a terminal selection drag is in progress.
    term_selecting: bool,

    /// Collapsed fold regions (sorted by start_line, non-overlapping).
    fold_regions: std.ArrayListUnmanaged(FoldRegion),

    /// Smart assist ghost-text buffer (accumulated UTF-8 completion tokens).
    sa_ghost: std.ArrayListUnmanaged(u8),
    /// Debounce countdown (seconds). Negative = idle. Arms to 0.4 on each edit.
    sa_debounce: f64,
    /// True while a background inference request is in flight.
    sa_active: bool,
    /// Cursor offset at the end of the last rendered frame (detects movement).
    sa_last_cursor: usize,
    /// Smart assist runtime; null when disabled or model not loaded.
    smart_assist: ?*sa_mod.SmartAssist,

    pub fn init(allocator: std.mem.Allocator) !EditorState {
        const buf = try RopeBuffer.init(allocator);
        const instances = try allocator.alloc(GlyphInstance, MAX_INSTANCES);
        const initial_theme = theme_mod.getTheme(.fasterbasic);

        return EditorState{
            .buffer = buf,
            .cursor = 0,
            .desired_col = null,
            .selection_anchor = null,
            .scroll_line = 0,
            .scroll_col = 0,
            .theme_id = .fasterbasic,
            .focus = .editor,
            .modified = false,
            .file_path = null,
            .time = 0,
            .cursor_visible = true,
            .cursor_blink_timer = 0,
            .window_focused = true,
            .viewport_width = 1280,
            .viewport_height = 720,
            .viewport_scale = 2.0,
            .atlas = std.mem.zeroes(GlyphAtlasInfo),
            .terminal_lines = TERMINAL_DEFAULT_LINES,
            .terminal_lines_before_run = TERMINAL_DEFAULT_LINES,
            .terminal_visible = false,
            .terminal_fullscreen = false,
            .terminal_lines_before_fullscreen = TERMINAL_DEFAULT_LINES,
            .terminal_scroll_offset = 0,
            .terminal_pinned_to_bottom = true,
            .cursor_is_resize = false,
            .splitter_dragging = false,
            .splitter_drag_start_y = 0,
            .splitter_drag_start_lines = TERMINAL_DEFAULT_LINES,
            .terminal = Terminal.init(allocator, 200, TERMINAL_DEFAULT_LINES, initial_theme.terminal_fg, initial_theme.terminal_bg),
            .find_state = .{},
            .rename_state = .{},
            .undo_stack = .{},
            .redo_stack = .{},
            .instances = instances,
            .allocator = allocator,
            .jit_runner = undefined,
            .jit_opt_level = 1,
            .jit_fast_math_trig = false,
            .error_lines = .{},
            .symbol_index = SymbolIndex.init(allocator),
            .symbols_dirty = true,
            .symbol_overlay = .{},
            .autocomplete_overlay = .{},
            .dot_mode = false,
            .type_mode = false,
            .sprite_mode = false,
            .sound_mode = false,
            .music_mode = false,
            .vs_mode = false,
            .dot_completions = undefined,
            .dot_completion_count = 0,
            .term_sel_anchor = null,
            .term_sel_end = null,
            .term_selecting = false,
            .fold_regions = .{},
            .sa_ghost = .{},
            .sa_debounce = -1,
            .sa_active = false,
            .sa_last_cursor = 0,
            .smart_assist = null,
        };
    }

    /// Second-phase init for fields that need a pointer to self.
    /// Must be called immediately after init(), before any use.
    pub fn initJitRunner(self: *EditorState) !void {
        self.jit_runner = try JitRunner.init(self.allocator, &self.terminal);
        // Register the terminal globally so the JIT runtime can call ed_terminal_cls()
        terminal_mod.setGlobalTerminal(&self.terminal);
    }

    /// Second-phase init: spin up the Smart Assist inference engine.
    /// Call after initJitRunner(). Silently no-ops when compiled without
    /// smart-assist support or when the model file cannot be loaded.
    pub fn initSmartAssist(self: *EditorState) void {
        if (!sa_mod.llama_enabled) return;
        const raw = sa_mod.default_model_path;
        // Ensure ggml Metal resources are discoverable without user env vars.
        self.primeMetalEnvPaths();
        // Allocate a null-terminated copy for the C API; intentionally leaked
        // for the lifetime of this SmartAssist instance (~app lifetime).
        const model_path_z = self.allocator.dupeZ(u8, raw) catch return;
        const cfg = sa_mod.SmartAssistConfig{
            .allocator = self.allocator,
            .model_path = model_path_z,
            .enabled = true,
        };
        self.smart_assist = sa_mod.SmartAssist.init(cfg) catch |e| blk: {
            std.log.warn("SmartAssist init failed: {}", .{e});
            break :blk null;
        };
    }

    fn primeMetalEnvPaths(self: *EditorState) void {
        // If the user already set GGML_METAL_PATH or GGML_METAL_PATH_RESOURCES,
        // leave them alone. Otherwise point them at the installed ggml-metal
        // payload alongside the executable (installed via build.zig).
        const exe_path = std.fs.selfExePathAlloc(self.allocator) catch return;
        defer self.allocator.free(exe_path);

        const exe_dir = std.fs.path.dirname(exe_path) orelse return;
        const metal_dir = std.fs.path.join(self.allocator, &.{ exe_dir, "ggml-metal" }) catch return;
        defer self.allocator.free(metal_dir);

        const metal_file = std.fs.path.join(self.allocator, &.{ metal_dir, "ggml-metal.metal" }) catch return;
        defer self.allocator.free(metal_file);

        const has_path = std.process.getEnvVarOwned(self.allocator, "GGML_METAL_PATH") catch null;
        defer if (has_path) |p| self.allocator.free(p);
        if (has_path == null) {
            std.os.setenvZ("GGML_METAL_PATH", metal_file) catch {};
        }

        const has_res = std.process.getEnvVarOwned(self.allocator, "GGML_METAL_PATH_RESOURCES") catch null;
        defer if (has_res) |p| self.allocator.free(p);
        if (has_res == null) {
            std.os.setenvZ("GGML_METAL_PATH_RESOURCES", metal_dir) catch {};
        }
    }

    pub fn deinit(self: *EditorState) void {
        // Shut down the retro graphics subsystem (release buffers, stop timers)
        ed_graphics_shutdown();

        self.jit_runner.deinit();
        self.symbol_index.deinit();
        self.error_lines.deinit(self.allocator);
        self.buffer.deinit();

        for (self.undo_stack.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.undo_stack.deinit(self.allocator);

        for (self.redo_stack.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.redo_stack.deinit(self.allocator);

        self.find_state.deinit(self.allocator);
        self.rename_state.deinit(self.allocator);
        self.fold_regions.deinit(self.allocator);

        if (self.smart_assist) |sa| sa.deinit();
        self.sa_ghost.deinit(self.allocator);

        self.terminal.deinit();

        self.allocator.free(self.instances);

        if (self.file_path) |p| {
            self.allocator.free(p);
        }
    }

    // ── Code Folding ─────────────────────────────────────────────────────

    /// Check if a buffer line is hidden (inside a collapsed fold region).
    pub fn isLineHidden(self: *const EditorState, line: usize) bool {
        for (self.fold_regions.items) |fr| {
            if (line > fr.start_line and line <= fr.end_line) return true;
        }
        return false;
    }

    /// Check if a line is the start of a collapsed fold region.
    pub fn isFoldStart(self: *const EditorState, line: usize) bool {
        for (self.fold_regions.items) |fr| {
            if (fr.start_line == line) return true;
        }
        return false;
    }

    /// Get the fold region starting at a given line, if any.
    pub fn getFoldAt(self: *const EditorState, line: usize) ?FoldRegion {
        for (self.fold_regions.items) |fr| {
            if (fr.start_line == line) return fr;
        }
        return null;
    }

    /// Map a screen row (relative to scroll) to a buffer line, skipping hidden lines.
    /// Returns null if screen_row extends past end of buffer.
    pub fn screenRowToBufferLine(self: *const EditorState, screen_row: usize) ?usize {
        var visible_count: usize = 0;
        var buf_line: usize = self.scroll_line;
        const total = self.buffer.lineCount();
        while (buf_line < total) : (buf_line += 1) {
            if (self.isLineHidden(buf_line)) continue;
            if (visible_count == screen_row) return buf_line;
            visible_count += 1;
        }
        return null;
    }

    /// Count total visible (non-hidden) lines in the buffer.
    pub fn totalVisibleLines(self: *const EditorState) usize {
        const total = self.buffer.lineCount();
        var count: usize = 0;
        for (0..total) |i| {
            if (!self.isLineHidden(i)) count += 1;
        }
        return count;
    }

    /// Find the end line for a foldable block starting at `start_line`.
    /// Scans forward for matching END keyword. Returns null if not foldable.
    pub fn findFoldEnd(self: *EditorState, start_line: usize) ?usize {
        const line_data = self.buffer.getLine(start_line) catch return null;
        defer self.allocator.free(line_data);

        const kw = foldableKeyword(line_data) orelse return null;
        const total = self.buffer.lineCount();

        // Search forward for matching end keyword, respecting nesting
        var depth: usize = 1;
        var i: usize = start_line + 1;
        while (i < total) : (i += 1) {
            const ld = self.buffer.getLine(i) catch continue;
            defer self.allocator.free(ld);
            if (lineMatchesOpen(ld, kw)) depth += 1;
            if (lineMatchesClose(ld, kw)) {
                depth -= 1;
                if (depth == 0) return i;
            }
        }
        return null;
    }

    /// Toggle fold at the cursor's current line. If the line starts a foldable
    /// block, collapse or expand it.
    pub fn toggleFoldAtCursor(self: *EditorState) void {
        const lc = self.cursorLineCol();
        self.toggleFoldAtLine(lc.line);
    }

    /// Toggle fold at a specific line.
    pub fn toggleFoldAtLine(self: *EditorState, line: usize) void {
        // Check if already folded — remove it
        for (self.fold_regions.items, 0..) |fr, idx| {
            if (fr.start_line == line) {
                _ = self.fold_regions.orderedRemove(idx);
                return;
            }
        }
        // Not folded — try to create a fold
        if (self.findFoldEnd(line)) |end_line| {
            // Insert in sorted order
            var insert_idx: usize = self.fold_regions.items.len;
            for (self.fold_regions.items, 0..) |fr, idx| {
                if (fr.start_line > line) {
                    insert_idx = idx;
                    break;
                }
            }
            self.fold_regions.insert(self.allocator, insert_idx, FoldRegion{
                .start_line = line,
                .end_line = end_line,
            }) catch {};
        }
    }

    /// Fold all foldable regions in the buffer.
    pub fn foldAll(self: *EditorState) void {
        self.fold_regions.clearRetainingCapacity();
        const total = self.buffer.lineCount();
        var i: usize = 0;
        while (i < total) : (i += 1) {
            if (self.findFoldEnd(i)) |end_line| {
                self.fold_regions.append(self.allocator, FoldRegion{
                    .start_line = i,
                    .end_line = end_line,
                }) catch {};
                i = end_line; // skip to end of this block
            }
        }
    }

    /// Unfold all regions.
    pub fn unfoldAll(self: *EditorState) void {
        self.fold_regions.clearRetainingCapacity();
    }

    /// Ensure the cursor is not hidden inside a fold. If it is, unfold
    /// the containing region.
    pub fn ensureCursorNotFolded(self: *EditorState) void {
        const lc = self.cursorLineCol();
        var idx: usize = 0;
        while (idx < self.fold_regions.items.len) {
            const fr = self.fold_regions.items[idx];
            if (lc.line > fr.start_line and lc.line <= fr.end_line) {
                _ = self.fold_regions.orderedRemove(idx);
                // Don't increment — check same index again
            } else {
                idx += 1;
            }
        }
    }

    /// Adjust scroll_line to account for folded regions when scrolling.
    /// Given a target scroll line, find the nearest visible (non-hidden) line.
    pub fn adjustScrollForFolds(self: *EditorState) void {
        // If current scroll_line is hidden, move to next visible line
        while (self.scroll_line < self.buffer.lineCount() and self.isLineHidden(self.scroll_line)) {
            self.scroll_line += 1;
        }
    }

    // ── Viewport Calculations ───────────────────────────────────────────

    /// Number of visible editor columns.
    pub fn visibleCols(self: *const EditorState) usize {
        if (self.atlas.cell_width <= 0) return 80;
        const gutter_px = @as(f32, @floatFromInt(GUTTER_CHARS)) * self.atlas.cell_width;
        const available_w = self.viewport_width - gutter_px - SCROLLBAR_WIDTH;
        if (available_w <= 0) return 10;
        return @intFromFloat(@floor(available_w / self.atlas.cell_width));
    }

    /// Number of visible editor lines (excluding terminal, status bar, and find bar).
    pub fn visibleLines(self: *const EditorState) usize {
        if (self.atlas.cell_height <= 0) return 25;
        const terminal_px = if (self.terminal_visible)
            @as(f32, @floatFromInt(self.terminal_lines + 1)) * self.atlas.cell_height
        else
            @as(f32, 0);
        const status_px = @as(f32, @floatFromInt(STATUS_BAR_LINES)) * self.atlas.cell_height;
        var chrome_lines: f32 = 0;
        if (self.find_state.visible) chrome_lines += self.atlas.cell_height;
        if (self.find_state.replace_visible) chrome_lines += self.atlas.cell_height;
        const available_h = self.viewport_height - terminal_px - status_px - chrome_lines;
        if (available_h <= 0) return 5;
        return @intFromFloat(@floor(available_h / self.atlas.cell_height));
    }

    /// Compute the Y position (in pixels) of the top of the divider line between
    /// the editor and terminal panes.  Returns `null` when the terminal is hidden.
    pub fn dividerY(self: *const EditorState) ?f32 {
        if (!self.terminal_visible) return null;
        if (self.atlas.cell_height <= 0) return null;
        var chrome_h: f32 = @as(f32, @floatFromInt(STATUS_BAR_LINES)) * self.atlas.cell_height;
        if (self.find_state.visible) chrome_h += self.atlas.cell_height;
        if (self.find_state.replace_visible) chrome_h += self.atlas.cell_height;
        // The terminal grid occupies `terminal_lines` rows; the divider sits one
        // cell_height above that.
        return self.viewport_height - chrome_h -
            @as(f32, @floatFromInt(self.terminal_lines + 1)) * self.atlas.cell_height;
    }

    /// Maximum number of terminal lines that still leaves at least 3 editor lines.
    pub fn maxTerminalLines(self: *const EditorState) u32 {
        if (self.atlas.cell_height <= 0) return TERMINAL_DEFAULT_LINES;
        var chrome_h: f32 = @as(f32, @floatFromInt(STATUS_BAR_LINES)) * self.atlas.cell_height;
        if (self.find_state.visible) chrome_h += self.atlas.cell_height;
        if (self.find_state.replace_visible) chrome_h += self.atlas.cell_height;
        const available = self.viewport_height - chrome_h;
        if (available <= 0) return TERMINAL_MIN_LINES;
        const total_lines = @as(u32, @intFromFloat(@floor(available / self.atlas.cell_height)));
        // Reserve at least 3 lines for the editor + 1 for the divider.
        if (total_lines <= 4) return TERMINAL_MIN_LINES;
        return total_lines - 4;
    }

    /// Get the current theme.
    pub fn currentTheme(self: *const EditorState) *const Theme {
        return theme_mod.getTheme(self.theme_id);
    }

    // ── Cursor / Line Info ──────────────────────────────────────────────

    /// Get line and column for the current cursor position.
    pub fn cursorLineCol(self: *const EditorState) struct { line: usize, col: usize } {
        const result = self.buffer.offsetToLineCol(self.cursor);
        return .{ .line = result.line, .col = result.col };
    }

    /// Ensure the cursor is visible by adjusting scroll position.
    pub fn ensureCursorVisible(self: *EditorState) void {
        // If cursor is inside a fold, expand it first
        self.ensureCursorNotFolded();

        const pos = self.cursorLineCol();
        const vis_lines = self.visibleLines();
        const vis_cols = self.visibleCols();

        // Vertical scroll
        if (pos.line < self.scroll_line) {
            self.scroll_line = pos.line;
        }
        if (vis_lines > 0 and pos.line >= self.scroll_line + vis_lines) {
            self.scroll_line = pos.line - vis_lines + 1;
        }

        // Make sure scroll_line is not in a folded region
        self.adjustScrollForFolds();

        // Horizontal scroll
        if (pos.col < self.scroll_col) {
            self.scroll_col = pos.col;
        }
        if (vis_cols > 0 and pos.col >= self.scroll_col + vis_cols) {
            self.scroll_col = pos.col - vis_cols + 1;
        }
    }

    /// Move cursor to a specific line and column, clamping to valid range.
    pub fn setCursorLineCol(self: *EditorState, line: usize, col: usize) void {
        const clamped_line = @min(line, if (self.buffer.lineCount() > 0) self.buffer.lineCount() - 1 else 0);
        self.cursor = self.buffer.lineColToOffset(clamped_line, col);
        self.ensureCursorVisible();
    }

    // ── Selection ───────────────────────────────────────────────────────

    /// Get the ordered selection range (start, end). Returns null if no selection.
    pub fn selectionRange(self: *const EditorState) ?struct { start: usize, end: usize } {
        const anchor = self.selection_anchor orelse return null;
        if (anchor == self.cursor) return null;
        return if (anchor < self.cursor)
            .{ .start = anchor, .end = self.cursor }
        else
            .{ .start = self.cursor, .end = anchor };
    }

    /// Delete the selected text and return it. Clears the selection.
    pub fn deleteSelection(self: *EditorState) !?[]u32 {
        const range = self.selectionRange() orelse return null;
        const deleted = try self.buffer.slice(range.start, range.end);
        try self.buffer.delete(range.start, range.end - range.start);
        self.cursor = range.start;
        self.selection_anchor = null;
        self.modified = true;
        return deleted;
    }

    // ── Undo / Redo ─────────────────────────────────────────────────────

    pub fn pushUndo(self: *EditorState, pos: usize, deleted: []const u32, inserted: []const u32) !void {
        // Clear redo stack on new edit
        for (self.redo_stack.items) |*e| {
            e.deinit(self.allocator);
        }
        self.redo_stack.clearRetainingCapacity();

        const del_copy: []u32 = if (deleted.len > 0)
            try self.allocator.dupe(u32, deleted)
        else
            @constCast(&[_]u32{});

        const ins_copy: []u32 = if (inserted.len > 0)
            try self.allocator.dupe(u32, inserted)
        else
            @constCast(&[_]u32{});

        try self.undo_stack.append(self.allocator, .{
            .pos = pos,
            .deleted = del_copy,
            .inserted = ins_copy,
            .cursor_before = self.cursor,
            .timestamp = self.time,
        });
    }

    pub fn undo(self: *EditorState) !void {
        if (self.undo_stack.items.len == 0) return;
        const entry = self.undo_stack.pop() orelse return;

        // Reverse the operation
        if (entry.inserted.len > 0) {
            try self.buffer.delete(entry.pos, entry.inserted.len);
        }
        if (entry.deleted.len > 0) {
            try self.buffer.insert(entry.pos, entry.deleted);
        }

        self.cursor = entry.cursor_before;
        self.ensureCursorVisible();
        self.modified = true;

        // Move to redo stack (swap deleted/inserted)
        const redo_entry = UndoEntry{
            .pos = entry.pos,
            .deleted = entry.inserted,
            .inserted = entry.deleted,
            .cursor_before = self.cursor,
            .timestamp = entry.timestamp,
        };
        try self.redo_stack.append(self.allocator, redo_entry);
        // Don't free entry fields — they are now owned by redo_entry
    }

    pub fn redo(self: *EditorState) !void {
        if (self.redo_stack.items.len == 0) return;
        const entry = self.redo_stack.pop() orelse return;

        if (entry.inserted.len > 0) {
            try self.buffer.delete(entry.pos, entry.inserted.len);
        }
        if (entry.deleted.len > 0) {
            try self.buffer.insert(entry.pos, entry.deleted);
        }

        self.cursor = entry.pos + entry.deleted.len;
        self.ensureCursorVisible();
        self.modified = true;

        const undo_entry = UndoEntry{
            .pos = entry.pos,
            .deleted = entry.inserted,
            .inserted = entry.deleted,
            .cursor_before = entry.cursor_before,
            .timestamp = entry.timestamp,
        };
        try self.undo_stack.append(self.allocator, undo_entry);
    }

    // ── Symbol Index ────────────────────────────────────────────────

    /// Rebuild the symbol index from the current buffer contents.
    /// Single-pass scan — iterates every line once, feeding each to both
    /// the symbol scanner and the Unicode string checker so we only
    /// allocate/free each line slice once.
    pub fn rebuildSymbols(self: *EditorState) void {
        // Prepare symbol index for a fresh scan.
        self.symbol_index.clear();

        // Remove stale editor-generated warnings (keyword + unicode)
        // while keeping any compiler errors/warnings intact.
        self.removeEditorWarnings();

        var current_class: [symbols_mod.MAX_NAME]u8 = undefined;
        var current_class_len: u8 = 0;
        var scope_kind: symbols_mod.ScopeKind = .none;

        const total = self.buffer.lineCount();
        var line_idx: usize = 0;
        while (line_idx < total) : (line_idx += 1) {
            const line_data = self.buffer.getLine(line_idx) catch continue;
            defer self.allocator.free(line_data);

            // Symbol scan (same work rebuildFromBuffer did).
            self.symbol_index.scanLine(
                line_data,
                @intCast(line_idx),
                &current_class,
                &current_class_len,
                &scope_kind,
            );

            // Unicode check — inline, no second allocation.
            if (lineHasNonAsciiInString(line_data)) |col| {
                var eli: ErrorLineInfo = .{
                    .line = line_idx,
                    .col = col,
                    .is_warning = true,
                    .message_buf = undefined,
                    .message_len = 0,
                };
                const msg = std.fmt.bufPrint(
                    &eli.message_buf,
                    "{s}: character U+{X:0>4} will render as '?' in DRAWTEXT",
                    .{ unicode_warning_prefix, @as(u32, line_data[col]) },
                ) catch unicode_warning_prefix;
                eli.message_len = @intCast(msg.len);
                self.error_lines.append(self.allocator, eli) catch {};
            }
        }

        self.symbol_index.buildSortedIndices();
        self.symbols_dirty = false;

        // Transfer keyword-shadow warnings from the symbol index.
        self.populateKeywordWarnings();
    }

    // ── Editor-generated warning helpers ─────────────────────────────

    /// Prefix used for Unicode warnings so they can be identified and
    /// removed independently of compiler errors and keyword warnings.
    const unicode_warning_prefix = "Non-ASCII in string";

    /// Remove all editor-generated warnings (keyword-shadow and Unicode)
    /// while keeping compiler errors/warnings intact.
    fn removeEditorWarnings(self: *EditorState) void {
        var i: usize = 0;
        while (i < self.error_lines.items.len) {
            const eli = self.error_lines.items[i];
            if (eli.is_warning and ((eli.message_len >= 10 and
                std.mem.startsWith(u8, eli.message(), "Variable '")) or
                (eli.message_len >= unicode_warning_prefix.len and
                    std.mem.startsWith(u8, eli.message(), unicode_warning_prefix))))
            {
                _ = self.error_lines.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Transfer keyword-shadow warnings from the symbol index into
    /// `error_lines`.  Called after the symbol index has been rebuilt.
    fn populateKeywordWarnings(self: *EditorState) void {
        for (self.symbol_index.warnings.items) |*w| {
            var eli: ErrorLineInfo = .{
                .line = w.line,
                .col = w.col,
                .is_warning = true,
                .message_buf = undefined,
                .message_len = 0,
            };
            const msg = w.formatMessage(&eli.message_buf);
            eli.message_len = @intCast(msg.len);
            self.error_lines.append(self.allocator, eli) catch {};
        }
    }

    /// Check whether the word at `word_start` on `line` is in "keyword
    /// position" — i.e. the first significant token on the line (after
    /// optional leading whitespace and an optional line number).
    ///
    /// A keyword-shadowing identifier like `Tail` in `TYPE Tail` or
    /// `bongo.tail.wagSpeed` is NOT in keyword position, so rename is
    /// allowed.  Only the genuine statement keyword (`TYPE`, `PRINT`,
    /// `IF`, etc.) occupies position 0 and should be blocked.
    fn isKeywordPosition(line: []const u32, word_start: usize) bool {
        // Walk backwards from word_start — everything before it must be
        // whitespace or digits (a BASIC line number).  If we hit any
        // identifier char, dot, or other token, the word is NOT the
        // first token on the line → it's an identifier usage.
        var pos: usize = word_start;
        // Skip whitespace immediately before the word
        while (pos > 0 and (line[pos - 1] == ' ' or line[pos - 1] == '\t')) {
            pos -= 1;
        }
        // Skip an optional leading line number (digits only)
        while (pos > 0 and line[pos - 1] >= '0' and line[pos - 1] <= '9') {
            pos -= 1;
        }
        // Skip any remaining leading whitespace
        while (pos > 0 and (line[pos - 1] == ' ' or line[pos - 1] == '\t')) {
            pos -= 1;
        }
        // If we've reached the start of the line, the word IS the first token.
        return pos == 0;
    }

    /// Walk a line's codepoints; return the column of the first non-ASCII
    /// codepoint found inside a string literal, or null if clean.
    fn lineHasNonAsciiInString(line: []const u32) ?usize {
        var in_string = false;
        for (line, 0..) |cp, col| {
            if (cp == '"') {
                in_string = !in_string;
                continue;
            }
            if (cp == '\'' and !in_string) {
                // Rest of line is a comment — stop scanning.
                break;
            }
            if (in_string and cp > 0x7F) {
                return col;
            }
        }
        return null;
    }

    /// Ensure the symbol index is up-to-date (lazy rebuild on demand).
    pub fn ensureSymbols(self: *EditorState) void {
        if (self.symbols_dirty) {
            self.rebuildSymbols();
        }
    }

    /// Go to the definition of the identifier under the cursor (F12).
    /// If text is selected, uses the selection as the lookup key.
    /// Otherwise falls back to the word under the cursor.
    pub fn goToDefinition(self: *EditorState) void {
        self.ensureSymbols();

        // ── Try selected text first ─────────────────────────────────
        if (self.selectionRange()) |range| {
            const sel_text = self.buffer.slice(range.start, range.end) catch null;
            if (sel_text) |st| {
                defer self.allocator.free(st);
                // Only use selection if it looks like a single identifier (no spaces/newlines)
                if (st.len > 0 and st.len <= symbols_mod.MAX_NAME) {
                    var valid = true;
                    for (st) |cp| {
                        if (cp == ' ' or cp == '\n' or cp == '\r' or cp == '\t') {
                            valid = false;
                            break;
                        }
                    }
                    if (valid) {
                        if (self.symbol_index.lookup(st)) |entry| {
                            self.setCursorLineCol(entry.line, entry.col);
                            self.selection_anchor = null;
                            self.ensureCursorVisible();
                            return;
                        }
                    }
                }
            }
        }

        // ── Fall back to word under cursor ──────────────────────────
        const lc = self.cursorLineCol();
        const line_data = self.buffer.getLine(lc.line) catch return;
        defer self.allocator.free(line_data);

        const word_info = symbols_mod.wordAtCursor(line_data, lc.col);
        if (word_info.word.len == 0) return;

        const entry = self.symbol_index.lookup(word_info.word) orelse {
            // Not a user-defined symbol — check if it's a language keyword
            if (keyword_help.lookupCodepoints(word_info.word)) |kw| {
                self.terminal_visible = true;
                self.updateTerminalSize();
                var help_buf: [4096]u8 = undefined;
                const help_text = keyword_help.formatHelp(kw, &help_buf);
                self.terminalPrint(help_text) catch {};
                return;
            }
            self.terminal_visible = true;
            self.updateTerminalSize();
            self.terminalPrint("  No definition found\r\n") catch {};
            return;
        };

        self.setCursorLineCol(entry.line, entry.col);
        self.selection_anchor = null;
        self.ensureCursorVisible();
    }

    /// Check whether Go-to-Definition would succeed for the current cursor/selection.
    /// Returns true if a symbol can be resolved.
    pub fn canGoToDefinition(self: *EditorState) bool {
        self.ensureSymbols();

        // Check selected text first
        if (self.selectionRange()) |range| {
            const sel_text = self.buffer.slice(range.start, range.end) catch null;
            if (sel_text) |st| {
                defer self.allocator.free(st);
                if (st.len > 0 and st.len <= symbols_mod.MAX_NAME) {
                    var valid = true;
                    for (st) |cp| {
                        if (cp == ' ' or cp == '\n' or cp == '\r' or cp == '\t') {
                            valid = false;
                            break;
                        }
                    }
                    if (valid) {
                        if (self.symbol_index.lookup(st) != null) return true;
                        if (keyword_help.lookupCodepoints(st) != null) return true;
                    }
                }
            }
        }

        // Fall back to word under cursor
        const lc = self.cursorLineCol();
        const line_data = self.buffer.getLine(lc.line) catch return false;
        defer self.allocator.free(line_data);
        const word_info = symbols_mod.wordAtCursor(line_data, lc.col);
        if (word_info.word.len == 0) return false;
        if (self.symbol_index.lookup(word_info.word) != null) return true;
        // Also match language keywords (for showing help)
        return keyword_help.lookupCodepoints(word_info.word) != null;
    }

    /// Get the word under the cursor (or the selected text) as a null-terminated
    /// UTF-8 string written into the provided buffer.  Returns the length, or 0
    /// if no word is found.  Used by the context menu to show "Go to <name>".
    pub fn wordUnderCursorUtf8(self: *EditorState, out: []u8) usize {
        // Try selection first
        if (self.selectionRange()) |range| {
            const sel_text = self.buffer.slice(range.start, range.end) catch null;
            if (sel_text) |st| {
                defer self.allocator.free(st);
                if (st.len > 0 and st.len <= symbols_mod.MAX_NAME) {
                    var valid = true;
                    for (st) |cp| {
                        if (cp == ' ' or cp == '\n' or cp == '\r' or cp == '\t') {
                            valid = false;
                            break;
                        }
                    }
                    if (valid) {
                        var n: usize = 0;
                        for (st) |cp| {
                            if (n + 4 >= out.len) break;
                            if (cp < 0x80) {
                                out[n] = @intCast(cp);
                                n += 1;
                            }
                            // Skip non-ASCII for simplicity; identifiers are ASCII
                        }
                        return n;
                    }
                }
            }
        }

        const lc = self.cursorLineCol();
        const line_data = self.buffer.getLine(lc.line) catch return 0;
        defer self.allocator.free(line_data);
        const word_info = symbols_mod.wordAtCursor(line_data, lc.col);
        if (word_info.word.len == 0) return 0;

        var n: usize = 0;
        for (word_info.word) |cp| {
            if (n + 4 >= out.len) break;
            if (cp < 0x80) {
                out[n] = @intCast(cp);
                n += 1;
            }
        }
        return n;
    }

    /// Search for all occurrences of the word under the cursor (or selected text)
    /// using the Find panel.
    pub fn findReferencesAtCursor(self: *EditorState) void {
        var word_buf: [256]u8 = undefined;
        const wlen = self.wordUnderCursorUtf8(&word_buf);
        if (wlen == 0) return;

        // Populate the find query with the word
        const copy_len = @min(wlen, FIND_MAX_LEN);
        for (word_buf[0..copy_len], 0..) |ch, i| {
            self.find_state.query[i] = ch;
        }
        self.find_state.query_len = copy_len;

        // Open find bar and run search
        self.find_state.visible = true;
        self.find_state.replace_visible = false;
        self.findUpdateMatches() catch {};
        self.ensureCursorVisible();
    }

    // ── Intelligent Rename ──────────────────────────────────────────────

    /// Open in-place rename for the symbol under the cursor.
    /// The symbol is boxed in a highlight colour and the cursor is confined
    /// to it.  The user edits the name directly in the buffer; pressing
    /// Return propagates the new name to every other occurrence in the
    /// document.  Escape reverts.
    pub fn openRename(self: *EditorState) void {
        self.ensureSymbols();

        // Get word under cursor as codepoints
        const lc = self.cursorLineCol();
        const line_data = self.buffer.getLine(lc.line) catch return;
        defer self.allocator.free(line_data);

        const word_info = symbols_mod.wordAtCursor(line_data, lc.col);
        if (word_info.word.len == 0) return;

        // Don't rename pure language keywords — but allow rename on
        // user-defined symbols that shadow a keyword (e.g. TYPE Tail
        // shadows the TAIL keyword).  A word is a keyword only when
        // it's the first token on the line (the statement keyword).
        // In any other position (after TYPE, AS, a dot, etc.) it's
        // being used as an identifier and should be renameable.
        var kw_buf: [RENAME_MAX_LEN]u8 = undefined;
        const kw_len = @min(word_info.word.len, RENAME_MAX_LEN);
        for (word_info.word[0..kw_len], 0..) |cp, ki| {
            kw_buf[ki] = if (cp >= 'a' and cp <= 'z') @intCast(cp - 32) else if (cp < 128) @intCast(cp) else '?';
        }
        if (symbols_mod.isKeyword(kw_buf[0..kw_len]) and isKeywordPosition(line_data, word_info.start)) {
            return;
        }

        // Close other overlays
        if (self.find_state.visible) {
            self.find_state.visible = false;
            self.find_state.replace_visible = false;
        }
        if (self.symbol_overlay.visible) self.symbol_overlay.close();
        if (self.autocomplete_overlay.visible) {
            self.autocomplete_overlay.close();
            self.dot_mode = false;
            self.type_mode = false;
            self.sprite_mode = false;
            self.sound_mode = false;
            self.music_mode = false;
            self.vs_mode = false;
        }

        // Record the primary occurrence position
        const line_range = self.buffer.lineRange(lc.line) orelse return;
        const primary_offset = line_range.start + word_info.start;

        // Set up rename state
        self.rename_state.setOldName(word_info.word);
        self.rename_state.primary_offset = primary_offset;
        self.rename_state.primary_line = lc.line;
        self.rename_state.primary_col = word_info.start;
        self.rename_state.open();

        // Find all semantic occurrences (will exclude primary)
        self.findIdentifierOccurrences() catch {
            self.rename_state.close(self.allocator);
            return;
        };

        // Select the word so the user can type a replacement immediately
        self.selection_anchor = primary_offset;
        self.cursor = primary_offset + word_info.word.len;
        self.ensureCursorVisible();

        // Focus stays on .editor — rename_state.visible gates the behaviour
    }

    /// Scan the entire buffer for whole-word, case-insensitive occurrences
    /// of the rename target identifier, skipping occurrences inside string
    /// literals and comments.
    pub fn findIdentifierOccurrences(self: *EditorState) !void {
        self.rename_state.matches.clearRetainingCapacity();

        const old_name = self.rename_state.oldNameSlice();
        if (old_name.len == 0) return;

        const buf_len = self.buffer.length();
        if (buf_len == 0) return;

        // Build uppercase version of the target name for comparison
        var upper_target: [RENAME_MAX_LEN]u32 = undefined;
        for (old_name, 0..) |cp, i| {
            upper_target[i] = toUpperAscii(cp);
        }
        const target_upper = upper_target[0..old_name.len];

        // Scan line by line so we can skip comments and strings
        const line_count = self.buffer.lineCount();
        var line_idx: usize = 0;
        var syntax_state = SyntaxState{};
        while (line_idx < line_count) : (line_idx += 1) {
            const line_data = self.buffer.getLine(line_idx) catch continue;
            defer self.allocator.free(line_data);

            const line_start_offset = self.buffer.lineColToOffset(line_idx, 0);

            // Classify each character for syntax (reuse the highlighting logic)
            const cats = highlightLine(self.allocator, line_data, self.file_path, &syntax_state) catch continue;
            defer self.allocator.free(cats);

            // Scan for identifier matches within this line
            var col: usize = 0;
            while (col + old_name.len <= line_data.len) {
                // Skip positions inside strings or comments
                if (cats[col] == .string or cats[col] == .comment) {
                    col += 1;
                    continue;
                }

                // Check word boundary: must not be preceded by an ident char
                if (col > 0 and isIdentChar(line_data[col - 1])) {
                    col += 1;
                    continue;
                }

                // Compare the candidate (case-insensitive)
                var matched = true;
                for (target_upper, 0..) |tch, ti| {
                    const bch = toUpperAscii(line_data[col + ti]);
                    if (tch != bch) {
                        matched = false;
                        break;
                    }
                }

                if (matched) {
                    // Check trailing word boundary: must not be followed by an ident char
                    const end_col = col + old_name.len;
                    if (end_col < line_data.len and isIdentChar(line_data[end_col])) {
                        col += 1;
                        continue;
                    }

                    // Also skip if the match is followed by a type suffix that
                    // would make it a different identifier (e.g. "x$" vs "x")
                    // — but only if the target itself doesn't end with one.
                    const target_has_suffix = old_name.len > 0 and
                        (old_name[old_name.len - 1] == '$' or
                            old_name[old_name.len - 1] == '%' or
                            old_name[old_name.len - 1] == '!' or
                            old_name[old_name.len - 1] == '#' or
                            old_name[old_name.len - 1] == '&');
                    if (!target_has_suffix and end_col < line_data.len) {
                        const next_ch = line_data[end_col];
                        if (next_ch == '$' or next_ch == '%' or next_ch == '!' or next_ch == '#' or next_ch == '&') {
                            col += 1;
                            continue;
                        }
                    }

                    // Record the buffer offset of this match (skip primary)
                    const match_offset = line_start_offset + col;
                    if (match_offset != self.rename_state.primary_offset) {
                        try self.rename_state.matches.append(self.allocator, match_offset);
                    }
                    col += old_name.len; // skip past this match
                } else {
                    col += 1;
                }
            }
        }
    }

    /// Apply the rename: read the new name from the buffer at primary_offset,
    /// then replace all other matched occurrences with it.
    /// Replacements are done in reverse buffer order to preserve earlier offsets.
    pub fn applyRename(self: *EditorState) void {
        const old_len = self.rename_state.old_name_len;

        // Read the new name from the buffer at primary_offset
        var new_buf: [RENAME_MAX_LEN]u32 = undefined;
        const new_len = self.rename_state.readCurrentWord(&self.buffer, &new_buf);
        const new_name = new_buf[0..new_len];

        if (new_len == 0) {
            // Empty — revert instead
            self.revertRename();
            return;
        }

        // If old and new names are identical (case-insensitive), just close
        const old_name = self.rename_state.oldNameSlice();
        if (old_name.len == new_len) {
            var same = true;
            for (old_name, new_name) |o, n| {
                if (toUpperAscii(o) != toUpperAscii(n)) {
                    same = false;
                    break;
                }
            }
            if (same) {
                self.selection_anchor = null;
                self.rename_state.close(self.allocator);
                return;
            }
        }

        // Don't rename to a keyword
        var kw_check: [RENAME_MAX_LEN]u8 = undefined;
        for (new_name, 0..) |cp, ki| {
            kw_check[ki] = if (cp >= 'a' and cp <= 'z') @intCast(cp - 32) else if (cp < 128) @intCast(cp) else '?';
        }
        if (symbols_mod.isKeyword(kw_check[0..new_len])) {
            self.terminal_visible = true;
            self.updateTerminalSize();
            self.terminalPrint("  Cannot rename to a language keyword.\r\n") catch {};
            self.revertRename();
            return;
        }

        // Validate: new name must be a valid identifier
        if (!isIdentStart(new_name[0])) {
            self.terminal_visible = true;
            self.updateTerminalSize();
            self.terminalPrint("  Invalid identifier name.\r\n") catch {};
            self.revertRename();
            return;
        }
        {
            const body_end = if (new_len > 1 and
                (new_name[new_len - 1] == '$' or
                    new_name[new_len - 1] == '%' or
                    new_name[new_len - 1] == '!' or
                    new_name[new_len - 1] == '#' or
                    new_name[new_len - 1] == '&'))
                new_len - 1
            else
                new_len;

            for (new_name[1..body_end]) |cp| {
                if (!isIdentChar(cp)) {
                    self.terminal_visible = true;
                    self.updateTerminalSize();
                    self.terminalPrint("  Invalid identifier name.\r\n") catch {};
                    self.revertRename();
                    return;
                }
            }
        }

        // Adjust stored match offsets: matches after the primary may have
        // shifted because the primary word length changed in the buffer.
        const primary_off = self.rename_state.primary_offset;
        const delta: isize = @as(isize, @intCast(new_len)) - @as(isize, @intCast(old_len));

        const match_count = self.rename_state.matches.items.len;

        // Replace OTHER occurrences in reverse order to preserve earlier offsets
        var i: usize = match_count;
        while (i > 0) {
            i -= 1;
            var match_pos = self.rename_state.matches.items[i];

            // Adjust for the primary edit if this match comes after it
            if (match_pos > primary_off) {
                if (delta >= 0) {
                    match_pos += @as(usize, @intCast(delta));
                } else {
                    const neg = @as(usize, @intCast(-delta));
                    if (match_pos >= neg) {
                        match_pos -= neg;
                    }
                }
            }

            const deleted = self.buffer.slice(match_pos, match_pos + old_len) catch continue;
            defer self.allocator.free(deleted);
            self.buffer.delete(match_pos, old_len) catch continue;

            if (new_len > 0) {
                self.buffer.insert(match_pos, new_name) catch continue;
            }

            self.pushUndo(match_pos, deleted, new_name) catch {};
        }

        self.modified = true;
        self.symbols_dirty = true;
        self.updateTitle();

        // Report the result
        self.terminal_visible = true;
        self.updateTerminalSize();
        {
            var old_ascii: [RENAME_MAX_LEN]u8 = undefined;
            for (self.rename_state.oldNameSlice(), 0..) |cp, j| {
                old_ascii[j] = if (cp < 128) @intCast(cp) else '?';
            }
            var new_ascii: [RENAME_MAX_LEN]u8 = undefined;
            for (new_name, 0..) |cp, j| {
                new_ascii[j] = if (cp < 128) @intCast(cp) else '?';
            }
            // +1 for the primary occurrence itself
            const total_count = match_count + 1;
            var msg_buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "  Renamed '{s}' -> '{s}' ({d} occurrence{s})\r\n", .{
                old_ascii[0..self.rename_state.old_name_len],
                new_ascii[0..new_len],
                total_count,
                if (total_count != 1) "s" else "",
            }) catch "  Rename complete.\r\n";
            self.terminalPrint(msg) catch {};
        }

        // Close rename mode
        self.selection_anchor = null;
        self.rename_state.close(self.allocator);
        self.ensureCursorVisible();
    }

    /// Revert the in-place rename: restore the old name at the primary
    /// position and close rename mode.
    pub fn revertRename(self: *EditorState) void {
        if (!self.rename_state.visible) return;

        const primary_off = self.rename_state.primary_offset;
        const old_name = self.rename_state.oldNameSlice();
        const cur_len = self.rename_state.currentWordLen(&self.buffer);

        // Delete whatever the user typed at the primary position
        if (cur_len > 0) {
            self.buffer.delete(primary_off, cur_len) catch {};
        }
        // Re-insert the original name
        if (old_name.len > 0) {
            self.buffer.insert(primary_off, old_name) catch {};
        }

        self.cursor = primary_off + old_name.len;
        self.selection_anchor = null;
        self.rename_state.close(self.allocator);
        self.ensureCursorVisible();
    }

    /// Open the symbol outline overlay (Ctrl+O).
    /// Populates the overlay with all symbols sorted by line order.
    pub fn openSymbolOutline(self: *EditorState) void {
        self.ensureSymbols();

        var ov = &self.symbol_overlay;
        ov.open();

        // Populate with all symbols in line order
        const n = @min(self.symbol_index.sorted_by_line.items.len, OVERLAY_MAX_ITEMS);
        for (0..n) |i| {
            ov.items[i] = self.symbol_index.sorted_by_line.items[i];
        }
        ov.item_count = @intCast(n);

        if (ov.item_count == 0) {
            ov.close();
            self.terminal_visible = true;
            self.updateTerminalSize();
            self.terminalPrint("  No symbols found\r\n") catch {};
            return;
        }

        self.focus = .symbol_overlay;
    }

    /// Filter the symbol outline overlay by the current filter text.
    pub fn filterSymbolOverlay(self: *EditorState) void {
        var ov = &self.symbol_overlay;
        const filter = ov.filterSlice();

        if (filter.len == 0) {
            // No filter — show all symbols in line order
            const n = @min(self.symbol_index.sorted_by_line.items.len, OVERLAY_MAX_ITEMS);
            for (0..n) |i| {
                ov.items[i] = self.symbol_index.sorted_by_line.items[i];
            }
            ov.item_count = @intCast(n);
        } else {
            // Fuzzy filter: match symbols whose name contains the filter as a subsequence
            var filter_upper: [OVERLAY_FILTER_MAX]u8 = undefined;
            const flen = @min(filter.len, OVERLAY_FILTER_MAX);
            for (filter[0..flen], 0..) |cp, i| {
                filter_upper[i] = if (cp >= 'a' and cp <= 'z') @intCast(cp - 32) else @intCast(cp & 0x7F);
            }
            const needle = filter_upper[0..flen];

            var count: u16 = 0;
            for (self.symbol_index.sorted_by_line.items) |entry_idx| {
                if (count >= OVERLAY_MAX_ITEMS) break;
                const entry = &self.symbol_index.entries.items[entry_idx];
                const name = entry.name_upper[0..entry.name_len];

                // Subsequence match
                var ni: usize = 0;
                for (name) |ch| {
                    if (ni < needle.len and ch == needle[ni]) {
                        ni += 1;
                    }
                }
                if (ni == needle.len) {
                    ov.items[count] = entry_idx;
                    count += 1;
                }
            }
            ov.item_count = count;
        }

        ov.selected = 0;
        ov.scroll = 0;
    }

    /// Open the autocomplete overlay (Ctrl+Space).
    /// Populates with keyword + symbol matches for the prefix at cursor.
    pub fn openAutocomplete(self: *EditorState) void {
        self.ensureSymbols();
        self.dot_mode = false;
        self.type_mode = false;
        self.sprite_mode = false;
        self.sound_mode = false;
        self.music_mode = false;
        self.vs_mode = false;

        const lc = self.cursorLineCol();
        const line_data = self.buffer.getLine(lc.line) catch return;
        defer self.allocator.free(line_data);

        const prefix = symbols_mod.prefixBeforeCursor(line_data, lc.col);
        if (prefix.len == 0) return;

        var ov = &self.autocomplete_overlay;
        ov.open();
        ov.trigger_cursor = self.cursor;
        ov.prefix_start_col = lc.col - prefix.len;

        // Copy prefix into filter
        const plen = @min(prefix.len, OVERLAY_FILTER_MAX);
        @memcpy(ov.filter[0..plen], prefix[0..plen]);
        ov.filter_len = @intCast(plen);

        self.filterAutocomplete();

        if (ov.item_count == 0) {
            ov.close();
            return;
        }

        // Calculate anchor position for the popup
        const atlas = self.atlas;
        if (atlas.cell_width > 0) {
            const gutter_px = @as(f32, @floatFromInt(GUTTER_CHARS)) * atlas.cell_width;
            ov.anchor_x = gutter_px + @as(f32, @floatFromInt(ov.prefix_start_col -| self.scroll_col)) * atlas.cell_width;
            ov.anchor_y = @as(f32, @floatFromInt(lc.line -| self.scroll_line + 1)) * atlas.cell_height;
        }

        self.focus = .autocomplete;
    }

    /// Open dot-triggered autocomplete after `identifier.` is typed.
    /// Looks up the identifier (or dotted chain) before the dot, resolves its type,
    /// and populates the autocomplete overlay with fields/methods.
    /// Supports nested UDTs: e.g. `hero.position.` resolves hero→Player, position→Vector2D,
    /// then offers Vector2D's fields.
    pub fn openDotAutocomplete(self: *EditorState) void {
        self.ensureSymbols();

        const lc = self.cursorLineCol();
        const line_data = self.buffer.getLine(lc.line) catch return;
        defer self.allocator.free(line_data);

        // The cursor is now AFTER the '.', so the identifier chain is before that.
        if (lc.col < 2) return; // need at least "x."
        const dot_col = lc.col - 1;
        if (dot_col == 0) return;

        // ── Extract the full dotted chain before the final dot ──
        // Scan backwards from dot_col-1 collecting ident chars and dots.
        // e.g. for `hero.position.` with cursor after last dot, we extract `hero.position`
        var chain_start: usize = dot_col;
        while (chain_start > 0) {
            const ch = line_data[chain_start - 1];
            if (ch == '.' or symbols_mod.isIdentChar(ch)) {
                chain_start -= 1;
            } else {
                break;
            }
        }
        if (chain_start >= dot_col) return; // nothing before the dot

        const chain_codepoints = line_data[chain_start..dot_col];

        // ── Split chain by '.' into segments and convert to uppercase ──
        const MAX_CHAIN_DEPTH = 16;
        var seg_bufs: [MAX_CHAIN_DEPTH][symbols_mod.MAX_NAME]u8 = undefined;
        var seg_lens: [MAX_CHAIN_DEPTH]usize = [_]usize{0} ** MAX_CHAIN_DEPTH;
        var seg_count: usize = 0;

        var si: usize = 0;
        for (chain_codepoints) |cp| {
            if (cp == '.') {
                // End current segment, start next
                if (si == 0) return; // empty segment (leading or double dot)
                seg_lens[seg_count] = si;
                seg_count += 1;
                if (seg_count >= MAX_CHAIN_DEPTH) return; // too deep
                si = 0;
            } else {
                if (si >= symbols_mod.MAX_NAME) return;
                seg_bufs[seg_count][si] = if (cp >= 'a' and cp <= 'z')
                    @intCast(cp - 32)
                else if (cp < 128)
                    @intCast(cp)
                else
                    '?';
                si += 1;
            }
        }
        // Finalize the last segment
        if (si == 0) return; // trailing dot with no ident before it (shouldn't happen)
        seg_lens[seg_count] = si;
        seg_count += 1;

        if (seg_count == 0) return;

        // Build slice-of-slices for the chain resolver
        var seg_slices: [MAX_CHAIN_DEPTH][]const u8 = undefined;
        for (0..seg_count) |i| {
            seg_slices[i] = seg_bufs[i][0..seg_lens[i]];
        }

        // Look up dot-completions using chain resolution (handles both single and nested)
        const n = self.symbol_index.dotCompletionsChain(
            seg_slices[0..seg_count],
            &self.dot_completions,
        );
        if (n == 0) return;

        self.dot_completion_count = @intCast(n);
        self.dot_mode = true;

        var ov = &self.autocomplete_overlay;
        ov.open();
        ov.trigger_cursor = self.cursor;
        ov.prefix_start_col = lc.col; // prefix starts after the dot
        ov.filter_len = 0; // no filter yet (nothing typed after dot)

        self.filterDotAutocomplete();

        if (ov.item_count == 0) {
            ov.close();
            self.dot_mode = false;
            return;
        }

        // Calculate anchor position for the popup
        const atlas = self.atlas;
        if (atlas.cell_width > 0) {
            const gutter_px = @as(f32, @floatFromInt(GUTTER_CHARS)) * atlas.cell_width;
            ov.anchor_x = gutter_px + @as(f32, @floatFromInt(lc.col -| self.scroll_col)) * atlas.cell_width;
            ov.anchor_y = @as(f32, @floatFromInt(lc.line -| self.scroll_line + 1)) * atlas.cell_height;
        }

        self.focus = .autocomplete;
    }

    /// Filter autocomplete items by the current prefix.
    /// Items are encoded as: 0..keyword_count = keyword index, keyword_count.. = symbol index.
    /// In dot_mode, delegates to filterDotAutocomplete instead.
    pub fn filterAutocomplete(self: *EditorState) void {
        if (self.dot_mode) {
            self.filterDotAutocomplete();
            return;
        }
        if (self.type_mode) {
            self.filterTypeAutocomplete();
            return;
        }
        if (self.sprite_mode or self.sound_mode or self.music_mode or self.vs_mode) {
            self.filterSpriteAutocomplete();
            return;
        }

        var ov = &self.autocomplete_overlay;
        const filter = ov.filterSlice();

        // Build uppercase filter
        var filter_upper: [OVERLAY_FILTER_MAX]u8 = undefined;
        const flen = @min(filter.len, OVERLAY_FILTER_MAX);
        for (filter[0..flen], 0..) |cp, i| {
            filter_upper[i] = if (cp >= 'a' and cp <= 'z') @intCast(cp - 32) else @intCast(cp & 0x7F);
        }
        const needle = filter_upper[0..flen];

        var count: u16 = 0;
        const kw_count: u32 = @intCast(symbols_mod.KEYWORDS.len);

        // Match keywords (encoded as index 0..kw_count-1)
        if (flen > 0) {
            for (symbols_mod.KEYWORDS, 0..) |kw, ki| {
                if (count >= OVERLAY_MAX_ITEMS) break;
                if (kw.len >= flen and std.mem.eql(u8, kw[0..flen], needle)) {
                    ov.items[count] = @as(u32, @intCast(ki));
                    count += 1;
                }
            }
        }

        // Match user symbols (encoded as kw_count + entry_index)
        if (flen > 0) {
            for (self.symbol_index.entries.items, 0..) |*entry, ei| {
                if (count >= OVERLAY_MAX_ITEMS) break;
                const name = entry.name_upper[0..entry.name_len];
                if (name.len >= flen and std.mem.eql(u8, name[0..flen], needle)) {
                    // Avoid duplicates with keywords
                    const encoded: u32 = kw_count + @as(u32, @intCast(ei));
                    ov.items[count] = encoded;
                    count += 1;
                }
            }
        }

        ov.item_count = count;
        ov.selected = 0;
        ov.scroll = 0;
    }

    /// Filter dot-autocomplete items by the typed prefix after the dot.
    /// Items are encoded as direct indices into `dot_completions`.
    fn filterDotAutocomplete(self: *EditorState) void {
        var ov = &self.autocomplete_overlay;
        const filter = ov.filterSlice();

        // Build uppercase filter
        var filter_upper: [OVERLAY_FILTER_MAX]u8 = undefined;
        const flen = @min(filter.len, OVERLAY_FILTER_MAX);
        for (filter[0..flen], 0..) |cp, i| {
            filter_upper[i] = if (cp >= 'a' and cp <= 'z') @intCast(cp - 32) else @intCast(cp & 0x7F);
        }
        const needle = filter_upper[0..flen];

        var count: u16 = 0;
        const dc_count = self.dot_completion_count;

        for (0..dc_count) |di| {
            if (count >= OVERLAY_MAX_ITEMS) break;
            const dc = &self.dot_completions[di];
            const name = dc.name_upper[0..dc.name_len];
            // If no filter, show all; otherwise prefix-match
            if (flen == 0 or (name.len >= flen and std.mem.eql(u8, name[0..flen], needle))) {
                ov.items[count] = @as(u32, @intCast(di));
                count += 1;
            }
        }

        ov.item_count = count;
        ov.selected = 0;
        ov.scroll = 0;
    }

    /// Open sprite-subcommand autocomplete after `SPRITE ` is typed.
    /// Shows all SPRITE subcommands (DEF, DATA, SHOW, FX PARAM, etc.).
    pub fn openSpriteAutocomplete(self: *EditorState) void {
        const lc = self.cursorLineCol();

        // Populate sprite subcommand completions
        const n = spriteSubcommandCompletions(&self.dot_completions);
        if (n == 0) return;

        self.dot_completion_count = @intCast(n);
        self.sprite_mode = true;
        self.dot_mode = false;
        self.type_mode = false;
        self.sound_mode = false;
        self.music_mode = false;
        self.vs_mode = false;

        var ov = &self.autocomplete_overlay;
        ov.open();
        ov.trigger_cursor = self.cursor;
        ov.prefix_start_col = lc.col; // prefix starts after the space
        ov.filter_len = 0; // nothing typed yet

        self.filterSpriteAutocomplete();

        if (ov.item_count == 0) {
            ov.close();
            self.sprite_mode = false;
            self.sound_mode = false;
            self.music_mode = false;
            self.vs_mode = false;
            return;
        }

        // Calculate anchor position for the popup
        const atlas = self.atlas;
        if (atlas.cell_width > 0) {
            const gutter_px = @as(f32, @floatFromInt(GUTTER_CHARS)) * atlas.cell_width;
            ov.anchor_x = gutter_px + @as(f32, @floatFromInt(lc.col -| self.scroll_col)) * atlas.cell_width;
            ov.anchor_y = @as(f32, @floatFromInt(lc.line -| self.scroll_line + 1)) * atlas.cell_height;
        }

        self.focus = .autocomplete;
    }

    /// Open sound-subcommand autocomplete after `SOUND ` is typed.
    pub fn openSoundAutocomplete(self: *EditorState) void {
        const n = soundSubcommandCompletions(&self.dot_completions);
        if (n == 0) return;

        self.dot_completion_count = @intCast(n);
        self.sound_mode = true;
        self.dot_mode = false;
        self.type_mode = false;
        self.sprite_mode = false;
        self.music_mode = false;
        self.vs_mode = false;

        var ov = &self.autocomplete_overlay;
        ov.open();
        ov.trigger_cursor = self.cursor;
        ov.filter_len = 0;

        self.filterSpriteAutocomplete();

        if (ov.item_count == 0) {
            ov.close();
            self.sound_mode = false;
            return;
        }

        self.focus = .autocomplete;
    }

    /// Open music-subcommand autocomplete after `MUSIC ` is typed.
    pub fn openMusicAutocomplete(self: *EditorState) void {
        const n = musicSubcommandCompletions(&self.dot_completions);
        if (n == 0) return;

        self.dot_completion_count = @intCast(n);
        self.music_mode = true;
        self.dot_mode = false;
        self.type_mode = false;
        self.sprite_mode = false;
        self.sound_mode = false;
        self.vs_mode = false;

        var ov = &self.autocomplete_overlay;
        ov.open();
        ov.trigger_cursor = self.cursor;
        ov.filter_len = 0;

        self.filterSpriteAutocomplete();

        if (ov.item_count == 0) {
            ov.close();
            self.music_mode = false;
            return;
        }

        self.focus = .autocomplete;
    }

    /// Open vs-subcommand autocomplete after `VS ` is typed.
    pub fn openVsAutocomplete(self: *EditorState) void {
        const n = vsSubcommandCompletions(&self.dot_completions);
        if (n == 0) return;

        self.dot_completion_count = @intCast(n);
        self.vs_mode = true;
        self.dot_mode = false;
        self.type_mode = false;
        self.sprite_mode = false;
        self.sound_mode = false;
        self.music_mode = false;

        var ov = &self.autocomplete_overlay;
        ov.open();
        ov.trigger_cursor = self.cursor;
        ov.filter_len = 0;

        self.filterSpriteAutocomplete();

        if (ov.item_count == 0) {
            ov.close();
            self.vs_mode = false;
            return;
        }

        self.focus = .autocomplete;
    }

    /// Filter sprite/sound/music/vs autocomplete items by the typed prefix.
    /// Items are encoded as direct indices into `dot_completions`.
    /// Allows spaces in the filter to support multi-word subcommands
    /// (e.g. "FX " matches "FX PARAM", "FX COLOUR", "FX OFF").
    fn filterSpriteAutocomplete(self: *EditorState) void {
        var ov = &self.autocomplete_overlay;
        const filter = ov.filterSlice();

        // Build uppercase filter (allow spaces through)
        var filter_upper: [OVERLAY_FILTER_MAX]u8 = undefined;
        const flen = @min(filter.len, OVERLAY_FILTER_MAX);
        for (filter[0..flen], 0..) |cp, i| {
            filter_upper[i] = if (cp >= 'a' and cp <= 'z') @intCast(cp - 32) else @intCast(cp & 0x7F);
        }
        const needle = filter_upper[0..flen];

        var count: u16 = 0;
        const dc_count = self.dot_completion_count;

        for (0..dc_count) |di| {
            if (count >= OVERLAY_MAX_ITEMS) break;
            const dc = &self.dot_completions[di];
            const name = dc.name_upper[0..dc.name_len];
            // If no filter, show all; otherwise prefix-match
            if (flen == 0 or (name.len >= flen and std.mem.eql(u8, name[0..flen], needle))) {
                ov.items[count] = @as(u32, @intCast(di));
                count += 1;
            }
        }

        ov.item_count = count;
        ov.selected = 0;
        ov.scroll = 0;
    }

    /// Populate SOUND subcommand completions for the autocomplete overlay.
    fn soundSubcommandCompletions(out: []symbols_mod.DotCompletion) usize {
        const commands = [_]struct { name: []const u8, args: []const u8 }{
            // Predefined SFX
            .{ .name = "BEEP", .args = "slot, freq, dur" },
            .{ .name = "ZAP", .args = "slot, freq, dur" },
            .{ .name = "EXPLODE", .args = "slot, size, dur" },
            .{ .name = "BIGEXPLODE", .args = "slot, size, dur" },
            .{ .name = "SMALLEXPLODE", .args = "slot, intensity, dur" },
            .{ .name = "DISTANTEXPLODE", .args = "slot, distance, dur" },
            .{ .name = "METALEXPLODE", .args = "slot, shrapnel, dur" },
            .{ .name = "BANG", .args = "slot, intensity, dur" },
            .{ .name = "COIN", .args = "slot, pitch, dur" },
            .{ .name = "JUMP", .args = "slot, power, dur" },
            .{ .name = "POWERUP", .args = "slot, intensity, dur" },
            .{ .name = "HURT", .args = "slot, severity, dur" },
            .{ .name = "SHOOT", .args = "slot, power, dur" },
            .{ .name = "CLICK", .args = "slot, sharpness, dur" },
            .{ .name = "BLIP", .args = "slot, pitch, dur" },
            .{ .name = "PICKUP", .args = "slot, brightness, dur" },
            .{ .name = "SWEEPUP", .args = "slot, startF, endF, dur" },
            .{ .name = "SWEEPDOWN", .args = "slot, startF, endF, dur" },
            .{ .name = "RANDOMBEEP", .args = "slot, seed, dur" },
            // Custom synthesis
            .{ .name = "TONE", .args = "slot, freq, dur, waveform" },
            .{ .name = "NOTE", .args = "slot, midi, dur, wf, a, d, s, r" },
            .{ .name = "NOISE", .args = "slot, noiseType, dur" },
            .{ .name = "FM", .args = "slot, carrier, mod, index, dur" },
            .{ .name = "FILTER TONE", .args = "slot, freq, dur, wf, ftype, cut, res" },
            .{ .name = "FILTER NOTE", .args = "slot, midi, dur, wf, a,d,s,r, ft, cut, res" },
            // Effects
            .{ .name = "REVERB", .args = "slot, freq, dur, wf, room, damp, wet" },
            .{ .name = "DELAY", .args = "slot, freq, dur, wf, time, fb, mix" },
            .{ .name = "DISTORT", .args = "slot, freq, dur, wf, drive, tone, lvl" },
            // Playback & management
            .{ .name = "PLAY", .args = "slot [, vol [, pan]]" },
            .{ .name = "FREE", .args = "slot" },
            .{ .name = "FREE ALL", .args = "" },
            .{ .name = "VOLUME", .args = "level" },
            .{ .name = "STOP", .args = "" },
        };

        var n: usize = 0;
        for (commands) |cmd| {
            if (n >= out.len) break;
            out[n] = .{ .kind = .method };
            const nlen = @min(cmd.name.len, symbols_mod.MAX_NAME);
            @memcpy(out[n].name[0..nlen], cmd.name[0..nlen]);
            @memcpy(out[n].name_upper[0..nlen], cmd.name[0..nlen]);
            out[n].name_len = @intCast(nlen);
            const elen = @min(cmd.args.len, symbols_mod.MAX_NAME);
            @memcpy(out[n].extra[0..elen], cmd.args[0..elen]);
            out[n].extra_len = @intCast(elen);
            n += 1;
        }
        return n;
    }

    /// Populate MUSIC subcommand completions for the autocomplete overlay.
    fn musicSubcommandCompletions(out: []symbols_mod.DotCompletion) usize {
        const commands = [_]struct { name: []const u8, args: []const u8 }{
            .{ .name = "PLAY", .args = "abc$ [, vol]  or  slot [, vol]" },
            .{ .name = "LOAD", .args = "slot, abc$" },
            .{ .name = "STOP", .args = "" },
            .{ .name = "PAUSE", .args = "" },
            .{ .name = "RESUME", .args = "" },
            .{ .name = "VOLUME", .args = "level" },
            .{ .name = "FREE", .args = "slot" },
            .{ .name = "FREE ALL", .args = "" },
            .{ .name = "RENDER", .args = "slot, abc$, sndSlot [, dur, sr]" },
            .{ .name = "RENDER WAV", .args = "abc$, filename$ [, dur, sr]" },
        };

        var n: usize = 0;
        for (commands) |cmd| {
            if (n >= out.len) break;
            out[n] = .{ .kind = .method };
            const nlen = @min(cmd.name.len, symbols_mod.MAX_NAME);
            @memcpy(out[n].name[0..nlen], cmd.name[0..nlen]);
            @memcpy(out[n].name_upper[0..nlen], cmd.name[0..nlen]);
            out[n].name_len = @intCast(nlen);
            const elen = @min(cmd.args.len, symbols_mod.MAX_NAME);
            @memcpy(out[n].extra[0..elen], cmd.args[0..elen]);
            out[n].extra_len = @intCast(elen);
            n += 1;
        }
        return n;
    }

    /// Populate VS subcommand completions for the autocomplete overlay.
    fn vsSubcommandCompletions(out: []symbols_mod.DotCompletion) usize {
        const commands = [_]struct { name: []const u8, args: []const u8 }{
            // Oscillator
            .{ .name = "WAVEFORM", .args = "voice, waveformType" },
            .{ .name = "FREQUENCY", .args = "voice, hz" },
            .{ .name = "NOTE", .args = "voice, midiNote" },
            .{ .name = "NOTENAME", .args = "voice, name$" },
            .{ .name = "PULSE", .args = "voice, width" },
            // Envelope & Gate
            .{ .name = "ENVELOPE", .args = "voice, a, d, s, r" },
            .{ .name = "GATE", .args = "voice, ON/OFF" },
            // Volume & Pan
            .{ .name = "VOLUME", .args = "voice, level" },
            .{ .name = "PAN", .args = "voice, position" },
            .{ .name = "MASTER", .args = "level" },
            // Filter
            .{ .name = "FILTER TYPE", .args = "filterType" },
            .{ .name = "FILTER CUTOFF", .args = "hz" },
            .{ .name = "FILTER RESONANCE", .args = "q" },
            .{ .name = "FILTER ON", .args = "" },
            .{ .name = "FILTER OFF", .args = "" },
            .{ .name = "FILTER ROUTE", .args = "voice, ON/OFF" },
            // Modulation
            .{ .name = "RING", .args = "voice, sourceVoice" },
            .{ .name = "SYNC", .args = "voice, sourceVoice" },
            .{ .name = "PORTAMENTO", .args = "voice, seconds" },
            .{ .name = "DETUNE", .args = "voice, cents" },
            // Per-Voice Delay
            .{ .name = "DELAY", .args = "voice, ON/OFF" },
            .{ .name = "DELAY TIME", .args = "voice, seconds" },
            .{ .name = "DELAY FEEDBACK", .args = "voice, amount" },
            .{ .name = "DELAY MIX", .args = "voice, wetDry" },
            // LFO
            .{ .name = "LFO WAVEFORM", .args = "lfo, waveform" },
            .{ .name = "LFO RATE", .args = "lfo, hz" },
            .{ .name = "LFO RESET", .args = "lfo" },
            .{ .name = "LFO PITCH", .args = "voice, lfo, depth" },
            .{ .name = "LFO VOLUME", .args = "voice, lfo, depth" },
            .{ .name = "LFO FILTER", .args = "voice, lfo, depth" },
            .{ .name = "LFO PULSE", .args = "voice, lfo, depth" },
            // Physical Modeling
            .{ .name = "PHYSICAL", .args = "voice, model" },
            .{ .name = "PHYSICAL DAMPING", .args = "voice, val" },
            .{ .name = "PHYSICAL BRIGHTNESS", .args = "voice, val" },
            .{ .name = "PHYSICAL EXCITATION", .args = "voice, val" },
            .{ .name = "PHYSICAL RESONANCE", .args = "voice, val" },
            .{ .name = "PHYSICAL TENSION", .args = "voice, val" },
            .{ .name = "PHYSICAL PRESSURE", .args = "voice, val" },
            .{ .name = "PHYSICAL TRIGGER", .args = "voice" },
            // Global Control
            .{ .name = "RESET", .args = "" },
            .{ .name = "STOP", .args = "" },
            // Recording
            .{ .name = "RECORD START", .args = "" },
            .{ .name = "RECORD TEMPO", .args = "bpm" },
            .{ .name = "RECORD WAIT", .args = "beats" },
            .{ .name = "RECORD SAVE", .args = "slot, volume" },
            .{ .name = "RECORD PLAY", .args = "" },
            .{ .name = "RECORD WAV", .args = "filename$" },
        };

        var n: usize = 0;
        for (commands) |cmd| {
            if (n >= out.len) break;
            out[n] = .{ .kind = .method };
            const nlen = @min(cmd.name.len, symbols_mod.MAX_NAME);
            @memcpy(out[n].name[0..nlen], cmd.name[0..nlen]);
            @memcpy(out[n].name_upper[0..nlen], cmd.name[0..nlen]);
            out[n].name_len = @intCast(nlen);
            const elen = @min(cmd.args.len, symbols_mod.MAX_NAME);
            @memcpy(out[n].extra[0..elen], cmd.args[0..elen]);
            out[n].extra_len = @intCast(elen);
            n += 1;
        }
        return n;
    }

    /// Populate sprite subcommand completions for the autocomplete overlay.
    /// Returns the number of completions written.
    fn spriteSubcommandCompletions(out: []symbols_mod.DotCompletion) usize {
        const commands = [_]struct { name: []const u8, args: []const u8 }{
            // Definition
            .{ .name = "DEF", .args = "id, w, h" },
            .{ .name = "DATA", .args = "id, x, y, colour" },
            .{ .name = "PALETTE", .args = "id, idx, r, g, b" },
            .{ .name = "STD PAL", .args = "id, pal_id" },
            .{ .name = "FRAMES", .args = "id, fw, fh, count" },
            .{ .name = "LOAD", .args = "id, \"file\"" },
            // Position & movement
            .{ .name = "POS", .args = "inst, x, y" },
            .{ .name = "MOVE", .args = "inst, dx, dy" },
            // Transforms
            .{ .name = "ROT", .args = "inst, angle" },
            .{ .name = "SCALE", .args = "inst, sx, sy" },
            .{ .name = "ANCHOR", .args = "inst, ax, ay" },
            .{ .name = "FLIP", .args = "inst, h, v" },
            // Visibility & appearance
            .{ .name = "SHOW", .args = "inst" },
            .{ .name = "HIDE", .args = "inst" },
            .{ .name = "ALPHA", .args = "inst, a" },
            .{ .name = "PRIORITY", .args = "inst, pri" },
            .{ .name = "BLEND", .args = "inst, mode" },
            // Animation
            .{ .name = "FRAME", .args = "inst, n" },
            .{ .name = "ANIMATE", .args = "inst, speed" },
            // Effects — shortcuts
            .{ .name = "GLOW", .args = "inst, rad, int, r, g, b" },
            .{ .name = "OUTLINE", .args = "inst, thick, r, g, b" },
            .{ .name = "SHADOW", .args = "inst, ox, oy, r, g, b, a" },
            .{ .name = "TINT", .args = "inst, factor, r, g, b" },
            .{ .name = "FLASH", .args = "inst, speed, r, g, b" },
            // Effects — FX subgroup
            .{ .name = "FX", .args = "inst, type" },
            .{ .name = "FX PARAM", .args = "inst, p1, p2" },
            .{ .name = "FX COLOUR", .args = "inst, r, g, b, a" },
            .{ .name = "FX OFF", .args = "inst" },
            // Palette override
            .{ .name = "PAL OVERRIDE", .args = "inst, def_id" },
            .{ .name = "PAL RESET", .args = "inst" },
            // Collision
            .{ .name = "COLLIDE", .args = "inst, group" },
            // Lifecycle
            .{ .name = "REMOVE", .args = "inst" },
            .{ .name = "REMOVE ALL", .args = "" },
            .{ .name = "SYNC", .args = "" },
        };

        var n: usize = 0;
        for (commands) |cmd| {
            if (n >= out.len) break;
            out[n] = .{ .kind = .method }; // use method kind for the ▸ icon
            const nlen = @min(cmd.name.len, symbols_mod.MAX_NAME);
            @memcpy(out[n].name[0..nlen], cmd.name[0..nlen]);
            @memcpy(out[n].name_upper[0..nlen], cmd.name[0..nlen]);
            out[n].name_len = @intCast(nlen);
            const elen = @min(cmd.args.len, symbols_mod.MAX_NAME);
            @memcpy(out[n].extra[0..elen], cmd.args[0..elen]);
            out[n].extra_len = @intCast(elen);
            n += 1;
        }

        return n;
    }

    /// Open type-completion autocomplete after `AS ` is typed.
    /// Shows built-in types (INTEGER, STRING, etc.) and user-defined TYPE/CLASS names.
    pub fn openTypeAutocomplete(self: *EditorState) void {
        self.ensureSymbols();

        const lc = self.cursorLineCol();

        // Populate type completions from the symbol index
        const n = self.symbol_index.typeCompletions(&self.dot_completions);
        if (n == 0) return;

        self.dot_completion_count = @intCast(n);
        self.type_mode = true;
        self.dot_mode = false;

        var ov = &self.autocomplete_overlay;
        ov.open();
        ov.trigger_cursor = self.cursor;
        ov.prefix_start_col = lc.col; // prefix starts after the space
        ov.filter_len = 0; // nothing typed yet

        self.filterTypeAutocomplete();

        if (ov.item_count == 0) {
            ov.close();
            self.type_mode = false;
            return;
        }

        // Calculate anchor position for the popup
        const atlas = self.atlas;
        if (atlas.cell_width > 0) {
            const gutter_px = @as(f32, @floatFromInt(GUTTER_CHARS)) * atlas.cell_width;
            ov.anchor_x = gutter_px + @as(f32, @floatFromInt(lc.col -| self.scroll_col)) * atlas.cell_width;
            ov.anchor_y = @as(f32, @floatFromInt(lc.line -| self.scroll_line + 1)) * atlas.cell_height;
        }

        self.focus = .autocomplete;
    }

    /// Filter type-autocomplete items by the typed prefix after `AS `.
    /// Items are encoded as direct indices into `dot_completions`.
    fn filterTypeAutocomplete(self: *EditorState) void {
        var ov = &self.autocomplete_overlay;
        const filter = ov.filterSlice();

        // Build uppercase filter
        var filter_upper: [OVERLAY_FILTER_MAX]u8 = undefined;
        const flen = @min(filter.len, OVERLAY_FILTER_MAX);
        for (filter[0..flen], 0..) |cp, i| {
            filter_upper[i] = if (cp >= 'a' and cp <= 'z') @intCast(cp - 32) else @intCast(cp & 0x7F);
        }
        const needle = filter_upper[0..flen];

        var count: u16 = 0;
        const dc_count = self.dot_completion_count;

        for (0..dc_count) |di| {
            if (count >= OVERLAY_MAX_ITEMS) break;
            const dc = &self.dot_completions[di];
            const name = dc.name_upper[0..dc.name_len];
            // If no filter, show all; otherwise prefix-match
            if (flen == 0 or (name.len >= flen and std.mem.eql(u8, name[0..flen], needle))) {
                ov.items[count] = @as(u32, @intCast(di));
                count += 1;
            }
        }

        ov.item_count = count;
        ov.selected = 0;
        ov.scroll = 0;
    }

    /// Apply the currently selected autocomplete item: replace the prefix with the full word.
    pub fn applyAutocomplete(self: *EditorState) void {
        const ov = &self.autocomplete_overlay;
        const sel_idx = ov.selectedIndex() orelse return;

        // Get the completion text
        var completion_buf: [symbols_mod.MAX_NAME]u8 = undefined;
        var completion_len: usize = 0;

        if (self.dot_mode or self.type_mode or self.sprite_mode or self.sound_mode or self.music_mode or self.vs_mode) {
            // Dot-mode, type-mode, or sprite/sound/music/vs-mode: index directly into dot_completions
            if (sel_idx < self.dot_completion_count) {
                const dc = &self.dot_completions[sel_idx];
                completion_len = dc.name_len;
                @memcpy(completion_buf[0..completion_len], dc.name[0..completion_len]);
            }
        } else {
            const kw_count: u32 = @intCast(symbols_mod.KEYWORDS.len);

            if (sel_idx < kw_count) {
                // Keyword
                const kw = symbols_mod.KEYWORDS[sel_idx];
                completion_len = @min(kw.len, completion_buf.len);
                @memcpy(completion_buf[0..completion_len], kw[0..completion_len]);
            } else {
                // User symbol
                const entry_idx = sel_idx - kw_count;
                if (entry_idx < self.symbol_index.entries.items.len) {
                    const entry = &self.symbol_index.entries.items[entry_idx];
                    completion_len = entry.name_len;
                    @memcpy(completion_buf[0..completion_len], entry.name_orig[0..completion_len]);
                }
            }
        }

        if (completion_len == 0) return;

        // Calculate the buffer range to replace (prefix_start_col to current col)
        const lc = self.cursorLineCol();
        const line_start = self.buffer.lineColToOffset(lc.line, 0);
        const prefix_offset = line_start + ov.prefix_start_col;
        const prefix_len = self.cursor - prefix_offset;

        // Delete the prefix
        if (prefix_len > 0) {
            self.buffer.delete(prefix_offset, prefix_len) catch return;
        }

        // Insert the completion as UTF-32 codepoints
        var cps: [symbols_mod.MAX_NAME]u32 = undefined;
        for (completion_buf[0..completion_len], 0..) |c, i| {
            cps[i] = c;
        }
        self.buffer.insert(prefix_offset, cps[0..completion_len]) catch return;

        self.cursor = prefix_offset + completion_len;
        self.modified = true;
        self.symbols_dirty = true;
        self.desired_col = null;
        self.selection_anchor = null;
        self.ensureCursorVisible();
        self.updateTitle();

        // Close the overlay and reset dot/type/sprite mode
        self.autocomplete_overlay.close();
        self.dot_mode = false;
        self.type_mode = false;
        self.sprite_mode = false;
        self.sound_mode = false;
        self.music_mode = false;
        self.vs_mode = false;
        self.focus = .editor;
    }

    /// Get the display text for an autocomplete item by its encoded index.
    pub fn autocompleteItemText(self: *const EditorState, encoded_idx: u32, buf: *[512]u8) []const u8 {
        if (self.dot_mode or self.type_mode or self.sprite_mode or self.sound_mode or self.music_mode or self.vs_mode) {
            // Dot-mode, type-mode, or sprite-mode: index into dot_completions
            if (encoded_idx < self.dot_completion_count) {
                const dc = &self.dot_completions[encoded_idx];
                var pos: usize = 0;

                // Kind prefix icon
                const prefix_str: []const u8 = switch (dc.kind) {
                    .field => "\xE2\x96\xAB ", // ▫ (small square for field)
                    .method => "\xE2\x96\xB8 ", // ▸ (triangle for method)
                    .type_name => "\xE2\x97\x86 ", // ◆ (diamond for type)
                };
                const plen = @min(prefix_str.len, buf.len - pos);
                @memcpy(buf[pos .. pos + plen], prefix_str[0..plen]);
                pos += plen;

                // Name
                const nlen = @min(dc.name_len, buf.len - pos);
                @memcpy(buf[pos .. pos + nlen], dc.name[0..nlen]);
                pos += nlen;

                // Extra (field type or return type)
                if (dc.extra_len > 0 and pos + 4 < buf.len) {
                    const sep: []const u8 = if (dc.kind == .method) " -> " else " : ";
                    const slen = @min(sep.len, buf.len - pos);
                    @memcpy(buf[pos .. pos + slen], sep[0..slen]);
                    pos += slen;
                    const elen = @min(dc.extra_len, buf.len - pos);
                    @memcpy(buf[pos .. pos + elen], dc.extra[0..elen]);
                    pos += elen;
                }

                return buf[0..pos];
            }
            return "";
        }

        const kw_count: u32 = @intCast(symbols_mod.KEYWORDS.len);

        if (encoded_idx < kw_count) {
            const kw = symbols_mod.KEYWORDS[encoded_idx];
            const len = @min(kw.len, buf.len);
            @memcpy(buf[0..len], kw[0..len]);
            return buf[0..len];
        } else {
            const entry_idx = encoded_idx - kw_count;
            if (entry_idx < self.symbol_index.entries.items.len) {
                const entry = &self.symbol_index.entries.items[entry_idx];
                return entry.formatDisplay(buf);
            }
            return "";
        }
    }

    /// Check whether an autocomplete item is a dot-mode item (for rendering colour).
    pub fn isDotModeItem(self: *const EditorState) bool {
        return self.dot_mode or self.type_mode;
    }

    // ── Terminal ─────────────────────────────────────────────────────────

    // ── Keyword Shadow Report (for Analyse output) ──────────────────

    /// Print keyword shadow warnings from the symbol index to the terminal.
    /// Called when the Analyse command completes to append issues to the report.
    fn printKeywordShadowReport(self: *EditorState) void {
        const warnings = self.symbol_index.warnings.items;
        if (warnings.len == 0) return;

        self.terminalPrint("\r\n") catch {};
        self.terminalPrint("  \xe2\x94\x80\xe2\x94\x80 Keyword Shadow Warnings \xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\r\n") catch {};

        for (warnings) |*w| {
            var line_buf: [256]u8 = undefined;
            const line_text = std.fmt.bufPrint(&line_buf, "    line {d}: {s} '{s}' shadows keyword {s}\r\n", .{
                @as(usize, w.line) + 1,
                w.getDecl(),
                w.getName(),
                w.getName(),
            }) catch continue;
            self.terminalPrint(line_text) catch {};
        }

        // Summary line
        {
            var sum_buf: [128]u8 = undefined;
            const sum_text = std.fmt.bufPrint(&sum_buf, "\r\n    {d} identifier(s) shadow built-in keyword/function names.\r\n", .{warnings.len}) catch "";
            if (sum_text.len > 0) {
                self.terminalPrint(sum_text) catch {};
            }
            self.terminalPrint("    Tip: rename these to avoid unexpected behaviour.\r\n") catch {};
        }
        self.terminalPrint("\r\n") catch {};
    }

    // ── Error Line Tracking ─────────────────────────────────────────

    /// Clear all error line markers.
    pub fn clearErrorLines(self: *EditorState) void {
        self.error_lines.clearRetainingCapacity();
    }

    /// Populate error_lines from the JIT runner's error diagnostics.
    /// Call after collectResult() to transfer error info for highlighting.
    pub fn populateErrorLines(self: *EditorState) void {
        self.clearErrorLines();
        const infos = self.jit_runner.getErrorInfos();
        for (infos) |info| {
            var eli: ErrorLineInfo = .{
                .line = if (info.line > 0) @as(usize, info.line) - 1 else 0,
                .col = if (info.col > 0) @as(usize, info.col) - 1 else 0,
                .is_warning = info.is_warning,
                .message_buf = undefined,
                .message_len = info.message_len,
            };
            @memcpy(eli.message_buf[0..info.message_len], info.message_buf[0..info.message_len]);
            self.error_lines.append(self.allocator, eli) catch {};
        }
    }

    /// Jump the cursor to the first error line and column.
    pub fn jumpToFirstError(self: *EditorState) void {
        for (self.error_lines.items) |eli| {
            if (!eli.is_warning) {
                self.setCursorLineCol(eli.line, eli.col);
                self.ensureCursorVisible();
                self.focus = .editor;
                return;
            }
        }
        // If only warnings, jump to the first one
        if (self.error_lines.items.len > 0) {
            const eli = self.error_lines.items[0];
            self.setCursorLineCol(eli.line, eli.col);
            self.ensureCursorVisible();
            self.focus = .editor;
        }
    }

    /// Check if a given 0-based line has an error marker.
    pub fn lineHasError(self: *const EditorState, line: usize) bool {
        for (self.error_lines.items) |eli| {
            if (eli.line == line and !eli.is_warning) return true;
        }
        return false;
    }

    /// Check if a given 0-based line has a warning marker.
    pub fn lineHasWarning(self: *const EditorState, line: usize) bool {
        for (self.error_lines.items) |eli| {
            if (eli.line == line and eli.is_warning) return true;
        }
        return false;
    }

    /// Returns true if the current file is a BASIC source file (.bas or .bi).
    /// Used to gate BASIC-specific features like keyword uppercasing.
    fn isBasicFile(self: *const EditorState) bool {
        const path = self.file_path orelse return true; // untitled = assume BASIC
        const ext_start = std.mem.lastIndexOf(u8, path, ".") orelse return false;
        const ext = path[ext_start..];
        return std.mem.eql(u8, ext, ".bas") or
            std.mem.eql(u8, ext, ".bi") or
            std.mem.eql(u8, ext, ".baz");
    }

    /// Uppercase any BASIC keywords and built-in function names on `line_idx`.
    ///
    /// Called automatically after the user presses Enter so that each completed
    /// line is normalised without requiring a full-buffer reformat.
    ///
    /// Rules:
    ///   - Only runs on .bas / .bi / .baz files (and untitled buffers).
    ///   - Skips content inside string literals ("…").
    ///   - Stops at single-quote comments (') and REM.
    ///   - Words immediately followed by a type suffix ($, %, !, #, &) are
    ///     identifiers, not keywords — they are left alone.
    ///   - Each keyword character replacement is done in-place (1-for-1), so
    ///     no buffer-length changes occur and all existing offsets stay valid.
    ///   - No undo entries are pushed — the change is considered part of the
    ///     newline insertion that triggered it.
    pub fn upcaseKeywordsOnLine(self: *EditorState, line_idx: usize) void {
        if (!self.isBasicFile()) return;

        const range = self.buffer.lineRange(line_idx) orelse return;
        const line_data = self.buffer.getLine(line_idx) catch return;
        defer self.allocator.free(line_data);
        if (line_data.len == 0) return;

        var i: usize = 0;
        var in_string = false;

        // Skip an optional BASIC line number at the start (e.g. "10 PRINT …").
        // Line numbers are all-digit sequences optionally followed by whitespace.
        {
            var j: usize = 0;
            while (j < line_data.len and line_data[j] >= '0' and line_data[j] <= '9') : (j += 1) {}
            if (j > 0 and j < line_data.len and (line_data[j] == ' ' or line_data[j] == '\t')) {
                i = j; // start scanning after the line number
            }
        }

        while (i < line_data.len) {
            const ch = line_data[i];

            // ── String literal ───────────────────────────────────────
            if (in_string) {
                if (ch == '"') in_string = false;
                i += 1;
                continue;
            }
            if (ch == '"') {
                in_string = true;
                i += 1;
                continue;
            }

            // ── Single-quote comment — rest of line is comment ───────
            if (ch == '\'') break;

            // ── Word (identifier / keyword candidate) ────────────────
            if (format_mod.isIdentStart(ch)) {
                const word_start = i;
                i += 1;
                while (i < line_data.len and format_mod.isIdentChar(line_data[i])) : (i += 1) {}
                const word_end = i;

                // If followed immediately by a type suffix this is an
                // identifier name (e.g. LEFT$, COUNT%), not a keyword.
                if (i < line_data.len and format_mod.isTypeSuffix(line_data[i])) {
                    i += 1; // consume the suffix and move on
                    continue;
                }

                // Build an uppercase byte representation for the lookup.
                const word_cps = line_data[word_start..word_end];
                var ubuf: [64]u8 = undefined;
                const upper = format_mod.toUpperSlice(word_cps, &ubuf);

                // REM — uppercase it and then stop scanning (rest is comment).
                const is_rem = std.mem.eql(u8, upper, "REM");

                if (is_rem or format_mod.isKeyword(upper)) {
                    // Uppercase each character that isn't already uppercase.
                    for (word_cps, 0..) |cp, j| {
                        if (cp >= 'a' and cp <= 'z') {
                            const buf_pos = range.start + word_start + j;
                            self.buffer.replace(buf_pos, 1, &[_]u32{cp - 32}) catch {};
                        }
                    }
                }

                if (is_rem) break; // everything after REM is a comment
                continue;
            }

            i += 1;
        }
    }

    /// Reformat the entire buffer using the BASIC formatter.
    /// Uppercases keywords, re-indents with 2-space blocks, trims whitespace.
    pub fn formatBuffer(self: *EditorState) void {
        // Get the entire buffer as codepoints
        const cps = self.buffer.toSlice() catch {
            self.terminalPrint("  Format: out of memory\r\n") catch {};
            return;
        };
        defer self.allocator.free(cps);

        // Run the formatter
        const formatted = format_mod.formatBasic(self.allocator, cps) catch {
            self.terminalPrint("  Format: out of memory\r\n") catch {};
            return;
        };
        defer self.allocator.free(formatted);

        // Replace the entire buffer: delete all, insert formatted
        const old_len = self.buffer.length();
        if (old_len > 0) {
            // Save for undo (the whole buffer)
            const deleted = self.buffer.slice(0, old_len) catch null;
            self.buffer.delete(0, old_len) catch {
                self.terminalPrint("  Format: delete failed\r\n") catch {};
                return;
            };
            self.buffer.insert(0, formatted) catch {
                // Try to restore
                if (deleted) |d| {
                    self.buffer.insert(0, d) catch {};
                    self.allocator.free(d);
                }
                self.terminalPrint("  Format: insert failed\r\n") catch {};
                return;
            };
            if (deleted) |d| {
                self.pushUndo(0, d, formatted) catch {};
                self.allocator.free(d);
            }
        } else {
            self.buffer.insert(0, formatted) catch return;
            self.pushUndo(0, &.{}, formatted) catch {};
        }

        // Adjust cursor to stay in bounds
        if (self.cursor > self.buffer.length()) {
            self.cursor = self.buffer.length();
        }
        self.selection_anchor = null;
        self.desired_col = null;
        self.modified = true;
        self.ensureCursorVisible();
        self.updateTitle();

        // Show terminal and report
        self.terminal_visible = true;
        self.updateTerminalSize();
        self.terminalPrint("[Formatted]\r\n") catch {};
    }

    /// Auto-save before run if the buffer is modified and has a file path.
    /// Returns true if save succeeded or was not needed.
    pub fn autoSaveBeforeRun(self: *EditorState) bool {
        if (!self.modified) return true;
        if (self.file_path == null) return true; // no path — run from buffer anyway
        self.saveFile() catch {
            self.terminalPrint("  Auto-save failed, running from buffer.\r\n") catch {};
            return true; // still allow the run
        };
        self.terminalPrint("  [saved]\r\n") catch {};
        return true;
    }

    pub fn terminalPrint(self: *EditorState, text: []const u8) !void {
        self.terminal.writeBytes(text);
        // Auto-scroll to bottom when new output arrives
        if (self.terminal_pinned_to_bottom) {
            self.terminal_scroll_offset = 0;
        }
        // Clear terminal selection when new output arrives
        self.clearTermSelection();
    }

    pub fn terminalClear(self: *EditorState) void {
        self.terminal.clearGrid();
    }

    /// Update the terminal dimensions to match the current viewport.
    pub fn updateTerminalSize(self: *EditorState) void {
        if (self.atlas.cell_width <= 0) return;
        const term_cols = @as(usize, @intFromFloat(@floor(self.viewport_width / self.atlas.cell_width)));
        const term_rows: usize = self.terminal_lines;
        if (term_cols > 0 and term_rows > 0) {
            self.terminal.resize(term_cols, term_rows);
        }
    }

    /// Expand the terminal to fill the bottom half of the screen (for Run).
    pub fn expandTerminalForRun(self: *EditorState) void {
        self.terminal_lines_before_run = self.terminal_lines;
        const total_lines = self.visibleLines() + self.terminal_lines;
        const half = @max(total_lines / 2, TERMINAL_MIN_LINES);
        self.terminal_lines = @intCast(half);
        self.terminal_visible = true;
        self.terminal_scroll_offset = 0;
        self.terminal_pinned_to_bottom = true;
        self.updateTerminalSize();
    }

    /// Toggle terminal between full-screen and previous size.
    pub fn toggleTerminalFullscreen(self: *EditorState) void {
        if (self.terminal_fullscreen) {
            // Restore previous size
            self.terminal_lines = self.terminal_lines_before_fullscreen;
            self.terminal_fullscreen = false;
        } else {
            // Go full-screen: fill entire window minus status bar
            self.terminal_lines_before_fullscreen = self.terminal_lines;
            const total = self.visibleLines() + self.terminal_lines;
            self.terminal_lines = @intCast(@max(total, TERMINAL_MIN_LINES));
            self.terminal_fullscreen = true;
        }
        self.terminal_visible = true;
        self.terminal_scroll_offset = 0;
        self.terminal_pinned_to_bottom = true;
        self.updateTerminalSize();
    }

    /// Scroll the terminal pane (positive = scroll up into history, negative = towards live).
    pub fn scrollTerminal(self: *EditorState, delta: i64) void {
        const max_offset = self.terminal.scrollbackLineCount();
        if (delta > 0) {
            // Scroll up (into history)
            const amount = @as(usize, @intCast(delta));
            self.terminal_scroll_offset = @min(self.terminal_scroll_offset + amount, max_offset);
            self.terminal_pinned_to_bottom = false;
        } else if (delta < 0) {
            // Scroll down (towards live)
            const amount = @as(usize, @intCast(-delta));
            if (self.terminal_scroll_offset >= amount) {
                self.terminal_scroll_offset -= amount;
            } else {
                self.terminal_scroll_offset = 0;
            }
            if (self.terminal_scroll_offset == 0) {
                self.terminal_pinned_to_bottom = true;
            }
        }
    }

    // ── Terminal Selection ──────────────────────────────────────────────

    /// Returns the ordered (start, end) of the terminal selection, or null if none.
    pub fn termSelRange(self: *const EditorState) ?struct { start: TermSelPos, end: TermSelPos } {
        const anchor = self.term_sel_anchor orelse return null;
        const end = self.term_sel_end orelse return null;
        if (anchor.eql(end)) return null;
        return if (TermSelPos.lessThan(anchor, end))
            .{ .start = anchor, .end = end }
        else
            .{ .start = end, .end = anchor };
    }

    /// Clear the terminal selection.
    pub fn clearTermSelection(self: *EditorState) void {
        self.term_sel_anchor = null;
        self.term_sel_end = null;
        self.term_selecting = false;
    }

    /// Convert pixel coordinates to a TermSelPos (combined scrollback+grid line, col).
    /// `term_area_top_y` is the Y pixel coordinate where the terminal grid starts rendering.
    pub fn termPixelToPos(self: *const EditorState, px_x: f32, px_y: f32, term_area_top_y: f32) TermSelPos {
        const atlas = self.atlas;
        const term_rows = @min(self.terminal_lines, @as(u32, @intCast(self.terminal.rows)));
        const sb_count = self.terminal.scrollbackLineCount();
        const total_term_lines = sb_count + self.terminal.rows;

        // Which visible row did the click land on?
        const row_f = (px_y - term_area_top_y) / atlas.cell_height;
        const vis_row = @as(usize, @intFromFloat(@max(row_f, 0)));
        const clamped_vis_row = @min(vis_row, if (term_rows > 0) term_rows - 1 else 0);

        // Which column?
        const col_f = px_x / atlas.cell_width;
        const col = @as(usize, @intFromFloat(@max(col_f, 0)));
        const clamped_col = @min(col, if (self.terminal.cols > 0) self.terminal.cols - 1 else 0);

        // Map visible row to combined line index (same logic as buildFrame).
        const bottom_line = if (total_term_lines >= self.terminal_scroll_offset)
            total_term_lines - self.terminal_scroll_offset
        else
            0;
        const top_line = if (bottom_line >= term_rows) bottom_line - term_rows else 0;
        const combined_line = top_line + clamped_vis_row;

        return .{ .line = combined_line, .col = clamped_col };
    }

    /// Copy the terminal selection to the system clipboard.
    /// Returns true if something was copied.
    pub fn copyTermSelection(self: *EditorState) bool {
        const range = self.termSelRange() orelse return false;

        // Build a UTF-8 string from the selected cells.
        var result: std.ArrayListUnmanaged(u8) = .{};
        defer result.deinit(self.allocator);

        var line = range.start.line;
        while (line <= range.end.line) : (line += 1) {
            const col_start = if (line == range.start.line) range.start.col else 0;
            const col_end = if (line == range.end.line) range.end.col else self.terminal.cols;

            // Collect codepoints for this line segment, trimming trailing spaces.
            var last_non_space: usize = col_start;
            var col = col_start;
            while (col < col_end) : (col += 1) {
                const cell = self.terminal.getScrollbackCell(line, col);
                if (cell.codepoint != ' ' and cell.codepoint != 0) {
                    last_non_space = col + 1;
                }
            }

            col = col_start;
            while (col < last_non_space) : (col += 1) {
                const cell = self.terminal.getScrollbackCell(line, col);
                var cp = cell.codepoint;
                if (cp == 0) cp = ' ';
                // Encode codepoint as UTF-8
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(@intCast(cp), &buf) catch continue;
                result.appendSlice(self.allocator, buf[0..len]) catch continue;
            }

            // Add newline between lines (but not after the last line)
            if (line < range.end.line) {
                result.append(self.allocator, '\n') catch continue;
            }
        }

        if (result.items.len == 0) return false;

        // Null-terminate for the C API
        const cstr = self.allocator.allocSentinel(u8, result.items.len, 0) catch return false;
        defer self.allocator.free(cstr);
        @memcpy(cstr[0..result.items.len], result.items);

        platform.ed_platform_clipboard_set(cstr);
        return true;
    }

    // ── File Save ───────────────────────────────────────────────────────

    pub fn saveFile(self: *EditorState) !void {
        const path = self.file_path orelse return error.NoFilePath;

        if (baz_mod.isBazPath(path)) {
            // ── .baz format: zstd-compressed UTF-32 codepoints ──────
            const cps = try self.buffer.toSlice();
            defer self.allocator.free(cps);

            baz_mod.saveBaz(self.allocator, path, cps) catch {
                self.terminalPrint("  Save (.baz): compression failed\r\n") catch {};
                return error.SaveFailed;
            };
        } else {
            // ── Plain text: UTF-8 ───────────────────────────────────
            const cps = try self.buffer.toSlice();
            defer self.allocator.free(cps);

            const utf8 = try buffer_mod.codepointsToUtf8(self.allocator, cps);
            defer self.allocator.free(utf8);

            const file = try std.fs.cwd().createFile(path, .{});
            defer file.close();

            try file.writeAll(utf8);
        }

        self.modified = false;
        self.updateTitle();
    }

    pub fn saveFileAs(self: *EditorState, path: []const u8) !void {
        // Store the new path
        if (self.file_path) |old_path| {
            self.allocator.free(old_path);
        }
        self.file_path = try self.allocator.dupe(u8, path);

        try self.saveFile();
    }

    // ── Title Update ────────────────────────────────────────────────────

    pub fn updateTitle(self: *EditorState) void {
        var title_buf: [512]u8 = undefined;
        const file_name: []const u8 = if (self.file_path) |p|
            std.fs.path.basename(p)
        else
            "untitled.baz";
        const mod_mark: []const u8 = if (self.modified) " *" else "";

        const title = std.fmt.bufPrint(&title_buf, "Ed — {s}{s}", .{ file_name, mod_mark }) catch "Ed";
        // Null-terminate
        if (title.len < title_buf.len) {
            title_buf[title.len] = 0;
            const title_z: [*:0]const u8 = @ptrCast(title_buf[0..title.len :0]);
            platform.ed_platform_set_title(title_z);
        }
    }

    // ── Find / Search ───────────────────────────────────────────────────

    pub fn findUpdateMatches(self: *EditorState) !void {
        self.find_state.clearMatches(self.allocator);

        const query = self.find_state.querySlice();
        if (query.len == 0) return;

        const buf_len = self.buffer.length();
        if (buf_len == 0) return;

        // Simple brute-force search through the buffer
        var pos: usize = 0;
        while (pos + query.len <= buf_len) {
            var match = true;
            for (query, 0..) |qcp, qi| {
                const bcp = self.buffer.charAt(pos + qi) orelse {
                    match = false;
                    break;
                };
                if (self.find_state.case_insensitive) {
                    if (toUpperAscii(qcp) != toUpperAscii(bcp)) {
                        match = false;
                        break;
                    }
                } else {
                    if (qcp != bcp) {
                        match = false;
                        break;
                    }
                }
            }
            if (match) {
                try self.find_state.matches.append(self.allocator, pos);
                pos += 1; // allow overlapping matches
            } else {
                pos += 1;
            }
        }

        // Set current match to the one nearest the cursor
        if (self.find_state.matches.items.len > 0) {
            self.find_state.current_match = 0;
            for (self.find_state.matches.items, 0..) |m, i| {
                if (m >= self.cursor) {
                    self.find_state.current_match = i;
                    break;
                }
            }
        }
    }

    pub fn findNext(self: *EditorState) void {
        if (self.find_state.matches.items.len == 0) return;
        if (self.find_state.current_match) |cm| {
            self.find_state.current_match = (cm + 1) % self.find_state.matches.items.len;
        } else {
            self.find_state.current_match = 0;
        }
        self.findGoToCurrentMatch();
    }

    pub fn findPrev(self: *EditorState) void {
        if (self.find_state.matches.items.len == 0) return;
        if (self.find_state.current_match) |cm| {
            self.find_state.current_match = if (cm == 0) self.find_state.matches.items.len - 1 else cm - 1;
        } else {
            self.find_state.current_match = if (self.find_state.matches.items.len > 0) self.find_state.matches.items.len - 1 else null;
        }
        self.findGoToCurrentMatch();
    }

    fn findGoToCurrentMatch(self: *EditorState) void {
        const cm = self.find_state.current_match orelse return;
        if (cm >= self.find_state.matches.items.len) return;

        const match_pos = self.find_state.matches.items[cm];
        const query_len = self.find_state.query_len;

        // Select the match
        self.selection_anchor = match_pos;
        self.cursor = match_pos + query_len;
        self.ensureCursorVisible();
    }

    /// Replace the current match with the replace string.
    pub fn replaceCurrent(self: *EditorState) !void {
        const cm = self.find_state.current_match orelse return;
        if (cm >= self.find_state.matches.items.len) return;

        const match_pos = self.find_state.matches.items[cm];
        const query_len = self.find_state.query_len;
        const replace_text = self.find_state.replaceSlice();

        // Delete the match
        const deleted = try self.buffer.slice(match_pos, match_pos + query_len);
        defer self.allocator.free(deleted);
        try self.buffer.delete(match_pos, query_len);

        // Insert the replacement
        if (replace_text.len > 0) {
            try self.buffer.insert(match_pos, replace_text);
        }

        // Push undo
        try self.pushUndo(match_pos, deleted, replace_text);

        self.cursor = match_pos + replace_text.len;
        self.modified = true;
        self.updateTitle();

        // Refresh matches
        try self.findUpdateMatches();
    }

    /// Replace all matches with the replace string.
    pub fn replaceAll(self: *EditorState) !void {
        if (self.find_state.matches.items.len == 0) return;

        const query_len = self.find_state.query_len;
        const replace_text = self.find_state.replaceSlice();

        // Replace in reverse order to preserve earlier offsets
        var i: usize = self.find_state.matches.items.len;
        while (i > 0) {
            i -= 1;
            const match_pos = self.find_state.matches.items[i];

            const deleted = self.buffer.slice(match_pos, match_pos + query_len) catch continue;
            defer self.allocator.free(deleted);
            self.buffer.delete(match_pos, query_len) catch continue;

            if (replace_text.len > 0) {
                self.buffer.insert(match_pos, replace_text) catch continue;
            }

            self.pushUndo(match_pos, deleted, replace_text) catch {};
        }

        self.modified = true;
        self.updateTitle();

        // Refresh matches (should be empty now if replace != query)
        self.findUpdateMatches() catch {};
    }

    // ── Bracket Matching ────────────────────────────────────────────────

    /// Find the matching bracket for the character at the given buffer offset.
    /// Returns the offset of the matching bracket, or null if none found.
    pub fn findMatchingBracket(self: *const EditorState, pos: usize) ?usize {
        const ch = self.buffer.charAt(pos) orelse return null;

        // Check if it's an opening bracket
        for (BRACKET_OPEN, 0..) |open, idx| {
            if (ch == open) {
                return self.scanForward(pos, open, BRACKET_CLOSE[idx]);
            }
        }

        // Check if it's a closing bracket
        for (BRACKET_CLOSE, 0..) |close, idx| {
            if (ch == close) {
                return self.scanBackward(pos, BRACKET_OPEN[idx], close);
            }
        }

        return null;
    }

    fn scanForward(self: *const EditorState, start: usize, open: u32, close: u32) ?usize {
        var depth: i32 = 0;
        var pos = start;
        const len = self.buffer.length();
        while (pos < len) {
            const ch = self.buffer.charAt(pos) orelse break;
            if (ch == open) {
                depth += 1;
            } else if (ch == close) {
                depth -= 1;
                if (depth == 0) return pos;
            }
            pos += 1;
        }
        return null;
    }

    fn scanBackward(self: *const EditorState, start: usize, open: u32, close: u32) ?usize {
        var depth: i32 = 0;
        var pos: i64 = @intCast(start);
        while (pos >= 0) {
            const upos: usize = @intCast(pos);
            const ch = self.buffer.charAt(upos) orelse break;
            if (ch == close) {
                depth += 1;
            } else if (ch == open) {
                depth -= 1;
                if (depth == 0) return upos;
            }
            pos -= 1;
        }
        return null;
    }

    // ── Open File ───────────────────────────────────────────────────────

    pub fn openFileDialog(self: *EditorState) void {
        const path_ptr = platform.ed_platform_open_file_dialog();
        if (path_ptr) |p| {
            defer platform.ed_platform_free_path(p);
            const path = std.mem.span(p);

            // Prompt to save if modified
            if (self.modified) {
                const file_cstr: ?[*:0]const u8 = if (self.file_path) |fp| blk: {
                    // Create a null-terminated version
                    var buf: [512]u8 = undefined;
                    const basename = std.fs.path.basename(fp);
                    const copy_len = @min(basename.len, buf.len - 1);
                    @memcpy(buf[0..copy_len], basename[0..copy_len]);
                    buf[copy_len] = 0;
                    break :blk @ptrCast(buf[0..copy_len :0]);
                } else null;
                const result = platform.ed_platform_confirm_save_dialog(file_cstr);
                if (result == 1) {
                    // Save first — use Save As dialog if this is an untitled buffer
                    if (self.file_path != null) {
                        self.saveFile() catch {};
                    } else {
                        self.saveFileAsDialog();
                    }
                } else if (result < 0) {
                    // Cancel — don't open
                    return;
                }
            }

            loadFile(self, path) catch {
                self.terminalPrint("Cannot open file!\r\n") catch {};
                self.terminal_visible = true;
            };
            self.updateTitle();
        }
    }

    // ── Insert File at Cursor ────────────────────────────────────────────

    /// Open a file-picker and insert the chosen file's contents at the
    /// start of the line the cursor is currently on.  The inserted text
    /// is a single undo-able operation.  The cursor is left at the end
    /// of the inserted content.
    pub fn insertFileAtCursor(self: *EditorState) void {
        const path_ptr = platform.ed_platform_open_file_dialog();
        if (path_ptr == null) return; // cancelled
        defer platform.ed_platform_free_path(path_ptr.?);
        const path = std.mem.span(path_ptr.?);

        // ── Read the file ────────────────────────────────────────────
        const file = std.fs.cwd().openFile(path, .{}) catch {
            self.terminalPrint("  Insert File: cannot open file\r\n") catch {};
            self.terminal_visible = true;
            return;
        };
        defer file.close();

        const stat = file.stat() catch {
            self.terminalPrint("  Insert File: cannot stat file\r\n") catch {};
            self.terminal_visible = true;
            return;
        };

        const raw = self.allocator.alloc(u8, stat.size) catch {
            self.terminalPrint("  Insert File: out of memory\r\n") catch {};
            self.terminal_visible = true;
            return;
        };
        defer self.allocator.free(raw);

        const bytes_read = file.readAll(raw) catch {
            self.terminalPrint("  Insert File: read error\r\n") catch {};
            self.terminal_visible = true;
            return;
        };
        const data = raw[0..bytes_read];

        // ── Convert to codepoints ────────────────────────────────────
        const cps = buffer_mod.utf8ToCodepoints(self.allocator, data) catch {
            self.terminalPrint("  Insert File: decode error\r\n") catch {};
            self.terminal_visible = true;
            return;
        };
        defer self.allocator.free(cps);

        if (cps.len == 0) return; // nothing to insert

        // ── Find the start of the current line ───────────────────────
        const lc = self.cursorLineCol();
        const insert_pos = self.buffer.lineStart(lc.line) orelse self.cursor;

        // Ensure the inserted content ends with a newline so the
        // following code stays on its own line.
        const needs_trailing_newline = cps[cps.len - 1] != '\n';
        const insert_len = cps.len + (if (needs_trailing_newline) @as(usize, 1) else 0);

        const to_insert: []u32 = blk: {
            if (needs_trailing_newline) {
                const buf = self.allocator.alloc(u32, cps.len + 1) catch {
                    self.terminalPrint("  Insert File: out of memory\r\n") catch {};
                    self.terminal_visible = true;
                    return;
                };
                @memcpy(buf[0..cps.len], cps);
                buf[cps.len] = '\n';
                break :blk buf;
            }
            break :blk @constCast(cps);
        };
        defer if (to_insert.ptr != cps.ptr) self.allocator.free(to_insert);

        // ── Insert into buffer ───────────────────────────────────────
        _ = self.deleteSelection() catch null;

        self.buffer.insert(insert_pos, to_insert) catch {
            self.terminalPrint("  Insert File: buffer insert failed\r\n") catch {};
            self.terminal_visible = true;
            return;
        };

        self.pushUndo(insert_pos, &.{}, to_insert) catch {};

        // Leave cursor at end of inserted content
        self.cursor = insert_pos + insert_len;
        self.selection_anchor = null;
        self.desired_col = null;
        self.modified = true;
        self.symbols_dirty = true;
        self.ensureCursorVisible();
        self.updateTitle();

        // Report in terminal
        const basename = std.fs.path.basename(path);
        self.terminalPrint("  Inserted: ") catch {};
        self.terminalPrint(basename) catch {};
        self.terminalPrint("\r\n") catch {};
    }

    pub fn saveFileAsDialog(self: *EditorState) void {
        const suggested: ?[*:0]const u8 = if (self.file_path) |fp| blk: {
            var buf: [512]u8 = undefined;
            const basename = std.fs.path.basename(fp);
            const copy_len = @min(basename.len, buf.len - 1);
            @memcpy(buf[0..copy_len], basename[0..copy_len]);
            buf[copy_len] = 0;
            break :blk @ptrCast(buf[0..copy_len :0]);
        } else null;

        const path_ptr = platform.ed_platform_save_file_dialog(suggested);
        if (path_ptr) |p| {
            defer platform.ed_platform_free_path(p);
            const path = std.mem.span(p);
            self.saveFileAs(path) catch {
                self.terminalPrint("Save failed!\r\n") catch {};
                self.terminal_visible = true;
            };
        }
    }

    fn suggestBuildOutputPath(self: *EditorState, source_utf8: []const u8) !?[]u8 {
        const file_path = self.file_path orelse return null;
        const basename = std.fs.path.basename(file_path);

        var dot_pos: ?usize = null;
        var scan: usize = basename.len;
        while (scan > 0) {
            scan -= 1;
            if (basename[scan] == '.') {
                dot_pos = scan;
                break;
            }
        }

        const stem = if (dot_pos) |dp| basename[0..dp] else basename;
        const use_app_bundle = builtin.os.tag == .macos and self.jit_runner.sourceRequiresGraphicsMode(source_utf8);
        const output_name = if (use_app_bundle)
            try std.fmt.allocPrint(self.allocator, "{s}.app", .{stem})
        else
            try self.allocator.dupe(u8, stem);
        defer self.allocator.free(output_name);

        const start_dir = std.fs.path.dirname(file_path) orelse {
            const fallback = try self.allocator.dupe(u8, output_name);
            return fallback;
        };
        if (findNearestBinbasDir(self.allocator, start_dir)) |binbas_dir| {
            defer self.allocator.free(binbas_dir);
            return try std.fs.path.join(self.allocator, &.{ binbas_dir, output_name });
        }

        return try std.fs.path.join(self.allocator, &.{ start_dir, "binbas", output_name });
    }

    pub fn openCompilerSettingsDialog(self: *EditorState) void {
        const current_path_z = self.allocator.dupeZ(u8, self.jit_runner.getCompilerExe()) catch return;
        defer self.allocator.free(current_path_z);
        const current_options_z = self.allocator.dupeZ(u8, self.jit_runner.getCompilerOptions()) catch return;
        defer self.allocator.free(current_options_z);

        var out_path: ?[*:0]const u8 = null;
        var out_options: ?[*:0]const u8 = null;
        const result = platform.ed_platform_compiler_settings_dialog(
            current_path_z,
            current_options_z,
            &out_path,
            &out_options,
        );
        defer if (out_path) |p| platform.ed_platform_free_path(p);
        defer if (out_options) |p| platform.ed_platform_free_path(p);

        switch (result) {
            1 => {
                const path_ptr = out_path orelse return;
                const path = std.mem.span(path_ptr);
                const options = if (out_options) |p| std.mem.span(p) else "";

                self.jit_runner.setCompilerBackend(path, options) catch {
                    self.terminal_visible = true;
                    self.updateTerminalSize();
                    self.terminalPrint("[Compiler settings] invalid compiler path\r\n") catch {};
                    return;
                };

                var persisted = true;
                self.jit_runner.persistCompilerConfig() catch {
                    persisted = false;
                };
                self.reportCompilerSettingsChange(persisted);
            },
            2 => {
                self.jit_runner.clearCompilerConfigOverride() catch {
                    self.terminal_visible = true;
                    self.updateTerminalSize();
                    self.terminalPrint("[Compiler settings] failed to restore defaults\r\n") catch {};
                    return;
                };
                self.reportCompilerSettingsDefaults();
            },
            else => {},
        }
    }

    fn reportCompilerSettingsChange(self: *EditorState, persisted: bool) void {
        self.terminal_visible = true;
        self.updateTerminalSize();

        var msg_buf: [1536]u8 = undefined;
        const options = self.jit_runner.getCompilerOptions();
        const backend = self.jit_runner.getCompilerBackendKind().text();
        const scope = if (persisted) "saved" else "session only";
        const msg = if (options.len != 0)
            std.fmt.bufPrint(&msg_buf, "[Compiler settings {s} {s}] {s} {s}\r\n", .{ backend, scope, self.jit_runner.getCompilerExe(), options }) catch "[Compiler settings updated]\r\n"
        else
            std.fmt.bufPrint(&msg_buf, "[Compiler settings {s} {s}] {s}\r\n", .{ backend, scope, self.jit_runner.getCompilerExe() }) catch "[Compiler settings updated]\r\n";
        self.terminalPrint(msg) catch {};
    }

    fn reportCompilerSettingsDefaults(self: *EditorState) void {
        self.terminal_visible = true;
        self.updateTerminalSize();

        var msg_buf: [1024]u8 = undefined;
        const options = self.jit_runner.getCompilerOptions();
        const backend = self.jit_runner.getCompilerBackendKind().text();
        const msg = if (options.len != 0)
            std.fmt.bufPrint(&msg_buf, "[Compiler settings defaults {s}] {s} {s}\r\n", .{ backend, self.jit_runner.getCompilerExe(), options }) catch "[Compiler settings defaults restored]\r\n"
        else
            std.fmt.bufPrint(&msg_buf, "[Compiler settings defaults {s}] {s}\r\n", .{ backend, self.jit_runner.getCompilerExe() }) catch "[Compiler settings defaults restored]\r\n";
        self.terminalPrint(msg) catch {};
    }

    // ── Export to UTF-8 ─────────────────────────────────────────────────

    /// Export the current buffer as a plain UTF-8 text file (.bas).
    /// Shows a Save dialog defaulting to a .bas version of the current
    /// filename.  Does NOT change the editor's file_path — the working
    /// file remains the .baz original.
    pub fn exportUtf8(self: *EditorState) void {
        // Build a suggested filename: current name with .bas extension
        const suggested: ?[*:0]const u8 = if (self.file_path) |fp| blk: {
            var buf: [512]u8 = undefined;
            const basename = std.fs.path.basename(fp);

            // Find the last dot to replace extension
            var dot_pos: ?usize = null;
            var scan: usize = basename.len;
            while (scan > 0) {
                scan -= 1;
                if (basename[scan] == '.') {
                    dot_pos = scan;
                    break;
                }
            }

            const stem = if (dot_pos) |dp| basename[0..dp] else basename;
            const total = stem.len + 4; // ".bas"
            if (total >= buf.len) break :blk null;

            @memcpy(buf[0..stem.len], stem);
            @memcpy(buf[stem.len..][0..4], ".bas");
            buf[total] = 0;
            break :blk @ptrCast(buf[0..total :0]);
        } else blk: {
            break :blk @as(?[*:0]const u8, "untitled.bas");
        };

        const path_ptr = platform.ed_platform_save_file_dialog(suggested);
        if (path_ptr) |p| {
            defer platform.ed_platform_free_path(p);
            const path = std.mem.span(p);

            // Always write as UTF-8 regardless of the chosen extension
            const cps = self.buffer.toSlice() catch {
                self.terminalPrint("  Export: out of memory\r\n") catch {};
                self.terminal_visible = true;
                return;
            };
            defer self.allocator.free(cps);

            const utf8 = buffer_mod.codepointsToUtf8(self.allocator, cps) catch {
                self.terminalPrint("  Export: UTF-8 conversion failed\r\n") catch {};
                self.terminal_visible = true;
                return;
            };
            defer self.allocator.free(utf8);

            const file = std.fs.cwd().createFile(path, .{}) catch {
                self.terminalPrint("  Export: cannot create file\r\n") catch {};
                self.terminal_visible = true;
                return;
            };
            defer file.close();

            file.writeAll(utf8) catch {
                self.terminalPrint("  Export: write failed\r\n") catch {};
                self.terminal_visible = true;
                return;
            };

            self.terminal_visible = true;
            self.updateTerminalSize();
            var msg_buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "[Exported UTF-8: {s}]\r\n", .{
                std.fs.path.basename(path),
            }) catch "[Exported]\r\n";
            self.terminalPrint(msg) catch {};
        }
    }
};

fn toUpperAscii(cp: u32) u32 {
    if (cp >= 'a' and cp <= 'z') return cp - 32;
    return cp;
}

// ─── Global State ───────────────────────────────────────────────────────────

var g_state: ?*EditorState = null;
var g_allocator: std.mem.Allocator = undefined;

// ─── Syntax Highlighting (simplified inline lexer) ──────────────────────────

fn classifyToken(word_buf: []const u32) SyntaxCategory {
    // Convert to uppercase ASCII for comparison
    var upper: [64]u8 = undefined;
    const len = @min(word_buf.len, 63);
    for (word_buf[0..len], 0..) |cp, i| {
        if (cp >= 'a' and cp <= 'z') {
            upper[i] = @intCast(cp - 32);
        } else if (cp < 128) {
            upper[i] = @intCast(cp);
        } else {
            return .default;
        }
    }
    const w = upper[0..len];

    // Control flow keywords
    if (strMatch(w, "IF") or strMatch(w, "THEN") or strMatch(w, "ELSE") or
        strMatch(w, "ELSEIF") or strMatch(w, "ENDIF") or
        strMatch(w, "FOR") or strMatch(w, "TO") or strMatch(w, "STEP") or
        strMatch(w, "NEXT") or strMatch(w, "WHILE") or strMatch(w, "WEND") or
        strMatch(w, "DO") or strMatch(w, "LOOP") or strMatch(w, "UNTIL") or
        strMatch(w, "REPEAT") or strMatch(w, "SELECT") or strMatch(w, "CASE") or
        strMatch(w, "ENDCASE") or strMatch(w, "OTHERWISE") or
        strMatch(w, "EXIT") or strMatch(w, "GOTO") or strMatch(w, "GOSUB") or
        strMatch(w, "RETURN") or strMatch(w, "ON") or strMatch(w, "BEGIN") or
        strMatch(w, "END") or strMatch(w, "DONE") or strMatch(w, "MATCH") or strMatch(w, "ENDMATCH") or
        strMatch(w, "WHEN") or strMatch(w, "IS") or
        strMatch(w, "TRY") or strMatch(w, "CATCH") or strMatch(w, "FINALLY") or
        strMatch(w, "THROW"))
    {
        return .control_flow;
    }

    // Subroutine keywords
    if (strMatch(w, "SUB") or strMatch(w, "FUNCTION") or
        strMatch(w, "ENDSUB") or strMatch(w, "ENDFUNCTION") or
        strMatch(w, "METHOD") or strMatch(w, "CONSTRUCTOR") or
        strMatch(w, "DESTRUCTOR") or strMatch(w, "CALL") or
        strMatch(w, "DEF") or strMatch(w, "FN"))
    {
        return .subroutine;
    }

    // Type keywords
    if (strMatch(w, "DIM") or strMatch(w, "REDIM") or strMatch(w, "AS") or
        strMatch(w, "TYPE") or strMatch(w, "ENDTYPE") or
        strMatch(w, "CLASS") or strMatch(w, "EXTENDS") or
        strMatch(w, "INTEGER") or strMatch(w, "DOUBLE") or strMatch(w, "SINGLE") or strMatch(w, "COMPLEX") or
        strMatch(w, "STRING") or strMatch(w, "LONG") or strMatch(w, "BYTE") or
        strMatch(w, "SHORT") or strMatch(w, "BOOLEAN") or
        strMatch(w, "UBYTE") or strMatch(w, "USHORT") or
        strMatch(w, "UINTEGER") or strMatch(w, "ULONG") or
        strMatch(w, "HASHMAP") or strMatch(w, "LIST") or
        strMatch(w, "NEW") or strMatch(w, "CREATE") or strMatch(w, "DELETE") or
        strMatch(w, "NOTHING") or strMatch(w, "ME") or strMatch(w, "SUPER") or
        strMatch(w, "CONSTANT") or strMatch(w, "SHARED") or
        strMatch(w, "LOCAL") or strMatch(w, "GLOBAL") or
        strMatch(w, "BYREF") or strMatch(w, "BYVAL") or
        strMatch(w, "ERASE") or strMatch(w, "PRESERVE") or
        strMatch(w, "MARSHALLED"))
    {
        return .type_keyword;
    }

    // Worker / concurrency keywords
    if (strMatch(w, "WORKER") or strMatch(w, "ENDWORKER") or
        strMatch(w, "SPAWN") or strMatch(w, "AWAIT") or
        strMatch(w, "SEND") or strMatch(w, "RECEIVE") or
        strMatch(w, "HASMESSAGE") or strMatch(w, "CANCEL") or
        strMatch(w, "CANCELLED") or strMatch(w, "MARSHALL") or
        strMatch(w, "UNMARSHALL") or strMatch(w, "FUTURE") or
        strMatch(w, "READY") or strMatch(w, "PARENT"))
    {
        return .worker;
    }

    // Other keywords
    if (strMatch(w, "PRINT") or strMatch(w, "INPUT") or strMatch(w, "LET") or
        strMatch(w, "REM") or strMatch(w, "CLS") or strMatch(w, "COLOR") or
        strMatch(w, "COLOUR") or strMatch(w, "LOCATE") or
        strMatch(w, "OPEN") or strMatch(w, "CLOSE") or
        strMatch(w, "READ") or strMatch(w, "WRITE") or strMatch(w, "DATA") or
        strMatch(w, "RESTORE") or strMatch(w, "SWAP") or
        strMatch(w, "INC") or strMatch(w, "DEC") or
        strMatch(w, "SLEEP") or strMatch(w, "WAIT") or strMatch(w, "TIMER") or
        strMatch(w, "OPTION") or strMatch(w, "INCLUDE") or
        strMatch(w, "SHELL") or strMatch(w, "SYSTEM") or
        strMatch(w, "CONSOLE") or strMatch(w, "SLURP") or strMatch(w, "SPIT") or
        strMatch(w, "IIF") or strMatch(w, "USING") or
        strMatch(w, "AND") or strMatch(w, "OR") or strMatch(w, "NOT") or
        strMatch(w, "XOR") or strMatch(w, "MOD") or
        strMatch(w, "EQV") or strMatch(w, "IMP") or
        strMatch(w, "BAND") or strMatch(w, "BOR") or strMatch(w, "BNOT") or
        strMatch(w, "BXOR") or strMatch(w, "ANDALSO") or strMatch(w, "ORELSE") or
        strMatch(w, "STOP") or strMatch(w, "RUN") or
        strMatch(w, "AFTER") or strMatch(w, "EVERY") or
        strMatch(w, "APPEND") or strMatch(w, "PREPEND") or
        strMatch(w, "HEAD") or strMatch(w, "TAIL") or
        strMatch(w, "REST") or strMatch(w, "LENGTH") or
        strMatch(w, "EMPTY") or strMatch(w, "CONTAINS") or
        strMatch(w, "KEYS") or strMatch(w, "SIZE") or
        strMatch(w, "CLEAR") or strMatch(w, "REMOVE") or
        strMatch(w, "HASKEY") or strMatch(w, "TYPEOF") or
        // Retro graphics window keywords
        strMatch(w, "SCREEN") or strMatch(w, "SCREENCLOSE") or
        strMatch(w, "SCREENTITLE") or strMatch(w, "SCREENMODE") or
        strMatch(w, "SETTARGET") or strMatch(w, "FLIP") or
        strMatch(w, "PSET") or strMatch(w, "GCLS") or
        strMatch(w, "GLINE") or strMatch(w, "RECT") or
        strMatch(w, "CIRCLE") or strMatch(w, "ELLIPSE") or
        strMatch(w, "TRIANGLE") or strMatch(w, "FILLAREA") or
        strMatch(w, "GSCROLL") or strMatch(w, "SETSCROLL") or
        strMatch(w, "BLIT") or strMatch(w, "BLITSOLID") or
        strMatch(w, "BLITSCALE") or strMatch(w, "BLITFLIP") or
        strMatch(w, "DRAWTEXT") or strMatch(w, "PALETTE") or
        strMatch(w, "LINEPALETTE") or strMatch(w, "RESETPALETTE") or
        strMatch(w, "PALCYCLE") or strMatch(w, "PALFADE") or
        strMatch(w, "PALPULSE") or strMatch(w, "PALGRADIENT") or
        strMatch(w, "PALSTROBE") or strMatch(w, "PALSTOP") or
        strMatch(w, "PALSTOPALL") or strMatch(w, "PALPAUSE") or
        strMatch(w, "PALRESUME") or strMatch(w, "GCOMMIT") or
        strMatch(w, "GWAIT") or strMatch(w, "VSYNC") or
        strMatch(w, "GCOLLIDESETUP") or strMatch(w, "GCOLLIDESRC") or
        strMatch(w, "GCOLLIDETEST") or
        // Retro graphics window functions (return values)
        strMatch(w, "PGET") or strMatch(w, "TEXTWIDTH") or
        strMatch(w, "TEXTHEIGHT") or strMatch(w, "GINKEY") or
        strMatch(w, "GINKEY$") or strMatch(w, "GKEYDOWN") or
        strMatch(w, "GMOUSEX") or strMatch(w, "GMOUSEY") or
        strMatch(w, "GMOUSEBUTTON") or strMatch(w, "GMOUSESCROLL") or
        strMatch(w, "JOYCOUNT") or strMatch(w, "JOYAXIS") or
        strMatch(w, "JOYBUTTON") or strMatch(w, "GSCREENWIDTH") or
        strMatch(w, "GSCREENHEIGHT") or strMatch(w, "SCREENACTIVE") or
        strMatch(w, "FRONTBUFFER") or strMatch(w, "GBUFFERWIDTH") or
        strMatch(w, "GBUFFERHEIGHT") or strMatch(w, "PALETTEGET") or
        strMatch(w, "LINEPALETTEGET") or strMatch(w, "GCOLLIDE") or
        strMatch(w, "GCOLLIDERESULT") or strMatch(w, "GFENCE") or
        strMatch(w, "GFENCEDONE") or strMatch(w, "FRAMES") or
        // ARM64 bit-manipulation intrinsics
        strMatch(w, "CLZ") or strMatch(w, "CTZ") or strMatch(w, "POPCNT") or
        strMatch(w, "BITREV") or strMatch(w, "BYTEREV") or
        strMatch(w, "BITGET") or strMatch(w, "BITSET") or
        strMatch(w, "BITCLR") or strMatch(w, "BITTGL") or
        strMatch(w, "BITFIELD") or strMatch(w, "BITSFIELD") or
        strMatch(w, "BITINS") or strMatch(w, "BITCLRF") or
        // GPU sprite keywords
        strMatch(w, "SPRITE") or
        strMatch(w, "SPRITEX") or strMatch(w, "SPRITEY") or
        strMatch(w, "SPRITEGETROT") or strMatch(w, "SPRITEVISIBLE") or
        strMatch(w, "SPRITEGETFRAME") or strMatch(w, "SPRITEHIT") or
        strMatch(w, "SPRITECOUNT") or strMatch(w, "SPRITEOVERLAP") or
        // Math functions (scalar and element-wise on whole arrays)
        strMatch(w, "SIN") or strMatch(w, "COS") or strMatch(w, "TAN") or
        strMatch(w, "ATN") or strMatch(w, "EXP") or strMatch(w, "LOG") or
        strMatch(w, "SQR") or strMatch(w, "ABS") or strMatch(w, "SGN") or
        strMatch(w, "INT") or strMatch(w, "CDBL") or strMatch(w, "CINT") or
        strMatch(w, "CMPLX") or strMatch(w, "REAL") or strMatch(w, "IMAG") or
        strMatch(w, "CONJ") or strMatch(w, "ABSZ") or strMatch(w, "ARG") or strMatch(w, "POLAR") or
        strMatch(w, "CLAMP") or strMatch(w, "LERP") or
        strMatch(w, "MIN") or strMatch(w, "MAX") or
        // Array reductions (SIMD-accelerated whole-array operations)
        strMatch(w, "SUM") or strMatch(w, "PRODUCT") or
        strMatch(w, "NORM") or strMatch(w, "COUNT") or
        strMatch(w, "AVG") or strMatch(w, "DOT") or
        strMatch(w, "SUMSQ") or strMatch(w, "RMS") or
        strMatch(w, "RANGE"))
    {
        return .keyword;
    }

    return .default;
}

fn strMatch(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn isIdentStart(cp: u32) bool {
    return (cp >= 'A' and cp <= 'Z') or (cp >= 'a' and cp <= 'z') or cp == '_';
}

fn isIdentChar(cp: u32) bool {
    return isIdentStart(cp) or (cp >= '0' and cp <= '9');
}

fn isDigit(cp: u32) bool {
    return cp >= '0' and cp <= '9';
}

// ─── File Type Detection ────────────────────────────────────────────────────

fn getFileType(file_path: ?[]const u8) enum { basic, zig, unknown } {
    const path = file_path orelse return .basic; // Default to BASIC for untitled

    if (std.mem.endsWith(u8, path, ".zig")) return .zig;
    if (std.mem.endsWith(u8, path, ".bas")) return .basic;
    if (std.mem.endsWith(u8, path, ".baz")) return .basic;

    return .basic; // Default to BASIC
}

// ── Sprite ROW pixel background colouring ─────────────────────────────────
//
// C64 VIC-II palette for sprite pixel indices 0..15.
// Indices 0 and 1 are null (black/white → use normal editor bg).
const C64_SPRITE_BG = [16]?Colour{
    Colour{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 255 }, // 0  Black
    Colour{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 255 }, // 1  Black (outline)
    Colour{ .r = 0x88, .g = 0x39, .b = 0x32, .a = 255 }, // 2  Red
    Colour{ .r = 0x67, .g = 0xB6, .b = 0xBD, .a = 255 }, // 3  Cyan
    Colour{ .r = 0x8B, .g = 0x3F, .b = 0x96, .a = 255 }, // 4  Purple
    Colour{ .r = 0x55, .g = 0xA0, .b = 0x49, .a = 255 }, // 5  Green
    Colour{ .r = 0x40, .g = 0x31, .b = 0x8D, .a = 255 }, // 6  Blue
    Colour{ .r = 0xBF, .g = 0xCE, .b = 0x72, .a = 255 }, // 7  Yellow
    Colour{ .r = 0x8B, .g = 0x54, .b = 0x29, .a = 255 }, // 8  Orange
    Colour{ .r = 0x57, .g = 0x42, .b = 0x00, .a = 255 }, // 9  Brown
    Colour{ .r = 0xB8, .g = 0x69, .b = 0x62, .a = 255 }, // 10 Light Red
    Colour{ .r = 0x50, .g = 0x50, .b = 0x50, .a = 255 }, // 11 Dark Grey
    Colour{ .r = 0x78, .g = 0x78, .b = 0x78, .a = 255 }, // 12 Grey
    Colour{ .r = 0x94, .g = 0xE0, .b = 0x89, .a = 255 }, // 13 Light Green
    Colour{ .r = 0x78, .g = 0x69, .b = 0xC4, .a = 255 }, // 14 Light Blue
    Colour{ .r = 0x9F, .g = 0x9F, .b = 0x9F, .a = 255 }, // 15 Light Grey
};

/// Contrasting fg for each C64 bg index — white on dark, dark on light.
const C64_SPRITE_FG = [16]?Colour{
    Colour{ .r = 0xFF, .g = 0xFF, .b = 0xFF, .a = 255 }, // 0  white on black
    Colour{ .r = 0xFF, .g = 0xFF, .b = 0xFF, .a = 255 }, // 1  white on black
    Colour{ .r = 0xFF, .g = 0xFF, .b = 0xFF, .a = 255 }, // 2  white on red
    Colour{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 255 }, // 3  black on cyan
    Colour{ .r = 0xFF, .g = 0xFF, .b = 0xFF, .a = 255 }, // 4  white on purple
    Colour{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 255 }, // 5  black on green
    Colour{ .r = 0xFF, .g = 0xFF, .b = 0xFF, .a = 255 }, // 6  white on blue
    Colour{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 255 }, // 7  black on yellow
    Colour{ .r = 0xFF, .g = 0xFF, .b = 0xFF, .a = 255 }, // 8  white on orange
    Colour{ .r = 0xFF, .g = 0xFF, .b = 0xFF, .a = 255 }, // 9  white on brown
    Colour{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 255 }, // 10 black on light red
    Colour{ .r = 0xFF, .g = 0xFF, .b = 0xFF, .a = 255 }, // 11 white on dark grey
    Colour{ .r = 0xFF, .g = 0xFF, .b = 0xFF, .a = 255 }, // 12 white on grey
    Colour{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 255 }, // 13 black on light green
    Colour{ .r = 0xFF, .g = 0xFF, .b = 0xFF, .a = 255 }, // 14 white on light blue
    Colour{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 255 }, // 15 black on light grey
};

/// For a SPRITE ROW line, returns a per-codepoint bg/fg colour override.
/// Both slices are the same length as `line`; null = use normal colours.
/// Returns null (not allocated) if the line is not a SPRITE ROW statement.
const SpritePixelOverride = struct { bg: ?Colour, fg: ?Colour };
fn spriteRowPixelBgs(allocator: std.mem.Allocator, line: []const u32) !?[]SpritePixelOverride {
    var i: usize = 0;
    // Skip leading whitespace and optional line number
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') i += 1;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    // Match SPRITE (case-insensitive)
    const kw_sprite = "SPRITE";
    if (i + kw_sprite.len > line.len) return null;
    for (kw_sprite, 0..) |c, j| {
        const lc = line[i + j];
        const up: u32 = if (lc >= 'a' and lc <= 'z') lc - 32 else lc;
        if (up != c) return null;
    }
    i += kw_sprite.len;
    // Skip whitespace
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    // Match ROW (case-insensitive)
    const kw_row = "ROW";
    if (i + kw_row.len > line.len) return null;
    for (kw_row, 0..) |c, j| {
        const lc = line[i + j];
        const up: u32 = if (lc >= 'a' and lc <= 'z') lc - 32 else lc;
        if (up != c) return null;
    }
    i += kw_row.len;
    // Skip whitespace
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    // Skip row index (decimal number)
    while (i < line.len and line[i] >= '0' and line[i] <= '9') i += 1;
    // Skip whitespace then mandatory comma
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    if (i >= line.len or line[i] != ',') return null;
    i += 1;

    // Allocate override array — all null by default
    const overrides = try allocator.alloc(SpritePixelOverride, line.len);
    @memset(overrides, .{ .bg = null, .fg = null });

    // Scan hex nibbles: each hex char 0-9 / A-F is one pixel.
    // Spaces are ignored (no colour override). Comment ends the scan.
    while (i < line.len) {
        const ch = line[i];
        if (ch == '\'') break; // comment
        const nibble: ?u8 = switch (ch) {
            '0'...'9' => @intCast(ch - '0'),
            'A'...'F' => @intCast(ch - 'A' + 10),
            'a'...'f' => @intCast(ch - 'a' + 10),
            else => null,
        };
        if (nibble) |n| {
            overrides[i] = .{ .bg = C64_SPRITE_BG[n], .fg = C64_SPRITE_FG[n] };
        }
        i += 1;
    }
    return overrides;
}

/// Syntax highlighting state that carries across lines (e.g., triple strings).
const SyntaxState = struct {
    in_basic_triple_string: bool = false,
};

/// Classify each code point in a line for syntax highlighting.
/// Returns an allocated array of SyntaxCategory, one per code point.
/// Dispatches to language-specific highlighter based on file type.
fn highlightLine(
    allocator: std.mem.Allocator,
    line: []const u32,
    file_path: ?[]const u8,
    state: ?*SyntaxState,
) ![]SyntaxCategory {
    const file_type = getFileType(file_path);
    return switch (file_type) {
        .basic => highlightLineBasic(allocator, line, state),
        .zig => highlightLineZig(allocator, line, state),
        .unknown => highlightLineBasic(allocator, line, state),
    };
}

/// Classify each code point in a line for BASIC syntax highlighting.
fn highlightLineBasic(allocator: std.mem.Allocator, line: []const u32, state: ?*SyntaxState) ![]SyntaxCategory {
    const cats = try allocator.alloc(SyntaxCategory, line.len);
    @memset(cats, .default);

    var triple_open = false;
    if (state) |s| {
        triple_open = s.in_basic_triple_string;
    }

    var i: usize = 0;
    while (i < line.len) {
        const cp = line[i];

        // Inside a triple-quoted string: mark until closing """ or end of line
        if (triple_open) {
            cats[i] = .string;
            if (cp == '"' and i + 2 < line.len and line[i + 1] == '"' and line[i + 2] == '"') {
                cats[i + 1] = .string;
                cats[i + 2] = .string;
                triple_open = false;
                i += 3;
                continue;
            }
            i += 1;
            continue;
        }

        // Triple-quoted string opener
        if (cp == '"' and i + 2 < line.len and line[i + 1] == '"' and line[i + 2] == '"') {
            cats[i] = .string;
            cats[i + 1] = .string;
            cats[i + 2] = .string;
            i += 3;
            triple_open = true;
            continue;
        }

        // Comment: ' or REM
        if (cp == '\'') {
            @memset(cats[i..], .comment);
            break;
        }

        // String literal
        if (cp == '"') {
            cats[i] = .string;
            i += 1;
            while (i < line.len) {
                cats[i] = .string;
                if (line[i] == '"') {
                    i += 1;
                    break;
                }
                i += 1;
            }
            continue;
        }

        // Number literal
        if (isDigit(cp) or (cp == '.' and i + 1 < line.len and isDigit(line[i + 1]))) {
            while (i < line.len and (isDigit(line[i]) or line[i] == '.' or line[i] == 'e' or line[i] == 'E')) {
                cats[i] = .number;
                i += 1;
            }
            continue;
        }

        // Hex/binary/octal literals: &H, &B, &O
        if (cp == '&' and i + 1 < line.len) {
            const next = line[i + 1];
            if (next == 'H' or next == 'h' or next == 'B' or next == 'b' or next == 'O' or next == 'o') {
                cats[i] = .number;
                cats[i + 1] = .number;
                i += 2;
                while (i < line.len and (isDigit(line[i]) or
                    (line[i] >= 'A' and line[i] <= 'F') or
                    (line[i] >= 'a' and line[i] <= 'f')))
                {
                    cats[i] = .number;
                    i += 1;
                }
                continue;
            }
        }

        // Identifier / keyword
        if (isIdentStart(cp)) {
            const start = i;
            while (i < line.len and isIdentChar(line[i])) {
                i += 1;
            }
            // Include trailing $ for string functions like LEFT$, MID$
            if (i < line.len and line[i] == '$') {
                i += 1;
            }

            const word = line[start..i];
            const cat = classifyToken(word);

            // Special case: REM starts a comment to end of line
            if (cat == .keyword and word.len >= 3) {
                var upper3: [3]u8 = undefined;
                for (word[0..3], 0..) |c, j| {
                    upper3[j] = if (c >= 'a' and c <= 'z') @intCast(c - 32) else @intCast(c & 0x7F);
                }
                if (upper3[0] == 'R' and upper3[1] == 'E' and upper3[2] == 'M') {
                    @memset(cats[start..], .comment);
                    break;
                }
            }

            @memset(cats[start..i], cat);
            continue;
        }

        // Operators
        if (cp == '+' or cp == '-' or cp == '*' or cp == '/' or cp == '\\' or
            cp == '^' or cp == '=' or cp == '<' or cp == '>')
        {
            cats[i] = .operator;
            // Handle <>, <=, >=
            if (i + 1 < line.len) {
                const nxt = line[i + 1];
                if ((cp == '<' and (nxt == '>' or nxt == '=')) or
                    (cp == '>' and nxt == '=') or
                    (cp == '!' and nxt == '='))
                {
                    i += 1;
                    cats[i] = .operator;
                }
            }
            i += 1;
            continue;
        }

        // Type suffixes
        if (cp == '%' or cp == '!' or cp == '#' or cp == '$' or cp == '@') {
            cats[i] = .type_suffix;
            i += 1;
            continue;
        }

        // Delimiters
        if (cp == '(' or cp == ')' or cp == ',' or cp == ';' or cp == ':' or cp == '.') {
            cats[i] = .delimiter;
            i += 1;
            continue;
        }

        // Everything else is default
        i += 1;
    }

    if (state) |s| {
        s.in_basic_triple_string = triple_open;
    }

    return cats;
}

/// Classify each code point in a line for Zig syntax highlighting.
fn highlightLineZig(allocator: std.mem.Allocator, line: []const u32, state: ?*SyntaxState) ![]SyntaxCategory {
    _ = state; // Zig highlighter currently stateless
    const cats = try allocator.alloc(SyntaxCategory, line.len);
    @memset(cats, .default);

    var i: usize = 0;
    while (i < line.len) {
        const cp = line[i];

        // Line comment: //
        if (cp == '/' and i + 1 < line.len and line[i + 1] == '/') {
            @memset(cats[i..], .comment);
            break;
        }

        // Doc comment: ///
        if (cp == '/' and i + 2 < line.len and line[i + 1] == '/' and line[i + 2] == '/') {
            @memset(cats[i..], .comment);
            break;
        }

        // String literal (double quotes)
        if (cp == '"') {
            cats[i] = .string;
            i += 1;
            var escaped = false;
            while (i < line.len) {
                cats[i] = .string;
                if (escaped) {
                    escaped = false;
                } else if (line[i] == '\\') {
                    escaped = true;
                } else if (line[i] == '"') {
                    i += 1;
                    break;
                }
                i += 1;
            }
            continue;
        }

        // Char literal (single quotes)
        if (cp == '\'') {
            cats[i] = .string;
            i += 1;
            var escaped = false;
            while (i < line.len) {
                cats[i] = .string;
                if (escaped) {
                    escaped = false;
                } else if (line[i] == '\\') {
                    escaped = true;
                } else if (line[i] == '\'') {
                    i += 1;
                    break;
                }
                i += 1;
            }
            continue;
        }

        // Number literal (including hex 0x, binary 0b, octal 0o)
        if (isDigit(cp) or (cp == '.' and i + 1 < line.len and isDigit(line[i + 1]))) {
            while (i < line.len and (isDigit(line[i]) or line[i] == '.' or
                line[i] == 'e' or line[i] == 'E' or line[i] == 'x' or
                line[i] == 'b' or line[i] == 'o' or line[i] == '_' or
                (line[i] >= 'A' and line[i] <= 'F') or (line[i] >= 'a' and line[i] <= 'f')))
            {
                cats[i] = .number;
                i += 1;
            }
            continue;
        }

        // Identifier / keyword
        if (isIdentStart(cp) or cp == '@') {
            const start = i;
            if (cp == '@') i += 1; // Built-in like @import
            while (i < line.len and isIdentChar(line[i])) {
                i += 1;
            }

            const word = line[start..i];
            const cat = classifyZigToken(word);
            @memset(cats[start..i], cat);
            continue;
        }

        // Operators
        if (cp == '+' or cp == '-' or cp == '*' or cp == '/' or cp == '%' or
            cp == '=' or cp == '<' or cp == '>' or cp == '!' or cp == '&' or
            cp == '|' or cp == '^' or cp == '~')
        {
            cats[i] = .operator;
            i += 1;
            continue;
        }

        // Delimiters
        if (cp == '(' or cp == ')' or cp == '{' or cp == '}' or cp == '[' or cp == ']' or
            cp == ',' or cp == ';' or cp == ':' or cp == '.')
        {
            cats[i] = .delimiter;
            i += 1;
            continue;
        }

        // Everything else is default
        i += 1;
    }

    return cats;
}

fn classifyZigToken(word: []const u32) SyntaxCategory {
    // Convert to uppercase ASCII for comparison
    var upper: [64]u8 = undefined;
    const len = @min(word.len, 63);
    for (word[0..len], 0..) |cp, idx| {
        if (cp >= 'a' and cp <= 'z') {
            upper[idx] = @intCast(cp - 32);
        } else if (cp < 128) {
            upper[idx] = @intCast(cp);
        } else {
            return .default;
        }
    }
    const u = upper[0..len];

    // Built-ins (start with @)
    if (word.len > 0 and word[0] == '@') return .keyword;

    // Control flow keywords
    if (std.mem.eql(u8, u, "IF")) return .control_flow;
    if (std.mem.eql(u8, u, "ELSE")) return .control_flow;
    if (std.mem.eql(u8, u, "WHILE")) return .control_flow;
    if (std.mem.eql(u8, u, "FOR")) return .control_flow;
    if (std.mem.eql(u8, u, "SWITCH")) return .control_flow;
    if (std.mem.eql(u8, u, "BREAK")) return .control_flow;
    if (std.mem.eql(u8, u, "CONTINUE")) return .control_flow;
    if (std.mem.eql(u8, u, "RETURN")) return .control_flow;
    if (std.mem.eql(u8, u, "DEFER")) return .control_flow;
    if (std.mem.eql(u8, u, "ERRDEFER")) return .control_flow;
    if (std.mem.eql(u8, u, "TRY")) return .control_flow;
    if (std.mem.eql(u8, u, "CATCH")) return .control_flow;
    if (std.mem.eql(u8, u, "ORELSE")) return .control_flow;

    // Type keywords
    if (std.mem.eql(u8, u, "CONST")) return .type_keyword;
    if (std.mem.eql(u8, u, "VAR")) return .type_keyword;
    if (std.mem.eql(u8, u, "COMPTIME")) return .type_keyword;
    if (std.mem.eql(u8, u, "STRUCT")) return .type_keyword;
    if (std.mem.eql(u8, u, "ENUM")) return .type_keyword;
    if (std.mem.eql(u8, u, "UNION")) return .type_keyword;
    if (std.mem.eql(u8, u, "PACKED")) return .type_keyword;
    if (std.mem.eql(u8, u, "EXTERN")) return .type_keyword;
    if (std.mem.eql(u8, u, "EXPORT")) return .type_keyword;
    if (std.mem.eql(u8, u, "TYPE")) return .type_keyword;
    if (std.mem.eql(u8, u, "ANYTYPE")) return .type_keyword;
    if (std.mem.eql(u8, u, "ERROR")) return .type_keyword;
    if (std.mem.eql(u8, u, "OPAQUE")) return .type_keyword;

    // Function/method keywords
    if (std.mem.eql(u8, u, "FN")) return .subroutine;
    if (std.mem.eql(u8, u, "PUB")) return .subroutine;
    if (std.mem.eql(u8, u, "INLINE")) return .subroutine;
    if (std.mem.eql(u8, u, "NOINLINE")) return .subroutine;

    // Other keywords
    if (std.mem.eql(u8, u, "AND")) return .keyword;
    if (std.mem.eql(u8, u, "OR")) return .keyword;
    if (std.mem.eql(u8, u, "TEST")) return .keyword;
    if (std.mem.eql(u8, u, "ASYNC")) return .keyword;
    if (std.mem.eql(u8, u, "AWAIT")) return .keyword;
    if (std.mem.eql(u8, u, "SUSPEND")) return .keyword;
    if (std.mem.eql(u8, u, "RESUME")) return .keyword;
    if (std.mem.eql(u8, u, "NOSUSPEND")) return .keyword;
    if (std.mem.eql(u8, u, "UNREACHABLE")) return .keyword;
    if (std.mem.eql(u8, u, "USINGNAMESPACE")) return .keyword;
    if (std.mem.eql(u8, u, "THREADLOCAL")) return .keyword;
    if (std.mem.eql(u8, u, "ALLOWZERO")) return .keyword;
    if (std.mem.eql(u8, u, "VOLATILE")) return .keyword;
    if (std.mem.eql(u8, u, "NOALIAS")) return .keyword;
    if (std.mem.eql(u8, u, "ALIGN")) return .keyword;
    if (std.mem.eql(u8, u, "LINKSECTION")) return .keyword;
    if (std.mem.eql(u8, u, "CALLCONV")) return .keyword;

    // Primitive types
    if (std.mem.eql(u8, u, "BOOL")) return .type_keyword;
    if (std.mem.eql(u8, u, "TRUE")) return .keyword;
    if (std.mem.eql(u8, u, "FALSE")) return .keyword;
    if (std.mem.eql(u8, u, "NULL")) return .keyword;
    if (std.mem.eql(u8, u, "UNDEFINED")) return .keyword;
    if (std.mem.eql(u8, u, "VOID")) return .type_keyword;
    if (std.mem.eql(u8, u, "NORETURN")) return .type_keyword;

    // Integer types (i8, u8, i16, u16, etc.)
    if (len >= 2 and (u[0] == 'I' or u[0] == 'U') and isDigit(u[1])) {
        return .type_keyword;
    }
    if (std.mem.eql(u8, u, "ISIZE")) return .type_keyword;
    if (std.mem.eql(u8, u, "USIZE")) return .type_keyword;
    if (std.mem.eql(u8, u, "C_SHORT")) return .type_keyword;
    if (std.mem.eql(u8, u, "C_USHORT")) return .type_keyword;
    if (std.mem.eql(u8, u, "C_INT")) return .type_keyword;
    if (std.mem.eql(u8, u, "C_UINT")) return .type_keyword;
    if (std.mem.eql(u8, u, "C_LONG")) return .type_keyword;
    if (std.mem.eql(u8, u, "C_ULONG")) return .type_keyword;
    if (std.mem.eql(u8, u, "C_LONGLONG")) return .type_keyword;
    if (std.mem.eql(u8, u, "C_ULONGLONG")) return .type_keyword;

    // Float types
    if (std.mem.eql(u8, u, "F16")) return .type_keyword;
    if (std.mem.eql(u8, u, "F32")) return .type_keyword;
    if (std.mem.eql(u8, u, "F64")) return .type_keyword;
    if (std.mem.eql(u8, u, "F80")) return .type_keyword;
    if (std.mem.eql(u8, u, "F128")) return .type_keyword;

    return .default;
}

// ─── Frame Building ─────────────────────────────────────────────────────────

fn buildFrame(state: *EditorState, dt: f64) EdFrameData {
    state.time += dt;

    // Smart assist: tick debounce, submit, drain tokens.
    saTickAndDrain(state, dt);

    // Cursor blink logic
    state.cursor_blink_timer += dt;
    const blink_period = CURSOR_BLINK_ON + CURSOR_BLINK_OFF;
    if (state.cursor_blink_timer > blink_period) {
        state.cursor_blink_timer -= blink_period;
    }
    state.cursor_visible = state.cursor_blink_timer < CURSOR_BLINK_ON;

    // Ensure symbol index (and keyword-shadow warnings) are up-to-date before rendering.
    // This is a no-op when symbols_dirty is false (just a boolean check).
    state.ensureSymbols();

    const theme = state.currentTheme();
    const atlas = state.atlas;

    if (atlas.cell_width <= 0 or atlas.cell_height <= 0) {
        // Atlas not initialised yet — return empty frame with clear colour
        const bg = theme.editor_bg.toFloat4();
        return EdFrameData{
            .instances = null,
            .instance_count = 0,
            ._pad0 = 0,
            .uniforms = EdUniforms{
                .viewport_width = 0,
                .viewport_height = 0,
                .cell_width = 0,
                .cell_height = 0,
                .atlas_width = 0,
                .atlas_height = 0,
                .time = 0,
                .effects_mode = 0,
            },
            .clear_r = bg[0],
            .clear_g = bg[1],
            .clear_b = bg[2],
            .clear_a = bg[3],
        };
    }

    var instance_count: u32 = 0;
    const instances = state.instances;

    const gutter_px = @as(f32, @floatFromInt(GUTTER_CHARS)) * atlas.cell_width;
    const vis_lines = state.visibleLines();
    const vis_cols = state.visibleCols();
    const cursor_lc = state.cursorLineCol();
    const sel = state.selectionRange();

    // Find matching bracket for highlight
    const matching_bracket: ?usize = blk: {
        // Check char at cursor
        if (state.findMatchingBracket(state.cursor)) |m| break :blk m;
        // Check char before cursor
        if (state.cursor > 0) {
            if (state.findMatchingBracket(state.cursor - 1)) |m| break :blk m;
        }
        break :blk null;
    };
    // The bracket position near the cursor (the one that triggered the match)
    const bracket_origin: ?usize = blk: {
        if (state.findMatchingBracket(state.cursor) != null) break :blk state.cursor;
        if (state.cursor > 0) {
            if (state.findMatchingBracket(state.cursor - 1) != null) break :blk state.cursor - 1;
        }
        break :blk null;
    };

    // ── Render editor lines ─────────────────────────────────────────────

    // Warm syntax state (triple-quoted strings) from file start up to first visible line
    var syntax_state = SyntaxState{};
    const first_visible = state.screenRowToBufferLine(0) orelse 0;
    var warm_line: usize = 0;
    while (warm_line < first_visible and warm_line < state.buffer.lineCount()) : (warm_line += 1) {
        const ld = state.buffer.getLine(warm_line) catch continue;
        defer state.allocator.free(ld);
        const warm_cats = highlightLine(state.allocator, ld, state.file_path, &syntax_state) catch continue;
        state.allocator.free(warm_cats);
    }

    for (0..vis_lines) |vi| {
        const line_idx = state.screenRowToBufferLine(vi) orelse break;
        if (line_idx >= state.buffer.lineCount()) break;

        const screen_y = @as(f32, @floatFromInt(vi)) * atlas.cell_height;

        // ── Check error/warning status for this line ────────────────────
        const line_has_error = state.lineHasError(line_idx);
        const line_has_warning = !line_has_error and state.lineHasWarning(line_idx);

        // ── Line number gutter ──────────────────────────────────────────
        {
            // Fold indicator detection for this line
            const is_fold_start = state.isFoldStart(line_idx);
            const line_foldable = blk: {
                if (is_fold_start) break :blk true;
                // Check if line starts a foldable block (not currently folded)
                const ld = state.buffer.getLine(line_idx) catch break :blk false;
                defer state.allocator.free(ld);
                break :blk foldableKeyword(ld) != null;
            };

            var line_num_buf: [16]u8 = undefined;
            const line_num_str = std.fmt.bufPrint(&line_num_buf, "{d: >5}  ", .{line_idx + 1}) catch "?????  ";

            for (line_num_str, 0..) |ch, ci| {
                if (instance_count >= MAX_INSTANCES) break;

                // Error/warning gutter marker: show a red/yellow dot in the
                // last gutter column (the space after the line number)
                var gutter_ch = @as(u32, ch);
                var gutter_fg = theme.gutter_fg;
                var gutter_bg = if (line_idx == cursor_lc.line) theme.current_line_bg.darken(0.1) else theme.gutter_bg;

                if (ci == 5) {
                    // Fold indicator column
                    if (is_fold_start) {
                        gutter_ch = '>'; // collapsed fold
                        gutter_fg = theme.syntaxColour(.comment); // subtle colour
                    } else if (line_foldable) {
                        gutter_ch = 'v'; // can be folded
                        gutter_fg = theme.gutter_fg.darken(0.3); // very subtle
                    }
                } else if (ci == GUTTER_CHARS - 1) {
                    // Last gutter column — show error/warning marker
                    if (line_has_error) {
                        gutter_ch = @as(u32, '\xe2'); // We can't use multi-byte — use ASCII marker
                        gutter_ch = '!';
                        gutter_fg = theme.error_underline;
                        gutter_bg = theme.error_underline.darken(0.7);
                    } else if (line_has_warning) {
                        gutter_ch = '!';
                        gutter_fg = theme.warning_underline;
                        gutter_bg = theme.warning_underline.darken(0.7);
                    }
                } else if (line_has_error) {
                    gutter_bg = theme.error_underline.darken(0.8);
                } else if (line_has_warning) {
                    gutter_bg = theme.warning_underline.darken(0.8);
                }

                const uv = platform.codepointToAtlasUV(gutter_ch, atlas);

                instances[instance_count] = GlyphInstance.make(
                    @as(f32, @floatFromInt(ci)) * atlas.cell_width,
                    screen_y,
                    uv.u,
                    uv.v,
                    gutter_fg,
                    gutter_bg,
                    0,
                );
                instance_count += 1;
            }
        }

        // ── Line text ───────────────────────────────────────────────────
        const line_data = state.buffer.getLine(line_idx) catch continue;
        defer state.allocator.free(line_data);

        const syntax = highlightLine(state.allocator, line_data, state.file_path, &syntax_state) catch continue;
        defer state.allocator.free(syntax);

        // Sprite ROW pixel bg/fg overrides (null when line is not SPRITE ROW)
        const sprite_px = spriteRowPixelBgs(state.allocator, line_data) catch null;
        defer if (sprite_px) |sp| state.allocator.free(sp);

        // Calculate selection range for this line (in buffer offsets)
        const line_range = state.buffer.lineRange(line_idx) orelse continue;

        for (0..vis_cols) |vc| {
            if (instance_count >= MAX_INSTANCES) break;

            const col_idx = state.scroll_col + vc;
            const screen_x = gutter_px + @as(f32, @floatFromInt(vc)) * atlas.cell_width;

            var cp: u32 = ' ';
            var cat: SyntaxCategory = .default;

            if (col_idx < line_data.len) {
                cp = line_data[col_idx];
                cat = syntax[col_idx];
            }

            // Handle tab rendering
            if (cp == '\t') cp = ' ';
            // Don't render control characters
            if (cp < 0x20 and cp != '\t') cp = ' ';

            var fg = theme.syntaxColour(cat);
            var bg = if (line_idx == cursor_lc.line) theme.current_line_bg else theme.editor_bg;
            var flags: u32 = 0;

            // Error/warning line background tinting
            // blend() uses self.a as the blend factor: self over other
            if (line_has_error) {
                const tint = Colour.rgba(theme.error_underline.r, theme.error_underline.g, theme.error_underline.b, 30);
                bg = tint.blend(bg);
            } else if (line_has_warning) {
                const tint = Colour.rgba(theme.warning_underline.r, theme.warning_underline.g, theme.warning_underline.b, 20);
                bg = tint.blend(bg);
            }

            // Only calculate buffer offset for actual line content (not spaces beyond end of line)
            // to prevent selection/highlight bleed from subsequent lines when horizontally scrolled
            if (col_idx < line_data.len) {
                const buf_offset = line_range.start + col_idx;

                // Sprite ROW pixel background colouring
                if (sprite_px) |sp| {
                    if (sp[col_idx].bg) |pbg| bg = pbg;
                    if (sp[col_idx].fg) |pfg| fg = pfg;
                }

                // Bracket matching highlight
                if (matching_bracket) |mb| {
                    if (buf_offset == mb or (bracket_origin != null and buf_offset == bracket_origin.?)) {
                        bg = theme.match_bg.darken(0.1);
                        flags |= GlyphInstance.FLAG_BOLD;
                    }
                }

                // Inline rename highlighting
                if (state.rename_state.visible) {
                    const r_primary = state.rename_state.primary_offset;
                    const r_word_len = state.rename_state.currentWordLen(&state.buffer);
                    const r_end = r_primary + r_word_len;

                    // Primary occurrence: boxed in rename_bg
                    if (buf_offset >= r_primary and buf_offset < r_end) {
                        bg = theme.rename_bg;
                    }

                    // Other occurrences: adjust for delta from primary edit
                    if (state.rename_state.old_name_len > 0) {
                        const old_len = state.rename_state.old_name_len;
                        const delta: isize = @as(isize, @intCast(r_word_len)) - @as(isize, @intCast(old_len));
                        for (state.rename_state.matches.items) |match_pos| {
                            // Adjust offset for matches after the primary
                            var adj_pos = match_pos;
                            if (match_pos > r_primary) {
                                if (delta >= 0) {
                                    adj_pos += @as(usize, @intCast(delta));
                                } else {
                                    const neg = @as(usize, @intCast(-delta));
                                    if (adj_pos >= neg) {
                                        adj_pos -= neg;
                                    }
                                }
                            }
                            if (buf_offset >= adj_pos and buf_offset < adj_pos + old_len) {
                                bg = theme.rename_bg.lighten(0.08);
                                break;
                            }
                        }
                    }
                }

                // Search match highlighting (behind selection so selection takes priority)
                if (state.find_state.visible and state.find_state.query_len > 0) {
                    for (state.find_state.matches.items, 0..) |match_pos, match_idx| {
                        if (buf_offset >= match_pos and buf_offset < match_pos + state.find_state.query_len) {
                            // Current match gets a brighter highlight
                            if (state.find_state.current_match) |cm| {
                                if (match_idx == cm) {
                                    bg = theme.match_bg;
                                    fg = Colour.hex(0x000000);
                                } else {
                                    bg = theme.match_bg.darken(0.3);
                                    fg = Colour.hex(0x000000);
                                }
                            } else {
                                bg = theme.match_bg.darken(0.3);
                                fg = Colour.hex(0x000000);
                            }
                            break;
                        }
                        // Early exit: matches are sorted, skip if past this line
                        if (match_pos > line_range.start + line_data.len) break;
                    }
                }

                // Selection highlight (overrides match highlight)
                if (sel) |s| {
                    if (buf_offset >= s.start and buf_offset < s.end) {
                        bg = theme.selection_bg;
                        fg = theme.selection_fg;
                        flags |= GlyphInstance.FLAG_SELECTION;
                    }
                }
            }

            // Cursor
            if (line_idx == cursor_lc.line and col_idx == cursor_lc.col and
                state.window_focused and state.cursor_visible)
            {
                flags |= GlyphInstance.FLAG_CURSOR;
            }

            const uv = platform.codepointToAtlasUV(cp, atlas);

            instances[instance_count] = GlyphInstance.make(
                screen_x,
                screen_y,
                uv.u,
                uv.v,
                fg,
                bg,
                flags,
            );
            instance_count += 1;
        }
    }

    // ── Render ghost text (smart assist completion) ──────────────────────
    if (state.sa_ghost.items.len > 0 and state.focus == .editor) {
        saRenderGhost(state, instances, &instance_count, atlas, theme, .{ .line = cursor_lc.line, .col = cursor_lc.col }, gutter_px, vis_lines, vis_cols);
    }

    // ── Render scrollbar ────────────────────────────────────────────────
    {
        const total_lines = state.totalVisibleLines();
        const sb_x = state.viewport_width - SCROLLBAR_WIDTH;
        const space_uv = platform.codepointToAtlasUV(' ', atlas);

        // Editor area height: from top to divider (or status bar if no terminal)
        const editor_area_h: f32 = if (state.dividerY()) |dy| dy else blk: {
            const status_h = @as(f32, @floatFromInt(STATUS_BAR_LINES)) * atlas.cell_height;
            break :blk state.viewport_height - status_h;
        };

        // Number of cell rows that fit in the editor area
        const row_count: usize = if (atlas.cell_height > 0)
            @intFromFloat(@floor(editor_area_h / atlas.cell_height))
        else
            0;

        if (row_count > 0 and total_lines > 0) {
            // Thumb geometry (in fractional rows)
            const total_f: f32 = @floatFromInt(total_lines);
            const vis_f: f32 = @floatFromInt(vis_lines);
            const rows_f: f32 = @floatFromInt(row_count);
            const thumb_ratio = @min(vis_f / total_f, 1.0);
            const thumb_rows_f = @max(thumb_ratio * rows_f, 2.0); // min 2 rows
            const scroll_f: f32 = @floatFromInt(state.scroll_line);
            const scroll_ratio = scroll_f / @max(total_f - vis_f, 1.0);
            const thumb_start_f = scroll_ratio * (rows_f - thumb_rows_f);
            const thumb_start: usize = @intFromFloat(@max(thumb_start_f, 0));
            const thumb_end: usize = @min(
                @as(usize, @intFromFloat(@ceil(thumb_start_f + thumb_rows_f))),
                row_count,
            );

            // Render each row of the scrollbar
            for (0..row_count) |ri| {
                if (instance_count >= MAX_INSTANCES) break;

                const row_y = @as(f32, @floatFromInt(ri)) * atlas.cell_height;
                const in_thumb = (ri >= thumb_start and ri < thumb_end);

                // Check for error/warning markers at this proportional position
                const proportional_line: usize = @intFromFloat(
                    @as(f32, @floatFromInt(ri)) / rows_f * total_f,
                );
                const has_error = state.lineHasError(proportional_line);
                const has_warning = !has_error and state.lineHasWarning(proportional_line);

                const bar_colour = if (has_error)
                    theme.error_underline
                else if (has_warning)
                    theme.warning_underline
                else if (in_thumb)
                    theme.scrollbar_thumb
                else
                    theme.scrollbar_track;

                instances[instance_count] = GlyphInstance.make(
                    sb_x,
                    row_y,
                    space_uv.u,
                    space_uv.v,
                    bar_colour,
                    bar_colour,
                    0,
                );
                instance_count += 1;
            }
        }
    }

    // ── Render status bar ───────────────────────────────────────────────
    {
        const status_y = state.viewport_height - atlas.cell_height;
        const status_cols = @as(usize, @intFromFloat(@floor(state.viewport_width / atlas.cell_width)));

        // Build status text
        var status_buf: [512]u8 = undefined;
        const lc = state.cursorLineCol();
        const mod_indicator: []const u8 = if (state.modified) " [modified]" else "";
        const file_name: []const u8 = if (state.file_path) |p| p else "untitled.baz";
        const theme_name = state.theme_id.name();

        const case_indicator: []const u8 = if (state.find_state.case_insensitive) "Aa" else "AA";

        // Count warnings and errors for the status bar indicator
        var warning_count: usize = 0;
        var error_count: usize = 0;
        for (state.error_lines.items) |eli| {
            if (eli.is_warning) {
                warning_count += 1;
            } else {
                error_count += 1;
            }
        }

        // Check if the cursor is on a line with a warning/error and grab the message
        var cursor_diag_msg: []const u8 = "";
        for (state.error_lines.items) |*eli| {
            if (eli.line == lc.line) {
                cursor_diag_msg = eli.message();
                break;
            }
        }

        // Build the diagnostic indicator suffix
        var diag_buf: [80]u8 = undefined;
        const diag_indicator: []const u8 = if (error_count > 0 and warning_count > 0)
            std.fmt.bufPrint(&diag_buf, "  |  {d} err, {d} warn", .{ error_count, warning_count }) catch ""
        else if (error_count > 0)
            std.fmt.bufPrint(&diag_buf, "  |  {d} err", .{error_count}) catch ""
        else if (warning_count > 0)
            std.fmt.bufPrint(&diag_buf, "  |  {d} warn", .{warning_count}) catch ""
        else
            "";

        const status_text = if (cursor_diag_msg.len > 0)
            std.fmt.bufPrint(&status_buf, " Ln {d: >5}, Col {d: >3}  |  {s}  |  {d} lines  |  {s}{s}  |  {s}  |  [{s}]{s}  |  {s}", .{
                lc.line + 1,
                lc.col + 1,
                "UTF-32",
                state.buffer.lineCount(),
                file_name,
                mod_indicator,
                theme_name,
                case_indicator,
                diag_indicator,
                cursor_diag_msg,
            }) catch " Ed "
        else
            std.fmt.bufPrint(&status_buf, " Ln {d: >5}, Col {d: >3}  |  {s}  |  {d} lines  |  {s}{s}  |  {s}  |  [{s}]{s}", .{
                lc.line + 1,
                lc.col + 1,
                "UTF-32",
                state.buffer.lineCount(),
                file_name,
                mod_indicator,
                theme_name,
                case_indicator,
                diag_indicator,
            }) catch " Ed ";

        for (0..status_cols) |ci| {
            if (instance_count >= MAX_INSTANCES) break;

            const ch: u32 = if (ci < status_text.len) @as(u32, status_text[ci]) else ' ';
            const uv = platform.codepointToAtlasUV(ch, atlas);

            // Tint the status bar when the cursor is on a diagnostic line
            const sb_fg = if (cursor_diag_msg.len > 0 and error_count > 0)
                theme.status_fg
            else if (cursor_diag_msg.len > 0 and warning_count > 0)
                theme.warning_underline
            else
                theme.status_fg;

            const sb_bg = if (cursor_diag_msg.len > 0 and error_count > 0)
                theme.error_underline.darken(0.6)
            else
                theme.status_bg;

            instances[instance_count] = GlyphInstance.make(
                @as(f32, @floatFromInt(ci)) * atlas.cell_width,
                status_y,
                uv.u,
                uv.v,
                sb_fg,
                sb_bg,
                0,
            );
            instance_count += 1;
        }
    }

    // ── Render find bar ─────────────────────────────────────────────────
    if (state.find_state.visible) {
        // Layout from bottom: status bar, then replace bar (if visible), then find bar.
        const replace_bar_y: f32 = if (state.find_state.replace_visible)
            state.viewport_height - atlas.cell_height * 2.0
        else
            0;
        const actual_find_bar_y: f32 = if (state.find_state.replace_visible)
            state.viewport_height - atlas.cell_height * 3.0
        else
            state.viewport_height - atlas.cell_height * 2.0;

        const find_cols = @as(usize, @intFromFloat(@floor(state.viewport_width / atlas.cell_width)));

        // Build find bar text: "Find: <query>  (N/M matches)"
        var find_display_buf: [512]u8 = undefined;
        const match_count = state.find_state.matches.items.len;
        const current_str = if (state.find_state.current_match) |cm| cm + 1 else @as(usize, 0);

        // Convert query to ASCII for status display
        var query_ascii: [FIND_MAX_LEN]u8 = undefined;
        for (state.find_state.querySlice(), 0..) |qcp, qi| {
            query_ascii[qi] = if (qcp < 128) @intCast(qcp) else '?';
        }
        const query_str = query_ascii[0..state.find_state.query_len];

        const find_text = if (match_count > 0)
            std.fmt.bufPrint(&find_display_buf, " Find: {s}  ({d}/{d} matches)", .{
                query_str, current_str, match_count,
            }) catch " Find: "
        else if (state.find_state.query_len > 0)
            std.fmt.bufPrint(&find_display_buf, " Find: {s}  (no matches)", .{query_str}) catch " Find: "
        else
            std.fmt.bufPrint(&find_display_buf, " Find: ", .{}) catch " Find: ";

        for (0..find_cols) |ci| {
            if (instance_count >= MAX_INSTANCES) break;

            var ch: u32 = ' ';
            var fg_col = theme.find_bar_fg;
            var f: u32 = 0;

            if (ci < find_text.len) {
                ch = @as(u32, find_text[ci]);
            }

            // Show cursor in the find bar at the end of the query
            const cursor_pos = 7 + state.find_state.query_len; // "  Find: " is 7 chars
            if (ci == cursor_pos and state.focus == .find_bar and state.cursor_visible) {
                f |= GlyphInstance.FLAG_CURSOR;
                fg_col = theme.find_bar_fg;
            }

            const uv = platform.codepointToAtlasUV(ch, atlas);

            instances[instance_count] = GlyphInstance.make(
                @as(f32, @floatFromInt(ci)) * atlas.cell_width,
                actual_find_bar_y,
                uv.u,
                uv.v,
                fg_col,
                theme.find_bar_bg,
                f,
            );
            instance_count += 1;
        }

        // ── Render replace bar ──────────────────────────────────────────
        if (state.find_state.replace_visible) {
            var replace_display_buf: [512]u8 = undefined;

            // Convert replace text to ASCII for display
            var replace_ascii: [FIND_MAX_LEN]u8 = undefined;
            for (state.find_state.replaceSlice(), 0..) |rcp, ri| {
                replace_ascii[ri] = if (rcp < 128) @intCast(rcp) else '?';
            }
            const replace_str = replace_ascii[0..state.find_state.replace_len];

            const replace_text = std.fmt.bufPrint(&replace_display_buf, " Replace: {s}", .{
                replace_str,
            }) catch " Replace: ";

            for (0..find_cols) |ci| {
                if (instance_count >= MAX_INSTANCES) break;

                var ch: u32 = ' ';
                var fg_col = theme.find_bar_fg;
                var f: u32 = 0;

                if (ci < replace_text.len) {
                    ch = @as(u32, replace_text[ci]);
                }

                // Show cursor in the replace bar at the end of the replace text
                const rep_cursor_pos = 10 + state.find_state.replace_len; // " Replace: " is 10 chars
                if (ci == rep_cursor_pos and state.focus == .replace_bar and state.cursor_visible) {
                    f |= GlyphInstance.FLAG_CURSOR;
                    fg_col = theme.find_bar_fg;
                }

                const uv = platform.codepointToAtlasUV(ch, atlas);

                instances[instance_count] = GlyphInstance.make(
                    @as(f32, @floatFromInt(ci)) * atlas.cell_width,
                    replace_bar_y,
                    uv.u,
                    uv.v,
                    fg_col,
                    theme.find_bar_bg.lighten(0.05),
                    f,
                );
                instance_count += 1;
            }
        }
    }

    // ── Render terminal pane ────────────────────────────────────────────
    if (state.terminal_visible) {
        // Drain any output from the ring buffer (thread-safe JIT output)
        state.terminal.drainOutputRing();

        // If CLS just cleared the terminal, reset scroll to bottom
        if (state.terminal.scrollbackLineCount() == 0 and state.terminal_scroll_offset > 0) {
            state.terminal_scroll_offset = 0;
            state.terminal_pinned_to_bottom = true;
        }

        // Check if the JIT runner has finished
        if (state.jit_runner.getState() == .finished) {
            const is_build = state.jit_runner.is_build;
            const is_analyse = state.jit_runner.is_analyse;
            const is_show_asm = state.jit_runner.is_show_asm;
            const is_show_ir = state.jit_runner.is_show_ir;

            // Capture error diagnostics BEFORE collectResult (infos survive until next run)
            state.populateErrorLines();

            if (state.jit_runner.collectResult()) |r| {
                if (r.was_stopped) {
                    state.terminalPrint("[Stopped]\r\n") catch {};
                } else if (is_show_ir) {
                    // View IR completion — IR text was already written to terminal by the thread
                    if (r.completed and r.exit_code == 0) {
                        var buf: [256]u8 = undefined;
                        var dur_buf: [32]u8 = undefined;
                        const msg = std.fmt.bufPrint(&buf, "[View IR complete]  {s}\r\n", .{formatDurationSeconds(&dur_buf, r.compile_ms)}) catch "[View IR complete]\r\n";
                        state.terminalPrint(msg) catch {};
                    } else if (r.error_count > 0) {
                        var buf: [128]u8 = undefined;
                        const msg = std.fmt.bufPrint(&buf, "[View IR failed \xe2\x80\x94 {d} error(s)]\r\n", .{r.error_count}) catch "[View IR failed]\r\n";
                        state.terminalPrint(msg) catch {};
                        state.jumpToFirstError();
                    } else {
                        state.terminalPrint("[View IR failed]\r\n") catch {};
                    }
                } else if (is_show_asm) {
                    // Show Assembly completion — disassembly was already written to terminal by the thread
                    if (r.completed and r.exit_code == 0) {
                        var buf: [256]u8 = undefined;
                        var dur_buf: [32]u8 = undefined;
                        const msg = std.fmt.bufPrint(&buf, "[Assembly complete]  {s}\r\n", .{formatDurationSeconds(&dur_buf, r.compile_ms)}) catch "[Assembly complete]\r\n";
                        state.terminalPrint(msg) catch {};
                    } else if (r.error_count > 0) {
                        var buf: [128]u8 = undefined;
                        const msg = std.fmt.bufPrint(&buf, "[Assembly failed \xe2\x80\x94 {d} error(s)]\r\n", .{r.error_count}) catch "[Assembly failed]\r\n";
                        state.terminalPrint(msg) catch {};
                        state.jumpToFirstError();
                    } else {
                        state.terminalPrint("[Assembly failed]\r\n") catch {};
                    }
                } else if (is_analyse) {
                    // Analyse completion — report was already written to terminal by the thread

                    // ── Append keyword shadow warnings to the analyse report ──
                    // The symbol index was rebuilt at the top of buildFrame via
                    // ensureSymbols(), so warnings are current.
                    state.printKeywordShadowReport();

                    if (r.completed and r.exit_code == 0) {
                        var buf: [256]u8 = undefined;
                        var dur_buf: [32]u8 = undefined;
                        const warn_count = state.symbol_index.warnings.items.len;
                        if (warn_count > 0) {
                            const msg = std.fmt.bufPrint(&buf, "[Analysis complete — {d} keyword shadow warning(s)]  {s}\r\n", .{ warn_count, formatDurationSeconds(&dur_buf, r.compile_ms) }) catch "[Analysis complete]\r\n";
                            state.terminalPrint(msg) catch {};
                        } else {
                            const msg = std.fmt.bufPrint(&buf, "[Analysis complete]  {s}\r\n", .{formatDurationSeconds(&dur_buf, r.compile_ms)}) catch "[Analysis complete]\r\n";
                            state.terminalPrint(msg) catch {};
                        }
                    } else if (r.error_count > 0) {
                        var buf: [128]u8 = undefined;
                        const msg = std.fmt.bufPrint(&buf, "[Analysis failed \xe2\x80\x94 {d} error(s)]\r\n", .{r.error_count}) catch "[Analysis failed]\r\n";
                        state.terminalPrint(msg) catch {};
                        state.jumpToFirstError();
                    } else {
                        state.terminalPrint("[Analysis failed]\r\n") catch {};
                    }
                } else if (is_build) {
                    // AOT Build completion
                    const build_label = if (state.jit_runner.build_outputs_app) "Build App" else "Build";
                    if (r.completed and r.exit_code == 0) {
                        var buf: [256]u8 = undefined;
                        var dur_buf: [32]u8 = undefined;
                        const msg = std.fmt.bufPrint(&buf, "[{s} succeeded]  {s}\r\n", .{ build_label, formatDurationSeconds(&dur_buf, r.compile_ms) }) catch "[Build succeeded]\r\n";
                        state.terminalPrint(msg) catch {};
                    } else if (r.error_count > 0) {
                        var buf: [128]u8 = undefined;
                        const msg = std.fmt.bufPrint(&buf, "[{s} failed \xe2\x80\x94 {d} error(s)]\r\n", .{ build_label, r.error_count }) catch "[Build failed]\r\n";
                        state.terminalPrint(msg) catch {};
                        // Jump to first error
                        state.jumpToFirstError();
                    } else {
                        state.terminalPrint(if (state.jit_runner.build_outputs_app) "[Build App failed]\r\n" else "[Build failed]\r\n") catch {};
                    }
                } else {
                    // JIT Run completion
                    if (r.completed and r.exit_code == 0) {
                        var buf: [256]u8 = undefined;
                        var compile_buf: [32]u8 = undefined;
                        var exec_buf: [32]u8 = undefined;
                        const msg = std.fmt.bufPrint(&buf, "[Program finished]  compile & build={s}  exec={s}\r\n", .{ formatDurationSeconds(&compile_buf, r.compile_ms), formatDurationSeconds(&exec_buf, r.exec_ms) }) catch "[Program finished]\r\n";
                        state.terminalPrint(msg) catch {};
                    } else if (r.completed) {
                        var buf: [256]u8 = undefined;
                        var compile_buf: [32]u8 = undefined;
                        var exec_buf: [32]u8 = undefined;
                        const msg = std.fmt.bufPrint(&buf, "[Program exited with code {d}]  compile & build={s}  exec={s}\r\n", .{ r.exit_code, formatDurationSeconds(&compile_buf, r.compile_ms), formatDurationSeconds(&exec_buf, r.exec_ms) }) catch "[Program exited]\r\n";
                        state.terminalPrint(msg) catch {};
                    } else if (r.error_count > 0) {
                        var buf: [128]u8 = undefined;
                        const msg = std.fmt.bufPrint(&buf, "[Compilation failed \xe2\x80\x94 {d} error(s)]\r\n", .{r.error_count}) catch "[Compilation failed]\r\n";
                        state.terminalPrint(msg) catch {};
                        // Jump cursor to the first error line
                        state.jumpToFirstError();
                    } else {
                        state.terminalPrint("[Program did not complete]\r\n") catch {};
                    }
                }
            }
        }

        // Auto-scroll to bottom when pinned and new output arrives
        if (state.terminal_pinned_to_bottom) {
            state.terminal_scroll_offset = 0;
        }

        var chrome_offset: f32 = atlas.cell_height; // status bar
        if (state.find_state.visible) chrome_offset += atlas.cell_height;
        if (state.find_state.replace_visible) chrome_offset += atlas.cell_height;
        const term_start_y = state.viewport_height - chrome_offset -
            @as(f32, @floatFromInt(state.terminal_lines)) * atlas.cell_height;
        const term_cols = @as(usize, @intFromFloat(@floor(state.viewport_width / atlas.cell_width)));

        // Divider line — show scroll indicator if scrolled up
        if (instance_count + term_cols < MAX_INSTANCES) {
            // Build divider text
            var div_buf: [128]u8 = undefined;
            // Build divider text with fullscreen toggle sigil on right edge
            const fs_sigil: []const u8 = if (state.terminal_fullscreen) " [v] " else " [^] ";

            const div_text = if (state.jit_runner.isRunning())
                (if (state.terminal_scroll_offset > 0)
                    std.fmt.bufPrint(&div_buf, "--- [RUNNING] type here for INPUT ({d} lines above) ---", .{state.terminal_scroll_offset}) catch "--- [RUNNING] ---"
                else
                    @as([]const u8, "--- [RUNNING] type here for INPUT ---"))
            else if (state.jit_runner.getState() == .compiling)
                @as([]const u8, "--- [COMPILING...] ---")
            else if (state.terminal_scroll_offset > 0)
                std.fmt.bufPrint(&div_buf, "--- terminal ({d} lines above) ---", .{state.terminal_scroll_offset}) catch "--- terminal ---"
            else
                @as([]const u8, "--- terminal ---");

            // Sigil position: right-aligned on the divider
            const sigil_start = if (term_cols > fs_sigil.len) term_cols - fs_sigil.len else 0;

            for (0..term_cols) |ci| {
                const sigil_offset = if (ci >= sigil_start) ci - sigil_start else fs_sigil.len;
                const disp_ch: u32 = if (sigil_offset < fs_sigil.len)
                    @as(u32, fs_sigil[sigil_offset])
                else if (ci < div_text.len)
                    @as(u32, div_text[ci])
                else
                    '-';

                // Highlight the sigil chars
                const is_sigil = ci >= sigil_start;
                // Match the scrollbar palette: thumb for text, track for bg.
                const fg_col = if (is_sigil) theme.cursor else theme.scrollbar_thumb;

                const uv = platform.codepointToAtlasUV(disp_ch, atlas);
                instances[instance_count] = GlyphInstance.make(
                    @as(f32, @floatFromInt(ci)) * atlas.cell_width,
                    term_start_y - atlas.cell_height,
                    uv.u,
                    uv.v,
                    fg_col,
                    theme.scrollbar_track,
                    0,
                );
                instance_count += 1;
            }
        }

        // Render terminal — scrollback-aware.
        // The terminal has `scrollbackLineCount` scrollback lines + `rows` live grid lines.
        // We show `terminal_lines` rows.  When scroll_offset=0, we show the bottom
        // (live grid).  When scroll_offset>0, we reach into scrollback history.
        const term_rows = @min(state.terminal_lines, @as(u32, @intCast(state.terminal.rows)));
        const sb_count = state.terminal.scrollbackLineCount();
        const total_term_lines = sb_count + state.terminal.rows;

        for (0..term_rows) |ti| {
            const screen_y = term_start_y + @as(f32, @floatFromInt(ti)) * atlas.cell_height;

            // Map visible row `ti` to the combined scrollback+grid line index.
            // When scroll_offset=0 we show the last `term_rows` lines (the live grid).
            // When scrolled up, we shift the window into scrollback.
            const bottom_line = if (total_term_lines >= state.terminal_scroll_offset)
                total_term_lines - state.terminal_scroll_offset
            else
                0;
            const top_line = if (bottom_line >= term_rows) bottom_line - term_rows else 0;
            const combined_line = top_line + ti;

            for (0..@min(term_cols, state.terminal.cols)) |ci| {
                if (instance_count >= MAX_INSTANCES) break;

                const cell = state.terminal.getScrollbackCell(combined_line, ci);
                var ch = cell.codepoint;

                // Clamp to atlas range
                if (ch < 0x20) ch = ' ';
                if (ch >= state.atlas.first_codepoint + state.atlas.glyph_count) ch = ' ';

                const uv = platform.codepointToAtlasUV(ch, atlas);

                var fg_col = cell.fg;
                var bg_col = cell.bg;
                var term_flags: u32 = 0;

                if (cell.attr.bold) term_flags |= GlyphInstance.FLAG_BOLD;
                if (cell.attr.underline) term_flags |= GlyphInstance.FLAG_UNDERLINE;
                if (cell.attr.strikethrough) term_flags |= GlyphInstance.FLAG_STRIKETHROUGH;

                // Terminal cursor — only show when viewing the live bottom
                if (state.terminal_scroll_offset == 0) {
                    const grid_row = if (combined_line >= sb_count) combined_line - sb_count else combined_line;
                    if (grid_row == state.terminal.cursor_row and ci == state.terminal.cursor_col and
                        state.terminal.cursor_visible and state.focus == .terminal and
                        state.window_focused and state.cursor_visible)
                    {
                        term_flags |= GlyphInstance.FLAG_CURSOR;
                    }
                }

                // Terminal selection highlight
                if (state.termSelRange()) |tsel| {
                    const pos = TermSelPos{ .line = combined_line, .col = ci };
                    const in_sel = if (tsel.start.line == tsel.end.line)
                        // Single-line selection
                        (pos.line == tsel.start.line and pos.col >= tsel.start.col and pos.col < tsel.end.col)
                    else if (pos.line == tsel.start.line)
                        // First line of multi-line selection
                        pos.col >= tsel.start.col
                    else if (pos.line == tsel.end.line)
                        // Last line of multi-line selection
                        pos.col < tsel.end.col
                    else
                        // Middle lines — fully selected
                        (pos.line > tsel.start.line and pos.line < tsel.end.line);

                    if (in_sel) {
                        fg_col = theme.selection_fg;
                        bg_col = theme.selection_bg;
                        term_flags |= GlyphInstance.FLAG_SELECTION;
                    }
                }

                // If cell uses default colours, apply theme colours instead
                if (fg_col.eql(Colour.hex(0xC0C0C0))) fg_col = theme.terminal_fg;
                if (bg_col.eql(Colour.hex(0x000020))) bg_col = theme.terminal_bg;

                instances[instance_count] = GlyphInstance.make(
                    @as(f32, @floatFromInt(ci)) * atlas.cell_width,
                    screen_y,
                    uv.u,
                    uv.v,
                    fg_col,
                    bg_col,
                    term_flags,
                );
                instance_count += 1;
            }
        }
    }

    // ── Render symbol outline overlay ────────────────────────────────────
    if (state.symbol_overlay.visible and state.focus == .symbol_overlay) {
        const ov = &state.symbol_overlay;
        // Overlay dimensions
        const ov_width_chars: usize = 60;
        const ov_visible = @min(@as(usize, ov.item_count), OVERLAY_MAX_VISIBLE);

        // Center horizontally, place below the top of the editor
        const ov_x_start: f32 = (state.viewport_width - @as(f32, @floatFromInt(ov_width_chars)) * atlas.cell_width) / 2.0;
        const ov_y_start: f32 = atlas.cell_height * 2.0; // two lines from top

        // Render filter bar: "  > filter_text"
        {
            var filter_text_buf: [80]u8 = undefined;
            var filter_ascii: [OVERLAY_FILTER_MAX]u8 = undefined;
            for (ov.filterSlice(), 0..) |fcp, fi| {
                filter_ascii[fi] = if (fcp < 128) @intCast(fcp) else '?';
            }
            const filter_str = filter_ascii[0..ov.filter_len];
            const filter_display = std.fmt.bufPrint(&filter_text_buf, " > {s}", .{filter_str}) catch " > ";

            for (0..ov_width_chars) |ci| {
                if (instance_count >= MAX_INSTANCES) break;
                const ch: u32 = if (ci < filter_display.len) @as(u32, filter_display[ci]) else ' ';
                const uv = platform.codepointToAtlasUV(ch, atlas);
                var f: u32 = 0;
                // Show cursor at end of filter text
                if (ci == 3 + ov.filter_len and state.cursor_visible) {
                    f |= GlyphInstance.FLAG_CURSOR;
                }
                instances[instance_count] = GlyphInstance.make(
                    ov_x_start + @as(f32, @floatFromInt(ci)) * atlas.cell_width,
                    ov_y_start,
                    uv.u,
                    uv.v,
                    theme.status_fg,
                    theme.status_bg,
                    f,
                );
                instance_count += 1;
            }
        }

        // Render symbol items
        for (0..ov_visible) |vi| {
            const item_idx = ov.scroll + @as(u16, @intCast(vi));
            if (item_idx >= ov.item_count) break;

            const entry_idx = ov.items[item_idx];
            const entry = &state.symbol_index.entries.items[entry_idx];

            var display_buf: [512]u8 = undefined;
            const display = entry.formatDisplay(&display_buf);

            // Line number suffix
            var line_num_buf: [16]u8 = undefined;
            const line_num_str = std.fmt.bufPrint(&line_num_buf, ":{d}", .{entry.line + 1}) catch "";

            const row_y = ov_y_start + @as(f32, @floatFromInt(vi + 1)) * atlas.cell_height;
            const is_selected = (item_idx == ov.selected);

            const row_bg = if (is_selected) theme.selection_bg else theme.find_bar_bg;
            const row_fg = if (is_selected) theme.selection_fg else theme.find_bar_fg;

            // Kind icon character
            const icon: u8 = switch (entry.kind) {
                .function => 'F',
                .sub => 'S',
                .worker => 'W',
                .type_decl => 'T',
                .class_decl => 'C',
                .constant => '#',
                .label => '@',
                .constructor => '+',
                .destructor => '~',
                .method => 'M',
            };

            for (0..ov_width_chars) |ci| {
                if (instance_count >= MAX_INSTANCES) break;

                var ch: u32 = ' ';
                var fg = row_fg;

                if (ci == 1) {
                    ch = icon;
                    fg = theme.syntaxColour(switch (entry.kind) {
                        .function, .method => .subroutine,
                        .sub => .subroutine,
                        .worker => .worker,
                        .type_decl, .class_decl => .type_keyword,
                        .constant => .number,
                        .label => .keyword,
                        .constructor, .destructor => .subroutine,
                    });
                } else if (ci >= 3 and ci - 3 < display.len) {
                    ch = @as(u32, display[ci - 3]);
                } else if (ci >= ov_width_chars - line_num_str.len and ci - (ov_width_chars - line_num_str.len) < line_num_str.len) {
                    const li = ci - (ov_width_chars - line_num_str.len);
                    ch = @as(u32, line_num_str[li]);
                    fg = theme.gutter_fg;
                }

                const uv = platform.codepointToAtlasUV(ch, atlas);
                instances[instance_count] = GlyphInstance.make(
                    ov_x_start + @as(f32, @floatFromInt(ci)) * atlas.cell_width,
                    row_y,
                    uv.u,
                    uv.v,
                    fg,
                    row_bg,
                    0,
                );
                instance_count += 1;
            }
        }
    }

    // ── Render autocomplete overlay ─────────────────────────────────────
    if (state.autocomplete_overlay.visible and state.focus == .autocomplete) {
        const ov = &state.autocomplete_overlay;
        const ov_width_chars: usize = 40;
        const ov_visible = @min(@as(usize, ov.item_count), OVERLAY_MAX_VISIBLE);

        if (ov_visible > 0) {
            const ov_x = ov.anchor_x;
            // If popup would go below the editor area, show it above the cursor line
            const popup_height = @as(f32, @floatFromInt(ov_visible)) * atlas.cell_height;
            const ov_y = if (ov.anchor_y + popup_height > state.viewport_height - atlas.cell_height * 3.0)
                ov.anchor_y - popup_height - atlas.cell_height
            else
                ov.anchor_y;

            for (0..ov_visible) |vi| {
                const item_idx = ov.scroll + @as(u16, @intCast(vi));
                if (item_idx >= ov.item_count) break;

                const encoded_idx = ov.items[item_idx];

                var display_buf: [512]u8 = undefined;
                const display = state.autocompleteItemText(encoded_idx, &display_buf);

                const row_y = ov_y + @as(f32, @floatFromInt(vi)) * atlas.cell_height;
                const is_selected = (item_idx == ov.selected);

                const row_bg = if (is_selected) theme.selection_bg else theme.find_bar_bg;
                const row_fg = if (is_selected) theme.selection_fg else theme.find_bar_fg;

                // Determine item kind for colouring
                const kind_fg = if (state.dot_mode or state.type_mode) blk: {
                    if (encoded_idx < state.dot_completion_count) {
                        const dc = &state.dot_completions[encoded_idx];
                        break :blk switch (dc.kind) {
                            .method => theme.syntaxColour(.subroutine),
                            .type_name => theme.syntaxColour(.type_keyword),
                            else => theme.syntaxColour(.default),
                        };
                    }
                    break :blk theme.syntaxColour(.default);
                } else blk: {
                    const kw_count: u32 = @intCast(symbols_mod.KEYWORDS.len);
                    const is_keyword_item = encoded_idx < kw_count;
                    break :blk if (is_keyword_item) theme.syntaxColour(.keyword) else theme.syntaxColour(.subroutine);
                };

                for (0..ov_width_chars) |ci| {
                    if (instance_count >= MAX_INSTANCES) break;

                    var ch: u32 = ' ';
                    var fg = row_fg;

                    if (ci >= 1 and ci - 1 < display.len) {
                        ch = @as(u32, display[ci - 1]);
                        // Colour the first word (the name or keyword)
                        if (ci <= display.len and ci < 30) {
                            fg = if (is_selected) theme.selection_fg else kind_fg;
                        }
                    }

                    const uv = platform.codepointToAtlasUV(ch, atlas);
                    instances[instance_count] = GlyphInstance.make(
                        ov_x + @as(f32, @floatFromInt(ci)) * atlas.cell_width,
                        row_y,
                        uv.u,
                        uv.v,
                        fg,
                        row_bg,
                        0,
                    );
                    instance_count += 1;
                }
            }
        }
    }

    // ── Build uniforms and return ────────────────────────────────────────
    const bg = theme.editor_bg.toFloat4();

    return EdFrameData{
        .instances = @ptrCast(instances.ptr),
        .instance_count = instance_count,
        ._pad0 = 0,
        .uniforms = EdUniforms{
            .viewport_width = state.viewport_width,
            .viewport_height = state.viewport_height,
            .cell_width = atlas.cell_width,
            .cell_height = atlas.cell_height,
            .atlas_width = atlas.atlas_width,
            .atlas_height = atlas.atlas_height,
            .time = @floatCast(state.time),
            .effects_mode = @floatFromInt(@intFromEnum(theme.effects)),
        },
        .clear_r = bg[0],
        .clear_g = bg[1],
        .clear_b = bg[2],
        .clear_a = bg[3],
    };
}

// ─── Input Handling ─────────────────────────────────────────────────────────

fn handleKeyDown(state: *EditorState, event: *const KeyEvent) void {
    const mods = event.modifiers;

    // Reset cursor blink on any keypress
    state.cursor_blink_timer = 0;
    state.cursor_visible = true;

    // ── Ctrl+Tab: switch between editor and terminal panes ──────────────
    if (mods.hasCtrl() and !mods.hasCmd() and event.keycode == VK.TAB) {
        // Close any open overlays first
        if (state.symbol_overlay.visible) {
            state.symbol_overlay.close();
        }
        if (state.autocomplete_overlay.visible) {
            state.autocomplete_overlay.close();
        }
        if (state.find_state.visible) {
            state.find_state.visible = false;
            state.find_state.replace_visible = false;
        }
        if (state.rename_state.visible) {
            state.rename_state.close(state.allocator);
        }

        if (state.focus == .terminal) {
            state.focus = .editor;
        } else {
            state.terminal_visible = true;
            state.updateTerminalSize();
            state.focus = .terminal;
        }
        return;
    }

    // ── Symbol outline overlay input handling ────────────────────────────
    if (state.focus == .symbol_overlay and state.symbol_overlay.visible) {
        switch (event.keycode) {
            VK.ESCAPE => {
                state.symbol_overlay.close();
                state.focus = .editor;
                return;
            },
            VK.RETURN => {
                // Jump to the selected symbol
                if (state.symbol_overlay.selectedIndex()) |sel_idx| {
                    const entry = &state.symbol_index.entries.items[sel_idx];
                    state.setCursorLineCol(entry.line, entry.col);
                    state.selection_anchor = null;
                    state.ensureCursorVisible();
                }
                state.symbol_overlay.close();
                state.focus = .editor;
                return;
            },
            VK.UP_ARROW => {
                state.symbol_overlay.moveUp();
                return;
            },
            VK.DOWN_ARROW => {
                state.symbol_overlay.moveDown();
                return;
            },
            VK.DELETE => {
                state.symbol_overlay.deleteFilter();
                state.filterSymbolOverlay();
                return;
            },
            else => {},
        }
        // Don't process other keys — text input will handle typing into the filter
        if (!mods.hasCmd() and !mods.hasCtrl()) {
            return;
        }
    }

    // ── Autocomplete overlay input handling ──────────────────────────────
    if (state.focus == .autocomplete and state.autocomplete_overlay.visible) {
        switch (event.keycode) {
            VK.ESCAPE => {
                state.autocomplete_overlay.close();
                state.dot_mode = false;
                state.type_mode = false;
                state.focus = .editor;
                return;
            },
            VK.RETURN, VK.TAB => {
                // Accept the selected completion
                state.applyAutocomplete();
                return;
            },
            VK.UP_ARROW => {
                state.autocomplete_overlay.moveUp();
                return;
            },
            VK.DOWN_ARROW => {
                state.autocomplete_overlay.moveDown();
                return;
            },
            VK.DELETE => {
                if ((state.dot_mode or state.type_mode) and state.autocomplete_overlay.filter_len == 0) {
                    // In dot/type-mode with nothing typed after the trigger — close overlay.
                    // The trigger char itself will be deleted by the normal backspace handler
                    // after we fall through.
                    state.autocomplete_overlay.close();
                    state.dot_mode = false;
                    state.type_mode = false;
                    state.focus = .editor;
                    // Don't return — let the normal backspace handling delete the char
                } else if (state.autocomplete_overlay.filter_len == 0) {
                    // Normal mode with no filter — just close
                    state.autocomplete_overlay.close();
                    state.focus = .editor;
                    return;
                } else {
                    // Filter has characters — delete from filter and buffer
                    state.autocomplete_overlay.deleteFilter();
                    if (state.cursor > 0) {
                        const del_pos = state.cursor - 1;
                        const ch = state.buffer.charAt(del_pos) orelse return;
                        state.buffer.delete(del_pos, 1) catch return;
                        state.pushUndo(del_pos, &[_]u32{ch}, &.{}) catch {};
                        state.cursor = del_pos;
                        state.modified = true;
                        state.updateTitle();
                    }
                    state.filterAutocomplete();
                    if (state.autocomplete_overlay.filter_len == 0 and !state.dot_mode and !state.type_mode) {
                        state.autocomplete_overlay.close();
                        state.dot_mode = false;
                        state.type_mode = false;
                        state.focus = .editor;
                    } else if (state.dot_mode and state.autocomplete_overlay.filter_len == 0) {
                        // Deleted back to just the dot — show all completions again
                        state.filterDotAutocomplete();
                    } else if (state.type_mode and state.autocomplete_overlay.filter_len == 0) {
                        // Deleted back to just after AS — show all type completions again
                        state.filterTypeAutocomplete();
                    } else if (state.autocomplete_overlay.item_count == 0) {
                        state.autocomplete_overlay.close();
                        state.dot_mode = false;
                        state.type_mode = false;
                        state.focus = .editor;
                    }
                    return;
                }
            },
            else => {},
        }
        // Don't process other keys — text input will handle typing into the filter
        if (!mods.hasCmd() and !mods.hasCtrl()) {
            return;
        }
        // Any Cmd/Ctrl key closes autocomplete and falls through
        state.autocomplete_overlay.close();
        state.dot_mode = false;
        state.type_mode = false;
        state.focus = .editor;
    }

    // ── Inline rename mode handling ─────────────────────────────────────
    if (state.rename_state.visible) {
        const r_primary = state.rename_state.primary_offset;
        const r_word_len = state.rename_state.currentWordLen(&state.buffer);
        const r_end = r_primary + r_word_len;

        switch (event.keycode) {
            VK.ESCAPE => {
                // Revert to old name and close
                state.revertRename();
                return;
            },
            VK.RETURN => {
                // Commit: propagate new name to all other occurrences
                state.applyRename();
                return;
            },
            VK.DELETE => {
                // Backspace — but don't go past the start of the word
                if (state.cursor > r_primary) {
                    const del_pos = state.cursor - 1;
                    const ch = state.buffer.charAt(del_pos) orelse return;
                    state.buffer.delete(del_pos, 1) catch return;
                    state.pushUndo(del_pos, &[_]u32{ch}, &.{}) catch {};
                    state.cursor = del_pos;
                    state.selection_anchor = null;
                    state.modified = true;
                    state.updateTitle();
                }
                return;
            },
            VK.FORWARD_DELETE => {
                // Forward-delete — but don't go past the end of the word
                if (state.cursor < r_end) {
                    const ch = state.buffer.charAt(state.cursor) orelse return;
                    state.buffer.delete(state.cursor, 1) catch return;
                    state.pushUndo(state.cursor, &[_]u32{ch}, &.{}) catch {};
                    state.selection_anchor = null;
                    state.modified = true;
                    state.updateTitle();
                }
                return;
            },
            VK.LEFT_ARROW => {
                // Move left but confine to word start
                if (state.cursor > r_primary) {
                    state.cursor -= 1;
                }
                state.selection_anchor = null;
                return;
            },
            VK.RIGHT_ARROW => {
                // Move right but confine to word end
                if (state.cursor < r_end) {
                    state.cursor += 1;
                }
                state.selection_anchor = null;
                return;
            },
            VK.HOME => {
                state.cursor = r_primary;
                state.selection_anchor = null;
                return;
            },
            VK.END => {
                state.cursor = r_end;
                state.selection_anchor = null;
                return;
            },
            // Block all vertical movement / page keys
            VK.UP_ARROW, VK.DOWN_ARROW, VK.PAGE_UP, VK.PAGE_DOWN => {
                return;
            },
            else => {},
        }
        // Cmd+R again cancels the rename
        if (mods.hasCmd() and event.keycode == VK.R) {
            state.revertRename();
            return;
        }
        // Cmd+A selects the entire word being renamed
        if (mods.hasCmd() and event.keycode == VK.A) {
            state.selection_anchor = r_primary;
            state.cursor = r_end;
            return;
        }
        // Block other Cmd/Ctrl shortcuts during rename (except the above)
        if (mods.hasCmd() or mods.hasCtrl()) {
            return;
        }
        // Don't fall through to normal editor key handling
        return;
    }

    // ── Replace bar input handling (when replace bar has focus) ──────────
    if (state.focus == .replace_bar and state.find_state.replace_visible) {
        switch (event.keycode) {
            VK.ESCAPE => {
                // Close both bars, return focus to editor
                state.find_state.visible = false;
                state.find_state.replace_visible = false;
                state.focus = .editor;
                state.selection_anchor = null;
                return;
            },
            VK.RETURN => {
                // Replace current match and advance to next
                state.replaceCurrent() catch {};
                return;
            },
            VK.DELETE => {
                // Backspace in replace string
                state.find_state.deleteReplaceChar();
                return;
            },
            VK.TAB => {
                // Tab moves focus back to find bar
                state.focus = .find_bar;
                return;
            },
            else => {},
        }

        // Cmd+Shift+Return: replace all
        if (mods.hasCmd() and event.keycode == VK.RETURN) {
            state.replaceAll() catch {};
            return;
        }

        // Cmd+G / Cmd+Shift+G
        if (mods.hasCmd() and event.keycode == VK.G) {
            if (mods.hasShift()) {
                state.findPrev();
            } else {
                state.findNext();
            }
            return;
        }

        // Cmd+H again closes
        if (mods.hasCmd() and event.keycode == VK.H) {
            state.find_state.visible = false;
            state.find_state.replace_visible = false;
            state.focus = .editor;
            return;
        }

        // Don't process other keys — text input will handle typing into the replace bar
        if (!mods.hasCmd() and !mods.hasCtrl()) {
            return;
        }
    }

    // ── Find bar input handling (when find bar has focus) ────────────────
    if (state.focus == .find_bar and state.find_state.visible) {
        switch (event.keycode) {
            VK.ESCAPE => {
                // Close find bar (and replace bar), return focus to editor
                state.find_state.visible = false;
                state.find_state.replace_visible = false;
                state.focus = .editor;
                state.selection_anchor = null;
                return;
            },
            VK.RETURN => {
                // If the query looks like a line number (all digits), go to that line
                const query = state.find_state.querySlice();
                var is_line_num = query.len > 0;
                for (query) |qcp| {
                    if (qcp < '0' or qcp > '9') {
                        is_line_num = false;
                        break;
                    }
                }
                if (is_line_num) {
                    // Parse line number from query
                    var line_num: usize = 0;
                    for (query) |qcp| {
                        line_num = line_num * 10 + @as(usize, @intCast(qcp - '0'));
                    }
                    if (line_num > 0) line_num -= 1; // Convert from 1-based to 0-based
                    state.setCursorLineCol(line_num, 0);
                    state.find_state.visible = false;
                    state.find_state.replace_visible = false;
                    state.focus = .editor;
                    state.selection_anchor = null;
                    return;
                }

                // Find next (or find prev with Shift)
                if (mods.hasShift()) {
                    state.findPrev();
                } else {
                    state.findNext();
                }
                return;
            },
            VK.DELETE => {
                // Backspace in find query
                state.find_state.deleteChar();
                state.findUpdateMatches() catch {};
                return;
            },
            VK.TAB => {
                // Tab moves focus to replace bar if visible, otherwise ignore
                if (state.find_state.replace_visible) {
                    state.focus = .replace_bar;
                    return;
                }
            },
            else => {},
        }

        // Cmd+G / Cmd+Shift+G in find bar
        if (mods.hasCmd() and event.keycode == VK.G) {
            if (mods.hasShift()) {
                state.findPrev();
            } else {
                state.findNext();
            }
            return;
        }

        // Cmd+F again closes the find bar
        if (mods.hasCmd() and event.keycode == VK.F) {
            state.find_state.visible = false;
            state.find_state.replace_visible = false;
            state.focus = .editor;
            return;
        }

        // Cmd+H opens the replace bar from find bar
        if (mods.hasCmd() and event.keycode == VK.H) {
            state.find_state.replace_visible = true;
            state.focus = .replace_bar;
            return;
        }

        // Don't process other keys below — text input will handle typing into the find bar
        if (!mods.hasCmd() and !mods.hasCtrl()) {
            return;
        }
    }

    // ── Terminal stdin key handling (when a JIT program is running) ──────
    if (state.focus == .terminal and state.jit_runner.isRunning()) {
        switch (event.keycode) {
            VK.RETURN => {
                // Flush the stdin buffer + newline to the running program
                state.terminal.writeBytes("\r\n");
                if (state.terminal_pinned_to_bottom) {
                    state.terminal_scroll_offset = 0;
                }
                _ = state.jit_runner.flushStdinLine();
                return;
            },
            VK.DELETE => {
                // Backspace — remove last character from stdin buffer and terminal echo
                if (state.jit_runner.stdin_input.backspace()) {
                    // Erase the last character on screen: backspace + space + backspace
                    state.terminal.writeBytes("\x08 \x08");
                    if (state.terminal_pinned_to_bottom) {
                        state.terminal_scroll_offset = 0;
                    }
                }
                return;
            },
            VK.ESCAPE => {
                // Clear the stdin buffer and return focus to editor
                state.jit_runner.stdin_input.clear();
                state.focus = .editor;
                return;
            },
            else => {},
        }

        // Cmd+. (Stop) should still work while in terminal stdin mode
        if (mods.hasCmd() and event.keycode == VK.PERIOD) {
            state.jit_runner.requestStop();
            state.terminalPrint("\r\n  [Stop requested]\r\n") catch {};
            return;
        }

        // Don't process other keys — text input callback handles typing
        // (but let navigation keys fall through to terminal-focused handling below)
        if (!mods.hasCmd() and !mods.hasCtrl()) {
            switch (event.keycode) {
                VK.UP_ARROW, VK.DOWN_ARROW, VK.PAGE_UP, VK.PAGE_DOWN, VK.HOME, VK.END => {},
                else => return,
            }
        }
    }

    // ── Terminal-focused key handling ────────────────────────────────────
    // When the terminal pane has focus (whether or not a program is running),
    // navigation keys control the terminal scrollback, Cmd+A selects all
    // terminal content, and editing keys are blocked so they don't
    // accidentally modify the editor buffer.
    if (state.focus == .terminal) {
        switch (event.keycode) {
            VK.UP_ARROW => {
                state.scrollTerminal(1);
                return;
            },
            VK.DOWN_ARROW => {
                state.scrollTerminal(-1);
                return;
            },
            VK.PAGE_UP => {
                const page: i64 = @intCast(state.terminal_lines);
                state.scrollTerminal(page);
                return;
            },
            VK.PAGE_DOWN => {
                const page: i64 = @intCast(state.terminal_lines);
                state.scrollTerminal(-page);
                return;
            },
            VK.HOME => {
                // Scroll to the very top of the scrollback
                const max_offset = state.terminal.scrollbackLineCount();
                state.terminal_scroll_offset = max_offset;
                state.terminal_pinned_to_bottom = false;
                return;
            },
            VK.END => {
                // Scroll to the bottom (live output)
                state.terminal_scroll_offset = 0;
                state.terminal_pinned_to_bottom = true;
                return;
            },
            VK.ESCAPE => {
                // Clear terminal selection if any, otherwise return to editor
                if (state.termSelRange() != null) {
                    state.clearTermSelection();
                } else {
                    state.focus = .editor;
                }
                return;
            },
            // Block editing keys from modifying the editor buffer
            VK.LEFT_ARROW, VK.RIGHT_ARROW => return,
            VK.DELETE, VK.FORWARD_DELETE, VK.RETURN, VK.TAB => return,
            else => {},
        }

        // Cmd+A → select all terminal content (but let Cmd+Shift+A through for Analyse)
        if (mods.cmdOnly() and event.keycode == VK.A) {
            const total = state.terminal.totalLines();
            state.term_sel_anchor = .{ .line = 0, .col = 0 };
            state.term_sel_end = .{
                .line = if (total > 0) total - 1 else 0,
                .col = state.terminal.cols,
            };
            return;
        }

        // Block editor-specific Cmd commands that make no sense in the terminal
        if (mods.hasCmd()) {
            switch (event.keycode) {
                VK.Z, // Undo / Redo
                VK.D, // Duplicate line
                VK.SLASH, // Toggle comment
                VK.M, // Jump to matching bracket
                => return,
                else => {},
            }
        }

        // Block editor-specific Ctrl commands
        if (mods.hasCtrl() and !mods.hasCmd()) {
            switch (event.keycode) {
                VK.K, // Kill line
                VK.D, // Duplicate line
                => return,
                else => {},
            }
        }

        // Block Alt+arrow line-move commands
        if (mods.hasAlt()) {
            switch (event.keycode) {
                VK.UP_ARROW, VK.DOWN_ARROW => return,
                else => {},
            }
        }

        // Block any remaining unmodified keys from reaching the editor,
        // but let function keys (F1–F12) through so Run/Help/etc. work
        // regardless of which pane has focus.
        if (!mods.hasCmd() and !mods.hasCtrl()) {
            switch (event.keycode) {
                VK.F1, VK.F2, VK.F3, VK.F4, VK.F5, VK.F6, VK.F7, VK.F8, VK.F9, VK.F10, VK.F11, VK.F12 => {}, // fall through
                else => return,
            }
        }

        // Global commands (Cmd+S, Cmd+O, Cmd+B, Cmd+F, Cmd+J, etc.) fall through
    }

    // ── Commands with Cmd modifier ──────────────────────────────────────
    if (mods.hasCmd()) {
        switch (event.keycode) {
            VK.Z => {
                if (mods.hasShift()) {
                    state.redo() catch {};
                } else {
                    state.undo() catch {};
                }
                return;
            },
            VK.S => {
                if (mods.hasShift()) {
                    // Save As (Cmd+Shift+S)
                    state.saveFileAsDialog();
                } else {
                    // Save file (Cmd+S)
                    state.saveFile() catch |err| {
                        if (err == error.NoFilePath) {
                            // No file path — invoke Save As dialog
                            state.saveFileAsDialog();
                        } else {
                            state.terminalPrint("Save failed!\r\n") catch {};
                            state.terminal_visible = true;
                        }
                    };
                }
                return;
            },
            VK.N => {
                // New file
                if (mods.cmdOnly()) {
                    // Prompt to save unsaved changes before clearing
                    if (state.modified) {
                        const file_cstr: ?[*:0]const u8 = if (state.file_path) |fp| blk: {
                            var nbuf: [512]u8 = undefined;
                            const basename = std.fs.path.basename(fp);
                            const copy_len = @min(basename.len, nbuf.len - 1);
                            @memcpy(nbuf[0..copy_len], basename[0..copy_len]);
                            nbuf[copy_len] = 0;
                            break :blk @ptrCast(nbuf[0..copy_len :0]);
                        } else null;
                        const result = platform.ed_platform_confirm_save_dialog(file_cstr);
                        if (result == 1) {
                            if (state.file_path != null) {
                                state.saveFile() catch {};
                            } else {
                                state.saveFileAsDialog();
                            }
                        } else if (result < 0) {
                            return; // Cancel
                        }
                        // result == 0 → Don't Save, continue
                    }
                    state.buffer.deinit();
                    state.buffer = RopeBuffer.init(state.allocator) catch return;
                    state.cursor = 0;
                    state.scroll_line = 0;
                    state.scroll_col = 0;
                    state.selection_anchor = null;
                    state.desired_col = null;
                    state.fold_regions.clearRetainingCapacity();
                    if (state.file_path) |old_path| {
                        state.allocator.free(old_path);
                    }
                    state.file_path = null;
                    state.modified = false;
                    // Clear undo/redo
                    for (state.undo_stack.items) |*e| {
                        e.deinit(state.allocator);
                    }
                    state.undo_stack.clearRetainingCapacity();
                    for (state.redo_stack.items) |*e| {
                        e.deinit(state.allocator);
                    }
                    state.redo_stack.clearRetainingCapacity();
                    state.updateTitle();
                    return;
                }
            },
            VK.L => {
                // Go to line — toggle a simple go-to-line mode
                // For now, use the terminal to show instructions
                if (mods.cmdOnly()) {
                    // Open find bar in "go to line" mode with a hint
                    state.find_state.visible = true;
                    state.focus = .find_bar;
                    state.find_state.query_len = 0;
                    state.find_state.clearMatches(state.allocator);
                    state.terminalPrint("Go to line: type a line number in the find bar and press Enter\r\n") catch {};
                    return;
                }
            },
            VK.F => {
                // Open find bar
                state.find_state.visible = true;
                state.focus = .find_bar;
                // If there's a selection, use it as the initial query
                if (state.selectionRange()) |range| {
                    const sel_text = state.buffer.slice(range.start, range.end) catch null;
                    if (sel_text) |st| {
                        defer state.allocator.free(st);
                        const copy_len = @min(st.len, FIND_MAX_LEN);
                        @memcpy(state.find_state.query[0..copy_len], st[0..copy_len]);
                        state.find_state.query_len = copy_len;
                        state.findUpdateMatches() catch {};
                    }
                }
                return;
            },
            VK.H => {
                // Open find & replace (Cmd+H)
                state.find_state.visible = true;
                state.find_state.replace_visible = true;
                state.focus = .find_bar;
                // If there's a selection, use it as the initial query
                if (state.selectionRange()) |range| {
                    const sel_text = state.buffer.slice(range.start, range.end) catch null;
                    if (sel_text) |st| {
                        defer state.allocator.free(st);
                        const copy_len = @min(st.len, FIND_MAX_LEN);
                        @memcpy(state.find_state.query[0..copy_len], st[0..copy_len]);
                        state.find_state.query_len = copy_len;
                        state.findUpdateMatches() catch {};
                    }
                }
                return;
            },
            VK.R => {
                // Rename symbol (Cmd+R)
                if (mods.cmdOnly()) {
                    state.openRename();
                    return;
                }
            },
            VK.O => {
                if (mods.cmdOnly()) {
                    // Open file (Cmd+O)
                    state.openFileDialog();
                    return;
                }
                if (mods.cmdShift()) {
                    // Symbol outline (Cmd+Shift+O)
                    state.openSymbolOutline();
                    return;
                }
            },
            VK.P => {
                if (mods.cmdShift()) {
                    // Insert File at cursor (Cmd+Shift+P)
                    state.insertFileAtCursor();
                    return;
                }
            },
            VK.G => {
                // Find next / prev (Cmd+G / Cmd+Shift+G)
                if (state.find_state.visible and state.find_state.query_len > 0) {
                    if (mods.hasShift()) {
                        state.findPrev();
                    } else {
                        state.findNext();
                    }
                }
                return;
            },
            VK.A => {
                if (mods.cmdShift()) {
                    // Analyse (Cmd+Shift+A)
                    if (state.jit_runner.isActive()) {
                        state.terminalPrint("  A task is already running.\r\n") catch {};
                        return;
                    }

                    // Collect any previous result
                    _ = state.jit_runner.collectResult();

                    // Clear error markers from previous run
                    state.clearErrorLines();

                    // Auto-save before analysing
                    _ = state.autoSaveBeforeRun();

                    // Expand terminal to show the report
                    state.expandTerminalForRun();
                    state.terminalPrint("\r\n") catch {};
                    state.terminalPrint("[Cmd+Shift+A] Analyse...\r\n") catch {};

                    // Extract buffer contents as UTF-8
                    const source_utf8 = state.buffer.toUtf8() catch {
                        state.terminalPrint("  Error: cannot extract buffer contents.\r\n") catch {};
                        return;
                    };
                    defer state.allocator.free(source_utf8);

                    // Start analysis on background thread
                    if (!state.jit_runner.startAnalyse(source_utf8)) {
                        state.terminalPrint("  Error: cannot start analysis.\r\n") catch {};
                    } else {
                        // Focus terminal to see the report
                        state.focus = .terminal;
                        state.terminal_pinned_to_bottom = true;
                        state.terminal_scroll_offset = 0;
                    }
                    return;
                }
                // Select all (Cmd+A)
                state.selection_anchor = 0;
                state.cursor = state.buffer.length();
                return;
            },
            VK.C, VK.X => {
                // Copy from terminal selection (Cmd+C only, not Cut)
                if (event.keycode == VK.C and state.focus == .terminal and state.termSelRange() != null) {
                    _ = state.copyTermSelection();
                    return;
                }
                // Copy / Cut from editor
                if (state.selectionRange()) |range| {
                    const sel_text = state.buffer.slice(range.start, range.end) catch return;
                    defer state.allocator.free(sel_text);
                    const utf8 = buffer_mod.codepointsToUtf8(state.allocator, sel_text) catch return;
                    defer state.allocator.free(utf8);

                    // Null-terminate for the C API
                    const cstr = state.allocator.allocSentinel(u8, utf8.len, 0) catch return;
                    defer state.allocator.free(cstr);
                    @memcpy(cstr[0..utf8.len], utf8);

                    platform.ed_platform_clipboard_set(cstr);

                    if (event.keycode == VK.X) {
                        // Cut: delete selection
                        const deleted = state.deleteSelection() catch null;
                        if (deleted) |d| {
                            state.pushUndo(state.cursor, d, &.{}) catch {};
                            state.allocator.free(d);
                        }
                    }
                }
                return;
            },
            VK.V => {
                // Paste
                const clip_text = platform.ed_platform_clipboard_get();
                if (clip_text) |ct| {
                    defer platform.ed_platform_clipboard_free(ct);
                    const clip_str = std.mem.span(ct);
                    const cps = buffer_mod.utf8ToCodepoints(state.allocator, clip_str) catch return;
                    defer state.allocator.free(cps);

                    // Delete selection first if any
                    _ = state.deleteSelection() catch null;

                    const pos = state.cursor;
                    state.buffer.insert(pos, cps) catch return;
                    state.pushUndo(pos, &.{}, cps) catch {};
                    state.cursor = pos + cps.len;
                    state.modified = true;
                    state.desired_col = null;
                    state.ensureCursorVisible();
                    state.updateTitle();
                }
                return;
            },
            VK.D => {
                // Duplicate line
                const lc = state.cursorLineCol();
                const range = state.buffer.lineRange(lc.line) orelse return;
                const line_data = state.buffer.slice(range.start, range.end) catch return;
                defer state.allocator.free(line_data);

                // Insert newline + line copy after end of line
                const nl = [_]u32{'\n'};
                const insert_pos = range.end;
                state.buffer.insert(insert_pos, &nl) catch return;
                state.buffer.insert(insert_pos + 1, line_data) catch return;
                state.cursor = insert_pos + 1 + lc.col;
                state.modified = true;
                state.ensureCursorVisible();
                state.updateTitle();
                return;
            },
            VK.SLASH => {
                // Toggle comment (single line or block selection)
                if (state.selectionRange()) |sel_range| {
                    // Block comment toggle: toggle comment on every line in the selection
                    const start_lc = state.buffer.offsetToLineCol(sel_range.start);
                    const end_lc = state.buffer.offsetToLineCol(sel_range.end);
                    const first_line = start_lc.line;
                    const last_line = if (end_lc.col == 0 and end_lc.line > first_line) end_lc.line - 1 else end_lc.line;

                    // Determine action: if ALL lines are commented, uncomment; otherwise comment all
                    var all_commented = true;
                    {
                        var check_line = first_line;
                        while (check_line <= last_line) : (check_line += 1) {
                            const ld = state.buffer.getLine(check_line) catch continue;
                            defer state.allocator.free(ld);
                            // Find first non-whitespace
                            var ws: usize = 0;
                            while (ws < ld.len and (ld[ws] == ' ' or ld[ws] == '\t')) : (ws += 1) {}
                            if (ws < ld.len and !(ld.len >= ws + 2 and ld[ws] == '\'' and ld[ws + 1] == ' ')) {
                                all_commented = false;
                                break;
                            }
                        }
                    }

                    const comment_prefix = [_]u32{ '\'', ' ' };
                    var total_offset: i64 = 0;
                    var line = first_line;
                    while (line <= last_line) : (line += 1) {
                        const r = state.buffer.lineRange(line) orelse continue;
                        const adjusted_start = @as(usize, @intCast(@as(i64, @intCast(r.start)) + total_offset));

                        if (all_commented) {
                            // Uncomment: find the "' " prefix and remove it
                            const ld = state.buffer.getLine(line) catch continue;
                            defer state.allocator.free(ld);
                            var ws: usize = 0;
                            while (ws < ld.len and (ld[ws] == ' ' or ld[ws] == '\t')) : (ws += 1) {}
                            if (ld.len >= ws + 2 and ld[ws] == '\'' and ld[ws + 1] == ' ') {
                                state.buffer.delete(adjusted_start + ws, 2) catch continue;
                                total_offset -= 2;
                            }
                        } else {
                            // Comment: insert "' " at line start
                            state.buffer.insert(adjusted_start, &comment_prefix) catch continue;
                            total_offset += 2;
                        }
                    }
                    if (total_offset != 0) {
                        state.modified = true;
                        state.symbols_dirty = true;
                        // Adjust cursor
                        const adj = @as(i64, @intCast(state.cursor)) + total_offset;
                        state.cursor = if (adj > 0) @intCast(adj) else 0;
                        // Adjust selection anchor
                        if (state.selection_anchor) |*anch| {
                            if (all_commented) {
                                anch.* = if (anch.* >= @as(usize, @intCast(-total_offset))) anch.* -| @as(usize, @intCast(-total_offset)) else 0;
                            } else {
                                anch.* +|= @as(usize, @intCast(total_offset));
                            }
                        }
                        state.ensureCursorVisible();
                        state.updateTitle();
                    }
                } else {
                    // Single line toggle comment
                    const lc = state.cursorLineCol();
                    const range = state.buffer.lineRange(lc.line) orelse return;
                    const line_data = state.buffer.slice(range.start, range.end) catch return;
                    defer state.allocator.free(line_data);

                    if (line_data.len >= 2 and line_data[0] == '\'' and line_data[1] == ' ') {
                        // Remove comment prefix
                        state.buffer.delete(range.start, 2) catch return;
                        state.cursor = if (state.cursor >= 2) state.cursor - 2 else 0;
                    } else {
                        // Add comment prefix
                        const prefix = [_]u32{ '\'', ' ' };
                        state.buffer.insert(range.start, &prefix) catch return;
                        state.cursor += 2;
                    }
                    state.modified = true;
                    state.symbols_dirty = true;
                    state.ensureCursorVisible();
                    state.updateTitle();
                }
                return;
            },
            VK.J => {
                if (mods.cmdShift()) {
                    // Toggle terminal fullscreen (Cmd+Shift+J)
                    state.toggleTerminalFullscreen();
                } else {
                    // Toggle terminal (Cmd+J)
                    if (state.terminal_fullscreen) {
                        // Exit fullscreen first
                        state.terminal_lines = state.terminal_lines_before_fullscreen;
                        state.terminal_fullscreen = false;
                    }
                    state.terminal_visible = !state.terminal_visible;
                    if (state.terminal_visible) {
                        state.updateTerminalSize();
                    }
                }
                return;
            },
            VK.E => {
                // Export to UTF-8 (Cmd+Shift+E)
                if (mods.cmdShift()) {
                    state.exportUtf8();
                    return;
                }
            },
            VK.I => {
                // Format BASIC source (Cmd+Shift+I)
                if (mods.cmdShift()) {
                    state.formatBuffer();
                    return;
                }
            },

            VK.M => {
                // Jump to matching bracket (Cmd+M)
                if (mods.cmdOnly()) {
                    if (state.findMatchingBracket(state.cursor)) |mb| {
                        state.cursor = mb;
                        state.desired_col = null;
                        state.ensureCursorVisible();
                        return;
                    } else if (state.cursor > 0) {
                        if (state.findMatchingBracket(state.cursor - 1)) |mb| {
                            state.cursor = mb;
                            state.desired_col = null;
                            state.ensureCursorVisible();
                            return;
                        }
                    }
                }
            },
            VK.LEFT_BRACKET => {
                if (mods.cmdShift()) {
                    // Fold/unfold at cursor (Cmd+Shift+[)
                    state.toggleFoldAtCursor();
                    state.adjustScrollForFolds();
                    return;
                }
                // Cycle theme backward (Cmd+[)
                // ThemeId.next() cycles forward; skip one = go backward in 5-cycle
                state.theme_id = state.theme_id.next();
                state.theme_id = state.theme_id.next();
                state.theme_id = state.theme_id.next();
                state.theme_id = state.theme_id.next();
                const new_theme = state.currentTheme();
                state.terminal.applyTheme(new_theme.terminal_fg, new_theme.terminal_bg);
                if (state.terminal_fullscreen) {
                    state.terminal_lines = state.terminal_lines_before_fullscreen;
                    state.terminal_fullscreen = false;
                }
                state.terminal_visible = false;
                if (state.focus == .terminal) state.focus = .editor;
                platform_set_help_theme(@intFromEnum(state.theme_id));
                return;
            },
            VK.RIGHT_BRACKET => {
                if (mods.cmdShift()) {
                    // Unfold all (Cmd+Shift+])
                    state.unfoldAll();
                    return;
                }
                // Cycle theme forward (Cmd+])
                state.theme_id = state.theme_id.next();
                const new_theme = state.currentTheme();
                state.terminal.applyTheme(new_theme.terminal_fg, new_theme.terminal_bg);
                if (state.terminal_fullscreen) {
                    state.terminal_lines = state.terminal_lines_before_fullscreen;
                    state.terminal_fullscreen = false;
                }
                state.terminal_visible = false;
                if (state.focus == .terminal) state.focus = .editor;
                platform_set_help_theme(@intFromEnum(state.theme_id));
                return;
            },
            VK.PERIOD => {
                // Stop running program (Cmd+.)
                if (state.jit_runner.isActive()) {
                    state.jit_runner.requestStop();
                    state.terminalPrint("\r\n  [Stop requested]\r\n") catch {};
                }
                return;
            },
            VK.B => {
                // Build program (Cmd+B)
                if (state.jit_runner.isActive()) {
                    state.terminalPrint("  A task is already running.\r\n") catch {};
                    return;
                }

                // Collect any previous result
                _ = state.jit_runner.collectResult();

                // Clear error markers from previous build
                state.clearErrorLines();

                // Auto-save before building
                _ = state.autoSaveBeforeRun();

                // Extract buffer contents as UTF-8
                const source_utf8 = state.buffer.toUtf8() catch {
                    state.terminalPrint("  Error: cannot extract buffer contents.\r\n") catch {};
                    return;
                };
                defer state.allocator.free(source_utf8);

                // Ask for output executable/app path via save dialog
                const suggested_build_path = state.suggestBuildOutputPath(source_utf8) catch null;
                defer if (suggested_build_path) |path| state.allocator.free(path);
                const build_outputs_app = if (suggested_build_path) |path|
                    std.mem.endsWith(u8, path, ".app")
                else
                    false;

                const suggested_build_path_z = if (suggested_build_path) |path|
                    state.allocator.dupeZ(u8, path) catch null
                else
                    null;
                defer if (suggested_build_path_z) |path| state.allocator.free(path);

                const out_path = platform.ed_platform_save_build_dialog(if (suggested_build_path_z) |path| path else "program");
                if (out_path == null) return; // user cancelled
                defer platform.ed_platform_free_path(out_path.?);

                const out_str = std.mem.span(out_path.?);

                // Show terminal and print header
                state.terminal_visible = true;
                state.updateTerminalSize();
                state.terminalPrint("\r\n") catch {};
                state.terminalPrint(if (build_outputs_app) "[Cmd+B] Build App...\r\n" else "[Cmd+B] Build Executable...\r\n") catch {};

                // Start AOT build on background thread
                if (!state.jit_runner.startBuild(source_utf8, out_str)) {
                    state.terminalPrint("  Error: cannot start build.\r\n") catch {};
                }
                return;
            },
            else => {},
        }
    }

    // ── Ctrl key combinations ───────────────────────────────────────────
    if (mods.hasCtrl() and !mods.hasCmd()) {
        switch (event.keycode) {
            VK.K => {
                // Kill (cut) line — delete entire current line, put on clipboard
                const lc = state.cursorLineCol();
                const range = state.buffer.lineRange(lc.line) orelse return;
                const line_data = state.buffer.slice(range.start, range.end) catch return;
                defer state.allocator.free(line_data);

                // Copy line to clipboard
                const utf8 = buffer_mod.codepointsToUtf8(state.allocator, line_data) catch return;
                defer state.allocator.free(utf8);
                const cstr = state.allocator.allocSentinel(u8, utf8.len, 0) catch return;
                defer state.allocator.free(cstr);
                @memcpy(cstr[0..utf8.len], utf8);
                platform.ed_platform_clipboard_set(cstr);

                // Delete the line including its trailing newline
                const delete_end = if (range.end < state.buffer.length())
                    range.end + 1 // include the \n
                else
                    range.end;
                const delete_len = delete_end - range.start;

                if (delete_len > 0) {
                    const deleted = state.buffer.slice(range.start, delete_end) catch null;
                    state.buffer.delete(range.start, delete_len) catch return;
                    state.cursor = range.start;
                    if (deleted) |d| {
                        state.pushUndo(range.start, d, &.{}) catch {};
                        state.allocator.free(d);
                    }
                    state.modified = true;
                    state.ensureCursorVisible();
                    state.updateTitle();
                }
                return;
            },
            VK.D => {
                // Duplicate line (Ctrl+D, same as Cmd+D)
                const lc = state.cursorLineCol();
                const range = state.buffer.lineRange(lc.line) orelse return;
                const line_data = state.buffer.slice(range.start, range.end) catch return;
                defer state.allocator.free(line_data);

                const nl = [_]u32{'\n'};
                const insert_pos = range.end;
                state.buffer.insert(insert_pos, &nl) catch return;
                state.buffer.insert(insert_pos + 1, line_data) catch return;
                state.cursor = insert_pos + 1 + lc.col;
                state.modified = true;
                state.ensureCursorVisible();
                state.updateTitle();
                return;
            },
            else => {},
        }
    }

    // ── Ctrl key combinations ───────────────────────────────────────────
    if (mods.hasCtrl() and !mods.hasCmd()) {
        switch (event.keycode) {
            VK.SPACE => {
                // Autocomplete (Ctrl+Space)
                state.openAutocomplete();
                return;
            },
            VK.RETURN => {
                // Ctrl+Enter — compile & run the whole program (same as F5)
                if (state.jit_runner.isActive()) {
                    state.terminalPrint("  Program already running.  Press Stop (Cmd+.) to cancel.\r\n") catch {};
                    return;
                }
                _ = state.jit_runner.collectResult();
                state.clearErrorLines();
                _ = state.autoSaveBeforeRun();
                state.expandTerminalForRun();
                state.terminalPrint("\r\n") catch {};
                state.terminalPrint("[Ctrl+Enter] Compile & Run...\r\n") catch {};
                const source_utf8 = state.buffer.toUtf8() catch {
                    state.terminalPrint("  Error: cannot extract buffer contents.\r\n") catch {};
                    return;
                };
                defer state.allocator.free(source_utf8);
                if (!state.jit_runner.startRun(source_utf8)) {
                    state.terminalPrint("  Error: cannot start JIT runner.\r\n") catch {};
                } else {
                    state.focus = .terminal;
                    state.terminal_pinned_to_bottom = true;
                    state.terminal_scroll_offset = 0;
                }
                return;
            },
            else => {},
        }
    }

    // ── Shift+Enter — run selected text (or whole program if no selection) ──
    if (mods.hasShift() and !mods.hasCmd() and !mods.hasCtrl() and event.keycode == VK.RETURN) {
        if (state.jit_runner.isActive()) {
            state.terminalPrint("  Program already running.  Press Stop (Cmd+.) to cancel.\r\n") catch {};
            return;
        }
        _ = state.jit_runner.collectResult();
        state.clearErrorLines();
        state.expandTerminalForRun();
        state.terminalPrint("\r\n") catch {};

        if (state.selectionRange()) |sel| {
            // Run only the selected text
            const sel_cps = state.buffer.slice(sel.start, sel.end) catch {
                state.terminalPrint("  Error: cannot extract selection.\r\n") catch {};
                return;
            };
            defer state.allocator.free(sel_cps);
            const sel_utf8 = buffer_mod.codepointsToUtf8(state.allocator, sel_cps) catch {
                state.terminalPrint("  Error: cannot encode selection.\r\n") catch {};
                return;
            };
            defer state.allocator.free(sel_utf8);
            state.terminalPrint("[Shift+Enter] Run selection...\r\n") catch {};
            if (!state.jit_runner.startRun(sel_utf8)) {
                state.terminalPrint("  Error: cannot start JIT runner.\r\n") catch {};
            } else {
                state.focus = .terminal;
                state.terminal_pinned_to_bottom = true;
                state.terminal_scroll_offset = 0;
            }
        } else {
            // No selection — run the whole program
            const source_utf8 = state.buffer.toUtf8() catch {
                state.terminalPrint("  Error: cannot extract buffer contents.\r\n") catch {};
                return;
            };
            defer state.allocator.free(source_utf8);
            state.terminalPrint("[Shift+Enter] Compile & Run...\r\n") catch {};
            if (!state.jit_runner.startRun(source_utf8)) {
                state.terminalPrint("  Error: cannot start JIT runner.\r\n") catch {};
            } else {
                state.focus = .terminal;
                state.terminal_pinned_to_bottom = true;
                state.terminal_scroll_offset = 0;
            }
        }
        return;
    }

    // ── Function keys ───────────────────────────────────────────────────
    switch (event.keycode) {
        VK.F5 => {
            // Run program (F5) — compile & execute via in-process JIT
            if (state.jit_runner.isActive()) {
                state.terminalPrint("  Program already running.  Press Stop (Cmd+.) to cancel.\r\n") catch {};
                return;
            }

            // If the previous run left a finished state, collect it first
            _ = state.jit_runner.collectResult();

            // Clear error markers from previous run
            state.clearErrorLines();

            // Auto-save before running
            _ = state.autoSaveBeforeRun();

            state.expandTerminalForRun();
            state.terminalPrint("\r\n") catch {};
            state.terminalPrint("[F5] Compile & Run...\r\n") catch {};

            // Extract buffer contents as UTF-8
            const source_utf8 = state.buffer.toUtf8() catch {
                state.terminalPrint("  Error: cannot extract buffer contents.\r\n") catch {};
                return;
            };
            defer state.allocator.free(source_utf8);

            // Start JIT compilation + execution on a background thread
            if (!state.jit_runner.startRun(source_utf8)) {
                state.terminalPrint("  Error: cannot start JIT runner.\r\n") catch {};
            } else {
                // Auto-focus the terminal so the user can immediately type
                // for INPUT statements without having to click it first.
                state.focus = .terminal;
                state.terminal_pinned_to_bottom = true;
                state.terminal_scroll_offset = 0;
            }
            // Output and completion status will appear via the terminal
            // ring buffer, drained each frame in buildFrame / ed_on_frame.
            return;
        },
        VK.F6 => {
            // Show Assembly (F6) — compile & disassemble without executing
            if (state.jit_runner.isActive()) {
                state.terminalPrint("  A task is already running.\r\n") catch {};
                return;
            }

            // Collect any previous result
            _ = state.jit_runner.collectResult();

            // Clear error markers from previous run
            state.clearErrorLines();

            // Auto-save before disassembling
            _ = state.autoSaveBeforeRun();

            // Expand terminal to show the report
            state.expandTerminalForRun();
            state.terminalPrint("\r\n") catch {};
            state.terminalPrint("[F6] Show Assembly...\r\n") catch {};

            // Extract buffer contents as UTF-8
            const source_utf8 = state.buffer.toUtf8() catch {
                state.terminalPrint("  Error: cannot extract buffer contents.\r\n") catch {};
                return;
            };
            defer state.allocator.free(source_utf8);

            // Start show-asm on background thread
            if (!state.jit_runner.startShowAsm(source_utf8)) {
                state.terminalPrint("  Error: cannot start assembly view.\r\n") catch {};
            } else {
                // Focus terminal to see the report
                state.focus = .terminal;
                state.terminal_pinned_to_bottom = true;
                state.terminal_scroll_offset = 0;
            }
            return;
        },
        VK.F7 => {
            // View IR (F7) — compile & show LLVM IR without executing
            if (state.jit_runner.isActive()) {
                state.terminalPrint("  A task is already running.\r\n") catch {};
                return;
            }

            // Collect any previous result
            _ = state.jit_runner.collectResult();

            // Clear error markers from previous run
            state.clearErrorLines();

            // Auto-save before compiling
            _ = state.autoSaveBeforeRun();

            // Expand terminal to show the report
            state.expandTerminalForRun();
            state.terminalPrint("\r\n") catch {};
            state.terminalPrint("[F7] View LLVM IR...\r\n") catch {};

            // Extract buffer contents as UTF-8
            const source_utf8 = state.buffer.toUtf8() catch {
                state.terminalPrint("  Error: cannot extract buffer contents.\r\n") catch {};
                return;
            };
            defer state.allocator.free(source_utf8);

            // Start show-IR on background thread
            if (!state.jit_runner.startShowIR(source_utf8)) {
                state.terminalPrint("  Error: cannot start IR view.\r\n") catch {};
            } else {
                // Focus terminal to see the report
                state.focus = .terminal;
                state.terminal_pinned_to_bottom = true;
                state.terminal_scroll_offset = 0;
            }
            return;
        },
        VK.F8 => {
            // View Assembly (F8) — compile & show native assembly without executing
            if (state.jit_runner.isActive()) {
                state.terminalPrint("  A task is already running.\r\n") catch {};
                return;
            }

            // Collect any previous result
            _ = state.jit_runner.collectResult();

            // Clear error markers from previous run
            state.clearErrorLines();

            // Auto-save before compiling
            _ = state.autoSaveBeforeRun();

            // Expand terminal to show the report
            state.expandTerminalForRun();
            state.terminalPrint("\r\n") catch {};
            state.terminalPrint("[F8] View Code...\r\n") catch {};

            // Extract buffer contents as UTF-8
            const source_utf8 = state.buffer.toUtf8() catch {
                state.terminalPrint("  Error: cannot extract buffer contents.\r\n") catch {};
                return;
            };
            defer state.allocator.free(source_utf8);

            // Start show-asm on background thread
            if (!state.jit_runner.startShowAsm(source_utf8)) {
                state.terminalPrint("  Error: cannot start assembly view.\r\n") catch {};
            } else {
                // Focus terminal to see the report
                state.focus = .terminal;
                state.terminal_pinned_to_bottom = true;
                state.terminal_scroll_offset = 0;
            }
            return;
        },
        VK.F9 => {
            // View AST (F9) — lex & parse the source and dump the AST
            if (state.jit_runner.isActive()) {
                state.terminalPrint("  A task is already running.\r\n") catch {};
                return;
            }

            _ = state.jit_runner.collectResult();
            state.clearErrorLines();
            _ = state.autoSaveBeforeRun();

            state.expandTerminalForRun();
            state.terminalPrint("\r\n") catch {};
            state.terminalPrint("[F9] View AST...\r\n") catch {};

            const source_utf8_ast = state.buffer.toUtf8() catch {
                state.terminalPrint("  Error: cannot extract buffer contents.\r\n") catch {};
                return;
            };
            defer state.allocator.free(source_utf8_ast);

            if (!state.jit_runner.startShowAST(source_utf8_ast)) {
                state.terminalPrint("  Error: cannot start AST view.\r\n") catch {};
            } else {
                state.focus = .terminal;
                state.terminal_pinned_to_bottom = true;
                state.terminal_scroll_offset = 0;
            }
            return;
        },
        VK.F10 => {
            // View CFG (F10) — compile through semantic+CFG and dump the Control Flow Graph
            if (state.jit_runner.isActive()) {
                state.terminalPrint("  A task is already running.\r\n") catch {};
                return;
            }

            _ = state.jit_runner.collectResult();
            state.clearErrorLines();
            _ = state.autoSaveBeforeRun();

            state.expandTerminalForRun();
            state.terminalPrint("\r\n") catch {};
            state.terminalPrint("[F10] View CFG...\r\n") catch {};

            const source_utf8_cfg = state.buffer.toUtf8() catch {
                state.terminalPrint("  Error: cannot extract buffer contents.\r\n") catch {};
                return;
            };
            defer state.allocator.free(source_utf8_cfg);

            if (!state.jit_runner.startShowCFG(source_utf8_cfg)) {
                state.terminalPrint("  Error: cannot start CFG view.\r\n") catch {};
            } else {
                state.focus = .terminal;
                state.terminal_pinned_to_bottom = true;
                state.terminal_scroll_offset = 0;
            }
            return;
        },
        VK.F11 => {
            // View Symbols (F11) — compile through semantic analysis and dump the symbol table
            if (state.jit_runner.isActive()) {
                state.terminalPrint("  A task is already running.\r\n") catch {};
                return;
            }

            _ = state.jit_runner.collectResult();
            state.clearErrorLines();
            _ = state.autoSaveBeforeRun();

            state.expandTerminalForRun();
            state.terminalPrint("\r\n") catch {};
            state.terminalPrint("[F11] View Symbols...\r\n") catch {};

            const source_utf8_sym = state.buffer.toUtf8() catch {
                state.terminalPrint("  Error: cannot extract buffer contents.\r\n") catch {};
                return;
            };
            defer state.allocator.free(source_utf8_sym);

            if (!state.jit_runner.startShowSymbols(source_utf8_sym)) {
                state.terminalPrint("  Error: cannot start Symbols view.\r\n") catch {};
            } else {
                state.focus = .terminal;
                state.terminal_pinned_to_bottom = true;
                state.terminal_scroll_offset = 0;
            }
            return;
        },
        VK.F1 => {
            // Help (F1) - Context sensitive
            var help_target: [256]u8 = undefined;
            var help_len: usize = 0;

            const lc = state.cursorLineCol();
            if (state.buffer.getLine(lc.line)) |line_data| {
                defer state.allocator.free(line_data);
                const word_info = symbols_mod.wordAtCursor(line_data, lc.col);
                if (word_info.word.len > 0) {
                    var i: usize = 0;
                    for (word_info.word) |cp| {
                        if (i + 4 >= help_target.len) break;
                        if (std.math.cast(u21, cp)) |codepoint| {
                            const n = std.unicode.utf8Encode(codepoint, help_target[i..]) catch 0;
                            i += n;
                        }
                    }
                    help_len = i;
                }
            } else |_| {}

            help_target[help_len] = 0; // Null terminate
            platform_show_help(help_target[0..help_len :0]);
            return;
        },
        VK.F12 => {
            // Go to definition (F12)
            state.goToDefinition();
            return;
        },
        VK.F2 => {
            // Toggle case sensitivity for search (F2)
            state.find_state.case_insensitive = !state.find_state.case_insensitive;
            if (state.find_state.visible) {
                state.findUpdateMatches() catch {};
            }
            const msg_str: []const u8 = if (state.find_state.case_insensitive) "Search: case-insensitive\r\n" else "Search: case-sensitive\r\n";
            state.terminalPrint(msg_str) catch {};
            state.terminal_visible = true;
            return;
        },
        else => {},
    }

    // Cancel ghost text on any navigation or editing before dispatching.
    if (state.sa_ghost.items.len > 0 and event.keycode != VK.TAB) {
        saCancelGhost(state);
    }

    // ── Navigation keys ─────────────────────────────────────────────────
    switch (event.keycode) {
        VK.LEFT_ARROW => {
            handleSelectionModifier(state, mods);
            if (mods.hasAlt()) {
                // Word left
                state.cursor = wordBoundaryLeft(state);
            } else if (mods.hasCmd()) {
                // Line start
                const lc = state.cursorLineCol();
                state.cursor = state.buffer.lineColToOffset(lc.line, 0);
            } else {
                if (state.cursor > 0) state.cursor -= 1;
            }
            state.desired_col = null;
            state.ensureCursorVisible();
            return;
        },
        VK.RIGHT_ARROW => {
            handleSelectionModifier(state, mods);
            if (mods.hasAlt()) {
                // Word right
                state.cursor = wordBoundaryRight(state);
            } else if (mods.hasCmd()) {
                // Line end
                const lc = state.cursorLineCol();
                const range = state.buffer.lineRange(lc.line) orelse return;
                state.cursor = range.end;
            } else {
                if (state.cursor < state.buffer.length()) state.cursor += 1;
            }
            state.desired_col = null;
            state.ensureCursorVisible();
            return;
        },
        VK.UP_ARROW => {
            if (mods.hasAlt() and !mods.hasShift() and !mods.hasCmd() and !mods.hasCtrl()) {
                // Alt+Up — move current line up
                const lc = state.cursorLineCol();
                if (lc.line > 0) {
                    const cur_range = state.buffer.lineRange(lc.line) orelse return;
                    const cur_data = state.buffer.slice(cur_range.start, cur_range.end) catch return;
                    defer state.allocator.free(cur_data);

                    const prev_range = state.buffer.lineRange(lc.line - 1) orelse return;
                    const prev_data = state.buffer.slice(prev_range.start, prev_range.end) catch return;
                    defer state.allocator.free(prev_data);

                    // Delete current line (including preceding newline)
                    const del_start = cur_range.start - 1; // the '\n' before this line
                    const del_len = cur_range.end - del_start;
                    state.buffer.delete(del_start, del_len) catch return;

                    // Insert current line before the previous line
                    const nl = [_]u32{'\n'};
                    state.buffer.insert(prev_range.start, cur_data) catch return;
                    state.buffer.insert(prev_range.start + cur_data.len, &nl) catch return;

                    // Move cursor to same column on the new line
                    state.setCursorLineCol(lc.line - 1, lc.col);
                    state.modified = true;
                    state.symbols_dirty = true;
                    state.ensureCursorVisible();
                    state.updateTitle();
                }
                return;
            }
            handleSelectionModifier(state, mods);
            const lc = state.cursorLineCol();
            if (lc.line > 0) {
                const col = state.desired_col orelse lc.col;
                // Skip over folded regions when moving up
                var target_line = lc.line - 1;
                while (target_line > 0 and state.isLineHidden(target_line)) {
                    target_line -= 1;
                }
                if (state.isLineHidden(target_line) and target_line == 0) {
                    // Line 0 is hidden (shouldn't happen normally) — stay put
                } else {
                    state.setCursorLineCol(target_line, col);
                }
                if (state.desired_col == null) state.desired_col = lc.col;
            }
            return;
        },
        VK.DOWN_ARROW => {
            if (mods.hasAlt() and !mods.hasShift() and !mods.hasCmd() and !mods.hasCtrl()) {
                // Alt+Down — move current line down
                const lc = state.cursorLineCol();
                if (lc.line + 1 < state.buffer.lineCount()) {
                    const cur_range = state.buffer.lineRange(lc.line) orelse return;
                    const cur_data = state.buffer.slice(cur_range.start, cur_range.end) catch return;
                    defer state.allocator.free(cur_data);

                    const next_range = state.buffer.lineRange(lc.line + 1) orelse return;
                    const next_data = state.buffer.slice(next_range.start, next_range.end) catch return;
                    defer state.allocator.free(next_data);

                    // Delete next line (including preceding newline)
                    const del_start = next_range.start - 1; // the '\n' before the next line
                    const del_len = next_range.end - del_start;
                    state.buffer.delete(del_start, del_len) catch return;

                    // Insert next line before the current line
                    const nl = [_]u32{'\n'};
                    state.buffer.insert(cur_range.start, next_data) catch return;
                    state.buffer.insert(cur_range.start + next_data.len, &nl) catch return;

                    // Move cursor to same column on the new line (which is now one line lower)
                    state.setCursorLineCol(lc.line + 1, lc.col);
                    state.modified = true;
                    state.symbols_dirty = true;
                    state.ensureCursorVisible();
                    state.updateTitle();
                }
                return;
            }
            handleSelectionModifier(state, mods);
            const lc = state.cursorLineCol();
            if (lc.line + 1 < state.buffer.lineCount()) {
                const col = state.desired_col orelse lc.col;
                // Skip over folded regions when moving down
                var target_line = lc.line + 1;
                const max_line = state.buffer.lineCount() - 1;
                while (target_line < max_line and state.isLineHidden(target_line)) {
                    target_line += 1;
                }
                if (!state.isLineHidden(target_line)) {
                    state.setCursorLineCol(target_line, col);
                }
                if (state.desired_col == null) state.desired_col = lc.col;
            }
            return;
        },
        VK.HOME => {
            handleSelectionModifier(state, mods);
            if (mods.hasCmd()) {
                state.cursor = 0;
            } else {
                const lc = state.cursorLineCol();
                state.cursor = state.buffer.lineColToOffset(lc.line, 0);
            }
            state.desired_col = null;
            state.ensureCursorVisible();
            return;
        },
        VK.END => {
            handleSelectionModifier(state, mods);
            if (mods.hasCmd()) {
                state.cursor = state.buffer.length();
            } else {
                const lc = state.cursorLineCol();
                const range = state.buffer.lineRange(lc.line) orelse return;
                state.cursor = range.end;
            }
            state.desired_col = null;
            state.ensureCursorVisible();
            return;
        },
        VK.PAGE_UP => {
            handleSelectionModifier(state, mods);
            const vis = state.visibleLines();
            const lc = state.cursorLineCol();
            const new_line = if (lc.line >= vis) lc.line - vis else 0;
            state.setCursorLineCol(new_line, state.desired_col orelse lc.col);
            if (state.desired_col == null) state.desired_col = lc.col;
            if (state.scroll_line >= vis) {
                state.scroll_line -= vis;
            } else {
                state.scroll_line = 0;
            }
            return;
        },
        VK.PAGE_DOWN => {
            handleSelectionModifier(state, mods);
            const vis = state.visibleLines();
            const lc = state.cursorLineCol();
            const max_line = if (state.buffer.lineCount() > 0) state.buffer.lineCount() - 1 else 0;
            const new_line = @min(lc.line + vis, max_line);
            state.setCursorLineCol(new_line, state.desired_col orelse lc.col);
            if (state.desired_col == null) state.desired_col = lc.col;
            state.scroll_line = @min(state.scroll_line + vis, max_line);
            return;
        },
        VK.ESCAPE => {
            // If there's a terminal selection, clear it first; otherwise return to editor
            if (state.termSelRange() != null) {
                state.clearTermSelection();
            } else {
                state.selection_anchor = null;
                state.focus = .editor;
            }
            return;
        },
        else => {},
    }

    // ── Editing keys ────────────────────────────────────────────────────

    // Clear error markers on any editing key (stale errors no longer apply)
    if (event.keycode == VK.DELETE or event.keycode == VK.FORWARD_DELETE or
        event.keycode == VK.RETURN or event.keycode == VK.TAB)
    {
        if (state.error_lines.items.len > 0) {
            state.clearErrorLines();
        }
    }

    switch (event.keycode) {
        VK.DELETE => {
            // Backspace
            _ = state.deleteSelection() catch null;
            if (state.selection_anchor == null and state.cursor > 0) {
                const del_pos = state.cursor - 1;
                const ch = state.buffer.charAt(del_pos) orelse return;
                state.buffer.delete(del_pos, 1) catch return;
                state.pushUndo(del_pos, &[_]u32{ch}, &.{}) catch {};
                state.cursor = del_pos;
                state.modified = true;
                state.updateTitle();
            }
            state.desired_col = null;
            state.ensureCursorVisible();
            return;
        },
        VK.FORWARD_DELETE => {
            // Forward delete
            _ = state.deleteSelection() catch null;
            if (state.selection_anchor == null and state.cursor < state.buffer.length()) {
                const ch = state.buffer.charAt(state.cursor) orelse return;
                state.buffer.delete(state.cursor, 1) catch return;
                state.pushUndo(state.cursor, &[_]u32{ch}, &.{}) catch {};
                state.modified = true;
                state.updateTitle();
            }
            state.desired_col = null;
            state.ensureCursorVisible();
            return;
        },
        VK.RETURN => {
            // Enter — insert newline with smart block-aware auto-indent
            _ = state.deleteSelection() catch null;
            const pos = state.cursor;

            // Calculate base indent from current line's leading whitespace
            const lc = state.cursorLineCol();
            const line_data = state.buffer.getLine(lc.line) catch null;
            var base_indent: usize = 0;
            if (line_data) |ld| {
                defer state.allocator.free(ld);
                for (ld) |ch| {
                    if (ch == ' ') {
                        base_indent += 1;
                    } else if (ch == '\t') {
                        base_indent += TAB_WIDTH;
                    } else break;
                }

                // Smart indent: classify the current line to detect block
                // openers (FOR, SUB, IF...THEN, WHILE, etc.) and adjust
                // the new line's indent level accordingly.
                const line_info = format_mod.classifyLine(ld);
                if (line_info.indent_after > 0) {
                    base_indent += @as(usize, line_info.indent_after) * INDENT_WIDTH;
                }
            }

            // Build newline + indent
            var insert_buf: [256]u32 = undefined;
            insert_buf[0] = '\n';
            const indent_count = @min(base_indent, 254);
            for (insert_buf[1 .. 1 + indent_count]) |*c| {
                c.* = ' ';
            }
            const insert_text = insert_buf[0 .. 1 + indent_count];

            state.buffer.insert(pos, insert_text) catch return;
            state.pushUndo(pos, &.{}, insert_text) catch {};
            state.cursor = pos + insert_text.len;
            state.modified = true;
            state.desired_col = null;
            state.selection_anchor = null;

            // Uppercase any BASIC keywords on the line that was just completed.
            state.upcaseKeywordsOnLine(lc.line);

            state.ensureCursorVisible();
            state.updateTitle();
            return;
        },
        VK.TAB => {
            if (mods.hasShift()) {
                // Shift+Tab — unindent current line or selected block
                if (state.selectionRange()) |sel_range| {
                    // Block unindent: unindent every line in the selection
                    const start_lc = state.buffer.offsetToLineCol(sel_range.start);
                    const end_lc = state.buffer.offsetToLineCol(sel_range.end);
                    const first_line = start_lc.line;
                    const last_line = if (end_lc.col == 0 and end_lc.line > first_line) end_lc.line - 1 else end_lc.line;

                    var total_removed: usize = 0;
                    var line = first_line;
                    while (line <= last_line) : (line += 1) {
                        const range = state.buffer.lineRange(line) orelse continue;
                        const ld = state.buffer.getLine(line) catch continue;
                        defer state.allocator.free(ld);

                        var leading: usize = 0;
                        while (leading < ld.len and leading < TAB_WIDTH and ld[leading] == ' ') {
                            leading += 1;
                        }
                        if (leading > 0) {
                            // Adjust the range for already-removed characters
                            const adjusted_start = if (range.start >= total_removed) range.start - total_removed else range.start;
                            _ = adjusted_start;
                            state.buffer.delete(range.start - total_removed, leading) catch continue;
                            state.pushUndo(range.start - total_removed, &.{}, &.{}) catch {};
                            total_removed += leading;
                        }
                    }
                    if (total_removed > 0) {
                        state.modified = true;
                        state.updateTitle();
                        // Adjust cursor and selection
                        if (state.cursor >= total_removed) {
                            state.cursor -= @min(total_removed, state.cursor);
                        }
                        if (state.selection_anchor) |*anch| {
                            if (anch.* >= total_removed) {
                                anch.* -= @min(total_removed, anch.*);
                            }
                        }
                    }
                } else {
                    // Single line unindent
                    const lc = state.cursorLineCol();
                    const range = state.buffer.lineRange(lc.line) orelse return;
                    const line_data = state.buffer.getLine(lc.line) catch return;
                    defer state.allocator.free(line_data);

                    var leading_spaces: usize = 0;
                    while (leading_spaces < line_data.len and leading_spaces < TAB_WIDTH and line_data[leading_spaces] == ' ') {
                        leading_spaces += 1;
                    }

                    if (leading_spaces > 0) {
                        const deleted_text = state.buffer.slice(range.start, range.start + leading_spaces) catch return;
                        defer state.allocator.free(deleted_text);
                        state.buffer.delete(range.start, leading_spaces) catch return;
                        state.pushUndo(range.start, deleted_text, &.{}) catch {};
                        if (lc.col >= leading_spaces) {
                            state.cursor -= leading_spaces;
                        } else {
                            state.cursor = range.start;
                        }
                        state.modified = true;
                        state.updateTitle();
                    }
                }
                state.desired_col = null;
                state.ensureCursorVisible();
                return;
            } else {
                // Tab — if ghost text is pending, accept it instead of indenting.
                if (state.sa_ghost.items.len > 0 and state.selectionRange() == null) {
                    saAcceptGhost(state);
                    state.ensureCursorVisible();
                    return;
                }
                // Tab — indent line or block
                if (state.selectionRange()) |sel_range| {
                    // Block indent: indent every line in the selection
                    const start_lc = state.buffer.offsetToLineCol(sel_range.start);
                    const end_lc = state.buffer.offsetToLineCol(sel_range.end);
                    const first_line = start_lc.line;
                    const last_line = if (end_lc.col == 0 and end_lc.line > first_line) end_lc.line - 1 else end_lc.line;

                    var spaces_buf: [8]u32 = undefined;
                    for (spaces_buf[0..TAB_WIDTH]) |*c| {
                        c.* = ' ';
                    }
                    const indent_text = spaces_buf[0..TAB_WIDTH];

                    var total_added: usize = 0;
                    var line = first_line;
                    while (line <= last_line) : (line += 1) {
                        const range = state.buffer.lineRange(line) orelse continue;
                        state.buffer.insert(range.start + total_added, indent_text) catch continue;
                        state.pushUndo(range.start + total_added, &.{}, indent_text) catch {};
                        total_added += TAB_WIDTH;
                    }
                    if (total_added > 0) {
                        state.modified = true;
                        state.cursor += total_added;
                        if (state.selection_anchor) |*anch| {
                            anch.* += TAB_WIDTH; // first line indent
                        }
                        state.updateTitle();
                    }
                } else {
                    // Single line: insert spaces to next tab stop
                    _ = state.deleteSelection() catch null;
                    const pos = state.cursor;
                    const lc = state.cursorLineCol();
                    const spaces_needed = TAB_WIDTH - (lc.col % TAB_WIDTH);
                    var spaces_buf: [8]u32 = undefined;
                    for (spaces_buf[0..spaces_needed]) |*c| {
                        c.* = ' ';
                    }
                    const spaces = spaces_buf[0..spaces_needed];

                    state.buffer.insert(pos, spaces) catch return;
                    state.pushUndo(pos, &.{}, spaces) catch {};
                    state.cursor = pos + spaces_needed;
                    state.modified = true;
                    state.desired_col = null;
                    state.selection_anchor = null;
                    state.updateTitle();
                }
                state.ensureCursorVisible();
                return;
            }
        },
        else => {},
    }
}

fn handleTextInput(state: *EditorState, codepoint: u32) void {
    // Filter out control characters and already-handled keys
    if (codepoint < 0x20) return;
    if (codepoint == 0x7F) return; // DEL

    // Reset cursor blink
    state.cursor_blink_timer = 0;
    state.cursor_visible = true;

    // ── Symbol outline filter typing ────────────────────────────────────
    if (state.focus == .symbol_overlay and state.symbol_overlay.visible) {
        state.symbol_overlay.appendFilter(codepoint);
        state.filterSymbolOverlay();
        if (state.symbol_overlay.item_count == 0 and state.symbol_overlay.filter_len > 0) {
            // Keep overlay open even with no matches — user can backspace
        }
        return;
    }

    // ── Autocomplete filter typing (also inserts into the buffer) ───────
    if (state.focus == .autocomplete and state.autocomplete_overlay.visible) {
        // If the character is not an identifier char, accept completion and
        // insert the character normally (e.g. typing '(' after selecting).
        const is_ident = (codepoint >= 'A' and codepoint <= 'Z') or
            (codepoint >= 'a' and codepoint <= 'z') or
            (codepoint >= '0' and codepoint <= '9') or codepoint == '_';

        // In sprite-mode, allow space as a filter character so multi-word
        // subcommands like "FX PARAM", "REMOVE ALL" can be progressively
        // narrowed.  If the space would yield zero matches the overlay
        // will close naturally after re-filter.
        const is_compound_space = (state.sprite_mode or state.sound_mode or state.music_mode or state.vs_mode) and codepoint == ' ';

        if (!is_ident and !is_compound_space) {
            if ((state.dot_mode or state.type_mode or state.sprite_mode or state.sound_mode or state.music_mode or state.vs_mode) and state.autocomplete_overlay.filter_len == 0) {
                // In dot/type/compound-mode with no filter typed yet — close without accepting.
                state.autocomplete_overlay.close();
                state.dot_mode = false;
                state.type_mode = false;
                state.sprite_mode = false;
                state.sound_mode = false;
                state.music_mode = false;
                state.vs_mode = false;
                state.focus = .editor;
                // Fall through to insert the character normally
            } else {
                // Accept current completion first, then fall through to normal insert
                state.applyAutocomplete();
                // Fall through — the character will be inserted below
            }
        } else {
            // Append to filter and insert into buffer
            state.autocomplete_overlay.appendFilter(codepoint);

            // Insert the character into the buffer
            const pos = state.cursor;
            const text = [_]u32{codepoint};
            state.buffer.insert(pos, &text) catch return;
            state.pushUndo(pos, &.{}, &text) catch {};
            state.cursor = pos + 1;
            state.modified = true;
            state.desired_col = null;
            state.selection_anchor = null;
            state.ensureCursorVisible();
            state.updateTitle();

            // Re-filter
            state.filterAutocomplete();
            if (state.autocomplete_overlay.item_count == 0) {
                state.autocomplete_overlay.close();
                state.focus = .editor;
            }
            return;
        }
    }

    // ── Terminal stdin input (when a JIT program is running) ─────────────
    if (state.focus == .terminal and state.jit_runner.isRunning()) {
        // Echo the typed character to the terminal and buffer it for stdin
        if (codepoint < 128) {
            const byte = @as(u8, @intCast(codepoint));
            var echo_buf: [1]u8 = .{byte};
            state.terminal.writeBytes(&echo_buf);
            _ = state.jit_runner.stdin_input.append(byte);
            if (state.terminal_pinned_to_bottom) {
                state.terminal_scroll_offset = 0;
            }
        }
        return;
    }

    // ── Terminal has focus but no program is running — ignore text input ─
    if (state.focus == .terminal) {
        return;
    }

    // ── Inline rename text input ────────────────────────────────────────
    if (state.rename_state.visible) {
        // Only allow identifier characters and BASIC type suffixes ($, %, !, #, &)
        if (isIdentChar(codepoint) or codepoint == '$' or codepoint == '%' or
            codepoint == '!' or codepoint == '#' or codepoint == '&')
        {
            // Delete selection first if any (e.g. the initial select-all)
            if (state.selectionRange()) |range| {
                const r_primary = state.rename_state.primary_offset;
                const r_word_len = state.rename_state.currentWordLen(&state.buffer);
                const r_end = r_primary + r_word_len;
                // Only delete if selection is within the rename word
                if (range.start >= r_primary and range.end <= r_end) {
                    const deleted = state.deleteSelection() catch null;
                    if (deleted) |d| {
                        state.allocator.free(d);
                    }
                }
            }
            // Insert the character at cursor position (within the word)
            const pos = state.cursor;
            state.buffer.insert(pos, &[_]u32{codepoint}) catch return;
            state.pushUndo(pos, &.{}, &[_]u32{codepoint}) catch {};
            state.cursor = pos + 1;
            state.selection_anchor = null;
            state.modified = true;
            state.updateTitle();
        }
        return;
    }

    // ── Find bar text input ─────────────────────────────────────────────
    if (state.focus == .find_bar and state.find_state.visible) {
        state.find_state.appendChar(codepoint);
        state.findUpdateMatches() catch {};
        return;
    }

    // ── Replace bar text input ──────────────────────────────────────────
    if (state.focus == .replace_bar and state.find_state.replace_visible) {
        state.find_state.appendReplaceChar(codepoint);
        return;
    }

    // Clear error markers on edit (stale errors no longer apply)
    if (state.error_lines.items.len > 0) {
        state.clearErrorLines();
    }

    // Delete selection first if any
    const deleted = state.deleteSelection() catch null;
    if (deleted) |d| {
        state.pushUndo(state.cursor, d, &.{}) catch {};
        state.allocator.free(d);
    }

    // Insert the character
    const pos = state.cursor;
    const text = [_]u32{codepoint};
    state.buffer.insert(pos, &text) catch return;
    state.pushUndo(pos, &.{}, &text) catch {};
    state.cursor = pos + 1;

    // Auto-closing pairs: when an opening bracket/quote is typed, insert the closer
    for (AUTO_CLOSE_PAIRS) |pair| {
        if (codepoint == pair[0]) {
            const closer = [_]u32{pair[1]};
            state.buffer.insert(state.cursor, &closer) catch break;
            // Don't advance cursor past the closer — user types inside
            break;
        }
    }

    // Auto-close double quotes
    if (codepoint == '"') {
        // Only auto-close if not already inside a string (heuristic: check if
        // there's an odd number of quotes on this line before cursor)
        const lc = state.cursorLineCol();
        const line_data = state.buffer.getLine(lc.line) catch null;
        var quote_count: usize = 0;
        if (line_data) |ld| {
            defer state.allocator.free(ld);
            for (ld[0..@min(lc.col, ld.len)]) |ch| {
                if (ch == '"') quote_count += 1;
            }
        }
        // If there's an even number of quotes before us (including the one we
        // just inserted), we're opening a new string — auto-close.
        // quote_count includes the just-inserted quote, so "even" means we just opened.
        if (quote_count % 2 == 1) {
            const closer = [_]u32{'"'};
            state.buffer.insert(state.cursor, &closer) catch {};
        }
    }

    state.modified = true;
    state.symbols_dirty = true;
    state.desired_col = null;
    state.selection_anchor = null;
    state.ensureCursorVisible();
    state.updateTitle();

    // Arm smart-assist debounce on every normal edit.
    saArmDebounce(state);

    // ── Dot-trigger: open dot-autocomplete when '.' is typed after an identifier ──
    if (codepoint == '.') {
        state.openDotAutocomplete();
    }

    // ── AS-trigger: open type-autocomplete when space is typed after `AS` ──
    // ── SPRITE-trigger: open sprite-subcommand autocomplete after `SPRITE ` ──
    if (codepoint == ' ') {
        const lc = state.cursorLineCol();
        const line_data = state.buffer.getLine(lc.line) catch null;
        if (line_data) |ld| {
            defer state.allocator.free(ld);
            // cursor is now AFTER the space, so the word before starts before col-1
            const sp_col = lc.col - 1; // position of the space we just inserted

            // Check for SPRITE (6 chars before the space)
            if (sp_col >= 6) {
                const s = sp_col - 6;
                const w = ld[s..sp_col];
                const is_sprite = (w[0] == 'S' or w[0] == 's') and
                    (w[1] == 'P' or w[1] == 'p') and
                    (w[2] == 'R' or w[2] == 'r') and
                    (w[3] == 'I' or w[3] == 'i') and
                    (w[4] == 'T' or w[4] == 't') and
                    (w[5] == 'E' or w[5] == 'e');
                if (is_sprite) {
                    // Verify word boundary: nothing before, or non-ident char before 'S'
                    const boundary = (s == 0) or !symbols_mod.isIdentChar(ld[s - 1]);
                    if (boundary) {
                        state.openSpriteAutocomplete();
                    }
                }
            }

            // Check for SOUND (5 chars before the space)
            if (sp_col >= 5) {
                const s = sp_col - 5;
                const w = ld[s..sp_col];
                const is_sound = (w[0] == 'S' or w[0] == 's') and
                    (w[1] == 'O' or w[1] == 'o') and
                    (w[2] == 'U' or w[2] == 'u') and
                    (w[3] == 'N' or w[3] == 'n') and
                    (w[4] == 'D' or w[4] == 'd');
                if (is_sound) {
                    const boundary = (s == 0) or !symbols_mod.isIdentChar(ld[s - 1]);
                    if (boundary) {
                        state.openSoundAutocomplete();
                    }
                }
            }

            // Check for MUSIC (5 chars before the space)
            if (sp_col >= 5) {
                const s = sp_col - 5;
                const w = ld[s..sp_col];
                const is_music = (w[0] == 'M' or w[0] == 'm') and
                    (w[1] == 'U' or w[1] == 'u') and
                    (w[2] == 'S' or w[2] == 's') and
                    (w[3] == 'I' or w[3] == 'i') and
                    (w[4] == 'C' or w[4] == 'c');
                if (is_music) {
                    const boundary = (s == 0) or !symbols_mod.isIdentChar(ld[s - 1]);
                    if (boundary) {
                        state.openMusicAutocomplete();
                    }
                }
            }

            // Check for VS (2 chars before the space)
            if (sp_col >= 2) {
                const s = sp_col - 2;
                const w = ld[s..sp_col];
                const is_vs = (w[0] == 'V' or w[0] == 'v') and
                    (w[1] == 'S' or w[1] == 's');
                if (is_vs) {
                    const boundary = (s == 0) or !symbols_mod.isIdentChar(ld[s - 1]);
                    // Make sure it's not VSYNC or another VS-prefixed word
                    const not_longer = (sp_col >= ld.len) or !symbols_mod.isIdentChar(ld[sp_col]);
                    _ = not_longer;
                    if (boundary) {
                        state.openVsAutocomplete();
                    }
                }
            }

            // Check for AS (2 chars before the space)
            if (sp_col >= 2) {
                // Check if the two characters before the space are "AS" (case-insensitive)
                // and that AS is a word boundary (not preceded by an ident char)
                const c1 = ld[sp_col - 2]; // 'A'
                const c2 = ld[sp_col - 1]; // 'S'
                const is_A = (c1 == 'A' or c1 == 'a');
                const is_S = (c2 == 'S' or c2 == 's');
                if (is_A and is_S) {
                    // Verify word boundary: nothing before, or non-ident char before the 'A'
                    const boundary = (sp_col < 3) or !symbols_mod.isIdentChar(ld[sp_col - 3]);
                    if (boundary) {
                        state.openTypeAutocomplete();
                    }
                }
            }
        }
    }
}

// ─── Smart Assist Helpers ───────────────────────────────────────────────────

/// Cancel any in-flight ghost text: signal inference stop and wipe the buffer.
fn saCancelGhost(state: *EditorState) void {
    if (state.smart_assist) |sa| sa.cancel();
    state.sa_ghost.clearRetainingCapacity();
    state.sa_debounce = -1;
    state.sa_active = false;
}

/// Arm the debounce timer after any editing keystroke.
fn saArmDebounce(state: *EditorState) void {
    if (state.smart_assist == null) return;
    saCancelGhost(state);
    state.sa_debounce = 0.4; // seconds
}

/// Per-frame tick: count down debounce, fire submit, drain tokens.
fn saTickAndDrain(state: *EditorState, dt: f64) void {
    const sa = state.smart_assist orelse return;

    // Cancel ghost when cursor moves (navigation)
    if (state.cursor != state.sa_last_cursor and state.sa_ghost.items.len > 0) {
        saCancelGhost(state);
    }
    state.sa_last_cursor = state.cursor;

    // Debounce countdown
    if (state.sa_debounce >= 0) {
        state.sa_debounce -= dt;
        if (state.sa_debounce < 0 and !state.sa_active) {
            state.sa_active = true;
            const buf_len = state.buffer.length();
            const pre_start = if (state.cursor > 1000) state.cursor - 1000 else 0;
            const suf_end = @min(state.cursor + 500, buf_len);

            const pre_u32 = state.buffer.slice(pre_start, state.cursor) catch null;
            defer if (pre_u32) |p| state.allocator.free(p);
            const suf_u32 = state.buffer.slice(state.cursor, suf_end) catch null;
            defer if (suf_u32) |s| state.allocator.free(s);

            const pre_utf8 = if (pre_u32) |p| buffer_mod.codepointsToUtf8(state.allocator, p) catch null else null;
            defer if (pre_utf8) |p| state.allocator.free(p);
            const suf_utf8 = if (suf_u32) |s| buffer_mod.codepointsToUtf8(state.allocator, s) catch null else null;
            defer if (suf_utf8) |s| state.allocator.free(s);

            sa.submit(.{
                .prefix = if (pre_utf8) |p| p else "",
                .suffix = if (suf_utf8) |s| s else "",
                .max_tokens = 64,
            }) catch {};
        }
    }

    // Drain new tokens into ghost buffer
    if (state.sa_active) {
        var new_tokens = std.ArrayList([]u8).empty;
        defer {
            for (new_tokens.items) |t| state.allocator.free(t);
            new_tokens.deinit(state.allocator);
        }
        sa.drainTokens(&new_tokens) catch {};
        for (new_tokens.items) |t| {
            state.sa_ghost.appendSlice(state.allocator, t) catch {};
        }
    }
}

/// Accept ghost text: insert into buffer, clear ghost state.
fn saAcceptGhost(state: *EditorState) void {
    if (state.sa_ghost.items.len == 0) return;
    if (state.smart_assist) |sa| sa.cancel();

    const u32s = buffer_mod.utf8ToCodepoints(state.allocator, state.sa_ghost.items) catch {
        saCancelGhost(state);
        return;
    };
    defer state.allocator.free(u32s);

    const pos = state.cursor;
    state.buffer.insert(pos, u32s) catch {
        saCancelGhost(state);
        return;
    };
    state.pushUndo(pos, &.{}, u32s) catch {};
    state.cursor = pos + u32s.len;
    state.modified = true;
    state.symbols_dirty = true;
    state.desired_col = null;
    state.selection_anchor = null;
    state.ensureCursorVisible();
    state.updateTitle();
    state.sa_ghost.clearRetainingCapacity();
    state.sa_debounce = -1;
    state.sa_active = false;
}

/// Render ghost text glyphs in a muted colour starting at the cursor position.
fn saRenderGhost(
    state: *const EditorState,
    instances: []GlyphInstance,
    count: *u32,
    atlas: GlyphAtlasInfo,
    theme: *const Theme,
    cursor_lc: struct { line: usize, col: usize },
    gutter_px: f32,
    vis_ln: usize,
    vis_cl: usize,
) void {
    const ghost_fg = theme.gutter_fg;
    var display_line = cursor_lc.line;
    var display_col = cursor_lc.col;
    var i: usize = 0;
    const text = state.sa_ghost.items;
    while (i < text.len) {
        const b0 = text[i];
        var cp: u32 = undefined;
        var stride: usize = 1;
        if (b0 < 0x80) {
            cp = b0;
        } else if (b0 < 0xE0 and i + 1 < text.len) {
            cp = (@as(u32, b0 & 0x1F) << 6) | (text[i + 1] & 0x3F);
            stride = 2;
        } else if (b0 < 0xF0 and i + 2 < text.len) {
            cp = (@as(u32, b0 & 0x0F) << 12) | (@as(u32, text[i + 1] & 0x3F) << 6) | (text[i + 2] & 0x3F);
            stride = 3;
        } else if (i + 3 < text.len) {
            cp = (@as(u32, b0 & 0x07) << 18) | (@as(u32, text[i + 1] & 0x3F) << 12) | (@as(u32, text[i + 2] & 0x3F) << 6) | (text[i + 3] & 0x3F);
            stride = 4;
        }
        i += stride;

        if (cp == '\n') {
            display_line += 1;
            display_col = 0;
            continue;
        }
        if (cp < 0x20) continue; // skip control chars

        if (display_line < state.scroll_line) continue;
        if (display_line >= state.scroll_line + vis_ln) break;
        if (display_col < state.scroll_col or display_col >= state.scroll_col + vis_cl) {
            display_col += 1;
            continue;
        }

        if (count.* >= @as(u32, @intCast(instances.len))) break;

        const screen_x = gutter_px + @as(f32, @floatFromInt(display_col - state.scroll_col)) * atlas.cell_width;
        const screen_y = @as(f32, @floatFromInt(display_line - state.scroll_line)) * atlas.cell_height;
        const uv = platform.codepointToAtlasUV(cp, atlas);
        instances[count.*] = GlyphInstance.make(
            screen_x,
            screen_y,
            uv.u,
            uv.v,
            ghost_fg,
            theme.editor_bg,
            0,
        );
        count.* += 1;
        display_col += 1;
    }
}

fn handleSelectionModifier(state: *EditorState, mods: Modifiers) void {
    if (mods.hasShift()) {
        // Start or extend selection
        if (state.selection_anchor == null) {
            state.selection_anchor = state.cursor;
        }
    } else {
        // Clear selection
        state.selection_anchor = null;
    }
}

// ─── Word Boundary Helpers ──────────────────────────────────────────────────

fn wordBoundaryLeft(state: *const EditorState) usize {
    if (state.cursor == 0) return 0;
    var pos = state.cursor - 1;

    // Skip whitespace
    while (pos > 0) {
        const ch = state.buffer.charAt(pos) orelse break;
        if (ch != ' ' and ch != '\t' and ch != '\n') break;
        pos -= 1;
    }

    // Skip word characters
    while (pos > 0) {
        const ch = state.buffer.charAt(pos - 1) orelse break;
        if (!isIdentChar(ch)) break;
        pos -= 1;
    }

    return pos;
}

/// Word boundary right for navigation (Alt+Right): skips word then whitespace
/// so the cursor lands at the start of the next word.
fn wordBoundaryRight(state: *const EditorState) usize {
    const len = state.buffer.length();
    if (state.cursor >= len) return len;
    var pos = state.cursor;

    // Skip current word characters
    while (pos < len) {
        const ch = state.buffer.charAt(pos) orelse break;
        if (!isIdentChar(ch)) break;
        pos += 1;
    }

    // Skip whitespace
    while (pos < len) {
        const ch = state.buffer.charAt(pos) orelse break;
        if (ch != ' ' and ch != '\t' and ch != '\n') break;
        pos += 1;
    }

    return pos;
}

/// Word boundary right for selection (double-click): stops at the end of the
/// word without consuming trailing whitespace or newlines.
fn wordBoundaryRightSelect(state: *const EditorState) usize {
    const len = state.buffer.length();
    if (state.cursor >= len) return len;
    var pos = state.cursor;

    // Skip current word characters only — no trailing whitespace
    while (pos < len) {
        const ch = state.buffer.charAt(pos) orelse break;
        if (!isIdentChar(ch)) break;
        pos += 1;
    }

    return pos;
}

// ─── Mouse Handling ─────────────────────────────────────────────────────────

/// Hit-test the splitter divider.  Returns true when the mouse Y falls within
/// the divider grab zone (the divider cell-height plus a few pixels of slop
/// on each side for a comfortable grab target).
fn isOverDivider(state: *const EditorState, y: f32) bool {
    const div_y = state.dividerY() orelse return false;
    const ch = state.atlas.cell_height;
    const slop: f32 = 3.0; // extra pixels above/below for easy grab
    return y >= div_y - slop and y < div_y + ch + slop;
}

fn handleMouseDown(state: *EditorState, event: *const MouseEvent) void {
    const atlas = state.atlas;
    if (atlas.cell_width <= 0 or atlas.cell_height <= 0) return;
    saCancelGhost(state);

    const gutter_px = @as(f32, @floatFromInt(GUTTER_CHARS)) * atlas.cell_width;

    // ── Drag continuation (click_count == 0) ────────────────────────────
    // click_count == 0 means this is a drag-continuation event (mouseDragged).

    // Terminal selection drag continuation
    if (state.term_selecting and event.click_count == 0) {
        const term_area_top_drag: f32 = blk: {
            var ch: f32 = atlas.cell_height;
            if (state.find_state.visible) ch += atlas.cell_height;
            if (state.find_state.replace_visible) ch += atlas.cell_height;
            break :blk state.viewport_height - ch -
                @as(f32, @floatFromInt(state.terminal_lines)) * atlas.cell_height;
        };
        state.term_sel_end = state.termPixelToPos(event.x, event.y, term_area_top_drag);
        return;
    }

    // Splitter drag continuation
    if (state.splitter_dragging and event.click_count == 0) {
        const delta_y = event.y - state.splitter_drag_start_y;
        // Positive delta_y = mouse moved down = terminal shrinks.
        // Each cell_height of movement = 1 line.
        const delta_lines = @as(i32, @intFromFloat(delta_y / atlas.cell_height));
        const new_lines_i = @as(i32, @intCast(state.splitter_drag_start_lines)) - delta_lines;
        const clamped = @as(u32, @intCast(@max(@as(i32, TERMINAL_MIN_LINES), @min(new_lines_i, @as(i32, @intCast(state.maxTerminalLines()))))));
        if (clamped != state.terminal_lines) {
            state.terminal_lines = clamped;
            state.terminal_fullscreen = false;
            state.updateTerminalSize();
        }
        if (!state.cursor_is_resize) {
            platform.ed_platform_set_cursor(platform.CURSOR_RESIZE_VERTICAL);
            state.cursor_is_resize = true;
        }
        return;
    }

    // Determine the terminal area top Y so we can route clicks
    const term_area_top: f32 = if (state.terminal_visible) blk: {
        var chrome_h: f32 = atlas.cell_height; // status bar
        if (state.find_state.visible) chrome_h += atlas.cell_height;
        if (state.find_state.replace_visible) chrome_h += atlas.cell_height;
        break :blk state.viewport_height - chrome_h -
            @as(f32, @floatFromInt(state.terminal_lines + 1)) * atlas.cell_height; // +1 for divider
    } else state.viewport_height;

    // ── Splitter divider click ──────────────────────────────────────────
    if (state.terminal_visible and isOverDivider(state, event.y) and
        event.x < state.viewport_width - SCROLLBAR_WIDTH)
    {
        // Check if click is on the fullscreen sigil (right edge of divider)
        const term_cols_f = state.viewport_width / atlas.cell_width;
        const sigil_len: f32 = 5.0; // " [^] " or " [v] "
        const sigil_x = (term_cols_f - sigil_len) * atlas.cell_width;
        if (event.x >= sigil_x) {
            state.toggleTerminalFullscreen();
            return;
        }

        // Start a splitter drag
        state.splitter_dragging = true;
        state.splitter_drag_start_y = event.y;
        state.splitter_drag_start_lines = state.terminal_lines;
        if (!state.cursor_is_resize) {
            platform.ed_platform_set_cursor(platform.CURSOR_RESIZE_VERTICAL);
            state.cursor_is_resize = true;
        }
        return;
    }

    // Check if click is in the terminal area (below divider)
    if (state.terminal_visible and event.y >= term_area_top and
        event.x < state.viewport_width - SCROLLBAR_WIDTH)
    {
        // The terminal grid starts one cell below the divider
        const term_grid_top = term_area_top + atlas.cell_height;

        state.focus = .terminal;
        state.cursor_blink_timer = 0;
        state.cursor_visible = true;

        // Drag continuation (click_count == 0): extend terminal selection
        if (event.click_count == 0) {
            if (state.term_sel_anchor != null) {
                state.term_sel_end = state.termPixelToPos(event.x, event.y, term_grid_top);
                state.term_selecting = true;
            }
            return;
        }

        // Double-click: select word at click position
        if (event.click_count == 2) {
            const click_pos = state.termPixelToPos(event.x, event.y, term_grid_top);
            // Expand left to find word start
            var left = click_pos.col;
            while (left > 0) {
                const cell = state.terminal.getScrollbackCell(click_pos.line, left - 1);
                const cp = cell.codepoint;
                if (cp == ' ' or cp == 0 or cp == '\t') break;
                left -= 1;
            }
            // Expand right to find word end
            var right = click_pos.col;
            while (right < state.terminal.cols) {
                const cell = state.terminal.getScrollbackCell(click_pos.line, right);
                const cp = cell.codepoint;
                if (cp == ' ' or cp == 0 or cp == '\t') break;
                right += 1;
            }
            state.term_sel_anchor = .{ .line = click_pos.line, .col = left };
            state.term_sel_end = .{ .line = click_pos.line, .col = right };
            state.term_selecting = false;
            return;
        }

        // Triple-click: select entire line
        if (event.click_count >= 3) {
            const click_pos = state.termPixelToPos(event.x, event.y, term_grid_top);
            state.term_sel_anchor = .{ .line = click_pos.line, .col = 0 };
            state.term_sel_end = .{ .line = click_pos.line, .col = state.terminal.cols };
            state.term_selecting = false;
            return;
        }

        // Single click: start a new selection (anchor)
        const click_pos = state.termPixelToPos(event.x, event.y, term_grid_top);
        state.term_sel_anchor = click_pos;
        state.term_sel_end = click_pos;
        state.term_selecting = true;
        return;
    }

    // Check if click is in the gutter (fold indicator)
    if (event.x <= gutter_px and event.x >= 0 and event.click_count == 1) {
        const line_f = event.y / atlas.cell_height;
        const click_line = @as(usize, @intFromFloat(@max(line_f, 0)));
        const target_line = state.screenRowToBufferLine(click_line) orelse return;

        // Check if click is in the fold indicator column (column 5)
        const col_f = event.x / atlas.cell_width;
        const click_col = @as(usize, @intFromFloat(@max(col_f, 0)));
        if (click_col == 5) {
            state.toggleFoldAtLine(target_line);
            state.adjustScrollForFolds();
            return;
        }
    }

    // Check if click is in the editor area
    if (event.x > gutter_px and event.x < state.viewport_width - SCROLLBAR_WIDTH) {
        state.focus = .editor;

        // Calculate line and column from click position
        const col_f = (event.x - gutter_px) / atlas.cell_width;
        const line_f = event.y / atlas.cell_height;

        const click_col = @as(usize, @intFromFloat(@max(col_f, 0)));
        const click_line = @as(usize, @intFromFloat(@max(line_f, 0)));

        const target_line = state.screenRowToBufferLine(click_line) orelse return;
        const target_col = state.scroll_col + click_col;

        // If inline rename is active, cancel it when clicking outside the word
        if (state.rename_state.visible) {
            const click_offset = state.buffer.lineColToOffset(target_line, target_col);
            const r_primary = state.rename_state.primary_offset;
            const r_word_len = state.rename_state.currentWordLen(&state.buffer);
            const r_end = r_primary + r_word_len;
            if (click_offset < r_primary or click_offset > r_end) {
                state.revertRename();
                return;
            }
        }

        // Drag continuation (click_count == 0): extend selection
        if (event.click_count == 0) {
            if (state.selection_anchor == null) {
                state.selection_anchor = state.cursor;
            }
            state.cursor = state.buffer.lineColToOffset(target_line, target_col);
        }
        // Double-click: select word
        else if (event.click_count == 2) {
            state.cursor = state.buffer.lineColToOffset(target_line, target_col);
            state.selection_anchor = wordBoundaryLeft(state);
            state.cursor = wordBoundaryRightSelect(state);
        }
        // Triple-click: select line
        else if (event.click_count >= 3) {
            const range = state.buffer.lineRange(target_line) orelse return;
            state.selection_anchor = range.start;
            state.cursor = range.end;
        }
        // Single click: position cursor
        else {
            state.cursor = state.buffer.lineColToOffset(target_line, target_col);
            state.selection_anchor = null;
        }

        state.desired_col = null;
        state.cursor_blink_timer = 0;
        state.cursor_visible = true;
    }
    // Check if click is in the scrollbar
    else if (event.x >= state.viewport_width - SCROLLBAR_WIDTH) {
        // Click-to-scroll in scrollbar: map click Y to a line in the buffer
        if (atlas.cell_height > 0) {
            const total_lines = state.buffer.lineCount();
            // Use the editor area height, not the full viewport
            const editor_area_h: f32 = if (state.dividerY()) |dy| dy else blk: {
                const status_h = @as(f32, @floatFromInt(STATUS_BAR_LINES)) * atlas.cell_height;
                break :blk state.viewport_height - status_h;
            };
            if (editor_area_h > 0) {
                const click_ratio = event.y / editor_area_h;
                const target_line = @as(usize, @intFromFloat(@min(
                    click_ratio * @as(f32, @floatFromInt(total_lines)),
                    @as(f32, @floatFromInt(if (total_lines > 0) total_lines - 1 else 0)),
                )));
                state.scroll_line = if (target_line >= state.visibleLines() / 2)
                    target_line - state.visibleLines() / 2
                else
                    0;
                state.adjustScrollForFolds();
            }
        }
    }
}

fn handleScroll(state: *EditorState, _: f32, dy: f32) void {
    if (state.atlas.cell_height <= 0) return;

    // Negate dy: macOS scrollingDeltaY is positive for "scroll up" (content
    // moves down), but our scroll_line logic treats positive as "scroll down".
    // Negating aligns with the system scroll direction (including natural
    // scrolling preference).
    const lines_to_scroll = -dy / state.atlas.cell_height;
    const scroll_delta = @as(i64, @intFromFloat(lines_to_scroll));

    // Determine if the scroll is in the terminal area.
    // We check if terminal is visible and focused, OR if we detect the
    // scroll Y position would be in the terminal region. Since we don't
    // get Y in the scroll callback, use focus as the heuristic.
    if (state.focus == .terminal and state.terminal_visible) {
        // Scroll the terminal scrollback
        // Positive delta = scroll up (into history), negative = towards live
        state.scrollTerminal(-scroll_delta);
        return;
    }

    if (scroll_delta < 0) {
        const abs_delta = @as(usize, @intCast(-scroll_delta));
        if (state.scroll_line >= abs_delta) {
            state.scroll_line -= abs_delta;
        } else {
            state.scroll_line = 0;
        }
    } else {
        const max_scroll = if (state.buffer.lineCount() > state.visibleLines())
            state.buffer.lineCount() - state.visibleLines()
        else
            0;
        state.scroll_line = @min(state.scroll_line + @as(usize, @intCast(scroll_delta)), max_scroll);
    }
    // Ensure scroll doesn't land inside a folded region
    state.adjustScrollForFolds();
}

fn handleWindowEvent(state: *EditorState, event: *const WindowEvent) void {
    switch (event.event_type) {
        .resized => {
            state.viewport_width = event.width;
            state.viewport_height = event.height;
            state.viewport_scale = event.scale;
            state.updateTitle();
            if (state.terminal_visible) {
                state.updateTerminalSize();
            }
        },
        .focus_gained => {
            state.window_focused = true;
            state.cursor_blink_timer = 0;
            state.cursor_visible = true;
        },
        .focus_lost => {
            state.window_focused = false;
        },
        .close_requested => {
            // Handled in ObjC: windowShouldClose / applicationShouldTerminate
            // only prompt when state.modified == true.
        },
        else => {},
    }
}

// ─── Exported Callbacks (called from ObjC bridge) ───────────────────────────

export fn ed_on_frame(dt: f64) callconv(.c) EdFrameData {
    const state = g_state orelse {
        return std.mem.zeroes(EdFrameData);
    };
    return buildFrame(state, dt);
}

export fn ed_on_key_down(event: *const KeyEvent) callconv(.c) void {
    const state = g_state orelse return;
    handleKeyDown(state, event);
}

export fn ed_on_key_up(_: *const KeyEvent) callconv(.c) void {
    // Currently unused — may be needed for modifier tracking
}

export fn ed_on_text_input(codepoint: u32) callconv(.c) void {
    const state = g_state orelse return;
    handleTextInput(state, codepoint);
}

export fn ed_on_mouse_down(event: *const MouseEvent) callconv(.c) void {
    const state = g_state orelse return;
    handleMouseDown(state, event);
}

export fn ed_on_mouse_up(_: *const MouseEvent) callconv(.c) void {
    const state = g_state orelse return;
    if (state.splitter_dragging) {
        state.splitter_dragging = false;
        if (state.cursor_is_resize) {
            platform.ed_platform_set_cursor(platform.CURSOR_ARROW);
            state.cursor_is_resize = false;
        }
    }
    // End terminal selection drag
    if (state.term_selecting) {
        state.term_selecting = false;
    }
}

export fn ed_on_mouse_moved(x: f32, y: f32) callconv(.c) void {
    const state = g_state orelse return;
    // Show a resize cursor when hovering over the splitter divider.
    if (state.splitter_dragging) {
        // Keep resize cursor while actively dragging.
        return;
    }
    const want_resize = state.terminal_visible and x < state.viewport_width - SCROLLBAR_WIDTH and isOverDivider(state, y);
    if (want_resize and !state.cursor_is_resize) {
        platform.ed_platform_set_cursor(platform.CURSOR_RESIZE_VERTICAL);
        state.cursor_is_resize = true;
    } else if (!want_resize and state.cursor_is_resize) {
        platform.ed_platform_set_cursor(platform.CURSOR_ARROW);
        state.cursor_is_resize = false;
    }
}

export fn ed_on_scroll(_: f32, dy: f32) callconv(.c) void {
    const state = g_state orelse return;
    handleScroll(state, 0, dy);
}

export fn ed_on_window_event(event: *const WindowEvent) callconv(.c) void {
    const state = g_state orelse return;
    handleWindowEvent(state, event);
}

// ─── Context Menu Support ───────────────────────────────────────────────────
//
// These C-ABI exports are called from ed_metal_bridge.m to implement the
// right-click context menu.  The ObjC side calls ed_context_menu_query()
// to learn what items to enable, then ed_context_menu_action() when the
// user picks one.

/// Context menu query flags (bitfield).
const CTX_HAS_SELECTION: u32 = 1 << 0;
const CTX_HAS_SYMBOL: u32 = 1 << 1;
const CTX_HAS_CLIPBOARD: u32 = 1 << 2;
const CTX_HAS_TERM_SELECTION: u32 = 1 << 3;

/// Query the editor state to determine which context menu items should be
/// enabled.  Returns a bitfield of CTX_* flags.
export fn ed_context_menu_query() callconv(.c) u32 {
    const state = g_state orelse return 0;
    var flags: u32 = 0;

    if (state.selectionRange() != null) {
        flags |= CTX_HAS_SELECTION;
    }

    if (state.canGoToDefinition()) {
        flags |= CTX_HAS_SYMBOL;
    }

    // Check clipboard
    const clip = platform.ed_platform_clipboard_get();
    if (clip) |c| {
        flags |= CTX_HAS_CLIPBOARD;
        platform.ed_platform_clipboard_free(c);
    }

    // Terminal selection
    if (state.termSelRange() != null) {
        flags |= CTX_HAS_TERM_SELECTION;
    }

    return flags;
}

/// Get the word under the cursor (or selected identifier) into a C buffer.
/// Returns the number of bytes written (not including the null terminator
/// which is always appended).  The caller must provide at least `buf_len`
/// bytes.  If no word is found, returns 0 and buf[0] is set to 0.
export fn ed_context_menu_word(buf: [*]u8, buf_len: u32) callconv(.c) u32 {
    const state = g_state orelse {
        if (buf_len > 0) buf[0] = 0;
        return 0;
    };
    const out = buf[0..buf_len];
    const n = state.wordUnderCursorUtf8(out);
    // Null-terminate
    if (n < buf_len) {
        buf[n] = 0;
    } else if (buf_len > 0) {
        buf[buf_len - 1] = 0;
    }
    return @intCast(n);
}

/// Context menu action IDs (must match the ObjC side).
const CTX_ACTION_GO_TO_DEFINITION: u32 = 0;
const CTX_ACTION_FIND_REFERENCES: u32 = 1;
const CTX_ACTION_SYMBOL_OUTLINE: u32 = 2;
const CTX_ACTION_CUT: u32 = 3;
const CTX_ACTION_COPY: u32 = 4;
const CTX_ACTION_PASTE: u32 = 5;
const CTX_ACTION_SELECT_ALL: u32 = 6;
const CTX_ACTION_TOGGLE_COMMENT: u32 = 7;
const CTX_ACTION_DUPLICATE_LINE: u32 = 8;
const CTX_ACTION_FORMAT: u32 = 9;
const CTX_ACTION_RENAME: u32 = 10;
// Terminal-pane context menu actions
const CTX_ACTION_TERM_CLEAR: u32 = 20;
const CTX_ACTION_TERM_COPY: u32 = 21;
const CTX_ACTION_TERM_PASTE: u32 = 22;

// ── Menu Bar Action IDs (100+) ──────────────────────────────────────────
const MENU_NEW: u32 = 100;
const MENU_OPEN: u32 = 101;
const MENU_SAVE: u32 = 102;
const MENU_SAVE_AS: u32 = 103;
const MENU_EXPORT_UTF8: u32 = 104;
const MENU_UNDO: u32 = 110;
const MENU_REDO: u32 = 111;
const MENU_CUT: u32 = 112;
const MENU_COPY: u32 = 113;
const MENU_PASTE: u32 = 114;
const MENU_SELECT_ALL: u32 = 115;
const MENU_FIND: u32 = 116;
const MENU_FIND_REPLACE: u32 = 117;
const MENU_FIND_NEXT: u32 = 118;
const MENU_FIND_PREV: u32 = 119;
const MENU_GO_TO_LINE: u32 = 120;
const MENU_FORMAT: u32 = 130;
const MENU_TOGGLE_COMMENT: u32 = 131;
const MENU_DUPLICATE_LINE: u32 = 132;
const MENU_FOLD: u32 = 133;
const MENU_UNFOLD_ALL: u32 = 134;
const MENU_FOLD_ALL: u32 = 135;
const MENU_RENAME: u32 = 136;
const MENU_GO_TO_DEF: u32 = 137;
const MENU_FIND_REFS: u32 = 138;
const MENU_SYMBOL_OUTLINE: u32 = 139;
const MENU_MATCH_BRACKET: u32 = 140;
const MENU_ANALYSE: u32 = 141;
const MENU_TOGGLE_TERMINAL: u32 = 150;
const MENU_TERMINAL_FULLSCREEN: u32 = 151;
const MENU_THEME_NEXT: u32 = 152;
const MENU_THEME_PREV: u32 = 153;
const MENU_INSERT_FILE: u32 = 154;
const MENU_COMPILER_SETTINGS: u32 = 155;
const MENU_RUN: u32 = 160;
const MENU_BUILD: u32 = 161;
const MENU_STOP: u32 = 162;
const MENU_VIEW_IR: u32 = 163;
const MENU_VIEW_ASM: u32 = 164;
const MENU_DISASSEMBLE: u32 = 165;
const MENU_VIEW_AST: u32 = 166;
const MENU_VIEW_CFG: u32 = 167;
const MENU_VIEW_SYMBOLS: u32 = 168;
const MENU_HELP: u32 = 170;
const MENU_MOVE_LINE_UP: u32 = 171;
const MENU_MOVE_LINE_DOWN: u32 = 172;

/// Perform a context menu action.  Called from the ObjC menu item handlers.
export fn ed_context_menu_action(action: u32) callconv(.c) void {
    const state = g_state orelse return;
    switch (action) {
        CTX_ACTION_GO_TO_DEFINITION => {
            state.goToDefinition();
        },
        CTX_ACTION_FIND_REFERENCES => {
            state.findReferencesAtCursor();
        },
        CTX_ACTION_RENAME => {
            state.openRename();
        },
        CTX_ACTION_SYMBOL_OUTLINE => {
            state.openSymbolOutline();
        },
        CTX_ACTION_CUT => {
            // Synthesise Cmd+X
            sendSyntheticCmd(VK.X);
        },
        CTX_ACTION_COPY => {
            sendSyntheticCmd(VK.C);
        },
        CTX_ACTION_PASTE => {
            sendSyntheticCmd(VK.V);
        },
        CTX_ACTION_SELECT_ALL => {
            sendSyntheticCmd(VK.A);
        },
        CTX_ACTION_TOGGLE_COMMENT => {
            sendSyntheticCmd(VK.SLASH);
        },
        CTX_ACTION_DUPLICATE_LINE => {
            sendSyntheticCmd(VK.D);
        },
        CTX_ACTION_FORMAT => {
            // Cmd+Shift+I
            sendSyntheticCmdShift(VK.I);
        },
        // ── Terminal pane actions ────────────────────────────────────────
        CTX_ACTION_TERM_CLEAR => {
            state.terminalClear();
        },
        CTX_ACTION_TERM_COPY => {
            _ = state.copyTermSelection();
        },
        CTX_ACTION_TERM_PASTE => {
            // Paste clipboard text into stdin when a program is running,
            // echoing each character to the terminal as if typed.
            if (state.jit_runner.isRunning()) {
                const ct = platform.ed_platform_clipboard_get() orelse return;
                defer platform.ed_platform_clipboard_free(ct);
                const clip_str = std.mem.span(ct);
                state.terminal.writeBytes(clip_str);
                for (clip_str) |b| {
                    _ = state.jit_runner.stdin_input.append(b);
                }
                if (state.terminal_pinned_to_bottom) {
                    state.terminal_scroll_offset = 0;
                }
            }
        },
        // ── Menu Bar Actions ────────────────────────────────────────────
        MENU_NEW => sendSyntheticCmd(VK.N),
        MENU_OPEN => sendSyntheticCmd(VK.O),
        MENU_SAVE => sendSyntheticCmd(VK.S),
        MENU_SAVE_AS => sendSyntheticCmdShift(VK.S),
        MENU_EXPORT_UTF8 => sendSyntheticCmdShift(VK.E),
        MENU_UNDO => sendSyntheticCmd(VK.Z),
        MENU_REDO => sendSyntheticCmdShift(VK.Z),
        MENU_CUT => sendSyntheticCmd(VK.X),
        MENU_COPY => sendSyntheticCmd(VK.C),
        MENU_PASTE => sendSyntheticCmd(VK.V),
        MENU_SELECT_ALL => sendSyntheticCmd(VK.A),
        MENU_FIND => sendSyntheticCmd(VK.F),
        MENU_FIND_REPLACE => sendSyntheticCmd(VK.H),
        MENU_FIND_NEXT => sendSyntheticCmd(VK.G),
        MENU_FIND_PREV => sendSyntheticCmdShift(VK.G),
        MENU_GO_TO_LINE => sendSyntheticCmd(VK.L),
        MENU_FORMAT => sendSyntheticCmdShift(VK.I),
        MENU_TOGGLE_COMMENT => sendSyntheticCmd(VK.SLASH),
        MENU_DUPLICATE_LINE => sendSyntheticCmd(VK.D),
        MENU_FOLD => sendSyntheticCmdShift(VK.LEFT_BRACKET),
        MENU_UNFOLD_ALL => sendSyntheticCmdShift(VK.RIGHT_BRACKET),
        MENU_FOLD_ALL => {
            state.foldAll();
            state.adjustScrollForFolds();
        },
        MENU_RENAME => state.openRename(),
        MENU_GO_TO_DEF => sendSyntheticKey(VK.F12),
        MENU_FIND_REFS => state.findReferencesAtCursor(),
        MENU_SYMBOL_OUTLINE => state.openSymbolOutline(),
        MENU_MATCH_BRACKET => sendSyntheticCmd(VK.M),
        MENU_ANALYSE => sendSyntheticCmdShift(VK.A),
        MENU_TOGGLE_TERMINAL => sendSyntheticCmd(VK.J),
        MENU_TERMINAL_FULLSCREEN => sendSyntheticCmdShift(VK.J),
        MENU_THEME_NEXT => sendSyntheticCmd(VK.RIGHT_BRACKET),
        MENU_THEME_PREV => sendSyntheticCmd(VK.LEFT_BRACKET),
        MENU_INSERT_FILE => sendSyntheticCmdShift(VK.P),
        MENU_COMPILER_SETTINGS => state.openCompilerSettingsDialog(),
        MENU_RUN => sendSyntheticKey(VK.F5),
        MENU_BUILD => sendSyntheticCmd(VK.B),
        MENU_STOP => sendSyntheticCmd(VK.PERIOD),
        MENU_VIEW_IR => sendSyntheticKey(VK.F7),
        MENU_VIEW_ASM => sendSyntheticKey(VK.F8),
        MENU_DISASSEMBLE => sendSyntheticKey(VK.F6),
        MENU_VIEW_AST => sendSyntheticKey(VK.F9),
        MENU_VIEW_CFG => sendSyntheticKey(VK.F10),
        MENU_VIEW_SYMBOLS => sendSyntheticKey(VK.F11),
        MENU_HELP => sendSyntheticKey(VK.F1),
        MENU_MOVE_LINE_UP => sendSyntheticAlt(VK.UP_ARROW),
        MENU_MOVE_LINE_DOWN => sendSyntheticAlt(VK.DOWN_ARROW),
        else => {},
    }
    platform.ed_platform_request_redraw();
}

/// Helper: send a synthetic Cmd+<key> event through the normal key handler.
fn sendSyntheticCmd(keycode: u16) void {
    const state = g_state orelse return;
    const ke = KeyEvent{
        .codepoint = 0,
        .keycode = keycode,
        .modifiers = .{ .cmd = true, .shift = false, .ctrl = false, .alt = false, .caps_lock = false, .fn_key = false, ._pad = 0 },
        .is_repeat = 0,
        ._pad = 0,
    };
    handleKeyDown(state, &ke);
}

/// Helper: send a synthetic Cmd+Shift+<key> event.
fn sendSyntheticCmdShift(keycode: u16) void {
    const state = g_state orelse return;
    const ke = KeyEvent{
        .codepoint = 0,
        .keycode = keycode,
        .modifiers = .{ .cmd = true, .shift = true, .ctrl = false, .alt = false, .caps_lock = false, .fn_key = false, ._pad = 0 },
        .is_repeat = 0,
        ._pad = 0,
    };
    handleKeyDown(state, &ke);
}

/// Helper: send a synthetic unmodified key event (for function keys).
fn sendSyntheticKey(keycode: u16) void {
    const state = g_state orelse return;
    const ke = KeyEvent{
        .codepoint = 0,
        .keycode = keycode,
        .modifiers = .{ .cmd = false, .shift = false, .ctrl = false, .alt = false, .caps_lock = false, .fn_key = false, ._pad = 0 },
        .is_repeat = 0,
        ._pad = 0,
    };
    handleKeyDown(state, &ke);
}

/// Helper: send a synthetic Alt+<key> event.
fn sendSyntheticAlt(keycode: u16) void {
    const state = g_state orelse return;
    const ke = KeyEvent{
        .codepoint = 0,
        .keycode = keycode,
        .modifiers = .{ .cmd = false, .shift = false, .ctrl = false, .alt = true, .caps_lock = false, .fn_key = false, ._pad = 0 },
        .is_repeat = 0,
        ._pad = 0,
    };
    handleKeyDown(state, &ke);
}

/// Return 1 if the given backing-pixel coordinate is inside the terminal pane.
/// Called by the ObjC bridge to decide which context menu to show.
export fn ed_context_menu_is_terminal(x: f32, y: f32) callconv(.c) c_int {
    _ = x;
    const state = g_state orelse return 0;
    if (!state.terminal_visible) return 0;
    const div_y = state.dividerY() orelse return 0;
    return if (y >= div_y) 1 else 0;
}

/// Position the cursor at a given pixel coordinate.  Called by the ObjC
/// bridge *before* showing the context menu so that Go-to-Definition and
/// word-under-cursor resolve at the click location rather than the old
/// cursor position.
export fn ed_context_menu_position_cursor(x: f32, y: f32) callconv(.c) void {
    const state = g_state orelse return;
    const atlas = state.atlas;
    if (atlas.cell_width <= 0 or atlas.cell_height <= 0) return;

    const gutter_px = @as(f32, @floatFromInt(GUTTER_CHARS)) * atlas.cell_width;

    // Only reposition if click is in the editor text area
    if (x > gutter_px and x < state.viewport_width - SCROLLBAR_WIDTH) {
        const col_f = (x - gutter_px) / atlas.cell_width;
        const line_f = y / atlas.cell_height;
        const click_col = @as(usize, @intFromFloat(@max(col_f, 0)));
        const click_line = @as(usize, @intFromFloat(@max(line_f, 0)));
        const target_line = state.scroll_line + click_line;
        const target_col = state.scroll_col + click_col;

        // If there's no selection, move cursor to click position.
        // If there IS a selection, keep it (user right-clicked on selected text).
        if (state.selection_anchor == null) {
            state.cursor = state.buffer.lineColToOffset(target_line, target_col);
            state.desired_col = null;
            state.cursor_blink_timer = 0;
            state.cursor_visible = true;
        }
    }
    state.focus = .editor;
}

// ─── File Loading ───────────────────────────────────────────────────────────

fn loadFile(state: *EditorState, path: []const u8) !void {
    // Replace buffer
    state.buffer.deinit();

    if (baz_mod.isBazPath(path)) {
        // ── .baz format: zstd-compressed UTF-32 codepoints ──────
        const cps = baz_mod.loadBaz(state.allocator, path) catch {
            state.buffer = try RopeBuffer.init(state.allocator);
            return error.LoadFailed;
        };
        defer state.allocator.free(cps);
        state.buffer = try RopeBuffer.initFromSlice(state.allocator, cps);
    } else {
        // ── Plain text: UTF-8 ───────────────────────────────────
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        const size = stat.size;

        const contents = try state.allocator.alloc(u8, size);
        defer state.allocator.free(contents);

        const bytes_read = try file.readAll(contents);
        const data = contents[0..bytes_read];

        state.buffer = try RopeBuffer.initFromUtf8(state.allocator, data);
    }
    state.cursor = 0;
    state.scroll_line = 0;
    state.scroll_col = 0;
    state.selection_anchor = null;
    state.modified = false;
    state.desired_col = null;
    state.fold_regions.clearRetainingCapacity();

    // Store file path
    if (state.file_path) |old_path| {
        state.allocator.free(old_path);
    }
    state.file_path = try state.allocator.dupe(u8, path);

    // Clear undo/redo
    for (state.undo_stack.items) |*e| {
        e.deinit(state.allocator);
    }
    state.undo_stack.clearRetainingCapacity();
    for (state.redo_stack.items) |*e| {
        e.deinit(state.allocator);
    }
    state.redo_stack.clearRetainingCapacity();
}

// ─── Main Entry Point ───────────────────────────────────────────────────────

pub fn main() !void {
    // ── Editor GUI mode ─────────────────────────────────────────────

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    g_allocator = allocator;

    // Create editor state
    var state = try EditorState.init(allocator);
    try state.initJitRunner();
    state.initSmartAssist();
    defer state.deinit();
    g_state = &state;
    defer {
        g_state = null;
    }

    // Parse command-line args — optional file to open
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Load a file if specified (bare filename with no flags = editor mode)
    if (args.len > 1) {
        loadFile(&state, args[1]) catch |err| {
            std.debug.print("Ed: cannot open '{s}': {}\n", .{ args[1], err });
        };
    } else {
        // Load a welcome/demo text
        const demo_text =
            \\' ============================================
            \\' Welcome to Ed — The FasterBASIC Editor
            \\' ============================================
            \\'
            \\' Press Cmd+] to cycle themes
            \\' Press Cmd+J to toggle terminal
            \\' Press Cmd+/ to toggle line comment
            \\'
            \\' Start typing your FasterBASIC program here!
            \\
            \\DIM greeting$ AS STRING
            \\greeting$ = "Hello, World!"
            \\
            \\FUNCTION Fibonacci(n AS INTEGER) AS INTEGER
            \\  IF n <= 1 THEN
            \\    Fibonacci = n
            \\    EXIT FUNCTION
            \\  END IF
            \\  Fibonacci = Fibonacci(n - 1) + Fibonacci(n - 2)
            \\END FUNCTION
            \\
            \\PRINT greeting$
            \\PRINT "Fibonacci(10) = "; Fibonacci(10)
            \\
            \\FOR i = 1 TO 20
            \\  PRINT i; " ";
            \\NEXT i
            \\PRINT
            \\
            \\' Worker example
            \\WORKER MyWorker
            \\  DIM result AS DOUBLE
            \\  result = 3.14159 * 2.0
            \\  SEND PARENT, result
            \\END WORKER
            \\
            \\DIM w AS INTEGER
            \\w = SPAWN MyWorker
            \\DIM pi2 AS DOUBLE
            \\pi2 = RECEIVE(w)
            \\PRINT "2*PI = "; pi2
            \\
            \\END
            \\
        ;
        state.buffer.deinit();
        state.buffer = try RopeBuffer.initFromUtf8(allocator, demo_text);
    }

    // Print welcome to terminal
    try state.terminalPrint("Ed v0.1 -- FasterBASIC Editor\r\n");
    try state.terminalPrint("Cmd+S Save  Cmd+O Open  Cmd+F Find  Cmd+H Replace\r\n");
    try state.terminalPrint("Cmd+] Theme  Cmd+J Terminal  F1 Help  F2 Case Toggle\r\n");
    try state.terminalPrint("Ready.\r\n");

    // Set up callbacks
    const callbacks = platform.EdCallbacks{
        .on_frame = &ed_on_frame,
        .on_key_down = &ed_on_key_down,
        .on_key_up = &ed_on_key_up,
        .on_text_input = &ed_on_text_input,
        .on_mouse_down = &ed_on_mouse_down,
        .on_mouse_up = &ed_on_mouse_up,
        .on_mouse_moved = &ed_on_mouse_moved,
        .on_scroll = &ed_on_scroll,
        .on_window_event = &ed_on_window_event,
    };

    // Initialize platform
    var title_buf: [512]u8 = undefined;
    const title_z: [*:0]const u8 = if (state.file_path) |p| blk: {
        const printed = std.fmt.bufPrint(&title_buf, "Ed — {s}", .{p}) catch "Ed";
        // null-terminate in-place
        if (printed.len < title_buf.len) {
            title_buf[printed.len] = 0;
            break :blk @ptrCast(title_buf[0..printed.len :0]);
        }
        break :blk "Ed";
    } else "Ed — untitled.baz";

    const init_result = platform.ed_platform_init(
        1440,
        900,
        title_z,
        "Menlo",
        14.0,
        &callbacks,
    );

    if (init_result != 0) {
        std.debug.print("Ed: platform initialisation failed\n", .{});
        return;
    }

    // Get atlas info
    state.atlas = platform.ed_platform_get_atlas_info();
    state.viewport_width = platform.ed_platform_get_width();
    state.viewport_height = platform.ed_platform_get_height();
    state.viewport_scale = platform.ed_platform_get_scale();

    // Initialize the retro graphics subsystem (command polling timer).
    // This must happen after platform init so the NSApplication run loop
    // exists, but before ed_platform_run() which enters the run loop.
    ed_graphics_init();

    // Enter the run loop (never returns)
    platform.ed_platform_run();
}

// ─── JIT Optimization Level ─────────────────────────────────────────────────

export fn ed_get_jit_opt_level() callconv(.c) u8 {
    const state = g_state orelse return 1;
    const level = compilerOptionMenuState(state.jit_runner.getCompilerOptions()).opt_level;
    state.jit_opt_level = level;
    return level;
}

export fn ed_set_jit_opt_level(level: u8) callconv(.c) void {
    const state = g_state orelse return;
    const next_level: u8 = if (level <= 3) level else 1;
    updateCompilerMenuOptions(state, next_level, compilerOptionMenuState(state.jit_runner.getCompilerOptions()).fast_math_trig);
}

export fn ed_get_jit_fast_math_trig() callconv(.c) u8 {
    const state = g_state orelse return 0;
    const enabled = compilerOptionMenuState(state.jit_runner.getCompilerOptions()).fast_math_trig;
    state.jit_fast_math_trig = enabled;
    return if (enabled) 1 else 0;
}

export fn ed_set_jit_fast_math_trig(enabled: u8) callconv(.c) void {
    const state = g_state orelse return;
    updateCompilerMenuOptions(state, compilerOptionMenuState(state.jit_runner.getCompilerOptions()).opt_level, enabled != 0);
}

const CompilerOptionMenuState = struct {
    opt_level: u8 = 1,
    fast_math_trig: bool = false,
};

fn compilerOptionMenuState(raw_options: []const u8) CompilerOptionMenuState {
    var state: CompilerOptionMenuState = .{};
    var cursor: usize = 0;

    while (nextCompilerOptionToken(raw_options, &cursor)) |token| {
        if (std.mem.eql(u8, token, "-O0")) {
            state.opt_level = 0;
        } else if (std.mem.eql(u8, token, "-O1")) {
            state.opt_level = 1;
        } else if (std.mem.eql(u8, token, "-O2")) {
            state.opt_level = 2;
        } else if (std.mem.eql(u8, token, "-O3")) {
            state.opt_level = 3;
        } else if (std.mem.eql(u8, token, "--fast-math-trig")) {
            state.fast_math_trig = true;
        }
    }

    return state;
}

fn updateCompilerMenuOptions(state: *EditorState, opt_level: u8, fast_math_trig: bool) void {
    const next_options = rebuildCompilerMenuOptions(state.allocator, state.jit_runner.getCompilerOptions(), opt_level, fast_math_trig) catch {
        state.terminal_visible = true;
        state.updateTerminalSize();
        state.terminalPrint("[Compiler settings] failed to apply optimization flags\r\n") catch {};
        return;
    };
    defer state.allocator.free(next_options);

    state.jit_runner.setCompilerBackend(state.jit_runner.getCompilerExe(), next_options) catch {
        state.terminal_visible = true;
        state.updateTerminalSize();
        state.terminalPrint("[Compiler settings] invalid compiler options\r\n") catch {};
        return;
    };

    state.jit_opt_level = if (opt_level <= 3) opt_level else 1;
    state.jit_fast_math_trig = fast_math_trig;

    state.terminal_visible = true;
    state.updateTerminalSize();
    state.reportCompilerSettingsChange(false);
}

fn rebuildCompilerMenuOptions(allocator: std.mem.Allocator, raw_options: []const u8, opt_level: u8, fast_math_trig: bool) ![]u8 {
    var tokens: std.ArrayListUnmanaged([]u8) = .{};
    defer {
        for (tokens.items) |token| allocator.free(token);
        tokens.deinit(allocator);
    }

    var cursor: usize = 0;
    while (nextCompilerOptionToken(raw_options, &cursor)) |token| {
        if (std.mem.eql(u8, token, "-O0") or
            std.mem.eql(u8, token, "-O1") or
            std.mem.eql(u8, token, "-O2") or
            std.mem.eql(u8, token, "-O3") or
            std.mem.eql(u8, token, "--no-optimize") or
            std.mem.eql(u8, token, "--fast-math-trig"))
        {
            continue;
        }

        try tokens.append(allocator, try allocator.dupe(u8, token));
    }

    const opt_token = switch (if (opt_level <= 3) opt_level else 1) {
        0 => "-O0",
        1 => "-O1",
        2 => "-O2",
        3 => "-O3",
        else => unreachable,
    };
    try tokens.append(allocator, try allocator.dupe(u8, opt_token));
    if (fast_math_trig) {
        try tokens.append(allocator, try allocator.dupe(u8, "--fast-math-trig"));
    }

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(allocator);

    for (tokens.items, 0..) |token, index| {
        if (index != 0) try out.append(allocator, ' ');
        try appendCompilerOptionTokenEscaped(allocator, &out, token);
    }

    return allocator.dupe(u8, out.items);
}

fn nextCompilerOptionToken(raw: []const u8, cursor: *usize) ?[]const u8 {
    while (cursor.* < raw.len and std.ascii.isWhitespace(raw[cursor.*])) : (cursor.* += 1) {}
    if (cursor.* >= raw.len) return null;

    const start = cursor.*;
    var in_quote: ?u8 = null;

    while (cursor.* < raw.len) {
        const ch = raw[cursor.*];
        if (in_quote) |quote| {
            if (ch == '\\' and cursor.* + 1 < raw.len) {
                cursor.* += 2;
                continue;
            }
            cursor.* += 1;
            if (ch == quote) in_quote = null;
            continue;
        }

        if (ch == '"' or ch == '\'') {
            in_quote = ch;
            cursor.* += 1;
            continue;
        }
        if (std.ascii.isWhitespace(ch)) break;
        if (ch == '\\' and cursor.* + 1 < raw.len) {
            cursor.* += 2;
            continue;
        }
        cursor.* += 1;
    }

    const token = raw[start..cursor.*];
    while (cursor.* < raw.len and std.ascii.isWhitespace(raw[cursor.*])) : (cursor.* += 1) {}
    return std.mem.trim(u8, token, " \t\r\n");
}

fn appendCompilerOptionTokenEscaped(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), token: []const u8) !void {
    const needs_quotes = for (token) |ch| {
        if (std.ascii.isWhitespace(ch) or ch == '"' or ch == '\\') break true;
    } else false;

    if (!needs_quotes) {
        try out.appendSlice(allocator, token);
        return;
    }

    try out.append(allocator, '"');
    for (token) |ch| {
        if (ch == '"' or ch == '\\') try out.append(allocator, '\\');
        try out.append(allocator, ch);
    }
    try out.append(allocator, '"');
}

fn findNearestBinbasDir(allocator: std.mem.Allocator, start_dir: []const u8) ?[]u8 {
    var current = allocator.dupe(u8, start_dir) catch return null;

    while (true) {
        const candidate = std.fs.path.join(allocator, &.{ current, "binbas" }) catch {
            allocator.free(current);
            return null;
        };
        if (pathExists(candidate)) {
            allocator.free(current);
            return candidate;
        }
        allocator.free(candidate);

        const parent = std.fs.path.dirname(current) orelse {
            allocator.free(current);
            return null;
        };
        if (std.mem.eql(u8, parent, current)) {
            allocator.free(current);
            return null;
        }

        const next = allocator.dupe(u8, parent) catch {
            allocator.free(current);
            return null;
        };
        allocator.free(current);
        current = next;
    }
}

fn pathExists(path: []const u8) bool {
    _ = std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// Returns 1 if the current buffer has unsaved changes, 0 otherwise.
export fn ed_is_modified() callconv(.c) c_int {
    const state = g_state orelse return 0;
    return if (state.modified) 1 else 0;
}

/// Save to the existing file path. Returns 1 = saved, 0 = no path set, -1 = error.
export fn ed_save_to_existing_path() callconv(.c) c_int {
    const state = g_state orelse return -1;
    if (state.file_path == null) return 0;
    state.saveFile() catch return -1;
    return 1;
}

/// Save to the given null-terminated UTF-8 path. Returns 1 = saved, -1 = error.
export fn ed_save_as_path(path_ptr: [*c]const u8) callconv(.c) c_int {
    const state = g_state orelse return -1;
    const path = std.mem.span(path_ptr);
    state.saveFileAs(path) catch return -1;
    return 1;
}

// ─── Help Snippet Runner ────────────────────────────────────────────────────

/// Called from the help WebView's Run button to execute a BASIC code snippet.
export fn ed_run_snippet(source_ptr: [*]const u8, source_len: u32) callconv(.c) void {
    const state = g_state orelse return;

    if (state.jit_runner.isActive()) {
        state.terminalPrint("  Program already running.  Press Stop (Cmd+.) to cancel.\r\n") catch {};
        return;
    }

    // Collect any previous result
    _ = state.jit_runner.collectResult();

    // Clear error markers from previous run
    state.clearErrorLines();

    state.expandTerminalForRun();
    state.terminalPrint("\r\n") catch {};
    state.terminalPrint("[Help] Run snippet...\r\n") catch {};

    const source = source_ptr[0..source_len];

    if (!state.jit_runner.startRun(source)) {
        state.terminalPrint("  Error: cannot start JIT runner.\r\n") catch {};
    } else {
        state.focus = .terminal;
        state.terminal_pinned_to_bottom = true;
        state.terminal_scroll_offset = 0;
    }
}

// ─── Help Snippet Editor ──────────────────────────────────────────────────

/// Called from the help WebView's Edit button.
/// Loads the snippet into the editor buffer as a new untitled file,
/// prompting the user to save any unsaved changes first.
export fn ed_edit_snippet(source_ptr: [*]const u8, source_len: u32) callconv(.c) void {
    const state = g_state orelse return;

    // If the current buffer is modified, ask the user whether to save first.
    if (state.modified) {
        const file_cstr: ?[*:0]const u8 = if (state.file_path) |fp| blk: {
            var buf: [512]u8 = undefined;
            const basename = std.fs.path.basename(fp);
            const copy_len = @min(basename.len, buf.len - 1);
            @memcpy(buf[0..copy_len], basename[0..copy_len]);
            buf[copy_len] = 0;
            break :blk @ptrCast(buf[0..copy_len :0]);
        } else null;
        const result = platform.ed_platform_confirm_save_dialog(file_cstr);
        if (result == 1) {
            // Save first — use Save As dialog if this is an untitled buffer
            if (state.file_path != null) {
                state.saveFile() catch {};
            } else {
                state.saveFileAsDialog();
            }
        } else if (result < 0) {
            // Cancel — abort opening the snippet
            return;
        }
    }

    // Load the snippet text into the editor as a new untitled buffer
    const source = source_ptr[0..source_len];
    state.buffer.deinit();
    state.buffer = RopeBuffer.initFromUtf8(state.allocator, source) catch {
        state.terminalPrint("  Edit snippet: out of memory\r\n") catch {};
        state.terminal_visible = true;
        return;
    };

    // Reset all editor state for the fresh buffer
    state.cursor = 0;
    state.scroll_line = 0;
    state.scroll_col = 0;
    state.selection_anchor = null;
    state.modified = false;
    state.desired_col = null;
    state.fold_regions.clearRetainingCapacity();
    state.symbols_dirty = true;

    // Mark as untitled (no file path)
    if (state.file_path) |old_path| {
        state.allocator.free(old_path);
    }
    state.file_path = null;

    // Clear undo/redo history
    for (state.undo_stack.items) |*e| {
        e.deinit(state.allocator);
    }
    state.undo_stack.clearRetainingCapacity();
    for (state.redo_stack.items) |*e| {
        e.deinit(state.allocator);
    }
    state.redo_stack.clearRetainingCapacity();

    state.focus = .editor;
    state.updateTitle();
}

// ─── Code Folding Keyword Detection ─────────────────────────────────────────

/// Fold keyword categories — each open keyword maps to its close keyword(s).
const FoldKeyword = enum {
    sub_fn, // SUB / END SUB, FUNCTION / END FUNCTION
    for_loop, // FOR / NEXT
    while_loop, // WHILE / WEND
    do_loop, // DO / LOOP
    if_block, // IF (multi-line) / END IF
    select_case, // SELECT CASE / END SELECT
    try_catch, // TRY / END TRY
    class_type, // CLASS / END CLASS, TYPE / END TYPE
    worker, // WORKER / END WORKER
    with, // WITH / END WITH
    repeat, // REPEAT / UNTIL
};

/// Check if `line` (UTF-32) starts a foldable block. Returns the keyword enum
/// if it does (after skipping optional line number and whitespace).
fn foldableKeyword(line: []const u32) ?FoldKeyword {
    var i: usize = 0;
    const n = line.len;

    // Skip leading line number (digits)
    while (i < n and line[i] >= '0' and line[i] <= '9') : (i += 1) {}
    // Skip whitespace
    while (i < n and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}

    if (i >= n) return null;

    // Match keyword (case-insensitive)
    if (matchesKwAt(line, i, &[_]u32{ 'S', 'U', 'B' }) and isWordEnd(line, i + 3)) return .sub_fn;
    if (matchesKwAt(line, i, &[_]u32{ 'F', 'U', 'N', 'C', 'T', 'I', 'O', 'N' }) and isWordEnd(line, i + 8)) return .sub_fn;
    if (matchesKwAt(line, i, &[_]u32{ 'F', 'O', 'R' }) and isWordEnd(line, i + 3)) return .for_loop;
    if (matchesKwAt(line, i, &[_]u32{ 'W', 'H', 'I', 'L', 'E' }) and isWordEnd(line, i + 5)) return .while_loop;
    if (matchesKwAt(line, i, &[_]u32{ 'D', 'O' }) and isWordEnd(line, i + 2)) return .do_loop;
    if (matchesKwAt(line, i, &[_]u32{ 'S', 'E', 'L', 'E', 'C', 'T' }) and isWordEnd(line, i + 6)) return .select_case;
    if (matchesKwAt(line, i, &[_]u32{ 'T', 'R', 'Y' }) and isWordEnd(line, i + 3)) return .try_catch;
    if (matchesKwAt(line, i, &[_]u32{ 'C', 'L', 'A', 'S', 'S' }) and isWordEnd(line, i + 5)) return .class_type;
    if (matchesKwAt(line, i, &[_]u32{ 'T', 'Y', 'P', 'E' }) and isWordEnd(line, i + 4)) return .class_type;
    if (matchesKwAt(line, i, &[_]u32{ 'W', 'O', 'R', 'K', 'E', 'R' }) and isWordEnd(line, i + 6)) return .worker;
    if (matchesKwAt(line, i, &[_]u32{ 'W', 'I', 'T', 'H' }) and isWordEnd(line, i + 4)) return .with;
    if (matchesKwAt(line, i, &[_]u32{ 'R', 'E', 'P', 'E', 'A', 'T' }) and isWordEnd(line, i + 6)) return .repeat;

    // Multi-line IF: line starts with IF and does NOT contain THEN + more code on same line
    if (matchesKwAt(line, i, &[_]u32{ 'I', 'F' }) and isWordEnd(line, i + 2)) {
        // Check if THEN is at end of line (multiline IF)
        if (endsWithThen(line)) return .if_block;
    }

    return null;
}

/// Check if a line matches the opening keyword for a given fold category.
fn lineMatchesOpen(line: []const u32, kw: FoldKeyword) bool {
    const detected = foldableKeyword(line) orelse return false;
    return detected == kw;
}

/// Check if a line matches the closing keyword for a given fold category.
fn lineMatchesClose(line: []const u32, kw: FoldKeyword) bool {
    var i: usize = 0;
    const n = line.len;

    // Skip leading line number
    while (i < n and line[i] >= '0' and line[i] <= '9') : (i += 1) {}
    // Skip whitespace
    while (i < n and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (i >= n) return false;

    return switch (kw) {
        .sub_fn => matchesKwAt(line, i, &[_]u32{ 'E', 'N', 'D' }) and
            matchesAfterSpace(line, i + 3, &[_]u32{ 'S', 'U', 'B' }) or
            (matchesKwAt(line, i, &[_]u32{ 'E', 'N', 'D' }) and
                matchesAfterSpace(line, i + 3, &[_]u32{ 'F', 'U', 'N', 'C', 'T', 'I', 'O', 'N' })),
        .for_loop => matchesKwAt(line, i, &[_]u32{ 'N', 'E', 'X', 'T' }) and isWordEnd(line, i + 4),
        .while_loop => matchesKwAt(line, i, &[_]u32{ 'W', 'E', 'N', 'D' }) and isWordEnd(line, i + 4),
        .do_loop => matchesKwAt(line, i, &[_]u32{ 'L', 'O', 'O', 'P' }) and isWordEnd(line, i + 4),
        .if_block => matchesKwAt(line, i, &[_]u32{ 'E', 'N', 'D' }) and matchesAfterSpace(line, i + 3, &[_]u32{ 'I', 'F' }),
        .select_case => matchesKwAt(line, i, &[_]u32{ 'E', 'N', 'D' }) and matchesAfterSpace(line, i + 3, &[_]u32{ 'S', 'E', 'L', 'E', 'C', 'T' }),
        .try_catch => matchesKwAt(line, i, &[_]u32{ 'E', 'N', 'D' }) and matchesAfterSpace(line, i + 3, &[_]u32{ 'T', 'R', 'Y' }),
        .class_type => matchesKwAt(line, i, &[_]u32{ 'E', 'N', 'D' }) and
            (matchesAfterSpace(line, i + 3, &[_]u32{ 'C', 'L', 'A', 'S', 'S' }) or
                matchesAfterSpace(line, i + 3, &[_]u32{ 'T', 'Y', 'P', 'E' })),
        .worker => matchesKwAt(line, i, &[_]u32{ 'E', 'N', 'D' }) and matchesAfterSpace(line, i + 3, &[_]u32{ 'W', 'O', 'R', 'K', 'E', 'R' }),
        .with => matchesKwAt(line, i, &[_]u32{ 'E', 'N', 'D' }) and matchesAfterSpace(line, i + 3, &[_]u32{ 'W', 'I', 'T', 'H' }),
        .repeat => matchesKwAt(line, i, &[_]u32{ 'U', 'N', 'T', 'I', 'L' }) and isWordEnd(line, i + 5),
    };
}

/// Case-insensitive keyword match at position `pos` in line.
fn matchesKwAt(line: []const u32, pos: usize, kw: []const u32) bool {
    if (pos + kw.len > line.len) return false;
    for (kw, 0..) |ch, j| {
        const lc = line[pos + j];
        const upper = if (lc >= 'a' and lc <= 'z') lc - 32 else lc;
        if (upper != ch) return false;
    }
    return true;
}

/// Check if position is at end of word (end of line or next char is not alphanumeric).
fn isWordEnd(line: []const u32, pos: usize) bool {
    if (pos >= line.len) return true;
    const ch = line[pos];
    if (ch >= 'A' and ch <= 'Z') return false;
    if (ch >= 'a' and ch <= 'z') return false;
    if (ch >= '0' and ch <= '9') return false;
    if (ch == '_') return false;
    return true;
}

/// Check if keyword `kw` appears after at least one space following `pos`.
fn matchesAfterSpace(line: []const u32, pos: usize, kw: []const u32) bool {
    var i = pos;
    // Must have at least one space
    if (i >= line.len or (line[i] != ' ' and line[i] != '\t')) return false;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    return matchesKwAt(line, i, kw) and isWordEnd(line, i + kw.len);
}

/// Check if a line ends with THEN (after trimming trailing whitespace/comments).
/// This distinguishes multi-line IF (ends with THEN) from single-line IF.
fn endsWithThen(line: []const u32) bool {
    // Find end ignoring trailing whitespace
    var end: usize = line.len;
    while (end > 0 and (line[end - 1] == ' ' or line[end - 1] == '\t' or line[end - 1] == '\r')) {
        end -= 1;
    }
    if (end < 4) return false;
    // Check if last 4 chars are THEN
    return matchesKwAt(line, end - 4, &[_]u32{ 'T', 'H', 'E', 'N' }) and
        (end - 4 == 0 or !isAlphaNum(line[end - 5]));
}

fn isAlphaNum(ch: u32) bool {
    if (ch >= 'A' and ch <= 'Z') return true;
    if (ch >= 'a' and ch <= 'z') return true;
    if (ch >= '0' and ch <= '9') return true;
    if (ch == '_') return true;
    return false;
}
