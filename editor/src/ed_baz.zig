//! ed_baz.zig — .baz file format: zstd-compressed UTF-32 codepoints
//!
//! File format:
//!   Bytes 0..3:   Magic "BAZ1"
//!   Bytes 4..7:   Codepoint count (u32 LE)
//!   Bytes 8..N:   Zstd-compressed raw u32 LE codepoint data
//!
//! Usage:
//!   const cps = try loadBaz(allocator, "/path/to/file.baz");
//!   defer allocator.free(cps);
//!
//!   try saveBaz(allocator, "/path/to/file.baz", codepoints);

const std = @import("std");

const c = @cImport({
    @cInclude("zstd.h");
});

/// Magic header identifying a .baz file.
const BAZ_MAGIC = [4]u8{ 'B', 'A', 'Z', '1' };

/// Header size: 4-byte magic + 4-byte codepoint count.
const HEADER_SIZE = 8;

/// Default zstd compression level (1 = fast, 19 = best, 3 = good default).
const ZSTD_LEVEL = 3;

/// Errors specific to .baz I/O.
pub const BazError = error{
    /// The file does not start with the BAZ1 magic header.
    InvalidMagic,
    /// Zstd compression failed.
    CompressFailed,
    /// Zstd decompression failed.
    DecompressFailed,
    /// The decompressed size is not a multiple of 4 (not valid u32 data).
    InvalidAlignment,
    /// The file is too small to contain a valid header.
    FileTooSmall,
    /// Zstd reported an error for the frame content size.
    BadFrameSize,
};

/// Save codepoints to a .baz file (zstd-compressed UTF-32 LE).
///
/// Format: "BAZ1" ++ u32_le(codepoint_count) ++ zstd_frame(raw_u32_le_bytes)
pub fn saveBaz(allocator: std.mem.Allocator, path: []const u8, codepoints: []const u32) !void {
    // Reinterpret the u32 slice as raw bytes (native endian = LE on ARM64/x86)
    const raw_bytes = std.mem.sliceAsBytes(codepoints);

    // Allocate destination buffer for compression.
    // ZSTD_compressBound gives the worst-case compressed size.
    const bound = c.ZSTD_compressBound(raw_bytes.len);
    if (bound == 0) return BazError.CompressFailed;

    const comp_buf = try allocator.alloc(u8, bound);
    defer allocator.free(comp_buf);

    // Compress
    const comp_size = c.ZSTD_compress(
        comp_buf.ptr,
        comp_buf.len,
        raw_bytes.ptr,
        raw_bytes.len,
        ZSTD_LEVEL,
    );
    if (c.ZSTD_isError(comp_size) != 0) {
        return BazError.CompressFailed;
    }

    // Open file for writing
    // We need a null-terminated path for std.fs
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    // Write header: magic + codepoint count
    var header: [HEADER_SIZE]u8 = undefined;
    @memcpy(header[0..4], &BAZ_MAGIC);
    std.mem.writeInt(u32, header[4..8], @intCast(codepoints.len), .little);
    try file.writeAll(&header);

    // Write compressed data
    try file.writeAll(comp_buf[0..comp_size]);
}

/// Load codepoints from a .baz file (zstd-compressed UTF-32 LE).
///
/// Returns a newly allocated u32 slice. Caller must free with the same allocator.
pub fn loadBaz(allocator: std.mem.Allocator, path: []const u8) ![]u32 {
    // Read the entire file
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const file_size = stat.size;

    if (file_size < HEADER_SIZE) return BazError.FileTooSmall;

    const file_data = try allocator.alloc(u8, file_size);
    defer allocator.free(file_data);

    const bytes_read = try file.readAll(file_data);
    if (bytes_read < HEADER_SIZE) return BazError.FileTooSmall;

    // Validate magic
    if (!std.mem.eql(u8, file_data[0..4], &BAZ_MAGIC)) {
        return BazError.InvalidMagic;
    }

    // Read codepoint count
    const cp_count = std.mem.readInt(u32, file_data[4..8], .little);
    const decomp_size: usize = @as(usize, cp_count) * 4;

    // Compressed payload
    const comp_data = file_data[HEADER_SIZE..bytes_read];

    // Allocate a properly-aligned u32 buffer for the result.
    // We decompress directly into its backing memory (reinterpreted
    // as bytes), which avoids a copy and guarantees u32 alignment.
    const codepoints = try allocator.alloc(u32, cp_count);
    errdefer allocator.free(codepoints);

    const decomp_buf = std.mem.sliceAsBytes(codepoints);

    // Decompress
    const result_size = c.ZSTD_decompress(
        decomp_buf.ptr,
        decomp_buf.len,
        comp_data.ptr,
        comp_data.len,
    );
    if (c.ZSTD_isError(result_size) != 0) {
        return BazError.DecompressFailed;
    }

    if (result_size != decomp_size) {
        return BazError.InvalidAlignment;
    }

    return codepoints;
}

/// Check whether a file path has the .baz extension (case-insensitive).
pub fn isBazPath(path: []const u8) bool {
    if (path.len < 4) return false;
    const ext = path[path.len - 4 ..];
    return (ext[0] == '.' and
        (ext[1] == 'b' or ext[1] == 'B') and
        (ext[2] == 'a' or ext[2] == 'A') and
        (ext[3] == 'z' or ext[3] == 'Z'));
}

/// Change a file path's extension to .baz.
/// If the path already has an extension, it is replaced.
/// Returns a newly allocated string. Caller must free.
pub fn toBazPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    // Find the last dot
    var dot_pos: ?usize = null;
    var i: usize = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '.') {
            dot_pos = i;
            break;
        }
        if (path[i] == '/' or path[i] == '\\') break;
    }

    if (dot_pos) |dp| {
        // Replace extension
        const base = path[0..dp];
        const result = try allocator.alloc(u8, base.len + 4);
        @memcpy(result[0..base.len], base);
        @memcpy(result[base.len..][0..4], ".baz");
        return result;
    } else {
        // Append extension
        const result = try allocator.alloc(u8, path.len + 4);
        @memcpy(result[0..path.len], path);
        @memcpy(result[path.len..][0..4], ".baz");
        return result;
    }
}

// ============================================================================
// Tests
// ============================================================================

test "isBazPath recognizes .baz extension" {
    try std.testing.expect(isBazPath("hello.baz"));
    try std.testing.expect(isBazPath("/path/to/file.baz"));
    try std.testing.expect(isBazPath("FILE.BAZ"));
    try std.testing.expect(isBazPath("test.Baz"));
    try std.testing.expect(!isBazPath("hello.bas"));
    try std.testing.expect(!isBazPath("hello.ba"));
    try std.testing.expect(!isBazPath(".ba"));
    try std.testing.expect(!isBazPath("baz"));
}

test "toBazPath replaces extension" {
    const allocator = std.testing.allocator;

    const r1 = try toBazPath(allocator, "hello.bas");
    defer allocator.free(r1);
    try std.testing.expectEqualStrings("hello.baz", r1);

    const r2 = try toBazPath(allocator, "/path/to/file.txt");
    defer allocator.free(r2);
    try std.testing.expectEqualStrings("/path/to/file.baz", r2);

    const r3 = try toBazPath(allocator, "noext");
    defer allocator.free(r3);
    try std.testing.expectEqualStrings("noext.baz", r3);
}

test "roundtrip save and load" {
    const allocator = std.testing.allocator;

    // Create some test codepoints (including non-ASCII)
    const codepoints = [_]u32{ 'H', 'E', 'L', 'L', 'O', ' ', 0x2713, '\n', 'B', 'Y', 'E' };

    // Save to a temp file
    const tmp_path = "/tmp/ed_baz_test_roundtrip.baz";

    try saveBaz(allocator, tmp_path, &codepoints);

    // Load it back
    const loaded = try loadBaz(allocator, tmp_path);
    defer allocator.free(loaded);

    try std.testing.expectEqual(codepoints.len, loaded.len);
    for (codepoints, loaded) |expected, actual| {
        try std.testing.expectEqual(expected, actual);
    }

    // Clean up
    std.fs.cwd().deleteFile(tmp_path) catch {};
}

test "loadBaz rejects non-baz file" {
    const allocator = std.testing.allocator;

    const tmp_path = "/tmp/ed_baz_test_bad.baz";

    // Write garbage
    {
        const f = try std.fs.cwd().createFile(tmp_path, .{});
        defer f.close();
        try f.writeAll("this is not a baz file at all!!");
    }

    const result = loadBaz(allocator, tmp_path);
    try std.testing.expect(result == BazError.InvalidMagic);

    std.fs.cwd().deleteFile(tmp_path) catch {};
}

test "loadBaz rejects too-small file" {
    const allocator = std.testing.allocator;

    const tmp_path = "/tmp/ed_baz_test_tiny.baz";

    // Write just 4 bytes (less than header)
    {
        const f = try std.fs.cwd().createFile(tmp_path, .{});
        defer f.close();
        try f.writeAll("BAZ1");
    }

    const result = loadBaz(allocator, tmp_path);
    try std.testing.expect(result == BazError.FileTooSmall);

    std.fs.cwd().deleteFile(tmp_path) catch {};
}

test "roundtrip empty codepoints" {
    const allocator = std.testing.allocator;
    const tmp_path = "/tmp/ed_baz_test_empty.baz";

    const empty = [_]u32{};
    try saveBaz(allocator, tmp_path, &empty);

    const loaded = try loadBaz(allocator, tmp_path);
    defer allocator.free(loaded);

    try std.testing.expectEqual(@as(usize, 0), loaded.len);

    std.fs.cwd().deleteFile(tmp_path) catch {};
}

test "roundtrip large buffer" {
    const allocator = std.testing.allocator;
    const tmp_path = "/tmp/ed_baz_test_large.baz";

    // Build a large buffer (64K codepoints — should compress well)
    const n = 65536;
    const big = try allocator.alloc(u32, n);
    defer allocator.free(big);
    for (big, 0..) |*cp, i| {
        cp.* = @intCast('A' + (i % 26));
    }

    try saveBaz(allocator, tmp_path, big);

    const loaded = try loadBaz(allocator, tmp_path);
    defer allocator.free(loaded);

    try std.testing.expectEqual(n, loaded.len);
    for (big, loaded) |expected, actual| {
        try std.testing.expectEqual(expected, actual);
    }

    // Verify it actually compressed (64K * 4 = 256KB uncompressed)
    const stat = try std.fs.cwd().statFile(tmp_path);
    // Should be much smaller than 256KB + 8 byte header
    try std.testing.expect(stat.size < 256 * 1024);

    std.fs.cwd().deleteFile(tmp_path) catch {};
}
