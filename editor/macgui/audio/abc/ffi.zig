const std = @import("std");
const types = @import("types.zig");
const parser = @import("parser.zig");
const midi = @import("midi.zig");
const writer = @import("writer.zig");

pub const ABCTuneHandle = *types.ABCTune;

export fn abc_parse(abc_string: [*:0]const u8) ?ABCTuneHandle {
    const allocator = std.heap.c_allocator;
    var p = parser.ABCParser.init(allocator);
    defer p.deinit();

    const tune = p.parse(std.mem.span(abc_string)) catch return null;

    // We need to allocate the tune on the heap so it outlives this function
    const tune_ptr = allocator.create(types.ABCTune) catch return null;
    tune_ptr.* = tune;
    return tune_ptr;
}

export fn abc_free_tune(tune: ?ABCTuneHandle) void {
    if (tune) |t| {
        const allocator = std.heap.c_allocator;
        t.deinit();
        allocator.destroy(t);
    }
}

export fn abc_generate_midi(tune: ?ABCTuneHandle, output_path: [*:0]const u8) bool {
    if (tune == null) return false;

    const allocator = std.heap.c_allocator;
    var generator = midi.MIDIGenerator.init(allocator);
    defer generator.deinit();

    var tracks = std.array_list.Managed(midi.MIDITrack).init(allocator);
    defer {
        for (tracks.items) |*track| {
            track.deinit();
        }
        tracks.deinit();
    }

    const ok = generator.generateMIDI(tune.?, &tracks) catch return false;
    if (!ok) {
        return false;
    }

    var file = std.fs.cwd().createFile(std.mem.span(output_path), .{}) catch return false;
    defer file.close();

    var w = writer.MIDIWriter.init(allocator, generator.ticks_per_quarter);
    var file_buf: [4096]u8 = undefined;
    var file_writer = file.writer(&file_buf);
    w.write(&tracks, &file_writer.interface) catch return false;
    file_writer.interface.flush() catch return false;

    return true;
}
