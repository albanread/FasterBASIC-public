const std = @import("std");
const trace = @import("../tracy.zig").trace;
const Compilation = @import("../Compilation.zig");
const Module = @import("../Package/Module.zig");
const target_util = @import("../target.zig");

pub const BuildError = error{
    OutOfMemory,
    AlreadyReported,
};

fn firstExistingPath(candidates: []const []const u8) ?[]const u8 {
    for (candidates) |candidate| {
        std.fs.cwd().access(candidate, .{}) catch continue;
        return candidate;
    }
    return null;
}

fn prebuiltRuntimeRelativePath(arena: std.mem.Allocator, target: *const std.Target) !?[]const u8 {
    if (target.os.tag != .macos) return null;

    const filename = try std.fmt.allocPrint(arena, "libmacguiruntime-{s}-{s}.a", .{
        @tagName(target.os.tag),
        @tagName(target.cpu.arch),
    });
    return try std.fs.path.join(arena, &.{ "macgui", "prebuilt", filename });
}

pub fn buildStaticLib(comp: *Compilation, prog_node: std.Progress.Node) BuildError!void {
    const tracy = trace(@src());
    defer tracy.end();

    const target = &comp.root_mod.resolved_target.result;
    const optimize_mode = comp.compilerRtOptMode();
    const strip = comp.compilerRtStrip();

    var arena_allocator = std.heap.ArenaAllocator.init(comp.gpa);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    if (try prebuiltRuntimeRelativePath(arena, target)) |rel_path| {
        if (comp.dirs.zig_lib.handle.access(rel_path, .{})) |_| {
            const full_path = try comp.dirs.zig_lib.join(comp.gpa, &.{rel_path});
            comp.basic_runtime_prebuilt_path = std.Build.Cache.Path.initCwd(full_path);
            return;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => {
                comp.lockAndSetMiscFailure(.basic_runtime, "unable to use prebuilt BASIC runtime '{s}': {s}", .{ rel_path, @errorName(err) });
                return error.AlreadyReported;
            },
        }
    }

    const config = Compilation.Config.resolve(.{
        .output_mode = .Lib,
        .link_mode = .static,
        .resolved_target = comp.root_mod.resolved_target,
        .is_test = false,
        .have_zcu = true,
        .emit_bin = true,
        .root_optimize_mode = optimize_mode,
        .root_strip = strip,
        .link_libc = true,
        .link_libcpp = if (target.os.tag == .macos) true else null,
        .any_unwind_tables = comp.root_mod.unwind_tables != .none,
        .any_error_tracing = false,
        .root_error_tracing = false,
        .lto = .none,
    }) catch |err| {
        comp.lockAndSetMiscFailure(.basic_runtime, "unable to build BASIC runtime: resolving configuration failed: {s}", .{@errorName(err)});
        return error.AlreadyReported;
    };

    const is_macos = target.os.tag == .macos;

    const root_mod = Module.create(arena, .{
        .paths = .{
            .root = .zig_lib_root,
            .root_src_path = if (is_macos)
                "compiler/basic/runtime/macguiruntime_entry.zig"
            else
                "compiler/basic/runtime/runtime_entry.zig",
        },
        .fully_qualified_name = "root",
        .inherited = .{
            .resolved_target = comp.root_mod.resolved_target,
            .strip = strip,
            .stack_check = false,
            .stack_protector = 0,
            .red_zone = comp.root_mod.red_zone,
            .omit_frame_pointer = comp.root_mod.omit_frame_pointer,
            .unwind_tables = comp.root_mod.unwind_tables,
            .pic = if (target_util.supports_fpic(target)) true else null,
            .optimize_mode = optimize_mode,
            .structured_cfg = comp.root_mod.structured_cfg,
            .no_builtin = true,
            .code_model = comp.root_mod.code_model,
            .error_tracing = false,
            .valgrind = false,
        },
        .global = config,
        .cc_argv = &.{},
        .parent = null,
    }) catch |err| {
        comp.lockAndSetMiscFailure(.basic_runtime, "unable to build BASIC runtime: creating module failed: {s}", .{@errorName(err)});
        return error.AlreadyReported;
    };

    var c_source_files = std.array_list.Managed(Compilation.CSourceFile).init(arena);

    const rt_dir = try comp.dirs.zig_lib.join(arena, &.{ "compiler", "basic", "runtime" });
    const macgui_dir = try comp.dirs.zig_lib.join(arena, &.{"macgui"});
    const macgui_audio_dir = try comp.dirs.zig_lib.join(arena, &.{ "macgui", "audio" });

    const sdk_path = if (is_macos)
        comp.sysroot orelse firstExistingPath(&.{
            "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk",
            "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk",
        })
    else
        null;

    const sdk_frameworks = if (sdk_path) |sdk|
        try std.fmt.allocPrint(arena, "{s}/System/Library/Frameworks", .{sdk})
    else
        null;

    const add_manual_sdk_flags = sdk_path != null;
    const base_cflags = try arena.alloc([]const u8, if (add_manual_sdk_flags) 12 else 6);
    base_cflags[0] = "-I";
    base_cflags[1] = rt_dir;
    base_cflags[2] = "-I";
    base_cflags[3] = macgui_dir;
    base_cflags[4] = "-I";
    base_cflags[5] = macgui_audio_dir;
    var common_cflags_len: usize = 6;
    if (add_manual_sdk_flags) {
        const sdk = sdk_path.?;
        base_cflags[6] = "-isysroot";
        base_cflags[7] = sdk;
        base_cflags[8] = "-iframework";
        base_cflags[9] = sdk_frameworks.?;
        base_cflags[10] = "-F";
        base_cflags[11] = sdk_frameworks.?;
        common_cflags_len = 12;
    }
    const common_cflags = base_cflags[0..common_cflags_len];

    const cpp_cflags = try arena.alloc([]const u8, common_cflags.len + 1);
    @memcpy(cpp_cflags[0..common_cflags.len], common_cflags);
    cpp_cflags[common_cflags.len] = "-std=c++17";

    const objcxx_cflags = try arena.alloc([]const u8, common_cflags.len + 2);
    @memcpy(objcxx_cflags[0..common_cflags.len], common_cflags);
    objcxx_cflags[common_cflags.len] = "-std=c++17";
    objcxx_cflags[common_cflags.len + 1] = "-fobjc-arc";

    const objc_cflags = try arena.alloc([]const u8, common_cflags.len + 1);
    @memcpy(objc_cflags[0..common_cflags.len], common_cflags);
    objc_cflags[common_cflags.len] = "-fobjc-arc";

    const stub_runtime_c_sources = [_][]const u8{
        "basic_runtime.c",
        "worker_runtime.c",
        "hashmap_runtime.c",
        "runtime_shims.c",
        "basic_worker_bridge.c",
        "graphics_audio_stubs.c",
        "aot_main_wrapper.c",
    };

    const macos_runtime_c_sources = [_]struct {
        rel_path: []const u8,
        ext: ?Compilation.FileExt = null,
        extra_flags: []const []const u8,
    }{
        .{ .rel_path = "compiler/basic/runtime/basic_runtime.c", .extra_flags = common_cflags },
        .{ .rel_path = "compiler/basic/runtime/worker_runtime.c", .extra_flags = common_cflags },
        .{ .rel_path = "compiler/basic/runtime/hashmap_runtime.c", .extra_flags = common_cflags },
        .{ .rel_path = "compiler/basic/runtime/runtime_shims.c", .extra_flags = common_cflags },
        .{ .rel_path = "compiler/basic/runtime/basic_worker_bridge.c", .extra_flags = common_cflags },
        .{ .rel_path = "compiler/basic/runtime/force_runtime_symbols.c", .extra_flags = common_cflags },
        .{ .rel_path = "macgui/aot_main_wrapper.c", .extra_flags = common_cflags },
        .{ .rel_path = "macgui/aot_appkit_init.m", .ext = .m, .extra_flags = objc_cflags },
        .{ .rel_path = "macgui/ed_graphics_bridge.m", .ext = .m, .extra_flags = objc_cflags },
        .{ .rel_path = "macgui/audio/fb_audio_shim.mm", .ext = .mm, .extra_flags = objcxx_cflags },
        .{ .rel_path = "macgui/audio/FBAudioManager.mm", .ext = .mm, .extra_flags = objcxx_cflags },
        .{ .rel_path = "macgui/audio/MidiEngine.mm", .ext = .mm, .extra_flags = objcxx_cflags },
        .{ .rel_path = "macgui/audio/CoreAudioEngine.cpp", .ext = .cpp, .extra_flags = cpp_cflags },
        .{ .rel_path = "macgui/audio/VoiceController.cpp", .ext = .cpp, .extra_flags = cpp_cflags },
        .{ .rel_path = "macgui/audio/SynthEngine.cpp", .ext = .cpp, .extra_flags = cpp_cflags },
        .{ .rel_path = "macgui/audio/SoundBank.cpp", .ext = .cpp, .extra_flags = cpp_cflags },
        .{ .rel_path = "macgui/audio/MusicBank.cpp", .ext = .cpp, .extra_flags = cpp_cflags },
    };

    if (is_macos) {
        try c_source_files.ensureUnusedCapacity(macos_runtime_c_sources.len);
        for (macos_runtime_c_sources) |src| {
            c_source_files.appendAssumeCapacity(.{
                .src_path = try comp.dirs.zig_lib.join(arena, &.{src.rel_path}),
                .extra_flags = src.extra_flags,
                .owner = root_mod,
                .ext = src.ext,
            });
        }
    } else {
        try c_source_files.ensureUnusedCapacity(stub_runtime_c_sources.len);
        for (stub_runtime_c_sources) |c_src| {
            c_source_files.appendAssumeCapacity(.{
                .src_path = try comp.dirs.zig_lib.join(arena, &.{ "compiler", "basic", "runtime", c_src }),
                .extra_flags = common_cflags[0..2],
                .owner = root_mod,
            });
        }
    }

    const framework_dirs: []const []const u8 = if (is_macos and sdk_frameworks != null)
        try arena.dupe([]const u8, &.{sdk_frameworks.?})
    else if (is_macos)
        &.{}
    else
        &.{};

    var sub_create_diag: Compilation.CreateDiagnostic = undefined;
    const sub_compilation = Compilation.create(comp.gpa, arena, &sub_create_diag, .{
        .dirs = comp.dirs.withoutLocalCache(),
        .thread_pool = comp.thread_pool,
        .self_exe_path = comp.self_exe_path,
        .cache_mode = .whole,
        .config = config,
        .root_mod = root_mod,
        .root_name = if (is_macos) "macguiruntime" else "basic_runtime",
        .sysroot = if (is_macos) comp.sysroot orelse sdk_path else null,
        .libc_installation = comp.libc_installation,
        .emit_bin = .yes_cache,
        .c_source_files = c_source_files.items,
        .framework_dirs = framework_dirs,
        .native_system_include_paths = comp.native_system_include_paths,
        .verbose_cc = comp.verbose_cc,
        .verbose_link = comp.verbose_link,
        .verbose_air = comp.verbose_air,
        .verbose_llvm_ir = comp.verbose_llvm_ir,
        .verbose_llvm_bc = comp.verbose_llvm_bc,
        .verbose_cimport = comp.verbose_cimport,
        .verbose_llvm_cpu_features = comp.verbose_llvm_cpu_features,
        .clang_passthrough_mode = comp.clang_passthrough_mode,
        .function_sections = true,
        .data_sections = true,
        .skip_linker_dependencies = true,
    }) catch |err| {
        switch (err) {
            else => comp.lockAndSetMiscFailure(.basic_runtime, "unable to build BASIC runtime: create compilation failed: {s}", .{@errorName(err)}),
            error.CreateFail => comp.lockAndSetMiscFailure(.basic_runtime, "unable to build BASIC runtime: create compilation failed: {f}", .{sub_create_diag}),
        }
        return error.AlreadyReported;
    };
    defer sub_compilation.destroy();

    comp.updateSubCompilation(sub_compilation, .basic_runtime, prog_node) catch |err| switch (err) {
        error.AlreadyReported => return error.AlreadyReported,
        else => {
            comp.lockAndSetMiscFailure(.basic_runtime, "unable to build BASIC runtime: compilation failed: {s}", .{@errorName(err)});
            return error.AlreadyReported;
        },
    };

    const crt_file = try sub_compilation.toCrtFile();
    comp.queuePrelinkTaskMode(crt_file.full_object_path, &config);
    comp.basic_runtime_lib = crt_file;
}
