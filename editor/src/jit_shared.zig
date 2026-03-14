const std = @import("std");

const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("sys/mman.h");
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
});

pub const SOURCE_CAPACITY: usize = 8 * 1024 * 1024;
pub const RING_CAPACITY: usize = 1024 * 1024;

pub const Header = extern struct {
    source_len: u32 = 0,
    output_write: u32 = 0,
    error_write: u32 = 0,
    input_write: u32 = 0,
    stop_requested: u32 = 0,
    exit_code: i32 = 0,
    compile_ns: u64 = 0,
    exec_ns: u64 = 0,
};

const HEADER_SIZE: usize = @sizeOf(Header);
const SOURCE_OFFSET: usize = HEADER_SIZE;
const INPUT_OFFSET: usize = SOURCE_OFFSET + SOURCE_CAPACITY;
const OUTPUT_OFFSET: usize = INPUT_OFFSET + RING_CAPACITY;
const ERROR_OFFSET: usize = OUTPUT_OFFSET + RING_CAPACITY;
pub const TOTAL_SIZE: usize = ERROR_OFFSET + RING_CAPACITY;

pub const SharedRegion = struct {
    fd: c_int,
    map_ptr: *anyopaque,
    name_len: usize,
    name_buf: [256]u8,

    header: *Header,
    source: []u8,
    input: []u8,
    output: []u8,
    err: []u8,
};

pub fn create(name_z: [:0]const u8) !SharedRegion {
    const fd = c.shm_open(name_z.ptr, c.O_CREAT | c.O_EXCL | c.O_RDWR, @as(c_uint, 0o600));
    if (fd < 0) return error.ShmOpenFailed;
    errdefer _ = c.close(fd);

    if (c.ftruncate(fd, @as(c_long, @intCast(TOTAL_SIZE))) != 0) {
        return error.TruncateFailed;
    }

    const map_ptr_opt = c.mmap(null, TOTAL_SIZE, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, 0);
    if (map_ptr_opt == c.MAP_FAILED) return error.MmapFailed;
    const map_ptr = map_ptr_opt orelse return error.MmapFailed;
    errdefer _ = c.munmap(map_ptr, TOTAL_SIZE);

    @memset(@as([*]u8, @ptrCast(map_ptr))[0..TOTAL_SIZE], 0);

    const region = makeRegion(fd, map_ptr, name_z);
    region.header.* = .{};
    return region;
}

pub fn open(name_z: [:0]const u8) !SharedRegion {
    const fd = c.shm_open(name_z.ptr, c.O_RDWR);
    if (fd < 0) return error.ShmOpenFailed;
    errdefer _ = c.close(fd);

    const map_ptr_opt = c.mmap(null, TOTAL_SIZE, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, 0);
    if (map_ptr_opt == c.MAP_FAILED) return error.MmapFailed;
    const map_ptr = map_ptr_opt orelse return error.MmapFailed;

    return makeRegion(fd, map_ptr, name_z);
}

fn makeRegion(fd: c_int, map_ptr: *anyopaque, name_z: [:0]const u8) SharedRegion {
    var name_buf: [256]u8 = [_]u8{0} ** 256;
    const copy_len = @min(name_z.len, name_buf.len - 1);
    @memcpy(name_buf[0..copy_len], name_z[0..copy_len]);

    const base: [*]u8 = @ptrCast(map_ptr);

    return .{
        .fd = fd,
        .map_ptr = map_ptr,
        .name_len = copy_len,
        .name_buf = name_buf,
        .header = @ptrCast(@alignCast(base + HEADER_SIZE - HEADER_SIZE)),
        .source = base[SOURCE_OFFSET .. SOURCE_OFFSET + SOURCE_CAPACITY],
        .input = base[INPUT_OFFSET .. INPUT_OFFSET + RING_CAPACITY],
        .output = base[OUTPUT_OFFSET .. OUTPUT_OFFSET + RING_CAPACITY],
        .err = base[ERROR_OFFSET .. ERROR_OFFSET + RING_CAPACITY],
    };
}

pub fn close(region: *SharedRegion) void {
    _ = c.munmap(region.map_ptr, TOTAL_SIZE);
    _ = c.close(region.fd);
}

pub fn unlink(region: *const SharedRegion) void {
    _ = c.shm_unlink(@as([*:0]const u8, @ptrCast(&region.name_buf[0])));
}

pub fn ringWrite(buffer: []u8, write_ptr: *u32, data: []const u8) void {
    if (buffer.len == 0) return;
    const cap: u32 = @intCast(buffer.len);
    var w = @atomicLoad(u32, write_ptr, .acquire);

    for (data) |b| {
        buffer[w] = b;
        w +%= 1;
        if (w >= cap) w = 0;
    }

    @atomicStore(u32, write_ptr, w, .release);
}

pub fn ringRead(buffer: []const u8, read_pos: *u32, write_pos: u32, out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !void {
    if (buffer.len == 0) return;
    const cap: u32 = @intCast(buffer.len);
    var r = read_pos.*;

    while (r != write_pos) {
        try out.append(allocator, buffer[r]);
        r +%= 1;
        if (r >= cap) r = 0;
    }

    read_pos.* = r;
}
