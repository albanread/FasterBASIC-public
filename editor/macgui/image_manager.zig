const std = @import("std");

pub const ImageFormat = enum(u8) {
    rgba8 = 1,
};

pub const ImageInfo = struct {
    id: u16,
    width: u32,
    height: u32,
    stride: u32,
    format: ImageFormat,
};

pub const ImageView = struct {
    ptr: [*]const u8,
    width: u32,
    height: u32,
    stride: u32,
};

const ImageRecord = struct {
    info: ImageInfo,
    pixels: []u8 = &.{},
};

const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

const BlendMode = enum(u8) {
    normal = 0,
    add = 1,
    multiply = 2,
    screen = 3,
    subtract = 4,
    xor = 5,
};

const DrawState = struct {
    paper: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    stroke: Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    fill: Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    line_width: i32 = 1,
    fill_explicit: bool = false,
    img_dest_x: i32 = 0,
    img_dest_y: i32 = 0,
    img_dest_w: i32 = 0,
    img_dest_h: i32 = 0,
    img_src_x: i32 = 0,
    img_src_y: i32 = 0,
    img_src_w: i32 = 0,
    img_src_h: i32 = 0,
    img_alpha: i32 = 255,
    img_blend: i32 = 0,
};

const PathPoint = struct {
    x: i32,
    y: i32,
    move: bool,
};

const PATH_MAX_POINTS: usize = 4096;

const PathState = struct {
    points: [PATH_MAX_POINTS]PathPoint = undefined,
    count: usize = 0,
    has_current: bool = false,
    current_x: f64 = 0.0,
    current_y: f64 = 0.0,
    contour_start: usize = 0,
};

const Map = std.AutoHashMapUnmanaged(u16, ImageRecord);

var g_lock: std.Thread.Mutex = .{};
var g_images: Map = .{};

inline fn alloc() std.mem.Allocator {
    return std.heap.c_allocator;
}

fn bytesPerPixel(format: ImageFormat) u32 {
    return switch (format) {
        .rgba8 => 4,
    };
}

fn freeRecord(rec: *ImageRecord) void {
    if (rec.pixels.len > 0) {
        alloc().free(rec.pixels);
        rec.pixels = &.{};
    }
}

pub fn define(id: u16, width: u32, height: u32, format: ImageFormat) bool {
    if (id == 0 or width == 0 or height == 0) return false;

    const bpp = bytesPerPixel(format);
    const stride64 = @as(u64, width) * @as(u64, bpp);
    const bytes64 = stride64 * @as(u64, height);
    if (stride64 > std.math.maxInt(u32) or bytes64 > std.math.maxInt(usize)) return false;

    const stride: u32 = @intCast(stride64);
    const bytes: usize = @intCast(bytes64);

    const pixels = alloc().alloc(u8, bytes) catch return false;
    @memset(pixels, 0);

    g_lock.lock();
    defer g_lock.unlock();

    if (g_images.getPtr(id)) |existing| {
        freeRecord(existing);
        existing.* = .{
            .info = .{ .id = id, .width = width, .height = height, .stride = stride, .format = format },
            .pixels = pixels,
        };
        return true;
    }

    g_images.put(alloc(), id, .{
        .info = .{ .id = id, .width = width, .height = height, .stride = stride, .format = format },
        .pixels = pixels,
    }) catch {
        alloc().free(pixels);
        return false;
    };
    return true;
}

pub fn destroy(id: u16) void {
    g_lock.lock();
    defer g_lock.unlock();

    if (g_images.fetchRemove(id)) |entry| {
        var rec = entry.value;
        freeRecord(&rec);
    }
}

pub fn clear() void {
    g_lock.lock();
    defer g_lock.unlock();

    var it = g_images.iterator();
    while (it.next()) |entry| {
        freeRecord(entry.value_ptr);
    }
    g_images.clearRetainingCapacity();
}

pub fn shutdown() void {
    g_lock.lock();
    defer g_lock.unlock();

    var it = g_images.iterator();
    while (it.next()) |entry| {
        freeRecord(entry.value_ptr);
    }
    g_images.deinit(alloc());
    g_images = .{};
}

pub fn exists(id: u16) bool {
    g_lock.lock();
    defer g_lock.unlock();
    return g_images.contains(id);
}

pub fn getInfo(id: u16) ?ImageInfo {
    g_lock.lock();
    defer g_lock.unlock();
    const rec = g_images.get(id) orelse return null;
    return rec.info;
}

pub fn getRgbaView(id: u16) ?ImageView {
    g_lock.lock();
    defer g_lock.unlock();

    const rec = g_images.get(id) orelse return null;
    if (rec.info.format != .rgba8 or rec.pixels.len == 0) return null;
    return .{
        .ptr = rec.pixels.ptr,
        .width = rec.info.width,
        .height = rec.info.height,
        .stride = rec.info.stride,
    };
}

pub fn setPixelsRgba8(id: u16, src_ptr: ?[*]const u8, src_len: usize, src_stride: u32) bool {
    const src = src_ptr orelse return false;

    g_lock.lock();
    defer g_lock.unlock();

    const rec = g_images.getPtr(id) orelse return false;
    if (rec.info.format != .rgba8) return false;

    const min_stride = rec.info.width * bytesPerPixel(.rgba8);
    const stride = if (src_stride == 0) min_stride else src_stride;
    if (stride < min_stride) return false;

    const needed64 = @as(u64, stride) * @as(u64, rec.info.height);
    if (needed64 > std.math.maxInt(usize)) return false;
    const needed: usize = @intCast(needed64);
    if (src_len < needed) return false;

    const dst_stride = rec.info.stride;
    const row_bytes: usize = @intCast(min_stride);
    const src_stride_usize: usize = @intCast(stride);
    const dst_stride_usize: usize = @intCast(dst_stride);
    var row: u32 = 0;
    while (row < rec.info.height) : (row += 1) {
        const src_off = @as(usize, row) * src_stride_usize;
        const dst_off = @as(usize, row) * dst_stride_usize;
        @memcpy(rec.pixels[dst_off .. dst_off + row_bytes], src[src_off .. src_off + row_bytes]);
    }

    return true;
}

inline fn clampF64(v: f64, lo: f64, hi: f64) f64 {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

inline fn lumaAt(pixels: []const u8, stride: usize, x: usize, y: usize) f64 {
    const off = y * stride + x * 4;
    const r = @as(f64, @floatFromInt(pixels[off + 0]));
    const g = @as(f64, @floatFromInt(pixels[off + 1]));
    const b = @as(f64, @floatFromInt(pixels[off + 2]));
    return 0.299 * r + 0.587 * g + 0.114 * b;
}

fn applyFxaaLike(rec: *ImageRecord, threshold_in: f64, strength_in: f64) bool {
    const width = rec.info.width;
    const height = rec.info.height;
    if (width < 3 or height < 3) return true;

    const threshold = clampF64(if (threshold_in > 0.0) threshold_in else 0.08, 0.01, 0.5) * 255.0;
    const strength = clampF64(if (strength_in > 0.0) strength_in else 0.75, 0.0, 1.0);

    const src = alloc().alloc(u8, rec.pixels.len) catch return false;
    defer alloc().free(src);
    @memcpy(src, rec.pixels);

    const stride: usize = @intCast(rec.info.stride);
    var y: usize = 1;
    while (y + 1 < height) : (y += 1) {
        var x: usize = 1;
        while (x + 1 < width) : (x += 1) {
            const l_c = lumaAt(src, stride, x, y);
            const l_l = lumaAt(src, stride, x - 1, y);
            const l_r = lumaAt(src, stride, x + 1, y);
            const l_u = lumaAt(src, stride, x, y - 1);
            const l_d = lumaAt(src, stride, x, y + 1);

            var l_min = l_c;
            var l_max = l_c;
            if (l_l < l_min) l_min = l_l;
            if (l_r < l_min) l_min = l_r;
            if (l_u < l_min) l_min = l_u;
            if (l_d < l_min) l_min = l_d;
            if (l_l > l_max) l_max = l_l;
            if (l_r > l_max) l_max = l_r;
            if (l_u > l_max) l_max = l_u;
            if (l_d > l_max) l_max = l_d;

            if ((l_max - l_min) <= threshold) continue;

            const off_c = y * stride + x * 4;
            const off_l = y * stride + (x - 1) * 4;
            const off_r = y * stride + (x + 1) * 4;
            const off_u = (y - 1) * stride + x * 4;
            const off_d = (y + 1) * stride + x * 4;

            var ch: usize = 0;
            while (ch < 3) : (ch += 1) {
                const c = @as(f64, @floatFromInt(src[off_c + ch]));
                const avg = (@as(f64, @floatFromInt(src[off_l + ch])) + @as(f64, @floatFromInt(src[off_r + ch])) + @as(f64, @floatFromInt(src[off_u + ch])) + @as(f64, @floatFromInt(src[off_d + ch]))) * 0.25;
                const out = c * (1.0 - strength) + avg * strength;
                rec.pixels[off_c + ch] = @intFromFloat(@round(clampF64(out, 0.0, 255.0)));
            }
            rec.pixels[off_c + 3] = src[off_c + 3];
        }
    }

    return true;
}

fn applyBoxBlur(rec: *ImageRecord, radius_in: f64, iterations_in: f64) bool {
    const width = rec.info.width;
    const height = rec.info.height;
    if (width < 2 or height < 2) return true;

    const radius: usize = @intFromFloat(@round(clampF64(if (radius_in > 0.0) radius_in else 1.0, 1.0, 4.0)));
    const iterations: usize = @intFromFloat(@round(clampF64(if (iterations_in > 0.0) iterations_in else 1.0, 1.0, 4.0)));
    const stride: usize = @intCast(rec.info.stride);

    const tmp = alloc().alloc(u8, rec.pixels.len) catch return false;
    defer alloc().free(tmp);

    var it: usize = 0;
    while (it < iterations) : (it += 1) {
        @memcpy(tmp, rec.pixels);

        var y: usize = 0;
        while (y < height) : (y += 1) {
            var x: usize = 0;
            while (x < width) : (x += 1) {
                var sum: [4]u32 = .{ 0, 0, 0, 0 };
                var count: u32 = 0;

                const y0 = if (y > radius) y - radius else 0;
                const x0 = if (x > radius) x - radius else 0;
                const y1 = @min(height - 1, y + radius);
                const x1 = @min(width - 1, x + radius);

                var yy = y0;
                while (yy <= y1) : (yy += 1) {
                    var xx = x0;
                    while (xx <= x1) : (xx += 1) {
                        const off = yy * stride + xx * 4;
                        sum[0] += tmp[off + 0];
                        sum[1] += tmp[off + 1];
                        sum[2] += tmp[off + 2];
                        sum[3] += tmp[off + 3];
                        count += 1;
                    }
                }

                const off = y * stride + x * 4;
                rec.pixels[off + 0] = @intCast((sum[0] + count / 2) / count);
                rec.pixels[off + 1] = @intCast((sum[1] + count / 2) / count);
                rec.pixels[off + 2] = @intCast((sum[2] + count / 2) / count);
                rec.pixels[off + 3] = @intCast((sum[3] + count / 2) / count);
            }
        }
    }

    return true;
}

fn applyGrayscale(rec: *ImageRecord, amount_in: f64) bool {
    const amount = clampF64(if (amount_in != 0.0) amount_in else 1.0, 0.0, 1.0);
    if (amount <= 0.0) return true;

    const stride: usize = @intCast(rec.info.stride);
    var y: usize = 0;
    while (y < rec.info.height) : (y += 1) {
        var x: usize = 0;
        while (x < rec.info.width) : (x += 1) {
            const off = y * stride + x * 4;
            const r = @as(f64, @floatFromInt(rec.pixels[off + 0]));
            const g = @as(f64, @floatFromInt(rec.pixels[off + 1]));
            const b = @as(f64, @floatFromInt(rec.pixels[off + 2]));
            const l = 0.299 * r + 0.587 * g + 0.114 * b;
            const out_r = r * (1.0 - amount) + l * amount;
            const out_g = g * (1.0 - amount) + l * amount;
            const out_b = b * (1.0 - amount) + l * amount;
            rec.pixels[off + 0] = @intFromFloat(@round(clampF64(out_r, 0.0, 255.0)));
            rec.pixels[off + 1] = @intFromFloat(@round(clampF64(out_g, 0.0, 255.0)));
            rec.pixels[off + 2] = @intFromFloat(@round(clampF64(out_b, 0.0, 255.0)));
        }
    }
    return true;
}

fn applySepia(rec: *ImageRecord, amount_in: f64) bool {
    const amount = clampF64(if (amount_in != 0.0) amount_in else 1.0, 0.0, 1.0);
    if (amount <= 0.0) return true;

    const stride: usize = @intCast(rec.info.stride);
    var y: usize = 0;
    while (y < rec.info.height) : (y += 1) {
        var x: usize = 0;
        while (x < rec.info.width) : (x += 1) {
            const off = y * stride + x * 4;
            const r = @as(f64, @floatFromInt(rec.pixels[off + 0]));
            const g = @as(f64, @floatFromInt(rec.pixels[off + 1]));
            const b = @as(f64, @floatFromInt(rec.pixels[off + 2]));

            const sr = clampF64(0.393 * r + 0.769 * g + 0.189 * b, 0.0, 255.0);
            const sg = clampF64(0.349 * r + 0.686 * g + 0.168 * b, 0.0, 255.0);
            const sb = clampF64(0.272 * r + 0.534 * g + 0.131 * b, 0.0, 255.0);

            const out_r = r * (1.0 - amount) + sr * amount;
            const out_g = g * (1.0 - amount) + sg * amount;
            const out_b = b * (1.0 - amount) + sb * amount;

            rec.pixels[off + 0] = @intFromFloat(@round(clampF64(out_r, 0.0, 255.0)));
            rec.pixels[off + 1] = @intFromFloat(@round(clampF64(out_g, 0.0, 255.0)));
            rec.pixels[off + 2] = @intFromFloat(@round(clampF64(out_b, 0.0, 255.0)));
        }
    }
    return true;
}

fn applyInvert(rec: *ImageRecord, amount_in: f64) bool {
    const amount = clampF64(if (amount_in != 0.0) amount_in else 1.0, 0.0, 1.0);
    if (amount <= 0.0) return true;

    const stride: usize = @intCast(rec.info.stride);
    var y: usize = 0;
    while (y < rec.info.height) : (y += 1) {
        var x: usize = 0;
        while (x < rec.info.width) : (x += 1) {
            const off = y * stride + x * 4;
            var ch: usize = 0;
            while (ch < 3) : (ch += 1) {
                const c = @as(f64, @floatFromInt(rec.pixels[off + ch]));
                const inv = 255.0 - c;
                const out = c * (1.0 - amount) + inv * amount;
                rec.pixels[off + ch] = @intFromFloat(@round(clampF64(out, 0.0, 255.0)));
            }
        }
    }
    return true;
}

fn applyBrightness(rec: *ImageRecord, delta_in: f64) bool {
    const delta = clampF64(if (delta_in != 0.0) delta_in else 0.12, -1.0, 1.0) * 255.0;

    const stride: usize = @intCast(rec.info.stride);
    var y: usize = 0;
    while (y < rec.info.height) : (y += 1) {
        var x: usize = 0;
        while (x < rec.info.width) : (x += 1) {
            const off = y * stride + x * 4;
            var ch: usize = 0;
            while (ch < 3) : (ch += 1) {
                const c = @as(f64, @floatFromInt(rec.pixels[off + ch]));
                rec.pixels[off + ch] = @intFromFloat(@round(clampF64(c + delta, 0.0, 255.0)));
            }
        }
    }
    return true;
}

fn applyContrast(rec: *ImageRecord, factor_in: f64) bool {
    const factor = clampF64(if (factor_in != 0.0) factor_in else 1.2, 0.0, 4.0);

    const stride: usize = @intCast(rec.info.stride);
    var y: usize = 0;
    while (y < rec.info.height) : (y += 1) {
        var x: usize = 0;
        while (x < rec.info.width) : (x += 1) {
            const off = y * stride + x * 4;
            var ch: usize = 0;
            while (ch < 3) : (ch += 1) {
                const c = @as(f64, @floatFromInt(rec.pixels[off + ch]));
                const out = (c - 128.0) * factor + 128.0;
                rec.pixels[off + ch] = @intFromFloat(@round(clampF64(out, 0.0, 255.0)));
            }
        }
    }
    return true;
}

fn applySaturation(rec: *ImageRecord, factor_in: f64) bool {
    const factor = clampF64(if (factor_in != 0.0) factor_in else 1.25, 0.0, 4.0);

    const stride: usize = @intCast(rec.info.stride);
    var y: usize = 0;
    while (y < rec.info.height) : (y += 1) {
        var x: usize = 0;
        while (x < rec.info.width) : (x += 1) {
            const off = y * stride + x * 4;
            const r = @as(f64, @floatFromInt(rec.pixels[off + 0]));
            const g = @as(f64, @floatFromInt(rec.pixels[off + 1]));
            const b = @as(f64, @floatFromInt(rec.pixels[off + 2]));
            const l = 0.299 * r + 0.587 * g + 0.114 * b;

            const out_r = l + (r - l) * factor;
            const out_g = l + (g - l) * factor;
            const out_b = l + (b - l) * factor;

            rec.pixels[off + 0] = @intFromFloat(@round(clampF64(out_r, 0.0, 255.0)));
            rec.pixels[off + 1] = @intFromFloat(@round(clampF64(out_g, 0.0, 255.0)));
            rec.pixels[off + 2] = @intFromFloat(@round(clampF64(out_b, 0.0, 255.0)));
        }
    }
    return true;
}

fn applySharpen(rec: *ImageRecord, amount_in: f64) bool {
    const width = rec.info.width;
    const height = rec.info.height;
    if (width < 3 or height < 3) return true;

    const amount = clampF64(if (amount_in != 0.0) amount_in else 1.0, 0.0, 3.0);
    if (amount <= 0.0) return true;

    const src = alloc().alloc(u8, rec.pixels.len) catch return false;
    defer alloc().free(src);
    @memcpy(src, rec.pixels);

    const stride: usize = @intCast(rec.info.stride);
    var y: usize = 1;
    while (y + 1 < height) : (y += 1) {
        var x: usize = 1;
        while (x + 1 < width) : (x += 1) {
            const off_c = y * stride + x * 4;
            const off_l = y * stride + (x - 1) * 4;
            const off_r = y * stride + (x + 1) * 4;
            const off_u = (y - 1) * stride + x * 4;
            const off_d = (y + 1) * stride + x * 4;

            var ch: usize = 0;
            while (ch < 3) : (ch += 1) {
                const c = @as(f64, @floatFromInt(src[off_c + ch]));
                const avg = (@as(f64, @floatFromInt(src[off_l + ch])) + @as(f64, @floatFromInt(src[off_r + ch])) + @as(f64, @floatFromInt(src[off_u + ch])) + @as(f64, @floatFromInt(src[off_d + ch]))) * 0.25;
                const out = c + (c - avg) * amount;
                rec.pixels[off_c + ch] = @intFromFloat(@round(clampF64(out, 0.0, 255.0)));
            }
            rec.pixels[off_c + 3] = src[off_c + 3];
        }
    }

    return true;
}

fn applyGamma(rec: *ImageRecord, gamma_in: f64) bool {
    const gamma = clampF64(if (gamma_in != 0.0) gamma_in else 1.2, 0.1, 5.0);
    const inv_gamma = 1.0 / gamma;

    const stride: usize = @intCast(rec.info.stride);
    var y: usize = 0;
    while (y < rec.info.height) : (y += 1) {
        var x: usize = 0;
        while (x < rec.info.width) : (x += 1) {
            const off = y * stride + x * 4;
            var ch: usize = 0;
            while (ch < 3) : (ch += 1) {
                const c = @as(f64, @floatFromInt(rec.pixels[off + ch])) / 255.0;
                const out = std.math.pow(f64, clampF64(c, 0.0, 1.0), inv_gamma) * 255.0;
                rec.pixels[off + ch] = @intFromFloat(@round(clampF64(out, 0.0, 255.0)));
            }
        }
    }
    return true;
}

fn applyVignette(rec: *ImageRecord, strength_in: f64, softness_in: f64) bool {
    const strength = clampF64(if (strength_in != 0.0) strength_in else 0.55, 0.0, 1.0);
    if (strength <= 0.0) return true;
    const softness = clampF64(if (softness_in != 0.0) softness_in else 1.8, 0.2, 6.0);

    const width = rec.info.width;
    const height = rec.info.height;
    if (width < 2 or height < 2) return true;

    const cx = (@as(f64, @floatFromInt(width - 1))) * 0.5;
    const cy = (@as(f64, @floatFromInt(height - 1))) * 0.5;
    const max_dist = std.math.sqrt(cx * cx + cy * cy);
    if (max_dist <= 0.0) return true;

    const stride: usize = @intCast(rec.info.stride);
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const fy = @as(f64, @floatFromInt(y));
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const fx = @as(f64, @floatFromInt(x));
            const dx = fx - cx;
            const dy = fy - cy;
            const t = clampF64(std.math.sqrt(dx * dx + dy * dy) / max_dist, 0.0, 1.0);
            const falloff = 1.0 - strength * std.math.pow(f64, t, softness);
            const m = clampF64(falloff, 0.0, 1.0);

            const off = y * stride + x * 4;
            var ch: usize = 0;
            while (ch < 3) : (ch += 1) {
                const c = @as(f64, @floatFromInt(rec.pixels[off + ch]));
                rec.pixels[off + ch] = @intFromFloat(@round(clampF64(c * m, 0.0, 255.0)));
            }
        }
    }
    return true;
}

fn applyEdgeDetect(rec: *ImageRecord, strength_in: f64, threshold_in: f64) bool {
    const width = rec.info.width;
    const height = rec.info.height;
    if (width < 3 or height < 3) return true;

    const strength = clampF64(if (strength_in != 0.0) strength_in else 1.0, 0.1, 4.0);
    const threshold = clampF64(if (threshold_in != 0.0) threshold_in else 0.12, 0.0, 1.0) * 255.0;

    const src = alloc().alloc(u8, rec.pixels.len) catch return false;
    defer alloc().free(src);
    @memcpy(src, rec.pixels);

    const stride: usize = @intCast(rec.info.stride);
    const sobel_max = 1443.0;

    var y: usize = 1;
    while (y + 1 < height) : (y += 1) {
        var x: usize = 1;
        while (x + 1 < width) : (x += 1) {
            const l_tl = lumaAt(src, stride, x - 1, y - 1);
            const l_tc = lumaAt(src, stride, x, y - 1);
            const l_tr = lumaAt(src, stride, x + 1, y - 1);
            const l_ml = lumaAt(src, stride, x - 1, y);
            const l_mr = lumaAt(src, stride, x + 1, y);
            const l_bl = lumaAt(src, stride, x - 1, y + 1);
            const l_bc = lumaAt(src, stride, x, y + 1);
            const l_br = lumaAt(src, stride, x + 1, y + 1);

            const gx = -l_tl + l_tr - 2.0 * l_ml + 2.0 * l_mr - l_bl + l_br;
            const gy = -l_tl - 2.0 * l_tc - l_tr + l_bl + 2.0 * l_bc + l_br;
            var mag = std.math.sqrt(gx * gx + gy * gy);
            mag = clampF64((mag / sobel_max) * 255.0 * strength, 0.0, 255.0);
            if (mag < threshold) mag = 0.0;

            const edge_val: u8 = @intFromFloat(@round(mag));
            const off = y * stride + x * 4;
            rec.pixels[off + 0] = edge_val;
            rec.pixels[off + 1] = edge_val;
            rec.pixels[off + 2] = edge_val;
            rec.pixels[off + 3] = src[off + 3];
        }
    }

    return true;
}

fn applyPosterize(rec: *ImageRecord, levels_in: f64) bool {
    const levels_i: u32 = @intFromFloat(@round(clampF64(if (levels_in > 0.0) levels_in else 6.0, 2.0, 64.0)));
    const levels = @as(f64, @floatFromInt(levels_i));
    const scale = (levels - 1.0) / 255.0;
    const inv = 255.0 / (levels - 1.0);

    const stride: usize = @intCast(rec.info.stride);
    var y: usize = 0;
    while (y < rec.info.height) : (y += 1) {
        var x: usize = 0;
        while (x < rec.info.width) : (x += 1) {
            const off = y * stride + x * 4;
            var ch: usize = 0;
            while (ch < 3) : (ch += 1) {
                const c = @as(f64, @floatFromInt(rec.pixels[off + ch]));
                const q = @round(c * scale) * inv;
                rec.pixels[off + ch] = @intFromFloat(@round(clampF64(q, 0.0, 255.0)));
            }
        }
    }
    return true;
}

pub fn applyEffectByName(id: u16, name_ptr: ?[*]const u8, name_len: usize, p1: f64, p2: f64, _: f64, _: f64) bool {
    const name_raw = name_ptr orelse return false;
    const name = name_raw[0..name_len];

    g_lock.lock();
    defer g_lock.unlock();

    const rec = g_images.getPtr(id) orelse return false;
    if (rec.info.format != .rgba8 or rec.pixels.len == 0) return false;

    if (std.ascii.eqlIgnoreCase(name, "FXAA") or std.ascii.eqlIgnoreCase(name, "FXA")) {
        return applyFxaaLike(rec, p1, p2);
    }
    if (std.ascii.eqlIgnoreCase(name, "BLUR")) {
        return applyBoxBlur(rec, p1, p2);
    }
    if (std.ascii.eqlIgnoreCase(name, "GRAYSCALE") or std.ascii.eqlIgnoreCase(name, "GREYSCALE")) {
        return applyGrayscale(rec, p1);
    }
    if (std.ascii.eqlIgnoreCase(name, "SEPIA")) {
        return applySepia(rec, p1);
    }
    if (std.ascii.eqlIgnoreCase(name, "INVERT")) {
        return applyInvert(rec, p1);
    }
    if (std.ascii.eqlIgnoreCase(name, "BRIGHTNESS")) {
        return applyBrightness(rec, p1);
    }
    if (std.ascii.eqlIgnoreCase(name, "CONTRAST")) {
        return applyContrast(rec, p1);
    }
    if (std.ascii.eqlIgnoreCase(name, "SATURATION") or std.ascii.eqlIgnoreCase(name, "SAT")) {
        return applySaturation(rec, p1);
    }
    if (std.ascii.eqlIgnoreCase(name, "SHARPEN")) {
        return applySharpen(rec, p1);
    }
    if (std.ascii.eqlIgnoreCase(name, "GAMMA")) {
        return applyGamma(rec, p1);
    }
    if (std.ascii.eqlIgnoreCase(name, "VIGNETTE")) {
        return applyVignette(rec, p1, p2);
    }
    if (std.ascii.eqlIgnoreCase(name, "EDGE") or std.ascii.eqlIgnoreCase(name, "EDGES") or std.ascii.eqlIgnoreCase(name, "EDGEDETECT") or std.ascii.eqlIgnoreCase(name, "EDGE_DETECT")) {
        return applyEdgeDetect(rec, p1, p2);
    }
    if (std.ascii.eqlIgnoreCase(name, "POSTERIZE") or std.ascii.eqlIgnoreCase(name, "POSTERISE")) {
        return applyPosterize(rec, p1);
    }

    return false;
}

inline fn toI32Rounded(v: f64) i32 {
    return @intFromFloat(@round(v));
}

inline fn clampI32(v: i32, lo: i32, hi: i32) i32 {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

fn colorFromPacked(argb_double: f64) Color {
    const argb: u32 = @intFromFloat(argb_double);
    return .{
        .a = @intCast((argb >> 24) & 0xFF),
        .r = @intCast((argb >> 16) & 0xFF),
        .g = @intCast((argb >> 8) & 0xFF),
        .b = @intCast(argb & 0xFF),
    };
}

fn clampBlendMode(v: i32) BlendMode {
    const clamped = clampI32(v, 0, 5);
    return @enumFromInt(@as(u8, @intCast(clamped)));
}

inline fn blendChannel(mode: BlendMode, src: u8, dst: u8) u32 {
    return switch (mode) {
        .normal => @as(u32, src),
        .add => @min(@as(u32, src) + @as(u32, dst), 255),
        .multiply => (@as(u32, src) * @as(u32, dst) + 127) / 255,
        .screen => 255 - ((255 - @as(u32, src)) * (255 - @as(u32, dst)) + 127) / 255,
        .subtract => if (dst > src) @as(u32, dst) - @as(u32, src) else 0,
        .xor => @as(u32, src) ^ @as(u32, dst),
    };
}

fn blendPixelMode(rec: *ImageRecord, x: i32, y: i32, src: Color, alpha_override: u8, mode: BlendMode) void {
    if (x < 0 or y < 0) return;
    const ux: u32 = @intCast(x);
    const uy: u32 = @intCast(y);
    if (ux >= rec.info.width or uy >= rec.info.height) return;

    const off = @as(usize, uy) * @as(usize, rec.info.stride) + @as(usize, ux) * 4;
    const dst_r = rec.pixels[off + 0];
    const dst_g = rec.pixels[off + 1];
    const dst_b = rec.pixels[off + 2];
    const dst_a = rec.pixels[off + 3];

    const eff_a: u32 = (@as(u32, src.a) * @as(u32, alpha_override) + 127) / 255;
    if (eff_a == 0) return;
    const inv: u32 = 255 - eff_a;

    const r_mode = blendChannel(mode, src.r, dst_r);
    const g_mode = blendChannel(mode, src.g, dst_g);
    const b_mode = blendChannel(mode, src.b, dst_b);

    const out_r: u32 = (r_mode * eff_a + @as(u32, dst_r) * inv + 127) / 255;
    const out_g: u32 = (g_mode * eff_a + @as(u32, dst_g) * inv + 127) / 255;
    const out_b: u32 = (b_mode * eff_a + @as(u32, dst_b) * inv + 127) / 255;
    const out_a: u32 = @min(255, eff_a + ((@as(u32, dst_a) * inv + 127) / 255));

    rec.pixels[off + 0] = @intCast(out_r);
    rec.pixels[off + 1] = @intCast(out_g);
    rec.pixels[off + 2] = @intCast(out_b);
    rec.pixels[off + 3] = @intCast(out_a);
}

fn blendPixel(rec: *ImageRecord, x: i32, y: i32, src: Color) void {
    if (x < 0 or y < 0) return;
    const ux: u32 = @intCast(x);
    const uy: u32 = @intCast(y);
    if (ux >= rec.info.width or uy >= rec.info.height) return;

    const off = @as(usize, uy) * @as(usize, rec.info.stride) + @as(usize, ux) * 4;
    const dst_r = rec.pixels[off + 0];
    const dst_g = rec.pixels[off + 1];
    const dst_b = rec.pixels[off + 2];
    const dst_a = rec.pixels[off + 3];

    const a = @as(u32, src.a);
    if (a == 0) return;
    if (a == 255) {
        rec.pixels[off + 0] = src.r;
        rec.pixels[off + 1] = src.g;
        rec.pixels[off + 2] = src.b;
        rec.pixels[off + 3] = src.a;
        return;
    }

    const inv = 255 - a;
    rec.pixels[off + 0] = @intCast((@as(u32, src.r) * a + @as(u32, dst_r) * inv + 127) / 255);
    rec.pixels[off + 1] = @intCast((@as(u32, src.g) * a + @as(u32, dst_g) * inv + 127) / 255);
    rec.pixels[off + 2] = @intCast((@as(u32, src.b) * a + @as(u32, dst_b) * inv + 127) / 255);
    rec.pixels[off + 3] = @intCast(a + ((@as(u32, dst_a) * inv + 127) / 255));
}

fn fillRect(rec: *ImageRecord, x: i32, y: i32, w: i32, h: i32, color: Color) void {
    if (w <= 0 or h <= 0) return;
    const x0 = clampI32(x, 0, @as(i32, @intCast(rec.info.width)) - 1);
    const y0 = clampI32(y, 0, @as(i32, @intCast(rec.info.height)) - 1);
    const x1 = clampI32(x + w - 1, 0, @as(i32, @intCast(rec.info.width)) - 1);
    const y1 = clampI32(y + h - 1, 0, @as(i32, @intCast(rec.info.height)) - 1);
    if (x1 < x0 or y1 < y0) return;

    var py = y0;
    while (py <= y1) : (py += 1) {
        var px = x0;
        while (px <= x1) : (px += 1) {
            blendPixel(rec, px, py, color);
        }
    }
}

fn drawLine(rec: *ImageRecord, x0_in: i32, y0_in: i32, x1: i32, y1: i32, color: Color, line_width: i32) void {
    var x0 = x0_in;
    var y0 = y0_in;
    const dx: i32 = @intCast(@abs(x1 - x0));
    const sx: i32 = if (x0 < x1) 1 else -1;
    const dy: i32 = -@as(i32, @intCast(@abs(y1 - y0)));
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err = dx + dy;

    const lw: i32 = @max(line_width, 1);
    const half: i32 = @divTrunc(lw, 2);

    while (true) {
        var oy = -half;
        while (oy <= half) : (oy += 1) {
            var ox = -half;
            while (ox <= half) : (ox += 1) {
                blendPixel(rec, x0 + ox, y0 + oy, color);
            }
        }

        if (x0 == x1 and y0 == y1) break;
        const e2 = err * 2;
        if (e2 >= dy) {
            err += dy;
            x0 += sx;
        }
        if (e2 <= dx) {
            err += dx;
            y0 += sy;
        }
    }
}

fn drawCircle(rec: *ImageRecord, cx: i32, cy: i32, r: i32, filled: bool, color: Color, line_width: i32) void {
    if (r <= 0) return;
    if (filled) {
        var y = -r;
        while (y <= r) : (y += 1) {
            const xx = @as(i32, @intFromFloat(@floor(@sqrt(@as(f64, @floatFromInt(r * r - y * y))))));
            drawLine(rec, cx - xx, cy + y, cx + xx, cy + y, color, 1);
        }
        return;
    }

    var x = r;
    var y: i32 = 0;
    var err: i32 = 1 - x;
    while (x >= y) {
        drawLine(rec, cx + x, cy + y, cx + x, cy + y, color, line_width);
        drawLine(rec, cx + y, cy + x, cx + y, cy + x, color, line_width);
        drawLine(rec, cx - y, cy + x, cx - y, cy + x, color, line_width);
        drawLine(rec, cx - x, cy + y, cx - x, cy + y, color, line_width);
        drawLine(rec, cx - x, cy - y, cx - x, cy - y, color, line_width);
        drawLine(rec, cx - y, cy - x, cx - y, cy - x, color, line_width);
        drawLine(rec, cx + y, cy - x, cx + y, cy - x, color, line_width);
        drawLine(rec, cx + x, cy - y, cx + x, cy - y, color, line_width);
        y += 1;
        if (err < 0) {
            err += 2 * y + 1;
        } else {
            x -= 1;
            err += 2 * (y - x) + 1;
        }
    }
}

fn drawEllipse(rec: *ImageRecord, cx: i32, cy: i32, rx: i32, ry: i32, filled: bool, color: Color, line_width: i32) void {
    if (rx <= 0 or ry <= 0) return;
    const steps = @max(rx, ry) * 8;
    if (steps <= 0) return;

    if (filled) {
        var y = -ry;
        while (y <= ry) : (y += 1) {
            const term = 1.0 - (@as(f64, @floatFromInt(y * y)) / @as(f64, @floatFromInt(ry * ry)));
            if (term < 0.0) continue;
            const xx = @as(i32, @intFromFloat(@floor(@sqrt(term) * @as(f64, @floatFromInt(rx)))));
            drawLine(rec, cx - xx, cy + y, cx + xx, cy + y, color, 1);
        }
        return;
    }

    var prev_x = cx + rx;
    var prev_y = cy;
    var i: i32 = 1;
    while (i <= steps) : (i += 1) {
        const t = (@as(f64, @floatFromInt(i)) * 2.0 * std.math.pi) / @as(f64, @floatFromInt(steps));
        const x = cx + @as(i32, @intFromFloat(@round(@cos(t) * @as(f64, @floatFromInt(rx)))));
        const y = cy + @as(i32, @intFromFloat(@round(@sin(t) * @as(f64, @floatFromInt(ry)))));
        drawLine(rec, prev_x, prev_y, x, y, color, line_width);
        prev_x = x;
        prev_y = y;
    }
}

fn edge(ax: i32, ay: i32, bx: i32, by: i32, px: i32, py: i32) i64 {
    return @as(i64, bx - ax) * @as(i64, py - ay) - @as(i64, by - ay) * @as(i64, px - ax);
}

fn drawTriangle(rec: *ImageRecord, x1: i32, y1: i32, x2: i32, y2: i32, x3: i32, y3: i32, filled: bool, color: Color, line_width: i32) void {
    if (!filled) {
        drawLine(rec, x1, y1, x2, y2, color, line_width);
        drawLine(rec, x2, y2, x3, y3, color, line_width);
        drawLine(rec, x3, y3, x1, y1, color, line_width);
        return;
    }

    const min_x = @min(x1, @min(x2, x3));
    const max_x = @max(x1, @max(x2, x3));
    const min_y = @min(y1, @min(y2, y3));
    const max_y = @max(y1, @max(y2, y3));
    const area = edge(x1, y1, x2, y2, x3, y3);
    if (area == 0) return;

    var py = min_y;
    while (py <= max_y) : (py += 1) {
        var px = min_x;
        while (px <= max_x) : (px += 1) {
            const w0 = edge(x2, y2, x3, y3, px, py);
            const w1 = edge(x3, y3, x1, y1, px, py);
            const w2 = edge(x1, y1, x2, y2, px, py);
            if ((w0 >= 0 and w1 >= 0 and w2 >= 0) or (w0 <= 0 and w1 <= 0 and w2 <= 0)) {
                blendPixel(rec, px, py, color);
            }
        }
    }
}

fn drawPolyline(rec: *ImageRecord, args: []const f64, closed: bool, filled: bool, color: Color, line_width: i32) void {
    if (args.len < 4) return;

    if (filled and closed and args.len >= 6) {
        var min_x = toI32Rounded(args[0]);
        var max_x = min_x;
        var min_y = toI32Rounded(args[1]);
        var max_y = min_y;
        var i: usize = 2;
        while (i + 1 < args.len) : (i += 2) {
            const x = toI32Rounded(args[i]);
            const y = toI32Rounded(args[i + 1]);
            min_x = @min(min_x, x);
            max_x = @max(max_x, x);
            min_y = @min(min_y, y);
            max_y = @max(max_y, y);
        }

        var y = min_y;
        while (y <= max_y) : (y += 1) {
            var nodes: [256]i32 = undefined;
            var node_count: usize = 0;

            var j: usize = args.len - 2;
            i = 0;
            while (i + 1 < args.len) : (i += 2) {
                const xi = toI32Rounded(args[i]);
                const yi = toI32Rounded(args[i + 1]);
                const xj = toI32Rounded(args[j]);
                const yj = toI32Rounded(args[j + 1]);

                if (((yi < y) and (yj >= y)) or ((yj < y) and (yi >= y))) {
                    if (node_count < nodes.len) {
                        nodes[node_count] = xi + @as(i32, @intFromFloat((@as(f64, @floatFromInt(y - yi)) * @as(f64, @floatFromInt(xj - xi))) / @as(f64, @floatFromInt(yj - yi))));
                        node_count += 1;
                    }
                }
                j = i;
            }

            var a: usize = 0;
            while (a < node_count) : (a += 1) {
                var b = a + 1;
                while (b < node_count) : (b += 1) {
                    if (nodes[b] < nodes[a]) {
                        const t = nodes[a];
                        nodes[a] = nodes[b];
                        nodes[b] = t;
                    }
                }
            }

            a = 0;
            while (a + 1 < node_count) : (a += 2) {
                drawLine(rec, nodes[a], y, nodes[a + 1], y, color, 1);
            }
        }
        return;
    }

    var i: usize = 0;
    while (i + 3 < args.len) : (i += 2) {
        drawLine(
            rec,
            toI32Rounded(args[i]),
            toI32Rounded(args[i + 1]),
            toI32Rounded(args[i + 2]),
            toI32Rounded(args[i + 3]),
            color,
            line_width,
        );
    }
    if (closed) {
        drawLine(
            rec,
            toI32Rounded(args[args.len - 2]),
            toI32Rounded(args[args.len - 1]),
            toI32Rounded(args[0]),
            toI32Rounded(args[1]),
            color,
            line_width,
        );
    }
}

fn fillPolygonPoints(rec: *ImageRecord, pts: []const PathPoint, color: Color) void {
    if (pts.len < 3) return;

    var min_x = pts[0].x;
    var max_x = pts[0].x;
    var min_y = pts[0].y;
    var max_y = pts[0].y;
    for (pts) |p| {
        min_x = @min(min_x, p.x);
        max_x = @max(max_x, p.x);
        min_y = @min(min_y, p.y);
        max_y = @max(max_y, p.y);
    }

    var y = min_y;
    while (y <= max_y) : (y += 1) {
        var nodes: [256]i32 = undefined;
        var node_count: usize = 0;

        var j: usize = pts.len - 1;
        var i: usize = 0;
        while (i < pts.len) : (i += 1) {
            const xi = pts[i].x;
            const yi = pts[i].y;
            const xj = pts[j].x;
            const yj = pts[j].y;

            if (((yi < y) and (yj >= y)) or ((yj < y) and (yi >= y))) {
                if (node_count < nodes.len and (yj - yi) != 0) {
                    nodes[node_count] = xi + @as(i32, @intFromFloat((@as(f64, @floatFromInt(y - yi)) * @as(f64, @floatFromInt(xj - xi))) / @as(f64, @floatFromInt(yj - yi))));
                    node_count += 1;
                }
            }
            j = i;
        }

        var a: usize = 0;
        while (a < node_count) : (a += 1) {
            var b = a + 1;
            while (b < node_count) : (b += 1) {
                if (nodes[b] < nodes[a]) {
                    const t = nodes[a];
                    nodes[a] = nodes[b];
                    nodes[b] = t;
                }
            }
        }

        a = 0;
        while (a + 1 < node_count) : (a += 2) {
            drawLine(rec, nodes[a], y, nodes[a + 1], y, color, 1);
        }
    }
}

fn pathReset(path: *PathState) void {
    path.count = 0;
    path.has_current = false;
    path.current_x = 0.0;
    path.current_y = 0.0;
    path.contour_start = 0;
}

fn pathAppend(path: *PathState, x: f64, y: f64, move: bool) bool {
    if (path.count >= PATH_MAX_POINTS) return false;
    path.points[path.count] = .{ .x = toI32Rounded(x), .y = toI32Rounded(y), .move = move };
    if (move) path.contour_start = path.count;
    path.count += 1;
    path.has_current = true;
    path.current_x = x;
    path.current_y = y;
    return true;
}

fn pathMoveTo(path: *PathState, x: f64, y: f64) void {
    _ = pathAppend(path, x, y, true);
}

fn pathLineTo(path: *PathState, x: f64, y: f64) void {
    if (!path.has_current) return;
    _ = pathAppend(path, x, y, false);
}

fn pathQuadTo(path: *PathState, cx: f64, cy: f64, x2: f64, y2: f64) void {
    if (!path.has_current) return;
    const x0 = path.current_x;
    const y0 = path.current_y;
    const steps: i32 = 24;
    var i: i32 = 1;
    while (i <= steps) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
        const inv = 1.0 - t;
        const x = inv * inv * x0 + 2.0 * inv * t * cx + t * t * x2;
        const y = inv * inv * y0 + 2.0 * inv * t * cy + t * t * y2;
        _ = pathAppend(path, x, y, false);
    }
}

fn pathCubicTo(path: *PathState, cx1: f64, cy1: f64, cx2: f64, cy2: f64, x2: f64, y2: f64) void {
    if (!path.has_current) return;
    const x0 = path.current_x;
    const y0 = path.current_y;
    const steps: i32 = 32;
    var i: i32 = 1;
    while (i <= steps) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
        const inv = 1.0 - t;
        const x = inv * inv * inv * x0 +
            3.0 * inv * inv * t * cx1 +
            3.0 * inv * t * t * cx2 +
            t * t * t * x2;
        const y = inv * inv * inv * y0 +
            3.0 * inv * inv * t * cy1 +
            3.0 * inv * t * t * cy2 +
            t * t * t * y2;
        _ = pathAppend(path, x, y, false);
    }
}

fn pathArc(path: *PathState, cx: f64, cy: f64, r: f64, start_deg: f64, end_deg: f64) void {
    if (r <= 0.0) return;
    const start = start_deg * std.math.pi / 180.0;
    var end = end_deg * std.math.pi / 180.0;
    while (end < start) end += 2.0 * std.math.pi;
    const delta = @abs(end - start);
    const steps: i32 = @max(12, @as(i32, @intFromFloat(@ceil(delta * 180.0 / (std.math.pi * 10.0)))));

    var i: i32 = 0;
    while (i <= steps) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
        const a = start + (end - start) * t;
        const x = cx + @cos(a) * r;
        const y = cy + @sin(a) * r;
        if (i == 0) {
            _ = pathAppend(path, x, y, !path.has_current);
        } else {
            _ = pathAppend(path, x, y, false);
        }
    }
}

fn pathClose(path: *PathState) void {
    if (!path.has_current or path.count == 0 or path.contour_start >= path.count) return;
    const start = path.points[path.contour_start];
    const last = path.points[path.count - 1];
    if (last.x == start.x and last.y == start.y) return;
    _ = pathAppend(path, @floatFromInt(start.x), @floatFromInt(start.y), false);
}

fn pathStroke(rec: *ImageRecord, path: *PathState, color: Color, line_width: i32) void {
    if (path.count < 2) {
        pathReset(path);
        return;
    }
    var i: usize = 1;
    while (i < path.count) : (i += 1) {
        if (path.points[i].move) continue;
        drawLine(
            rec,
            path.points[i - 1].x,
            path.points[i - 1].y,
            path.points[i].x,
            path.points[i].y,
            color,
            line_width,
        );
    }
    pathReset(path);
}

fn pathFill(rec: *ImageRecord, path: *PathState, color: Color) void {
    if (path.count < 3) {
        pathReset(path);
        return;
    }

    var start: usize = 0;
    while (start < path.count) {
        while (start < path.count and path.points[start].move == false and start != 0) : (start += 1) {}
        if (start >= path.count) break;

        var end = start + 1;
        while (end < path.count and !path.points[end].move) : (end += 1) {}
        if (end - start >= 3) {
            fillPolygonPoints(rec, path.points[start..end], color);
        }
        start = end;
    }

    pathReset(path);
}

fn blitImageRegion(dst: *ImageRecord, src: *const ImageRecord, dx: i32, dy: i32, dw_in: i32, dh_in: i32, alpha_in: i32, blend_in: i32, sx_in: i32, sy_in: i32, sw_in: i32, sh_in: i32) void {
    if (src.info.width == 0 or src.info.height == 0) return;

    const alpha: u8 = @intCast(clampI32(alpha_in, 0, 255));
    const mode = clampBlendMode(blend_in);

    const sx0 = clampI32(sx_in, 0, @as(i32, @intCast(src.info.width)) - 1);
    const sy0 = clampI32(sy_in, 0, @as(i32, @intCast(src.info.height)) - 1);
    const sw_raw = if (sw_in <= 0) @as(i32, @intCast(src.info.width)) else sw_in;
    const sh_raw = if (sh_in <= 0) @as(i32, @intCast(src.info.height)) else sh_in;
    const sx1 = clampI32(sx0 + sw_raw - 1, sx0, @as(i32, @intCast(src.info.width)) - 1);
    const sy1 = clampI32(sy0 + sh_raw - 1, sy0, @as(i32, @intCast(src.info.height)) - 1);
    const sw = sx1 - sx0 + 1;
    const sh = sy1 - sy0 + 1;
    if (sw <= 0 or sh <= 0) return;

    const dw = if (dw_in <= 0) sw else dw_in;
    const dh = if (dh_in <= 0) sh else dh_in;
    if (dw <= 0 or dh <= 0) return;

    var dy_out: i32 = 0;
    while (dy_out < dh) : (dy_out += 1) {
        const sy_f = (@as(f64, @floatFromInt(dy_out)) * @as(f64, @floatFromInt(sh))) / @as(f64, @floatFromInt(dh));
        const sy = sy0 + clampI32(@intFromFloat(sy_f), 0, sh - 1);
        var dx_out: i32 = 0;
        while (dx_out < dw) : (dx_out += 1) {
            const sx_f = (@as(f64, @floatFromInt(dx_out)) * @as(f64, @floatFromInt(sw))) / @as(f64, @floatFromInt(dw));
            const sx = sx0 + clampI32(@intFromFloat(sx_f), 0, sw - 1);
            const soff = @as(usize, @intCast(sy)) * @as(usize, src.info.stride) + @as(usize, @intCast(sx)) * 4;
            blendPixelMode(dst, dx + dx_out, dy + dy_out, .{
                .r = src.pixels[soff + 0],
                .g = src.pixels[soff + 1],
                .b = src.pixels[soff + 2],
                .a = src.pixels[soff + 3],
            }, alpha, mode);
        }
    }
}

fn blitImage(dst: *ImageRecord, src: *const ImageRecord, x: i32, y: i32, w_in: i32, h_in: i32, alpha_in: i32, blend_in: i32) void {
    blitImageRegion(dst, src, x, y, w_in, h_in, alpha_in, blend_in, 0, 0, 0, 0);
}

fn decodeArgs(data: []const u8, pos: *usize, out: []f64) bool {
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        if (pos.* + 8 > data.len) return false;
        const bits = std.mem.readInt(u64, data[pos.*..][0..8], .little);
        out[i] = @bitCast(bits);
        pos.* += 8;
    }
    return true;
}

pub fn applyBatch(id: u16, data_ptr: ?[*]const u8, data_len: usize) bool {
    const ptr = data_ptr orelse return false;
    if (data_len < 4) return false;

    g_lock.lock();
    defer g_lock.unlock();

    const rec = g_images.getPtr(id) orelse return false;
    if (rec.info.format != .rgba8) return false;

    const data = ptr[0..data_len];
    var state = DrawState{};
    var path = PathState{};
    pathReset(&path);
    var pos: usize = 0;

    while (pos + 4 <= data.len) {
        const op = data[pos + 0];
        const count = data[pos + 1];
        const text_len: usize = @as(u16, data[pos + 2]) | (@as(u16, data[pos + 3]) << 8);
        pos += 4;

        const args_bytes = @as(usize, count) * 8;
        if (pos + args_bytes + text_len > data.len) break;

        var args_buf: [254]f64 = undefined;
        const args = args_buf[0..count];
        if (!decodeArgs(data, &pos, args)) break;

        const text_start = pos;
        pos += text_len;

        switch (op) {
            0 => { // CLEAR
                fillRect(rec, 0, 0, @intCast(rec.info.width), @intCast(rec.info.height), state.paper);
                pathReset(&path);
            },
            1 => { // COLOR
                if (args.len >= 1) {
                    state.stroke = colorFromPacked(args[0]);
                    if (!state.fill_explicit) state.fill = state.stroke;
                }
            },
            2 => { // LINEWIDTH
                if (args.len >= 1) state.line_width = @max(1, toI32Rounded(args[0]));
            },
            3 => { // TEXT (not yet rasterized in software path)
                _ = text_start;
            },
            4 => { // IMAGE id, x, y, w, h [, alpha] [, blend]
                if (args.len >= 5) {
                    const src_id: u16 = @intFromFloat(args[0]);
                    const src = g_images.getPtr(src_id) orelse continue;
                    const alpha_val: i32 = if (args.len >= 6) toI32Rounded(args[5]) else 255;
                    const blend_val: i32 = if (args.len >= 7) toI32Rounded(args[6]) else 0;
                    blitImage(
                        rec,
                        src,
                        toI32Rounded(args[1]),
                        toI32Rounded(args[2]),
                        toI32Rounded(args[3]),
                        toI32Rounded(args[4]),
                        alpha_val,
                        blend_val,
                    );
                }
            },
            5 => { // LINE
                if (args.len >= 4) {
                    drawLine(rec, toI32Rounded(args[0]), toI32Rounded(args[1]), toI32Rounded(args[2]), toI32Rounded(args[3]), state.stroke, state.line_width);
                }
            },
            6 => { // RECT
                if (args.len >= 5) {
                    const x = toI32Rounded(args[0]);
                    const y = toI32Rounded(args[1]);
                    const w = toI32Rounded(args[2]);
                    const h = toI32Rounded(args[3]);
                    const filled = args[4] != 0.0;
                    if (filled) {
                        fillRect(rec, x, y, w, h, state.fill);
                    } else {
                        drawLine(rec, x, y, x + w - 1, y, state.stroke, state.line_width);
                        drawLine(rec, x, y, x, y + h - 1, state.stroke, state.line_width);
                        drawLine(rec, x + w - 1, y, x + w - 1, y + h - 1, state.stroke, state.line_width);
                        drawLine(rec, x, y + h - 1, x + w - 1, y + h - 1, state.stroke, state.line_width);
                    }
                }
            },
            7 => { // CIRCLE
                if (args.len >= 4) {
                    drawCircle(rec, toI32Rounded(args[0]), toI32Rounded(args[1]), toI32Rounded(args[2]), args[3] != 0.0, if (args[3] != 0.0) state.fill else state.stroke, state.line_width);
                }
            },
            8 => { // ELLIPSE
                if (args.len >= 5) {
                    drawEllipse(rec, toI32Rounded(args[0]), toI32Rounded(args[1]), toI32Rounded(args[2]), toI32Rounded(args[3]), args[4] != 0.0, if (args[4] != 0.0) state.fill else state.stroke, state.line_width);
                }
            },
            9 => { // TRIANGLE
                if (args.len >= 7) {
                    drawTriangle(rec, toI32Rounded(args[0]), toI32Rounded(args[1]), toI32Rounded(args[2]), toI32Rounded(args[3]), toI32Rounded(args[4]), toI32Rounded(args[5]), args[6] != 0.0, if (args[6] != 0.0) state.fill else state.stroke, state.line_width);
                }
            },
            10 => { // POLYLINE
                drawPolyline(rec, args, false, false, state.stroke, state.line_width);
            },
            11 => { // POLYGON
                drawPolyline(rec, args, true, true, state.fill, state.line_width);
            },
            12 => { // PAPER
                if (args.len >= 1) state.paper = colorFromPacked(args[0]);
            },
            13 => { // FILL
                if (args.len >= 1) {
                    state.fill = colorFromPacked(args[0]);
                    state.fill_explicit = true;
                }
            },
            14 => { // NOFILL
                state.fill_explicit = false;
                state.fill = state.stroke;
            },
            15 => { // ARC (approximate polyline)
                if (args.len >= 6) {
                    const cx = toI32Rounded(args[0]);
                    const cy = toI32Rounded(args[1]);
                    const r = toI32Rounded(args[2]);
                    const start = args[3] * std.math.pi / 180.0;
                    var end = args[4] * std.math.pi / 180.0;
                    while (end < start) end += 2.0 * std.math.pi;
                    const filled = args[5] != 0.0;
                    const steps: i32 = 72;
                    var prev_x = cx + @as(i32, @intFromFloat(@round(@cos(start) * @as(f64, @floatFromInt(r)))));
                    var prev_y = cy + @as(i32, @intFromFloat(@round(@sin(start) * @as(f64, @floatFromInt(r)))));
                    var i: i32 = 1;
                    while (i <= steps) : (i += 1) {
                        const t = start + (end - start) * (@as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps)));
                        const x = cx + @as(i32, @intFromFloat(@round(@cos(t) * @as(f64, @floatFromInt(r)))));
                        const y = cy + @as(i32, @intFromFloat(@round(@sin(t) * @as(f64, @floatFromInt(r)))));
                        drawLine(rec, prev_x, prev_y, x, y, state.stroke, state.line_width);
                        if (filled) drawLine(rec, cx, cy, x, y, state.fill, 1);
                        prev_x = x;
                        prev_y = y;
                    }
                }
            },
            16 => { // IMAGE SET DEST: x, y, w, h
                if (args.len >= 2) {
                    state.img_dest_x = toI32Rounded(args[0]);
                    state.img_dest_y = toI32Rounded(args[1]);
                }
                if (args.len >= 3) state.img_dest_w = toI32Rounded(args[2]);
                if (args.len >= 4) state.img_dest_h = toI32Rounded(args[3]);
            },
            17 => { // IMAGE SET SRC: sx, sy, sw, sh
                if (args.len >= 2) {
                    state.img_src_x = toI32Rounded(args[0]);
                    state.img_src_y = toI32Rounded(args[1]);
                }
                if (args.len >= 3) state.img_src_w = toI32Rounded(args[2]);
                if (args.len >= 4) state.img_src_h = toI32Rounded(args[3]);
            },
            18 => { // IMAGE SET BLEND: alpha, mode
                if (args.len >= 1) state.img_alpha = toI32Rounded(args[0]);
                if (args.len >= 2) state.img_blend = toI32Rounded(args[1]);
            },
            19 => { // IMAGE PLACE: id (uses current image state)
                if (args.len >= 1) {
                    const src_id: u16 = @intFromFloat(args[0]);
                    const src = g_images.getPtr(src_id) orelse continue;
                    blitImageRegion(
                        rec,
                        src,
                        state.img_dest_x,
                        state.img_dest_y,
                        state.img_dest_w,
                        state.img_dest_h,
                        state.img_alpha,
                        state.img_blend,
                        state.img_src_x,
                        state.img_src_y,
                        state.img_src_w,
                        state.img_src_h,
                    );
                }
            },
            20, 21, 22, 23, 24, 25, 26, 27 => {
                switch (op) {
                    20 => if (args.len >= 2) pathMoveTo(&path, args[0], args[1]), // PATH MOVE
                    21 => if (args.len >= 2) pathLineTo(&path, args[0], args[1]), // PATH LINE
                    22 => if (args.len >= 4) pathQuadTo(&path, args[0], args[1], args[2], args[3]), // PATH CURVE
                    23 => if (args.len >= 6) pathCubicTo(&path, args[0], args[1], args[2], args[3], args[4], args[5]), // PATH BEZIER
                    24 => if (args.len >= 5) pathArc(&path, args[0], args[1], args[2], args[3], args[4]), // PATH ARC
                    25 => pathClose(&path), // PATH CLOSE
                    26 => pathFill(rec, &path, state.fill), // PATH FILL
                    27 => pathStroke(rec, &path, state.stroke, state.line_width), // PATH STROKE
                    else => {},
                }
            },
            else => {},
        }
    }

    return true;
}

pub fn savePng(
    id: u16,
    path_ptr: ?[*]const u8,
    path_len: usize,
    save_bridge: *const fn (path_ptr: ?[*]const u8, path_len: u32, rgba_ptr: ?[*]const u8, width: u32, height: u32, stride: u32) callconv(.c) u8,
) bool {
    const path = path_ptr orelse return false;
    if (path_len == 0 or path_len > std.math.maxInt(u32)) return false;

    g_lock.lock();
    defer g_lock.unlock();

    const rec = g_images.getPtr(id) orelse return false;
    if (rec.info.format != .rgba8 or rec.pixels.len == 0) return false;

    const ok = save_bridge(path, @intCast(path_len), rec.pixels.ptr, rec.info.width, rec.info.height, rec.info.stride);
    return ok != 0;
}
