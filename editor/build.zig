const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const basic_root_dir = b.option(
        []const u8,
        "basic-root-dir",
        "Path to the authoritative FasterBASIC core compiler tree",
    ) orelse "../zfb2026B/lib/compiler/basic";

    // Keep build_options present because smart_assist.zig imports it.
    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_smart_assist", false);
    build_options.addOption(
        []const u8,
        "smart_assist_model_path",
        "models/qwen2.5-coder-3b-instruct-q4_k_m.gguf",
    );
    const build_options_mod = build_options.createModule();

    const smart_assist_mod = b.createModule(.{
        .root_source_file = b.path("src/smart_assist.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    smart_assist_mod.addImport("build_options", build_options_mod);

    const ed_graphics_mod = b.createModule(.{
        .root_source_file = b.path("macgui/ed_graphics.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const graphics_runtime_mod = b.createModule(.{
        .root_source_file = b.path("macgui/graphics_runtime.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    graphics_runtime_mod.addImport("ed_graphics", ed_graphics_mod);

    const audio_runtime_mod = b.createModule(.{
        .root_source_file = b.path("macgui/audio_runtime.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/ed_main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const basic_frontend_mod = b.createModule(.{
        .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ basic_root_dir, "frontend.zig" }) },
        .target = target,
        .optimize = optimize,
    });

    exe_mod.addImport("smart_assist", smart_assist_mod);
    exe_mod.addImport("ed_graphics", ed_graphics_mod);
    exe_mod.addImport("graphics_runtime", graphics_runtime_mod);
    exe_mod.addImport("audio_runtime", audio_runtime_mod);
    exe_mod.addImport("basic_frontend", basic_frontend_mod);

    // Needed by ObjC bridges and embedded shader headers.
    exe_mod.addIncludePath(b.path("src"));
    exe_mod.addIncludePath(b.path("macgui"));
    exe_mod.addIncludePath(b.path("macgui/audio"));

    exe_mod.addCSourceFiles(.{
        .root = b.path("macgui"),
        .files = &[_][]const u8{
            "ed_metal_bridge.m",
            "ed_graphics_bridge.m",
            "aot_appkit_init.m",
        },
        .flags = &[_][]const u8{
            "-fobjc-arc",
            "-fno-objc-exceptions",
        },
    });

    exe_mod.addCSourceFiles(.{
        .root = b.path("macgui/audio"),
        .files = &[_][]const u8{
            "SynthEngine.cpp",
            "SoundBank.cpp",
            "MusicBank.cpp",
            "CoreAudioEngine.cpp",
            "VoiceController.cpp",
        },
        .flags = &[_][]const u8{
            "-std=c++17",
            "-fno-exceptions",
            "-fno-rtti",
            "-Wall",
            "-Wno-unused-parameter",
        },
    });

    exe_mod.addCSourceFiles(.{
        .root = b.path("macgui/audio"),
        .files = &[_][]const u8{
            "FBAudioManager.mm",
            "fb_audio_shim.mm",
            "MidiEngine.mm",
        },
        .flags = &[_][]const u8{
            "-std=c++17",
            "-fobjc-arc",
            "-fno-exceptions",
            "-fno-rtti",
            "-Wall",
            "-Wno-unused-parameter",
        },
    });

    exe_mod.linkSystemLibrary("c++", .{});

    exe_mod.linkFramework("Cocoa", .{});
    exe_mod.linkFramework("Metal", .{});
    exe_mod.linkFramework("MetalKit", .{});
    exe_mod.linkFramework("CoreText", .{});
    exe_mod.linkFramework("QuartzCore", .{});
    exe_mod.linkFramework("UniformTypeIdentifiers", .{});
    exe_mod.linkFramework("GameController", .{});
    exe_mod.linkFramework("AVFoundation", .{});
    exe_mod.linkFramework("AudioToolbox", .{});
    exe_mod.linkFramework("CoreMIDI", .{});
    exe_mod.linkFramework("CoreAudio", .{});
    exe_mod.linkFramework("Accelerate", .{});
    exe_mod.linkFramework("WebKit", .{});

    // Used by ed_baz.zig.
    exe_mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    exe_mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    exe_mod.linkSystemLibrary("zstd", .{});

    const exe = b.addExecutable(.{
        .name = "Ed",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const glue_mod = b.createModule(.{
        .root_source_file = b.path("src/edglue.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const glue_exe = b.addExecutable(.{
        .name = "edglue",
        .root_module = glue_mod,
    });

    glue_exe.addCSourceFile(.{ .file = b.path("src/edglue_macos_quit.m") });
    glue_exe.root_module.linkFramework("Cocoa", .{});

    b.installArtifact(glue_exe);
    const install_default_icon = b.addInstallFileWithDir(b.path("macgui/FasterBASIC.icns"), .bin, "FasterBASIC.icns");
    b.getInstallStep().dependOn(&install_default_icon.step);

    const install_shaders = b.addInstallDirectory(.{
        .source_dir = b.path("macgui/shaders"),
        .install_dir = .bin,
        .install_subdir = "shaders",
    });
    b.getInstallStep().dependOn(&install_shaders.step);

    const test_step = b.step("test", "Run unit tests");
    const frontend_test_files = [_][]const u8{
        "lexer.zig",
        "parser.zig",
        "ast.zig",
        "semantic.zig",
        "cfg.zig",
    };

    for (frontend_test_files) |test_file| {
        const mod = b.createModule(.{
            .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ basic_root_dir, test_file }) },
            .target = target,
            .optimize = optimize,
        });
        const unit_tests = b.addTest(.{ .root_module = mod });
        const run_tests = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run_tests.step);
    }
}
