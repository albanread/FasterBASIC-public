//! ed_format.zig — BASIC source code formatter for the Ed editor
//!
//! Reformats FasterBASIC source code with:
//!   - Consistent 2-space indentation based on block structure
//!   - Uppercased keywords (IF, FOR, PRINT, etc.)
//!   - Trimmed trailing whitespace
//!   - Preserved blank lines (collapsed to single blank)
//!   - Preserved string literals and comments verbatim
//!
//! Usage:
//!   const result = formatBasic(allocator, codepoints);
//!   defer allocator.free(result);

const std = @import("std");

/// Number of spaces per indent level.
const INDENT: usize = 2;

/// Format an entire BASIC source buffer (as UTF-32 code points).
/// Returns a newly allocated code point slice with reformatted text.
/// The caller must free the returned slice.
pub fn formatBasic(allocator: std.mem.Allocator, source: []const u32) ![]u32 {
    // Split into lines
    var lines = std.ArrayListUnmanaged([]const u32){};
    defer lines.deinit(allocator);

    var start: usize = 0;
    for (source, 0..) |cp, i| {
        if (cp == '\n') {
            try lines.append(allocator, source[start..i]);
            start = i + 1;
        }
    }
    // Last line (may not end with newline)
    if (start <= source.len) {
        try lines.append(allocator, source[start..]);
    }

    // Process each line: determine indent level, strip leading whitespace,
    // uppercase keywords, and rebuild with correct indentation.
    var out = std.ArrayListUnmanaged(u32){};
    defer out.deinit(allocator);

    var indent_level: i32 = 0;
    var prev_blank = false;
    var in_triple_string = false;

    for (lines.items) |raw_line| {
        // ── Triple-quoted string continuation ──────────────────────────────
        // When inside a """...""" multiline string, emit lines verbatim so
        // the formatter never touches the string's content or indentation.
        if (in_triple_string) {
            if (findTripleQuote(raw_line)) |close_pos| {
                // Closing """ found — emit everything up to and including it
                // verbatim, then process any trailing code on the same line.
                for (raw_line[0 .. close_pos + 3]) |c| try out.append(allocator, c);
                in_triple_string = false;
                const after = stripLeading(stripTrailing(raw_line[close_pos + 3 ..]));
                if (after.len > 0) {
                    try appendLineWithTripleHandling(allocator, &out, after, &in_triple_string);
                }
                try out.append(allocator, '\n');
            } else {
                // Entirely inside triple string — emit raw line verbatim.
                for (raw_line) |c| try out.append(allocator, c);
                try out.append(allocator, '\n');
            }
            prev_blank = false;
            continue;
        }
        // Strip leading whitespace
        const stripped = stripLeading(raw_line);
        // Strip trailing whitespace
        const trimmed = stripTrailing(stripped);

        // Blank line handling — preserve one blank, collapse multiples
        if (trimmed.len == 0) {
            if (!prev_blank and out.items.len > 0) {
                try out.append(allocator, '\n');
            }
            prev_blank = true;
            continue;
        }
        prev_blank = false;

        // Extract the first keyword(s) to determine indent changes
        const line_info = classifyLine(trimmed);

        // Apply dedent BEFORE writing this line
        if (line_info.dedent_before > 0) {
            indent_level -= @as(i32, @intCast(line_info.dedent_before));
            if (indent_level < 0) indent_level = 0;
        }

        // Label lines get zero indent
        const effective_indent: usize = if (line_info.is_label)
            0
        else
            @as(usize, @intCast(indent_level));

        // Detect leading line number (digits followed by whitespace).
        // Line numbers are NEVER indented — indent goes AFTER the number.
        var line_num_end: usize = 0;
        if (trimmed.len > 0 and trimmed[0] >= '0' and trimmed[0] <= '9') {
            while (line_num_end < trimmed.len and trimmed[line_num_end] >= '0' and trimmed[line_num_end] <= '9') {
                line_num_end += 1;
            }
        }

        if (line_num_end > 0) {
            // Write line number first (no indentation before it)
            for (trimmed[0..line_num_end]) |c| {
                try out.append(allocator, c);
            }
            // Write a space after the line number
            try out.append(allocator, ' ');
            // Write indent AFTER the line number
            for (0..effective_indent * INDENT) |_| {
                try out.append(allocator, ' ');
            }
            // Skip whitespace between line number and content
            const content_start = skipWhitespace(trimmed, line_num_end);
            // Write the line content (after the line number) with keywords uppercased
            try appendLineWithTripleHandling(allocator, &out, trimmed[content_start..], &in_triple_string);
        } else {
            // No line number — write indent then content as before
            for (0..effective_indent * INDENT) |_| {
                try out.append(allocator, ' ');
            }
            // Write the line content with keywords uppercased
            try appendLineWithTripleHandling(allocator, &out, trimmed, &in_triple_string);
        }

        // Newline
        try out.append(allocator, '\n');

        // Apply indent AFTER writing this line
        if (line_info.indent_after > 0) {
            indent_level += @as(i32, @intCast(line_info.indent_after));
        }
    }

    // Remove trailing newline if the original didn't have one
    if (out.items.len > 0 and source.len > 0 and source[source.len - 1] != '\n') {
        if (out.items[out.items.len - 1] == '\n') {
            _ = out.pop();
        }
    }

    // Remove trailing blank lines (extra newlines at the end)
    while (out.items.len >= 2 and
        out.items[out.items.len - 1] == '\n' and
        out.items[out.items.len - 2] == '\n')
    {
        _ = out.pop();
    }

    return out.toOwnedSlice(allocator);
}

// ============================================================================
// Triple-quoted string helpers
// ============================================================================

/// Returns the index of the first `"""` sequence in `line`, or null.
fn findTripleQuote(line: []const u32) ?usize {
    if (line.len < 3) return null;
    var i: usize = 0;
    while (i + 3 <= line.len) : (i += 1) {
        if (line[i] == '"' and line[i + 1] == '"' and line[i + 2] == '"') return i;
    }
    return null;
}

// ============================================================================
// Line classification — determines indent changes
// ============================================================================

pub const LineInfo = struct {
    /// How many indent levels to remove BEFORE this line.
    dedent_before: u8,
    /// How many indent levels to add AFTER this line.
    indent_after: u8,
    /// True if this is a label line (gets zero indent).
    is_label: bool,
};

pub fn classifyLine(line: []const u32) LineInfo {
    var info = LineInfo{
        .dedent_before = 0,
        .indent_after = 0,
        .is_label = false,
    };

    if (line.len == 0) return info;

    // Skip leading line number (digits followed by whitespace).
    // Line-numbered BASIC: "1360 IF dist = 8 THEN" — we need to
    // look past "1360 " to find the keyword.
    var content_start: usize = 0;
    if (line[0] >= '0' and line[0] <= '9') {
        while (content_start < line.len and line[content_start] >= '0' and line[content_start] <= '9') {
            content_start += 1;
        }
        content_start = skipWhitespace(line, content_start);
    }
    const content = line[content_start..];

    if (content.len == 0) return info;

    // Check for comment — no indent changes
    if (content[0] == '\'' or startsWithRem(content)) return info;

    // Check for label (identifier followed by colon, not a keyword)
    // Only for non-numbered lines — numbered lines don't use label syntax.
    if (content_start == 0 and isLabelLine(content)) {
        info.is_label = true;
        return info;
    }

    // Extract first word (past the line number, if any)
    var word_buf: [32]u8 = undefined;
    const first = extractUpperWord(content, 0, &word_buf);
    const w1 = first.word;
    const after1 = first.next_pos;

    if (w1.len == 0) return info;

    // ── Block closers (dedent before) ───────────────────────────────

    // END followed by a block keyword
    if (eql(w1, "END")) {
        var word2_buf: [32]u8 = undefined;
        const second = extractUpperWord(content, after1, &word2_buf);
        const w2 = second.word;

        if (eql(w2, "IF") or eql(w2, "SUB") or eql(w2, "FUNCTION") or
            eql(w2, "SELECT") or eql(w2, "TYPE") or eql(w2, "CLASS") or
            eql(w2, "WORKER") or eql(w2, "MATCH") or eql(w2, "CASE") or
            eql(w2, "METHOD") or eql(w2, "CONSTRUCTOR") or
            eql(w2, "DESTRUCTOR") or eql(w2, "TRY") or
            eql(w2, "WINDOW") or eql(w2, "DEFINE"))
        {
            info.dedent_before = 1;
            return info;
        }

        // Bare END — just a statement, no indent change
        return info;
    }

    // Compound closers
    if (eql(w1, "ENDIF") or eql(w1, "ENDSUB") or eql(w1, "ENDFUNCTION") or
        eql(w1, "ENDTYPE") or eql(w1, "ENDCASE") or eql(w1, "ENDMATCH") or
        eql(w1, "ENDWORKER"))
    {
        info.dedent_before = 1;
        return info;
    }

    // NEXT, WEND, LOOP, DONE, UNTIL
    if (eql(w1, "NEXT") or eql(w1, "WEND") or eql(w1, "DONE") or eql(w1, "UNTIL")) {
        info.dedent_before = 1;
        return info;
    }
    if (eql(w1, "LOOP")) {
        info.dedent_before = 1;
        return info;
    }

    // ── Hinge keywords (dedent before + indent after) ───────────────

    if (eql(w1, "ELSE")) {
        info.dedent_before = 1;
        // Check if it's ELSE followed by content on the same line (single-line ELSE)
        // If there's non-trivial content after ELSE, it's a single-line else
        const rest = skipWhitespace(content, after1);
        if (rest < content.len and content[rest] != '\'' and !isLineEnd(content, rest)) {
            // Single-line ELSE — dedent before, indent after to re-open
            info.indent_after = 1;
            // Actually single-line else: the next line should be at the same level
            // so no indent_after. But we need to re-indent because ELSE opens a block.
            // ELSE <statement> is single-line — no indent change after.
            info.indent_after = 0;
            // But we still need the block after ELSE if it ends the line
            // Actually for "ELSE" with stuff after it, it's single-line form
            info.dedent_before = 1;
            return info;
        }
        // Multi-line ELSE — dedent before, indent after
        info.indent_after = 1;
        return info;
    }

    if (eql(w1, "ELSEIF")) {
        info.dedent_before = 1;
        // ELSEIF always opens a new block (the THEN part)
        // Check for THEN at end of line
        if (lineEndsWithKeyword(content, "THEN")) {
            info.indent_after = 1;
        } else {
            // Implicit THEN
            info.indent_after = 1;
        }
        return info;
    }

    if (eql(w1, "CASE")) {
        // CASE within SELECT — dedent before, indent after
        // But only if we're not at top level (which would be SELECT CASE)
        // We check if the previous context was a SELECT, but we don't have
        // that info here, so we use a heuristic: CASE as first word and
        // not followed by ELSE right after = it's a case branch
        info.dedent_before = 1;
        info.indent_after = 1;
        return info;
    }

    if (eql(w1, "CATCH") or eql(w1, "FINALLY") or eql(w1, "OTHERWISE")) {
        info.dedent_before = 1;
        info.indent_after = 1;
        return info;
    }

    if (eql(w1, "WHEN")) {
        info.dedent_before = 1;
        info.indent_after = 1;
        return info;
    }

    // ── Block openers (indent after) ────────────────────────────────

    // IF ... THEN (multi-line)
    if (eql(w1, "IF")) {
        // Single-line IF: IF ... THEN <statement>
        // Multi-line IF: IF ... THEN (nothing after) or IF ... (no THEN)
        if (isSingleLineIf(content, after1)) {
            // No indent change
            return info;
        }
        info.indent_after = 1;
        return info;
    }

    // FOR
    if (eql(w1, "FOR")) {
        info.indent_after = 1;
        return info;
    }

    // WHILE
    if (eql(w1, "WHILE")) {
        info.indent_after = 1;
        return info;
    }

    // DO
    if (eql(w1, "DO")) {
        info.indent_after = 1;
        return info;
    }

    // REPEAT
    if (eql(w1, "REPEAT")) {
        info.indent_after = 1;
        return info;
    }

    // SUB / FUNCTION / METHOD / CONSTRUCTOR / DESTRUCTOR
    if (eql(w1, "SUB") or eql(w1, "FUNCTION") or eql(w1, "METHOD") or
        eql(w1, "CONSTRUCTOR") or eql(w1, "DESTRUCTOR") or eql(w1, "DEF"))
    {
        info.indent_after = 1;
        return info;
    }

    // SELECT
    if (eql(w1, "SELECT")) {
        info.indent_after = 1;
        return info;
    }

    // TYPE / CLASS
    if (eql(w1, "TYPE") or eql(w1, "CLASS")) {
        info.indent_after = 1;
        return info;
    }

    // WORKER
    if (eql(w1, "WORKER")) {
        info.indent_after = 1;
        return info;
    }

    // TRY
    if (eql(w1, "TRY")) {
        info.indent_after = 1;
        return info;
    }

    // MATCH
    if (eql(w1, "MATCH")) {
        info.indent_after = 1;
        return info;
    }

    // WINDOW DEFINE / MENU DEFINE / WINDOW CANVAS BEGIN
    if (eql(w1, "WINDOW")) {
        var w2_buf: [32]u8 = undefined;
        const second = extractUpperWord(content, after1, &w2_buf);
        const w2 = second.word;

        if (eql(w2, "DEFINE")) {
            info.indent_after = 1;
            return info;
        }

        if (eql(w2, "CANVAS")) {
            var w3_buf: [32]u8 = undefined;
            const third = extractUpperWord(content, second.next_pos, &w3_buf);
            if (eql(third.word, "BEGIN")) {
                info.indent_after = 1;
                return info;
            }
            if (eql(third.word, "END")) {
                info.dedent_before = 1;
                return info;
            }
        }

        if (eql(w2, "IMAGE")) {
            var w3_buf: [32]u8 = undefined;
            const third = extractUpperWord(content, second.next_pos, &w3_buf);
            if (eql(third.word, "BEGIN")) {
                info.indent_after = 1;
                return info;
            }
            if (eql(third.word, "END")) {
                info.dedent_before = 1;
                return info;
            }
        }
    }

    if (eql(w1, "MENU")) {
        var w2_buf: [32]u8 = undefined;
        const second = extractUpperWord(content, after1, &w2_buf);
        if (eql(second.word, "DEFINE")) {
            info.indent_after = 1;
            return info;
        }
    }

    return info;
}

// ============================================================================
// Line formatting — uppercase keywords, preserve strings/comments
// ============================================================================

fn appendFormattedLine(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u32), line: []const u32) !void {
    var i: usize = 0;
    while (i < line.len) {
        const cp = line[i];

        // Comment — copy rest of line verbatim
        if (cp == '\'') {
            for (line[i..]) |c| {
                try out.append(allocator, c);
            }
            return;
        }

        // REM comment — uppercase REM, then copy rest verbatim
        if (isIdentStart(cp)) {
            const word_start = i;
            var end = i;
            while (end < line.len and isIdentChar(line[end])) : (end += 1) {}

            // Check for type suffix
            if (end < line.len and isTypeSuffix(line[end])) {
                end += 1;
            }

            var ubuf: [64]u8 = undefined;
            const upper = toUpperSlice(line[word_start..end], &ubuf);

            if (word_start == 0 and eql(upper, "REM")) {
                // REM comment — uppercase REM, rest verbatim
                try out.append(allocator, 'R');
                try out.append(allocator, 'E');
                try out.append(allocator, 'M');
                for (line[end..]) |c| {
                    try out.append(allocator, c);
                }
                return;
            }

            // Check if this word is a keyword
            if (isKeyword(upper)) {
                // Emit uppercased keyword
                for (line[word_start..end]) |c| {
                    if (c >= 'a' and c <= 'z') {
                        try out.append(allocator, c - 32);
                    } else {
                        try out.append(allocator, c);
                    }
                }
            } else {
                // Not a keyword — emit as-is
                for (line[word_start..end]) |c| {
                    try out.append(allocator, c);
                }
            }
            i = end;
            continue;
        }

        // String literal — copy verbatim
        if (cp == '"') {
            try out.append(allocator, cp);
            i += 1;
            while (i < line.len) {
                try out.append(allocator, line[i]);
                if (line[i] == '"') {
                    i += 1;
                    break;
                }
                i += 1;
            }
            continue;
        }

        // Collapse multiple spaces between tokens to single space
        // (but not inside strings, already handled above)
        if (cp == ' ' or cp == '\t') {
            try out.append(allocator, ' ');
            i += 1;
            while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
            continue;
        }

        // Everything else — copy as-is
        try out.append(allocator, cp);
        i += 1;
    }
}

/// Formats a line while preserving any content inside triple-quoted strings.
/// Parts outside """ blocks are formatted normally; everything between an
/// opening and closing """ is emitted verbatim. If a closing delimiter is not
/// found on the same line, `in_triple_string` is set so following lines are
/// copied verbatim until the closing delimiter appears.
fn appendLineWithTripleHandling(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u32),
    line: []const u32,
    in_triple_string: *bool,
) !void {
    var start: usize = 0;
    while (start < line.len) {
        if (findTripleQuote(line[start..])) |pos_rel| {
            const open = start + pos_rel;
            if (open > start) {
                try appendFormattedLine(allocator, out, line[start..open]);
            }

            const after_open = open + 3;
            if (after_open > line.len) {
                // Degenerate case: line ends mid-delimiter; treat as open.
                for (line[open..]) |c| try out.append(allocator, c);
                in_triple_string.* = true;
                return;
            }

            if (findTripleQuote(line[after_open..])) |close_rel| {
                const close = after_open + close_rel;
                for (line[open .. close + 3]) |c| try out.append(allocator, c);
                in_triple_string.* = false;
                start = close + 3;
                // Continue scanning in case there is more code after the triple.
                continue;
            }

            // Triple opens and continues onto the next line — emit the rest verbatim.
            for (line[open..]) |c| try out.append(allocator, c);
            in_triple_string.* = true;
            return;
        }

        // No more triple delimiters; format the remainder and finish.
        try appendFormattedLine(allocator, out, line[start..]);
        return;
    }
}

// ============================================================================
// Keyword detection
// ============================================================================

pub fn isKeyword(upper: []const u8) bool {
    // Control flow
    if (eql(upper, "IF") or eql(upper, "THEN") or eql(upper, "ELSE") or
        eql(upper, "ELSEIF") or eql(upper, "ENDIF") or
        eql(upper, "FOR") or eql(upper, "TO") or eql(upper, "STEP") or
        eql(upper, "NEXT") or eql(upper, "WHILE") or eql(upper, "WEND") or
        eql(upper, "DO") or eql(upper, "LOOP") or eql(upper, "UNTIL") or
        eql(upper, "REPEAT") or eql(upper, "SELECT") or eql(upper, "CASE") or
        eql(upper, "ENDCASE") or eql(upper, "OTHERWISE") or
        eql(upper, "EXIT") or eql(upper, "GOTO") or eql(upper, "GOSUB") or
        eql(upper, "RETURN") or eql(upper, "ON") or eql(upper, "END") or
        eql(upper, "DONE") or eql(upper, "MATCH") or eql(upper, "ENDMATCH") or
        eql(upper, "WHEN") or eql(upper, "IS") or
        eql(upper, "TRY") or eql(upper, "CATCH") or eql(upper, "FINALLY") or
        eql(upper, "THROW"))
    {
        return true;
    }

    // Subroutine
    if (eql(upper, "SUB") or eql(upper, "FUNCTION") or
        eql(upper, "ENDSUB") or eql(upper, "ENDFUNCTION") or
        eql(upper, "METHOD") or eql(upper, "CONSTRUCTOR") or
        eql(upper, "DESTRUCTOR") or eql(upper, "CALL") or
        eql(upper, "DEF") or eql(upper, "FN"))
    {
        return true;
    }

    // Type keywords
    if (eql(upper, "DIM") or eql(upper, "REDIM") or eql(upper, "AS") or
        eql(upper, "TYPE") or eql(upper, "ENDTYPE") or
        eql(upper, "CLASS") or eql(upper, "EXTENDS") or
        eql(upper, "INTEGER") or eql(upper, "DOUBLE") or eql(upper, "SINGLE") or
        eql(upper, "STRING") or eql(upper, "LONG") or eql(upper, "BYTE") or
        eql(upper, "SHORT") or eql(upper, "BOOLEAN") or
        eql(upper, "UBYTE") or eql(upper, "USHORT") or
        eql(upper, "UINTEGER") or eql(upper, "ULONG") or
        eql(upper, "HASHMAP") or eql(upper, "LIST") or
        eql(upper, "NEW") or eql(upper, "CREATE") or eql(upper, "DELETE") or
        eql(upper, "NOTHING") or eql(upper, "ME") or eql(upper, "SUPER") or
        eql(upper, "CONSTANT") or eql(upper, "SHARED") or
        eql(upper, "LOCAL") or eql(upper, "GLOBAL") or
        eql(upper, "BYREF") or eql(upper, "BYVAL") or
        eql(upper, "ERASE") or eql(upper, "PRESERVE") or
        eql(upper, "MARSHALLED"))
    {
        return true;
    }

    // Worker / concurrency
    if (eql(upper, "WORKER") or eql(upper, "ENDWORKER") or
        eql(upper, "SPAWN") or eql(upper, "AWAIT") or
        eql(upper, "SEND") or eql(upper, "RECEIVE") or
        eql(upper, "HASMESSAGE") or eql(upper, "CANCEL") or
        eql(upper, "CANCELLED") or eql(upper, "MARSHALL") or
        eql(upper, "UNMARSHALL") or eql(upper, "FUTURE") or
        eql(upper, "READY") or eql(upper, "PARENT"))
    {
        return true;
    }

    // I/O and general keywords
    if (eql(upper, "PRINT") or eql(upper, "INPUT") or eql(upper, "LET") or
        eql(upper, "REM") or eql(upper, "CLS") or eql(upper, "COLOR") or
        eql(upper, "COLOUR") or eql(upper, "LOCATE") or
        eql(upper, "OPEN") or eql(upper, "CLOSE") or
        eql(upper, "READ") or eql(upper, "WRITE") or eql(upper, "DATA") or
        eql(upper, "RESTORE") or eql(upper, "SWAP") or
        eql(upper, "INC") or eql(upper, "DEC") or
        eql(upper, "SLEEP") or eql(upper, "WAIT") or eql(upper, "TIMER") or
        eql(upper, "INCLUDE") or
        eql(upper, "SHELL") or eql(upper, "SYSTEM") or
        eql(upper, "CONSOLE") or eql(upper, "SLURP") or eql(upper, "SPIT") or
        eql(upper, "IIF") or eql(upper, "USING") or
        eql(upper, "STOP") or eql(upper, "RUN"))
    {
        return true;
    }

    // Logical / bitwise operators (keyword form)
    if (eql(upper, "AND") or eql(upper, "OR") or eql(upper, "NOT") or
        eql(upper, "XOR") or eql(upper, "MOD") or
        eql(upper, "EQV") or eql(upper, "IMP"))
    {
        return true;
    }

    // List / collection keywords
    if (eql(upper, "APPEND") or eql(upper, "PREPEND") or
        eql(upper, "HEAD") or eql(upper, "TAIL") or
        eql(upper, "REST") or eql(upper, "LENGTH") or
        eql(upper, "EMPTY") or eql(upper, "CONTAINS") or
        eql(upper, "KEYS") or eql(upper, "SIZE") or
        eql(upper, "CLEAR") or eql(upper, "REMOVE") or
        eql(upper, "HASKEY") or eql(upper, "TYPEOF"))
    {
        return true;
    }

    // Timer / event keywords
    if (eql(upper, "AFTER") or eql(upper, "EVERY")) {
        return true;
    }

    // Audio keywords (compound statement prefixes)
    if (eql(upper, "SOUND") or eql(upper, "MUSIC") or eql(upper, "VS")) {
        return true;
    }

    // Built-in functions (commonly used, uppercase by convention)
    if (eql(upper, "ABS") or eql(upper, "SGN") or eql(upper, "SQR") or
        eql(upper, "INT") or eql(upper, "FIX") or eql(upper, "CINT") or
        eql(upper, "CLNG") or eql(upper, "CDBL") or eql(upper, "CSNG") or
        eql(upper, "SIN") or eql(upper, "COS") or eql(upper, "TAN") or
        eql(upper, "ATN") or eql(upper, "LOG") or eql(upper, "EXP") or
        eql(upper, "RND") or eql(upper, "RANDOMIZE") or
        eql(upper, "LEN") or eql(upper, "VAL") or eql(upper, "STR") or
        eql(upper, "CHR") or eql(upper, "ASC") or
        eql(upper, "LEFT") or eql(upper, "RIGHT") or eql(upper, "MID") or
        eql(upper, "INSTR") or eql(upper, "LCASE") or eql(upper, "UCASE") or
        eql(upper, "LTRIM") or eql(upper, "RTRIM") or eql(upper, "TRIM") or
        eql(upper, "SPACE") or eql(upper, "TAB") or
        eql(upper, "HEX") or eql(upper, "OCT") or eql(upper, "BIN") or
        eql(upper, "PEEK") or eql(upper, "POKE") or
        eql(upper, "LBOUND") or eql(upper, "UBOUND") or
        eql(upper, "EOF") or eql(upper, "LOC") or eql(upper, "LOF") or
        eql(upper, "FREEFILE") or
        eql(upper, "TRUE") or eql(upper, "FALSE") or
        eql(upper, "CVS") or eql(upper, "CVD") or eql(upper, "MKS") or eql(upper, "MKD") or
        eql(upper, "CMPLX") or eql(upper, "REAL") or eql(upper, "IMAG") or
        eql(upper, "CONJ") or eql(upper, "ABSZ") or eql(upper, "ARG") or eql(upper, "POLAR") or
        eql(upper, "SPLIT") or eql(upper, "JOIN") or eql(upper, "REPLACE") or
        eql(upper, "STARTSWITH") or eql(upper, "ENDSWITH") or
        eql(upper, "FORMAT") or eql(upper, "TYPEOF") or
        eql(upper, "LINE"))
    {
        return true;
    }

    return false;
}

// ============================================================================
// Helper functions
// ============================================================================

pub const WordResult = struct {
    word: []const u8,
    next_pos: usize,
};

/// Extract a word from line starting at `pos`, uppercase it into `buf`.
/// Returns the uppercased word (slice of buf) and the position after the word.
pub fn extractUpperWord(line: []const u32, start: usize, buf: *[32]u8) WordResult {
    var pos = skipWhitespace(line, start);
    if (pos >= line.len or !isIdentStart(line[pos])) {
        return .{ .word = buf[0..0], .next_pos = pos };
    }

    var len: usize = 0;
    while (pos < line.len and isIdentChar(line[pos]) and len < buf.len) {
        const cp = line[pos];
        if (cp >= 'a' and cp <= 'z') {
            buf[len] = @intCast(cp - 32);
        } else if (cp < 128) {
            buf[len] = @intCast(cp);
        } else {
            break;
        }
        len += 1;
        pos += 1;
    }

    return .{ .word = buf[0..len], .next_pos = pos };
}

/// Convert a codepoint slice to uppercase ASCII into buf, return the slice.
pub fn toUpperSlice(cps: []const u32, buf: *[64]u8) []const u8 {
    var len: usize = 0;
    for (cps) |cp| {
        if (len >= buf.len) break;
        if (cp >= 'a' and cp <= 'z') {
            buf[len] = @intCast(cp - 32);
        } else if (cp < 128) {
            buf[len] = @intCast(cp);
        } else {
            buf[len] = '?';
        }
        len += 1;
    }
    return buf[0..len];
}

pub fn stripLeading(line: []const u32) []const u32 {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    return line[i..];
}

pub fn stripTrailing(line: []const u32) []const u32 {
    var end: usize = line.len;
    while (end > 0 and (line[end - 1] == ' ' or line[end - 1] == '\t' or line[end - 1] == '\r')) {
        end -= 1;
    }
    return line[0..end];
}

pub fn skipWhitespace(line: []const u32, start: usize) usize {
    var i = start;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    return i;
}

pub fn isIdentStart(cp: u32) bool {
    return (cp >= 'A' and cp <= 'Z') or (cp >= 'a' and cp <= 'z') or cp == '_';
}

pub fn isIdentChar(cp: u32) bool {
    return isIdentStart(cp) or (cp >= '0' and cp <= '9');
}

pub fn isTypeSuffix(cp: u32) bool {
    return cp == '$' or cp == '%' or cp == '!' or cp == '#' or cp == '&';
}

pub fn isLineEnd(line: []const u32, pos: usize) bool {
    const p = skipWhitespace(line, pos);
    return p >= line.len;
}

pub fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Check if line starts with REM (case-insensitive).
pub fn startsWithRem(line: []const u32) bool {
    if (line.len < 3) return false;
    const r = line[0];
    const e = line[1];
    const m = line[2];
    if (!((r == 'R' or r == 'r') and (e == 'E' or e == 'e') and (m == 'M' or m == 'm')))
        return false;
    // Must be followed by space, tab, or end of line
    if (line.len == 3) return true;
    return line[3] == ' ' or line[3] == '\t';
}

/// Check if a line is a label (identifier followed by colon, not a keyword line).
pub fn isLabelLine(line: []const u32) bool {
    if (line.len == 0) return false;
    if (!isIdentStart(line[0])) return false;

    var i: usize = 0;
    while (i < line.len and isIdentChar(line[i])) : (i += 1) {}

    if (i >= line.len) return false;
    if (line[i] != ':') return false;

    // Everything after the colon should be whitespace or comment
    const rest = skipWhitespace(line, i + 1);
    if (rest >= line.len) return true;
    if (line[rest] == '\'') return true;

    // Check if the word before the colon is a keyword — if so, not a label
    var ubuf: [64]u8 = undefined;
    const upper = toUpperSlice(line[0..i], &ubuf);
    if (isKeyword(upper)) return false;

    return false; // has content after colon — probably not a simple label
}

/// Determine if an IF line is a single-line IF (has executable content after THEN).
pub fn isSingleLineIf(line: []const u32, start: usize) bool {
    // Scan forward looking for THEN keyword
    var pos = start;
    while (pos < line.len) {
        const cp = line[pos];

        // Skip string literals
        if (cp == '"') {
            pos += 1;
            while (pos < line.len and line[pos] != '"') : (pos += 1) {}
            if (pos < line.len) pos += 1;
            continue;
        }

        // Check for THEN keyword
        if (isIdentStart(cp)) {
            const word_start = pos;
            while (pos < line.len and isIdentChar(line[pos])) : (pos += 1) {}
            var ubuf: [64]u8 = undefined;
            const upper = toUpperSlice(line[word_start..pos], &ubuf);
            if (eql(upper, "THEN")) {
                // Found THEN — check if there's content after it
                const after = skipWhitespace(line, pos);
                if (after >= line.len) return false; // nothing after THEN → multi-line
                if (line[after] == '\'') return false; // only a comment after THEN → multi-line
                return true; // content after THEN → single-line IF
            }
            continue;
        }

        pos += 1;
    }

    // No THEN found — treat as multi-line IF (implicit THEN)
    return false;
}

/// Check if a line ends with a specific keyword (ignoring trailing whitespace/comments).
pub fn lineEndsWithKeyword(line: []const u32, keyword: []const u8) bool {
    // Work backwards from end of line, skipping trailing whitespace
    var end = line.len;
    while (end > 0 and (line[end - 1] == ' ' or line[end - 1] == '\t')) {
        end -= 1;
    }
    if (end == 0) return false;

    // Scan forward through the line, tracking the last keyword found
    var pos: usize = 0;
    var last_kw_match = false;
    var last_kw_end: usize = 0;

    while (pos < end) {
        const cp = line[pos];

        // Skip string literals
        if (cp == '"') {
            pos += 1;
            while (pos < end and line[pos] != '"') : (pos += 1) {}
            if (pos < end) pos += 1;
            last_kw_match = false;
            continue;
        }

        // Skip comments — if we hit a comment, check the last keyword
        if (cp == '\'') break;

        if (isIdentStart(cp)) {
            const word_start = pos;
            while (pos < end and isIdentChar(line[pos])) : (pos += 1) {}
            var ubuf: [64]u8 = undefined;
            const upper = toUpperSlice(line[word_start..pos], &ubuf);
            last_kw_match = eql(upper, keyword);
            last_kw_end = pos;
            continue;
        }

        last_kw_match = false;
        pos += 1;
    }

    // The last keyword must end at (or near) the end of significant content
    if (last_kw_match) {
        const after = skipWhitespace(line, last_kw_end);
        return after >= end or line[after] == '\'';
    }
    return false;
}

// ============================================================================
// Tests
// ============================================================================

pub fn toU32(comptime s: []const u8) [s.len]u32 {
    var result: [s.len]u32 = undefined;
    for (s, 0..) |c, i| {
        result[i] = c;
    }
    return result;
}

test "stripLeading removes spaces and tabs" {
    const input = toU32("   hello");
    const result = stripLeading(&input);
    try std.testing.expectEqual(@as(usize, 5), result.len);
    try std.testing.expectEqual(@as(u32, 'h'), result[0]);
}

test "stripTrailing removes trailing spaces" {
    const input = toU32("hello   ");
    const result = stripTrailing(&input);
    try std.testing.expectEqual(@as(usize, 5), result.len);
}

test "isSingleLineIf detects single-line IF" {
    const line1 = toU32("x > 0 THEN PRINT x");
    try std.testing.expect(isSingleLineIf(&line1, 0));

    const line2 = toU32("x > 0 THEN");
    try std.testing.expect(!isSingleLineIf(&line2, 0));

    const line3 = toU32("x > 0 THEN ' comment");
    try std.testing.expect(!isSingleLineIf(&line3, 0));
}

test "lineEndsWithKeyword finds THEN at end" {
    const line1 = toU32("IF x > 0 THEN");
    try std.testing.expect(lineEndsWithKeyword(&line1, "THEN"));

    const line2 = toU32("IF x > 0 THEN   ");
    try std.testing.expect(lineEndsWithKeyword(&line2, "THEN"));

    const line3 = toU32("IF x > 0 THEN PRINT x");
    try std.testing.expect(!lineEndsWithKeyword(&line3, "THEN"));
}

test "classifyLine detects block openers" {
    const for_line = toU32("FOR i = 1 TO 10");
    const for_info = classifyLine(&for_line);
    try std.testing.expectEqual(@as(u8, 0), for_info.dedent_before);
    try std.testing.expectEqual(@as(u8, 1), for_info.indent_after);

    const while_line = toU32("WHILE x > 0");
    const while_info = classifyLine(&while_line);
    try std.testing.expectEqual(@as(u8, 1), while_info.indent_after);
}

test "classifyLine detects block closers" {
    const next_line = toU32("NEXT");
    const next_info = classifyLine(&next_line);
    try std.testing.expectEqual(@as(u8, 1), next_info.dedent_before);
    try std.testing.expectEqual(@as(u8, 0), next_info.indent_after);

    const endif_line = toU32("END IF");
    const endif_info = classifyLine(&endif_line);
    try std.testing.expectEqual(@as(u8, 1), endif_info.dedent_before);
}

test "classifyLine detects hinge keywords" {
    const else_line = toU32("ELSE");
    const else_info = classifyLine(&else_line);
    try std.testing.expectEqual(@as(u8, 1), else_info.dedent_before);
    try std.testing.expectEqual(@as(u8, 1), else_info.indent_after);

    const case_line = toU32("CASE 1");
    const case_info = classifyLine(&case_line);
    try std.testing.expectEqual(@as(u8, 1), case_info.dedent_before);
    try std.testing.expectEqual(@as(u8, 1), case_info.indent_after);
}

test "classifyLine single-line IF no indent change" {
    const line = toU32("IF x > 0 THEN PRINT x");
    const info = classifyLine(&line);
    try std.testing.expectEqual(@as(u8, 0), info.dedent_before);
    try std.testing.expectEqual(@as(u8, 0), info.indent_after);
}

test "classifyLine multi-line IF indents" {
    const line = toU32("IF x > 0 THEN");
    const info = classifyLine(&line);
    try std.testing.expectEqual(@as(u8, 0), info.dedent_before);
    try std.testing.expectEqual(@as(u8, 1), info.indent_after);
}

test "isKeyword recognizes common keywords" {
    try std.testing.expect(isKeyword("PRINT"));
    try std.testing.expect(isKeyword("IF"));
    try std.testing.expect(isKeyword("FOR"));
    try std.testing.expect(isKeyword("DIM"));
    try std.testing.expect(!isKeyword("myVar"));
    try std.testing.expect(!isKeyword("hello"));
}

test "formatBasic simple indent" {
    const allocator = std.testing.allocator;

    const src = toU32("for i = 1 to 10\nprint i\nnext");
    const result = try formatBasic(allocator, &src);
    defer allocator.free(result);

    // Expected: FOR indented at 0, PRINT at 2, NEXT at 0
    // "FOR i = 1 TO 10\n  PRINT i\nNEXT"
    try std.testing.expectEqual(@as(u32, 'F'), result[0]);
    try std.testing.expectEqual(@as(u32, '\n'), result[15]);
    // Line 2 should start with 2 spaces
    try std.testing.expectEqual(@as(u32, ' '), result[16]);
    try std.testing.expectEqual(@as(u32, ' '), result[17]);
    try std.testing.expectEqual(@as(u32, 'P'), result[18]);
}

test "formatBasic line-numbered IF/ELSE/END IF" {
    const allocator = std.testing.allocator;

    const src = toU32("1360 IF dist = 8 THEN\n1370 PRINT \"pass\"\n1380 ELSE\n1390 PRINT \"fail\"\n1400 END IF");
    const result = try formatBasic(allocator, &src);
    defer allocator.free(result);

    // Line numbers should never be indented; indentation goes AFTER the line number.
    // Expected output:
    //   "1360 IF dist = 8 THEN\n1370   PRINT \"pass\"\n1380 ELSE\n1390   PRINT \"fail\"\n1400 END IF"
    //
    // Verify each line starts with its line number (no leading spaces).
    var lines_list: [8][]const u32 = undefined;
    var line_count: usize = 0;
    var line_start: usize = 0;
    for (result, 0..) |cp, i| {
        if (cp == '\n') {
            if (line_count < lines_list.len) {
                lines_list[line_count] = result[line_start..i];
                line_count += 1;
            }
            line_start = i + 1;
        }
    }
    if (line_start <= result.len and line_count < lines_list.len) {
        lines_list[line_count] = result[line_start..result.len];
        line_count += 1;
    }

    // Every line must start with a digit (the line number), never a space
    for (0..line_count) |li| {
        const line = lines_list[li];
        try std.testing.expect(line.len > 0);
        try std.testing.expect(line[0] >= '0' and line[0] <= '9');
    }

    // "1370   PRINT ..." — after "1370 " there should be 2 indent spaces
    // Line 1: "1370 " = 5 chars, then 2 spaces indent, then PRINT
    const l1 = lines_list[1];
    // Skip digits
    var pos: usize = 0;
    while (pos < l1.len and l1[pos] >= '0' and l1[pos] <= '9') : (pos += 1) {}
    // Skip the single separator space
    try std.testing.expectEqual(@as(u32, ' '), l1[pos]);
    pos += 1;
    // Count indent spaces
    var indent_spaces: usize = 0;
    while (pos < l1.len and l1[pos] == ' ') : (pos += 1) {
        indent_spaces += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), indent_spaces);
}

test "formatBasic line-numbered FOR/NEXT" {
    const allocator = std.testing.allocator;

    const src = toU32("100 FOR i = 1 TO 10\n110 PRINT i\n120 NEXT");
    const result = try formatBasic(allocator, &src);
    defer allocator.free(result);

    // Expected: "100 FOR i = 1 TO 10\n110   PRINT i\n120 NEXT"
    // Line numbers never indented; indent goes after line number.
    var lines_list: [4][]const u32 = undefined;
    var line_count: usize = 0;
    var line_start: usize = 0;
    for (result, 0..) |cp, i| {
        if (cp == '\n') {
            if (line_count < lines_list.len) {
                lines_list[line_count] = result[line_start..i];
                line_count += 1;
            }
            line_start = i + 1;
        }
    }
    if (line_start <= result.len and line_count < lines_list.len) {
        lines_list[line_count] = result[line_start..result.len];
        line_count += 1;
    }

    // Every line starts with its line number (digit), not a space
    for (0..line_count) |li| {
        const line = lines_list[li];
        try std.testing.expect(line.len > 0);
        try std.testing.expect(line[0] >= '0' and line[0] <= '9');
    }

    // "110   PRINT i" — after "110 " there should be 2 indent spaces
    const l1 = lines_list[1];
    var pos: usize = 0;
    while (pos < l1.len and l1[pos] >= '0' and l1[pos] <= '9') : (pos += 1) {}
    // Skip separator space
    try std.testing.expectEqual(@as(u32, ' '), l1[pos]);
    pos += 1;
    // Count indent spaces
    var indent_spaces: usize = 0;
    while (pos < l1.len and l1[pos] == ' ') : (pos += 1) {
        indent_spaces += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), indent_spaces);

    // "120 NEXT" — no indent after line number (just "120 NEXT")
    const l2 = lines_list[2];
    pos = 0;
    while (pos < l2.len and l2[pos] >= '0' and l2[pos] <= '9') : (pos += 1) {}
    try std.testing.expectEqual(@as(u32, ' '), l2[pos]);
    pos += 1;
    // Should be 'N' immediately (no indent spaces)
    try std.testing.expectEqual(@as(u32, 'N'), l2[pos]);
}

test "formatBasic preserves strings" {
    const allocator = std.testing.allocator;

    const src = toU32("print \"hello world\"");
    const result = try formatBasic(allocator, &src);
    defer allocator.free(result);

    // Should contain the string verbatim
    var found = false;
    for (0..result.len - 5) |i| {
        if (result[i] == 'h' and result[i + 1] == 'e' and result[i + 2] == 'l') {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "formatBasic preserves triple-quoted blocks" {
    const allocator = std.testing.allocator;

    const src = toU32(
        "LET K$=\"\"\"\n" ++
            "  This IS a STRING\n\n\n" ++
            "\"\"\"\n" ++
            "PRINT K$",
    );
    const result = try formatBasic(allocator, &src);
    defer allocator.free(result);

    // Expect header formatted, but inner triple content untouched (keeps IS/STRING case)
    const expected = toU32(
        "LET K$=\"\"\"\n" ++
            "  This IS a STRING\n\n\n" ++
            "\"\"\"\n" ++
            "PRINT K$",
    );
    try std.testing.expectEqualSlices(u32, &expected, result);
}

test "formatBasic nested blocks" {
    const allocator = std.testing.allocator;

    const src = toU32("sub test\nfor i = 1 to 10\nprint i\nnext\nend sub");
    const result = try formatBasic(allocator, &src);
    defer allocator.free(result);

    // Count leading spaces on each line
    var line_num: usize = 0;
    var line_start: usize = 0;
    for (result, 0..) |cp, i| {
        if (cp == '\n' or i == result.len - 1) {
            const line_end = if (cp == '\n') i else i + 1;
            var spaces: usize = 0;
            var j = line_start;
            while (j < line_end and result[j] == ' ') : (j += 1) {
                spaces += 1;
            }
            switch (line_num) {
                0 => try std.testing.expectEqual(@as(usize, 0), spaces), // SUB test
                1 => try std.testing.expectEqual(@as(usize, 2), spaces), // FOR
                2 => try std.testing.expectEqual(@as(usize, 4), spaces), // PRINT
                3 => try std.testing.expectEqual(@as(usize, 2), spaces), // NEXT
                4 => try std.testing.expectEqual(@as(usize, 0), spaces), // END SUB
                else => {},
            }
            line_num += 1;
            line_start = i + 1;
        }
    }
}

test "formatBasic FOR/NEXT outdent" {
    const allocator = std.testing.allocator;

    // FOR/NEXT should indent body and outdent at NEXT
    const src = toU32("print \"before\"\nfor i = 1 to 10\nprint i\nnext\nprint \"after\"");
    const result = try formatBasic(allocator, &src);
    defer allocator.free(result);

    // Collect leading spaces per line
    var line_num: usize = 0;
    var line_start: usize = 0;
    var spaces_per_line: [8]usize = .{99} ** 8;
    for (result, 0..) |cp, i| {
        if (cp == '\n' or i == result.len - 1) {
            const line_end = if (cp == '\n') i else i + 1;
            var spaces: usize = 0;
            var j = line_start;
            while (j < line_end and result[j] == ' ') : (j += 1) {
                spaces += 1;
            }
            if (line_num < spaces_per_line.len) {
                spaces_per_line[line_num] = spaces;
            }
            line_num += 1;
            line_start = i + 1;
        }
    }

    // PRINT "before"  → 0 spaces
    try std.testing.expectEqual(@as(usize, 0), spaces_per_line[0]);
    // FOR i = 1 TO 10 → 0 spaces
    try std.testing.expectEqual(@as(usize, 0), spaces_per_line[1]);
    // PRINT i         → 2 spaces (indented inside FOR)
    try std.testing.expectEqual(@as(usize, 2), spaces_per_line[2]);
    // NEXT            → 0 spaces (outdented)
    try std.testing.expectEqual(@as(usize, 0), spaces_per_line[3]);
    // PRINT "after"   → 0 spaces (back to base)
    try std.testing.expectEqual(@as(usize, 0), spaces_per_line[4]);
}

test "formatBasic NEXT with variable outdents" {
    const allocator = std.testing.allocator;

    const src = toU32("for i = 1 to 10\nprint i\nnext i");
    const result = try formatBasic(allocator, &src);
    defer allocator.free(result);

    var line_num: usize = 0;
    var line_start: usize = 0;
    var spaces_per_line: [4]usize = .{99} ** 4;
    for (result, 0..) |cp, i| {
        if (cp == '\n' or i == result.len - 1) {
            const line_end = if (cp == '\n') i else i + 1;
            var spaces: usize = 0;
            var j = line_start;
            while (j < line_end and result[j] == ' ') : (j += 1) {
                spaces += 1;
            }
            if (line_num < spaces_per_line.len) {
                spaces_per_line[line_num] = spaces;
            }
            line_num += 1;
            line_start = i + 1;
        }
    }

    // FOR  → 0
    try std.testing.expectEqual(@as(usize, 0), spaces_per_line[0]);
    // PRINT → 2
    try std.testing.expectEqual(@as(usize, 2), spaces_per_line[1]);
    // NEXT I → 0
    try std.testing.expectEqual(@as(usize, 0), spaces_per_line[2]);
}

test "formatBasic nested FOR loops" {
    const allocator = std.testing.allocator;

    const src = toU32("for i = 1 to 10\nfor j = 1 to 5\nprint i, j\nnext j\nnext i");
    const result = try formatBasic(allocator, &src);
    defer allocator.free(result);

    var line_num: usize = 0;
    var line_start: usize = 0;
    var spaces_per_line: [8]usize = .{99} ** 8;
    for (result, 0..) |cp, i| {
        if (cp == '\n' or i == result.len - 1) {
            const line_end = if (cp == '\n') i else i + 1;
            var spaces: usize = 0;
            var j = line_start;
            while (j < line_end and result[j] == ' ') : (j += 1) {
                spaces += 1;
            }
            if (line_num < spaces_per_line.len) {
                spaces_per_line[line_num] = spaces;
            }
            line_num += 1;
            line_start = i + 1;
        }
    }

    // FOR i       → 0
    try std.testing.expectEqual(@as(usize, 0), spaces_per_line[0]);
    // FOR j       → 2
    try std.testing.expectEqual(@as(usize, 2), spaces_per_line[1]);
    // PRINT i, j  → 4
    try std.testing.expectEqual(@as(usize, 4), spaces_per_line[2]);
    // NEXT j      → 2
    try std.testing.expectEqual(@as(usize, 2), spaces_per_line[3]);
    // NEXT i      → 0
    try std.testing.expectEqual(@as(usize, 0), spaces_per_line[4]);
}
