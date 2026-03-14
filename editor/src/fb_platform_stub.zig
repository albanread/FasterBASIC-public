// fb_platform_stub.zig
//
// Minimal Zig stub module for the fb_platform static library.
//
// This library contains all the platform-specific Objective-C/C++ code
// (graphics, audio, AppKit bridges) compiled as a static library so
// AOT-compiled BASIC programs can link against it.
//
// The actual implementation is in C/C++/Objective-C files added via
// addCSourceFiles in build.zig.

const std = @import("std");

// This module intentionally has no exported functions - it's just a stub
// to allow build.zig to create a library from pure C/Obj-C sources.
//
// All the actual symbols are provided by:
//   - ed_metal_bridge.m
//   - ed_graphics_bridge.m
//   - fbc_appkit_runner.m
//   - SynthEngine.cpp, SoundBank.cpp, etc. (audio subsystem)
//   - FBAudioManager.mm, fb_audio_shim.mm, etc.

comptime {
    // Force libc linking
    _ = std.c;
}
