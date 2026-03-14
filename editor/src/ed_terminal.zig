//! Ed Terminal Pane — Cell Grid, Cursor, Colours, and VT100 Escape Parsing
//!
//! This module implements the terminal pane that appears at the bottom of the
//! Ed editor. It provides:
//!
//!   - A fixed-size cell grid (cols × rows) where each cell has a character,
//!     foreground colour, background colour, and attribute flags
//!   - A cursor with position tracking and visibility state
//!   - Basic VT100/ANSI escape sequence parsing (CSI, SGR, cursor movement,
//!     erase, scroll)
//!   - A scrollback buffer for output history
//!   - Thread-safe output buffering (for JIT program output from a background thread)
//!   - Input line editing with history
//!
//! The terminal pane is NOT a real PTY. It's a lightweight terminal emulator
//! that processes escape sequences written by the FasterBASIC runtime's I/O
//! functions. This is much simpler than a full terminal emulator because we
//! control the output source.
//!
//! Coordinate system: (0,0) is top-left of the terminal grid.
//! Column indices are 0-based internally, 1-based in ANSI escape sequences.

const std = @import("std");
const theme_mod = @import("ed_theme.zig");
const Colour = theme_mod.Colour;

// ─── Constants ──────────────────────────────────────────────────────────────

/// Maximum number of columns in the terminal grid.
pub const MAX_COLS: usize = 256;

/// Maximum number of rows in the terminal grid.
pub const MAX_ROWS: usize = 64;

/// Maximum scrollback lines (effectively endless for any real session).
pub const MAX_SCROLLBACK: usize = 100_000;

/// Maximum length of an input line.
pub const MAX_INPUT_LEN: usize = 1024;

/// Maximum number of input history entries.
pub const MAX_HISTORY: usize = 100;

/// Maximum number of CSI parameters.
const MAX_CSI_PARAMS: usize = 16;

/// Size of the thread-safe output ring buffer.
const OUTPUT_RING_SIZE: usize = 64 * 1024;

// ─── Cell Attributes ────────────────────────────────────────────────────────

pub const CellAttr = packed struct(u8) {
    bold: bool = false,
    underline: bool = false,
    inverse: bool = false,
    strikethrough: bool = false,
    dim: bool = false,
    italic: bool = false,
    blink: bool = false,
    _pad: u1 = 0,

    pub const NONE = CellAttr{};
};

// ─── Terminal Cell ──────────────────────────────────────────────────────────

pub const Cell = struct {
    /// The Unicode code point displayed in this cell.
    codepoint: u32 = ' ',
    /// Foreground colour.
    fg: Colour = Colour.hex(0xC0C0C0),
    /// Background colour.
    bg: Colour = Colour.hex(0x000020),
    /// Text attributes.
    attr: CellAttr = CellAttr.NONE,
    /// Whether this cell has been written to (dirty tracking).
    dirty: bool = false,

    pub fn reset(self: *Cell, default_fg: Colour, default_bg: Colour) void {
        self.codepoint = ' ';
        self.fg = default_fg;
        self.bg = default_bg;
        self.attr = CellAttr.NONE;
        self.dirty = false;
    }
};

// ─── ANSI Colour Table ──────────────────────────────────────────────────────

/// Standard 16-colour ANSI palette.
pub const ANSI_COLOURS = [16]Colour{
    Colour.hex(0x000000), // 0: Black
    Colour.hex(0xAA0000), // 1: Red
    Colour.hex(0x00AA00), // 2: Green
    Colour.hex(0xAA5500), // 3: Yellow/Brown
    Colour.hex(0x0000AA), // 4: Blue
    Colour.hex(0xAA00AA), // 5: Magenta
    Colour.hex(0x00AAAA), // 6: Cyan
    Colour.hex(0xAAAAAA), // 7: White (light grey)
    Colour.hex(0x555555), // 8: Bright Black (dark grey)
    Colour.hex(0xFF5555), // 9: Bright Red
    Colour.hex(0x55FF55), // 10: Bright Green
    Colour.hex(0xFFFF55), // 11: Bright Yellow
    Colour.hex(0x5555FF), // 12: Bright Blue
    Colour.hex(0xFF55FF), // 13: Bright Magenta
    Colour.hex(0x55FFFF), // 14: Bright Cyan
    Colour.hex(0xFFFFFF), // 15: Bright White
};

// ─── VT100 Parser State ─────────────────────────────────────────────────────

const ParserState = enum {
    /// Normal character output.
    ground,
    /// Received ESC (0x1B), waiting for next byte.
    escape,
    /// Received ESC [, collecting CSI parameters.
    csi_param,
    /// Received ESC ], collecting OSC string.
    osc_string,
    /// Received ESC ( or ESC ), designating character set (ignored).
    charset,
    /// Received ESC #, DEC private sequence (ignored).
    dec_hash,
};

// ─── Input Mode ─────────────────────────────────────────────────────────────

pub const InputMode = enum {
    /// Terminal is not waiting for input.
    none,
    /// Waiting for a full line of input (INPUT statement).
    line_input,
    /// Waiting for a single character (INKEY$ / INPUT$(1)).
    char_input,
    /// Waiting for a single keypress with no echo (INKEY$).
    raw_input,
};

// ─── Scrollback Line ────────────────────────────────────────────────────────

const ScrollbackLine = struct {
    cells: []Cell,

    pub fn deinit(self: *ScrollbackLine, allocator: std.mem.Allocator) void {
        allocator.free(self.cells);
    }
};

// ─── Terminal ───────────────────────────────────────────────────────────────

pub const Terminal = struct {
    /// The cell grid: grid[row][col].
    grid: [MAX_ROWS][MAX_COLS]Cell = undefined,

    /// Current terminal dimensions.
    cols: usize,
    rows: usize,

    /// Cursor position (0-based).
    cursor_col: usize = 0,
    cursor_row: usize = 0,

    /// Whether the cursor is visible.
    cursor_visible: bool = true,

    /// Saved cursor position (for ESC 7 / ESC 8, CSI s / CSI u).
    saved_cursor_col: usize = 0,
    saved_cursor_row: usize = 0,

    /// Current text attributes for new characters.
    current_fg: Colour,
    current_bg: Colour,
    current_attr: CellAttr = CellAttr.NONE,

    /// Default colours (from theme).
    default_fg: Colour,
    default_bg: Colour,

    /// VT100 parser state.
    parser_state: ParserState = .ground,

    /// CSI parameter accumulator.
    csi_params: [MAX_CSI_PARAMS]u32 = [_]u32{0} ** MAX_CSI_PARAMS,
    csi_param_count: usize = 0,
    csi_private: bool = false, // '?' prefix in CSI
    csi_intermediate: u8 = 0, // intermediate byte (e.g., ' ', '!')

    /// OSC string accumulator.
    osc_buf: [256]u8 = [_]u8{0} ** 256,
    osc_len: usize = 0,

    /// Scroll region (top and bottom row, 0-based, inclusive).
    scroll_top: usize = 0,
    scroll_bottom: usize = 0, // set to rows-1 on init

    /// Scrollback buffer.
    scrollback: std.ArrayListUnmanaged(ScrollbackLine) = .{},

    /// Scrollback view offset (0 = showing live terminal, >0 = scrolled up).
    scrollback_offset: usize = 0,

    /// Input state.
    input_mode: InputMode = .none,
    input_buf: [MAX_INPUT_LEN]u32 = [_]u32{0} ** MAX_INPUT_LEN,
    input_len: usize = 0,
    input_cursor: usize = 0,
    input_prompt_col: usize = 0,
    input_ready: bool = false,

    /// Input history.
    history: std.ArrayListUnmanaged([]u32) = .{},
    history_idx: ?usize = null,

    /// Output ring buffer for thread-safe writes from JIT program thread.
    output_ring: [OUTPUT_RING_SIZE]u8 = [_]u8{0} ** OUTPUT_RING_SIZE,
    output_ring_write: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    output_ring_read: usize = 0,

    /// Whether there's new output to process (checked each frame).
    has_new_output: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Whether a CLS (clear screen) has been requested from the JIT thread.
    /// Set atomically by the runtime; checked and cleared by the main thread.
    cls_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Whether a program is currently running in the terminal.
    program_running: bool = false,

    /// Allocator for scrollback and history.
    allocator: std.mem.Allocator,

    // ── Initialization ──────────────────────────────────────────────────

    pub fn init(allocator: std.mem.Allocator, cols: usize, rows: usize, fg: Colour, bg: Colour) Terminal {
        var term = Terminal{
            .cols = @min(cols, MAX_COLS),
            .rows = @min(rows, MAX_ROWS),
            .current_fg = fg,
            .current_bg = bg,
            .default_fg = fg,
            .default_bg = bg,
            .allocator = allocator,
        };
        term.scroll_bottom = if (term.rows > 0) term.rows - 1 else 0;
        term.clearGrid();
        return term;
    }

    pub fn deinit(self: *Terminal) void {
        for (self.scrollback.items) |*line| {
            line.deinit(self.allocator);
        }
        self.scrollback.deinit(self.allocator);

        for (self.history.items) |h| {
            self.allocator.free(h);
        }
        self.history.deinit(self.allocator);
    }

    // ── Grid Operations ─────────────────────────────────────────────────

    pub fn clearGrid(self: *Terminal) void {
        for (0..self.rows) |r| {
            for (0..self.cols) |c| {
                self.grid[r][c].reset(self.default_fg, self.default_bg);
            }
        }
        self.cursor_col = 0;
        self.cursor_row = 0;
    }

    /// Apply a new theme to the terminal. Cells that were still using the
    /// previous default colours adopt the new defaults; coloured output keeps
    /// its explicit colours.
    pub fn applyTheme(self: *Terminal, fg: Colour, bg: Colour) void {
        const old_fg = self.default_fg;
        const old_bg = self.default_bg;

        self.default_fg = fg;
        self.default_bg = bg;
        self.current_fg = fg;
        self.current_bg = bg;

        // Retint the visible grid where cells still use the old defaults.
        for (0..self.rows) |r| {
            for (0..self.cols) |c| {
                var cell = &self.grid[r][c];
                if (cell.fg.eql(old_fg)) cell.fg = fg;
                if (cell.bg.eql(old_bg)) cell.bg = bg;
            }
        }

        // Retint scrollback cells that were using the old defaults.
        for (self.scrollback.items) |*line| {
            for (line.cells) |*cell| {
                if (cell.fg.eql(old_fg)) cell.fg = fg;
                if (cell.bg.eql(old_bg)) cell.bg = bg;
            }
        }
    }

    pub fn clearLine(self: *Terminal, row: usize) void {
        if (row >= self.rows) return;
        for (0..self.cols) |c| {
            self.grid[row][c].reset(self.default_fg, self.default_bg);
        }
    }

    pub fn clearLineFrom(self: *Terminal, row: usize, col: usize) void {
        if (row >= self.rows) return;
        var c = col;
        while (c < self.cols) : (c += 1) {
            self.grid[row][c].reset(self.current_fg, self.current_bg);
        }
    }

    pub fn clearLineTo(self: *Terminal, row: usize, col: usize) void {
        if (row >= self.rows) return;
        const end = @min(col + 1, self.cols);
        for (0..end) |c| {
            self.grid[row][c].reset(self.current_fg, self.current_bg);
        }
    }

    pub fn clearFromCursor(self: *Terminal) void {
        // Clear from cursor to end of line
        self.clearLineFrom(self.cursor_row, self.cursor_col);
        // Clear all lines below
        var r = self.cursor_row + 1;
        while (r < self.rows) : (r += 1) {
            self.clearLine(r);
        }
    }

    pub fn clearToCursor(self: *Terminal) void {
        // Clear from beginning to cursor
        self.clearLineTo(self.cursor_row, self.cursor_col);
        // Clear all lines above
        for (0..self.cursor_row) |r| {
            self.clearLine(r);
        }
    }

    /// Get a cell reference.
    pub fn getCell(self: *Terminal, row: usize, col: usize) *Cell {
        const r = @min(row, MAX_ROWS - 1);
        const c = @min(col, MAX_COLS - 1);
        return &self.grid[r][c];
    }

    /// Get a cell (const).
    pub fn getCellConst(self: *const Terminal, row: usize, col: usize) Cell {
        const r = @min(row, if (self.rows > 0) self.rows - 1 else 0);
        const c = @min(col, if (self.cols > 0) self.cols - 1 else 0);
        return self.grid[r][c];
    }

    // ── Resize ──────────────────────────────────────────────────────────

    pub fn resize(self: *Terminal, new_cols: usize, new_rows: usize) void {
        const old_rows = self.rows;
        self.cols = @min(new_cols, MAX_COLS);
        self.rows = @min(new_rows, MAX_ROWS);
        self.scroll_bottom = if (self.rows > 0) self.rows - 1 else 0;

        // Clear any newly exposed rows
        if (self.rows > old_rows) {
            var r = old_rows;
            while (r < self.rows) : (r += 1) {
                self.clearLine(r);
            }
        }

        // Clamp cursor
        if (self.cursor_col >= self.cols) self.cursor_col = if (self.cols > 0) self.cols - 1 else 0;
        if (self.cursor_row >= self.rows) self.cursor_row = if (self.rows > 0) self.rows - 1 else 0;
    }

    // ── Scrolling ───────────────────────────────────────────────────────

    /// Scroll the grid up by one line within the scroll region.
    /// The top line is pushed to scrollback.
    pub fn scrollUp(self: *Terminal) void {
        // Save the top line of the scroll region to scrollback
        self.pushToScrollback(self.scroll_top);

        // Shift lines up within the scroll region
        var r = self.scroll_top;
        while (r < self.scroll_bottom) : (r += 1) {
            self.grid[r] = self.grid[r + 1];
        }

        // Clear the bottom line of the scroll region
        self.clearLine(self.scroll_bottom);
    }

    /// Scroll the grid down by one line within the scroll region.
    pub fn scrollDown(self: *Terminal) void {
        // Shift lines down within the scroll region
        var r = self.scroll_bottom;
        while (r > self.scroll_top) : (r -= 1) {
            self.grid[r] = self.grid[r - 1];
        }

        // Clear the top line of the scroll region
        self.clearLine(self.scroll_top);
    }

    fn pushToScrollback(self: *Terminal, row: usize) void {
        if (row >= self.rows) return;

        // Find the last non-space column to avoid storing trailing spaces
        var last_col: usize = 0;
        for (0..self.cols) |c| {
            if (self.grid[row][c].codepoint != ' ' or self.grid[row][c].dirty) {
                last_col = c + 1;
            }
        }

        const cells = self.allocator.alloc(Cell, last_col) catch return;
        for (0..last_col) |c| {
            cells[c] = self.grid[row][c];
        }

        self.scrollback.append(self.allocator, .{ .cells = cells }) catch {
            self.allocator.free(cells);
            return;
        };

        // Trim scrollback if too long
        while (self.scrollback.items.len > MAX_SCROLLBACK) {
            var removed = self.scrollback.orderedRemove(0);
            removed.deinit(self.allocator);
        }
    }

    // ── Character Output ────────────────────────────────────────────────

    /// Write a single byte through the VT100 parser state machine.
    pub fn writeByte(self: *Terminal, byte: u8) void {
        switch (self.parser_state) {
            .ground => self.processGround(byte),
            .escape => self.processEscape(byte),
            .csi_param => self.processCSI(byte),
            .osc_string => self.processOSC(byte),
            .charset => {
                // Ignore the character set designation byte
                self.parser_state = .ground;
            },
            .dec_hash => {
                // Ignore DEC private hash sequences
                self.parser_state = .ground;
            },
        }
    }

    /// Write a slice of bytes through the parser.
    pub fn writeBytes(self: *Terminal, bytes: []const u8) void {
        for (bytes) |b| {
            self.writeByte(b);
        }
    }

    /// Write a UTF-32 code point directly (no escape parsing).
    pub fn writeCodepoint(self: *Terminal, cp: u32) void {
        self.putChar(cp);
    }

    /// Write a string directly to the terminal (convenience).
    pub fn writeString(self: *Terminal, str: []const u8) void {
        self.writeBytes(str);
    }

    // ── Direct Cursor and Attribute Manipulation ────────────────────────

    /// Set cursor position directly (0-based).
    pub fn setCursorPos(self: *Terminal, row: usize, col: usize) void {
        self.cursor_row = @min(row, if (self.rows > 0) self.rows - 1 else 0);
        self.cursor_col = @min(col, if (self.cols > 0) self.cols - 1 else 0);
    }

    /// Set foreground colour directly.
    pub fn setFg(self: *Terminal, colour: Colour) void {
        self.current_fg = colour;
    }

    /// Set background colour directly.
    pub fn setBg(self: *Terminal, colour: Colour) void {
        self.current_bg = colour;
    }

    /// Reset attributes to defaults.
    pub fn resetAttributes(self: *Terminal) void {
        self.current_fg = self.default_fg;
        self.current_bg = self.default_bg;
        self.current_attr = CellAttr.NONE;
    }

    // ── Thread-Safe Output Ring Buffer ──────────────────────────────────

    /// Write bytes to the output ring buffer (thread-safe, called from JIT thread).
    // ── Scrollback Query (for rendering) ────────────────────────────────

    /// Number of lines currently stored in the scrollback buffer.
    pub fn scrollbackLineCount(self: *const Terminal) usize {
        return self.scrollback.items.len;
    }

    /// Total number of lines: scrollback + live grid rows.
    pub fn totalLines(self: *const Terminal) usize {
        return self.scrollback.items.len + self.rows;
    }

    /// Get a cell from the combined scrollback + live grid, where line 0 is
    /// the oldest scrollback line and `scrollbackLineCount() + rows - 1` is
    /// the last live grid row.  Returns a default blank cell if out of range.
    pub fn getScrollbackCell(self: *const Terminal, line: usize, col: usize) Cell {
        const sb_count = self.scrollback.items.len;
        if (line < sb_count) {
            // Reading from scrollback
            const sb_line = self.scrollback.items[line];
            if (col < sb_line.cells.len) {
                return sb_line.cells[col];
            }
            // Past the stored content — return a blank cell with default colours
            return Cell{
                .codepoint = ' ',
                .fg = self.default_fg,
                .bg = self.default_bg,
                .attr = CellAttr.NONE,
                .dirty = false,
            };
        }
        // Reading from live grid
        const grid_row = line - sb_count;
        if (grid_row < self.rows and col < self.cols) {
            return self.grid[grid_row][col];
        }
        return Cell{
            .codepoint = ' ',
            .fg = self.default_fg,
            .bg = self.default_bg,
            .attr = CellAttr.NONE,
            .dirty = false,
        };
    }

    // ── Ring Buffer ─────────────────────────────────────────────────────

    pub fn ringWrite(self: *Terminal, data: []const u8) void {
        for (data) |byte| {
            const w = self.output_ring_write.load(.acquire);
            const next_w = (w + 1) % OUTPUT_RING_SIZE;
            // If ring is full, drop bytes (don't block)
            if (next_w == self.output_ring_read) continue;
            self.output_ring[w] = byte;
            self.output_ring_write.store(next_w, .release);
        }
        self.has_new_output.store(true, .release);
    }

    /// Drain the output ring buffer into the terminal (called on main thread each frame).
    pub fn drainOutputRing(self: *Terminal) void {
        // Check for CLS request from JIT thread — clear grid + scrollback
        if (self.cls_requested.load(.acquire)) {
            self.cls_requested.store(false, .release);
            self.clearGrid();
            // Free and clear all scrollback lines
            for (self.scrollback.items) |*sb_line| {
                sb_line.deinit(self.allocator);
            }
            self.scrollback.clearRetainingCapacity();
        }

        if (!self.has_new_output.load(.acquire)) return;
        self.has_new_output.store(false, .release);

        const w = self.output_ring_write.load(.acquire);
        while (self.output_ring_read != w) {
            const byte = self.output_ring[self.output_ring_read];
            self.output_ring_read = (self.output_ring_read + 1) % OUTPUT_RING_SIZE;
            self.writeByte(byte);
        }
    }

    // ── Input ───────────────────────────────────────────────────────────

    /// Start waiting for line input (called when BASIC program does INPUT).
    pub fn beginLineInput(self: *Terminal, prompt: ?[]const u8) void {
        if (prompt) |p| {
            self.writeBytes(p);
        }
        self.input_mode = .line_input;
        self.input_len = 0;
        self.input_cursor = 0;
        self.input_prompt_col = self.cursor_col;
        self.input_ready = false;
        self.history_idx = null;
    }

    /// Start waiting for a single character input.
    pub fn beginCharInput(self: *Terminal) void {
        self.input_mode = .char_input;
        self.input_len = 0;
        self.input_cursor = 0;
        self.input_ready = false;
    }

    /// Handle a key press during input mode.
    /// Returns true if input is now complete (ready to be read).
    pub fn handleInputKey(self: *Terminal, codepoint: u32, keycode: u16) bool {
        const VK_RETURN: u16 = 0x24;
        const VK_DELETE: u16 = 0x33;
        const VK_LEFT: u16 = 0x7B;
        const VK_RIGHT: u16 = 0x7C;
        const VK_UP: u16 = 0x7E;
        const VK_DOWN: u16 = 0x7D;
        const VK_HOME: u16 = 0x73;
        const VK_END: u16 = 0x77;

        switch (self.input_mode) {
            .none => return false,

            .char_input, .raw_input => {
                if (codepoint >= 0x20 or codepoint == '\n') {
                    self.input_buf[0] = codepoint;
                    self.input_len = 1;
                    self.input_ready = true;
                    if (self.input_mode == .char_input and codepoint >= 0x20) {
                        self.putChar(codepoint);
                    }
                    self.input_mode = .none;
                    return true;
                }
                return false;
            },

            .line_input => {
                if (keycode == VK_RETURN) {
                    // Submit the input line
                    self.putChar('\n');
                    self.input_ready = true;

                    // Save to history
                    if (self.input_len > 0) {
                        const hist_copy = self.allocator.alloc(u32, self.input_len) catch null;
                        if (hist_copy) |hc| {
                            @memcpy(hc, self.input_buf[0..self.input_len]);
                            self.history.append(self.allocator, hc) catch {
                                self.allocator.free(hc);
                            };
                            // Trim history
                            while (self.history.items.len > MAX_HISTORY) {
                                const removed = self.history.orderedRemove(0);
                                self.allocator.free(removed);
                            }
                        }
                    }

                    self.input_mode = .none;
                    return true;
                }

                if (keycode == VK_DELETE) {
                    // Backspace
                    if (self.input_cursor > 0) {
                        // Shift characters left
                        var i = self.input_cursor - 1;
                        while (i + 1 < self.input_len) : (i += 1) {
                            self.input_buf[i] = self.input_buf[i + 1];
                        }
                        self.input_len -= 1;
                        self.input_cursor -= 1;
                        self.redrawInputLine();
                    }
                    return false;
                }

                if (keycode == VK_LEFT) {
                    if (self.input_cursor > 0) {
                        self.input_cursor -= 1;
                        if (self.cursor_col > 0) self.cursor_col -= 1;
                    }
                    return false;
                }

                if (keycode == VK_RIGHT) {
                    if (self.input_cursor < self.input_len) {
                        self.input_cursor += 1;
                        if (self.cursor_col < self.cols - 1) self.cursor_col += 1;
                    }
                    return false;
                }

                if (keycode == VK_HOME) {
                    self.input_cursor = 0;
                    self.cursor_col = self.input_prompt_col;
                    return false;
                }

                if (keycode == VK_END) {
                    self.input_cursor = self.input_len;
                    self.cursor_col = self.input_prompt_col + self.input_len;
                    if (self.cursor_col >= self.cols) self.cursor_col = self.cols - 1;
                    return false;
                }

                if (keycode == VK_UP) {
                    // History up
                    if (self.history.items.len > 0) {
                        if (self.history_idx) |idx| {
                            if (idx > 0) self.history_idx = idx - 1;
                        } else {
                            self.history_idx = self.history.items.len - 1;
                        }
                        if (self.history_idx) |idx| {
                            const hist = self.history.items[idx];
                            const copy_len = @min(hist.len, MAX_INPUT_LEN);
                            @memcpy(self.input_buf[0..copy_len], hist[0..copy_len]);
                            self.input_len = copy_len;
                            self.input_cursor = copy_len;
                            self.redrawInputLine();
                        }
                    }
                    return false;
                }

                if (keycode == VK_DOWN) {
                    // History down
                    if (self.history_idx) |idx| {
                        if (idx + 1 < self.history.items.len) {
                            self.history_idx = idx + 1;
                            const hist = self.history.items[idx + 1];
                            const copy_len = @min(hist.len, MAX_INPUT_LEN);
                            @memcpy(self.input_buf[0..copy_len], hist[0..copy_len]);
                            self.input_len = copy_len;
                            self.input_cursor = copy_len;
                        } else {
                            self.history_idx = null;
                            self.input_len = 0;
                            self.input_cursor = 0;
                        }
                        self.redrawInputLine();
                    }
                    return false;
                }

                // Regular character insertion
                if (codepoint >= 0x20 and self.input_len < MAX_INPUT_LEN - 1) {
                    // Shift characters right
                    if (self.input_cursor < self.input_len) {
                        var i = self.input_len;
                        while (i > self.input_cursor) : (i -= 1) {
                            self.input_buf[i] = self.input_buf[i - 1];
                        }
                    }
                    self.input_buf[self.input_cursor] = codepoint;
                    self.input_len += 1;
                    self.input_cursor += 1;
                    self.redrawInputLine();
                    return false;
                }

                return false;
            },
        }
    }

    /// Get the completed input as a u32 slice (valid until next input operation).
    pub fn getInputSlice(self: *const Terminal) []const u32 {
        return self.input_buf[0..self.input_len];
    }

    /// Redraw the input line on the terminal grid.
    fn redrawInputLine(self: *Terminal) void {
        // Clear the input area
        self.clearLineFrom(self.cursor_row, self.input_prompt_col);

        // Redraw the input text
        for (0..self.input_len) |i| {
            const col = self.input_prompt_col + i;
            if (col >= self.cols) break;
            self.grid[self.cursor_row][col] = Cell{
                .codepoint = self.input_buf[i],
                .fg = self.current_fg,
                .bg = self.current_bg,
                .attr = self.current_attr,
                .dirty = true,
            };
        }

        // Position cursor
        self.cursor_col = self.input_prompt_col + self.input_cursor;
        if (self.cursor_col >= self.cols) self.cursor_col = self.cols - 1;
    }

    // ── VT100 State Machine ─────────────────────────────────────────────

    fn processGround(self: *Terminal, byte: u8) void {
        switch (byte) {
            0x00...0x06, 0x0E...0x1A, 0x1C...0x1F => {
                // Ignore most C0 control characters
            },
            0x07 => {
                // BEL — visual bell (we could flash the terminal)
            },
            0x08 => {
                // BS — backspace
                if (self.cursor_col > 0) self.cursor_col -= 1;
            },
            0x09 => {
                // HT — horizontal tab (advance to next tab stop, every 8 columns)
                self.cursor_col = (self.cursor_col + 8) & ~@as(usize, 7);
                if (self.cursor_col >= self.cols) self.cursor_col = self.cols - 1;
            },
            0x0A, 0x0B, 0x0C => {
                // LF, VT, FF — line feed
                self.lineFeed();
            },
            0x0D => {
                // CR — carriage return
                self.cursor_col = 0;
            },
            0x1B => {
                // ESC — start escape sequence
                self.parser_state = .escape;
            },
            else => {
                // Printable character
                self.putChar(@as(u32, byte));
            },
        }
    }

    fn processEscape(self: *Terminal, byte: u8) void {
        switch (byte) {
            '[' => {
                // CSI — Control Sequence Introducer
                self.parser_state = .csi_param;
                self.csi_params = [_]u32{0} ** MAX_CSI_PARAMS;
                self.csi_param_count = 0;
                self.csi_private = false;
                self.csi_intermediate = 0;
            },
            ']' => {
                // OSC — Operating System Command
                self.parser_state = .osc_string;
                self.osc_len = 0;
            },
            '(', ')' => {
                // Designate Character Set — ignore the next byte
                self.parser_state = .charset;
            },
            '#' => {
                // DEC private
                self.parser_state = .dec_hash;
            },
            '7' => {
                // DECSC — Save Cursor
                self.saved_cursor_col = self.cursor_col;
                self.saved_cursor_row = self.cursor_row;
                self.parser_state = .ground;
            },
            '8' => {
                // DECRC — Restore Cursor
                self.cursor_col = self.saved_cursor_col;
                self.cursor_row = self.saved_cursor_row;
                self.parser_state = .ground;
            },
            'D' => {
                // IND — Index (move cursor down, scroll if needed)
                self.lineFeed();
                self.parser_state = .ground;
            },
            'E' => {
                // NEL — Next Line
                self.cursor_col = 0;
                self.lineFeed();
                self.parser_state = .ground;
            },
            'M' => {
                // RI — Reverse Index (move cursor up, reverse scroll if needed)
                if (self.cursor_row == self.scroll_top) {
                    self.scrollDown();
                } else if (self.cursor_row > 0) {
                    self.cursor_row -= 1;
                }
                self.parser_state = .ground;
            },
            'c' => {
                // RIS — Full Reset
                self.resetAttributes();
                self.clearGrid();
                self.scroll_top = 0;
                self.scroll_bottom = if (self.rows > 0) self.rows - 1 else 0;
                self.parser_state = .ground;
            },
            else => {
                // Unknown escape sequence — ignore and return to ground
                self.parser_state = .ground;
            },
        }
    }

    fn processCSI(self: *Terminal, byte: u8) void {
        switch (byte) {
            '0'...'9' => {
                // Digit: accumulate parameter
                if (self.csi_param_count == 0) self.csi_param_count = 1;
                const idx = self.csi_param_count - 1;
                if (idx < MAX_CSI_PARAMS) {
                    self.csi_params[idx] = self.csi_params[idx] * 10 + (byte - '0');
                }
            },
            ';' => {
                // Parameter separator
                if (self.csi_param_count < MAX_CSI_PARAMS) {
                    self.csi_param_count += 1;
                }
            },
            '?' => {
                // Private mode prefix
                self.csi_private = true;
            },
            ' ', '!', '"', '#', '$', '%', '&', '\'' => {
                // Intermediate bytes
                self.csi_intermediate = byte;
            },
            // ── Final bytes (dispatch the CSI command) ──────────────────
            'A' => {
                self.csiCursorUp();
                self.parser_state = .ground;
            },
            'B' => {
                self.csiCursorDown();
                self.parser_state = .ground;
            },
            'C' => {
                self.csiCursorForward();
                self.parser_state = .ground;
            },
            'D' => {
                self.csiCursorBackward();
                self.parser_state = .ground;
            },
            'E' => {
                self.csiCursorNextLine();
                self.parser_state = .ground;
            },
            'F' => {
                self.csiCursorPrevLine();
                self.parser_state = .ground;
            },
            'G' => {
                self.csiCursorColumn();
                self.parser_state = .ground;
            },
            'H', 'f' => {
                self.csiCursorPosition();
                self.parser_state = .ground;
            },
            'J' => {
                self.csiEraseDisplay();
                self.parser_state = .ground;
            },
            'K' => {
                self.csiEraseLine();
                self.parser_state = .ground;
            },
            'L' => {
                self.csiInsertLines();
                self.parser_state = .ground;
            },
            'M' => {
                self.csiDeleteLines();
                self.parser_state = .ground;
            },
            'S' => {
                self.csiScrollUp();
                self.parser_state = .ground;
            },
            'T' => {
                self.csiScrollDown();
                self.parser_state = .ground;
            },
            'd' => {
                self.csiCursorRow();
                self.parser_state = .ground;
            },
            'm' => {
                self.csiSGR();
                self.parser_state = .ground;
            },
            'n' => {
                self.csiDeviceStatus();
                self.parser_state = .ground;
            },
            'r' => {
                self.csiSetScrollRegion();
                self.parser_state = .ground;
            },
            's' => {
                // Save cursor position
                self.saved_cursor_col = self.cursor_col;
                self.saved_cursor_row = self.cursor_row;
                self.parser_state = .ground;
            },
            'u' => {
                // Restore cursor position
                self.cursor_col = self.saved_cursor_col;
                self.cursor_row = self.saved_cursor_row;
                self.parser_state = .ground;
            },
            'h' => {
                // Set mode
                if (self.csi_private) {
                    self.csiSetPrivateMode(true);
                }
                self.parser_state = .ground;
            },
            'l' => {
                // Reset mode
                if (self.csi_private) {
                    self.csiSetPrivateMode(false);
                }
                self.parser_state = .ground;
            },
            '@' => {
                self.csiInsertChars();
                self.parser_state = .ground;
            },
            'P' => {
                self.csiDeleteChars();
                self.parser_state = .ground;
            },
            'X' => {
                self.csiEraseChars();
                self.parser_state = .ground;
            },
            else => {
                // Unknown CSI final byte — abort and return to ground
                self.parser_state = .ground;
            },
        }
    }

    fn processOSC(self: *Terminal, byte: u8) void {
        if (byte == 0x07 or byte == 0x9C) {
            // BEL or ST terminates OSC
            // OSC 0; <title> ST — set window title
            // OSC 2; <title> ST — set window title
            // We could forward this to Ed's title bar if desired
            self.parser_state = .ground;
            return;
        }
        if (byte == 0x1B) {
            // ESC might start ST (ESC \)
            // For simplicity, just end the OSC
            self.parser_state = .ground;
            return;
        }
        if (self.osc_len < self.osc_buf.len) {
            self.osc_buf[self.osc_len] = byte;
            self.osc_len += 1;
        }
    }

    // ── CSI Command Implementations ─────────────────────────────────────

    fn csiParam(self: *const Terminal, idx: usize, default: u32) u32 {
        if (idx < self.csi_param_count and self.csi_params[idx] > 0) {
            return self.csi_params[idx];
        }
        return default;
    }

    fn csiCursorUp(self: *Terminal) void {
        const n = self.csiParam(0, 1);
        if (self.cursor_row >= n) {
            self.cursor_row -= @intCast(n);
        } else {
            self.cursor_row = 0;
        }
    }

    fn csiCursorDown(self: *Terminal) void {
        const n = self.csiParam(0, 1);
        self.cursor_row = @min(self.cursor_row + @as(usize, @intCast(n)), if (self.rows > 0) self.rows - 1 else 0);
    }

    fn csiCursorForward(self: *Terminal) void {
        const n = self.csiParam(0, 1);
        self.cursor_col = @min(self.cursor_col + @as(usize, @intCast(n)), if (self.cols > 0) self.cols - 1 else 0);
    }

    fn csiCursorBackward(self: *Terminal) void {
        const n = self.csiParam(0, 1);
        if (self.cursor_col >= n) {
            self.cursor_col -= @intCast(n);
        } else {
            self.cursor_col = 0;
        }
    }

    fn csiCursorNextLine(self: *Terminal) void {
        const n = self.csiParam(0, 1);
        self.cursor_col = 0;
        self.cursor_row = @min(self.cursor_row + @as(usize, @intCast(n)), if (self.rows > 0) self.rows - 1 else 0);
    }

    fn csiCursorPrevLine(self: *Terminal) void {
        const n = self.csiParam(0, 1);
        self.cursor_col = 0;
        if (self.cursor_row >= n) {
            self.cursor_row -= @intCast(n);
        } else {
            self.cursor_row = 0;
        }
    }

    fn csiCursorColumn(self: *Terminal) void {
        const col = self.csiParam(0, 1);
        // CSI columns are 1-based
        self.cursor_col = @min(if (col > 0) @as(usize, @intCast(col)) - 1 else 0, if (self.cols > 0) self.cols - 1 else 0);
    }

    fn csiCursorPosition(self: *Terminal) void {
        const row = self.csiParam(0, 1);
        const col = self.csiParam(1, 1);
        // CSI positions are 1-based
        self.cursor_row = @min(if (row > 0) @as(usize, @intCast(row)) - 1 else 0, if (self.rows > 0) self.rows - 1 else 0);
        self.cursor_col = @min(if (col > 0) @as(usize, @intCast(col)) - 1 else 0, if (self.cols > 0) self.cols - 1 else 0);
    }

    fn csiCursorRow(self: *Terminal) void {
        const row = self.csiParam(0, 1);
        self.cursor_row = @min(if (row > 0) @as(usize, @intCast(row)) - 1 else 0, if (self.rows > 0) self.rows - 1 else 0);
    }

    fn csiEraseDisplay(self: *Terminal) void {
        const mode = self.csiParam(0, 0);
        switch (mode) {
            0 => self.clearFromCursor(),
            1 => self.clearToCursor(),
            2, 3 => {
                self.clearGrid();
                self.cursor_row = 0;
                self.cursor_col = 0;
            },
            else => {},
        }
    }

    fn csiEraseLine(self: *Terminal) void {
        const mode = self.csiParam(0, 0);
        switch (mode) {
            0 => self.clearLineFrom(self.cursor_row, self.cursor_col),
            1 => self.clearLineTo(self.cursor_row, self.cursor_col),
            2 => self.clearLine(self.cursor_row),
            else => {},
        }
    }

    fn csiInsertLines(self: *Terminal) void {
        const n = self.csiParam(0, 1);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            // Insert a blank line at cursor row, shift others down
            if (self.cursor_row <= self.scroll_bottom) {
                var r = self.scroll_bottom;
                while (r > self.cursor_row) : (r -= 1) {
                    self.grid[r] = self.grid[r - 1];
                }
                self.clearLine(self.cursor_row);
            }
        }
    }

    fn csiDeleteLines(self: *Terminal) void {
        const n = self.csiParam(0, 1);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            if (self.cursor_row < self.scroll_bottom) {
                var r = self.cursor_row;
                while (r < self.scroll_bottom) : (r += 1) {
                    self.grid[r] = self.grid[r + 1];
                }
                self.clearLine(self.scroll_bottom);
            }
        }
    }

    fn csiInsertChars(self: *Terminal) void {
        const n = self.csiParam(0, 1);
        const count: usize = @intCast(@min(n, @as(u32, @intCast(self.cols - self.cursor_col))));
        // Shift characters right
        var c = self.cols - 1;
        while (c >= self.cursor_col + count) : (c -= 1) {
            self.grid[self.cursor_row][c] = self.grid[self.cursor_row][c - count];
            if (c == 0) break;
        }
        // Clear inserted positions
        for (self.cursor_col..self.cursor_col + count) |ci| {
            if (ci < self.cols) {
                self.grid[self.cursor_row][ci].reset(self.current_fg, self.current_bg);
            }
        }
    }

    fn csiDeleteChars(self: *Terminal) void {
        const n = self.csiParam(0, 1);
        const count: usize = @intCast(@min(n, @as(u32, @intCast(self.cols - self.cursor_col))));
        // Shift characters left
        var c = self.cursor_col;
        while (c + count < self.cols) : (c += 1) {
            self.grid[self.cursor_row][c] = self.grid[self.cursor_row][c + count];
        }
        // Clear vacated positions
        while (c < self.cols) : (c += 1) {
            self.grid[self.cursor_row][c].reset(self.current_fg, self.current_bg);
        }
    }

    fn csiEraseChars(self: *Terminal) void {
        const n = self.csiParam(0, 1);
        const count: usize = @intCast(@min(n, @as(u32, @intCast(self.cols - self.cursor_col))));
        for (self.cursor_col..self.cursor_col + count) |c| {
            if (c < self.cols) {
                self.grid[self.cursor_row][c].reset(self.current_fg, self.current_bg);
            }
        }
    }

    fn csiScrollUp(self: *Terminal) void {
        const n = self.csiParam(0, 1);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            self.scrollUp();
        }
    }

    fn csiScrollDown(self: *Terminal) void {
        const n = self.csiParam(0, 1);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            self.scrollDown();
        }
    }

    fn csiSetScrollRegion(self: *Terminal) void {
        const top = self.csiParam(0, 1);
        const bottom = self.csiParam(1, @as(u32, @intCast(self.rows)));
        self.scroll_top = if (top > 0) @as(usize, @intCast(top)) - 1 else 0;
        self.scroll_bottom = if (bottom > 0) @min(@as(usize, @intCast(bottom)) - 1, self.rows - 1) else self.rows - 1;
        if (self.scroll_top > self.scroll_bottom) {
            self.scroll_top = 0;
            self.scroll_bottom = if (self.rows > 0) self.rows - 1 else 0;
        }
        // DECSTBM resets cursor to top-left
        self.cursor_row = self.scroll_top;
        self.cursor_col = 0;
    }

    fn csiDeviceStatus(self: *Terminal) void {
        _ = self;
        // DSR — Device Status Report
        // Normally we'd send back a response, but since we're not connected
        // to a real PTY, we can ignore this.
    }

    fn csiSetPrivateMode(self: *Terminal, set: bool) void {
        const mode = self.csiParam(0, 0);
        switch (mode) {
            25 => {
                // DECTCEM — cursor visibility
                self.cursor_visible = set;
            },
            1049 => {
                // Alternate screen buffer — we don't support this but handle gracefully
                if (set) {
                    self.saved_cursor_col = self.cursor_col;
                    self.saved_cursor_row = self.cursor_row;
                    self.clearGrid();
                } else {
                    self.cursor_col = self.saved_cursor_col;
                    self.cursor_row = self.saved_cursor_row;
                }
            },
            else => {},
        }
    }

    // ── SGR (Select Graphic Rendition) ──────────────────────────────────

    fn csiSGR(self: *Terminal) void {
        // If no parameters, treat as SGR 0 (reset)
        if (self.csi_param_count == 0) {
            self.resetAttributes();
            return;
        }

        var i: usize = 0;
        while (i < self.csi_param_count) : (i += 1) {
            const p = self.csi_params[i];
            switch (p) {
                0 => self.resetAttributes(),
                1 => self.current_attr.bold = true,
                2 => self.current_attr.dim = true,
                3 => self.current_attr.italic = true,
                4 => self.current_attr.underline = true,
                5, 6 => self.current_attr.blink = true,
                7 => self.current_attr.inverse = true,
                8 => {}, // Hidden — not supported
                9 => self.current_attr.strikethrough = true,
                21 => self.current_attr.bold = false,
                22 => {
                    self.current_attr.bold = false;
                    self.current_attr.dim = false;
                },
                23 => self.current_attr.italic = false,
                24 => self.current_attr.underline = false,
                25 => self.current_attr.blink = false,
                27 => self.current_attr.inverse = false,
                29 => self.current_attr.strikethrough = false,

                // Foreground colours (standard 8)
                30 => self.current_fg = ANSI_COLOURS[0],
                31 => self.current_fg = ANSI_COLOURS[1],
                32 => self.current_fg = ANSI_COLOURS[2],
                33 => self.current_fg = ANSI_COLOURS[3],
                34 => self.current_fg = ANSI_COLOURS[4],
                35 => self.current_fg = ANSI_COLOURS[5],
                36 => self.current_fg = ANSI_COLOURS[6],
                37 => self.current_fg = ANSI_COLOURS[7],

                38 => {
                    // Extended foreground: 38;5;N (256-colour) or 38;2;R;G;B (24-bit)
                    if (i + 1 < self.csi_param_count) {
                        if (self.csi_params[i + 1] == 5 and i + 2 < self.csi_param_count) {
                            // 256-colour
                            const col_idx = self.csi_params[i + 2];
                            self.current_fg = colour256(col_idx);
                            i += 2;
                        } else if (self.csi_params[i + 1] == 2 and i + 4 < self.csi_param_count) {
                            // 24-bit RGB
                            self.current_fg = Colour.rgb(
                                @intCast(self.csi_params[i + 2] & 0xFF),
                                @intCast(self.csi_params[i + 3] & 0xFF),
                                @intCast(self.csi_params[i + 4] & 0xFF),
                            );
                            i += 4;
                        }
                    }
                },

                39 => self.current_fg = self.default_fg, // Default foreground

                // Background colours (standard 8)
                40 => self.current_bg = ANSI_COLOURS[0],
                41 => self.current_bg = ANSI_COLOURS[1],
                42 => self.current_bg = ANSI_COLOURS[2],
                43 => self.current_bg = ANSI_COLOURS[3],
                44 => self.current_bg = ANSI_COLOURS[4],
                45 => self.current_bg = ANSI_COLOURS[5],
                46 => self.current_bg = ANSI_COLOURS[6],
                47 => self.current_bg = ANSI_COLOURS[7],

                48 => {
                    // Extended background: 48;5;N or 48;2;R;G;B
                    if (i + 1 < self.csi_param_count) {
                        if (self.csi_params[i + 1] == 5 and i + 2 < self.csi_param_count) {
                            const col_idx = self.csi_params[i + 2];
                            self.current_bg = colour256(col_idx);
                            i += 2;
                        } else if (self.csi_params[i + 1] == 2 and i + 4 < self.csi_param_count) {
                            self.current_bg = Colour.rgb(
                                @intCast(self.csi_params[i + 2] & 0xFF),
                                @intCast(self.csi_params[i + 3] & 0xFF),
                                @intCast(self.csi_params[i + 4] & 0xFF),
                            );
                            i += 4;
                        }
                    }
                },

                49 => self.current_bg = self.default_bg, // Default background

                // Bright foreground colours
                90 => self.current_fg = ANSI_COLOURS[8],
                91 => self.current_fg = ANSI_COLOURS[9],
                92 => self.current_fg = ANSI_COLOURS[10],
                93 => self.current_fg = ANSI_COLOURS[11],
                94 => self.current_fg = ANSI_COLOURS[12],
                95 => self.current_fg = ANSI_COLOURS[13],
                96 => self.current_fg = ANSI_COLOURS[14],
                97 => self.current_fg = ANSI_COLOURS[15],

                // Bright background colours
                100 => self.current_bg = ANSI_COLOURS[8],
                101 => self.current_bg = ANSI_COLOURS[9],
                102 => self.current_bg = ANSI_COLOURS[10],
                103 => self.current_bg = ANSI_COLOURS[11],
                104 => self.current_bg = ANSI_COLOURS[12],
                105 => self.current_bg = ANSI_COLOURS[13],
                106 => self.current_bg = ANSI_COLOURS[14],
                107 => self.current_bg = ANSI_COLOURS[15],

                else => {}, // Unknown SGR parameter — ignore
            }
        }
    }

    // ── Character Placement ─────────────────────────────────────────────

    fn putChar(self: *Terminal, cp: u32) void {
        if (self.cursor_col >= self.cols) {
            // Auto-wrap: move to next line
            self.cursor_col = 0;
            self.lineFeed();
        }

        if (self.cursor_row < self.rows and self.cursor_col < self.cols) {
            var fg = self.current_fg;
            var bg = self.current_bg;

            if (self.current_attr.inverse) {
                const tmp = fg;
                fg = bg;
                bg = tmp;
            }

            self.grid[self.cursor_row][self.cursor_col] = Cell{
                .codepoint = cp,
                .fg = fg,
                .bg = bg,
                .attr = self.current_attr,
                .dirty = true,
            };
            self.cursor_col += 1;
        }
    }

    fn lineFeed(self: *Terminal) void {
        if (self.cursor_row >= self.scroll_bottom) {
            // At or past the bottom of the scroll region — scroll up
            self.scrollUp();
        } else {
            self.cursor_row += 1;
        }
    }
};

// ─── Global Terminal Pointer (for JIT runtime callbacks) ────────────────────

/// Global pointer to the editor's Terminal instance, set by EditorState.
/// Used by the JIT runtime's basic_cls() to request a direct screen clear
/// without relying on ANSI escape codes being piped and parsed.
var g_terminal: ?*Terminal = null;

/// Called by EditorState after init to register the terminal for runtime callbacks.
pub fn setGlobalTerminal(t: *Terminal) void {
    g_terminal = t;
}

/// Exported for the FasterBASIC runtime — requests a full terminal clear.
/// Thread-safe: sets an atomic flag that the main thread checks each frame.
export fn ed_terminal_cls() void {
    if (g_terminal) |t| {
        t.cls_requested.store(true, .release);
        t.has_new_output.store(true, .release);
    }
}

// ─── 256-Colour Lookup ──────────────────────────────────────────────────────

/// Convert a 256-colour index to an RGB Colour.
fn colour256(idx: u32) Colour {
    if (idx < 16) {
        // Standard 16 colours
        return ANSI_COLOURS[idx];
    } else if (idx < 232) {
        // 6×6×6 colour cube (indices 16–231)
        const cube_idx = idx - 16;
        const b_val = cube_idx % 6;
        const g_val = (cube_idx / 6) % 6;
        const r_val = cube_idx / 36;
        return Colour.rgb(
            @intCast(if (r_val > 0) r_val * 40 + 55 else 0),
            @intCast(if (g_val > 0) g_val * 40 + 55 else 0),
            @intCast(if (b_val > 0) b_val * 40 + 55 else 0),
        );
    } else if (idx < 256) {
        // Greyscale ramp (indices 232–255)
        const grey: u8 = @intCast((idx - 232) * 10 + 8);
        return Colour.rgb(grey, grey, grey);
    }
    return Colour.hex(0xFFFFFF);
}

// ─── Tests ──────────────────────────────────────────────────────────────────

test "Terminal init creates correct grid" {
    var term = Terminal.init(std.testing.allocator, 80, 24, Colour.hex(0xC0C0C0), Colour.hex(0x000020));
    defer term.deinit();

    try std.testing.expectEqual(@as(usize, 80), term.cols);
    try std.testing.expectEqual(@as(usize, 24), term.rows);
    try std.testing.expectEqual(@as(usize, 0), term.cursor_col);
    try std.testing.expectEqual(@as(usize, 0), term.cursor_row);
    try std.testing.expectEqual(@as(u32, ' '), term.getCellConst(0, 0).codepoint);
}

test "Terminal putChar places character and advances cursor" {
    var term = Terminal.init(std.testing.allocator, 80, 24, Colour.hex(0xC0C0C0), Colour.hex(0x000020));
    defer term.deinit();

    term.writeCodepoint('A');
    try std.testing.expectEqual(@as(u32, 'A'), term.getCellConst(0, 0).codepoint);
    try std.testing.expectEqual(@as(usize, 1), term.cursor_col);
    try std.testing.expectEqual(@as(usize, 0), term.cursor_row);
}

test "Terminal newline moves to next row" {
    var term = Terminal.init(std.testing.allocator, 80, 24, Colour.hex(0xC0C0C0), Colour.hex(0x000020));
    defer term.deinit();

    // LF (\n) moves cursor down but does NOT reset column (that's CR).
    // Use \r\n for a full newline (carriage return + line feed).
    term.writeBytes("Hello\r\n");
    try std.testing.expectEqual(@as(usize, 0), term.cursor_col);
    try std.testing.expectEqual(@as(usize, 1), term.cursor_row);
    try std.testing.expectEqual(@as(u32, 'H'), term.getCellConst(0, 0).codepoint);
}

test "Terminal carriage return resets column" {
    var term = Terminal.init(std.testing.allocator, 80, 24, Colour.hex(0xC0C0C0), Colour.hex(0x000020));
    defer term.deinit();

    term.writeBytes("Hello\r");
    try std.testing.expectEqual(@as(usize, 0), term.cursor_col);
    try std.testing.expectEqual(@as(usize, 0), term.cursor_row);
}

test "Terminal CRLF handling" {
    var term = Terminal.init(std.testing.allocator, 80, 24, Colour.hex(0xC0C0C0), Colour.hex(0x000020));
    defer term.deinit();

    term.writeBytes("Line1\r\nLine2");
    try std.testing.expectEqual(@as(u32, 'L'), term.getCellConst(0, 0).codepoint);
    try std.testing.expectEqual(@as(u32, 'L'), term.getCellConst(1, 0).codepoint);
    try std.testing.expectEqual(@as(usize, 5), term.cursor_col);
    try std.testing.expectEqual(@as(usize, 1), term.cursor_row);
}

test "Terminal auto-wrap at end of line" {
    var term = Terminal.init(std.testing.allocator, 10, 5, Colour.hex(0xC0C0C0), Colour.hex(0x000020));
    defer term.deinit();

    // Write more characters than the line width
    term.writeBytes("1234567890X");
    try std.testing.expectEqual(@as(usize, 1), term.cursor_col);
    try std.testing.expectEqual(@as(usize, 1), term.cursor_row);
    try std.testing.expectEqual(@as(u32, 'X'), term.getCellConst(1, 0).codepoint);
}

test "Terminal CSI cursor position" {
    var term = Terminal.init(std.testing.allocator, 80, 24, Colour.hex(0xC0C0C0), Colour.hex(0x000020));
    defer term.deinit();

    // ESC[5;10H — move cursor to row 5, col 10 (1-based)
    term.writeBytes("\x1b[5;10H");
    try std.testing.expectEqual(@as(usize, 4), term.cursor_row); // 0-based
    try std.testing.expectEqual(@as(usize, 9), term.cursor_col); // 0-based
}

test "Terminal CSI erase display" {
    var term = Terminal.init(std.testing.allocator, 80, 24, Colour.hex(0xC0C0C0), Colour.hex(0x000020));
    defer term.deinit();

    term.writeBytes("ABCDEF");
    // ESC[2J — clear entire screen
    term.writeBytes("\x1b[2J");
    try std.testing.expectEqual(@as(u32, ' '), term.getCellConst(0, 0).codepoint);
    try std.testing.expectEqual(@as(usize, 0), term.cursor_col);
    try std.testing.expectEqual(@as(usize, 0), term.cursor_row);
}

test "Terminal CSI erase to end of line" {
    var term = Terminal.init(std.testing.allocator, 80, 24, Colour.hex(0xC0C0C0), Colour.hex(0x000020));
    defer term.deinit();

    term.writeBytes("Hello World");
    // Move cursor to column 5
    term.writeBytes("\x1b[1;6H");
    // ESC[K — erase from cursor to end of line
    term.writeBytes("\x1b[K");
    try std.testing.expectEqual(@as(u32, 'H'), term.getCellConst(0, 0).codepoint);
    try std.testing.expectEqual(@as(u32, 'e'), term.getCellConst(0, 1).codepoint);
    try std.testing.expectEqual(@as(u32, 'l'), term.getCellConst(0, 2).codepoint);
    try std.testing.expectEqual(@as(u32, 'l'), term.getCellConst(0, 3).codepoint);
    try std.testing.expectEqual(@as(u32, 'o'), term.getCellConst(0, 4).codepoint);
    try std.testing.expectEqual(@as(u32, ' '), term.getCellConst(0, 5).codepoint);
}

test "Terminal SGR colour codes" {
    var term = Terminal.init(std.testing.allocator, 80, 24, Colour.hex(0xC0C0C0), Colour.hex(0x000020));
    defer term.deinit();

    // Set red foreground: ESC[31m
    term.writeBytes("\x1b[31m");
    try std.testing.expect(term.current_fg.eql(ANSI_COLOURS[1]));

    // Set bold: ESC[1m
    term.writeBytes("\x1b[1m");
    try std.testing.expect(term.current_attr.bold);

    // Reset: ESC[0m
    term.writeBytes("\x1b[0m");
    try std.testing.expect(!term.current_attr.bold);
    try std.testing.expect(term.current_fg.eql(Colour.hex(0xC0C0C0)));
}

test "Terminal SGR 256-colour foreground" {
    var term = Terminal.init(std.testing.allocator, 80, 24, Colour.hex(0xC0C0C0), Colour.hex(0x000020));
    defer term.deinit();

    // ESC[38;5;196m — set foreground to colour 196 (bright red in 256-colour)
    term.writeBytes("\x1b[38;5;196m");
    // Colour 196 = cube index 196-16=180, r=180/36=5, g=(180%36)/6=0, b=0
    // r = 5*40+55=255, g=0, b=0
    try std.testing.expectEqual(@as(u8, 255), term.current_fg.r);
    try std.testing.expectEqual(@as(u8, 0), term.current_fg.g);
    try std.testing.expectEqual(@as(u8, 0), term.current_fg.b);
}

test "Terminal SGR 24-bit colour" {
    var term = Terminal.init(std.testing.allocator, 80, 24, Colour.hex(0xC0C0C0), Colour.hex(0x000020));
    defer term.deinit();

    // ESC[38;2;100;200;50m — set foreground to RGB(100,200,50)
    term.writeBytes("\x1b[38;2;100;200;50m");
    try std.testing.expectEqual(@as(u8, 100), term.current_fg.r);
    try std.testing.expectEqual(@as(u8, 200), term.current_fg.g);
    try std.testing.expectEqual(@as(u8, 50), term.current_fg.b);
}

test "Terminal scroll up pushes to scrollback" {
    var term = Terminal.init(std.testing.allocator, 80, 5, Colour.hex(0xC0C0C0), Colour.hex(0x000020));
    defer term.deinit();

    // Fill 6 lines (should cause 1 scroll)
    term.writeBytes("Line1\nLine2\nLine3\nLine4\nLine5\nLine6");
    // After 6 lines in a 5-row terminal, there should be 1 line in scrollback
    try std.testing.expectEqual(@as(usize, 1), term.scrollback.items.len);
}

test "Terminal cursor save and restore" {
    var term = Terminal.init(std.testing.allocator, 80, 24, Colour.hex(0xC0C0C0), Colour.hex(0x000020));
    defer term.deinit();

    term.writeBytes("\x1b[5;10H"); // Move to (4,9)
    term.writeBytes("\x1b[s"); // Save
    term.writeBytes("\x1b[1;1H"); // Move to (0,0)
    try std.testing.expectEqual(@as(usize, 0), term.cursor_row);
    try std.testing.expectEqual(@as(usize, 0), term.cursor_col);
    term.writeBytes("\x1b[u"); // Restore
    try std.testing.expectEqual(@as(usize, 4), term.cursor_row);
    try std.testing.expectEqual(@as(usize, 9), term.cursor_col);
}

test "Terminal cursor movement sequences" {
    var term = Terminal.init(std.testing.allocator, 80, 24, Colour.hex(0xC0C0C0), Colour.hex(0x000020));
    defer term.deinit();

    term.writeBytes("\x1b[10;20H"); // Start at (9,19)
    term.writeBytes("\x1b[3A"); // Up 3
    try std.testing.expectEqual(@as(usize, 6), term.cursor_row);
    term.writeBytes("\x1b[2B"); // Down 2
    try std.testing.expectEqual(@as(usize, 8), term.cursor_row);
    term.writeBytes("\x1b[5C"); // Forward 5
    try std.testing.expectEqual(@as(usize, 24), term.cursor_col);
    term.writeBytes("\x1b[10D"); // Backward 10
    try std.testing.expectEqual(@as(usize, 14), term.cursor_col);
}

test "Terminal resize clamps cursor" {
    var term = Terminal.init(std.testing.allocator, 80, 24, Colour.hex(0xC0C0C0), Colour.hex(0x000020));
    defer term.deinit();

    term.cursor_col = 70;
    term.cursor_row = 20;
    term.resize(40, 10);
    try std.testing.expectEqual(@as(usize, 39), term.cursor_col);
    try std.testing.expectEqual(@as(usize, 9), term.cursor_row);
}

test "Terminal backspace moves cursor back" {
    var term = Terminal.init(std.testing.allocator, 80, 24, Colour.hex(0xC0C0C0), Colour.hex(0x000020));
    defer term.deinit();

    term.writeBytes("ABC\x08");
    try std.testing.expectEqual(@as(usize, 2), term.cursor_col);
}

test "Terminal tab advances to next tab stop" {
    var term = Terminal.init(std.testing.allocator, 80, 24, Colour.hex(0xC0C0C0), Colour.hex(0x000020));
    defer term.deinit();

    term.writeBytes("AB\t");
    try std.testing.expectEqual(@as(usize, 8), term.cursor_col);
}

test "Terminal ESC 7/8 save and restore cursor" {
    var term = Terminal.init(std.testing.allocator, 80, 24, Colour.hex(0xC0C0C0), Colour.hex(0x000020));
    defer term.deinit();

    term.writeBytes("\x1b[3;5H"); // Move to (2,4)
    term.writeBytes("\x1b\x37"); // ESC 7 = save
    term.writeBytes("\x1b[1;1H"); // Move to (0,0)
    term.writeBytes("\x1b\x38"); // ESC 8 = restore
    try std.testing.expectEqual(@as(usize, 2), term.cursor_row);
    try std.testing.expectEqual(@as(usize, 4), term.cursor_col);
}

test "Terminal clear from cursor" {
    var term = Terminal.init(std.testing.allocator, 10, 3, Colour.hex(0xC0C0C0), Colour.hex(0x000020));
    defer term.deinit();

    term.writeBytes("AAAAAAAAAA");
    term.writeBytes("BBBBBBBBBB");
    term.writeBytes("CCCCCCCC");
    term.setCursorPos(1, 5);
    // ESC[0J — erase from cursor to end
    term.writeBytes("\x1b[0J");
    // Row 0 should be intact
    try std.testing.expectEqual(@as(u32, 'A'), term.getCellConst(0, 0).codepoint);
    // Row 1 col 0-4 should be intact, col 5+ should be space
    try std.testing.expectEqual(@as(u32, 'B'), term.getCellConst(1, 0).codepoint);
    try std.testing.expectEqual(@as(u32, ' '), term.getCellConst(1, 5).codepoint);
    // Row 2 should be cleared
    try std.testing.expectEqual(@as(u32, ' '), term.getCellConst(2, 0).codepoint);
}

test "colour256 standard colours" {
    const c0 = colour256(0);
    try std.testing.expect(c0.eql(ANSI_COLOURS[0]));
    const c15 = colour256(15);
    try std.testing.expect(c15.eql(ANSI_COLOURS[15]));
}

test "colour256 cube colours" {
    // Index 16 = (0,0,0) = black
    const c16 = colour256(16);
    try std.testing.expectEqual(@as(u8, 0), c16.r);
    try std.testing.expectEqual(@as(u8, 0), c16.g);
    try std.testing.expectEqual(@as(u8, 0), c16.b);

    // Index 196 = (5,0,0) = pure red = 255,0,0
    const c196 = colour256(196);
    try std.testing.expectEqual(@as(u8, 255), c196.r);
    try std.testing.expectEqual(@as(u8, 0), c196.g);
    try std.testing.expectEqual(@as(u8, 0), c196.b);
}

test "colour256 greyscale" {
    // Index 232 = grey 8
    const c232 = colour256(232);
    try std.testing.expectEqual(@as(u8, 8), c232.r);
    try std.testing.expectEqual(@as(u8, 8), c232.g);
    try std.testing.expectEqual(@as(u8, 8), c232.b);

    // Index 255 = grey 238
    const c255 = colour256(255);
    try std.testing.expectEqual(@as(u8, 238), c255.r);
    try std.testing.expectEqual(@as(u8, 238), c255.g);
    try std.testing.expectEqual(@as(u8, 238), c255.b);
}

test "Terminal ring buffer write and drain" {
    var term = Terminal.init(std.testing.allocator, 80, 24, Colour.hex(0xC0C0C0), Colour.hex(0x000020));
    defer term.deinit();

    term.ringWrite("Hi");
    try std.testing.expect(term.has_new_output.load(.acquire));

    term.drainOutputRing();
    try std.testing.expectEqual(@as(u32, 'H'), term.getCellConst(0, 0).codepoint);
    try std.testing.expectEqual(@as(u32, 'i'), term.getCellConst(0, 1).codepoint);
    try std.testing.expect(!term.has_new_output.load(.acquire));
}

test "Terminal scroll region" {
    var term = Terminal.init(std.testing.allocator, 20, 5, Colour.hex(0xC0C0C0), Colour.hex(0x000020));
    defer term.deinit();

    // Set scroll region to rows 2-4 (1-based)
    term.writeBytes("\x1b[2;4r");
    try std.testing.expectEqual(@as(usize, 1), term.scroll_top);
    try std.testing.expectEqual(@as(usize, 3), term.scroll_bottom);
    // Cursor should be at the top of scroll region
    try std.testing.expectEqual(@as(usize, 1), term.cursor_row);
    try std.testing.expectEqual(@as(usize, 0), term.cursor_col);
}

test "Terminal inverse attribute" {
    var term = Terminal.init(std.testing.allocator, 80, 24, Colour.hex(0xC0C0C0), Colour.hex(0x000020));
    defer term.deinit();

    // ESC[7m — inverse
    term.writeBytes("\x1b[7m");
    try std.testing.expect(term.current_attr.inverse);
    term.writeCodepoint('X');
    // The cell fg/bg should be swapped
    const cell = term.getCellConst(0, 0);
    try std.testing.expect(cell.fg.eql(Colour.hex(0x000020))); // bg as fg
    try std.testing.expect(cell.bg.eql(Colour.hex(0xC0C0C0))); // fg as bg
}

test "Terminal full reset via ESC c" {
    var term = Terminal.init(std.testing.allocator, 80, 24, Colour.hex(0xC0C0C0), Colour.hex(0x000020));
    defer term.deinit();

    term.writeBytes("ABCDEF");
    term.writeBytes("\x1b[31m"); // Set red
    term.writeBytes("\x1b\x63"); // Full reset

    try std.testing.expectEqual(@as(usize, 0), term.cursor_row);
    try std.testing.expectEqual(@as(usize, 0), term.cursor_col);
    try std.testing.expectEqual(@as(u32, ' '), term.getCellConst(0, 0).codepoint);
    try std.testing.expect(term.current_fg.eql(Colour.hex(0xC0C0C0)));
}
