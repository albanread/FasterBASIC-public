const std = @import("std");

pub const BackendKind = enum {
    fbzig,

    pub fn parse(raw_text: []const u8) ?BackendKind {
        const trimmed = std.mem.trim(u8, raw_text, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(trimmed, "fbzig")) return .fbzig;
        return null;
    }

    pub fn text(self: BackendKind) []const u8 {
        return switch (self) {
            .fbzig => "fbzig",
        };
    }
};

pub const BackendConfig = struct {
    kind: BackendKind,
    compiler_exe: []u8,
    compiler_options: []u8,

    pub fn deinit(self: *BackendConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.compiler_exe);
        allocator.free(self.compiler_options);
    }
};

const ParsedConfig = struct {
    kind: ?BackendKind = null,
    compiler_exe: ?[]u8 = null,
    compiler_options: ?[]u8 = null,

    fn deinit(self: *ParsedConfig, allocator: std.mem.Allocator) void {
        if (self.compiler_exe) |value| allocator.free(value);
        if (self.compiler_options) |value| allocator.free(value);
    }
};

pub fn resolve(allocator: std.mem.Allocator) !BackendConfig {
    var parsed = try readPersistedConfig(allocator);
    defer parsed.deinit(allocator);

    const kind = (try readEnvBackendKind(allocator)) orelse parsed.kind orelse .fbzig;

    const compiler_exe = blk: {
        if (try readEnvText(allocator, &.{ "ED_COMPILER_EXE", "EDGLUE_COMPILER_EXE" })) |value| {
            break :blk value;
        }
        if (parsed.compiler_exe) |value| {
            parsed.compiler_exe = null;
            break :blk value;
        }
        if (try readLegacyConfigText(allocator, legacyCompilerExeConfigName())) |value| {
            break :blk value;
        }

        const preferred = "/Volumes/xc/March2026/fbzig-basic-arm64/bin/zig";
        if (fileExists(preferred)) {
            break :blk try allocator.dupe(u8, preferred);
        }
        break :blk try allocator.dupe(u8, "zig");
    };
    errdefer allocator.free(compiler_exe);

    const compiler_options = blk: {
        if (try readEnvText(allocator, &.{ "ED_COMPILER_OPTIONS", "EDGLUE_COMPILER_OPTIONS" })) |value| {
            break :blk value;
        }
        if (parsed.compiler_options) |value| {
            parsed.compiler_options = null;
            break :blk value;
        }
        if (try readLegacyConfigText(allocator, legacyCompilerOptionsConfigName())) |value| {
            break :blk value;
        }
        break :blk try allocator.dupe(u8, "");
    };

    return .{
        .kind = kind,
        .compiler_exe = compiler_exe,
        .compiler_options = compiler_options,
    };
}

pub fn persistCurrent(allocator: std.mem.Allocator, kind: BackendKind, compiler_exe: []const u8, compiler_options: []const u8) !void {
    const path = try resolveConfigWritePath(allocator, configFileName());
    defer allocator.free(path);

    var contents: std.ArrayListUnmanaged(u8) = .{};
    defer contents.deinit(allocator);

    try contents.appendSlice(allocator, "backend=");
    try contents.appendSlice(allocator, kind.text());
    try contents.append(allocator, '\n');

    try contents.appendSlice(allocator, "compiler=");
    try contents.appendSlice(allocator, std.mem.trim(u8, compiler_exe, " \t\r\n"));
    try contents.append(allocator, '\n');

    const trimmed_options = std.mem.trim(u8, compiler_options, " \t\r\n");
    if (trimmed_options.len != 0) {
        try contents.appendSlice(allocator, "compiler_options=");
        try contents.appendSlice(allocator, trimmed_options);
        try contents.append(allocator, '\n');
    }

    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = contents.items });

    try deleteConfigFile(legacyCompilerExeConfigName());
    try deleteConfigFile(legacyCompilerOptionsConfigName());
    try deleteLegacyWritePath(allocator, legacyCompilerExeConfigName());
    try deleteLegacyWritePath(allocator, legacyCompilerOptionsConfigName());
}

pub fn clearPersistedConfig(allocator: std.mem.Allocator) !void {
    try deleteConfigFile(configFileName());
    try deleteLegacyWritePath(allocator, configFileName());
    try deleteConfigFile(legacyCompilerExeConfigName());
    try deleteConfigFile(legacyCompilerOptionsConfigName());
    try deleteLegacyWritePath(allocator, legacyCompilerExeConfigName());
    try deleteLegacyWritePath(allocator, legacyCompilerOptionsConfigName());
}

pub fn configFileName() []const u8 {
    return "edglue-backend.cfg";
}

fn readPersistedConfig(allocator: std.mem.Allocator) !ParsedConfig {
    const exe_path = std.fs.selfExePathAlloc(allocator) catch return .{};
    defer allocator.free(exe_path);

    const exe_dir = std.fs.path.dirname(exe_path) orelse return .{};
    const exe_config = try std.fs.path.join(allocator, &.{ exe_dir, configFileName() });
    defer allocator.free(exe_config);

    if (try readConfigFile(allocator, exe_config)) |parsed| return parsed;
    if (try readConfigFile(allocator, configFileName())) |parsed| return parsed;
    return .{};
}

fn readConfigFile(allocator: std.mem.Allocator, path: []const u8) !?ParsedConfig {
    if (!fileExists(path)) return null;

    const raw = try std.fs.cwd().readFileAlloc(allocator, path, 8192);
    defer allocator.free(raw);

    return try parseConfigText(allocator, raw);
}

fn parseConfigText(allocator: std.mem.Allocator, text: []const u8) !ParsedConfig {
    var parsed = ParsedConfig{};
    errdefer parsed.deinit(allocator);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const eq_index = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidBackendConfig;
        const key = std.mem.trim(u8, line[0..eq_index], " \t\r");
        const value = std.mem.trim(u8, line[eq_index + 1 ..], " \t\r");

        if (std.ascii.eqlIgnoreCase(key, "backend")) {
            parsed.kind = BackendKind.parse(value) orelse return error.InvalidBackendKind;
        } else if (std.ascii.eqlIgnoreCase(key, "compiler")) {
            if (parsed.compiler_exe) |existing| allocator.free(existing);
            parsed.compiler_exe = try allocator.dupe(u8, value);
        } else if (std.ascii.eqlIgnoreCase(key, "compiler_options")) {
            if (parsed.compiler_options) |existing| allocator.free(existing);
            parsed.compiler_options = try allocator.dupe(u8, value);
        }
    }

    return parsed;
}

fn readLegacyConfigText(allocator: std.mem.Allocator, file_name: []const u8) !?[]u8 {
    const exe_path = std.fs.selfExePathAlloc(allocator) catch return null;
    defer allocator.free(exe_path);

    const exe_dir = std.fs.path.dirname(exe_path) orelse return null;
    const exe_config = try std.fs.path.join(allocator, &.{ exe_dir, file_name });
    defer allocator.free(exe_config);

    if (try readPlainConfigFile(allocator, exe_config)) |value| return value;
    return readPlainConfigFile(allocator, file_name);
}

fn readPlainConfigFile(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    if (!fileExists(path)) return null;

    const raw = try std.fs.cwd().readFileAlloc(allocator, path, 4096);
    defer allocator.free(raw);

    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    return @as(?[]u8, try allocator.dupe(u8, trimmed));
}

fn readEnvBackendKind(allocator: std.mem.Allocator) !?BackendKind {
    if (try readEnvText(allocator, &.{ "ED_COMPILER_BACKEND", "EDGLUE_BACKEND" })) |value| {
        defer allocator.free(value);
        return BackendKind.parse(value) orelse error.InvalidBackendKind;
    }
    return null;
}

fn readEnvText(allocator: std.mem.Allocator, names: []const []const u8) !?[]u8 {
    for (names) |env_name| {
        const env_value = std.process.getEnvVarOwned(allocator, env_name) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };
        if (env_value) |raw| {
            defer allocator.free(raw);
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (trimmed.len == 0) continue;
            return @as(?[]u8, try allocator.dupe(u8, trimmed));
        }
    }
    return null;
}

fn resolveConfigWritePath(allocator: std.mem.Allocator, file_name: []const u8) ![]u8 {
    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);

    const exe_dir = std.fs.path.dirname(exe_path) orelse return error.NoExeDir;
    return std.fs.path.join(allocator, &.{ exe_dir, file_name });
}

fn deleteLegacyWritePath(allocator: std.mem.Allocator, file_name: []const u8) !void {
    const write_path = try resolveConfigWritePath(allocator, file_name);
    defer allocator.free(write_path);
    try deleteConfigFile(write_path);
}

fn deleteConfigFile(path: []const u8) !void {
    std.fs.cwd().deleteFile(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn fileExists(path: []const u8) bool {
    _ = std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn legacyCompilerExeConfigName() []const u8 {
    return "edglue-compiler.txt";
}

fn legacyCompilerOptionsConfigName() []const u8 {
    return "edglue-compiler-options.txt";
}

test "parse backend config file" {
    const text =
        \\backend=fbzig
        \\compiler=/tmp/fbzig
        \\compiler_options=-O ReleaseFast --target x86_64-macos
    ;

    var parsed = try parseConfigText(std.testing.allocator, text);
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(BackendKind.fbzig, parsed.kind.?);
    try std.testing.expectEqualStrings("/tmp/fbzig", parsed.compiler_exe.?);
    try std.testing.expectEqualStrings("-O ReleaseFast --target x86_64-macos", parsed.compiler_options.?);
}
