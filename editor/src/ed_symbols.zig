// ============================================================================
// ed_symbols.zig — Lightweight FasterBASIC Symbol Scanner
// ============================================================================
//
// Scans a UTF-32 code point buffer for declaration patterns and builds a
// symbol index.  This is intentionally a fast, standalone scanner — it does
// NOT invoke the full compiler pipeline.  It runs synchronously on the main
// thread and targets <1ms for 250K-line files (we only inspect the first
// few tokens of each line).
//
// Recognised patterns:
//   SUB name(params)
//   FUNCTION name(params) [AS type]
//   WORKER name(params)
//   TYPE name
//   CLASS name [EXTENDS base]
//   CONSTANT name = value
//   DEF FN name(params)
//   label:                          (identifier followed by colon at line start)
//   CONSTRUCTOR(params)
//   DESTRUCTOR()
//   METHOD name(params) [AS type]
//
// The index supports:
//   - Lookup by name       → go-to-definition (F12)
//   - Sorted symbol list   → outline navigation (Ctrl+O)
//   - Prefix matching      → autocomplete (Ctrl+Space)
//   - All-keywords list    → autocomplete keyword source
//
// ============================================================================

const std = @import("std");
const Allocator = std.mem.Allocator;

// ── Public types ────────────────────────────────────────────────────────────

pub const SymbolKind = enum(u8) {
    function,
    sub,
    worker,
    type_decl,
    class_decl,
    constant,
    label,
    constructor,
    destructor,
    method,
};

pub const MAX_NAME: usize = 128;
pub const MAX_PARAMS: usize = 256;

pub const SymbolEntry = struct {
    /// Symbol name (ASCII uppercased for matching, original case preserved in name_orig).
    name_upper: [MAX_NAME]u8 = undefined,
    /// Original-case name for display.
    name_orig: [MAX_NAME]u8 = undefined,
    name_len: u8 = 0,

    kind: SymbolKind = .sub,

    /// 0-based line number where the declaration appears.
    line: u32 = 0,
    /// 0-based column of the name token.
    col: u16 = 0,

    /// Parameter signature as text, e.g. "x AS INTEGER, y AS DOUBLE".
    /// Empty for types, constants, labels.
    params: [MAX_PARAMS]u8 = undefined,
    params_len: u16 = 0,

    /// Return type for FUNCTIONs, base class for CLASSes, value for CONSTANTs.
    extra: [MAX_NAME]u8 = undefined,
    extra_len: u8 = 0,

    /// For TYPE/CLASS: the owning class/type name (empty for top-level symbols).
    owner: [MAX_NAME]u8 = undefined,
    owner_len: u8 = 0,

    pub fn getName(self: *const SymbolEntry) []const u8 {
        return self.name_orig[0..self.name_len];
    }

    pub fn getNameUpper(self: *const SymbolEntry) []const u8 {
        return self.name_upper[0..self.name_len];
    }

    pub fn getParams(self: *const SymbolEntry) []const u8 {
        return self.params[0..self.params_len];
    }

    pub fn getExtra(self: *const SymbolEntry) []const u8 {
        return self.extra[0..self.extra_len];
    }

    pub fn getOwner(self: *const SymbolEntry) []const u8 {
        return self.owner[0..self.owner_len];
    }

    /// Format a one-line display string:  "FUNCTION name(params) AS type"
    pub fn formatDisplay(self: *const SymbolEntry, buf: *[512]u8) []const u8 {
        var pos: usize = 0;

        // Kind prefix
        const prefix = switch (self.kind) {
            .function => "FUNCTION ",
            .sub => "SUB ",
            .worker => "WORKER ",
            .type_decl => "TYPE ",
            .class_decl => "CLASS ",
            .constant => "CONSTANT ",
            .label => "",
            .constructor => "CONSTRUCTOR",
            .destructor => "DESTRUCTOR",
            .method => "METHOD ",
        };
        const plen = @min(prefix.len, buf.len - pos);
        @memcpy(buf[pos .. pos + plen], prefix[0..plen]);
        pos += plen;

        // Name
        const nlen = @min(self.name_len, buf.len - pos);
        @memcpy(buf[pos .. pos + nlen], self.name_orig[0..nlen]);
        pos += nlen;

        // Params
        if (self.params_len > 0) {
            if (pos < buf.len) {
                buf[pos] = '(';
                pos += 1;
            }
            const prlen = @min(self.params_len, buf.len - pos);
            @memcpy(buf[pos .. pos + prlen], self.params[0..prlen]);
            pos += prlen;
            if (pos < buf.len) {
                buf[pos] = ')';
                pos += 1;
            }
        }

        // Extra (return type, EXTENDS, value)
        if (self.extra_len > 0) {
            const sep: []const u8 = switch (self.kind) {
                .function, .method => " AS ",
                .class_decl => " EXTENDS ",
                .constant => " = ",
                else => " ",
            };
            const slen = @min(sep.len, buf.len - pos);
            @memcpy(buf[pos .. pos + slen], sep[0..slen]);
            pos += slen;

            const elen = @min(self.extra_len, buf.len - pos);
            @memcpy(buf[pos .. pos + elen], self.extra[0..elen]);
            pos += elen;
        }

        // Label colon
        if (self.kind == .label and pos < buf.len) {
            buf[pos] = ':';
            pos += 1;
        }

        return buf[0..pos];
    }
};

/// A field declaration inside a TYPE or CLASS body.
pub const TypeFieldEntry = struct {
    /// Owning TYPE/CLASS name (uppercased).
    type_name_upper: [MAX_NAME]u8 = undefined,
    type_name_len: u8 = 0,
    /// Field name (uppercased for matching).
    field_name_upper: [MAX_NAME]u8 = undefined,
    /// Original-case field name for display / insertion.
    field_name_orig: [MAX_NAME]u8 = undefined,
    field_name_len: u8 = 0,
    /// Declared type of the field (e.g. "INTEGER", "STRING", "Vector2D"), uppercased.
    field_type: [MAX_NAME]u8 = undefined,
    field_type_len: u8 = 0,
    /// For LIST/HASHMAP fields: element/value type after OF (uppercased).
    element_type: [MAX_NAME]u8 = undefined,
    element_type_len: u8 = 0,

    pub fn getFieldName(self: *const TypeFieldEntry) []const u8 {
        return self.field_name_orig[0..self.field_name_len];
    }

    pub fn getFieldNameUpper(self: *const TypeFieldEntry) []const u8 {
        return self.field_name_upper[0..self.field_name_len];
    }

    pub fn getFieldType(self: *const TypeFieldEntry) []const u8 {
        return self.field_type[0..self.field_type_len];
    }

    pub fn getTypeName(self: *const TypeFieldEntry) []const u8 {
        return self.type_name_upper[0..self.type_name_len];
    }

    pub fn getElementType(self: *const TypeFieldEntry) []const u8 {
        return self.element_type[0..self.element_type_len];
    }
};

/// Maps a variable name to its declared type (from DIM/LOCAL ... AS TypeName).
pub const VarTypeEntry = struct {
    /// Variable name (uppercased for matching).
    var_name_upper: [MAX_NAME]u8 = undefined,
    var_name_len: u8 = 0,
    /// The declared type name (uppercased), e.g. "HASHMAP", "LIST", "VECTOR2D".
    type_name_upper: [MAX_NAME]u8 = undefined,
    type_name_len: u8 = 0,
    /// For LIST/HASHMAP: the element/value type declared after OF (uppercased).
    element_type_upper: [MAX_NAME]u8 = undefined,
    element_type_len: u8 = 0,
    /// Optional scope name (SUB/FUNCTION/METHOD name, uppercased) — empty means module-level.
    scope_name_upper: [MAX_NAME]u8 = undefined,
    scope_name_len: u8 = 0,
    /// 0-based line of the declaration.
    line: u32 = 0,

    pub fn getVarName(self: *const VarTypeEntry) []const u8 {
        return self.var_name_upper[0..self.var_name_len];
    }

    pub fn getTypeName(self: *const VarTypeEntry) []const u8 {
        return self.type_name_upper[0..self.type_name_len];
    }

    pub fn getElementType(self: *const VarTypeEntry) []const u8 {
        return self.element_type_upper[0..self.element_type_len];
    }

    pub fn getScopeName(self: *const VarTypeEntry) []const u8 {
        return self.scope_name_upper[0..self.scope_name_len];
    }
};

/// Fixed method lists for built-in collection types.
pub const HASHMAP_METHODS = [_][]const u8{
    "CLEAR",
    "GET",
    "HASKEY",
    "KEYS",
    "REMOVE",
    "SET",
    "SIZE",
};

pub const LIST_METHODS = [_][]const u8{
    "APPEND",
    "CLEAR",
    "CONTAINS",
    "COPY",
    "EMPTY",
    "EXTEND",
    "GET",
    "HEAD",
    "INDEXOF",
    "INSERT",
    "JOIN",
    "LENGTH",
    "POP",
    "PREPEND",
    "REMOVE",
    "REST",
    "REVERSE",
    "SHIFT",
    "SIZE",
    "SORT",
    "SORTED",
    "TAIL",
};

/// Built-in type names available after AS (sorted for binary search / consistent display).
pub const BUILTIN_TYPES = [_][]const u8{
    "BYTE",
    "COMPLEX",
    "DOUBLE",
    "HASHMAP",
    "INTEGER",
    "LIST",
    "LONG",
    "SHORT",
    "SINGLE",
    "STRING",
    "UBYTE",
    "UINTEGER",
    "ULONG",
    "USHORT",
};

/// The kind of scope the scanner is currently inside (for field detection).
pub const ScopeKind = enum(u8) {
    none,
    type_decl,
    class_decl,
    method_body,
};

/// Warning emitted when a variable declaration shadows a language keyword.
pub const KeywordShadowWarning = struct {
    /// 0-based line index.
    line: u32 = 0,
    /// 0-based column of the offending variable name.
    col: u16 = 0,
    /// The keyword name that is being shadowed (uppercased).
    name_buf: [MAX_NAME]u8 = undefined,
    name_len: u8 = 0,
    /// The declaration keyword that introduced it (e.g. "LET", "DIM").
    decl_buf: [8]u8 = undefined,
    decl_len: u8 = 0,

    pub fn getName(self: *const KeywordShadowWarning) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn getDecl(self: *const KeywordShadowWarning) []const u8 {
        return self.decl_buf[0..self.decl_len];
    }

    /// Format a human-readable warning message into the supplied buffer.
    pub fn formatMessage(self: *const KeywordShadowWarning, buf: *[256]u8) []const u8 {
        var pos: usize = 0;
        const prefix = "Variable '";
        @memcpy(buf[pos .. pos + prefix.len], prefix);
        pos += prefix.len;
        const nlen = @min(self.name_len, buf.len - pos);
        @memcpy(buf[pos .. pos + nlen], self.name_buf[0..nlen]);
        pos += nlen;
        const mid = "' shadows keyword ";
        const mlen = @min(mid.len, buf.len - pos);
        @memcpy(buf[pos .. pos + mlen], mid[0..mlen]);
        pos += mlen;
        const nlen2 = @min(self.name_len, buf.len - pos);
        @memcpy(buf[pos .. pos + nlen2], self.name_buf[0..nlen2]);
        pos += nlen2;
        return buf[0..pos];
    }
};

/// The symbol index — a flat, sorted list of symbols extracted from the buffer.
pub const SymbolIndex = struct {
    entries: std.ArrayListUnmanaged(SymbolEntry),
    /// Sorted indices into `entries` by name (for binary search).
    sorted_by_name: std.ArrayListUnmanaged(u32),
    /// Sorted indices into `entries` by line number (for outline display).
    sorted_by_line: std.ArrayListUnmanaged(u32),
    /// Warnings about variable declarations that shadow keywords.
    warnings: std.ArrayListUnmanaged(KeywordShadowWarning),
    /// Fields belonging to TYPE / CLASS declarations (for dot-autocomplete).
    type_fields: std.ArrayListUnmanaged(TypeFieldEntry),
    /// Variable → type mappings from DIM/LOCAL ... AS declarations.
    var_types: std.ArrayListUnmanaged(VarTypeEntry),

    allocator: Allocator,

    pub fn init(allocator: Allocator) SymbolIndex {
        return .{
            .entries = .{},
            .sorted_by_name = .{},
            .sorted_by_line = .{},
            .warnings = .{},
            .type_fields = .{},
            .var_types = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SymbolIndex) void {
        self.entries.deinit(self.allocator);
        self.sorted_by_name.deinit(self.allocator);
        self.sorted_by_line.deinit(self.allocator);
        self.warnings.deinit(self.allocator);
        self.type_fields.deinit(self.allocator);
        self.var_types.deinit(self.allocator);
    }

    pub fn clear(self: *SymbolIndex) void {
        self.entries.clearRetainingCapacity();
        self.sorted_by_name.clearRetainingCapacity();
        self.sorted_by_line.clearRetainingCapacity();
        self.warnings.clearRetainingCapacity();
        self.type_fields.clearRetainingCapacity();
        self.var_types.clearRetainingCapacity();
    }

    pub fn count(self: *const SymbolIndex) usize {
        return self.entries.items.len;
    }

    /// Get the Nth entry in line order.
    pub fn byLine(self: *const SymbolIndex, idx: usize) ?*const SymbolEntry {
        if (idx >= self.sorted_by_line.items.len) return null;
        const entry_idx = self.sorted_by_line.items[idx];
        return &self.entries.items[entry_idx];
    }

    /// Get the Nth entry in name order.
    pub fn byName(self: *const SymbolIndex, idx: usize) ?*const SymbolEntry {
        if (idx >= self.sorted_by_name.items.len) return null;
        const entry_idx = self.sorted_by_name.items[idx];
        return &self.entries.items[entry_idx];
    }

    /// Look up a symbol by exact name (case-insensitive).  Returns the first match.
    /// Uses binary search over `sorted_by_name` for O(log N) performance.
    pub fn lookup(self: *const SymbolIndex, name: []const u32) ?*const SymbolEntry {
        var upper_buf: [MAX_NAME]u8 = undefined;
        const ulen = codepoints_to_upper(name, &upper_buf);
        if (ulen == 0) return null;
        const needle = upper_buf[0..ulen];

        const idx = self.binarySearchName(needle) orelse return null;
        // Walk backwards to find the first entry with this name (there may be duplicates).
        var i = idx;
        while (i > 0) {
            const prev = self.sorted_by_name.items[i - 1];
            const prev_entry = &self.entries.items[prev];
            if (prev_entry.name_len != ulen or !std.mem.eql(u8, prev_entry.name_upper[0..prev_entry.name_len], needle))
                break;
            i -= 1;
        }
        const entry_idx = self.sorted_by_name.items[i];
        return &self.entries.items[entry_idx];
    }

    /// Look up a symbol by exact ASCII name (case-insensitive).
    /// Uses binary search over `sorted_by_name` for O(log N) performance.
    pub fn lookupAscii(self: *const SymbolIndex, name: []const u8) ?*const SymbolEntry {
        var upper_buf: [MAX_NAME]u8 = undefined;
        const ulen = @min(name.len, MAX_NAME);
        for (name[0..ulen], 0..) |c, i| {
            upper_buf[i] = std.ascii.toUpper(c);
        }
        const needle = upper_buf[0..ulen];

        const idx = self.binarySearchName(needle) orelse return null;
        var i = idx;
        while (i > 0) {
            const prev = self.sorted_by_name.items[i - 1];
            const prev_entry = &self.entries.items[prev];
            if (prev_entry.name_len != ulen or !std.mem.eql(u8, prev_entry.name_upper[0..prev_entry.name_len], needle))
                break;
            i -= 1;
        }
        const entry_idx = self.sorted_by_name.items[i];
        return &self.entries.items[entry_idx];
    }

    /// Look up the declared type of a variable by its uppercased ASCII name.
    /// Returns the type name (uppercased) or null if the variable has no recorded type.
    pub fn lookupVarType(self: *const SymbolIndex, var_name_upper: []const u8) ?[]const u8 {
        for (self.var_types.items) |*vt| {
            if (vt.var_name_len == var_name_upper.len and
                std.mem.eql(u8, vt.var_name_upper[0..vt.var_name_len], var_name_upper))
            {
                return vt.type_name_upper[0..vt.type_name_len];
            }
        }
        return null;
    }

    /// Look up the declared type of a field within a TYPE/CLASS.
    /// Given a type name (uppercased) and a field name (uppercased), returns the
    /// field's declared type (uppercased) or null if not found.
    pub fn lookupFieldType(self: *const SymbolIndex, type_name_upper: []const u8, field_name_upper: []const u8) ?[]const u8 {
        for (self.type_fields.items) |*tf| {
            if (tf.type_name_len == type_name_upper.len and
                std.mem.eql(u8, tf.type_name_upper[0..tf.type_name_len], type_name_upper) and
                tf.field_name_len == field_name_upper.len and
                std.mem.eql(u8, tf.field_name_upper[0..tf.field_name_len], field_name_upper))
            {
                if (tf.field_type_len > 0) {
                    return tf.field_type[0..tf.field_type_len];
                }
                return null;
            }
        }
        return null;
    }

    /// Resolve a dotted chain of identifiers to the final type name.
    /// `segments` contains uppercased identifier names, e.g. for `hero.position`:
    ///   segments[0] = "HERO", segments[1] = "POSITION"
    /// The first segment is looked up as a variable (via lookupVarType).
    /// Each subsequent segment is looked up as a field of the current type
    /// (via lookupFieldType).  Returns the final resolved type name (uppercased)
    /// or null if any step in the chain fails to resolve.
    /// Max chain depth is 16 to prevent infinite loops from circular type refs.
    pub fn resolveChainType(self: *const SymbolIndex, segments: []const []const u8) ?[]const u8 {
        if (segments.len == 0) return null;

        // Resolve first segment: variable → type
        var cur_type = self.lookupVarType(segments[0]) orelse return null;

        // Walk remaining segments
        for (segments[1..]) |seg| {
            // For LIST/HASHMAP: retrieval methods return the element type
            if (std.mem.eql(u8, cur_type, "LIST") or std.mem.eql(u8, cur_type, "HASHMAP")) {
                const seg_up = seg; // already uppercased by callers
                const is_retrieval = std.mem.eql(u8, seg_up, "GET") or
                    std.mem.eql(u8, seg_up, "HEAD") or
                    std.mem.eql(u8, seg_up, "TAIL") or
                    std.mem.eql(u8, seg_up, "POP") or
                    std.mem.eql(u8, seg_up, "SHIFT");
                if (is_retrieval) {
                    // Look up element type recorded in var_types or type_fields
                    const elem = self.lookupElementType(segments[0]) orelse return null;
                    if (elem.len == 0) return null;
                    cur_type = elem;
                    continue;
                }
            }
            cur_type = self.lookupFieldType(cur_type, seg) orelse return null;
        }

        return cur_type;
    }

    /// Look up the element type (LIST OF T / HASHMAP OF T) for a variable name.
    fn lookupElementType(self: *const SymbolIndex, var_name_upper: []const u8) ?[]const u8 {
        var best_idx: usize = std.math.maxInt(usize);
        var best_line: u32 = 0;
        for (self.var_types.items, 0..) |*vt, i| {
            if (vt.var_name_len == var_name_upper.len and
                std.mem.eql(u8, vt.var_name_upper[0..vt.var_name_len], var_name_upper) and
                vt.element_type_len > 0)
            {
                if (best_idx == std.math.maxInt(usize) or vt.line > best_line) {
                    best_idx = i;
                    best_line = vt.line;
                }
            }
        }
        if (best_idx == std.math.maxInt(usize)) return null;
        const vt = &self.var_types.items[best_idx];
        return vt.element_type_upper[0..vt.element_type_len];
    }

    /// Build type-completions for the AS keyword context.
    /// Populates `out_names` with built-in types + user-defined TYPE/CLASS names.
    /// Returns the number of completions written.
    pub fn typeCompletions(
        self: *const SymbolIndex,
        out_names: []DotCompletion,
    ) usize {
        var n: usize = 0;

        // 1. Built-in types
        for (BUILTIN_TYPES) |bt| {
            if (n >= out_names.len) break;
            out_names[n] = .{ .kind = .type_name };
            const len = @min(bt.len, MAX_NAME);
            @memcpy(out_names[n].name[0..len], bt[0..len]);
            @memcpy(out_names[n].name_upper[0..len], bt[0..len]);
            out_names[n].name_len = @intCast(len);
            // Extra: "built-in"
            const tag = "built-in";
            @memcpy(out_names[n].extra[0..tag.len], tag);
            out_names[n].extra_len = @intCast(tag.len);
            n += 1;
        }

        // 2. User-defined TYPE and CLASS names
        for (self.entries.items) |*entry| {
            if (n >= out_names.len) break;
            if (entry.kind == .type_decl or entry.kind == .class_decl) {
                // Check for duplicates with built-in types
                const ename = entry.name_upper[0..entry.name_len];
                var is_dup = false;
                for (BUILTIN_TYPES) |bt| {
                    if (bt.len == ename.len and std.mem.eql(u8, bt, ename)) {
                        is_dup = true;
                        break;
                    }
                }
                if (is_dup) continue;

                out_names[n] = .{ .kind = .type_name };
                const len = entry.name_len;
                @memcpy(out_names[n].name[0..len], entry.name_orig[0..len]);
                @memcpy(out_names[n].name_upper[0..len], entry.name_upper[0..len]);
                out_names[n].name_len = len;
                // Extra: "TYPE" or "CLASS"
                const tag: []const u8 = if (entry.kind == .class_decl) "CLASS" else "TYPE";
                @memcpy(out_names[n].extra[0..tag.len], tag);
                out_names[n].extra_len = @intCast(tag.len);
                n += 1;
            }
        }

        return n;
    }

    /// Build dot-completions for a dotted chain (e.g. hero.position.).
    /// `segments` are the uppercased identifiers before the final dot.
    /// For a single segment like `hero.`, this behaves like `dotCompletions`.
    /// For multiple segments like `hero.position.`, it resolves the chain to the
    /// final type and returns completions for that type.
    pub fn dotCompletionsChain(
        self: *const SymbolIndex,
        segments: []const []const u8,
        out_names: []DotCompletion,
    ) usize {
        if (segments.len == 0) return 0;

        if (segments.len == 1) {
            // Single identifier — use existing logic
            return self.dotCompletions(segments[0], out_names);
        }

        // Multi-segment: resolve chain to final type, then complete for that type
        const final_type = self.resolveChainType(segments) orelse return 0;
        return self.dotCompletionsForType(final_type, out_names);
    }

    /// Get all fields belonging to a given TYPE/CLASS name (uppercased).
    /// Returns a count and fills `out_buf` with pointers to matching TypeFieldEntry items.
    pub fn getTypeFields(
        self: *const SymbolIndex,
        type_name_upper: []const u8,
        out_buf: []const *const TypeFieldEntry,
    ) usize {
        var n_found: usize = 0;
        for (self.type_fields.items) |*tf| {
            if (n_found >= out_buf.len) break;
            if (tf.type_name_len == type_name_upper.len and
                std.mem.eql(u8, tf.type_name_upper[0..tf.type_name_len], type_name_upper))
            {
                out_buf[n_found] = tf;
                n_found += 1;
            }
        }
        return n_found;
    }

    /// Build a list of dot-completion strings for a given variable name (uppercased ASCII).
    /// Writes completion strings (original case) into `out_names` / `out_upper`, returns count.
    /// Handles HASHMAP, LIST, user TYPE/CLASS fields, and class methods.
    pub fn dotCompletions(
        self: *const SymbolIndex,
        var_name_upper: []const u8,
        out_names: []DotCompletion,
    ) usize {
        // 1. Look up the variable's declared type
        const type_name = self.lookupVarType(var_name_upper) orelse {
            // No DIM/LOCAL type info — check if the name itself is a TYPE/CLASS
            // (handles cases like `ME` completion if we store ME -> class mapping)
            return 0;
        };

        return self.dotCompletionsForType(type_name, out_names);
    }

    /// Build dot-completions for a known type name (uppercased).
    /// Return the EXTENDS base class name (uppercased) for a given class, or null.
    pub fn lookupClassParent(self: *const SymbolIndex, class_name_upper: []const u8) ?[]const u8 {
        for (self.entries.items) |*entry| {
            if (entry.kind == .class_decl and
                entry.name_len == class_name_upper.len and
                std.mem.eql(u8, entry.name_upper[0..entry.name_len], class_name_upper))
            {
                if (entry.extra_len > 0) return entry.extra[0..entry.extra_len];
                return null;
            }
        }
        return null;
    }

    pub fn dotCompletionsForType(
        self: *const SymbolIndex,
        type_name: []const u8,
        out_names: []DotCompletion,
    ) usize {
        var n_found: usize = 0;
        var seen_buf: [8][MAX_NAME]u8 = undefined;
        var seen_lens: [8]u8 = [_]u8{0} ** 8;
        var seen_count: usize = 0;

        // Walk up the inheritance chain collecting completions (max depth 8)
        var cur_type = type_name;
        var depth: usize = 0;
        while (depth < 8) : (depth += 1) {
            // Guard against cycles
            var already_seen = false;
            for (seen_buf[0..seen_count], 0..) |sb, si| {
                if (seen_lens[si] == cur_type.len and std.mem.eql(u8, sb[0..seen_lens[si]], cur_type)) {
                    already_seen = true;
                    break;
                }
            }
            if (already_seen) break;
            if (seen_count < 8) {
                const slen = @min(cur_type.len, MAX_NAME);
                @memcpy(seen_buf[seen_count][0..slen], cur_type[0..slen]);
                seen_lens[seen_count] = @intCast(slen);
                seen_count += 1;
            }

            // 1. Check built-in collection types (only for base type, depth==0)
            if (depth == 0) {
                if (std.mem.eql(u8, cur_type, "HASHMAP")) {
                    for (HASHMAP_METHODS) |m| {
                        if (n_found >= out_names.len) break;
                        out_names[n_found] = .{ .kind = .method };
                        const len = @min(m.len, MAX_NAME);
                        @memcpy(out_names[n_found].name[0..len], m[0..len]);
                        @memcpy(out_names[n_found].name_upper[0..len], m[0..len]);
                        out_names[n_found].name_len = @intCast(len);
                        n_found += 1;
                    }
                    return n_found;
                }
                if (std.mem.eql(u8, cur_type, "LIST")) {
                    for (LIST_METHODS) |m| {
                        if (n_found >= out_names.len) break;
                        out_names[n_found] = .{ .kind = .method };
                        const len = @min(m.len, MAX_NAME);
                        @memcpy(out_names[n_found].name[0..len], m[0..len]);
                        @memcpy(out_names[n_found].name_upper[0..len], m[0..len]);
                        out_names[n_found].name_len = @intCast(len);
                        n_found += 1;
                    }
                    return n_found;
                }
            }

            // 2. TYPE/CLASS fields for cur_type
            for (self.type_fields.items) |*tf| {
                if (n_found >= out_names.len) break;
                if (tf.type_name_len == cur_type.len and
                    std.mem.eql(u8, tf.type_name_upper[0..tf.type_name_len], cur_type))
                {
                    out_names[n_found] = .{ .kind = .field };
                    const len = tf.field_name_len;
                    @memcpy(out_names[n_found].name[0..len], tf.field_name_orig[0..len]);
                    @memcpy(out_names[n_found].name_upper[0..len], tf.field_name_upper[0..len]);
                    out_names[n_found].name_len = len;
                    const tlen = tf.field_type_len;
                    @memcpy(out_names[n_found].extra[0..tlen], tf.field_type[0..tlen]);
                    out_names[n_found].extra_len = tlen;
                    n_found += 1;
                }
            }

            // 3. CLASS methods (symbols with this owner)
            for (self.entries.items) |*entry| {
                if (n_found >= out_names.len) break;
                if (entry.kind == .method or entry.kind == .constructor or entry.kind == .destructor) {
                    if (entry.owner_len == cur_type.len and
                        std.mem.eql(u8, entry.owner[0..entry.owner_len], cur_type))
                    {
                        if (entry.kind == .constructor or entry.kind == .destructor) continue;
                        out_names[n_found] = .{ .kind = .method };
                        const len = entry.name_len;
                        @memcpy(out_names[n_found].name[0..len], entry.name_orig[0..len]);
                        @memcpy(out_names[n_found].name_upper[0..len], entry.name_upper[0..len]);
                        out_names[n_found].name_len = len;
                        const elen = entry.extra_len;
                        @memcpy(out_names[n_found].extra[0..elen], entry.extra[0..elen]);
                        out_names[n_found].extra_len = elen;
                        n_found += 1;
                    }
                }
            }

            // Climb to parent class
            const parent = self.lookupClassParent(cur_type) orelse break;
            cur_type = parent;
        }

        return n_found;
    }

    /// Find all symbols whose name starts with the given prefix (case-insensitive).
    /// Returns a list of indices into `entries`.  Caller must free.
    /// Uses binary search to find the first match, then scans forward — O(log N + m).
    pub fn prefixMatch(self: *const SymbolIndex, prefix: []const u32, alloc: Allocator) ![]u32 {
        var upper_buf: [MAX_NAME]u8 = undefined;
        const plen = codepoints_to_upper(prefix, &upper_buf);
        if (plen == 0) return &.{};
        const needle = upper_buf[0..plen];

        var results = std.ArrayListUnmanaged(u32){};

        // Binary search for the first sorted entry whose name >= needle prefix.
        const start = self.lowerBoundPrefix(needle);
        // Scan forward while entries still match the prefix.
        var i = start;
        while (i < self.sorted_by_name.items.len) : (i += 1) {
            const entry_idx = self.sorted_by_name.items[i];
            const entry = &self.entries.items[entry_idx];
            if (entry.name_len < plen) break;
            if (!std.mem.eql(u8, entry.name_upper[0..plen], needle)) break;
            try results.append(alloc, entry_idx);
        }
        return results.toOwnedSlice(alloc);
    }

    // ── Binary-search helpers (private) ─────────────────────────────

    /// Binary search `sorted_by_name` for an entry whose upper-case name
    /// exactly equals `needle`.  Returns the index into `sorted_by_name`
    /// (not into `entries`) so the caller can walk duplicates.  O(log N).
    fn binarySearchName(self: *const SymbolIndex, needle: []const u8) ?usize {
        const sorted = self.sorted_by_name.items;
        if (sorted.len == 0) return null;
        var lo: usize = 0;
        var hi: usize = sorted.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const entry = &self.entries.items[sorted[mid]];
            const ename = entry.name_upper[0..entry.name_len];
            switch (std.mem.order(u8, ename, needle)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return mid,
            }
        }
        return null;
    }

    /// Find the index in `sorted_by_name` of the first entry whose name is
    /// >= `prefix` when compared only on the first `prefix.len` bytes
    /// (lower bound for prefix scan).  O(log N).
    fn lowerBoundPrefix(self: *const SymbolIndex, prefix: []const u8) usize {
        const sorted = self.sorted_by_name.items;
        var lo: usize = 0;
        var hi: usize = sorted.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const entry = &self.entries.items[sorted[mid]];
            const ename = entry.name_upper[0..entry.name_len];
            // Compare the entry's name (truncated to prefix length) against the prefix.
            const cmp_len = @min(ename.len, prefix.len);
            const ord = std.mem.order(u8, ename[0..cmp_len], prefix);
            if (ord == .lt or (ord == .eq and cmp_len < prefix.len)) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return lo;
    }

    /// Scan an entire buffer (as lines of UTF-32 codepoints) and rebuild the index.
    /// `getLine` is a function that returns the codepoints for a given 0-based line index,
    /// or null if the line doesn't exist.  The returned slice must be freed by the caller.
    pub fn rebuild(
        self: *SymbolIndex,
        total_lines: usize,
        getLine: *const fn (usize, Allocator) ?[]const u32,
        allocator: Allocator,
    ) void {
        self.clear();

        var current_class: [MAX_NAME]u8 = undefined;
        var current_class_len: u8 = 0;
        var scope_kind: ScopeKind = .none;
        _ = &current_class;

        var line_idx: usize = 0;
        while (line_idx < total_lines) : (line_idx += 1) {
            const line_data = getLine(line_idx, allocator) orelse continue;
            defer allocator.free(line_data);

            // Track class/type scope (crude: set on CLASS/TYPE, clear on END CLASS/END TYPE)
            self.scanLine(line_data, @intCast(line_idx), &current_class, &current_class_len, &scope_kind);
        }

        // Build sorted indices
        self.buildSortedIndices();
    }

    /// Rebuild from a RopeBuffer-like object that has `lineCount()` and `getLine()`.
    pub fn rebuildFromBuffer(self: *SymbolIndex, buffer: anytype) void {
        self.clear();

        var current_class: [MAX_NAME]u8 = undefined;
        var current_class_len: u8 = 0;
        var scope_kind: ScopeKind = .none;

        const total = buffer.lineCount();
        var line_idx: usize = 0;
        while (line_idx < total) : (line_idx += 1) {
            const line_data = buffer.getLine(line_idx) catch continue;
            defer self.allocator.free(line_data);

            self.scanLine(line_data, @intCast(line_idx), &current_class, &current_class_len, &scope_kind);
        }

        self.buildSortedIndices();
    }

    // ── Internal line scanner ───────────────────────────────────────

    pub fn scanLine(
        self: *SymbolIndex,
        line: []const u32,
        line_idx: u32,
        current_class: *[MAX_NAME]u8,
        current_class_len: *u8,
        scope_kind: *ScopeKind,
    ) void {
        if (line.len == 0) return;

        // Skip leading whitespace
        var pos: usize = 0;
        while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) : (pos += 1) {}
        if (pos >= line.len) return;

        // Skip leading line number
        if (line[pos] >= '0' and line[pos] <= '9') {
            while (pos < line.len and line[pos] >= '0' and line[pos] <= '9') : (pos += 1) {}
            while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) : (pos += 1) {}
            if (pos >= line.len) return;
        }

        // Skip comment lines
        if (line[pos] == '\'') return;

        // Extract first word (uppercased)
        var w1_buf: [32]u8 = undefined;
        var w1_len: usize = 0;
        const w1_start = pos;
        _ = w1_start;
        while (pos < line.len and isIdentChar(line[pos]) and w1_len < 32) {
            w1_buf[w1_len] = asciiUpper(line[pos]);
            w1_len += 1;
            pos += 1;
        }
        const w1 = w1_buf[0..w1_len];

        if (w1_len == 0) {
            // Check for label: identifier at column 0 followed by ':'
            // (already past whitespace so won't match indented lines — that's correct)
            return;
        }

        // Check for REM
        if (eql(w1, "REM")) return;

        // ── SUB name(params) ────────────────────────────────────────
        if (eql(w1, "SUB")) {
            self.parseProcDecl(line, pos, line_idx, .sub, current_class, current_class_len);
            return;
        }

        // ── FUNCTION name(params) [AS type] ─────────────────────────
        if (eql(w1, "FUNCTION")) {
            self.parseProcDecl(line, pos, line_idx, .function, current_class, current_class_len);
            return;
        }

        // ── WORKER name(params) ─────────────────────────────────────
        if (eql(w1, "WORKER")) {
            self.parseProcDecl(line, pos, line_idx, .worker, current_class, current_class_len);
            return;
        }

        // ── METHOD name(params) [AS type] ───────────────────────────
        if (eql(w1, "METHOD")) {
            self.parseProcDecl(line, pos, line_idx, .method, current_class, current_class_len);
            // Enter method_body scope so lines inside are not treated as fields
            if (scope_kind.* == .class_decl) {
                scope_kind.* = .method_body;
            }
            return;
        }

        // ── CONSTRUCTOR(params) ─────────────────────────────────────
        if (eql(w1, "CONSTRUCTOR")) {
            self.parseConstructorDestructor(line, pos, line_idx, .constructor, current_class, current_class_len);
            if (scope_kind.* == .class_decl) {
                scope_kind.* = .method_body;
            }
            return;
        }

        // ── DESTRUCTOR() ────────────────────────────────────────────
        if (eql(w1, "DESTRUCTOR")) {
            self.parseConstructorDestructor(line, pos, line_idx, .destructor, current_class, current_class_len);
            if (scope_kind.* == .class_decl) {
                scope_kind.* = .method_body;
            }
            return;
        }

        // ── TYPE name ───────────────────────────────────────────────
        if (eql(w1, "TYPE")) {
            self.parseTypeOrClass(line, pos, line_idx, .type_decl, current_class, current_class_len);
            scope_kind.* = .type_decl;
            return;
        }

        // ── CLASS name [EXTENDS base] ───────────────────────────────
        if (eql(w1, "CLASS")) {
            self.parseTypeOrClass(line, pos, line_idx, .class_decl, current_class, current_class_len);
            scope_kind.* = .class_decl;
            return;
        }

        // ── END TYPE / END CLASS / END METHOD etc. — manage scope ───
        if (eql(w1, "END") or eql(w1, "ENDTYPE") or eql(w1, "ENDCLASS") or
            eql(w1, "ENDMETHOD") or eql(w1, "ENDSUB") or eql(w1, "ENDFUNCTION"))
        {
            if (eql(w1, "ENDTYPE") or eql(w1, "ENDCLASS")) {
                current_class_len.* = 0;
                scope_kind.* = .none;
                return;
            }
            if (eql(w1, "ENDMETHOD") or eql(w1, "ENDSUB") or eql(w1, "ENDFUNCTION")) {
                if (scope_kind.* == .method_body) {
                    scope_kind.* = .class_decl;
                }
                return;
            }
            // "END" — check next word
            var w2_buf: [32]u8 = undefined;
            var w2_len: usize = 0;
            var p2 = skipWs(line, pos);
            while (p2 < line.len and isIdentChar(line[p2]) and w2_len < 32) {
                w2_buf[w2_len] = asciiUpper(line[p2]);
                w2_len += 1;
                p2 += 1;
            }
            const w2 = w2_buf[0..w2_len];
            if (eql(w2, "TYPE") or eql(w2, "CLASS")) {
                current_class_len.* = 0;
                scope_kind.* = .none;
            } else if (eql(w2, "METHOD") or eql(w2, "CONSTRUCTOR") or eql(w2, "DESTRUCTOR") or
                eql(w2, "SUB") or eql(w2, "FUNCTION"))
            {
                // Leaving a method body — return to class_decl scope
                if (scope_kind.* == .method_body) {
                    scope_kind.* = .class_decl;
                }
            }
            return;
        }

        // ── CONSTANT name = value ───────────────────────────────────
        if (eql(w1, "CONSTANT")) {
            self.parseConstant(line, pos, line_idx);
            return;
        }

        // ── LET / DIM / REDIM / LOCAL — check for keyword-shadowing variable names ──
        if (eql(w1, "LET") or eql(w1, "DIM") or eql(w1, "REDIM") or eql(w1, "LOCAL")) {
            self.checkKeywordShadow(line, pos, line_idx, w1);
            // Also extract variable type info for dot-autocomplete
            self.parseVarType(line, pos, line_idx, null);
            // Don't return — fall through (these don't produce symbol entries)
        }

        // ── GLOBAL / SHARED — module-level typed declarations ───────
        if (eql(w1, "GLOBAL") or eql(w1, "SHARED")) {
            self.parseVarType(line, pos, line_idx, null);
            // Don't return — fall through
        }

        // ── DEF FN name(params) ─────────────────────────────────────
        if (eql(w1, "DEF")) {
            var w2_buf: [32]u8 = undefined;
            var w2_len: usize = 0;
            var p2 = skipWs(line, pos);
            while (p2 < line.len and isIdentChar(line[p2]) and w2_len < 32) {
                w2_buf[w2_len] = asciiUpper(line[p2]);
                w2_len += 1;
                p2 += 1;
            }
            if (eql(w2_buf[0..w2_len], "FN")) {
                self.parseProcDecl(line, p2, line_idx, .function, current_class, current_class_len);
            }
            return;
        }

        // ── TYPE/CLASS field: identifier [AS type] inside a TYPE or CLASS body ──
        // When inside a TYPE/CLASS scope and the first word is not one of the
        // declaration keywords that fell through above (LET/DIM/REDIM/LOCAL),
        // treat it as a field declaration.  Keyword-named fields like `pos`
        // (matching keyword POS) are intentionally allowed.
        if (current_class_len.* > 0 and (scope_kind.* == .type_decl or scope_kind.* == .class_decl) and
            w1_len > 0 and
            !eql(w1, "LET") and !eql(w1, "DIM") and !eql(w1, "REDIM") and !eql(w1, "LOCAL"))
        {
            // Check this is a field: should NOT be followed by ':' (label).
            if (pos >= line.len or line[pos] != ':') {
                self.parseTypeField(line, w1, w1_len, pos, current_class, current_class_len);
                return;
            }
        }

        // ── Step G: FOR item IN collection — infer loop variable element type ──
        // Pattern: FOR <ident> IN <listVar>
        if (eql(w1, "FOR")) {
            self.parseForIn(line, pos, line_idx);
        }

        // ── Label: identifier at start of (non-indented) line followed by ':' ──
        // We check if the first token is followed by ':' and it's not a keyword
        if (pos < line.len and line[pos] == ':') {
            // Check that we started at the beginning (no leading whitespace beyond line num)
            if (!isKeyword(w1)) {
                var entry = SymbolEntry{};
                entry.kind = .label;
                entry.line = line_idx;
                entry.col = 0;
                entry.name_len = @intCast(@min(w1_len, MAX_NAME));
                // Preserve original case — re-read from line
                const name_start = findWordStart(line);
                copyName(line, name_start, w1_len, &entry.name_orig, &entry.name_upper);
                self.entries.append(self.allocator, entry) catch {};
            }
        }
    }

    /// Parse `FOR item IN listVar` and record `item` as having the element type of `listVar`.
    fn parseForIn(
        self: *SymbolIndex,
        line: []const u32,
        after_for: usize,
        line_idx: u32,
    ) void {
        // Read loop variable name
        var p = skipWs(line, after_for);
        if (p >= line.len or !isIdentStart(line[p])) return;
        var loop_var: [MAX_NAME]u8 = undefined;
        var lv_len: usize = 0;
        while (p < line.len and isIdentChar(line[p]) and lv_len < MAX_NAME) {
            loop_var[lv_len] = asciiUpper(line[p]);
            lv_len += 1;
            p += 1;
        }
        if (lv_len == 0) return;
        // Skip type suffix
        if (p < line.len and isTypeSuffix(line[p])) p += 1;

        // Expect "IN"
        p = skipWs(line, p);
        var in_buf: [4]u8 = undefined;
        var in_len: usize = 0;
        var p2 = p;
        while (p2 < line.len and isIdentChar(line[p2]) and in_len < 4) {
            in_buf[in_len] = asciiUpper(line[p2]);
            in_len += 1;
            p2 += 1;
        }
        if (!eql(in_buf[0..in_len], "IN")) return;
        p = skipWs(line, p2);

        // Read the collection variable name
        if (p >= line.len or !isIdentStart(line[p])) return;
        var coll_var: [MAX_NAME]u8 = undefined;
        var cv_len: usize = 0;
        while (p < line.len and isIdentChar(line[p]) and cv_len < MAX_NAME) {
            coll_var[cv_len] = asciiUpper(line[p]);
            cv_len += 1;
            p += 1;
        }
        if (cv_len == 0) return;

        // Look up the element type of the collection variable
        const elem = self.lookupElementType(coll_var[0..cv_len]) orelse return;
        if (elem.len == 0) return;

        // Record the loop variable → element type
        var ve = VarTypeEntry{};
        ve.var_name_len = @intCast(lv_len);
        @memcpy(ve.var_name_upper[0..lv_len], loop_var[0..lv_len]);
        ve.type_name_len = @intCast(@min(elem.len, MAX_NAME));
        @memcpy(ve.type_name_upper[0..ve.type_name_len], elem[0..ve.type_name_len]);
        ve.line = line_idx;
        self.var_types.append(self.allocator, ve) catch {};
    }

    fn parseProcDecl(
        self: *SymbolIndex,
        line: []const u32,
        after_keyword: usize,
        line_idx: u32,
        kind: SymbolKind,
        current_class: *const [MAX_NAME]u8,
        current_class_len: *const u8,
    ) void {
        var pos = skipWs(line, after_keyword);
        if (pos >= line.len or !isIdentStart(line[pos])) return;

        var entry = SymbolEntry{};
        entry.kind = kind;
        entry.line = line_idx;
        entry.col = @intCast(@min(pos, std.math.maxInt(u16)));

        // Read name
        const name_start = pos;
        var nlen: usize = 0;
        while (pos < line.len and isIdentChar(line[pos]) and nlen < MAX_NAME) {
            entry.name_orig[nlen] = @intCast(line[pos] & 0x7F);
            entry.name_upper[nlen] = asciiUpper(line[pos]);
            nlen += 1;
            pos += 1;
        }
        _ = name_start;
        // Include type suffix ($, %, !, #, &) in name
        if (pos < line.len and isTypeSuffix(line[pos]) and nlen < MAX_NAME) {
            entry.name_orig[nlen] = @intCast(line[pos] & 0x7F);
            entry.name_upper[nlen] = @intCast(line[pos] & 0x7F);
            nlen += 1;
            pos += 1;
        }
        entry.name_len = @intCast(nlen);

        // ── Keyword shadow check for SUB / FUNCTION / WORKER ────────
        // (Not METHOD — methods have their own namespace via obj.Name())
        if (kind != .method and nlen > 0) {
            if (isKeyword(entry.name_upper[0..nlen])) {
                const decl_str: []const u8 = switch (kind) {
                    .sub => "SUB",
                    .function => "FUNCTION",
                    .worker => "WORKER",
                    else => "DECL",
                };
                var warn = KeywordShadowWarning{};
                warn.line = line_idx;
                warn.col = entry.col;
                warn.name_len = @intCast(nlen);
                @memcpy(warn.name_buf[0..nlen], entry.name_upper[0..nlen]);
                warn.decl_len = @intCast(@min(decl_str.len, 8));
                @memcpy(warn.decl_buf[0..warn.decl_len], decl_str[0..warn.decl_len]);
                self.warnings.append(self.allocator, warn) catch {};
            }
        }

        // Read params (everything inside parentheses)
        pos = skipWs(line, pos);
        if (pos < line.len and line[pos] == '(') {
            pos += 1; // skip '('
            var plen: usize = 0;
            var depth: u32 = 1;
            while (pos < line.len and depth > 0) {
                if (line[pos] == '(') depth += 1;
                if (line[pos] == ')') {
                    depth -= 1;
                    if (depth == 0) break;
                }
                if (plen < MAX_PARAMS) {
                    entry.params[plen] = @intCast(line[pos] & 0x7F);
                    plen += 1;
                }
                pos += 1;
            }
            entry.params_len = @intCast(plen);
            if (pos < line.len and line[pos] == ')') pos += 1;
        }

        // Read return type: "AS type"
        pos = skipWs(line, pos);
        if (pos + 2 < line.len) {
            const a = asciiUpper(line[pos]);
            const s = asciiUpper(line[pos + 1]);
            if (a == 'A' and s == 'S' and (pos + 2 >= line.len or !isIdentChar(line[pos + 2]))) {
                pos = skipWs(line, pos + 2);
                var elen: usize = 0;
                while (pos < line.len and isIdentChar(line[pos]) and elen < MAX_NAME) {
                    entry.extra[elen] = @intCast(line[pos] & 0x7F);
                    elen += 1;
                    pos += 1;
                }
                entry.extra_len = @intCast(elen);
            }
        }

        // Owner (enclosing TYPE/CLASS)
        if (current_class_len.* > 0) {
            entry.owner_len = current_class_len.*;
            @memcpy(entry.owner[0..entry.owner_len], current_class[0..entry.owner_len]);
        }

        self.entries.append(self.allocator, entry) catch {};

        // ── Step F: inject synthetic ME variable for method bodies ───────────
        // When parsing a METHOD inside a class, add a module-scoped VarTypeEntry
        // so that ME. triggers dot-completion for the enclosing class.
        if (kind == .method and current_class_len.* > 0 and entry.name_len > 0) {
            var me_entry = VarTypeEntry{};
            const me_name = "ME";
            me_entry.var_name_len = @intCast(me_name.len);
            @memcpy(me_entry.var_name_upper[0..me_name.len], me_name);
            me_entry.type_name_len = current_class_len.*;
            @memcpy(me_entry.type_name_upper[0..current_class_len.*], current_class[0..current_class_len.*]);
            me_entry.line = line_idx;
            // Scope it to the method so it only shows up inside this method
            const slen = @min(entry.name_len, MAX_NAME);
            me_entry.scope_name_len = @intCast(slen);
            @memcpy(me_entry.scope_name_upper[0..slen], entry.name_upper[0..slen]);
            self.var_types.append(self.allocator, me_entry) catch {};
        }

        // ── Step B: extract typed parameters as scoped VarTypeEntry items ──────
        // Re-scan the params blob for `name AS TypeName` pairs.
        // We work on the ASCII params[] byte array stored in the entry.
        if (entry.params_len > 0 and entry.name_len > 0) {
            const scope_slice = entry.name_upper[0..entry.name_len];
            var pi: usize = 0;
            const pb = entry.params[0..entry.params_len];
            while (pi < pb.len) {
                // Skip whitespace and commas/semicolons
                while (pi < pb.len and (pb[pi] == ' ' or pb[pi] == ',' or pb[pi] == ';' or pb[pi] == '\t')) : (pi += 1) {}
                if (pi >= pb.len) break;
                // Read param name
                if (!isIdentStartByte(pb[pi])) {
                    pi += 1;
                    continue;
                }
                var pname: [MAX_NAME]u8 = undefined;
                var pnlen: usize = 0;
                while (pi < pb.len and isIdentCharByte(pb[pi]) and pnlen < MAX_NAME) {
                    pname[pnlen] = asciiUpperByte(pb[pi]);
                    pnlen += 1;
                    pi += 1;
                }
                // Skip type suffix
                if (pi < pb.len and isTypeSuffixByte(pb[pi])) pi += 1;
                // Skip array parens
                if (pi < pb.len and pb[pi] == '(') {
                    while (pi < pb.len and pb[pi] != ')') : (pi += 1) {}
                    if (pi < pb.len) pi += 1;
                }
                // Skip whitespace
                while (pi < pb.len and pb[pi] == ' ') : (pi += 1) {}
                // Look for AS
                if (pi + 2 > pb.len) continue;
                if ((pb[pi] == 'A' or pb[pi] == 'a') and
                    (pb[pi + 1] == 'S' or pb[pi + 1] == 's') and
                    (pi + 2 >= pb.len or !isIdentCharByte(pb[pi + 2])))
                {
                    pi += 2;
                    while (pi < pb.len and pb[pi] == ' ') : (pi += 1) {}
                    if (pi >= pb.len or !isIdentStartByte(pb[pi])) continue;
                    var tname: [MAX_NAME]u8 = undefined;
                    var tnlen: usize = 0;
                    while (pi < pb.len and isIdentCharByte(pb[pi]) and tnlen < MAX_NAME) {
                        tname[tnlen] = asciiUpperByte(pb[pi]);
                        tnlen += 1;
                        pi += 1;
                    }
                    if (tnlen == 0 or pnlen == 0) continue;
                    // Skip primitive types — no dot-completion value
                    if (eql(tname[0..tnlen], "INTEGER") or eql(tname[0..tnlen], "DOUBLE") or
                        eql(tname[0..tnlen], "SINGLE") or eql(tname[0..tnlen], "STRING") or
                        eql(tname[0..tnlen], "LONG") or eql(tname[0..tnlen], "SHORT") or
                        eql(tname[0..tnlen], "BYTE") or eql(tname[0..tnlen], "UBYTE") or
                        eql(tname[0..tnlen], "USHORT") or eql(tname[0..tnlen], "UINTEGER") or
                        eql(tname[0..tnlen], "ULONG")) continue;
                    var ve = VarTypeEntry{};
                    ve.var_name_len = @intCast(pnlen);
                    @memcpy(ve.var_name_upper[0..pnlen], pname[0..pnlen]);
                    ve.type_name_len = @intCast(tnlen);
                    @memcpy(ve.type_name_upper[0..tnlen], tname[0..tnlen]);
                    ve.line = line_idx;
                    const slen = @min(scope_slice.len, MAX_NAME);
                    ve.scope_name_len = @intCast(slen);
                    @memcpy(ve.scope_name_upper[0..slen], scope_slice[0..slen]);
                    self.var_types.append(self.allocator, ve) catch {};
                }
                // Advance past identifier characters until next comma
                while (pi < pb.len and pb[pi] != ',') : (pi += 1) {}
            }
        }
    }

    fn parseConstructorDestructor(
        self: *SymbolIndex,
        line: []const u32,
        after_keyword: usize,
        line_idx: u32,
        kind: SymbolKind,
        current_class: *const [MAX_NAME]u8,
        current_class_len: *const u8,
    ) void {
        var entry = SymbolEntry{};
        entry.kind = kind;
        entry.line = line_idx;
        entry.col = 0;

        // Name is the keyword itself
        const kw_name = if (kind == .constructor) "CONSTRUCTOR" else "DESTRUCTOR";
        entry.name_len = @intCast(kw_name.len);
        @memcpy(entry.name_orig[0..kw_name.len], kw_name);
        @memcpy(entry.name_upper[0..kw_name.len], kw_name);

        // Read params
        var pos = skipWs(line, after_keyword);
        if (pos < line.len and line[pos] == '(') {
            pos += 1;
            var plen: usize = 0;
            var depth: u32 = 1;
            while (pos < line.len and depth > 0) {
                if (line[pos] == '(') depth += 1;
                if (line[pos] == ')') {
                    depth -= 1;
                    if (depth == 0) break;
                }
                if (plen < MAX_PARAMS) {
                    entry.params[plen] = @intCast(line[pos] & 0x7F);
                    plen += 1;
                }
                pos += 1;
            }
            entry.params_len = @intCast(plen);
        }

        // Owner
        if (current_class_len.* > 0) {
            entry.owner_len = current_class_len.*;
            @memcpy(entry.owner[0..entry.owner_len], current_class[0..entry.owner_len]);
        }

        self.entries.append(self.allocator, entry) catch {};
    }

    /// Parse `DIM varname AS typename` / `LOCAL varname AS typename` to record
    /// variable → type mappings for dot-autocomplete.
    /// `scope` is an optional uppercased scope name (SUB/FUNCTION name) for scoped params.
    fn parseVarType(
        self: *SymbolIndex,
        line: []const u32,
        after_keyword: usize,
        line_idx: u32,
        scope: ?[]const u8,
    ) void {
        var p = skipWs(line, after_keyword);
        if (p >= line.len or !isIdentStart(line[p])) return;

        // Read variable name
        var var_name: [MAX_NAME]u8 = undefined;
        var var_len: usize = 0;
        while (p < line.len and isIdentChar(line[p]) and var_len < MAX_NAME) {
            var_name[var_len] = asciiUpper(line[p]);
            var_len += 1;
            p += 1;
        }
        // Skip type suffix
        if (p < line.len and isTypeSuffix(line[p])) {
            p += 1;
        }
        // Skip optional array bounds: (...)
        if (p < line.len and line[p] == '(') {
            var depth: u32 = 1;
            p += 1;
            while (p < line.len and depth > 0) {
                if (line[p] == '(') depth += 1;
                if (line[p] == ')') depth -= 1;
                p += 1;
            }
        }

        // Look for "AS"
        p = skipWs(line, p);
        if (p + 2 > line.len) return;
        const a_ch = asciiUpper(line[p]);
        const s_ch = asciiUpper(line[p + 1]);
        if (a_ch != 'A' or s_ch != 'S') return;
        // Make sure "AS" is a whole word
        if (p + 2 < line.len and isIdentChar(line[p + 2])) return;
        p = skipWs(line, p + 2);

        // Read type name
        if (p >= line.len or !isIdentStart(line[p])) return;
        var type_name: [MAX_NAME]u8 = undefined;
        var type_len: usize = 0;
        while (p < line.len and isIdentChar(line[p]) and type_len < MAX_NAME) {
            type_name[type_len] = asciiUpper(line[p]);
            type_len += 1;
            p += 1;
        }
        if (type_len == 0 or var_len == 0) return;

        // Skip primitive types — no dot-completion for INTEGER, STRING, etc.
        // (But keep LIST and HASHMAP since those have dot-completion methods.)
        if (eql(type_name[0..type_len], "INTEGER") or
            eql(type_name[0..type_len], "DOUBLE") or
            eql(type_name[0..type_len], "SINGLE") or
            eql(type_name[0..type_len], "STRING") or
            eql(type_name[0..type_len], "LONG") or
            eql(type_name[0..type_len], "SHORT") or
            eql(type_name[0..type_len], "BYTE") or
            eql(type_name[0..type_len], "UBYTE") or
            eql(type_name[0..type_len], "USHORT") or
            eql(type_name[0..type_len], "UINTEGER") or
            eql(type_name[0..type_len], "ULONG"))
        {
            return;
        }

        var entry = VarTypeEntry{};
        entry.var_name_len = @intCast(var_len);
        @memcpy(entry.var_name_upper[0..var_len], var_name[0..var_len]);
        entry.type_name_len = @intCast(type_len);
        @memcpy(entry.type_name_upper[0..type_len], type_name[0..type_len]);
        entry.line = line_idx;

        // Attach scope name if provided
        if (scope) |sc| {
            const slen = @min(sc.len, MAX_NAME);
            entry.scope_name_len = @intCast(slen);
            @memcpy(entry.scope_name_upper[0..slen], sc[0..slen]);
        }

        // For LIST/HASHMAP: check for "OF TypeName"
        if (eql(type_name[0..type_len], "LIST") or eql(type_name[0..type_len], "HASHMAP")) {
            const p2 = skipWs(line, p);
            // Read next word
            var of_buf: [4]u8 = undefined;
            var of_len: usize = 0;
            var p3 = p2;
            while (p3 < line.len and isIdentChar(line[p3]) and of_len < 4) {
                of_buf[of_len] = asciiUpper(line[p3]);
                of_len += 1;
                p3 += 1;
            }
            if (eql(of_buf[0..of_len], "OF")) {
                p3 = skipWs(line, p3);
                var elen: usize = 0;
                while (p3 < line.len and isIdentChar(line[p3]) and elen < MAX_NAME) {
                    entry.element_type_upper[elen] = asciiUpper(line[p3]);
                    elen += 1;
                    p3 += 1;
                }
                entry.element_type_len = @intCast(elen);
            }
        }

        self.var_types.append(self.allocator, entry) catch {};
    }

    /// Parse a field declaration inside a TYPE or CLASS body.
    /// Expected format: `fieldname [AS type]` or `fieldname(dims) AS type`
    fn parseTypeField(
        self: *SymbolIndex,
        line: []const u32,
        w1: []const u8,
        w1_len: usize,
        after_name: usize,
        current_class: *const [MAX_NAME]u8,
        current_class_len: *const u8,
    ) void {
        if (current_class_len.* == 0 or w1_len == 0) return;

        var field = TypeFieldEntry{};
        // Set owning type name
        field.type_name_len = current_class_len.*;
        @memcpy(field.type_name_upper[0..field.type_name_len], current_class[0..field.type_name_len]);

        // Set field name (w1 is already uppercased)
        const nlen = @min(w1_len, MAX_NAME);
        field.field_name_len = @intCast(nlen);
        @memcpy(field.field_name_upper[0..nlen], w1[0..nlen]);
        // Recover original case from line — find the first word again
        const ws = findWordStart(line);
        for (0..nlen) |i| {
            if (ws + i < line.len) {
                field.field_name_orig[i] = @intCast(line[ws + i] & 0x7F);
            } else {
                field.field_name_orig[i] = w1[i];
            }
        }

        // Look for AS <type> after the field name
        var p = after_name;
        // Skip type suffix
        if (p < line.len and isTypeSuffix(line[p])) {
            p += 1;
        }
        // Skip optional array bounds
        if (p < line.len and line[p] == '(') {
            var depth: u32 = 1;
            p += 1;
            while (p < line.len and depth > 0) {
                if (line[p] == '(') depth += 1;
                if (line[p] == ')') depth -= 1;
                p += 1;
            }
        }
        p = skipWs(line, p);
        if (p + 2 <= line.len) {
            const a_ch = asciiUpper(line[p]);
            const s_ch = asciiUpper(line[p + 1]);
            if (a_ch == 'A' and s_ch == 'S' and (p + 2 >= line.len or !isIdentChar(line[p + 2]))) {
                p = skipWs(line, p + 2);
                var tlen: usize = 0;
                while (p < line.len and isIdentChar(line[p]) and tlen < MAX_NAME) {
                    field.field_type[tlen] = asciiUpper(line[p]);
                    tlen += 1;
                    p += 1;
                }
                field.field_type_len = @intCast(tlen);

                // For LIST/HASHMAP: parse optional "OF TypeName"
                if (eql(field.field_type[0..tlen], "LIST") or eql(field.field_type[0..tlen], "HASHMAP")) {
                    const p2 = skipWs(line, p);
                    var of_buf: [4]u8 = undefined;
                    var of_len: usize = 0;
                    var p3 = p2;
                    while (p3 < line.len and isIdentChar(line[p3]) and of_len < 4) {
                        of_buf[of_len] = asciiUpper(line[p3]);
                        of_len += 1;
                        p3 += 1;
                    }
                    if (eql(of_buf[0..of_len], "OF")) {
                        p3 = skipWs(line, p3);
                        var elen: usize = 0;
                        while (p3 < line.len and isIdentChar(line[p3]) and elen < MAX_NAME) {
                            field.element_type[elen] = asciiUpper(line[p3]);
                            elen += 1;
                            p3 += 1;
                        }
                        field.element_type_len = @intCast(elen);
                    }
                }
            }
        }

        self.type_fields.append(self.allocator, field) catch {};
    }

    fn parseTypeOrClass(
        self: *SymbolIndex,
        line: []const u32,
        after_keyword: usize,
        line_idx: u32,
        kind: SymbolKind,
        current_class: *[MAX_NAME]u8,
        current_class_len: *u8,
    ) void {
        var pos = skipWs(line, after_keyword);
        if (pos >= line.len or !isIdentStart(line[pos])) return;

        var entry = SymbolEntry{};
        entry.kind = kind;
        entry.line = line_idx;
        entry.col = @intCast(@min(pos, std.math.maxInt(u16)));

        // Read name
        var nlen: usize = 0;
        while (pos < line.len and isIdentChar(line[pos]) and nlen < MAX_NAME) {
            entry.name_orig[nlen] = @intCast(line[pos] & 0x7F);
            entry.name_upper[nlen] = asciiUpper(line[pos]);
            nlen += 1;
            pos += 1;
        }
        entry.name_len = @intCast(nlen);

        // ── Keyword shadow check for TYPE / CLASS ───────────────────
        if (nlen > 0 and isKeyword(entry.name_upper[0..nlen])) {
            const decl_str: []const u8 = if (kind == .class_decl) "CLASS" else "TYPE";
            var warn = KeywordShadowWarning{};
            warn.line = line_idx;
            warn.col = entry.col;
            warn.name_len = @intCast(nlen);
            @memcpy(warn.name_buf[0..nlen], entry.name_upper[0..nlen]);
            warn.decl_len = @intCast(@min(decl_str.len, 8));
            @memcpy(warn.decl_buf[0..warn.decl_len], decl_str[0..warn.decl_len]);
            self.warnings.append(self.allocator, warn) catch {};
        }

        // Set current class scope
        current_class_len.* = @intCast(nlen);
        @memcpy(current_class[0..nlen], entry.name_upper[0..nlen]);

        // For CLASS: look for EXTENDS
        if (kind == .class_decl) {
            pos = skipWs(line, pos);
            var ext_buf: [32]u8 = undefined;
            var ext_len: usize = 0;
            while (pos < line.len and isIdentChar(line[pos]) and ext_len < 32) {
                ext_buf[ext_len] = asciiUpper(line[pos]);
                ext_len += 1;
                pos += 1;
            }
            if (eql(ext_buf[0..ext_len], "EXTENDS")) {
                pos = skipWs(line, pos);
                var elen: usize = 0;
                while (pos < line.len and isIdentChar(line[pos]) and elen < MAX_NAME) {
                    entry.extra[elen] = @intCast(line[pos] & 0x7F);
                    elen += 1;
                    pos += 1;
                }
                entry.extra_len = @intCast(elen);
            }
        }

        self.entries.append(self.allocator, entry) catch {};
    }

    fn parseConstant(
        self: *SymbolIndex,
        line: []const u32,
        after_keyword: usize,
        line_idx: u32,
    ) void {
        var pos = skipWs(line, after_keyword);
        if (pos >= line.len or !isIdentStart(line[pos])) return;

        var entry = SymbolEntry{};
        entry.kind = .constant;
        entry.line = line_idx;
        entry.col = @intCast(@min(pos, std.math.maxInt(u16)));

        // Read name
        var nlen: usize = 0;
        while (pos < line.len and isIdentChar(line[pos]) and nlen < MAX_NAME) {
            entry.name_orig[nlen] = @intCast(line[pos] & 0x7F);
            entry.name_upper[nlen] = asciiUpper(line[pos]);
            nlen += 1;
            pos += 1;
        }
        // Include type suffix
        if (pos < line.len and isTypeSuffix(line[pos]) and nlen < MAX_NAME) {
            entry.name_orig[nlen] = @intCast(line[pos] & 0x7F);
            entry.name_upper[nlen] = @intCast(line[pos] & 0x7F);
            nlen += 1;
            pos += 1;
        }
        entry.name_len = @intCast(nlen);

        // Read value: skip whitespace and '=', then capture the rest
        pos = skipWs(line, pos);
        if (pos < line.len and line[pos] == '=') {
            pos = skipWs(line, pos + 1);
            var elen: usize = 0;
            while (pos < line.len and elen < MAX_NAME) {
                const cp = line[pos];
                if (cp == '\'' or cp == '\n' or cp == '\r') break; // stop at comment or EOL
                entry.extra[elen] = @intCast(cp & 0x7F);
                elen += 1;
                pos += 1;
            }
            // Trim trailing whitespace
            while (elen > 0 and (entry.extra[elen - 1] == ' ' or entry.extra[elen - 1] == '\t')) {
                elen -= 1;
            }
            entry.extra_len = @intCast(elen);
        }

        self.entries.append(self.allocator, entry) catch {};
    }

    // ── Sort helpers ────────────────────────────────────────────────

    pub fn buildSortedIndices(self: *SymbolIndex) void {
        const n = self.entries.items.len;
        if (n == 0) return;

        // Build index arrays
        self.sorted_by_name.clearRetainingCapacity();
        self.sorted_by_line.clearRetainingCapacity();

        self.sorted_by_name.ensureTotalCapacity(self.allocator, n) catch {};
        self.sorted_by_line.ensureTotalCapacity(self.allocator, n) catch {};

        for (0..n) |i| {
            self.sorted_by_name.append(self.allocator, @as(u32, @intCast(i))) catch continue;
            self.sorted_by_line.append(self.allocator, @as(u32, @intCast(i))) catch continue;
        }

        const entries = self.entries.items;

        // Sort by name (enables binary search in lookup / prefixMatch)
        std.mem.sortUnstable(u32, self.sorted_by_name.items, entries, struct {
            fn lessThan(ctx: []const SymbolEntry, a: u32, b: u32) bool {
                const na = ctx[a].name_upper[0..ctx[a].name_len];
                const nb = ctx[b].name_upper[0..ctx[b].name_len];
                return std.mem.order(u8, na, nb) == .lt;
            }
        }.lessThan);

        // Sort by line
        std.mem.sortUnstable(u32, self.sorted_by_line.items, entries, struct {
            fn lessThan(ctx: []const SymbolEntry, a: u32, b: u32) bool {
                return ctx[a].line < ctx[b].line;
            }
        }.lessThan);
    }

    // ── Keyword-shadow detection helper ─────────────────────────────

    /// Check whether the identifier after a LET/DIM/REDIM/LOCAL keyword
    /// is itself a language keyword, and if so, emit a warning.
    fn checkKeywordShadow(
        self: *SymbolIndex,
        line: []const u32,
        after_keyword: usize,
        line_idx: u32,
        decl_keyword: []const u8,
    ) void {
        var p = skipWs(line, after_keyword);
        if (p >= line.len or !isIdentStart(line[p])) return;

        const name_col = p;

        // Extract the variable name (identifier chars)
        var name_buf: [MAX_NAME]u8 = undefined;
        var nlen: usize = 0;
        while (p < line.len and isIdentChar(line[p]) and nlen < MAX_NAME) {
            name_buf[nlen] = asciiUpper(line[p]);
            nlen += 1;
            p += 1;
        }

        // Include trailing BASIC type suffix ($, %, !, #) if present
        if (p < line.len and nlen < MAX_NAME) {
            const ch = line[p];
            if (ch == '$' or ch == '%' or ch == '!' or ch == '#') {
                name_buf[nlen] = @intCast(ch & 0x7F);
                nlen += 1;
            }
        }

        if (nlen == 0) return;

        // Check against the keyword list
        if (isKeyword(name_buf[0..nlen])) {
            var warn = KeywordShadowWarning{};
            warn.line = line_idx;
            warn.col = @intCast(@min(name_col, std.math.maxInt(u16)));
            warn.name_len = @intCast(nlen);
            @memcpy(warn.name_buf[0..nlen], name_buf[0..nlen]);
            warn.decl_len = @intCast(@min(decl_keyword.len, 8));
            @memcpy(warn.decl_buf[0..warn.decl_len], decl_keyword[0..warn.decl_len]);
            self.warnings.append(self.allocator, warn) catch {};
        }
    }
};

// ── Keyword & built-in function list for autocomplete / shadow detection ────

/// All FasterBASIC keywords AND built-in function names.
/// Sorted alphabetically for binary search and autocomplete display.
pub const KEYWORDS = [_][]const u8{
    "ABS",
    "ABSZ",
    "ACOS",
    "AFTER",
    "AND",
    "ANDALSO",
    "APPEND",
    "ARG",
    "AS",
    "ASC",
    "ASIN",
    "AT",
    "ATAN",
    "ATAN2",
    "ATN",
    "AVG",
    "AWAIT",
    "BAND",
    "BEGINPAINT",
    "BIN$",
    "BITCLR",
    "BITCLRF",
    "BITFIELD",
    "BITGET",
    "BITINS",
    "BITREV",
    "BITSET",
    "BITSFIELD",
    "BITTGL",
    "BLIT",
    "BLITFLIP",
    "BLITSCALE",
    "BLITSOLID",
    "BNOT",
    "BOLD",
    "BOR",
    "BXOR",
    "BYREF",
    "BYTE",
    "BYTEREV",
    "BYVAL",
    "CALL",
    "CANCEL",
    "CANCELLED",
    "CASE",
    "CATCH",
    "CBRT",
    "CEIL",
    "CENTER$",
    "CHR$",
    "CINT",
    "CIRCLE",
    "CIRCLEF",
    "CLASS",
    "CLEAR",
    "CLG",
    "CLOSE",
    "CLZ",
    "CLS",
    "CMPLX",
    "COLOR",
    "COLOUR",
    "COMMAND",
    "COMMAND$",
    "COMMANDCOUNT",
    "COMPLEX",
    "CONSOLE",
    "CONSTANT",
    "CONJ",
    "CONSTRUCTOR",
    "CONTAINS",
    "COPY",
    "COS",
    "COSH",
    "CREATE",
    "CSRLIN",
    "CURSOR_HIDE",
    "CURSOR_OFF",
    "CURSOR_ON",
    "CURSOR_RESTORE",
    "CURSOR_SAVE",
    "CURSOR_SHOW",
    "CTZ",
    "CVD",
    "CVI",
    "CVS",
    "DATA",
    "DEC",
    "DEF",
    "DELETE",
    "DELETE$",
    "DESTRUCTOR",
    "DIM",
    "DO",
    "DONE",
    "DOT",
    "DOUBLE",
    "DRAWTEXT",
    "EACH",
    "ELLIPSE",
    "ELSE",
    "ELSEIF",
    "EMPTY",
    "END",
    "ENDCASE",
    "ENDFUNCTION",
    "ENDIF",
    "ENDMATCH",
    "ENDPAINT",
    "ENDSUB",
    "ENDTYPE",
    "ENDWORKER",
    "EOF",
    "ERASE",
    "ERL",
    "ERR",
    "EVERY",
    "EXIT",
    "EXP",
    "EXTRACT$",
    "EXTEND",
    "EXTENDS",
    "FIELD",
    "FILLAREA",
    "FINALLY",
    "FIX",
    "FLIP",
    "FLOOR",
    "FLUSH",
    "FN",
    "FOR",
    "FRAMES",
    "FRONTBUFFER",
    "FUNCTION",
    "FUTURE",
    "GBUFFERHEIGHT",
    "GBUFFERWIDTH",
    "GCLS",
    "GCOLLIDE",
    "GCOLLIDERESULT",
    "GCOLLIDESETUP",
    "GCOLLIDESRC",
    "GCOLLIDETEST",
    "GCOMMIT",
    "GET",
    "GFENCE",
    "GFENCEDONE",
    "GINKEY",
    "GINKEY$",
    "GKEYDOWN",
    "GLINE",
    "GLOBAL",
    "GMOUSEBUTTON",
    "GMOUSESCROLL",
    "GMOUSEX",
    "GMOUSEY",
    "GOSUB",
    "GOTO",
    "GSCREENHEIGHT",
    "GSCREENWIDTH",
    "GSCROLL",
    "GWAIT",
    "HASHMAP",
    "HASKEY",
    "HASMESSAGE",
    "HEAD",
    "HEX$",
    "HLINE",
    "HYPOT",
    "IF",
    "IIF",
    "IMP",
    "IMAG",
    "IN",
    "INC",
    "INCLUDE",
    "INDEXOF",
    "INKEY",
    "INKEY$",
    "INPUT",
    "INPUT$",
    "INSERT",
    "INSERT$",
    "INSTR",
    "INSTRREV",
    "INT",
    "INTEGER",
    "INVERSE",
    "IS",
    "ITALIC",
    "JOIN",
    "JOYAXIS",
    "JOYBUTTON",
    "JOYCOUNT",
    "KBCLEAR",
    "KBCODE",
    "KBCOUNT",
    "KBECHO",
    "KBFLUSH",
    "KBGET",
    "KBHIT",
    "KBINPUT",
    "KBMOD",
    "KBPEEK",
    "KBRAW",
    "KBSPECIAL",
    "KEYS",
    "LCASE$",
    "LEFT$",
    "LEN",
    "LENGTH",
    "LET",
    "LINE",
    "LINEPALETTE",
    "LINEPALETTEGET",
    "LIST",
    "LOC",
    "LOCAL",
    "LOCATE",
    "LOF",
    "LOG",
    "LOG10",
    "LONG",
    "LOOP",
    "LPAD$",
    "LSET",
    "LTRIM$",
    "MARSHALL",
    "MARSHALLED",
    "MATCH",
    "MAX",
    "ME",
    "METHOD",
    "MID$",
    "MIN",
    "MKD$",
    "MKI$",
    "MKS$",
    "MOD",
    "MOUSE_BUTTON",
    "MOUSE_BUTTONS",
    "MOUSE_POLL",
    "MOUSE_X",
    "MOUSE_Y",
    "MUSIC",
    "NEW",
    "NEXT",
    "NORMAL",
    "NOT",
    "NOTHING",
    "OCT$",
    "OF",
    "ON",
    "ONEVENT",
    "OPEN",
    "OR",
    "ORELSE",
    "OTHERWISE",
    "PALCYCLE",
    "PALETTE",
    "PALETTEGET",
    "PALFADE",
    "PALGRADIENT",
    "PALPAUSE",
    "PALPULSE",
    "PALRESUME",
    "PALSTOP",
    "PALSTOPALL",
    "PALSTROBE",
    "PARENT",
    "PGET",
    "PLAY",
    "POP",
    "POS",
    "POPCNT",
    "POLAR",
    "POW",
    "PREPEND",
    "PRESERVE",
    "PRINT",
    "PSET",
    "PUT",
    "READ",
    "REAL",
    "READY",
    "RECEIVE",
    "RECT",
    "REDIM",
    "REM",
    "REMOVE",
    "REMOVE$",
    "REPEAT",
    "REPEAT$",
    "REPLACE$",
    "RESETPALETTE",
    "REST",
    "RESTORE",
    "RETURN",
    "REVERSE",
    "REVERSE$",
    "RGB",
    "RGBBG",
    "RGBFG",
    "RIGHT$",
    "RND",
    "ROUND",
    "RPAD$",
    "ROW",
    "RSET",
    "RTRIM$",
    "RUN",
    "SCREEN",
    "SCREENACTIVE",
    "SCREENCLOSE",
    "SCREENHEIGHT",
    "SCREENMODE",
    "SCREENTITLE",
    "SCREENWIDTH",
    "SEEK",
    "SELECT",
    "SEND",
    "SETSCROLL",
    "SETTARGET",
    "SGN",
    "SHARED",
    "SHELL",
    "SHIFT",
    "SHORT",
    "SIN",
    "SINGLE",
    "SINH",
    "SIZE",
    "SLEEP",
    "SLURP",
    "SOUND",
    "SPACE$",
    "SPAWN",
    "SPIT",
    "SPREXPLODE",
    "SPRFREE",
    "SPRHIDE",
    "SPRITE",
    "SPRITECOUNT",
    "SPRITEGETFRAME",
    "SPRITEGETROT",
    "SPRITEHIT",
    "SPRITEOVERLAP",
    "SPRITEVISIBLE",
    "SPRITEX",
    "SPRITEY",
    "SPRLOAD",
    "SPRMOVE",
    "SPRPOS",
    "SPRROT",
    "SPRSCALE",
    "SPRSHOW",
    "SPRTINT",
    "SQR",
    "STEP",
    "STOP",
    "STR$",
    "STRCENTER",
    "STRDELETE",
    "STREXTRACT",
    "STRING",
    "STRING$",
    "STRINSERT",
    "STRINSTRREV",
    "STRLPAD",
    "STRREMOVE",
    "STRREPEAT",
    "STRREPLACE",
    "STRREVERSE",
    "STRRPAD",
    "STRTALLY",
    "STYLE_RESET",
    "SUB",
    "SUM",
    "SUPER",
    "SWAP",
    "SYSTEM",
    "TAIL",
    "TALLY",
    "TAN",
    "TANH",
    "STR$",
    "TEXTWIDTH",
    "TGRID",
    "TYPE",
    "TYPEOF",
    "UBYTE",
    "UCASE$",
    "UINTEGER",
    "ULONG",
    "UNDERLINE",
    "UNMARSHALL",
    "UNTIL",
    "USHORT",
    "USING",
    "VAL",
    "VDUCLS",
    "VDUCOLOR",
    "VDUCOLOUR",
    "VDUCURSOR",
    "VDUDOWN",
    "VDUEOL",
    "VDUEOS",
    "VDUHEIGHT",
    "VDULEFT",
    "VDUMOVE",
    "VDUPOS",
    "VDUPOSX",
    "VDUPOSY",
    "VDURESET",
    "VDURGB",
    "VDURIGHT",
    "VDUSCREEN",
    "VDUSIZE",
    "VDUSTYLE",
    "VDUUP",
    "VDUWIDTH",
    "VLINE",
    "VS",
    "VSYNC",
    "WAIT",
    "WEND",
    "WHEN",
    "WHILE",
    "WORKER",
    "WRITE",
    "XOR",
};

// ── Keyword check (for filtering labels & shadow detection) ─────────────────

/// A single dot-completion item for the autocomplete popup.
pub const DotCompletion = struct {
    /// Original-case name for insertion.
    name: [MAX_NAME]u8 = undefined,
    /// Uppercased name for matching.
    name_upper: [MAX_NAME]u8 = undefined,
    name_len: u8 = 0,
    /// Extra info (field type or method return type, or "built-in"/"TYPE"/"CLASS" for type completions).
    extra: [MAX_NAME]u8 = undefined,
    extra_len: u8 = 0,
    /// Item kind.
    kind: enum(u8) { field, method, type_name } = .field,

    pub fn getName(self: *const DotCompletion) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn getNameUpper(self: *const DotCompletion) []const u8 {
        return self.name_upper[0..self.name_len];
    }

    pub fn getExtra(self: *const DotCompletion) []const u8 {
        return self.extra[0..self.extra_len];
    }
};

/// Maximum number of dot-completion items.
pub const MAX_DOT_COMPLETIONS: usize = 128;

/// Check whether `word` (expected uppercase) is a language keyword.
/// Uses binary search over the sorted KEYWORDS array — O(log N).
pub fn isKeyword(word: []const u8) bool {
    if (word.len == 0) return false;
    var lo: usize = 0;
    var hi: usize = KEYWORDS.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const ord = std.mem.order(u8, KEYWORDS[mid], word);
        switch (ord) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return true,
        }
    }
    return false;
}

// ── Utility functions ───────────────────────────────────────────────────────

fn isIdentStart(cp: u32) bool {
    return (cp >= 'A' and cp <= 'Z') or (cp >= 'a' and cp <= 'z') or cp == '_';
}

pub fn isIdentChar(cp: u32) bool {
    return isIdentStart(cp) or (cp >= '0' and cp <= '9');
}

fn isTypeSuffix(cp: u32) bool {
    return cp == '$' or cp == '%' or cp == '!' or cp == '#' or cp == '&';
}

fn asciiUpper(cp: u32) u8 {
    if (cp >= 'a' and cp <= 'z') return @intCast(cp - 32);
    if (cp < 128) return @intCast(cp);
    return '?';
}

/// Byte-level helpers used when scanning the ASCII params buffer in parseProcDecl.
fn isIdentStartByte(b: u8) bool {
    return (b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z') or b == '_';
}

fn isIdentCharByte(b: u8) bool {
    return isIdentStartByte(b) or (b >= '0' and b <= '9');
}

fn isTypeSuffixByte(b: u8) bool {
    return b == '$' or b == '%' or b == '!' or b == '#' or b == '&';
}

fn asciiUpperByte(b: u8) u8 {
    if (b >= 'a' and b <= 'z') return b - 32;
    return b;
}

fn skipWs(line: []const u32, start: usize) usize {
    var i = start;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    return i;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Convert a codepoint slice to uppercase ASCII bytes, return the length written.
fn codepoints_to_upper(cps: []const u32, buf: *[MAX_NAME]u8) usize {
    var len: usize = 0;
    for (cps) |cp| {
        if (len >= MAX_NAME) break;
        buf[len] = asciiUpper(cp);
        len += 1;
    }
    return len;
}

/// Copy a name from a codepoint line, preserving original case and building uppercased version.
fn copyName(line: []const u32, start: usize, len: usize, orig: *[MAX_NAME]u8, upper: *[MAX_NAME]u8) void {
    const cpy_len = @min(len, MAX_NAME);
    for (0..cpy_len) |i| {
        if (start + i < line.len) {
            const cp = line[start + i];
            orig[i] = @intCast(cp & 0x7F);
            upper[i] = asciiUpper(cp);
        }
    }
}

/// Find the start of the first identifier in a line (skipping whitespace and line numbers).
fn findWordStart(line: []const u32) usize {
    var pos: usize = 0;
    // Skip whitespace
    while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) : (pos += 1) {}
    // Skip line number
    if (pos < line.len and line[pos] >= '0' and line[pos] <= '9') {
        while (pos < line.len and line[pos] >= '0' and line[pos] <= '9') : (pos += 1) {}
        while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) : (pos += 1) {}
    }
    return pos;
}

/// Given a line and a column position, extract the identifier word under/before
/// the cursor.  Returns the word as u32 codepoints and its start column.
pub fn wordAtCursor(line: []const u32, col: usize) struct { word: []const u32, start: usize } {
    if (line.len == 0 or col == 0) return .{ .word = &.{}, .start = col };

    // Walk backward to find start of word
    var start = @min(col, line.len);
    // If cursor is past the end or on a non-ident char, step back
    if (start > 0 and (start >= line.len or !isIdentChar(line[start]))) {
        start -= 1;
    }
    while (start > 0 and isIdentChar(line[start - 1])) {
        start -= 1;
    }
    // Find end of word
    var end = start;
    while (end < line.len and isIdentChar(line[end])) {
        end += 1;
    }
    // Include type suffix
    if (end < line.len and isTypeSuffix(line[end])) {
        end += 1;
    }

    if (end <= start) return .{ .word = &.{}, .start = col };
    return .{ .word = line[start..end], .start = start };
}

/// Get the word (as codepoints) immediately before a given column.
/// Useful for autocomplete prefix extraction.
pub fn prefixBeforeCursor(line: []const u32, col: usize) []const u32 {
    if (line.len == 0 or col == 0) return &.{};

    const end = @min(col, line.len);
    var start = end;
    while (start > 0 and isIdentChar(line[start - 1])) {
        start -= 1;
    }
    if (start == end) return &.{};
    return line[start..end];
}

// ============================================================================
// Tests
// ============================================================================

fn toU32(comptime s: []const u8) [s.len]u32 {
    var result: [s.len]u32 = undefined;
    for (s, 0..) |c, i| {
        result[i] = c;
    }
    return result;
}

test "scanLine detects SUB" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    const line = toU32("SUB MyProc(x AS INTEGER, y AS DOUBLE)");
    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;
    idx.scanLine(&line, 0, &cls, &cls_len, &sk);

    try std.testing.expectEqual(@as(usize, 1), idx.count());
    const entry = &idx.entries.items[0];
    try std.testing.expectEqual(SymbolKind.sub, entry.kind);
    try std.testing.expectEqualStrings("MyProc", entry.getName());
    try std.testing.expectEqualStrings("x AS INTEGER, y AS DOUBLE", entry.getParams());
}

test "scanLine detects FUNCTION with return type" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    const line = toU32("FUNCTION Add(a AS INTEGER, b AS INTEGER) AS INTEGER");
    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;
    idx.scanLine(&line, 5, &cls, &cls_len, &sk);

    try std.testing.expectEqual(@as(usize, 1), idx.count());
    const entry = &idx.entries.items[0];
    try std.testing.expectEqual(SymbolKind.function, entry.kind);
    try std.testing.expectEqualStrings("Add", entry.getName());
    try std.testing.expectEqualStrings("INTEGER", entry.getExtra());
}

test "scanLine detects TYPE" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    const line = toU32("TYPE Vector2D");
    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;
    idx.scanLine(&line, 0, &cls, &cls_len, &sk);

    try std.testing.expectEqual(@as(usize, 1), idx.count());
    const entry = &idx.entries.items[0];
    try std.testing.expectEqual(SymbolKind.type_decl, entry.kind);
    try std.testing.expectEqualStrings("Vector2D", entry.getName());
    // Class scope should be set
    try std.testing.expectEqual(@as(u8, 8), cls_len);
}

test "scanLine detects CLASS with EXTENDS" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    const line = toU32("CLASS Dog EXTENDS Animal");
    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;
    idx.scanLine(&line, 0, &cls, &cls_len, &sk);

    try std.testing.expectEqual(@as(usize, 1), idx.count());
    const entry = &idx.entries.items[0];
    try std.testing.expectEqual(SymbolKind.class_decl, entry.kind);
    try std.testing.expectEqualStrings("Dog", entry.getName());
    try std.testing.expectEqualStrings("Animal", entry.getExtra());
}

test "scanLine detects CONSTANT" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    const line = toU32("CONSTANT PI = 3.14159");
    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;
    idx.scanLine(&line, 0, &cls, &cls_len, &sk);

    try std.testing.expectEqual(@as(usize, 1), idx.count());
    const entry = &idx.entries.items[0];
    try std.testing.expectEqual(SymbolKind.constant, entry.kind);
    try std.testing.expectEqualStrings("PI", entry.getName());
    try std.testing.expectEqualStrings("3.14159", entry.getExtra());
}

test "scanLine detects WORKER" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    const line = toU32("WORKER DataProcessor(url AS STRING)");
    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;
    idx.scanLine(&line, 0, &cls, &cls_len, &sk);

    try std.testing.expectEqual(@as(usize, 1), idx.count());
    const entry = &idx.entries.items[0];
    try std.testing.expectEqual(SymbolKind.worker, entry.kind);
    try std.testing.expectEqualStrings("DataProcessor", entry.getName());
}

test "WORKER without parens found by lookup" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;

    // Simulate the user's program — WORKER with no parentheses
    const line1 = toU32("FUNCTION Fibonacci(n AS INTEGER) AS INTEGER");
    const line2 = toU32("END FUNCTION");
    const line3 = toU32("WORKER MyWorker");
    const line4 = toU32("  DIM result AS DOUBLE");
    const line5 = toU32("END WORKER");
    const line6 = toU32("w = SPAWN MyWorker");

    idx.scanLine(&line1, 0, &cls, &cls_len, &sk);
    idx.scanLine(&line2, 1, &cls, &cls_len, &sk);
    idx.scanLine(&line3, 2, &cls, &cls_len, &sk);
    idx.scanLine(&line4, 3, &cls, &cls_len, &sk);
    idx.scanLine(&line5, 4, &cls, &cls_len, &sk);
    idx.scanLine(&line6, 5, &cls, &cls_len, &sk);
    idx.buildSortedIndices();

    // Verify WORKER was detected
    try std.testing.expectEqual(@as(usize, 2), idx.count()); // Fibonacci + MyWorker

    // lookup (codepoint path — what goToDefinition uses)
    const query = toU32("MyWorker");
    const result = idx.lookup(&query);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(SymbolKind.worker, result.?.kind);
    try std.testing.expectEqual(@as(u32, 2), result.?.line);
    try std.testing.expectEqualStrings("MyWorker", result.?.getName());

    // lookupAscii
    const result2 = idx.lookupAscii("myworker");
    try std.testing.expect(result2 != null);
    try std.testing.expectEqual(@as(u32, 2), result2.?.line);

    // Also verify Fibonacci is found
    const fib_query = toU32("Fibonacci");
    const fib_result = idx.lookup(&fib_query);
    try std.testing.expect(fib_result != null);
    try std.testing.expectEqual(SymbolKind.function, fib_result.?.kind);
}

test "scanLine detects label" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    const line = toU32("MainLoop:");
    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;
    idx.scanLine(&line, 0, &cls, &cls_len, &sk);

    try std.testing.expectEqual(@as(usize, 1), idx.count());
    const entry = &idx.entries.items[0];
    try std.testing.expectEqual(SymbolKind.label, entry.kind);
    try std.testing.expectEqualStrings("MainLoop", entry.getName());
}

test "scanLine ignores comments" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    const line1 = toU32("' SUB NotAReal()");
    const line2 = toU32("REM FUNCTION AlsoNot()");
    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;
    idx.scanLine(&line1, 0, &cls, &cls_len, &sk);
    idx.scanLine(&line2, 1, &cls, &cls_len, &sk);

    try std.testing.expectEqual(@as(usize, 0), idx.count());
}

test "END TYPE clears class scope" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;

    const line1 = toU32("TYPE Foo");
    idx.scanLine(&line1, 0, &cls, &cls_len, &sk);
    try std.testing.expect(cls_len > 0);
    try std.testing.expectEqual(ScopeKind.type_decl, sk);

    const line2 = toU32("END TYPE");
    idx.scanLine(&line2, 1, &cls, &cls_len, &sk);
    try std.testing.expectEqual(@as(u8, 0), cls_len);
    try std.testing.expectEqual(ScopeKind.none, sk);
}

test "lookup finds symbol case-insensitively" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    const line = toU32("FUNCTION Calculate(n AS INTEGER) AS DOUBLE");
    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;
    idx.scanLine(&line, 42, &cls, &cls_len, &sk);
    idx.buildSortedIndices();

    const query_lower = toU32("calculate");
    const result = idx.lookup(&query_lower);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u32, 42), result.?.line);
}

test "lookupAscii finds symbol" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    const line = toU32("SUB DrawSprite(id AS INTEGER)");
    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;
    idx.scanLine(&line, 10, &cls, &cls_len, &sk);
    idx.buildSortedIndices();

    const result = idx.lookupAscii("drawsprite");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(SymbolKind.sub, result.?.kind);
}

test "prefixMatch returns matching symbols" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    const line1 = toU32("FUNCTION DrawCircle(r AS INTEGER) AS INTEGER");
    const line2 = toU32("SUB DrawRect(w AS INTEGER)");
    const line3 = toU32("FUNCTION PrintMessage()");
    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;
    idx.scanLine(&line1, 1, &cls, &cls_len, &sk);
    idx.scanLine(&line2, 2, &cls, &cls_len, &sk);
    idx.scanLine(&line3, 3, &cls, &cls_len, &sk);
    idx.buildSortedIndices();

    const prefix = toU32("draw");
    const matches: []u32 = try idx.prefixMatch(&prefix, allocator);
    defer allocator.free(matches);

    try std.testing.expectEqual(@as(usize, 2), matches.len);
}

test "wordAtCursor extracts word" {
    const line = toU32("  DIM myVar AS INTEGER");
    const result = wordAtCursor(&line, 9);
    try std.testing.expectEqual(@as(usize, 5), result.word.len);
    // "myVar" starts at col 6
    try std.testing.expectEqual(@as(u32, 'm'), result.word[0]);
    try std.testing.expectEqual(@as(u32, 'r'), result.word[4]);
}

test "wordAtCursor finds MyWorker in SPAWN line" {
    const line = toU32("w = SPAWN MyWorker");
    //                   0123456789012345678
    //                             ^ col 10 = 'M'

    // Cursor on 'M' (col 10)
    const r1 = wordAtCursor(&line, 10);
    try std.testing.expectEqual(@as(usize, 8), r1.word.len);
    try std.testing.expectEqual(@as(usize, 10), r1.start);
    try std.testing.expectEqual(@as(u32, 'M'), r1.word[0]);
    try std.testing.expectEqual(@as(u32, 'r'), r1.word[7]);

    // Cursor in middle of MyWorker (col 14 = 'r')
    const r2 = wordAtCursor(&line, 14);
    try std.testing.expectEqual(@as(usize, 8), r2.word.len);
    try std.testing.expectEqual(@as(usize, 10), r2.start);

    // Cursor at end of line (col 18, one past last char)
    const r3 = wordAtCursor(&line, 18);
    try std.testing.expectEqual(@as(usize, 8), r3.word.len);
    try std.testing.expectEqual(@as(usize, 10), r3.start);

    // Cursor on SPAWN (col 5)
    const r4 = wordAtCursor(&line, 5);
    try std.testing.expectEqual(@as(usize, 5), r4.word.len);
    try std.testing.expectEqual(@as(u32, 'S'), r4.word[0]);

    // Cursor on 'w' (col 1)
    const r5 = wordAtCursor(&line, 1);
    try std.testing.expectEqual(@as(usize, 1), r5.word.len);
    try std.testing.expectEqual(@as(u32, 'w'), r5.word[0]);
}

test "prefixBeforeCursor extracts prefix" {
    const line = toU32("  PRINT Cal");
    const prefix = prefixBeforeCursor(&line, 11);
    try std.testing.expectEqual(@as(usize, 3), prefix.len);
    try std.testing.expectEqual(@as(u32, 'C'), prefix[0]);
}

test "formatDisplay produces readable string" {
    var entry = SymbolEntry{};
    entry.kind = .function;
    entry.name_len = 3;
    @memcpy(entry.name_orig[0..3], "Add");
    entry.params_len = 18;
    @memcpy(entry.params[0..18], "a AS INT, b AS INT");
    entry.extra_len = 7;
    @memcpy(entry.extra[0..7], "INTEGER");

    var buf: [512]u8 = undefined;
    const display = entry.formatDisplay(&buf);
    try std.testing.expect(display.len > 0);
    // Should contain "FUNCTION Add(a AS INT, b AS INT) AS INTEGER"
    try std.testing.expect(std.mem.indexOf(u8, display, "FUNCTION") != null);
    try std.testing.expect(std.mem.indexOf(u8, display, "Add") != null);
    try std.testing.expect(std.mem.indexOf(u8, display, "INTEGER") != null);
}

test "sorted indices are in order" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;

    const line1 = toU32("SUB Zebra()");
    const line2 = toU32("SUB Alpha()");
    const line3 = toU32("SUB Middle()");
    idx.scanLine(&line1, 10, &cls, &cls_len, &sk);
    idx.scanLine(&line2, 5, &cls, &cls_len, &sk);
    idx.scanLine(&line3, 8, &cls, &cls_len, &sk);
    idx.buildSortedIndices();

    // By name: Alpha, Middle, Zebra
    try std.testing.expectEqualStrings("Alpha", idx.byName(0).?.getName());
    try std.testing.expectEqualStrings("Middle", idx.byName(1).?.getName());
    try std.testing.expectEqualStrings("Zebra", idx.byName(2).?.getName());

    // By line: Alpha(5), Middle(8), Zebra(10)
    try std.testing.expectEqual(@as(u32, 5), idx.byLine(0).?.line);
    try std.testing.expectEqual(@as(u32, 8), idx.byLine(1).?.line);
    try std.testing.expectEqual(@as(u32, 10), idx.byLine(2).?.line);
}

test "indented SUB is detected" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    const line = toU32("    SUB Helper(msg AS STRING)");
    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;
    idx.scanLine(&line, 0, &cls, &cls_len, &sk);

    try std.testing.expectEqual(@as(usize, 1), idx.count());
    try std.testing.expectEqualStrings("Helper", idx.entries.items[0].getName());
}

test "line-numbered declaration is detected" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    const line = toU32("100 SUB OldSchool()");
    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;
    idx.scanLine(&line, 0, &cls, &cls_len, &sk);

    try std.testing.expectEqual(@as(usize, 1), idx.count());
    try std.testing.expectEqualStrings("OldSchool", idx.entries.items[0].getName());
}

test "METHOD inside CLASS gets owner" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;

    const line1 = toU32("CLASS Player");
    idx.scanLine(&line1, 0, &cls, &cls_len, &sk);

    const line2 = toU32("  METHOD Move(dx AS INTEGER)");
    idx.scanLine(&line2, 1, &cls, &cls_len, &sk);

    try std.testing.expectEqual(@as(usize, 2), idx.count());
    const method = &idx.entries.items[1];
    try std.testing.expectEqual(SymbolKind.method, method.kind);
    try std.testing.expectEqualStrings("Move", method.getName());
    try std.testing.expectEqualStrings("PLAYER", method.getOwner());
}

test "CONSTRUCTOR detected" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;

    var sk: ScopeKind = .none;
    const line = toU32("  CONSTRUCTOR(name AS STRING)");
    idx.scanLine(&line, 5, &cls, &cls_len, &sk);

    try std.testing.expectEqual(@as(usize, 1), idx.count());
    try std.testing.expectEqual(SymbolKind.constructor, idx.entries.items[0].kind);
    try std.testing.expectEqualStrings("name AS STRING", idx.entries.items[0].getParams());
}

test "DEF FN detected as function" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    const line = toU32("DEF FN Square(x) = x * x");
    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;
    idx.scanLine(&line, 0, &cls, &cls_len, &sk);

    try std.testing.expectEqual(@as(usize, 1), idx.count());
    try std.testing.expectEqual(SymbolKind.function, idx.entries.items[0].kind);
    try std.testing.expectEqualStrings("Square", idx.entries.items[0].getName());
}

// ── Keyword shadow detection tests ──────────────────────────────────────────

test "isKeyword binary search finds known keywords" {
    try std.testing.expect(isKeyword("PRINT"));
    try std.testing.expect(isKeyword("DIM"));
    try std.testing.expect(isKeyword("LET"));
    try std.testing.expect(isKeyword("FOR"));
    try std.testing.expect(isKeyword("STEP"));
    try std.testing.expect(isKeyword("LINE"));
    try std.testing.expect(isKeyword("CIRCLE"));
    try std.testing.expect(isKeyword("LEFT$"));
    try std.testing.expect(isKeyword("UCASE$"));
    try std.testing.expect(isKeyword("XOR"));
    try std.testing.expect(isKeyword("AFTER"));
    // First and last entries in sorted list
    try std.testing.expect(isKeyword(KEYWORDS[0]));
    try std.testing.expect(isKeyword(KEYWORDS[KEYWORDS.len - 1]));
}

test "isKeyword finds built-in functions" {
    // String functions
    try std.testing.expect(isKeyword("LEN"));
    try std.testing.expect(isKeyword("VAL"));
    try std.testing.expect(isKeyword("ASC"));
    try std.testing.expect(isKeyword("CHR$"));
    try std.testing.expect(isKeyword("STR$"));
    try std.testing.expect(isKeyword("INSTR"));
    try std.testing.expect(isKeyword("LTRIM$"));
    try std.testing.expect(isKeyword("RTRIM$"));
    try std.testing.expect(isKeyword("TRIM$"));
    try std.testing.expect(isKeyword("HEX$"));
    try std.testing.expect(isKeyword("OCT$"));
    try std.testing.expect(isKeyword("BIN$"));
    try std.testing.expect(isKeyword("SPACE$"));
    try std.testing.expect(isKeyword("STRING$"));
    try std.testing.expect(isKeyword("REPLACE$"));
    try std.testing.expect(isKeyword("REVERSE$"));
    try std.testing.expect(isKeyword("TALLY"));
    try std.testing.expect(isKeyword("INSTRREV"));
    try std.testing.expect(isKeyword("INSERT$"));
    try std.testing.expect(isKeyword("DELETE$"));
    try std.testing.expect(isKeyword("REMOVE$"));
    try std.testing.expect(isKeyword("EXTRACT$"));
    try std.testing.expect(isKeyword("LPAD$"));
    try std.testing.expect(isKeyword("RPAD$"));
    try std.testing.expect(isKeyword("CENTER$"));
    try std.testing.expect(isKeyword("REPEAT$"));
    // Math functions
    try std.testing.expect(isKeyword("ABS"));
    try std.testing.expect(isKeyword("SQR"));
    try std.testing.expect(isKeyword("SIN"));
    try std.testing.expect(isKeyword("COS"));
    try std.testing.expect(isKeyword("TAN"));
    try std.testing.expect(isKeyword("LOG"));
    try std.testing.expect(isKeyword("EXP"));
    try std.testing.expect(isKeyword("RND"));
    try std.testing.expect(isKeyword("SGN"));
    try std.testing.expect(isKeyword("INT"));
    try std.testing.expect(isKeyword("FIX"));
    try std.testing.expect(isKeyword("CEIL"));
    try std.testing.expect(isKeyword("FLOOR"));
    try std.testing.expect(isKeyword("ROUND"));
    try std.testing.expect(isKeyword("POW"));
    try std.testing.expect(isKeyword("MAX"));
    try std.testing.expect(isKeyword("MIN"));
    try std.testing.expect(isKeyword("SUM"));
    try std.testing.expect(isKeyword("AVG"));
    try std.testing.expect(isKeyword("ATN"));
    try std.testing.expect(isKeyword("ATAN"));
    try std.testing.expect(isKeyword("ATAN2"));
    try std.testing.expect(isKeyword("ACOS"));
    try std.testing.expect(isKeyword("ASIN"));
    try std.testing.expect(isKeyword("HYPOT"));
    try std.testing.expect(isKeyword("CBRT"));
    // Error / misc
    try std.testing.expect(isKeyword("ERR"));
    try std.testing.expect(isKeyword("ERL"));
    try std.testing.expect(isKeyword("EOF"));
    try std.testing.expect(isKeyword("TIMER_MS"));
    try std.testing.expect(isKeyword("CSRLIN"));
    // I/O functions
    try std.testing.expect(isKeyword("MKI$"));
    try std.testing.expect(isKeyword("MKS$"));
    try std.testing.expect(isKeyword("MKD$"));
    try std.testing.expect(isKeyword("CVI"));
    try std.testing.expect(isKeyword("CVS"));
    try std.testing.expect(isKeyword("CVD"));
    try std.testing.expect(isKeyword("INPUT$"));
    try std.testing.expect(isKeyword("LOC"));
    // Mouse
    try std.testing.expect(isKeyword("MOUSE_X"));
    try std.testing.expect(isKeyword("MOUSE_Y"));
    try std.testing.expect(isKeyword("MOUSE_BUTTON"));
    try std.testing.expect(isKeyword("MOUSE_BUTTONS"));
    try std.testing.expect(isKeyword("MOUSE_POLL"));
    // GPU Sprites
    try std.testing.expect(isKeyword("SPRITE"));
    try std.testing.expect(isKeyword("SPRITEX"));
    try std.testing.expect(isKeyword("SPRITEY"));
    try std.testing.expect(isKeyword("SPRITEGETROT"));
    try std.testing.expect(isKeyword("SPRITEVISIBLE"));
    try std.testing.expect(isKeyword("SPRITEGETFRAME"));
    try std.testing.expect(isKeyword("SPRITEHIT"));
    try std.testing.expect(isKeyword("SPRITECOUNT"));
    try std.testing.expect(isKeyword("SPRITEOVERLAP"));
}

test "isKeyword binary search rejects non-keywords" {
    try std.testing.expect(!isKeyword("myVar"));
    try std.testing.expect(!isKeyword("MYVARIABLE"));
    try std.testing.expect(!isKeyword("FOOBAR"));
    try std.testing.expect(!isKeyword("SPRINT"));
    try std.testing.expect(!isKeyword(""));
    try std.testing.expect(!isKeyword("Z"));
    try std.testing.expect(!isKeyword("AAA"));
}

test "KEYWORDS array is sorted" {
    // Verify the binary search precondition: array must be strictly sorted
    var i: usize = 1;
    while (i < KEYWORDS.len) : (i += 1) {
        const prev = KEYWORDS[i - 1];
        const curr = KEYWORDS[i];
        const ord = std.mem.order(u8, prev, curr);
        if (ord != .lt) {
            std.debug.print("KEYWORDS not sorted at index {d}: \"{s}\" >= \"{s}\"\n", .{ i, prev, curr });
        }
        try std.testing.expect(ord == .lt);
    }
}

test "LET keyword warns on keyword variable name" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    const line = toU32("LET STEP = 1");
    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;
    idx.scanLine(&line, 0, &cls, &cls_len, &sk);

    try std.testing.expectEqual(@as(usize, 1), idx.warnings.items.len);
    const w = &idx.warnings.items[0];
    try std.testing.expectEqualStrings("STEP", w.getName());
    try std.testing.expectEqualStrings("LET", w.getDecl());
    try std.testing.expectEqual(@as(u32, 0), w.line);
    try std.testing.expectEqual(@as(u16, 4), w.col);
}

test "LET with safe variable produces no warning" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    const line = toU32("LET myCounter = 42");
    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;
    idx.scanLine(&line, 0, &cls, &cls_len, &sk);

    try std.testing.expectEqual(@as(usize, 0), idx.warnings.items.len);
}

test "DIM keyword warns on keyword array name" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    const line = toU32("DIM LINE(200)");
    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;
    idx.scanLine(&line, 0, &cls, &cls_len, &sk);

    try std.testing.expectEqual(@as(usize, 1), idx.warnings.items.len);
    try std.testing.expectEqualStrings("LINE", idx.warnings.items[0].getName());
    try std.testing.expectEqualStrings("DIM", idx.warnings.items[0].getDecl());
}

test "DIM with type suffix warns on keyword name" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    // LEFT$ is a keyword — DIM LEFT$(100) should warn
    const line = toU32("DIM LEFT$(100)");
    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;
    idx.scanLine(&line, 0, &cls, &cls_len, &sk);

    try std.testing.expectEqual(@as(usize, 1), idx.warnings.items.len);
    try std.testing.expectEqualStrings("LEFT$", idx.warnings.items[0].getName());
}

test "DIM with safe variable produces no warning" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    const line = toU32("DIM myArray(200)");
    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;
    idx.scanLine(&line, 0, &cls, &cls_len, &sk);

    try std.testing.expectEqual(@as(usize, 0), idx.warnings.items.len);
}

test "REDIM keyword warns on keyword variable name" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    const line = toU32("REDIM PRINT(500)");
    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;
    idx.scanLine(&line, 0, &cls, &cls_len, &sk);

    try std.testing.expectEqual(@as(usize, 1), idx.warnings.items.len);
    try std.testing.expectEqualStrings("PRINT", idx.warnings.items[0].getName());
    try std.testing.expectEqualStrings("REDIM", idx.warnings.items[0].getDecl());
}

test "LOCAL keyword warns on keyword variable name" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    const line = toU32("LOCAL COLOR");
    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;
    idx.scanLine(&line, 0, &cls, &cls_len, &sk);

    try std.testing.expectEqual(@as(usize, 1), idx.warnings.items.len);
    try std.testing.expectEqualStrings("COLOR", idx.warnings.items[0].getName());
    try std.testing.expectEqualStrings("LOCAL", idx.warnings.items[0].getDecl());
}

test "keyword shadow is case-insensitive" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    // lowercase 'step' should still match keyword STEP
    const line = toU32("LET step = 10");
    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;
    idx.scanLine(&line, 3, &cls, &cls_len, &sk);

    try std.testing.expectEqual(@as(usize, 1), idx.warnings.items.len);
    try std.testing.expectEqualStrings("STEP", idx.warnings.items[0].getName());
    try std.testing.expectEqual(@as(u32, 3), idx.warnings.items[0].line);
}

test "keyword shadow warning formatMessage" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    const line = toU32("DIM CIRCLE(100)");
    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;
    idx.scanLine(&line, 7, &cls, &cls_len, &sk);

    try std.testing.expectEqual(@as(usize, 1), idx.warnings.items.len);
    var msg_buf: [256]u8 = undefined;
    const msg = idx.warnings.items[0].formatMessage(&msg_buf);
    try std.testing.expect(msg.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, msg, "CIRCLE") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "shadows keyword") != null);
}

test "multiple keyword shadows detected in rebuild" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;

    const line1 = toU32("LET STEP = 1");
    const line2 = toU32("DIM LINE(50)");
    const line3 = toU32("LOCAL COLOR");
    const line4 = toU32("LET myVar = 5");
    const line5 = toU32("REDIM FOR(10)");
    idx.scanLine(&line1, 0, &cls, &cls_len, &sk);
    idx.scanLine(&line2, 1, &cls, &cls_len, &sk);
    idx.scanLine(&line3, 2, &cls, &cls_len, &sk);
    idx.scanLine(&line4, 3, &cls, &cls_len, &sk);
    idx.scanLine(&line5, 4, &cls, &cls_len, &sk);

    // Lines 0,1,2,4 should warn; line 3 (myVar) should not
    try std.testing.expectEqual(@as(usize, 4), idx.warnings.items.len);
    try std.testing.expectEqualStrings("STEP", idx.warnings.items[0].getName());
    try std.testing.expectEqualStrings("LINE", idx.warnings.items[1].getName());
    try std.testing.expectEqualStrings("COLOR", idx.warnings.items[2].getName());
    try std.testing.expectEqualStrings("FOR", idx.warnings.items[3].getName());
}

test "SUB with keyword name warns" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    const line = toU32("SUB PRINT()");
    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;
    idx.scanLine(&line, 5, &cls, &cls_len, &sk);

    // Should produce both a symbol entry AND a warning
    try std.testing.expectEqual(@as(usize, 1), idx.count());
    try std.testing.expectEqual(@as(usize, 1), idx.warnings.items.len);
    try std.testing.expectEqualStrings("PRINT", idx.warnings.items[0].getName());
    try std.testing.expectEqualStrings("SUB", idx.warnings.items[0].getDecl());
}

test "FUNCTION with keyword name warns" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    const line = toU32("FUNCTION LEN(s AS STRING) AS INTEGER");
    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;
    idx.scanLine(&line, 10, &cls, &cls_len, &sk);

    try std.testing.expectEqual(@as(usize, 1), idx.count());
    try std.testing.expectEqual(@as(usize, 1), idx.warnings.items.len);
    try std.testing.expectEqualStrings("LEN", idx.warnings.items[0].getName());
    try std.testing.expectEqualStrings("FUNCTION", idx.warnings.items[0].getDecl());
}

test "WORKER with keyword name warns" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    const line = toU32("WORKER TIMER");
    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;
    idx.scanLine(&line, 0, &cls, &cls_len, &sk);

    try std.testing.expectEqual(@as(usize, 1), idx.count());
    try std.testing.expectEqual(@as(usize, 1), idx.warnings.items.len);
    try std.testing.expectEqualStrings("TIMER", idx.warnings.items[0].getName());
    try std.testing.expectEqualStrings("WORKER", idx.warnings.items[0].getDecl());
}

test "CLASS with keyword name warns" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    const line = toU32("CLASS STRING");
    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;
    idx.scanLine(&line, 0, &cls, &cls_len, &sk);

    try std.testing.expectEqual(@as(usize, 1), idx.count());
    try std.testing.expectEqual(@as(usize, 1), idx.warnings.items.len);
    try std.testing.expectEqualStrings("STRING", idx.warnings.items[0].getName());
    try std.testing.expectEqualStrings("CLASS", idx.warnings.items[0].getDecl());
}

test "TYPE with keyword name warns" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    const line = toU32("TYPE CIRCLE");
    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;
    idx.scanLine(&line, 0, &cls, &cls_len, &sk);

    try std.testing.expectEqual(@as(usize, 1), idx.count());
    try std.testing.expectEqual(@as(usize, 1), idx.warnings.items.len);
    try std.testing.expectEqualStrings("CIRCLE", idx.warnings.items[0].getName());
    try std.testing.expectEqualStrings("TYPE", idx.warnings.items[0].getDecl());
}

test "METHOD with keyword name does NOT warn (own namespace)" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    // First set up a class scope
    const line1 = toU32("CLASS Shape");
    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;
    idx.scanLine(&line1, 0, &cls, &cls_len, &sk);

    // METHOD LINE inside a class should NOT produce a keyword shadow warning
    const line2 = toU32("  METHOD LINE(x1, y1, x2, y2)");
    idx.scanLine(&line2, 1, &cls, &cls_len, &sk);

    // CLASS Shape + METHOD LINE = 2 symbols, but only CLASS warns (not METHOD)
    try std.testing.expectEqual(@as(usize, 2), idx.count());
    // Only 1 warning — for CLASS Shape? No, Shape is not a keyword. 0 warnings.
    try std.testing.expectEqual(@as(usize, 0), idx.warnings.items.len);
}

test "SUB with safe name does not warn" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    const line = toU32("SUB DrawSprite(id AS INTEGER)");
    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;
    idx.scanLine(&line, 0, &cls, &cls_len, &sk);

    try std.testing.expectEqual(@as(usize, 1), idx.count());
    try std.testing.expectEqual(@as(usize, 0), idx.warnings.items.len);
}

test "LET with built-in function name warns" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    const line = toU32("LET VAL = 42");
    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;
    idx.scanLine(&line, 0, &cls, &cls_len, &sk);

    try std.testing.expectEqual(@as(usize, 1), idx.warnings.items.len);
    try std.testing.expectEqualStrings("VAL", idx.warnings.items[0].getName());
}

test "DIM with built-in function name warns" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    const line = toU32("DIM LEN(100)");
    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;
    idx.scanLine(&line, 0, &cls, &cls_len, &sk);

    try std.testing.expectEqual(@as(usize, 1), idx.warnings.items.len);
    try std.testing.expectEqualStrings("LEN", idx.warnings.items[0].getName());
}

test "FUNCTION shadowing built-in function warns" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    const line = toU32("FUNCTION ABS(x AS DOUBLE) AS DOUBLE");
    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;
    idx.scanLine(&line, 0, &cls, &cls_len, &sk);

    try std.testing.expectEqual(@as(usize, 1), idx.count());
    try std.testing.expectEqual(@as(usize, 1), idx.warnings.items.len);
    try std.testing.expectEqualStrings("ABS", idx.warnings.items[0].getName());
    try std.testing.expectEqualStrings("FUNCTION", idx.warnings.items[0].getDecl());
}

test "indented LET keyword shadow detected" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    // Indented code inside a SUB
    const line = toU32("    LET TIMER = 0");
    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;
    idx.scanLine(&line, 12, &cls, &cls_len, &sk);

    try std.testing.expectEqual(@as(usize, 1), idx.warnings.items.len);
    try std.testing.expectEqualStrings("TIMER", idx.warnings.items[0].getName());
    try std.testing.expectEqual(@as(u16, 8), idx.warnings.items[0].col);
}

test "warnings cleared on rebuild" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;

    const line = toU32("LET STEP = 1");
    idx.scanLine(&line, 0, &cls, &cls_len, &sk);
    try std.testing.expectEqual(@as(usize, 1), idx.warnings.items.len);

    // clear() should also clear warnings
    idx.clear();
    try std.testing.expectEqual(@as(usize, 0), idx.warnings.items.len);
}

// ── TYPE field scanning tests ───────────────────────────────────────────────

test "TYPE fields are detected" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;

    const line1 = toU32("TYPE Vector2D");
    idx.scanLine(&line1, 0, &cls, &cls_len, &sk);
    try std.testing.expectEqual(ScopeKind.type_decl, sk);

    const line2 = toU32("  x AS DOUBLE");
    idx.scanLine(&line2, 1, &cls, &cls_len, &sk);

    const line3 = toU32("  y AS DOUBLE");
    idx.scanLine(&line3, 2, &cls, &cls_len, &sk);

    const line4 = toU32("END TYPE");
    idx.scanLine(&line4, 3, &cls, &cls_len, &sk);
    try std.testing.expectEqual(ScopeKind.none, sk);

    // Should have 2 type fields
    try std.testing.expectEqual(@as(usize, 2), idx.type_fields.items.len);

    const f0 = &idx.type_fields.items[0];
    try std.testing.expectEqualStrings("VECTOR2D", f0.getTypeName());
    try std.testing.expectEqualStrings("x", f0.getFieldName());
    try std.testing.expectEqualStrings("DOUBLE", f0.getFieldType());

    const f1 = &idx.type_fields.items[1];
    try std.testing.expectEqualStrings("VECTOR2D", f1.getTypeName());
    try std.testing.expectEqualStrings("y", f1.getFieldName());
    try std.testing.expectEqualStrings("DOUBLE", f1.getFieldType());
}

test "TYPE field without AS type" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;

    const line1 = toU32("TYPE Simple");
    idx.scanLine(&line1, 0, &cls, &cls_len, &sk);

    const line2 = toU32("  value");
    idx.scanLine(&line2, 1, &cls, &cls_len, &sk);

    const line3 = toU32("END TYPE");
    idx.scanLine(&line3, 2, &cls, &cls_len, &sk);

    try std.testing.expectEqual(@as(usize, 1), idx.type_fields.items.len);
    try std.testing.expectEqualStrings("SIMPLE", idx.type_fields.items[0].getTypeName());
    try std.testing.expectEqualStrings("value", idx.type_fields.items[0].getFieldName());
    try std.testing.expectEqual(@as(u8, 0), idx.type_fields.items[0].field_type_len);
}

test "TYPE fields with nested type" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;

    const l1 = toU32("TYPE Vector2D");
    idx.scanLine(&l1, 0, &cls, &cls_len, &sk);
    const l2 = toU32("  x AS DOUBLE");
    idx.scanLine(&l2, 1, &cls, &cls_len, &sk);
    const l3 = toU32("  y AS DOUBLE");
    idx.scanLine(&l3, 2, &cls, &cls_len, &sk);
    const l4 = toU32("END TYPE");
    idx.scanLine(&l4, 3, &cls, &cls_len, &sk);

    const l5 = toU32("TYPE Player");
    idx.scanLine(&l5, 4, &cls, &cls_len, &sk);
    const l6 = toU32("  name AS STRING");
    idx.scanLine(&l6, 5, &cls, &cls_len, &sk);
    const l7 = toU32("  pos AS Vector2D");
    idx.scanLine(&l7, 6, &cls, &cls_len, &sk);
    const l8 = toU32("  health AS INTEGER");
    idx.scanLine(&l8, 7, &cls, &cls_len, &sk);
    const l9 = toU32("END TYPE");
    idx.scanLine(&l9, 8, &cls, &cls_len, &sk);

    // Vector2D has 2 fields, Player has 3 fields = 5 total
    try std.testing.expectEqual(@as(usize, 5), idx.type_fields.items.len);

    // Check Player fields
    var player_count: usize = 0;
    for (idx.type_fields.items) |*tf| {
        if (std.mem.eql(u8, tf.getTypeName(), "PLAYER")) {
            player_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), player_count);
}

test "CLASS fields are detected" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;

    const l1 = toU32("CLASS Animal");
    idx.scanLine(&l1, 0, &cls, &cls_len, &sk);
    try std.testing.expectEqual(ScopeKind.class_decl, sk);

    const l2 = toU32("  name AS STRING");
    idx.scanLine(&l2, 1, &cls, &cls_len, &sk);

    const l3 = toU32("  age AS INTEGER");
    idx.scanLine(&l3, 2, &cls, &cls_len, &sk);

    const l4 = toU32("  METHOD Speak()");
    idx.scanLine(&l4, 3, &cls, &cls_len, &sk);

    const l5 = toU32("  END METHOD");
    idx.scanLine(&l5, 4, &cls, &cls_len, &sk);

    const l6 = toU32("END CLASS");
    idx.scanLine(&l6, 5, &cls, &cls_len, &sk);

    // 2 fields for CLASS Animal
    try std.testing.expectEqual(@as(usize, 2), idx.type_fields.items.len);
    try std.testing.expectEqualStrings("ANIMAL", idx.type_fields.items[0].getTypeName());
    try std.testing.expectEqualStrings("name", idx.type_fields.items[0].getFieldName());
    try std.testing.expectEqualStrings("STRING", idx.type_fields.items[0].getFieldType());
}

test "fields cleared on index clear" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;

    const l1 = toU32("TYPE Foo");
    idx.scanLine(&l1, 0, &cls, &cls_len, &sk);
    const l2 = toU32("  bar AS INTEGER");
    idx.scanLine(&l2, 1, &cls, &cls_len, &sk);

    try std.testing.expectEqual(@as(usize, 1), idx.type_fields.items.len);
    idx.clear();
    try std.testing.expectEqual(@as(usize, 0), idx.type_fields.items.len);
}

// ── DIM variable type tracking tests ────────────────────────────────────────

test "DIM var AS typename records var type" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;

    const line = toU32("DIM pos AS Vector2D");
    idx.scanLine(&line, 0, &cls, &cls_len, &sk);

    try std.testing.expectEqual(@as(usize, 1), idx.var_types.items.len);
    try std.testing.expectEqualStrings("POS", idx.var_types.items[0].getVarName());
    try std.testing.expectEqualStrings("VECTOR2D", idx.var_types.items[0].getTypeName());
}

test "LOCAL var AS typename records var type" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;

    const line = toU32("LOCAL obj AS Player");
    idx.scanLine(&line, 5, &cls, &cls_len, &sk);

    try std.testing.expectEqual(@as(usize, 1), idx.var_types.items.len);
    try std.testing.expectEqualStrings("OBJ", idx.var_types.items[0].getVarName());
    try std.testing.expectEqualStrings("PLAYER", idx.var_types.items[0].getTypeName());
    try std.testing.expectEqual(@as(u32, 5), idx.var_types.items[0].line);
}

test "DIM var AS HASHMAP records type" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;

    const line = toU32("DIM cache AS HASHMAP");
    idx.scanLine(&line, 0, &cls, &cls_len, &sk);

    try std.testing.expectEqual(@as(usize, 1), idx.var_types.items.len);
    try std.testing.expectEqualStrings("CACHE", idx.var_types.items[0].getVarName());
    try std.testing.expectEqualStrings("HASHMAP", idx.var_types.items[0].getTypeName());
}

test "DIM var AS LIST records type" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;

    const line = toU32("DIM items AS LIST");
    idx.scanLine(&line, 0, &cls, &cls_len, &sk);

    try std.testing.expectEqual(@as(usize, 1), idx.var_types.items.len);
    try std.testing.expectEqualStrings("ITEMS", idx.var_types.items[0].getVarName());
    try std.testing.expectEqualStrings("LIST", idx.var_types.items[0].getTypeName());
}

test "DIM var AS INTEGER does NOT record var type (primitive)" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;

    const line = toU32("DIM count AS INTEGER");
    idx.scanLine(&line, 0, &cls, &cls_len, &sk);

    try std.testing.expectEqual(@as(usize, 0), idx.var_types.items.len);
}

test "DIM var AS STRING does NOT record var type (primitive)" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;

    const line = toU32("DIM name AS STRING");
    idx.scanLine(&line, 0, &cls, &cls_len, &sk);

    try std.testing.expectEqual(@as(usize, 0), idx.var_types.items.len);
}

test "DIM with array bounds and AS typename records type" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;

    const line = toU32("DIM enemies(10) AS Monster");
    idx.scanLine(&line, 0, &cls, &cls_len, &sk);

    try std.testing.expectEqual(@as(usize, 1), idx.var_types.items.len);
    try std.testing.expectEqualStrings("ENEMIES", idx.var_types.items[0].getVarName());
    try std.testing.expectEqualStrings("MONSTER", idx.var_types.items[0].getTypeName());
}

test "DIM without AS does not record var type" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;

    const line = toU32("DIM x = 42");
    idx.scanLine(&line, 0, &cls, &cls_len, &sk);

    try std.testing.expectEqual(@as(usize, 0), idx.var_types.items.len);
}

test "var types cleared on index clear" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;

    const line = toU32("DIM h AS HASHMAP");
    idx.scanLine(&line, 0, &cls, &cls_len, &sk);
    try std.testing.expectEqual(@as(usize, 1), idx.var_types.items.len);

    idx.clear();
    try std.testing.expectEqual(@as(usize, 0), idx.var_types.items.len);
}

test "lookupVarType finds recorded type" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;

    const l1 = toU32("DIM cache AS HASHMAP");
    idx.scanLine(&l1, 0, &cls, &cls_len, &sk);
    const l2 = toU32("DIM pos AS Vector2D");
    idx.scanLine(&l2, 1, &cls, &cls_len, &sk);

    const t1 = idx.lookupVarType("CACHE");
    try std.testing.expect(t1 != null);
    try std.testing.expectEqualStrings("HASHMAP", t1.?);

    const t2 = idx.lookupVarType("POS");
    try std.testing.expect(t2 != null);
    try std.testing.expectEqualStrings("VECTOR2D", t2.?);

    const t3 = idx.lookupVarType("NONEXIST");
    try std.testing.expect(t3 == null);
}

// ── Dot-completion tests ────────────────────────────────────────────────────

test "dotCompletions for HASHMAP variable" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;

    const line = toU32("DIM cache AS HASHMAP");
    idx.scanLine(&line, 0, &cls, &cls_len, &sk);

    var completions: [MAX_DOT_COMPLETIONS]DotCompletion = undefined;
    const count = idx.dotCompletions("CACHE", &completions);

    try std.testing.expectEqual(HASHMAP_METHODS.len, count);
    // Verify all HASHMAP methods are present
    for (HASHMAP_METHODS) |expected| {
        var found = false;
        for (completions[0..count]) |*c| {
            if (std.mem.eql(u8, c.getName(), expected)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "dotCompletions for LIST variable" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;

    const line = toU32("DIM items AS LIST");
    idx.scanLine(&line, 0, &cls, &cls_len, &sk);

    var completions: [MAX_DOT_COMPLETIONS]DotCompletion = undefined;
    const count = idx.dotCompletions("ITEMS", &completions);

    try std.testing.expectEqual(LIST_METHODS.len, count);
    // Check a few specific ones
    var found_append = false;
    var found_length = false;
    var found_pop = false;
    for (completions[0..count]) |*c| {
        if (std.mem.eql(u8, c.getName(), "APPEND")) found_append = true;
        if (std.mem.eql(u8, c.getName(), "LENGTH")) found_length = true;
        if (std.mem.eql(u8, c.getName(), "POP")) found_pop = true;
    }
    try std.testing.expect(found_append);
    try std.testing.expect(found_length);
    try std.testing.expect(found_pop);
}

test "dotCompletions for TYPE variable returns fields" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;

    // Define TYPE
    const l1 = toU32("TYPE Vector2D");
    idx.scanLine(&l1, 0, &cls, &cls_len, &sk);
    const l2 = toU32("  x AS DOUBLE");
    idx.scanLine(&l2, 1, &cls, &cls_len, &sk);
    const l3 = toU32("  y AS DOUBLE");
    idx.scanLine(&l3, 2, &cls, &cls_len, &sk);
    const l4 = toU32("END TYPE");
    idx.scanLine(&l4, 3, &cls, &cls_len, &sk);

    // Declare variable of that type
    const l5 = toU32("DIM pos AS Vector2D");
    idx.scanLine(&l5, 4, &cls, &cls_len, &sk);
    idx.buildSortedIndices();

    var completions: [MAX_DOT_COMPLETIONS]DotCompletion = undefined;
    const count = idx.dotCompletions("POS", &completions);

    try std.testing.expectEqual(@as(usize, 2), count);

    // Should contain x and y
    var found_x = false;
    var found_y = false;
    for (completions[0..count]) |*c| {
        if (std.mem.eql(u8, c.getName(), "x")) found_x = true;
        if (std.mem.eql(u8, c.getName(), "y")) found_y = true;
    }
    try std.testing.expect(found_x);
    try std.testing.expect(found_y);
}

test "dotCompletions for CLASS variable returns methods" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;

    // Define CLASS with fields and methods
    const l1 = toU32("CLASS Player");
    idx.scanLine(&l1, 0, &cls, &cls_len, &sk);
    const l2 = toU32("  name AS STRING");
    idx.scanLine(&l2, 1, &cls, &cls_len, &sk);
    const l3 = toU32("  health AS INTEGER");
    idx.scanLine(&l3, 2, &cls, &cls_len, &sk);
    const l4 = toU32("  METHOD Move(dx AS INTEGER)");
    idx.scanLine(&l4, 3, &cls, &cls_len, &sk);
    const l5 = toU32("  METHOD Attack() AS INTEGER");
    idx.scanLine(&l5, 4, &cls, &cls_len, &sk);
    const l6 = toU32("  CONSTRUCTOR(n AS STRING)");
    idx.scanLine(&l6, 5, &cls, &cls_len, &sk);
    const l7 = toU32("END CLASS");
    idx.scanLine(&l7, 6, &cls, &cls_len, &sk);

    // Declare variable
    const l8 = toU32("DIM hero AS Player");
    idx.scanLine(&l8, 7, &cls, &cls_len, &sk);
    idx.buildSortedIndices();

    var completions: [MAX_DOT_COMPLETIONS]DotCompletion = undefined;
    const count = idx.dotCompletions("HERO", &completions);

    // Should have: name, health (fields) + Move, Attack (methods) = 4
    // CONSTRUCTOR should be excluded
    try std.testing.expectEqual(@as(usize, 4), count);

    var found_name = false;
    var found_health = false;
    var found_move = false;
    var found_attack = false;
    var found_constructor = false;
    for (completions[0..count]) |*c| {
        if (std.mem.eql(u8, c.getName(), "name")) found_name = true;
        if (std.mem.eql(u8, c.getName(), "health")) found_health = true;
        if (std.mem.eql(u8, c.getName(), "Move")) found_move = true;
        if (std.mem.eql(u8, c.getName(), "Attack")) found_attack = true;
        if (std.mem.eql(u8, c.getName(), "CONSTRUCTOR")) found_constructor = true;
    }
    try std.testing.expect(found_name);
    try std.testing.expect(found_health);
    try std.testing.expect(found_move);
    try std.testing.expect(found_attack);
    try std.testing.expect(!found_constructor);
}

test "CLASS method body code does not leak into dot completions" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;

    // Define CLASS with fields, methods that contain code statements
    const l1 = toU32("CLASS Cat");
    idx.scanLine(&l1, 0, &cls, &cls_len, &sk);
    const l2 = toU32("    name AS STRING");
    idx.scanLine(&l2, 1, &cls, &cls_len, &sk);
    const l3 = toU32("    lives AS INTEGER");
    idx.scanLine(&l3, 2, &cls, &cls_len, &sk);
    const l4 = toU32("    METHOD Meow()");
    idx.scanLine(&l4, 3, &cls, &cls_len, &sk);
    try std.testing.expectEqual(ScopeKind.method_body, sk);
    const l5 = toU32("        PRINT name & \" says MEOW!\"");
    idx.scanLine(&l5, 4, &cls, &cls_len, &sk);
    const l6 = toU32("        IF lives > 0 THEN");
    idx.scanLine(&l6, 5, &cls, &cls_len, &sk);
    const l7 = toU32("            PRINT \"still alive\"");
    idx.scanLine(&l7, 6, &cls, &cls_len, &sk);
    const l8 = toU32("        END IF");
    idx.scanLine(&l8, 7, &cls, &cls_len, &sk);
    const l9 = toU32("    END METHOD");
    idx.scanLine(&l9, 8, &cls, &cls_len, &sk);
    try std.testing.expectEqual(ScopeKind.class_decl, sk);
    const l10 = toU32("    METHOD Purr(volume AS INTEGER)");
    idx.scanLine(&l10, 9, &cls, &cls_len, &sk);
    try std.testing.expectEqual(ScopeKind.method_body, sk);
    const l11 = toU32("        PRINT name & \" purrs at \" & STR$(volume)");
    idx.scanLine(&l11, 10, &cls, &cls_len, &sk);
    const l12 = toU32("        FOR i = 1 TO volume");
    idx.scanLine(&l12, 11, &cls, &cls_len, &sk);
    const l13 = toU32("            PRINT \"purrr\"");
    idx.scanLine(&l13, 12, &cls, &cls_len, &sk);
    const l14 = toU32("        NEXT i");
    idx.scanLine(&l14, 13, &cls, &cls_len, &sk);
    const l15 = toU32("    END METHOD");
    idx.scanLine(&l15, 14, &cls, &cls_len, &sk);
    try std.testing.expectEqual(ScopeKind.class_decl, sk);
    // Field declared after methods should still work
    const l15b = toU32("    mood AS STRING");
    idx.scanLine(&l15b, 15, &cls, &cls_len, &sk);
    const l16 = toU32("END CLASS");
    idx.scanLine(&l16, 16, &cls, &cls_len, &sk);
    try std.testing.expectEqual(ScopeKind.none, sk);

    // DIM a cat
    const l17 = toU32("DIM mittens AS Cat");
    idx.scanLine(&l17, 17, &cls, &cls_len, &sk);

    var completions: [MAX_DOT_COMPLETIONS]DotCompletion = undefined;
    const count = idx.dotCompletions("MITTENS", &completions);

    // Should have: name, lives, mood (fields) + Meow, Purr (methods) = 5
    // Must NOT have: PRINT, IF, FOR, NEXT, STR$, END, etc.
    try std.testing.expectEqual(@as(usize, 5), count);

    var found_name = false;
    var found_lives = false;
    var found_mood = false;
    var found_meow = false;
    var found_purr = false;
    var found_print = false;
    var found_if = false;
    var found_for = false;
    for (completions[0..count]) |*c| {
        const n = c.getNameUpper();
        if (std.mem.eql(u8, n, "NAME")) found_name = true;
        if (std.mem.eql(u8, n, "LIVES")) found_lives = true;
        if (std.mem.eql(u8, n, "MOOD")) found_mood = true;
        if (std.mem.eql(u8, n, "MEOW")) found_meow = true;
        if (std.mem.eql(u8, n, "PURR")) found_purr = true;
        if (std.mem.eql(u8, n, "PRINT")) found_print = true;
        if (std.mem.eql(u8, n, "IF")) found_if = true;
        if (std.mem.eql(u8, n, "FOR")) found_for = true;
    }
    try std.testing.expect(found_name);
    try std.testing.expect(found_lives);
    try std.testing.expect(found_mood);
    try std.testing.expect(found_meow);
    try std.testing.expect(found_purr);
    // These MUST NOT appear — they are code inside method bodies, not fields
    try std.testing.expect(!found_print);
    try std.testing.expect(!found_if);
    try std.testing.expect(!found_for);
}

test "dotCompletions for unknown variable returns 0" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var completions: [MAX_DOT_COMPLETIONS]DotCompletion = undefined;
    const count = idx.dotCompletions("NONEXIST", &completions);
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "dotCompletionsForType for HASHMAP" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var completions: [MAX_DOT_COMPLETIONS]DotCompletion = undefined;
    const count = idx.dotCompletionsForType("HASHMAP", &completions);
    try std.testing.expectEqual(HASHMAP_METHODS.len, count);
}

test "dotCompletionsForType for LIST" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var completions: [MAX_DOT_COMPLETIONS]DotCompletion = undefined;
    const count = idx.dotCompletionsForType("LIST", &completions);
    try std.testing.expectEqual(LIST_METHODS.len, count);
}

test "multiple DIM AS declarations tracked" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;

    const l1 = toU32("DIM cache AS HASHMAP");
    idx.scanLine(&l1, 0, &cls, &cls_len, &sk);
    const l2 = toU32("DIM items AS LIST");
    idx.scanLine(&l2, 1, &cls, &cls_len, &sk);
    const l3 = toU32("DIM pos AS Vector2D");
    idx.scanLine(&l3, 2, &cls, &cls_len, &sk);
    const l4 = toU32("DIM count AS INTEGER");
    idx.scanLine(&l4, 3, &cls, &cls_len, &sk);

    // 3 entries (INTEGER is filtered as primitive)
    try std.testing.expectEqual(@as(usize, 3), idx.var_types.items.len);
}

test "HASHMAP_METHODS are sorted" {
    var i: usize = 1;
    while (i < HASHMAP_METHODS.len) : (i += 1) {
        const prev = HASHMAP_METHODS[i - 1];
        const curr = HASHMAP_METHODS[i];
        const ord = std.mem.order(u8, prev, curr);
        try std.testing.expect(ord == .lt);
    }
}

test "LIST_METHODS are sorted" {
    var i: usize = 1;
    while (i < LIST_METHODS.len) : (i += 1) {
        const prev = LIST_METHODS[i - 1];
        const curr = LIST_METHODS[i];
        const ord = std.mem.order(u8, prev, curr);
        try std.testing.expect(ord == .lt);
    }
}

test "BUILTIN_TYPES are sorted" {
    var i: usize = 1;
    while (i < BUILTIN_TYPES.len) : (i += 1) {
        const prev = BUILTIN_TYPES[i - 1];
        const curr = BUILTIN_TYPES[i];
        const ord = std.mem.order(u8, prev, curr);
        try std.testing.expect(ord == .lt);
    }
}

test "typeCompletions returns built-in types when no user types" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var completions: [MAX_DOT_COMPLETIONS]DotCompletion = undefined;
    const count = idx.typeCompletions(&completions);

    // Should have exactly the built-in types
    try std.testing.expectEqual(BUILTIN_TYPES.len, count);

    // Verify all are type_name kind
    for (completions[0..count]) |*c| {
        try std.testing.expectEqual(@as(@TypeOf(c.kind), .type_name), c.kind);
    }

    // Verify INTEGER is present
    var found_integer = false;
    for (completions[0..count]) |*c| {
        if (std.mem.eql(u8, c.name_upper[0..c.name_len], "INTEGER")) {
            found_integer = true;
            try std.testing.expectEqualStrings("built-in", c.extra[0..c.extra_len]);
        }
    }
    try std.testing.expect(found_integer);
}

test "typeCompletions includes user TYPE and CLASS names" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;

    const l1 = toU32("TYPE Vector2D");
    idx.scanLine(&l1, 0, &cls, &cls_len, &sk);
    const l2 = toU32("    x AS INTEGER");
    idx.scanLine(&l2, 1, &cls, &cls_len, &sk);
    const l3 = toU32("END TYPE");
    idx.scanLine(&l3, 2, &cls, &cls_len, &sk);

    const l4 = toU32("CLASS Player");
    idx.scanLine(&l4, 3, &cls, &cls_len, &sk);
    const l5 = toU32("END CLASS");
    idx.scanLine(&l5, 4, &cls, &cls_len, &sk);

    var completions: [MAX_DOT_COMPLETIONS]DotCompletion = undefined;
    const count = idx.typeCompletions(&completions);

    // Should have built-in types + Vector2D + Player
    try std.testing.expectEqual(BUILTIN_TYPES.len + 2, count);

    // Verify Vector2D is present with "TYPE" extra
    var found_vec = false;
    var found_player = false;
    for (completions[0..count]) |*c| {
        const name = c.name_upper[0..c.name_len];
        if (std.mem.eql(u8, name, "VECTOR2D")) {
            found_vec = true;
            try std.testing.expectEqualStrings("TYPE", c.extra[0..c.extra_len]);
        }
        if (std.mem.eql(u8, name, "PLAYER")) {
            found_player = true;
            try std.testing.expectEqualStrings("CLASS", c.extra[0..c.extra_len]);
        }
    }
    try std.testing.expect(found_vec);
    try std.testing.expect(found_player);
}

test "typeCompletions does not duplicate built-in type names" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    // If someone defines a TYPE named INTEGER (unusual but possible),
    // it should not appear twice.
    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;

    const l1 = toU32("TYPE INTEGER");
    idx.scanLine(&l1, 0, &cls, &cls_len, &sk);
    const l2 = toU32("END TYPE");
    idx.scanLine(&l2, 1, &cls, &cls_len, &sk);

    var completions: [MAX_DOT_COMPLETIONS]DotCompletion = undefined;
    const count = idx.typeCompletions(&completions);

    // Should still be only BUILTIN_TYPES.len (user INTEGER is a dup)
    try std.testing.expectEqual(BUILTIN_TYPES.len, count);
}

// ─── Nested UDT tests ──────────────────────────────────────────────────────

test "lookupFieldType returns field type for known TYPE field" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;

    const l1 = toU32("TYPE Vector2D");
    idx.scanLine(&l1, 0, &cls, &cls_len, &sk);
    const l2 = toU32("    x AS INTEGER");
    idx.scanLine(&l2, 1, &cls, &cls_len, &sk);
    const l3 = toU32("    y AS INTEGER");
    idx.scanLine(&l3, 2, &cls, &cls_len, &sk);
    const l4 = toU32("END TYPE");
    idx.scanLine(&l4, 3, &cls, &cls_len, &sk);

    // Known field with type
    const ft = idx.lookupFieldType("VECTOR2D", "X");
    try std.testing.expect(ft != null);
    try std.testing.expectEqualStrings("INTEGER", ft.?);

    const ft2 = idx.lookupFieldType("VECTOR2D", "Y");
    try std.testing.expect(ft2 != null);
    try std.testing.expectEqualStrings("INTEGER", ft2.?);

    // Unknown field
    const ft3 = idx.lookupFieldType("VECTOR2D", "Z");
    try std.testing.expect(ft3 == null);

    // Unknown type
    const ft4 = idx.lookupFieldType("NONEXIST", "X");
    try std.testing.expect(ft4 == null);
}

test "lookupFieldType returns UDT field type for nested TYPE" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;

    // Define Vector2D
    const l1 = toU32("TYPE Vector2D");
    idx.scanLine(&l1, 0, &cls, &cls_len, &sk);
    const l2 = toU32("    x AS INTEGER");
    idx.scanLine(&l2, 1, &cls, &cls_len, &sk);
    const l3 = toU32("    y AS INTEGER");
    idx.scanLine(&l3, 2, &cls, &cls_len, &sk);
    const l4 = toU32("END TYPE");
    idx.scanLine(&l4, 3, &cls, &cls_len, &sk);

    // Define Player with a Vector2D field
    const l5 = toU32("TYPE Player");
    idx.scanLine(&l5, 4, &cls, &cls_len, &sk);
    const l6 = toU32("    name AS STRING");
    idx.scanLine(&l6, 5, &cls, &cls_len, &sk);
    const l7 = toU32("    position AS Vector2D");
    idx.scanLine(&l7, 6, &cls, &cls_len, &sk);
    const l8 = toU32("END TYPE");
    idx.scanLine(&l8, 7, &cls, &cls_len, &sk);

    // position field should have type VECTOR2D
    const ft = idx.lookupFieldType("PLAYER", "POSITION");
    try std.testing.expect(ft != null);
    try std.testing.expectEqualStrings("VECTOR2D", ft.?);

    // name field should have type STRING
    const ft2 = idx.lookupFieldType("PLAYER", "NAME");
    try std.testing.expect(ft2 != null);
    try std.testing.expectEqualStrings("STRING", ft2.?);
}

test "resolveChainType single segment resolves variable type" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;

    const l1 = toU32("TYPE Player");
    idx.scanLine(&l1, 0, &cls, &cls_len, &sk);
    const l2 = toU32("    name AS STRING");
    idx.scanLine(&l2, 1, &cls, &cls_len, &sk);
    const l3 = toU32("END TYPE");
    idx.scanLine(&l3, 2, &cls, &cls_len, &sk);

    const l4 = toU32("DIM hero AS Player");
    idx.scanLine(&l4, 3, &cls, &cls_len, &sk);

    // Single segment: hero → PLAYER
    const segs1 = [_][]const u8{"HERO"};
    const t1 = idx.resolveChainType(&segs1);
    try std.testing.expect(t1 != null);
    try std.testing.expectEqualStrings("PLAYER", t1.?);

    // Unknown variable returns null
    const segs2 = [_][]const u8{"UNKNOWN"};
    const t2 = idx.resolveChainType(&segs2);
    try std.testing.expect(t2 == null);
}

test "resolveChainType two segments resolves nested field type" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;

    // Define Vector2D
    const l1 = toU32("TYPE Vector2D");
    idx.scanLine(&l1, 0, &cls, &cls_len, &sk);
    const l2 = toU32("    x AS INTEGER");
    idx.scanLine(&l2, 1, &cls, &cls_len, &sk);
    const l3 = toU32("    y AS INTEGER");
    idx.scanLine(&l3, 2, &cls, &cls_len, &sk);
    const l4 = toU32("END TYPE");
    idx.scanLine(&l4, 3, &cls, &cls_len, &sk);

    // Define Player with Vector2D field
    const l5 = toU32("TYPE Player");
    idx.scanLine(&l5, 4, &cls, &cls_len, &sk);
    const l6 = toU32("    position AS Vector2D");
    idx.scanLine(&l6, 5, &cls, &cls_len, &sk);
    const l7 = toU32("END TYPE");
    idx.scanLine(&l7, 6, &cls, &cls_len, &sk);

    // DIM hero AS Player
    const l8 = toU32("DIM hero AS Player");
    idx.scanLine(&l8, 7, &cls, &cls_len, &sk);

    // hero.position → VECTOR2D
    const segs = [_][]const u8{ "HERO", "POSITION" };
    const t = idx.resolveChainType(&segs);
    try std.testing.expect(t != null);
    try std.testing.expectEqualStrings("VECTOR2D", t.?);
}

test "resolveChainType three segments resolves deeply nested" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;

    // Define Coord
    const l1 = toU32("TYPE Coord");
    idx.scanLine(&l1, 0, &cls, &cls_len, &sk);
    const l2 = toU32("    value AS INTEGER");
    idx.scanLine(&l2, 1, &cls, &cls_len, &sk);
    const l3 = toU32("END TYPE");
    idx.scanLine(&l3, 2, &cls, &cls_len, &sk);

    // Define Vector2D with Coord fields
    const l4 = toU32("TYPE Vector2D");
    idx.scanLine(&l4, 3, &cls, &cls_len, &sk);
    const l5 = toU32("    x AS Coord");
    idx.scanLine(&l5, 4, &cls, &cls_len, &sk);
    const l6 = toU32("    y AS Coord");
    idx.scanLine(&l6, 5, &cls, &cls_len, &sk);
    const l7 = toU32("END TYPE");
    idx.scanLine(&l7, 6, &cls, &cls_len, &sk);

    // Define Player with Vector2D field
    const l8 = toU32("TYPE Player");
    idx.scanLine(&l8, 7, &cls, &cls_len, &sk);
    const l9 = toU32("    position AS Vector2D");
    idx.scanLine(&l9, 8, &cls, &cls_len, &sk);
    const l10 = toU32("END TYPE");
    idx.scanLine(&l10, 9, &cls, &cls_len, &sk);

    // DIM hero AS Player
    const l11 = toU32("DIM hero AS Player");
    idx.scanLine(&l11, 10, &cls, &cls_len, &sk);

    // hero.position.x → COORD
    const segs3 = [_][]const u8{ "HERO", "POSITION", "X" };
    const t3 = idx.resolveChainType(&segs3);
    try std.testing.expect(t3 != null);
    try std.testing.expectEqualStrings("COORD", t3.?);

    // hero.position → VECTOR2D (2-segment still works)
    const segs2 = [_][]const u8{ "HERO", "POSITION" };
    const t2 = idx.resolveChainType(&segs2);
    try std.testing.expect(t2 != null);
    try std.testing.expectEqualStrings("VECTOR2D", t2.?);
}

test "resolveChainType fails on bad intermediate field" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;

    const l1 = toU32("TYPE Player");
    idx.scanLine(&l1, 0, &cls, &cls_len, &sk);
    const l2 = toU32("    name AS STRING");
    idx.scanLine(&l2, 1, &cls, &cls_len, &sk);
    const l3 = toU32("END TYPE");
    idx.scanLine(&l3, 2, &cls, &cls_len, &sk);

    const l4 = toU32("DIM hero AS Player");
    idx.scanLine(&l4, 3, &cls, &cls_len, &sk);

    // hero.nonexistent → null (field doesn't exist)
    const segs = [_][]const u8{ "HERO", "NONEXISTENT" };
    const t = idx.resolveChainType(&segs);
    try std.testing.expect(t == null);

    // hero.name.something → null (STRING has no fields to resolve further)
    const segs2 = [_][]const u8{ "HERO", "NAME", "SOMETHING" };
    const t2 = idx.resolveChainType(&segs2);
    try std.testing.expect(t2 == null);
}

test "resolveChainType empty segments returns null" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    const segs: [0][]const u8 = .{};
    const t = idx.resolveChainType(&segs);
    try std.testing.expect(t == null);
}

test "dotCompletionsChain single segment works like dotCompletions" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;

    const l1 = toU32("TYPE Vector2D");
    idx.scanLine(&l1, 0, &cls, &cls_len, &sk);
    const l2 = toU32("    x AS INTEGER");
    idx.scanLine(&l2, 1, &cls, &cls_len, &sk);
    const l3 = toU32("    y AS INTEGER");
    idx.scanLine(&l3, 2, &cls, &cls_len, &sk);
    const l4 = toU32("END TYPE");
    idx.scanLine(&l4, 3, &cls, &cls_len, &sk);
    const l5 = toU32("DIM pos AS Vector2D");
    idx.scanLine(&l5, 4, &cls, &cls_len, &sk);

    // Single-segment chain: same as dotCompletions("POS", ...)
    var completions: [MAX_DOT_COMPLETIONS]DotCompletion = undefined;
    const segs = [_][]const u8{"POS"};
    const count = idx.dotCompletionsChain(&segs, &completions);
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "dotCompletionsChain nested UDT returns inner type fields" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;

    // Define Vector2D
    const l1 = toU32("TYPE Vector2D");
    idx.scanLine(&l1, 0, &cls, &cls_len, &sk);
    const l2 = toU32("    x AS INTEGER");
    idx.scanLine(&l2, 1, &cls, &cls_len, &sk);
    const l3 = toU32("    y AS INTEGER");
    idx.scanLine(&l3, 2, &cls, &cls_len, &sk);
    const l4 = toU32("END TYPE");
    idx.scanLine(&l4, 3, &cls, &cls_len, &sk);

    // Define Player with Vector2D field
    const l5 = toU32("TYPE Player");
    idx.scanLine(&l5, 4, &cls, &cls_len, &sk);
    const l6 = toU32("    name AS STRING");
    idx.scanLine(&l6, 5, &cls, &cls_len, &sk);
    const l7 = toU32("    position AS Vector2D");
    idx.scanLine(&l7, 6, &cls, &cls_len, &sk);
    const l8 = toU32("END TYPE");
    idx.scanLine(&l8, 7, &cls, &cls_len, &sk);

    // DIM hero AS Player
    const l9 = toU32("DIM hero AS Player");
    idx.scanLine(&l9, 8, &cls, &cls_len, &sk);

    // hero.position. should offer Vector2D fields: x, y
    var completions: [MAX_DOT_COMPLETIONS]DotCompletion = undefined;
    const segs = [_][]const u8{ "HERO", "POSITION" };
    const count = idx.dotCompletionsChain(&segs, &completions);
    try std.testing.expectEqual(@as(usize, 2), count);

    // Verify we got x and y
    var found_x = false;
    var found_y = false;
    for (completions[0..count]) |*c| {
        const name = c.getNameUpper();
        if (std.mem.eql(u8, name, "X")) found_x = true;
        if (std.mem.eql(u8, name, "Y")) found_y = true;
    }
    try std.testing.expect(found_x);
    try std.testing.expect(found_y);
}

test "dotCompletionsChain three-deep nested UDT" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;

    // Define Coord
    const l1 = toU32("TYPE Coord");
    idx.scanLine(&l1, 0, &cls, &cls_len, &sk);
    const l2 = toU32("    value AS INTEGER");
    idx.scanLine(&l2, 1, &cls, &cls_len, &sk);
    const l3 = toU32("    label AS STRING");
    idx.scanLine(&l3, 2, &cls, &cls_len, &sk);
    const l4 = toU32("END TYPE");
    idx.scanLine(&l4, 3, &cls, &cls_len, &sk);

    // Define Vector2D with Coord fields
    const l5 = toU32("TYPE Vector2D");
    idx.scanLine(&l5, 4, &cls, &cls_len, &sk);
    const l6 = toU32("    x AS Coord");
    idx.scanLine(&l6, 5, &cls, &cls_len, &sk);
    const l7 = toU32("    y AS Coord");
    idx.scanLine(&l7, 6, &cls, &cls_len, &sk);
    const l8 = toU32("END TYPE");
    idx.scanLine(&l8, 7, &cls, &cls_len, &sk);

    // Define Player with Vector2D field
    const l9 = toU32("TYPE Player");
    idx.scanLine(&l9, 8, &cls, &cls_len, &sk);
    const l10 = toU32("    position AS Vector2D");
    idx.scanLine(&l10, 9, &cls, &cls_len, &sk);
    const l11 = toU32("END TYPE");
    idx.scanLine(&l11, 10, &cls, &cls_len, &sk);

    // DIM hero AS Player
    const l12 = toU32("DIM hero AS Player");
    idx.scanLine(&l12, 11, &cls, &cls_len, &sk);

    // hero.position.x. should offer Coord fields: value, label
    var completions: [MAX_DOT_COMPLETIONS]DotCompletion = undefined;
    const segs = [_][]const u8{ "HERO", "POSITION", "X" };
    const count = idx.dotCompletionsChain(&segs, &completions);
    try std.testing.expectEqual(@as(usize, 2), count);

    var found_value = false;
    var found_label = false;
    for (completions[0..count]) |*c| {
        const name = c.getNameUpper();
        if (std.mem.eql(u8, name, "VALUE")) found_value = true;
        if (std.mem.eql(u8, name, "LABEL")) found_label = true;
    }
    try std.testing.expect(found_value);
    try std.testing.expect(found_label);
}

test "dotCompletionsChain returns 0 for unknown nested field" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;

    const l1 = toU32("TYPE Player");
    idx.scanLine(&l1, 0, &cls, &cls_len, &sk);
    const l2 = toU32("    name AS STRING");
    idx.scanLine(&l2, 1, &cls, &cls_len, &sk);
    const l3 = toU32("END TYPE");
    idx.scanLine(&l3, 2, &cls, &cls_len, &sk);
    const l4 = toU32("DIM hero AS Player");
    idx.scanLine(&l4, 3, &cls, &cls_len, &sk);

    // hero.bogus. — BOGUS is not a field of Player, so chain fails → 0
    var completions: [MAX_DOT_COMPLETIONS]DotCompletion = undefined;
    const segs = [_][]const u8{ "HERO", "BOGUS" };
    const count = idx.dotCompletionsChain(&segs, &completions);
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "dotCompletionsChain empty segments returns 0" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var completions: [MAX_DOT_COMPLETIONS]DotCompletion = undefined;
    const segs: [0][]const u8 = .{};
    const count = idx.dotCompletionsChain(&segs, &completions);
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "dotCompletionsChain nested UDT field with HASHMAP type" {
    const allocator = std.testing.allocator;
    var idx = SymbolIndex.init(allocator);
    defer idx.deinit();

    var cls: [MAX_NAME]u8 = undefined;
    var cls_len: u8 = 0;
    var sk: ScopeKind = .none;

    // Define GameState with a HASHMAP field
    const l1 = toU32("TYPE GameState");
    idx.scanLine(&l1, 0, &cls, &cls_len, &sk);
    const l2 = toU32("    scores AS HASHMAP");
    idx.scanLine(&l2, 1, &cls, &cls_len, &sk);
    const l3 = toU32("    name AS STRING");
    idx.scanLine(&l3, 2, &cls, &cls_len, &sk);
    const l4 = toU32("END TYPE");
    idx.scanLine(&l4, 3, &cls, &cls_len, &sk);

    const l5 = toU32("DIM game AS GameState");
    idx.scanLine(&l5, 4, &cls, &cls_len, &sk);

    // game.scores. should offer HASHMAP methods
    var completions: [MAX_DOT_COMPLETIONS]DotCompletion = undefined;
    const segs = [_][]const u8{ "GAME", "SCORES" };
    const count = idx.dotCompletionsChain(&segs, &completions);
    try std.testing.expectEqual(HASHMAP_METHODS.len, count);
}
