const std = @import("std");
const backend_config = @import("backend_config.zig");
const jit_shared = @import("jit_shared.zig");

const c = @cImport({
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("poll.h");
    @cInclude("sys/wait.h");
    @cInclude("unistd.h");
});

const EXIT_PENDING: i32 = -2147483647;
const EXIT_STOPPED: i32 = 130;

extern fn edglue_request_mac_quit(pid: c_int) bool;
extern fn edglue_force_mac_quit(pid: c_int) bool;
extern fn edglue_request_mac_front(pid: c_int) bool;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = std.process.args();
    _ = args.next();
    const shm_name = args.next() orelse {
        std.log.err("usage: edglue <shared_region_name> [--backend <kind>] [--compiler <path>] [--compiler-options <args>] [--build <output>] [--bundle-app]", .{});
        return error.InvalidArgs;
    };
    var backend_kind_override: ?backend_config.BackendKind = null;
    var compiler_exe_override: ?[]const u8 = null;
    var compiler_options_override: ?[]const u8 = null;

    var build_output: ?[]const u8 = null;
    var bundle_app = false;
    var show_asm = false;
    var show_ir = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--backend")) {
            const backend_text = args.next() orelse return error.InvalidArgs;
            backend_kind_override = backend_config.BackendKind.parse(backend_text) orelse return error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--compiler")) {
            compiler_exe_override = args.next() orelse return error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--compiler-options")) {
            compiler_options_override = args.next() orelse return error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--build")) {
            build_output = args.next() orelse return error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--bundle-app")) {
            bundle_app = true;
        } else if (std.mem.eql(u8, arg, "--show-asm")) {
            show_asm = true;
        } else if (std.mem.eql(u8, arg, "--show-ir")) {
            show_ir = true;
        } else if (!std.mem.startsWith(u8, arg, "--")) {
            compiler_exe_override = arg;
        } else {
            return error.InvalidArgs;
        }
    }

    if (show_asm and show_ir) return error.InvalidArgs;

    var resolved_backend = try backend_config.resolve(allocator);
    defer resolved_backend.deinit(allocator);

    const backend_kind = backend_kind_override orelse resolved_backend.kind;
    const compiler_exe = compiler_exe_override orelse resolved_backend.compiler_exe;
    const compiler_options_raw = blk: {
        if (compiler_options_override) |value| break :blk value;
        const trimmed = std.mem.trim(u8, resolved_backend.compiler_options, " \t\r\n");
        if (trimmed.len == 0) break :blk null;
        break :blk resolved_backend.compiler_options;
    };

    var name_buf: [256]u8 = undefined;
    if (shm_name.len + 1 > name_buf.len) return error.NameTooLong;
    @memcpy(name_buf[0..shm_name.len], shm_name);
    name_buf[shm_name.len] = 0;
    const name_z: [:0]const u8 = name_buf[0..shm_name.len :0];

    var region = try jit_shared.open(name_z);
    defer jit_shared.close(&region);

    @atomicStore(i32, &region.header.exit_code, EXIT_PENDING, .release);
    @atomicStore(u64, &region.header.compile_ns, 0, .release);
    @atomicStore(u64, &region.header.exec_ns, 0, .release);
    writeErr(&region, "[edglue] started\n");

    const source_len = @as(usize, @intCast(region.header.source_len));
    if (source_len == 0 or source_len > region.source.len) {
        writeErr(&region, "[edglue] invalid source_len\n");
        @atomicStore(i32, &region.header.exit_code, 2, .release);
        return;
    }

    try std.fs.cwd().makePath("tmp");
    const src_path = try tempPath(allocator, "edglue-input", ".bas");
    defer allocator.free(src_path);
    defer std.fs.cwd().deleteFile(src_path) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = src_path, .data = region.source[0..source_len] });

    const src_stem = std.fs.path.stem(std.fs.path.basename(src_path));
    const exe_path = if (builtinIsWindows())
        try std.fmt.allocPrint(allocator, "{s}.exe", .{src_stem})
    else
        try allocator.dupe(u8, src_stem);
    defer allocator.free(exe_path);

    var build_destination: ?BuildDestination = null;
    defer if (build_destination) |*dest| dest.deinit(allocator);
    if (build_output) |out_path| {
        build_destination = if (bundle_app and builtinIsMacOS())
            try BuildDestination.initMacApp(allocator, out_path)
        else
            try BuildDestination.initDirect(allocator, out_path);
    }

    var compile_argv: std.ArrayListUnmanaged([]const u8) = .{};
    defer compile_argv.deinit(allocator);
    var owned_option_tokens: std.ArrayListUnmanaged([]u8) = .{};
    defer {
        for (owned_option_tokens.items) |token| allocator.free(token);
        owned_option_tokens.deinit(allocator);
    }

    try compile_argv.append(allocator, compiler_exe);
    if (compiler_options_raw) |raw| {
        try appendCompilerOptions(allocator, &compile_argv, &owned_option_tokens, raw);
    }
    try appendBackendCompileArgs(allocator, &compile_argv, backend_kind, src_path, if (build_destination) |dest| dest.compiler_output_path else null);

    var emitted_view_path: ?[]const u8 = null;
    defer if (emitted_view_path) |path| {
        std.fs.cwd().deleteFile(path) catch {};
        allocator.free(path);
    };

    if (show_asm) {
        const asm_path = try tempPath(allocator, "edglue-view", ".s");
        emitted_view_path = asm_path;
        const emit_flag = try std.fmt.allocPrint(allocator, "-femit-asm={s}", .{asm_path});
        try owned_option_tokens.append(allocator, emit_flag);
        try compile_argv.append(allocator, emit_flag);
        try compile_argv.append(allocator, "-fno-emit-bin");
    } else if (show_ir) {
        const ir_path = try tempPath(allocator, "edglue-view", ".ll");
        emitted_view_path = ir_path;
        const emit_flag = try std.fmt.allocPrint(allocator, "-femit-llvm-ir={s}", .{ir_path});
        try owned_option_tokens.append(allocator, emit_flag);
        try compile_argv.append(allocator, emit_flag);
        try compile_argv.append(allocator, "-fno-emit-bin");
    }

    var compile_msg_buf: [512]u8 = undefined;
    const action_label = if (show_asm)
        "generating assembly"
    else if (show_ir)
        "generating LLVM IR"
    else
        "compiling";
    const compile_msg = if (compiler_options_raw) |raw|
        std.fmt.bufPrint(&compile_msg_buf, "[edglue] {s} via {s} with {s} {s}\n", .{ action_label, backend_kind.text(), compiler_exe, raw }) catch "[edglue] compiling\n"
    else
        std.fmt.bufPrint(&compile_msg_buf, "[edglue] {s} via {s} with {s}\n", .{ action_label, backend_kind.text(), compiler_exe }) catch "[edglue] compiling\n";
    writeOut(&region, compile_msg);
    const compile_started_ns = std.time.nanoTimestamp();
    const compile_code = try runChildAndPipe(allocator, &region, compile_argv.items, false);
    const compile_elapsed_ns = std.time.nanoTimestamp() - compile_started_ns;
    @atomicStore(u64, &region.header.compile_ns, @as(u64, @intCast(@max(compile_elapsed_ns, 0))), .release);
    if (compile_code != 0) {
        @atomicStore(i32, &region.header.exit_code, compile_code, .release);
        return;
    }

    if (emitted_view_path) |view_path| {
        const label = if (show_asm) "Assembly" else "LLVM IR";
        writeOut(&region, "\n");
        var heading_buf: [256]u8 = undefined;
        const heading = std.fmt.bufPrint(&heading_buf, "=== {s}: {s} ===\n", .{ label, std.fs.path.basename(view_path) }) catch "=== Output ===\n";
        writeOut(&region, heading);

        const emitted_bytes = std.fs.cwd().readFileAlloc(allocator, view_path, 16 * 1024 * 1024) catch |err| {
            var buf: [160]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "[edglue] failed to read emitted file: {s}\n", .{@errorName(err)}) catch "[edglue] failed to read emitted file\n";
            writeErr(&region, msg);
            @atomicStore(i32, &region.header.exit_code, 1, .release);
            return;
        };
        defer allocator.free(emitted_bytes);

        if (emitted_bytes.len != 0) {
            writeOut(&region, emitted_bytes);
            if (emitted_bytes[emitted_bytes.len - 1] != '\n') writeOut(&region, "\n");
        }
        const footer = std.fmt.bufPrint(&heading_buf, "=== End {s} ===\n", .{label}) catch "=== End Output ===\n";
        writeOut(&region, footer);
        @atomicStore(u64, &region.header.exec_ns, 0, .release);
        @atomicStore(i32, &region.header.exit_code, 0, .release);
        return;
    }

    if (build_output != null) {
        @atomicStore(i32, &region.header.exit_code, 0, .release);
        return;
    }

    const produced_path = try resolveRunPath(allocator, exe_path);
    defer allocator.free(produced_path);

    writeOut(&region, "[edglue] running\n");
    const run_argv = [_][]const u8{produced_path};
    const run_started_ns = std.time.nanoTimestamp();
    const run_code = try runChildAndPipe(allocator, &region, &run_argv, true);
    const run_elapsed_ns = std.time.nanoTimestamp() - run_started_ns;
    @atomicStore(u64, &region.header.exec_ns, @as(u64, @intCast(@max(run_elapsed_ns, 0))), .release);
    @atomicStore(i32, &region.header.exit_code, run_code, .release);
}

fn resolveRunPath(allocator: std.mem.Allocator, exe_name: []const u8) ![]const u8 {
    if (fileExists(exe_name)) {
        return normalizeExecPath(allocator, exe_name);
    }

    const binbas_path = try std.fmt.allocPrint(allocator, "binbas/{s}", .{exe_name});
    errdefer allocator.free(binbas_path);
    if (fileExists(binbas_path)) {
        defer allocator.free(binbas_path);
        return normalizeExecPath(allocator, binbas_path);
    }

    return error.FileNotFound;
}

fn normalizeExecPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        return allocator.dupe(u8, path);
    }
    if (std.mem.indexOfScalar(u8, path, std.fs.path.sep) != null) {
        if (std.mem.startsWith(u8, path, "./")) return allocator.dupe(u8, path);
        return std.fmt.allocPrint(allocator, "./{s}", .{path});
    }
    return std.fmt.allocPrint(allocator, "./{s}", .{path});
}

fn fileExists(path: []const u8) bool {
    _ = std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn appendBackendCompileArgs(
    allocator: std.mem.Allocator,
    argv: *std.ArrayListUnmanaged([]const u8),
    kind: backend_config.BackendKind,
    src_path: []const u8,
    output_path: ?[]const u8,
) !void {
    switch (kind) {
        .fbzig => {
            try argv.append(allocator, "basic");
            if (output_path) |path| {
                const emit_flag = try std.fmt.allocPrint(allocator, "-femit-bin={s}", .{path});
                try argv.append(allocator, emit_flag);
            }
            try argv.append(allocator, src_path);
        },
    }
}

const BuildDestination = struct {
    final_output_path: []u8,
    compiler_output_path: []u8,

    fn initDirect(allocator: std.mem.Allocator, out_path: []const u8) !BuildDestination {
        const owned_final = try allocator.dupe(u8, out_path);
        errdefer allocator.free(owned_final);
        try ensureParentDir(owned_final);
        return .{
            .final_output_path = owned_final,
            .compiler_output_path = try allocator.dupe(u8, owned_final),
        };
    }

    fn initMacApp(allocator: std.mem.Allocator, requested_path: []const u8) !BuildDestination {
        const bundle_path = if (std.mem.endsWith(u8, requested_path, ".app"))
            try allocator.dupe(u8, requested_path)
        else
            try std.fmt.allocPrint(allocator, "{s}.app", .{requested_path});
        errdefer allocator.free(bundle_path);

        const app_name_with_ext = std.fs.path.basename(bundle_path);
        const app_name = app_name_with_ext[0 .. app_name_with_ext.len - ".app".len];
        const executable_name = if (app_name.len == 0) "program" else app_name;

        const macos_dir = try std.fs.path.join(allocator, &.{ bundle_path, "Contents", "MacOS" });
        defer allocator.free(macos_dir);
        const resources_dir = try std.fs.path.join(allocator, &.{ bundle_path, "Contents", "Resources" });
        defer allocator.free(resources_dir);
        try std.fs.cwd().makePath(macos_dir);
        try std.fs.cwd().makePath(resources_dir);

        const copied_default_icon = copyDefaultAppIcon(allocator, resources_dir) catch false;

        const plist_path = try std.fs.path.join(allocator, &.{ bundle_path, "Contents", "Info.plist" });
        defer allocator.free(plist_path);
        const plist_data = try makeMacAppInfoPlist(allocator, executable_name, copied_default_icon);
        defer allocator.free(plist_data);
        try std.fs.cwd().writeFile(.{ .sub_path = plist_path, .data = plist_data });

        const compiler_output_path = try std.fs.path.join(allocator, &.{ bundle_path, "Contents", "MacOS", executable_name });
        return .{
            .final_output_path = bundle_path,
            .compiler_output_path = compiler_output_path,
        };
    }

    fn deinit(self: *BuildDestination, allocator: std.mem.Allocator) void {
        allocator.free(self.final_output_path);
        allocator.free(self.compiler_output_path);
    }
};

fn ensureParentDir(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0 or std.mem.eql(u8, parent, ".")) return;
    try std.fs.cwd().makePath(parent);
}

fn makeMacAppInfoPlist(allocator: std.mem.Allocator, executable_name: []const u8, include_default_icon: bool) ![]u8 {
    const bundle_id_suffix = try sanitizeBundleIdentifierComponent(allocator, executable_name);
    defer allocator.free(bundle_id_suffix);

    const icon_block = if (include_default_icon)
        "  <key>CFBundleIconFile</key>\n  <string>FasterBASIC.icns</string>\n"
    else
        "";

    return std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>CFBundleName</key>
        \\  <string>{s}</string>
        \\  <key>CFBundleDisplayName</key>
        \\  <string>{s}</string>
        \\  <key>CFBundleExecutable</key>
        \\  <string>{s}</string>
        \\  <key>CFBundleIdentifier</key>
        \\  <string>com.fasterbasic.{s}</string>
        \\  <key>CFBundlePackageType</key>
        \\  <string>APPL</string>
        \\{s}
        \\  <key>CFBundleVersion</key>
        \\  <string>1</string>
        \\  <key>CFBundleShortVersionString</key>
        \\  <string>1.0</string>
        \\  <key>NSHighResolutionCapable</key>
        \\  <true/>
        \\</dict>
        \\</plist>
    , .{ executable_name, executable_name, executable_name, bundle_id_suffix, icon_block });
}

fn copyDefaultAppIcon(allocator: std.mem.Allocator, resources_dir: []const u8) !bool {
    const icon_source = resolveDefaultAppIconPath(allocator) orelse return false;
    defer allocator.free(icon_source);

    const icon_bytes = std.fs.cwd().readFileAlloc(allocator, icon_source, 2 * 1024 * 1024) catch return false;
    defer allocator.free(icon_bytes);

    const icon_dest = try std.fs.path.join(allocator, &.{ resources_dir, "FasterBASIC.icns" });
    defer allocator.free(icon_dest);
    try std.fs.cwd().writeFile(.{ .sub_path = icon_dest, .data = icon_bytes });
    return true;
}

fn resolveDefaultAppIconPath(allocator: std.mem.Allocator) ?[]u8 {
    const exe_path = std.fs.selfExePathAlloc(allocator) catch return null;
    defer allocator.free(exe_path);
    const exe_dir = std.fs.path.dirname(exe_path) orelse return null;

    const sibling_icon = std.fs.path.join(allocator, &.{ exe_dir, "FasterBASIC.icns" }) catch return null;
    if (fileExists(sibling_icon)) return sibling_icon;
    allocator.free(sibling_icon);

    return null;
}

fn sanitizeBundleIdentifierComponent(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);

    for (raw) |byte| {
        if (std.ascii.isAlphanumeric(byte)) {
            try buf.append(allocator, std.ascii.toLower(byte));
        } else if (byte == '-' or byte == '.') {
            try buf.append(allocator, byte);
        } else {
            try buf.append(allocator, '-');
        }
    }

    if (buf.items.len == 0) {
        try buf.appendSlice(allocator, "app");
    }

    return buf.toOwnedSlice(allocator);
}

fn runChildAndPipe(allocator: std.mem.Allocator, region: *jit_shared.SharedRegion, argv: []const []const u8, activate_on_macos: bool) !i32 {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "[edglue] spawn failed: {s}\n", .{@errorName(err)}) catch "[edglue] spawn failed\n";
        writeErr(region, msg);
        return 127;
    };

    var stdout_open = true;
    var stderr_open = true;
    var stop_sent = false;
    var stdout_normalizer = NewlineNormalizer{};
    var stderr_normalizer = NewlineNormalizer{};
    var wait_status: c_int = 0;
    var exit_code: ?i32 = null;
    var stop_requested_at_ns: ?i128 = null;
    var activate_deadline_ns: ?i128 = if (activate_on_macos) std.time.nanoTimestamp() + 2_000 * std.time.ns_per_ms else null;
    var next_activate_attempt_ns: ?i128 = if (activate_on_macos) std.time.nanoTimestamp() else null;

    try setNonBlocking(child.stdout.?.handle);
    try setNonBlocking(child.stderr.?.handle);

    while (exit_code == null or stdout_open or stderr_open) {
        if (next_activate_attempt_ns) |attempt_ns| {
            const now = std.time.nanoTimestamp();
            if (now >= attempt_ns) {
                _ = requestMacFront(&child);
                if (activate_deadline_ns) |deadline_ns| {
                    if (now + 250 * std.time.ns_per_ms <= deadline_ns) {
                        next_activate_attempt_ns = now + 250 * std.time.ns_per_ms;
                    } else {
                        next_activate_attempt_ns = null;
                        activate_deadline_ns = null;
                    }
                } else {
                    next_activate_attempt_ns = null;
                }
            }
        }

        if (!stop_sent and @atomicLoad(u32, &region.header.stop_requested, .acquire) != 0) {
            stop_sent = true;
            stop_requested_at_ns = std.time.nanoTimestamp();
            writeErr(region, "[edglue] stop requested\n");
            if (!requestMacQuit(&child)) {
                _ = child.kill() catch {};
            }
        } else if (stop_sent and exit_code == null) {
            if (stop_requested_at_ns) |started_ns| {
                const elapsed_ns = std.time.nanoTimestamp() - started_ns;
                if (elapsed_ns >= 1_500 * std.time.ns_per_ms) {
                    _ = forceMacQuit(&child);
                    _ = child.kill() catch {};
                    stop_requested_at_ns = null;
                }
            }
        }

        if (stdout_open or stderr_open) {
            var pollfds: [2]c.struct_pollfd = undefined;
            var poll_count: c.nfds_t = 0;

            if (stdout_open) {
                pollfds[poll_count] = .{
                    .fd = child.stdout.?.handle,
                    .events = c.POLLIN | c.POLLHUP | c.POLLERR,
                    .revents = 0,
                };
                poll_count += 1;
            }
            if (stderr_open) {
                pollfds[poll_count] = .{
                    .fd = child.stderr.?.handle,
                    .events = c.POLLIN | c.POLLHUP | c.POLLERR,
                    .revents = 0,
                };
                poll_count += 1;
            }

            const poll_result = c.poll(&pollfds[0], poll_count, 50);
            if (poll_result < 0) {
                return error.PollFailed;
            }

            if (stdout_open) stdout_open = try pumpPipe(child.stdout.?, region, &stdout_normalizer, false);
            if (stderr_open) stderr_open = try pumpPipe(child.stderr.?, region, &stderr_normalizer, true);
        } else {
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }

        if (exit_code == null) {
            const wait_result = c.waitpid(@as(c_int, @intCast(child.id)), &wait_status, c.WNOHANG);
            if (wait_result < 0) {
                writeErr(region, "[edglue] wait failed\n");
                return 127;
            }
            if (wait_result == @as(c_int, @intCast(child.id))) {
                exit_code = waitStatusToExitCode(wait_status);
            }
        }
    }

    if (stop_sent) return EXIT_STOPPED;
    return exit_code orelse 1;
}

fn writeOut(region: *jit_shared.SharedRegion, bytes: []const u8) void {
    var normalizer = NewlineNormalizer{};
    normalizer.write(region.output, &region.header.output_write, bytes);
}

fn writeErr(region: *jit_shared.SharedRegion, bytes: []const u8) void {
    var normalizer = NewlineNormalizer{};
    normalizer.write(region.err, &region.header.error_write, bytes);
}

const NewlineNormalizer = struct {
    last_was_cr: bool = false,

    fn write(self: *NewlineNormalizer, buffer: []u8, write_ptr: *u32, bytes: []const u8) void {
        for (bytes) |byte| {
            if (byte == '\n' and !self.last_was_cr) {
                jit_shared.ringWrite(buffer, write_ptr, "\r\n");
            } else {
                var one = [1]u8{byte};
                jit_shared.ringWrite(buffer, write_ptr, &one);
            }
            self.last_was_cr = (byte == '\r');
        }
    }
};

fn setNonBlocking(fd: c_int) !void {
    const flags = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    if (flags < 0) return error.FcntlGetFailed;
    if (c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) < 0) return error.FcntlSetFailed;
}

fn pumpPipe(file: std.fs.File, region: *jit_shared.SharedRegion, normalizer: *NewlineNormalizer, is_err: bool) !bool {
    var buf: [4096]u8 = undefined;

    while (true) {
        const amt = file.read(&buf) catch |err| switch (err) {
            error.WouldBlock => return true,
            else => return err,
        };
        if (amt == 0) return false;

        if (is_err) {
            normalizer.write(region.err, &region.header.error_write, buf[0..amt]);
        } else {
            normalizer.write(region.output, &region.header.output_write, buf[0..amt]);
        }
    }
}

fn waitStatusToExitCode(status: c_int) i32 {
    if (c.WIFEXITED(status)) {
        return @as(i32, c.WEXITSTATUS(status));
    }
    if (c.WIFSIGNALED(status)) {
        return -@as(i32, c.WTERMSIG(status));
    }
    return 1;
}

fn requestMacQuit(child: *std.process.Child) bool {
    if (@import("builtin").os.tag != .macos) return false;
    return edglue_request_mac_quit(@as(c_int, @intCast(child.id)));
}

fn forceMacQuit(child: *std.process.Child) bool {
    if (@import("builtin").os.tag != .macos) return false;
    return edglue_force_mac_quit(@as(c_int, @intCast(child.id)));
}

fn requestMacFront(child: *std.process.Child) bool {
    if (@import("builtin").os.tag != .macos) return false;
    return edglue_request_mac_front(@as(c_int, @intCast(child.id)));
}

test "newline normalizer expands bare lf" {
    var buffer: [32]u8 = [_]u8{0} ** 32;
    var write_pos: u32 = 0;
    var normalizer = NewlineNormalizer{};

    normalizer.write(buffer[0..], &write_pos, "a\nb\r\nc");

    try std.testing.expectEqual(@as(u32, 7), write_pos);
    try std.testing.expectEqualStrings("a\r\nb\r\nc", buffer[0..7]);
}

test "newline normalizer preserves split crlf" {
    var buffer: [32]u8 = [_]u8{0} ** 32;
    var write_pos: u32 = 0;
    var normalizer = NewlineNormalizer{};

    normalizer.write(buffer[0..], &write_pos, "a\r");
    normalizer.write(buffer[0..], &write_pos, "\nb\n");

    try std.testing.expectEqual(@as(u32, 6), write_pos);
    try std.testing.expectEqualStrings("a\r\nb\r\n", buffer[0..6]);
}

fn appendCompilerOptions(
    allocator: std.mem.Allocator,
    argv: *std.ArrayListUnmanaged([]const u8),
    owned_tokens: *std.ArrayListUnmanaged([]u8),
    raw: []const u8,
) !void {
    var cursor: usize = 0;
    while (cursor < raw.len) {
        while (cursor < raw.len and std.ascii.isWhitespace(raw[cursor])) : (cursor += 1) {}
        if (cursor >= raw.len) break;

        var token_buf: std.ArrayListUnmanaged(u8) = .{};
        defer token_buf.deinit(allocator);

        while (cursor < raw.len and !std.ascii.isWhitespace(raw[cursor])) {
            const ch = raw[cursor];
            if (ch == '"' or ch == '\'') {
                const quote = ch;
                cursor += 1;
                while (cursor < raw.len) {
                    const qch = raw[cursor];
                    if (qch == '\\' and cursor + 1 < raw.len) {
                        try token_buf.append(allocator, raw[cursor + 1]);
                        cursor += 2;
                        continue;
                    }
                    if (qch == quote) {
                        cursor += 1;
                        break;
                    }
                    try token_buf.append(allocator, qch);
                    cursor += 1;
                }
                continue;
            }
            if (ch == '\\' and cursor + 1 < raw.len) {
                try token_buf.append(allocator, raw[cursor + 1]);
                cursor += 2;
                continue;
            }
            try token_buf.append(allocator, ch);
            cursor += 1;
        }

        if (token_buf.items.len == 0) continue;

        const owned = try allocator.dupe(u8, token_buf.items);
        try owned_tokens.append(allocator, owned);
        try argv.append(allocator, owned);
    }
}

fn tempPath(allocator: std.mem.Allocator, prefix: []const u8, suffix: []const u8) ![]const u8 {
    const nonce = std.crypto.random.int(u64);
    return std.fmt.allocPrint(allocator, "tmp/{s}-{x}{s}", .{ prefix, nonce, suffix });
}

fn builtinIsWindows() bool {
    return @import("builtin").os.tag == .windows;
}

fn builtinIsMacOS() bool {
    return @import("builtin").os.tag == .macos;
}
