const std = @import("std");
const parser_mod = @import("parser.zig");
const types = @import("types.zig");

test "parser handles dotted note duration" {
    const allocator = std.testing.allocator;
    var parser = parser_mod.ABCParser.init(allocator);
    defer parser.deinit();

    var tune = types.ABCTune.init(allocator);
    defer tune.deinit();

    const abc =
        "X:1\n" ++
        "T:Dotted\n" ++
        "M:4/4\n" ++
        "L:1/8\n" ++
        "K:C\n" ++
        "C. D\n";

    try std.testing.expect(try parser.parseABC(abc, &tune));

    var found = false;
    for (tune.features.items) |feature| {
        if (feature.ty == .note) {
            const n = feature.data.note;
            try std.testing.expectEqual(@as(i32, 3), n.duration.num);
            try std.testing.expectEqual(@as(i32, 16), n.duration.denom);
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "guitar chord symbols emit gchord feature" {
    const allocator = std.testing.allocator;
    var parser = parser_mod.ABCParser.init(allocator);
    defer parser.deinit();

    var tune = types.ABCTune.init(allocator);
    defer tune.deinit();

    const abc =
        "X:1\n" ++
        "T:GChord\n" ++
        "M:4/4\n" ++
        "L:1/8\n" ++
        "K:C\n" ++
        "\"C\" C\n";

    try std.testing.expect(try parser.parseABC(abc, &tune));

    var found = false;
    for (tune.features.items) |feature| {
        if (feature.ty == .gchord) {
            const gc = feature.data.gchord;
            try std.testing.expectEqualSlices(u8, "C", gc.symbol);
            try std.testing.expectEqual(@as(u8, 48), gc.root_note);
            try std.testing.expectEqual(@as(i32, 1), gc.duration.num);
            try std.testing.expectEqual(@as(i32, 8), gc.duration.denom);
            try std.testing.expectApproxEqAbs(@as(f64, 0.0), feature.ts, 0.000001);
            found = true;
            break;
        }
    }

    try std.testing.expect(found);
}

test "inline tempo line emits tempo feature" {
    const allocator = std.testing.allocator;
    var parser = parser_mod.ABCParser.init(allocator);
    defer parser.deinit();

    var tune = types.ABCTune.init(allocator);
    defer tune.deinit();

    const abc =
        "X:1\n" ++
        "T:TempoInline\n" ++
        "M:4/4\n" ++
        "L:1/8\n" ++
        "K:C\n" ++
        "Q:150\n" ++
        "C\n";

    try std.testing.expect(try parser.parseABC(abc, &tune));

    var found = false;
    for (tune.features.items) |feature| {
        if (feature.ty == .tempo) {
            try std.testing.expectEqual(@as(i32, 150), feature.data.tempo.bpm);
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "tied notes merge into single sustained note" {
    const allocator = std.testing.allocator;
    var parser = parser_mod.ABCParser.init(allocator);
    defer parser.deinit();

    var tune = types.ABCTune.init(allocator);
    defer tune.deinit();

    const abc =
        "X:1\n" ++
        "T:Ties\n" ++
        "M:4/4\n" ++
        "L:1/8\n" ++
        "K:C\n" ++
        "C-C D\n";

    try std.testing.expect(try parser.parseABC(abc, &tune));

    var note_count: usize = 0;
    var first_duration: f64 = 0.0;
    for (tune.features.items) |feature| {
        if (feature.ty == .note) {
            note_count += 1;
            if (note_count == 1) {
                first_duration = feature.data.note.duration.toDouble();
            }
        }
    }

    try std.testing.expectEqual(@as(usize, 2), note_count);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), first_duration, 0.000001);
}

test "key signature adjusts note pitch" {
    const allocator = std.testing.allocator;

    var parser_c = parser_mod.ABCParser.init(allocator);
    defer parser_c.deinit();
    var tune_c = types.ABCTune.init(allocator);
    defer tune_c.deinit();

    const abc_c =
        "X:1\n" ++
        "T:KeyC\n" ++
        "M:4/4\n" ++
        "L:1/8\n" ++
        "K:C\n" ++
        "F\n";

    try std.testing.expect(try parser_c.parseABC(abc_c, &tune_c));

    var parser_g = parser_mod.ABCParser.init(allocator);
    defer parser_g.deinit();
    var tune_g = types.ABCTune.init(allocator);
    defer tune_g.deinit();

    const abc_g =
        "X:1\n" ++
        "T:KeyG\n" ++
        "M:4/4\n" ++
        "L:1/8\n" ++
        "K:G\n" ++
        "F\n";

    try std.testing.expect(try parser_g.parseABC(abc_g, &tune_g));

    var note_c: ?u8 = null;
    for (tune_c.features.items) |feature| {
        if (feature.ty == .note) {
            note_c = feature.data.note.midi_note;
            break;
        }
    }

    var note_g: ?u8 = null;
    for (tune_g.features.items) |feature| {
        if (feature.ty == .note) {
            note_g = feature.data.note.midi_note;
            break;
        }
    }

    try std.testing.expect(note_c != null);
    try std.testing.expect(note_g != null);
    try std.testing.expectEqual(@as(i32, @intCast(note_c.? + 1)), @as(i32, @intCast(note_g.?)));
}

test "repeat expansion duplicates repeated section" {
    const allocator = std.testing.allocator;
    var parser = parser_mod.ABCParser.init(allocator);
    defer parser.deinit();

    var tune = types.ABCTune.init(allocator);
    defer tune.deinit();

    const abc =
        "X:1\n" ++
        "T:Repeat\n" ++
        "M:4/4\n" ++
        "L:1/8\n" ++
        "K:C\n" ++
        "|: C D :|\n";

    try std.testing.expect(try parser.parseABC(abc, &tune));

    var note_count: usize = 0;
    for (tune.features.items) |feature| {
        if (feature.ty == .note) note_count += 1;
    }

    try std.testing.expectEqual(@as(usize, 4), note_count);
}

test "mid tune key change emits feature and affects following note" {
    const allocator = std.testing.allocator;
    var parser = parser_mod.ABCParser.init(allocator);
    defer parser.deinit();

    var tune = types.ABCTune.init(allocator);
    defer tune.deinit();

    const abc =
        "X:1\n" ++
        "T:MidKey\n" ++
        "M:4/4\n" ++
        "L:1/8\n" ++
        "K:C\n" ++
        "F\n" ++
        "K:G\n" ++
        "F\n";

    try std.testing.expect(try parser.parseABC(abc, &tune));

    var first_note: ?u8 = null;
    var second_note: ?u8 = null;
    var key_change_found = false;

    for (tune.features.items) |feature| {
        if (feature.ty == .key and feature.ts > 0.0) {
            key_change_found = true;
        }
        if (feature.ty == .note) {
            if (first_note == null) {
                first_note = feature.data.note.midi_note;
            } else if (second_note == null) {
                second_note = feature.data.note.midi_note;
            }
        }
    }

    try std.testing.expect(key_change_found);
    try std.testing.expect(first_note != null);
    try std.testing.expect(second_note != null);
    try std.testing.expectEqual(@as(i32, @intCast(first_note.? + 1)), @as(i32, @intCast(second_note.?)));
}

test "broken rhythm adjusts paired durations" {
    const allocator = std.testing.allocator;
    var parser = parser_mod.ABCParser.init(allocator);
    defer parser.deinit();

    var tune = types.ABCTune.init(allocator);
    defer tune.deinit();

    const abc =
        "X:1\n" ++
        "T:BrokenRhythm\n" ++
        "M:4/4\n" ++
        "L:1/8\n" ++
        "K:C\n" ++
        "C>D\n";

    try std.testing.expect(try parser.parseABC(abc, &tune));

    var first_duration: ?f64 = null;
    var second_duration: ?f64 = null;
    var first_ts: ?f64 = null;
    var second_ts: ?f64 = null;

    for (tune.features.items) |feature| {
        if (feature.ty == .note) {
            if (first_duration == null) {
                first_duration = feature.data.note.duration.toDouble();
                first_ts = feature.ts;
            } else if (second_duration == null) {
                second_duration = feature.data.note.duration.toDouble();
                second_ts = feature.ts;
                break;
            }
        }
    }

    try std.testing.expect(first_duration != null);
    try std.testing.expect(second_duration != null);
    try std.testing.expect(first_ts != null);
    try std.testing.expect(second_ts != null);

    try std.testing.expectApproxEqAbs(@as(f64, 3.0 / 16.0), first_duration.?, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 16.0), second_duration.?, 0.000001);
    try std.testing.expectApproxEqAbs(first_duration.?, second_ts.? - first_ts.?, 0.000001);
}

test "multi voice timekeeping restores per voice timeline" {
    const allocator = std.testing.allocator;
    var parser = parser_mod.ABCParser.init(allocator);
    defer parser.deinit();

    var tune = types.ABCTune.init(allocator);
    defer tune.deinit();

    const abc =
        "X:1\n" ++
        "T:Voices\n" ++
        "M:4/4\n" ++
        "L:1/8\n" ++
        "K:C\n" ++
        "V:1\n" ++
        "C D\n" ++
        "V:2\n" ++
        "E\n" ++
        "V:1\n" ++
        "F\n";

    try std.testing.expect(try parser.parseABC(abc, &tune));

    var voice1_first_ts: ?f64 = null;
    var voice1_second_ts: ?f64 = null;
    var voice1_third_ts: ?f64 = null;
    var voice2_ts: ?f64 = null;

    for (tune.features.items) |feature| {
        if (feature.ty != .note) continue;

        if (feature.voice_id == 1) {
            if (voice1_first_ts == null) {
                voice1_first_ts = feature.ts;
            } else if (voice1_second_ts == null) {
                voice1_second_ts = feature.ts;
            } else if (voice1_third_ts == null) {
                voice1_third_ts = feature.ts;
            }
        } else if (feature.voice_id == 2 and voice2_ts == null) {
            voice2_ts = feature.ts;
        }
    }

    try std.testing.expect(voice1_first_ts != null);
    try std.testing.expect(voice1_second_ts != null);
    try std.testing.expect(voice1_third_ts != null);
    try std.testing.expect(voice2_ts != null);

    try std.testing.expectApproxEqAbs(@as(f64, 0.0), voice1_first_ts.?, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 8.0), voice1_second_ts.?, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0 / 8.0), voice1_third_ts.?, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), voice2_ts.?, 0.000001);
}

test "tie across barline merges sustained note" {
    const allocator = std.testing.allocator;
    var parser = parser_mod.ABCParser.init(allocator);
    defer parser.deinit();

    var tune = types.ABCTune.init(allocator);
    defer tune.deinit();

    const abc =
        "X:1\n" ++
        "T:TieAcrossBar\n" ++
        "M:4/4\n" ++
        "L:1/8\n" ++
        "K:C\n" ++
        "C-|C D\n";

    try std.testing.expect(try parser.parseABC(abc, &tune));

    var note_count: usize = 0;
    var first_duration: ?f64 = null;
    for (tune.features.items) |feature| {
        if (feature.ty == .note) {
            note_count += 1;
            if (first_duration == null) {
                first_duration = feature.data.note.duration.toDouble();
            }
        }
    }

    try std.testing.expectEqual(@as(usize, 2), note_count);
    try std.testing.expect(first_duration != null);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), first_duration.?, 0.000001);
}

test "malformed chord recovers and continues parsing" {
    const allocator = std.testing.allocator;
    var parser = parser_mod.ABCParser.init(allocator);
    defer parser.deinit();

    var tune = types.ABCTune.init(allocator);
    defer tune.deinit();

    const abc =
        "X:1\n" ++
        "T:MalformedChord\n" ++
        "M:4/4\n" ++
        "L:1/8\n" ++
        "K:C\n" ++
        "[CE D\n";

    try std.testing.expect(try parser.parseABC(abc, &tune));

    var note_count: usize = 0;
    for (tune.features.items) |feature| {
        if (feature.ty == .note) {
            note_count += 1;
        }
    }

    try std.testing.expect(note_count >= 1);
}

test "voice definition supports multi-word quoted name" {
    const allocator = std.testing.allocator;
    var parser = parser_mod.ABCParser.init(allocator);
    defer parser.deinit();

    var tune = types.ABCTune.init(allocator);
    defer tune.deinit();

    const abc =
        "X:1\n" ++
        "T:VoiceNameQuoted\n" ++
        "M:4/4\n" ++
        "L:1/8\n" ++
        "K:C\n" ++
        "V:1 name=\"Soprano Lead\" instrument=40\n" ++
        "[V:1] C\n";

    try std.testing.expect(try parser.parseABC(abc, &tune));

    const voice = tune.voices.get(1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Soprano Lead", voice.name);
    try std.testing.expectEqual(@as(u8, 40), voice.instrument);
}

test "section-style inline named voices parse into separate timelines" {
    const allocator = std.testing.allocator;
    var parser = parser_mod.ABCParser.init(allocator);
    defer parser.deinit();

    var tune = types.ABCTune.init(allocator);
    defer tune.deinit();

    const abc =
        "X:1\n" ++
        "T:Inline Voice Test\n" ++
        "M:4/4\n" ++
        "L:1/4\n" ++
        "Q:120\n" ++
        "K:C\n" ++
        "[V:melody]\n" ++
        "C D E F |\n" ++
        "[V:bass]\n" ++
        "G A B c |\n";

    try std.testing.expect(try parser.parseABC(abc, &tune));
    try std.testing.expectEqual(@as(usize, 2), tune.voices.count());

    var melody_voice: ?i32 = null;
    var bass_voice: ?i32 = null;

    var vit = tune.voices.iterator();
    while (vit.next()) |entry| {
        const id = entry.key_ptr.*;
        const name = entry.value_ptr.name;
        if (std.mem.eql(u8, name, "melody")) {
            melody_voice = id;
        } else if (std.mem.eql(u8, name, "bass")) {
            bass_voice = id;
        }
    }

    try std.testing.expect(melody_voice != null);
    try std.testing.expect(bass_voice != null);
    try std.testing.expect(melody_voice.? != bass_voice.?);

    var melody_notes: usize = 0;
    var bass_notes: usize = 0;
    for (tune.features.items) |feature| {
        if (feature.ty != .note) continue;
        if (feature.voice_id == melody_voice.?) melody_notes += 1;
        if (feature.voice_id == bass_voice.?) bass_notes += 1;
    }

    try std.testing.expectEqual(@as(usize, 4), melody_notes);
    try std.testing.expectEqual(@as(usize, 4), bass_notes);
}

test "bar accidental carries within bar then resets" {
    const allocator = std.testing.allocator;
    var parser = parser_mod.ABCParser.init(allocator);
    defer parser.deinit();

    var tune = types.ABCTune.init(allocator);
    defer tune.deinit();

    const abc =
        "X:1\n" ++
        "T:BarAccidentals\n" ++
        "M:4/4\n" ++
        "L:1/8\n" ++
        "K:C\n" ++
        "^F F | F\n";

    try std.testing.expect(try parser.parseABC(abc, &tune));

    var notes = [_]u8{ 0, 0, 0 };
    var idx: usize = 0;
    for (tune.features.items) |feature| {
        if (feature.ty != .note) continue;
        if (idx < notes.len) {
            notes[idx] = feature.data.note.midi_note;
        }
        idx += 1;
    }

    try std.testing.expectEqual(@as(usize, 3), idx);
    try std.testing.expectEqual(notes[0], notes[1]);
    try std.testing.expectEqual(@as(i32, @intCast(notes[2] + 1)), @as(i32, @intCast(notes[1])));
}

test "triplet scales next three notes" {
    const allocator = std.testing.allocator;
    var parser = parser_mod.ABCParser.init(allocator);
    defer parser.deinit();

    var tune = types.ABCTune.init(allocator);
    defer tune.deinit();

    const abc =
        "X:1\n" ++
        "T:TupletTriplet\n" ++
        "M:4/4\n" ++
        "L:1/8\n" ++
        "K:C\n" ++
        "(3ABC\n";

    try std.testing.expect(try parser.parseABC(abc, &tune));

    var durations = [_]f64{ 0.0, 0.0, 0.0 };
    var timestamps = [_]f64{ 0.0, 0.0, 0.0 };
    var idx: usize = 0;
    for (tune.features.items) |feature| {
        if (feature.ty != .note) continue;
        if (idx < durations.len) {
            durations[idx] = feature.data.note.duration.toDouble();
            timestamps[idx] = feature.ts;
        }
        idx += 1;
    }

    try std.testing.expectEqual(@as(usize, 3), idx);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 12.0), durations[0], 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 12.0), durations[1], 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 12.0), durations[2], 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 12.0), timestamps[1] - timestamps[0], 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 12.0), timestamps[2] - timestamps[1], 0.000001);
}

test "bracketed inline K L Q M fields affect subsequent parsing" {
    const allocator = std.testing.allocator;
    var parser = parser_mod.ABCParser.init(allocator);
    defer parser.deinit();

    var tune = types.ABCTune.init(allocator);
    defer tune.deinit();

    const abc =
        "X:1\n" ++
        "T:InlineBracketFields\n" ++
        "M:4/4\n" ++
        "L:1/8\n" ++
        "K:C\n" ++
        "F [K:G] F [L:1/16] C2 [Q:150] [M:3/4] D\n";

    try std.testing.expect(try parser.parseABC(abc, &tune));

    var notes = [_]types.Note{ undefined, undefined, undefined, undefined };
    var note_idx: usize = 0;
    var saw_tempo = false;
    var saw_time = false;
    var saw_key_change = false;

    for (tune.features.items) |feature| {
        switch (feature.ty) {
            .note => {
                if (note_idx < notes.len) {
                    notes[note_idx] = feature.data.note;
                }
                note_idx += 1;
            },
            .tempo => {
                if (feature.data.tempo.bpm == 150) saw_tempo = true;
            },
            .time => {
                if (feature.data.time.num == 3 and feature.data.time.denom == 4) saw_time = true;
            },
            .key => {
                if (feature.ts > 0.0 and feature.data.key.sharps == 1) saw_key_change = true;
            },
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 4), note_idx);
    try std.testing.expectEqual(@as(i32, @intCast(notes[0].midi_note + 1)), @as(i32, @intCast(notes[1].midi_note)));
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 8.0), notes[0].duration.toDouble(), 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 8.0), notes[2].duration.toDouble(), 0.000001);
    try std.testing.expect(saw_tempo);
    try std.testing.expect(saw_time);
    try std.testing.expect(saw_key_change);
}

test "header continuation appends title field" {
    const allocator = std.testing.allocator;
    var parser = parser_mod.ABCParser.init(allocator);
    defer parser.deinit();

    var tune = types.ABCTune.init(allocator);
    defer tune.deinit();

    const abc =
        "X:1\n" ++
        "T:Inline\n" ++
        "+: Voice Test\n" ++
        "M:4/4\n" ++
        "L:1/8\n" ++
        "K:C\n" ++
        "C\n";

    try std.testing.expect(try parser.parseABC(abc, &tune));
    try std.testing.expectEqualStrings("Inline Voice Test", tune.title);
}

test "continuation on tempo line is ignored under strict string-only continuation" {
    const allocator = std.testing.allocator;
    var parser = parser_mod.ABCParser.init(allocator);
    defer parser.deinit();

    var tune = types.ABCTune.init(allocator);
    defer tune.deinit();

    const abc =
        "X:1\n" ++
        "T:TempoContinuation\n" ++
        "M:4/4\n" ++
        "L:1/8\n" ++
        "Q:120\n" ++
        "+:150\n" ++
        "K:C\n" ++
        "C\n";

    try std.testing.expect(try parser.parseABC(abc, &tune));
    try std.testing.expectEqual(@as(i32, 120), tune.default_tempo.bpm);
    try std.testing.expect(parser.warnings.items.len >= 1);
}

test "leading continuation line emits warning" {
    const allocator = std.testing.allocator;
    var parser = parser_mod.ABCParser.init(allocator);
    defer parser.deinit();

    var tune = types.ABCTune.init(allocator);
    defer tune.deinit();

    const abc =
        "+:orphan continuation\n" ++
        "X:1\n" ++
        "T:LeadingContinuation\n" ++
        "M:4/4\n" ++
        "L:1/8\n" ++
        "K:C\n" ++
        "C\n";

    try std.testing.expect(try parser.parseABC(abc, &tune));
    try std.testing.expect(parser.warnings.items.len >= 1);
}

test "valid H continuation does not emit warning" {
    const allocator = std.testing.allocator;
    var parser = parser_mod.ABCParser.init(allocator);
    defer parser.deinit();

    var tune = types.ABCTune.init(allocator);
    defer tune.deinit();

    const abc =
        "X:1\n" ++
        "T:HistoryContinuation\n" ++
        "H:first line\n" ++
        "+:second line\n" ++
        "M:4/4\n" ++
        "L:1/8\n" ++
        "K:C\n" ++
        "C\n";

    try std.testing.expect(try parser.parseABC(abc, &tune));
    try std.testing.expectEqual(@as(usize, 0), parser.warnings.items.len);
    try std.testing.expectEqualStrings("first line second line", tune.history);
}

test "string metadata fields are retained and continuable" {
    const allocator = std.testing.allocator;
    var parser = parser_mod.ABCParser.init(allocator);
    defer parser.deinit();

    var tune = types.ABCTune.init(allocator);
    defer tune.deinit();

    const abc =
        "X:1\n" ++
        "T:Meta\n" ++
        "C:Jane Doe\n" ++
        "O:Ireland\n" ++
        "R:reel\n" ++
        "N:first\n" ++
        "+:second\n" ++
        "M:4/4\n" ++
        "L:1/8\n" ++
        "K:C\n" ++
        "C\n";

    try std.testing.expect(try parser.parseABC(abc, &tune));
    try std.testing.expectEqualStrings("Jane Doe", tune.composer);
    try std.testing.expectEqualStrings("Ireland", tune.origin);
    try std.testing.expectEqualStrings("reel", tune.rhythm);
    try std.testing.expectEqualStrings("first second", tune.notes);
    try std.testing.expectEqual(@as(usize, 0), parser.warnings.items.len);
}

test "W and w lyrics fields are retained" {
    const allocator = std.testing.allocator;
    var parser = parser_mod.ABCParser.init(allocator);
    defer parser.deinit();

    var tune = types.ABCTune.init(allocator);
    defer tune.deinit();

    const abc =
        "X:1\n" ++
        "T:Lyrics\n" ++
        "W:line one\n" ++
        "w:do re mi\n" ++
        "M:4/4\n" ++
        "L:1/8\n" ++
        "K:C\n" ++
        "C D E\n";

    try std.testing.expect(try parser.parseABC(abc, &tune));
    try std.testing.expectEqualStrings("line one", tune.words);
    try std.testing.expectEqualStrings("do re mi", tune.aligned_words);
}

test "w continuation appends aligned lyrics" {
    const allocator = std.testing.allocator;
    var parser = parser_mod.ABCParser.init(allocator);
    defer parser.deinit();

    var tune = types.ABCTune.init(allocator);
    defer tune.deinit();

    const abc =
        "X:1\n" ++
        "T:LyricsContinuation\n" ++
        "w:fa la\n" ++
        "+:la\n" ++
        "M:4/4\n" ++
        "L:1/8\n" ++
        "K:C\n" ++
        "C D E\n";

    try std.testing.expect(try parser.parseABC(abc, &tune));
    try std.testing.expectEqualStrings("fa la la", tune.aligned_words);
    try std.testing.expectEqual(@as(usize, 0), parser.warnings.items.len);
}

test "grace notes are timing-neutral" {
    const allocator = std.testing.allocator;
    var parser = parser_mod.ABCParser.init(allocator);
    defer parser.deinit();

    var tune = types.ABCTune.init(allocator);
    defer tune.deinit();

    const abc =
        "X:1\n" ++
        "T:GraceNeutral\n" ++
        "M:4/4\n" ++
        "L:1/8\n" ++
        "K:C\n" ++
        "C{g}D\n";

    try std.testing.expect(try parser.parseABC(abc, &tune));

    var timestamps = [_]f64{ 0.0, 0.0 };
    var idx: usize = 0;
    for (tune.features.items) |feature| {
        if (feature.ty != .note) continue;
        if (idx < timestamps.len) timestamps[idx] = feature.ts;
        idx += 1;
    }

    try std.testing.expectEqual(@as(usize, 2), idx);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), timestamps[0], 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 8.0), timestamps[1], 0.000001);
}

test "acciaccatura grace syntax does not block note parse" {
    const allocator = std.testing.allocator;
    var parser = parser_mod.ABCParser.init(allocator);
    defer parser.deinit();

    var tune = types.ABCTune.init(allocator);
    defer tune.deinit();

    const abc =
        "X:1\n" ++
        "T:Acciaccatura\n" ++
        "M:4/4\n" ++
        "L:1/8\n" ++
        "K:C\n" ++
        "{/g}C\n";

    try std.testing.expect(try parser.parseABC(abc, &tune));

    var note_count: usize = 0;
    for (tune.features.items) |feature| {
        if (feature.ty == .note) note_count += 1;
    }

    try std.testing.expectEqual(@as(usize, 1), note_count);
}

test "broken rhythm with intervening grace is parsed" {
    const allocator = std.testing.allocator;
    var parser = parser_mod.ABCParser.init(allocator);
    defer parser.deinit();

    var tune = types.ABCTune.init(allocator);
    defer tune.deinit();

    const abc =
        "X:1\n" ++
        "T:GraceBrokenRhythm\n" ++
        "M:4/4\n" ++
        "L:1/8\n" ++
        "K:C\n" ++
        "A{g}<A\n";

    try std.testing.expect(try parser.parseABC(abc, &tune));

    var durations = [_]f64{ 0.0, 0.0 };
    var idx: usize = 0;
    for (tune.features.items) |feature| {
        if (feature.ty != .note) continue;
        if (idx < durations.len) durations[idx] = feature.data.note.duration.toDouble();
        idx += 1;
    }

    try std.testing.expectEqual(@as(usize, 2), idx);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 16.0), durations[0], 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0 / 16.0), durations[1], 0.000001);
}
