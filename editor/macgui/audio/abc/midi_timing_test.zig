const std = @import("std");
const posix = std.posix;
const parser_mod = @import("parser.zig");
const midi_mod = @import("midi.zig");
const types = @import("types.zig");

fn findFirstNoteTrack(tracks: *std.array_list.Managed(midi_mod.MIDITrack)) ?*midi_mod.MIDITrack {
    for (tracks.items) |*track| {
        if (track.ty == .notes) return track;
    }
    return null;
}

fn findTempoTrack(tracks: *std.array_list.Managed(midi_mod.MIDITrack)) ?*midi_mod.MIDITrack {
    for (tracks.items) |*track| {
        if (track.ty == .tempo) return track;
    }
    return null;
}

fn findTrackByVoice(tracks: *std.array_list.Managed(midi_mod.MIDITrack), voice_id: i32) ?*midi_mod.MIDITrack {
    for (tracks.items) |*track| {
        if (track.ty == .notes and track.voice_number == voice_id) return track;
    }
    return null;
}

test "midi timing uses sustained duration for tied notes" {
    const allocator = std.testing.allocator;

    var parser = parser_mod.ABCParser.init(allocator);
    defer parser.deinit();

    var tune = types.ABCTune.init(allocator);
    defer tune.deinit();

    const abc =
        "X:1\n" ++
        "T:TieTiming\n" ++
        "M:4/4\n" ++
        "L:1/8\n" ++
        "K:C\n" ++
        "C-C\n";

    try std.testing.expect(try parser.parseABC(abc, &tune));

    var generator = midi_mod.MIDIGenerator.init(allocator);
    defer generator.deinit();

    var tracks = std.array_list.Managed(midi_mod.MIDITrack).init(allocator);
    defer {
        for (tracks.items) |*track| track.deinit();
        tracks.deinit();
    }

    try std.testing.expect(try generator.generateMIDI(&tune, &tracks));

    const note_track = findFirstNoteTrack(&tracks) orelse return error.TestUnexpectedResult;

    var note_on_count: usize = 0;
    var note_off_count: usize = 0;
    var on_ts: f64 = -1.0;
    var off_ts: f64 = -1.0;

    for (note_track.events.items) |event| {
        if (event.ty == .note_on) {
            note_on_count += 1;
            if (on_ts < 0.0) on_ts = event.timestamp;
        } else if (event.ty == .note_off) {
            note_off_count += 1;
            if (off_ts < 0.0) off_ts = event.timestamp;
        }
    }

    try std.testing.expectEqual(@as(usize, 1), note_on_count);
    try std.testing.expectEqual(@as(usize, 1), note_off_count);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), on_ts, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), off_ts, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), off_ts - on_ts, 0.000001);
}

test "guitar chords only play when enabled" {
    const allocator = std.testing.allocator;

    var parser = parser_mod.ABCParser.init(allocator);
    defer parser.deinit();

    var tune = types.ABCTune.init(allocator);
    defer tune.deinit();

    const abc =
        "X:1\n" ++
        "T:ChordFlag\n" ++
        "M:4/4\n" ++
        "L:1/8\n" ++
        "K:C\n" ++
        "\"C\" C\n";

    try std.testing.expect(try parser.parseABC(abc, &tune));

    const counts_off = try runOnce(false, allocator, &tune);
    const counts_on = try runOnce(true, allocator, &tune);
    _ = posix.unsetenv("ED_PLAY_CHORDS") catch {};

    try std.testing.expectEqual(@as(usize, 1), counts_off.on);
    try std.testing.expectEqual(@as(usize, 1), counts_off.off);

    try std.testing.expectEqual(@as(usize, 4), counts_on.on);
    try std.testing.expectEqual(@as(usize, 4), counts_on.off);
}

fn runOnce(env_on: bool, allocator: std.mem.Allocator, tune: *types.ABCTune) !struct { on: usize, off: usize } {
    if (env_on) {
        try posix.setenv("ED_PLAY_CHORDS", "1", true);
    } else {
        _ = posix.unsetenv("ED_PLAY_CHORDS") catch {};
    }

    var generator = midi_mod.MIDIGenerator.init(allocator);
    defer generator.deinit();

    var tracks = std.array_list.Managed(midi_mod.MIDITrack).init(allocator);
    defer {
        for (tracks.items) |*track| track.deinit();
        tracks.deinit();
    }

    try std.testing.expect(try generator.generateMIDI(tune, &tracks));

    const note_track = findFirstNoteTrack(&tracks) orelse return error.TestUnexpectedResult;

    var counts = .{ .on = @as(usize, 0), .off = @as(usize, 0) };
    for (note_track.events.items) |event| {
        switch (event.ty) {
            .note_on => counts.on += 1,
            .note_off => counts.off += 1,
            else => {},
        }
    }

    return counts;
}

test "midi timing preserves broken-rhythm note boundaries" {
    const allocator = std.testing.allocator;

    var parser = parser_mod.ABCParser.init(allocator);
    defer parser.deinit();

    var tune = types.ABCTune.init(allocator);
    defer tune.deinit();

    const abc =
        "X:1\n" ++
        "T:BrokenTiming\n" ++
        "M:4/4\n" ++
        "L:1/8\n" ++
        "K:C\n" ++
        "C>D\n";

    try std.testing.expect(try parser.parseABC(abc, &tune));

    var generator = midi_mod.MIDIGenerator.init(allocator);
    defer generator.deinit();

    var tracks = std.array_list.Managed(midi_mod.MIDITrack).init(allocator);
    defer {
        for (tracks.items) |*track| track.deinit();
        tracks.deinit();
    }

    try std.testing.expect(try generator.generateMIDI(&tune, &tracks));

    const note_track = findFirstNoteTrack(&tracks) orelse return error.TestUnexpectedResult;

    var on_timestamps = [_]f64{ -1.0, -1.0 };
    var off_timestamps = [_]f64{ -1.0, -1.0 };
    var on_idx: usize = 0;
    var off_idx: usize = 0;

    for (note_track.events.items) |event| {
        switch (event.ty) {
            .note_on => {
                if (on_idx < on_timestamps.len) {
                    on_timestamps[on_idx] = event.timestamp;
                }
                on_idx += 1;
            },
            .note_off => {
                if (off_idx < off_timestamps.len) {
                    off_timestamps[off_idx] = event.timestamp;
                }
                off_idx += 1;
            },
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 2), on_idx);
    try std.testing.expectEqual(@as(usize, 2), off_idx);

    try std.testing.expectApproxEqAbs(@as(f64, 0.0), on_timestamps[0], 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0 / 16.0), on_timestamps[1], 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0 / 16.0), off_timestamps[0], 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 4.0), off_timestamps[1], 0.000001);
}

test "note track EOT includes trailing rest duration" {
    const allocator = std.testing.allocator;

    var parser = parser_mod.ABCParser.init(allocator);
    defer parser.deinit();

    var tune = types.ABCTune.init(allocator);
    defer tune.deinit();

    const abc =
        "X:1\n" ++
        "T:RestEOT\n" ++
        "M:4/4\n" ++
        "L:1/8\n" ++
        "K:C\n" ++
        "C z2\n";

    try std.testing.expect(try parser.parseABC(abc, &tune));

    var generator = midi_mod.MIDIGenerator.init(allocator);
    defer generator.deinit();

    var tracks = std.array_list.Managed(midi_mod.MIDITrack).init(allocator);
    defer {
        for (tracks.items) |*track| track.deinit();
        tracks.deinit();
    }

    try std.testing.expect(try generator.generateMIDI(&tune, &tracks));

    const note_track = findFirstNoteTrack(&tracks) orelse return error.TestUnexpectedResult;

    var note_eot: ?f64 = null;
    for (note_track.events.items) |event| {
        if (event.ty == .meta_end_of_track) {
            note_eot = event.timestamp;
            break;
        }
    }

    try std.testing.expect(note_eot != null);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0 / 8.0), note_eot.?, 0.000001);
}

test "chord notes end together and note-track EOT matches chord end" {
    const allocator = std.testing.allocator;

    var parser = parser_mod.ABCParser.init(allocator);
    defer parser.deinit();

    var tune = types.ABCTune.init(allocator);
    defer tune.deinit();

    const abc =
        "X:1\n" ++
        "T:ChordTiming\n" ++
        "M:4/4\n" ++
        "L:1/8\n" ++
        "K:C\n" ++
        "[CEG]2\n";

    try std.testing.expect(try parser.parseABC(abc, &tune));

    var generator = midi_mod.MIDIGenerator.init(allocator);
    defer generator.deinit();

    var tracks = std.array_list.Managed(midi_mod.MIDITrack).init(allocator);
    defer {
        for (tracks.items) |*track| track.deinit();
        tracks.deinit();
    }

    try std.testing.expect(try generator.generateMIDI(&tune, &tracks));

    const note_track = findFirstNoteTrack(&tracks) orelse return error.TestUnexpectedResult;

    var note_on_count: usize = 0;
    var note_off_count: usize = 0;
    var first_note_off_ts: ?f64 = null;
    var all_note_off_same = true;
    var note_eot: ?f64 = null;

    for (note_track.events.items) |event| {
        switch (event.ty) {
            .note_on => note_on_count += 1,
            .note_off => {
                note_off_count += 1;
                if (first_note_off_ts == null) {
                    first_note_off_ts = event.timestamp;
                } else {
                    if (@abs(event.timestamp - first_note_off_ts.?) > 0.000001) {
                        all_note_off_same = false;
                    }
                }
            },
            .meta_end_of_track => note_eot = event.timestamp,
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 3), note_on_count);
    try std.testing.expectEqual(@as(usize, 3), note_off_count);
    try std.testing.expect(first_note_off_ts != null);
    try std.testing.expect(all_note_off_same);
    try std.testing.expect(note_eot != null);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 4.0), first_note_off_ts.?, 0.000001);
    try std.testing.expectApproxEqAbs(first_note_off_ts.?, note_eot.?, 0.000001);
}

test "tempo track EOT reaches end of musical timeline" {
    const allocator = std.testing.allocator;

    var parser = parser_mod.ABCParser.init(allocator);
    defer parser.deinit();

    var tune = types.ABCTune.init(allocator);
    defer tune.deinit();

    const abc =
        "X:1\n" ++
        "T:TempoEOT\n" ++
        "M:4/4\n" ++
        "L:1/8\n" ++
        "K:C\n" ++
        "C z2\n";

    try std.testing.expect(try parser.parseABC(abc, &tune));

    var generator = midi_mod.MIDIGenerator.init(allocator);
    defer generator.deinit();

    var tracks = std.array_list.Managed(midi_mod.MIDITrack).init(allocator);
    defer {
        for (tracks.items) |*track| track.deinit();
        tracks.deinit();
    }

    try std.testing.expect(try generator.generateMIDI(&tune, &tracks));

    const tempo_track = findTempoTrack(&tracks) orelse return error.TestUnexpectedResult;

    var tempo_eot: ?f64 = null;
    for (tempo_track.events.items) |event| {
        if (event.ty == .meta_end_of_track) {
            tempo_eot = event.timestamp;
            break;
        }
    }

    try std.testing.expect(tempo_eot != null);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0 / 8.0), tempo_eot.?, 0.000001);
}

test "multi voice overlap uses separate channels and aligned starts" {
    const allocator = std.testing.allocator;

    var parser = parser_mod.ABCParser.init(allocator);
    defer parser.deinit();

    var tune = types.ABCTune.init(allocator);
    defer tune.deinit();

    const abc =
        "X:1\n" ++
        "T:VoiceOverlap\n" ++
        "M:4/4\n" ++
        "L:1/8\n" ++
        "K:C\n" ++
        "V:1\n" ++
        "C\n" ++
        "V:2\n" ++
        "E\n";

    try std.testing.expect(try parser.parseABC(abc, &tune));

    var generator = midi_mod.MIDIGenerator.init(allocator);
    defer generator.deinit();

    var tracks = std.array_list.Managed(midi_mod.MIDITrack).init(allocator);
    defer {
        for (tracks.items) |*track| track.deinit();
        tracks.deinit();
    }

    try std.testing.expect(try generator.generateMIDI(&tune, &tracks));

    const v1 = findTrackByVoice(&tracks, 1) orelse return error.TestUnexpectedResult;
    const v2 = findTrackByVoice(&tracks, 2) orelse return error.TestUnexpectedResult;

    try std.testing.expect(v1.channel >= 0);
    try std.testing.expect(v2.channel >= 0);
    try std.testing.expect(v1.channel != v2.channel);

    var v1_on: ?f64 = null;
    for (v1.events.items) |event| {
        if (event.ty == .note_on) {
            v1_on = event.timestamp;
            break;
        }
    }

    var v2_on: ?f64 = null;
    for (v2.events.items) |event| {
        if (event.ty == .note_on) {
            v2_on = event.timestamp;
            break;
        }
    }

    try std.testing.expect(v1_on != null);
    try std.testing.expect(v2_on != null);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), v1_on.?, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), v2_on.?, 0.000001);
}

test "tempo changes are emitted at exact feature boundaries" {
    const allocator = std.testing.allocator;

    var parser = parser_mod.ABCParser.init(allocator);
    defer parser.deinit();

    var tune = types.ABCTune.init(allocator);
    defer tune.deinit();

    const abc =
        "X:1\n" ++
        "T:TempoBoundaries\n" ++
        "M:4/4\n" ++
        "L:1/8\n" ++
        "Q:120\n" ++
        "K:C\n" ++
        "C\n" ++
        "Q:180\n" ++
        "D\n";

    try std.testing.expect(try parser.parseABC(abc, &tune));

    var generator = midi_mod.MIDIGenerator.init(allocator);
    defer generator.deinit();

    var tracks = std.array_list.Managed(midi_mod.MIDITrack).init(allocator);
    defer {
        for (tracks.items) |*track| track.deinit();
        tracks.deinit();
    }

    try std.testing.expect(try generator.generateMIDI(&tune, &tracks));

    const tempo_track = findTempoTrack(&tracks) orelse return error.TestUnexpectedResult;

    var tempo_events = [_]f64{ -1.0, -1.0, -1.0 };
    var tempo_idx: usize = 0;
    for (tempo_track.events.items) |event| {
        if (event.ty == .meta_tempo and tempo_idx < tempo_events.len) {
            tempo_events[tempo_idx] = event.timestamp;
            tempo_idx += 1;
        }
    }

    try std.testing.expect(tempo_idx >= 2);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), tempo_events[0], 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 8.0), tempo_events[1], 0.000001);
}

test "three voice overlap keeps distinct channels and synchronized starts" {
    const allocator = std.testing.allocator;

    var parser = parser_mod.ABCParser.init(allocator);
    defer parser.deinit();

    var tune = types.ABCTune.init(allocator);
    defer tune.deinit();

    const abc =
        "X:1\n" ++
        "T:ThreeVoiceOverlap\n" ++
        "M:4/4\n" ++
        "L:1/8\n" ++
        "K:C\n" ++
        "V:1\n" ++
        "C\n" ++
        "V:2\n" ++
        "E\n" ++
        "V:3\n" ++
        "G\n";

    try std.testing.expect(try parser.parseABC(abc, &tune));

    var generator = midi_mod.MIDIGenerator.init(allocator);
    defer generator.deinit();

    var tracks = std.array_list.Managed(midi_mod.MIDITrack).init(allocator);
    defer {
        for (tracks.items) |*track| track.deinit();
        tracks.deinit();
    }

    try std.testing.expect(try generator.generateMIDI(&tune, &tracks));

    const v1 = findTrackByVoice(&tracks, 1) orelse return error.TestUnexpectedResult;
    const v2 = findTrackByVoice(&tracks, 2) orelse return error.TestUnexpectedResult;
    const v3 = findTrackByVoice(&tracks, 3) orelse return error.TestUnexpectedResult;

    try std.testing.expect(v1.channel != v2.channel);
    try std.testing.expect(v1.channel != v3.channel);
    try std.testing.expect(v2.channel != v3.channel);

    var starts = [_]f64{ -1.0, -1.0, -1.0 };
    const voice_tracks = [_]*midi_mod.MIDITrack{ v1, v2, v3 };
    for (voice_tracks, 0..) |track, i| {
        for (track.events.items) |event| {
            if (event.ty == .note_on) {
                starts[i] = event.timestamp;
                break;
            }
        }
    }

    for (starts) |start| {
        try std.testing.expect(start >= 0.0);
        try std.testing.expectApproxEqAbs(@as(f64, 0.0), start, 0.000001);
    }
}

test "rapid successive tempo changes keep monotonic boundary timestamps" {
    const allocator = std.testing.allocator;

    var parser = parser_mod.ABCParser.init(allocator);
    defer parser.deinit();

    var tune = types.ABCTune.init(allocator);
    defer tune.deinit();

    const abc =
        "X:1\n" ++
        "T:RapidTempo\n" ++
        "M:4/4\n" ++
        "L:1/8\n" ++
        "Q:120\n" ++
        "K:C\n" ++
        "C\n" ++
        "Q:132\n" ++
        "D\n" ++
        "Q:144\n" ++
        "E\n" ++
        "Q:156\n" ++
        "F\n";

    try std.testing.expect(try parser.parseABC(abc, &tune));

    var generator = midi_mod.MIDIGenerator.init(allocator);
    defer generator.deinit();

    var tracks = std.array_list.Managed(midi_mod.MIDITrack).init(allocator);
    defer {
        for (tracks.items) |*track| track.deinit();
        tracks.deinit();
    }

    try std.testing.expect(try generator.generateMIDI(&tune, &tracks));

    const tempo_track = findTempoTrack(&tracks) orelse return error.TestUnexpectedResult;

    var timestamps = std.array_list.Managed(f64).init(allocator);
    defer timestamps.deinit();

    for (tempo_track.events.items) |event| {
        if (event.ty == .meta_tempo) {
            try timestamps.append(event.timestamp);
        }
    }

    try std.testing.expect(timestamps.items.len >= 4);

    var i: usize = 1;
    while (i < timestamps.items.len) : (i += 1) {
        try std.testing.expect(timestamps.items[i] >= timestamps.items[i - 1]);
    }

    try std.testing.expectApproxEqAbs(@as(f64, 0.0), timestamps.items[0], 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 8.0), timestamps.items[1], 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0 / 8.0), timestamps.items[2], 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0 / 8.0), timestamps.items[3], 0.000001);
}

test "voice instrument attributes map to per-track MIDI program changes" {
    const allocator = std.testing.allocator;

    var parser = parser_mod.ABCParser.init(allocator);
    defer parser.deinit();

    var tune = types.ABCTune.init(allocator);
    defer tune.deinit();

    const abc =
        "X:1\n" ++
        "T:VoiceInstruments\n" ++
        "M:4/4\n" ++
        "L:1/8\n" ++
        "K:C\n" ++
        "V:1 name=\"Lead\" instrument=40\n" ++
        "V:2 name=\"Harmony\" instrument=41\n" ++
        "[V:1] C\n" ++
        "[V:2] E\n";

    try std.testing.expect(try parser.parseABC(abc, &tune));

    var generator = midi_mod.MIDIGenerator.init(allocator);
    defer generator.deinit();

    var tracks = std.array_list.Managed(midi_mod.MIDITrack).init(allocator);
    defer {
        for (tracks.items) |*track| track.deinit();
        tracks.deinit();
    }

    try std.testing.expect(try generator.generateMIDI(&tune, &tracks));

    const v1 = findTrackByVoice(&tracks, 1) orelse return error.TestUnexpectedResult;
    const v2 = findTrackByVoice(&tracks, 2) orelse return error.TestUnexpectedResult;

    var v1_program: ?u8 = null;
    for (v1.events.items) |event| {
        if (event.ty == .program_change) {
            v1_program = event.data1;
            break;
        }
    }

    var v2_program: ?u8 = null;
    for (v2.events.items) |event| {
        if (event.ty == .program_change) {
            v2_program = event.data1;
            break;
        }
    }

    try std.testing.expect(v1_program != null);
    try std.testing.expect(v2_program != null);
    try std.testing.expectEqual(@as(u8, 40), v1_program.?);
    try std.testing.expectEqual(@as(u8, 41), v2_program.?);
}

test "multi-word quoted voice names keep instrument program mapping" {
    const allocator = std.testing.allocator;

    var parser = parser_mod.ABCParser.init(allocator);
    defer parser.deinit();

    var tune = types.ABCTune.init(allocator);
    defer tune.deinit();

    const abc =
        "X:1\n" ++
        "T:QuotedNamesPrograms\n" ++
        "M:4/4\n" ++
        "L:1/8\n" ++
        "K:C\n" ++
        "V:1 name=\"Soprano Lead\" instrument=40\n" ++
        "V:2 name=\"Alto Harmony\" instrument=41\n" ++
        "[V:1] C\n" ++
        "[V:2] E\n";

    try std.testing.expect(try parser.parseABC(abc, &tune));
    try std.testing.expectEqualStrings("Soprano Lead", (tune.voices.get(1) orelse return error.TestUnexpectedResult).name);
    try std.testing.expectEqualStrings("Alto Harmony", (tune.voices.get(2) orelse return error.TestUnexpectedResult).name);

    var generator = midi_mod.MIDIGenerator.init(allocator);
    defer generator.deinit();

    var tracks = std.array_list.Managed(midi_mod.MIDITrack).init(allocator);
    defer {
        for (tracks.items) |*track| track.deinit();
        tracks.deinit();
    }

    try std.testing.expect(try generator.generateMIDI(&tune, &tracks));

    const v1 = findTrackByVoice(&tracks, 1) orelse return error.TestUnexpectedResult;
    const v2 = findTrackByVoice(&tracks, 2) orelse return error.TestUnexpectedResult;

    var v1_program: ?u8 = null;
    for (v1.events.items) |event| {
        if (event.ty == .program_change) {
            v1_program = event.data1;
            break;
        }
    }

    var v2_program: ?u8 = null;
    for (v2.events.items) |event| {
        if (event.ty == .program_change) {
            v2_program = event.data1;
            break;
        }
    }

    try std.testing.expect(v1_program != null);
    try std.testing.expect(v2_program != null);
    try std.testing.expectEqual(@as(u8, 40), v1_program.?);
    try std.testing.expectEqual(@as(u8, 41), v2_program.?);
}
