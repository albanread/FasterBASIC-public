//! Ed Rope Buffer — UTF-32 Text Storage
//!
//! A balanced rope (weight-balanced binary tree) where each leaf holds a chunk
//! of UTF-32 code points. Provides O(log n) insert, delete, and line lookup
//! for files up to 250K+ lines.
//!
//! Design:
//!   - Leaves store up to LEAF_MAX (2048) code points each
//!   - Internal nodes cache: total length, total line count, subtree height
//!   - Balancing via AVL rotations (height-balanced)
//!   - Copy-on-write snapshots for background parsing (future)
//!
//! All indices are 0-based code point offsets unless noted otherwise.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

// ─── Configuration ──────────────────────────────────────────────────────────

/// Maximum code points per leaf node.
pub const LEAF_MAX: usize = 2048;

/// Minimum code points per leaf before merging with a sibling.
pub const LEAF_MIN: usize = 512;

/// The newline code point.
pub const NEWLINE: u32 = '\n';

// ─── Node ───────────────────────────────────────────────────────────────────

/// A node in the rope tree. Either a leaf (holds text) or a branch (two children).
pub const Node = struct {
    data: Data,
    /// Reference count for future COW snapshots. 1 = sole owner.
    ref_count: u32 = 1,

    const Data = union(enum) {
        leaf: Leaf,
        branch: Branch,
    };

    pub const Leaf = struct {
        /// The code point buffer. Allocated to capacity, used up to `len`.
        buf: []u32,
        /// Number of valid code points in `buf`.
        len: usize,
        /// Number of newline characters in buf[0..len].
        newline_count: usize,
    };

    pub const Branch = struct {
        left: *Node,
        right: *Node,
        /// Total code points in the left subtree (the "weight" in a weight-balanced rope).
        left_len: usize,
        /// Total code points in left + right.
        total_len: usize,
        /// Total newlines in left + right.
        total_newlines: usize,
        /// Tree height (for AVL balancing).
        height: u32,
    };

    /// Create a new leaf node.
    pub fn createLeaf(allocator: Allocator, text: []const u32) !*Node {
        const buf = try allocator.alloc(u32, LEAF_MAX);
        const copy_len = @min(text.len, LEAF_MAX);
        @memcpy(buf[0..copy_len], text[0..copy_len]);

        var nl_count: usize = 0;
        for (text[0..copy_len]) |cp| {
            if (cp == NEWLINE) nl_count += 1;
        }

        const node = try allocator.create(Node);
        node.* = .{
            .data = .{ .leaf = .{
                .buf = buf,
                .len = copy_len,
                .newline_count = nl_count,
            } },
            .ref_count = 1,
        };
        return node;
    }

    /// Create a new empty leaf node.
    pub fn createEmptyLeaf(allocator: Allocator) !*Node {
        const buf = try allocator.alloc(u32, LEAF_MAX);
        const node = try allocator.create(Node);
        node.* = .{
            .data = .{ .leaf = .{
                .buf = buf,
                .len = 0,
                .newline_count = 0,
            } },
            .ref_count = 1,
        };
        return node;
    }

    /// Create a branch node joining two children.
    pub fn createBranch(allocator: Allocator, left: *Node, right: *Node) !*Node {
        const l_len = left.textLen();
        const r_len = right.textLen();
        const l_nl = left.newlineCount();
        const r_nl = right.newlineCount();
        const l_h = left.height();
        const r_h = right.height();

        const node = try allocator.create(Node);
        node.* = .{
            .data = .{ .branch = .{
                .left = left,
                .right = right,
                .left_len = l_len,
                .total_len = l_len + r_len,
                .total_newlines = l_nl + r_nl,
                .height = 1 + @max(l_h, r_h),
            } },
            .ref_count = 1,
        };
        return node;
    }

    /// Total code points in this subtree.
    pub fn textLen(self: *const Node) usize {
        return switch (self.data) {
            .leaf => |l| l.len,
            .branch => |b| b.total_len,
        };
    }

    /// Total newline count in this subtree.
    pub fn newlineCount(self: *const Node) usize {
        return switch (self.data) {
            .leaf => |l| l.newline_count,
            .branch => |b| b.total_newlines,
        };
    }

    /// Total line count (newlines + 1, since the last line may not end with \n).
    pub fn lineCount(self: *const Node) usize {
        return self.newlineCount() + 1;
    }

    /// Tree height (0 for leaf).
    pub fn height(self: *const Node) u32 {
        return switch (self.data) {
            .leaf => 0,
            .branch => |b| b.height,
        };
    }

    /// Balance factor (left height - right height). Used for AVL rotations.
    pub fn balanceFactor(self: *const Node) i32 {
        return switch (self.data) {
            .leaf => 0,
            .branch => |b| {
                const lh: i32 = @intCast(b.left.height());
                const rh: i32 = @intCast(b.right.height());
                return lh - rh;
            },
        };
    }

    /// Free this node and all its children recursively.
    pub fn destroy(self: *Node, allocator: Allocator) void {
        switch (self.data) {
            .leaf => |l| {
                allocator.free(l.buf);
            },
            .branch => |b| {
                b.left.destroy(allocator);
                b.right.destroy(allocator);
            },
        }
        allocator.destroy(self);
    }

    /// Update cached metrics for a branch node.
    fn updateBranchMetrics(self: *Node) void {
        switch (self.data) {
            .branch => |*b| {
                const l_len = b.left.textLen();
                const r_len = b.right.textLen();
                b.left_len = l_len;
                b.total_len = l_len + r_len;
                b.total_newlines = b.left.newlineCount() + b.right.newlineCount();
                b.height = 1 + @max(b.left.height(), b.right.height());
            },
            .leaf => {},
        }
    }
};

// ─── Rope (public API) ─────────────────────────────────────────────────────

/// A rope-based text buffer storing UTF-32 code points.
pub const RopeBuffer = struct {
    root: *Node,
    allocator: Allocator,

    /// Create an empty rope buffer.
    pub fn init(allocator: Allocator) !RopeBuffer {
        const root = try Node.createEmptyLeaf(allocator);
        return .{
            .root = root,
            .allocator = allocator,
        };
    }

    /// Create a rope from a slice of code points.
    pub fn initFromSlice(allocator: Allocator, text: []const u32) !RopeBuffer {
        if (text.len == 0) {
            return init(allocator);
        }
        const root = try buildRopeFromSlice(allocator, text);
        return .{
            .root = root,
            .allocator = allocator,
        };
    }

    /// Create a rope from a UTF-8 string (convenience for loading files).
    pub fn initFromUtf8(allocator: Allocator, utf8: []const u8) !RopeBuffer {
        // Decode UTF-8 → UTF-32
        const codepoints = try utf8ToCodepoints(allocator, utf8);
        defer allocator.free(codepoints);
        return initFromSlice(allocator, codepoints);
    }

    /// Destroy the rope and free all memory.
    pub fn deinit(self: *RopeBuffer) void {
        self.root.destroy(self.allocator);
    }

    /// Total number of code points in the buffer.
    pub fn length(self: *const RopeBuffer) usize {
        return self.root.textLen();
    }

    /// Total number of lines (newline_count + 1).
    pub fn lineCount(self: *const RopeBuffer) usize {
        return self.root.lineCount();
    }

    /// Total number of newline characters.
    pub fn newlineCount(self: *const RopeBuffer) usize {
        return self.root.newlineCount();
    }

    /// Get the code point at a given offset. Returns null if out of bounds.
    pub fn charAt(self: *const RopeBuffer, pos: usize) ?u32 {
        if (pos >= self.length()) return null;
        return charAtNode(self.root, pos);
    }

    /// Insert code points at the given offset.
    pub fn insert(self: *RopeBuffer, pos: usize, text: []const u32) !void {
        if (text.len == 0) return;
        const insert_node = try buildRopeFromSlice(self.allocator, text);
        self.root = try insertNode(self.allocator, self.root, pos, insert_node);
    }

    /// Insert a single code point at the given offset.
    pub fn insertChar(self: *RopeBuffer, pos: usize, cp: u32) !void {
        const text = [_]u32{cp};
        try self.insert(pos, &text);
    }

    /// Delete `count` code points starting at `pos`.
    pub fn delete(self: *RopeBuffer, pos: usize, count: usize) !void {
        if (count == 0) return;
        const total = self.length();
        if (pos >= total) return;
        const actual_count = @min(count, total - pos);
        self.root = try deleteRange(self.allocator, self.root, pos, actual_count);
    }

    /// Replace `count` code points at `pos` with `text`.
    pub fn replace(self: *RopeBuffer, pos: usize, count: usize, text: []const u32) !void {
        try self.delete(pos, count);
        try self.insert(pos, text);
    }

    /// Get the byte offset (code point offset) where line `line_idx` (0-based) starts.
    /// Returns null if the line index is out of bounds.
    pub fn lineStart(self: *const RopeBuffer, line_idx: usize) ?usize {
        if (line_idx == 0) return 0;
        if (line_idx >= self.lineCount()) return null;
        // Find the position right after the (line_idx)th newline (0-indexed)
        return nthNewlinePos(self.root, line_idx - 1);
    }

    /// Get the start and end offsets (exclusive) for line `line_idx` (0-based).
    /// The end offset does NOT include the trailing newline (if any).
    pub fn lineRange(self: *const RopeBuffer, line_idx: usize) ?struct { start: usize, end: usize } {
        const total_lines = self.lineCount();
        if (line_idx >= total_lines) return null;

        const start = if (line_idx == 0) @as(usize, 0) else (nthNewlinePos(self.root, line_idx - 1) orelse return null);

        // Find end: position of the next newline, or end of buffer
        const end = if (line_idx + 1 < total_lines)
            // There's a newline ending this line; find it
            (nthNewlinePosRaw(self.root, line_idx) orelse self.length())
        else
            self.length();

        return .{ .start = start, .end = end };
    }

    /// Extract a range of code points as a newly allocated slice.
    pub fn slice(self: *const RopeBuffer, start: usize, end: usize) ![]u32 {
        const total = self.length();
        const s = @min(start, total);
        const e = @min(end, total);
        if (s >= e) return self.allocator.alloc(u32, 0);

        const len = e - s;
        const result = try self.allocator.alloc(u32, len);
        var idx: usize = 0;
        collectRange(self.root, s, e, result, &idx);
        return result;
    }

    /// Extract a single line as a newly allocated slice of code points.
    /// Does NOT include the trailing newline.
    pub fn getLine(self: *const RopeBuffer, line_idx: usize) ![]u32 {
        const range = self.lineRange(line_idx) orelse return self.allocator.alloc(u32, 0);
        return self.slice(range.start, range.end);
    }

    /// Convert the entire buffer to a UTF-8 byte string.
    pub fn toUtf8(self: *const RopeBuffer) ![]u8 {
        const cps = try self.slice(0, self.length());
        defer self.allocator.free(cps);
        return codepointsToUtf8(self.allocator, cps);
    }

    /// Find the line index and column for a given code point offset.
    pub fn offsetToLineCol(self: *const RopeBuffer, offset: usize) struct { line: usize, col: usize } {
        const pos = @min(offset, self.length());
        // Count newlines before `pos`
        const nl = countNewlinesBefore(self.root, pos);
        // Find start of that line
        const line_start_off = if (nl == 0) @as(usize, 0) else (nthNewlinePos(self.root, nl - 1) orelse 0);
        return .{ .line = nl, .col = pos - line_start_off };
    }

    /// Convert a line index and column to a code point offset.
    pub fn lineColToOffset(self: *const RopeBuffer, line: usize, col: usize) usize {
        const start = self.lineStart(line) orelse self.length();
        const range = self.lineRange(line) orelse return start;
        const line_len = range.end - range.start;
        return start + @min(col, line_len);
    }

    /// Insert a UTF-8 string at the given offset.
    pub fn insertUtf8(self: *RopeBuffer, pos: usize, utf8: []const u8) !void {
        const cps = try utf8ToCodepoints(self.allocator, utf8);
        defer self.allocator.free(cps);
        try self.insert(pos, cps);
    }

    /// Collect all text into a contiguous code point buffer.
    pub fn toSlice(self: *const RopeBuffer) ![]u32 {
        return self.slice(0, self.length());
    }
};

// ─── Internal: Build rope from slice (bottom-up) ───────────────────────────

fn buildRopeFromSlice(allocator: Allocator, text: []const u32) !*Node {
    if (text.len == 0) {
        return Node.createEmptyLeaf(allocator);
    }

    // Split text into LEAF_MAX-sized chunks, create leaves
    const chunk_count = (text.len + LEAF_MAX - 1) / LEAF_MAX;

    if (chunk_count == 1) {
        return Node.createLeaf(allocator, text);
    }

    // Allocate an array of leaf pointers, then build a balanced tree bottom-up
    var nodes = try allocator.alloc(*Node, chunk_count);
    defer allocator.free(nodes);

    for (0..chunk_count) |i| {
        const start = i * LEAF_MAX;
        const end = @min(start + LEAF_MAX, text.len);
        nodes[i] = try Node.createLeaf(allocator, text[start..end]);
    }

    // Merge pairwise until we have a single root
    var current_count = chunk_count;
    while (current_count > 1) {
        const new_count = (current_count + 1) / 2;
        for (0..new_count) |i| {
            const left_idx = i * 2;
            const right_idx = left_idx + 1;
            if (right_idx < current_count) {
                nodes[i] = try Node.createBranch(allocator, nodes[left_idx], nodes[right_idx]);
            } else {
                nodes[i] = nodes[left_idx];
            }
        }
        current_count = new_count;
    }

    return nodes[0];
}

// ─── Internal: Character lookup ─────────────────────────────────────────────

fn charAtNode(node: *const Node, pos: usize) u32 {
    switch (node.data) {
        .leaf => |l| {
            return l.buf[pos];
        },
        .branch => |b| {
            if (pos < b.left_len) {
                return charAtNode(b.left, pos);
            } else {
                return charAtNode(b.right, pos - b.left_len);
            }
        },
    }
}

// ─── Internal: Collect range of code points ─────────────────────────────────

fn collectRange(node: *const Node, start: usize, end: usize, out: []u32, idx: *usize) void {
    if (start >= end) return;

    switch (node.data) {
        .leaf => |l| {
            const copy_start = start;
            const copy_end = @min(end, l.len);
            for (l.buf[copy_start..copy_end]) |cp| {
                out[idx.*] = cp;
                idx.* += 1;
            }
        },
        .branch => |b| {
            if (start < b.left_len) {
                collectRange(b.left, start, @min(end, b.left_len), out, idx);
            }
            if (end > b.left_len) {
                const r_start = if (start > b.left_len) start - b.left_len else 0;
                const r_end = end - b.left_len;
                collectRange(b.right, r_start, r_end, out, idx);
            }
        },
    }
}

// ─── Internal: Split a node at position ─────────────────────────────────────

/// Split a node into two: [0..pos) and [pos..len).
/// Returns the left and right subtrees. The original node is consumed.
fn splitNode(allocator: Allocator, node: *Node, pos: usize) !struct { left: *Node, right: *Node } {
    const node_len = node.textLen();

    if (pos == 0) {
        const empty = try Node.createEmptyLeaf(allocator);
        return .{ .left = empty, .right = node };
    }
    if (pos >= node_len) {
        const empty = try Node.createEmptyLeaf(allocator);
        return .{ .left = node, .right = empty };
    }

    switch (node.data) {
        .leaf => |l| {
            // Split the leaf into two leaves
            const left = try Node.createLeaf(allocator, l.buf[0..pos]);
            const right = try Node.createLeaf(allocator, l.buf[pos..l.len]);
            node.destroy(allocator);
            return .{ .left = left, .right = right };
        },
        .branch => |b| {
            if (pos == b.left_len) {
                // Split exactly at the boundary
                const left = b.left;
                const right = b.right;
                // Free only the branch node, not children
                allocator.destroy(node);
                return .{ .left = left, .right = right };
            } else if (pos < b.left_len) {
                // Split within the left child
                const right_child = b.right;
                const left_child = b.left;
                allocator.destroy(node);
                const split = try splitNode(allocator, left_child, pos);
                const new_right = try joinNodes(allocator, split.right, right_child);
                return .{ .left = split.left, .right = new_right };
            } else {
                // Split within the right child
                const left_child = b.left;
                const right_child = b.right;
                allocator.destroy(node);
                const split = try splitNode(allocator, right_child, pos - b.left_len);
                const new_left = try joinNodes(allocator, left_child, split.left);
                return .{ .left = new_left, .right = split.right };
            }
        },
    }
}

// ─── Internal: Join two nodes ───────────────────────────────────────────────

/// Join two nodes into a balanced tree. Neither input is modified.
fn joinNodes(allocator: Allocator, left: *Node, right: *Node) !*Node {
    // If either is empty, return the other
    if (left.textLen() == 0) {
        left.destroy(allocator);
        return right;
    }
    if (right.textLen() == 0) {
        right.destroy(allocator);
        return left;
    }

    // If both are small leaves, merge them into one leaf
    if (left.data == .leaf and right.data == .leaf) {
        const ll = left.data.leaf;
        const rl = right.data.leaf;
        if (ll.len + rl.len <= LEAF_MAX) {
            const merged = try allocator.alloc(u32, LEAF_MAX);
            @memcpy(merged[0..ll.len], ll.buf[0..ll.len]);
            @memcpy(merged[ll.len .. ll.len + rl.len], rl.buf[0..rl.len]);

            var nl_count: usize = 0;
            for (merged[0 .. ll.len + rl.len]) |cp| {
                if (cp == NEWLINE) nl_count += 1;
            }

            const node = try allocator.create(Node);
            node.* = .{
                .data = .{ .leaf = .{
                    .buf = merged,
                    .len = ll.len + rl.len,
                    .newline_count = nl_count,
                } },
                .ref_count = 1,
            };
            left.destroy(allocator);
            right.destroy(allocator);
            return node;
        }
    }

    const branch = try Node.createBranch(allocator, left, right);
    return balance(allocator, branch);
}

// ─── Internal: Insert a node at position ────────────────────────────────────

fn insertNode(allocator: Allocator, root: *Node, pos: usize, insert: *Node) !*Node {
    const split = try splitNode(allocator, root, pos);
    const left_joined = try joinNodes(allocator, split.left, insert);
    return joinNodes(allocator, left_joined, split.right);
}

// ─── Internal: Delete range ─────────────────────────────────────────────────

fn deleteRange(allocator: Allocator, root: *Node, pos: usize, count: usize) !*Node {
    // Split at pos → (before, rest)
    const split1 = try splitNode(allocator, root, pos);
    // Split rest at count → (deleted, after)
    const split2 = try splitNode(allocator, split1.right, count);
    // Free the deleted portion
    split2.left.destroy(allocator);
    // Join before and after
    return joinNodes(allocator, split1.left, split2.right);
}

// ─── Internal: AVL Balancing ────────────────────────────────────────────────

fn balance(allocator: Allocator, node: *Node) !*Node {
    if (node.data != .branch) return node;

    const bf = node.balanceFactor();

    if (bf > 1) {
        // Left-heavy
        const left = node.data.branch.left;
        if (left.balanceFactor() < 0) {
            // Left-Right case: rotate left child left, then rotate root right
            node.data.branch.left = try rotateLeft(allocator, left);
            node.updateBranchMetrics();
        }
        return rotateRight(allocator, node);
    }

    if (bf < -1) {
        // Right-heavy
        const right = node.data.branch.right;
        if (right.balanceFactor() > 0) {
            // Right-Left case: rotate right child right, then rotate root left
            node.data.branch.right = try rotateRight(allocator, right);
            node.updateBranchMetrics();
        }
        return rotateLeft(allocator, node);
    }

    return node;
}

fn rotateRight(allocator: Allocator, node: *Node) !*Node {
    if (node.data != .branch) return node;
    const left = node.data.branch.left;
    if (left.data != .branch) return node;

    // left becomes the new root
    const left_right = left.data.branch.right;
    node.data.branch.left = left_right;
    node.updateBranchMetrics();

    left.data.branch.right = node;
    left.updateBranchMetrics();

    _ = allocator; // used in error paths if needed
    return left;
}

fn rotateLeft(allocator: Allocator, node: *Node) !*Node {
    if (node.data != .branch) return node;
    const right = node.data.branch.right;
    if (right.data != .branch) return node;

    // right becomes the new root
    const right_left = right.data.branch.left;
    node.data.branch.right = right_left;
    node.updateBranchMetrics();

    right.data.branch.left = node;
    right.updateBranchMetrics();

    _ = allocator;
    return right;
}

// ─── Internal: Newline navigation ───────────────────────────────────────────

/// Count how many newlines appear before position `pos` (exclusive).
fn countNewlinesBefore(node: *const Node, pos: usize) usize {
    if (pos == 0) return 0;

    switch (node.data) {
        .leaf => |l| {
            const scan_to = @min(pos, l.len);
            var count: usize = 0;
            for (l.buf[0..scan_to]) |cp| {
                if (cp == NEWLINE) count += 1;
            }
            return count;
        },
        .branch => |b| {
            if (pos <= b.left_len) {
                return countNewlinesBefore(b.left, pos);
            } else {
                return b.left.newlineCount() + countNewlinesBefore(b.right, pos - b.left_len);
            }
        },
    }
}

/// Find the position right after the nth newline (0-based). This gives the
/// start of line (n+1). Returns null if there aren't enough newlines.
fn nthNewlinePos(node: *const Node, n: usize) ?usize {
    const raw_pos = nthNewlinePosRaw(node, n) orelse return null;
    return raw_pos + 1; // position after the newline = start of next line
}

/// Find the position OF the nth newline (0-based). Returns the offset of
/// the newline character itself.
fn nthNewlinePosRaw(node: *const Node, n: usize) ?usize {
    switch (node.data) {
        .leaf => |l| {
            var count: usize = 0;
            for (l.buf[0..l.len], 0..) |cp, i| {
                if (cp == NEWLINE) {
                    if (count == n) return i;
                    count += 1;
                }
            }
            return null;
        },
        .branch => |b| {
            const left_nl = b.left.newlineCount();
            if (n < left_nl) {
                return nthNewlinePosRaw(b.left, n);
            } else {
                const right_pos = nthNewlinePosRaw(b.right, n - left_nl) orelse return null;
                return b.left_len + right_pos;
            }
        },
    }
}

// ─── UTF-8 ↔ UTF-32 Conversion ─────────────────────────────────────────────

/// Decode a UTF-8 byte string into UTF-32 code points.
/// Invalid sequences are replaced with U+FFFD.
/// Line endings are normalised: \r\n → \n, lone \r → \n.
pub fn utf8ToCodepoints(allocator: Allocator, utf8: []const u8) ![]u32 {
    // Worst case: every byte is a character
    var result: std.ArrayListUnmanaged(u32) = .{};
    defer result.deinit(allocator);
    try result.ensureTotalCapacity(allocator, utf8.len);

    var i: usize = 0;
    while (i < utf8.len) {
        const byte = utf8[i];

        // Handle \r\n and lone \r → \n
        if (byte == '\r') {
            try result.append(allocator, NEWLINE);
            if (i + 1 < utf8.len and utf8[i + 1] == '\n') {
                i += 2; // skip \r\n
            } else {
                i += 1; // lone \r
            }
            continue;
        }

        // Skip BOM (U+FEFF) at start
        if (i == 0 and utf8.len >= 3 and utf8[0] == 0xEF and utf8[1] == 0xBB and utf8[2] == 0xBF) {
            i += 3;
            continue;
        }

        if (byte < 0x80) {
            // ASCII
            try result.append(allocator, @as(u32, byte));
            i += 1;
        } else if (byte & 0xE0 == 0xC0) {
            // 2-byte sequence
            if (i + 1 < utf8.len and utf8[i + 1] & 0xC0 == 0x80) {
                const cp: u32 = (@as(u32, byte & 0x1F) << 6) | @as(u32, utf8[i + 1] & 0x3F);
                try result.append(allocator, cp);
                i += 2;
            } else {
                try result.append(allocator, 0xFFFD);
                i += 1;
            }
        } else if (byte & 0xF0 == 0xE0) {
            // 3-byte sequence
            if (i + 2 < utf8.len and utf8[i + 1] & 0xC0 == 0x80 and utf8[i + 2] & 0xC0 == 0x80) {
                const cp: u32 = (@as(u32, byte & 0x0F) << 12) |
                    (@as(u32, utf8[i + 1] & 0x3F) << 6) |
                    @as(u32, utf8[i + 2] & 0x3F);
                try result.append(allocator, cp);
                i += 3;
            } else {
                try result.append(allocator, 0xFFFD);
                i += 1;
            }
        } else if (byte & 0xF8 == 0xF0) {
            // 4-byte sequence
            if (i + 3 < utf8.len and utf8[i + 1] & 0xC0 == 0x80 and utf8[i + 2] & 0xC0 == 0x80 and utf8[i + 3] & 0xC0 == 0x80) {
                const cp: u32 = (@as(u32, byte & 0x07) << 18) |
                    (@as(u32, utf8[i + 1] & 0x3F) << 12) |
                    (@as(u32, utf8[i + 2] & 0x3F) << 6) |
                    @as(u32, utf8[i + 3] & 0x3F);
                try result.append(allocator, cp);
                i += 4;
            } else {
                try result.append(allocator, 0xFFFD);
                i += 1;
            }
        } else {
            try result.append(allocator, 0xFFFD);
            i += 1;
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// Encode UTF-32 code points to a UTF-8 byte string.
pub fn codepointsToUtf8(allocator: Allocator, codepoints: []const u32) ![]u8 {
    // Worst case: each code point = 4 bytes
    var result: std.ArrayListUnmanaged(u8) = .{};
    defer result.deinit(allocator);
    try result.ensureTotalCapacity(allocator, codepoints.len);

    for (codepoints) |cp| {
        if (cp < 0x80) {
            try result.append(allocator, @intCast(cp));
        } else if (cp < 0x800) {
            try result.append(allocator, @intCast(0xC0 | (cp >> 6)));
            try result.append(allocator, @intCast(0x80 | (cp & 0x3F)));
        } else if (cp < 0x10000) {
            try result.append(allocator, @intCast(0xE0 | (cp >> 12)));
            try result.append(allocator, @intCast(0x80 | ((cp >> 6) & 0x3F)));
            try result.append(allocator, @intCast(0x80 | (cp & 0x3F)));
        } else if (cp < 0x110000) {
            try result.append(allocator, @intCast(0xF0 | (cp >> 18)));
            try result.append(allocator, @intCast(0x80 | ((cp >> 12) & 0x3F)));
            try result.append(allocator, @intCast(0x80 | ((cp >> 6) & 0x3F)));
            try result.append(allocator, @intCast(0x80 | (cp & 0x3F)));
        } else {
            // Invalid code point → U+FFFD in UTF-8
            try result.append(allocator, 0xEF);
            try result.append(allocator, 0xBF);
            try result.append(allocator, 0xBD);
        }
    }

    return try result.toOwnedSlice(allocator);
}

// ─── Tests ──────────────────────────────────────────────────────────────────

test "empty buffer" {
    var buf = try RopeBuffer.init(testing.allocator);
    defer buf.deinit();

    try testing.expectEqual(@as(usize, 0), buf.length());
    try testing.expectEqual(@as(usize, 1), buf.lineCount());
    try testing.expectEqual(@as(?u32, null), buf.charAt(0));
}

test "init from UTF-8" {
    var buf = try RopeBuffer.initFromUtf8(testing.allocator, "Hello\nWorld");
    defer buf.deinit();

    try testing.expectEqual(@as(usize, 11), buf.length());
    try testing.expectEqual(@as(usize, 2), buf.lineCount());
    try testing.expectEqual(@as(?u32, 'H'), buf.charAt(0));
    try testing.expectEqual(@as(?u32, '\n'), buf.charAt(5));
    try testing.expectEqual(@as(?u32, 'W'), buf.charAt(6));
}

test "insert and delete" {
    var buf = try RopeBuffer.initFromUtf8(testing.allocator, "Hello");
    defer buf.deinit();

    try testing.expectEqual(@as(usize, 5), buf.length());

    // Insert " World" at position 5
    try buf.insertUtf8(5, " World");
    try testing.expectEqual(@as(usize, 11), buf.length());

    const text = try buf.toUtf8();
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("Hello World", text);

    // Delete " World" (positions 5..11)
    try buf.delete(5, 6);
    try testing.expectEqual(@as(usize, 5), buf.length());

    const text2 = try buf.toUtf8();
    defer testing.allocator.free(text2);
    try testing.expectEqualStrings("Hello", text2);
}

test "line navigation" {
    var buf = try RopeBuffer.initFromUtf8(testing.allocator, "Line 0\nLine 1\nLine 2");
    defer buf.deinit();

    try testing.expectEqual(@as(usize, 3), buf.lineCount());

    // Line starts
    try testing.expectEqual(@as(?usize, 0), buf.lineStart(0));
    try testing.expectEqual(@as(?usize, 7), buf.lineStart(1));
    try testing.expectEqual(@as(?usize, 14), buf.lineStart(2));
    try testing.expectEqual(@as(?usize, null), buf.lineStart(3));

    // Get lines
    const line0 = try buf.getLine(0);
    defer testing.allocator.free(line0);
    const line0_utf8 = try codepointsToUtf8(testing.allocator, line0);
    defer testing.allocator.free(line0_utf8);
    try testing.expectEqualStrings("Line 0", line0_utf8);

    const line2 = try buf.getLine(2);
    defer testing.allocator.free(line2);
    const line2_utf8 = try codepointsToUtf8(testing.allocator, line2);
    defer testing.allocator.free(line2_utf8);
    try testing.expectEqualStrings("Line 2", line2_utf8);
}

test "offset to line/col" {
    var buf = try RopeBuffer.initFromUtf8(testing.allocator, "AB\nCD\nEF");
    defer buf.deinit();

    // A=0, B=1, \n=2, C=3, D=4, \n=5, E=6, F=7
    const pos0 = buf.offsetToLineCol(0);
    try testing.expectEqual(@as(usize, 0), pos0.line);
    try testing.expectEqual(@as(usize, 0), pos0.col);

    const pos3 = buf.offsetToLineCol(3);
    try testing.expectEqual(@as(usize, 1), pos3.line);
    try testing.expectEqual(@as(usize, 0), pos3.col);

    const pos7 = buf.offsetToLineCol(7);
    try testing.expectEqual(@as(usize, 2), pos7.line);
    try testing.expectEqual(@as(usize, 1), pos7.col);
}

test "line/col to offset" {
    var buf = try RopeBuffer.initFromUtf8(testing.allocator, "AB\nCD\nEF");
    defer buf.deinit();

    try testing.expectEqual(@as(usize, 0), buf.lineColToOffset(0, 0));
    try testing.expectEqual(@as(usize, 1), buf.lineColToOffset(0, 1));
    try testing.expectEqual(@as(usize, 3), buf.lineColToOffset(1, 0));
    try testing.expectEqual(@as(usize, 6), buf.lineColToOffset(2, 0));
    try testing.expectEqual(@as(usize, 7), buf.lineColToOffset(2, 1));
}

test "UTF-8 round-trip" {
    const original = "Hello, 世界! 🌍";
    var buf = try RopeBuffer.initFromUtf8(testing.allocator, original);
    defer buf.deinit();

    const result = try buf.toUtf8();
    defer testing.allocator.free(result);
    try testing.expectEqualStrings(original, result);
}

test "CRLF normalisation" {
    var buf = try RopeBuffer.initFromUtf8(testing.allocator, "A\r\nB\rC\nD");
    defer buf.deinit();

    try testing.expectEqual(@as(usize, 4), buf.lineCount());

    const result = try buf.toUtf8();
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("A\nB\nC\nD", result);
}

test "insert at beginning and end" {
    var buf = try RopeBuffer.initFromUtf8(testing.allocator, "World");
    defer buf.deinit();

    try buf.insertUtf8(0, "Hello ");
    try buf.insertUtf8(buf.length(), "!");

    const result = try buf.toUtf8();
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Hello World!", result);
}

test "single char operations" {
    var buf = try RopeBuffer.init(testing.allocator);
    defer buf.deinit();

    try buf.insertChar(0, 'A');
    try buf.insertChar(1, 'C');
    try buf.insertChar(1, 'B');

    try testing.expectEqual(@as(?u32, 'A'), buf.charAt(0));
    try testing.expectEqual(@as(?u32, 'B'), buf.charAt(1));
    try testing.expectEqual(@as(?u32, 'C'), buf.charAt(2));
    try testing.expectEqual(@as(usize, 3), buf.length());
}

test "large insert builds balanced tree" {
    // Insert enough text to force multiple leaves
    const line = "This is a line of BASIC code that is reasonably long for testing purposes.\n";
    var big_text: std.ArrayListUnmanaged(u8) = .{};
    defer big_text.deinit(testing.allocator);

    // Build 1000 lines
    for (0..1000) |_| {
        try big_text.appendSlice(testing.allocator, line);
    }

    var buf = try RopeBuffer.initFromUtf8(testing.allocator, big_text.items);
    defer buf.deinit();

    try testing.expectEqual(@as(usize, 1001), buf.lineCount()); // 1000 \n + trailing empty line

    // Verify first line
    const first_line = try buf.getLine(0);
    defer testing.allocator.free(first_line);
    const first_utf8 = try codepointsToUtf8(testing.allocator, first_line);
    defer testing.allocator.free(first_utf8);
    try testing.expectEqualStrings("This is a line of BASIC code that is reasonably long for testing purposes.", first_utf8);

    // Tree should be reasonably balanced
    const h = buf.root.height();
    // For ~1000 leaves, height should be around 10-15 (AVL guarantees <= 1.44 * log2(n))
    try testing.expect(h <= 20);
}

test "delete entire content" {
    var buf = try RopeBuffer.initFromUtf8(testing.allocator, "Hello World");
    defer buf.deinit();

    try buf.delete(0, buf.length());
    try testing.expectEqual(@as(usize, 0), buf.length());
    try testing.expectEqual(@as(usize, 1), buf.lineCount());
}

test "replace" {
    var buf = try RopeBuffer.initFromUtf8(testing.allocator, "Hello World");
    defer buf.deinit();

    const replacement = [_]u32{ 'Z', 'i', 'g' };
    try buf.replace(6, 5, &replacement);

    const result = try buf.toUtf8();
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Hello Zig", result);
}

test "empty line range" {
    var buf = try RopeBuffer.initFromUtf8(testing.allocator, "\n\n\n");
    defer buf.deinit();

    try testing.expectEqual(@as(usize, 4), buf.lineCount());

    // First line is empty (range 0..0)
    const r0 = buf.lineRange(0) orelse unreachable;
    try testing.expectEqual(@as(usize, 0), r0.start);
    try testing.expectEqual(@as(usize, 0), r0.end);

    // Second line is empty (range 1..1)
    const r1 = buf.lineRange(1) orelse unreachable;
    try testing.expectEqual(@as(usize, 1), r1.start);
    try testing.expectEqual(@as(usize, 1), r1.end);
}

test "slice extraction" {
    var buf = try RopeBuffer.initFromUtf8(testing.allocator, "ABCDEFGHIJ");
    defer buf.deinit();

    const sub = try buf.slice(3, 7);
    defer testing.allocator.free(sub);

    const utf8 = try codepointsToUtf8(testing.allocator, sub);
    defer testing.allocator.free(utf8);
    try testing.expectEqualStrings("DEFG", utf8);
}

test "BOM is skipped" {
    const with_bom = "\xEF\xBB\xBFHello";
    var buf = try RopeBuffer.initFromUtf8(testing.allocator, with_bom);
    defer buf.deinit();

    try testing.expectEqual(@as(usize, 5), buf.length());

    const result = try buf.toUtf8();
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Hello", result);
}
