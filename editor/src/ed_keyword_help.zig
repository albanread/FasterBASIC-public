//! Keyword Help — embeds keywords.yaml at compile time and provides
//! O(1) lookup by keyword name.
//!
//! The YAML is parsed at comptime into a sorted array of entries.
//! At runtime, `lookup()` does a case-insensitive binary search.

const std = @import("std");

// ── Embedded YAML source ────────────────────────────────────────────────────

const yaml_source = @embedFile("keywords.yaml");

// ── Public types ────────────────────────────────────────────────────────────

pub const KeywordHelp = struct {
    name: []const u8,
    category: []const u8,
    desc: []const u8,
    usage: []const u8,
    example: []const u8,
};

// ── Comptime YAML parser ────────────────────────────────────────────────────

const max_entries = 512;

const ParseResult = struct {
    entries: [max_entries]KeywordHelp,
    count: usize,
};

fn comptimeParse() ParseResult {
    @setEvalBranchQuota(1_000_000);
    var result = ParseResult{
        .entries = undefined,
        .count = 0,
    };

    // Zero-init all entries
    for (0..max_entries) |i| {
        result.entries[i] = .{
            .name = "",
            .category = "",
            .desc = "",
            .usage = "",
            .example = "",
        };
    }

    const src = yaml_source;
    var pos: usize = 0;

    var current_name: []const u8 = "";
    var current_category: []const u8 = "";
    var current_desc: []const u8 = "";
    var current_usage_start: usize = 0;
    var current_usage_end: usize = 0;
    var current_example_start: usize = 0;
    var current_example_end: usize = 0;
    var in_usage_block: bool = false;
    var in_example_block: bool = false;
    var in_entry: bool = false;

    while (pos < src.len) {
        const line_start = pos;
        // Find end of line
        while (pos < src.len and src[pos] != '\n') : (pos += 1) {}
        const line_end = pos;
        if (pos < src.len) pos += 1; // skip \n

        const line = src[line_start..line_end];

        // Skip empty lines and pure comment lines at top level
        if (line.len == 0) {
            if (in_usage_block) {
                current_usage_end = line_end;
            } else if (in_example_block) {
                current_example_end = line_end;
            }
            continue;
        }

        // Detect top-level key: non-whitespace at column 0, ends with ':'
        if (line[0] != ' ' and line[0] != '#' and line[0] != '\t') {
            // Flush previous entry
            if (in_entry and current_name.len > 0) {
                if (result.count < max_entries) {
                    result.entries[result.count] = .{
                        .name = current_name,
                        .category = current_category,
                        .desc = current_desc,
                        .usage = trimUsageBlock(src[current_usage_start..current_usage_end]),
                        .example = trimUsageBlock(src[current_example_start..current_example_end]),
                    };
                    result.count += 1;
                }
            }

            // Start new entry
            in_usage_block = false;
            in_example_block = false;
            current_category = "";
            current_desc = "";
            current_usage_start = 0;
            current_usage_end = 0;
            current_example_start = 0;
            current_example_end = 0;

            // Extract name (strip trailing ':')
            var name_end: usize = 0;
            while (name_end < line.len and line[name_end] != ':') : (name_end += 1) {}
            current_name = line[0..name_end];
            in_entry = true;
            continue;
        }

        // Inside an entry — look for fields
        if (line[0] == '#') continue; // comment

        if (in_usage_block) {
            if (line.len >= 4 and (line[0] == ' ' or line[0] == '\t')) {
                current_usage_end = line_end;
                continue;
            } else {
                in_usage_block = false;
            }
        }

        if (in_example_block) {
            if (line.len >= 4 and (line[0] == ' ' or line[0] == '\t')) {
                current_example_end = line_end;
                continue;
            } else {
                in_example_block = false;
            }
        }

        // Strip leading whitespace
        var field_start: usize = 0;
        while (field_start < line.len and (line[field_start] == ' ' or line[field_start] == '\t')) : (field_start += 1) {}
        const trimmed = line[field_start..];

        if (startsWith(trimmed, "category:")) {
            current_category = stripQuotes(trimField(trimmed, "category:".len));
        } else if (startsWith(trimmed, "desc:")) {
            current_desc = stripQuotes(trimField(trimmed, "desc:".len));
        } else if (startsWith(trimmed, "usage:")) {
            in_usage_block = true;
            in_example_block = false;
            current_usage_start = pos;
            current_usage_end = pos;
        } else if (startsWith(trimmed, "example:")) {
            in_example_block = true;
            in_usage_block = false;
            current_example_start = pos;
            current_example_end = pos;
        }
    }

    // Flush last entry
    if (in_entry and current_name.len > 0 and result.count < max_entries) {
        result.entries[result.count] = .{
            .name = current_name,
            .category = current_category,
            .desc = current_desc,
            .usage = trimUsageBlock(src[current_usage_start..current_usage_end]),
            .example = trimUsageBlock(src[current_example_start..current_example_end]),
        };
        result.count += 1;
    }

    // Sort by name (uppercase) for binary search
    sortEntries(&result);

    return result;
}

fn startsWith(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    return std.mem.eql(u8, haystack[0..needle.len], needle);
}

fn trimField(line: []const u8, after: usize) []const u8 {
    var s = after;
    while (s < line.len and (line[s] == ' ' or line[s] == '\t')) : (s += 1) {}
    var e = line.len;
    while (e > s and (line[e - 1] == ' ' or line[e - 1] == '\t' or line[e - 1] == '\r')) : (e -= 1) {}
    return line[s..e];
}

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
        return s[1 .. s.len - 1];
    }
    return s;
}

fn trimUsageBlock(raw: []const u8) []const u8 {
    if (raw.len == 0) return "";
    // Trim trailing whitespace/newlines
    var end = raw.len;
    while (end > 0 and (raw[end - 1] == '\n' or raw[end - 1] == '\r' or raw[end - 1] == ' ')) : (end -= 1) {}
    return raw[0..end];
}

fn asciiUpperChar(c: u8) u8 {
    return if (c >= 'a' and c <= 'z') c - 32 else c;
}

fn compareNames(a: []const u8, b: []const u8) std.math.Order {
    const len = @min(a.len, b.len);
    for (0..len) |i| {
        const ca = asciiUpperChar(a[i]);
        const cb = asciiUpperChar(b[i]);
        if (ca < cb) return .lt;
        if (ca > cb) return .gt;
    }
    if (a.len < b.len) return .lt;
    if (a.len > b.len) return .gt;
    return .eq;
}

fn sortEntries(result: *ParseResult) void {
    // Simple insertion sort (fine for ~300 entries at comptime)
    const n = result.count;
    if (n <= 1) return;
    for (1..n) |i| {
        const key = result.entries[i];
        var j: usize = i;
        while (j > 0 and compareNames(result.entries[j - 1].name, key.name) == .gt) {
            result.entries[j] = result.entries[j - 1];
            j -= 1;
        }
        result.entries[j] = key;
    }
}

// ── Comptime-evaluated data ─────────────────────────────────────────────────

const parsed = comptimeParse();
const entry_count: usize = parsed.count;
const entries: [entry_count]KeywordHelp = parsed.entries[0..entry_count].*;

// ── Public API ──────────────────────────────────────────────────────────────

/// Look up a keyword by name (case-insensitive).
/// Returns the help entry, or null if the name is not a keyword.
pub fn lookup(name: []const u8) ?*const KeywordHelp {
    if (name.len == 0 or name.len > 64) return null;

    // Binary search
    var lo: usize = 0;
    var hi: usize = entry_count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const ord = compareNames(entries[mid].name, name);
        switch (ord) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return &entries[mid],
        }
    }
    return null;
}

/// Look up from a UTF-32 codepoint slice (the editor's internal format).
/// Converts to ASCII uppercase first, then does a binary search.
pub fn lookupCodepoints(cps: []const u32) ?*const KeywordHelp {
    var buf: [128]u8 = undefined;
    if (cps.len == 0 or cps.len > buf.len) return null;
    for (cps, 0..) |cp, i| {
        if (cp > 127) return null; // non-ASCII → not a keyword
        buf[i] = @intCast(cp & 0x7F);
    }
    return lookup(buf[0..cps.len]);
}

/// Returns the total number of keyword help entries.
pub fn count() usize {
    return entry_count;
}

/// Format a keyword help entry for terminal display.
/// Writes into the provided buffer and returns the slice.
pub fn formatHelp(entry: *const KeywordHelp, buf: []u8) []const u8 {
    var pos: usize = 0;

    // Helper to append a string
    const append = struct {
        fn f(b: []u8, p: *usize, s: []const u8) void {
            const n = @min(s.len, b.len - p.*);
            @memcpy(b[p.* .. p.* + n], s[0..n]);
            p.* += n;
        }
    }.f;

    append(buf, &pos, "\r\n  ");
    append(buf, &pos, entry.name);
    append(buf, &pos, "  (");
    append(buf, &pos, entry.category);
    append(buf, &pos, ")\r\n  ");

    // Description
    append(buf, &pos, entry.desc);
    append(buf, &pos, "\r\n");

    // Usage block — indent each line with "    "
    if (entry.usage.len > 0) {
        append(buf, &pos, "\r\n");
        var upos: usize = 0;
        while (upos < entry.usage.len) {
            // Find end of line in usage
            var eol = upos;
            while (eol < entry.usage.len and entry.usage[eol] != '\n') : (eol += 1) {}

            const uline = entry.usage[upos..eol];

            // Strip leading 4 spaces of YAML indentation
            var stripped = uline;
            if (stripped.len >= 4 and std.mem.eql(u8, stripped[0..4], "    ")) {
                stripped = stripped[4..];
            }

            append(buf, &pos, "    ");
            append(buf, &pos, stripped);
            append(buf, &pos, "\r\n");

            upos = if (eol < entry.usage.len) eol + 1 else eol;
        }
    }

    // Example block — indent each line with "    "
    if (entry.example.len > 0) {
        append(buf, &pos, "\r\n  Example:\r\n");
        var epos: usize = 0;
        while (epos < entry.example.len) {
            var eol = epos;
            while (eol < entry.example.len and entry.example[eol] != '\n') : (eol += 1) {}

            const eline = entry.example[epos..eol];

            // Strip leading 4 spaces of YAML indentation
            var stripped = eline;
            if (stripped.len >= 4 and std.mem.eql(u8, stripped[0..4], "    ")) {
                stripped = stripped[4..];
            }

            append(buf, &pos, "    ");
            append(buf, &pos, stripped);
            append(buf, &pos, "\r\n");

            epos = if (eol < entry.example.len) eol + 1 else eol;
        }
    }

    append(buf, &pos, "\r\n");
    return buf[0..pos];
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "keyword help entries are parsed" {
    try std.testing.expect(entry_count > 100);
}

test "lookup finds PRINT" {
    const result = lookup("PRINT");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("PRINT", result.?.name);
    try std.testing.expect(result.?.desc.len > 0);
    try std.testing.expect(result.?.usage.len > 0);
}

test "lookup is case-insensitive" {
    const r1 = lookup("print");
    const r2 = lookup("Print");
    const r3 = lookup("PRINT");
    try std.testing.expect(r1 != null);
    try std.testing.expect(r2 != null);
    try std.testing.expect(r3 != null);
    try std.testing.expectEqualStrings(r1.?.name, r3.?.name);
    try std.testing.expectEqualStrings(r2.?.name, r3.?.name);
}

test "lookup finds WORKER" {
    const result = lookup("WORKER");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("worker", result.?.category);
}

test "lookup finds FOR" {
    const result = lookup("FOR");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("control_flow", result.?.category);
}

test "lookup returns null for non-keyword" {
    const result = lookup("MyVariable");
    try std.testing.expect(result == null);
}

test "lookupCodepoints works" {
    const cps = [_]u32{ 'D', 'I', 'M' };
    const result = lookupCodepoints(&cps);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("DIM", result.?.name);
}

test "formatHelp produces output" {
    const entry = lookup("IF") orelse unreachable;
    var buf: [4096]u8 = undefined;
    const output = formatHelp(entry, &buf);
    try std.testing.expect(output.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, output, "IF") != null);
}

test "entries are sorted" {
    if (entry_count < 2) return;
    for (1..entry_count) |i| {
        const ord = compareNames(entries[i - 1].name, entries[i].name);
        try std.testing.expect(ord != .gt);
    }
}
