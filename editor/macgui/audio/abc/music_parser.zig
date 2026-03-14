const std = @import("std");
const types = @import("types.zig");
const VoiceManager = @import("voice_manager.zig").VoiceManager;

pub const MusicParser = struct {
    allocator: std.mem.Allocator,
    current_time: f64,
    current_line: usize,
    in_chord: bool,
    in_grace: bool,
    voice_bar_accidentals: std.AutoHashMap(i32, [7]?i8),
    tuplet_num: i32,
    tuplet_denom: i32,
    tuplet_notes_remaining: i32,

    pub fn init(allocator: std.mem.Allocator) MusicParser {
        return .{
            .allocator = allocator,
            .current_time = 0.0,
            .current_line = 0,
            .in_chord = false,
            .in_grace = false,
            .voice_bar_accidentals = std.AutoHashMap(i32, [7]?i8).init(allocator),
            .tuplet_num = 1,
            .tuplet_denom = 1,
            .tuplet_notes_remaining = 0,
        };
    }

    pub fn deinit(self: *MusicParser) void {
        self.voice_bar_accidentals.deinit();
    }

    pub fn reset(self: *MusicParser) void {
        self.current_time = 0.0;
        self.current_line = 0;
        self.in_chord = false;
        self.in_grace = false;
        self.voice_bar_accidentals.clearRetainingCapacity();
        self.tuplet_num = 1;
        self.tuplet_denom = 1;
        self.tuplet_notes_remaining = 0;
    }

    pub fn parseMusicLine(self: *MusicParser, line: []const u8, tune: *types.ABCTune, voice_mgr: *VoiceManager) !void {
        if (line.len >= 2 and line[1] == ':') {
            // Inline header field
            try self.parseInlineHeader(line, tune, voice_mgr);
            return;
        }

        try self.parseNoteSequence(line, tune, voice_mgr);
    }

    fn parseInlineHeader(self: *MusicParser, line: []const u8, tune: *types.ABCTune, voice_mgr: *VoiceManager) !void {
        if (line.len < 2 or line[1] != ':') return;

        const field = line[0];
        const value = std.mem.trim(u8, line[2..], " \t");
        try self.applyInlineFieldValue(field, value, tune, voice_mgr);
    }

    fn applyInlineFieldValue(self: *MusicParser, field: u8, value: []const u8, tune: *types.ABCTune, voice_mgr: *VoiceManager) !void {
        const voice = tune.voices.getPtr(voice_mgr.current_voice) orelse return;

        switch (field) {
            'Q' => {
                var tempo_str = value;
                if (std.mem.indexOf(u8, value, "=")) |eq_pos| {
                    tempo_str = value[eq_pos + 1 ..];
                }
                tempo_str = std.mem.trim(u8, tempo_str, " \t");
                if (std.fmt.parseInt(i32, tempo_str, 10)) |bpm| {
                    tune.default_tempo = .{ .bpm = bpm };
                    try tune.features.append(.{
                        .ty = .tempo,
                        .voice_id = voice_mgr.current_voice,
                        .ts = self.current_time,
                        .line_number = self.current_line,
                        .data = .{ .tempo = .{ .bpm = bpm } },
                    });
                } else |_| {}
            },
            'M' => {
                var tsig = voice.timesig;
                if (std.mem.eql(u8, value, "C") or std.mem.eql(u8, value, "c")) {
                    tsig = .{ .num = 4, .denom = 4 };
                } else if (std.mem.eql(u8, value, "C|") or std.mem.eql(u8, value, "c|")) {
                    tsig = .{ .num = 2, .denom = 2 };
                } else if (std.mem.indexOf(u8, value, "/")) |slash_pos| {
                    const num_str = value[0..slash_pos];
                    const denom_str = value[slash_pos + 1 ..];
                    if (std.fmt.parseInt(u8, num_str, 10)) |num| {
                        if (std.fmt.parseInt(u8, denom_str, 10)) |denom| {
                            tsig = .{ .num = num, .denom = denom };
                        } else |_| {}
                    } else |_| {}
                }

                voice.timesig = tsig;
                try tune.features.append(.{
                    .ty = .time,
                    .voice_id = voice_mgr.current_voice,
                    .ts = self.current_time,
                    .line_number = self.current_line,
                    .data = .{ .time = tsig },
                });
            },
            'L' => {
                if (std.mem.indexOf(u8, value, "/")) |slash_pos| {
                    const num_str = value[0..slash_pos];
                    const denom_str = value[slash_pos + 1 ..];
                    if (std.fmt.parseInt(i32, num_str, 10)) |num| {
                        if (std.fmt.parseInt(i32, denom_str, 10)) |denom| {
                            voice.unit_len = types.Fraction.init(num, denom);
                        } else |_| {}
                    } else |_| {}
                }
            },
            'K' => {
                const key_sig = parseKeySig(value);
                voice.key = key_sig;
                try tune.features.append(.{
                    .ty = .key,
                    .voice_id = voice_mgr.current_voice,
                    .ts = self.current_time,
                    .line_number = self.current_line,
                    .data = .{ .key = key_sig },
                });
            },
            else => {},
        }
    }

    fn parseNoteSequence(self: *MusicParser, sequence: []const u8, tune: *types.ABCTune, voice_mgr: *VoiceManager) !void {
        var pos: usize = 0;
        while (pos < sequence.len) {
            pos = skipWhitespace(sequence, pos);
            if (pos >= sequence.len) break;

            if (sequence[pos] == '{') {
                _ = skipGraceGroup(sequence, &pos);
                continue;
            }

            if (sequence[pos] == '[') {
                if (try self.parseInlineBracketField(sequence, &pos, tune, voice_mgr)) {
                    continue;
                }
            }

            // Check for inline voice switch [V:name]
            if (sequence.len - pos >= 3 and sequence[pos] == '[' and sequence[pos + 1] == 'V' and sequence[pos + 2] == ':') {
                if (try self.parseInlineVoiceSwitch(sequence, &pos, tune, voice_mgr)) {
                    continue;
                }
            }

            // Check for guitar chord "chord_name"
            if (sequence[pos] == '"') {
                var gchord: types.GuitarChord = undefined;
                if (try self.parseGuitarChord(sequence, &pos, &gchord)) {
                    // Look ahead for note duration
                    const next_pos = skipWhitespace(sequence, pos);
                    if (next_pos < sequence.len and isNote(sequence[next_pos])) {
                        var dummy_note: types.Note = undefined;
                        var temp_pos = next_pos;
                        if (try self.parseNote(sequence, &temp_pos, &dummy_note, tune, voice_mgr.current_voice)) {
                            gchord.duration = dummy_note.duration;
                        } else {
                            gchord.duration = tune.voices.get(voice_mgr.current_voice).?.unit_len;
                        }
                    } else {
                        gchord.duration = tune.voices.get(voice_mgr.current_voice).?.unit_len;
                    }

                    try self.createGChordFeature(gchord, tune, voice_mgr.current_voice);
                    continue;
                }
            }

            // Check for chord
            if (sequence[pos] == '[' and !self.in_chord) {
                var chord: types.Chord = undefined;
                if (try self.parseChord(sequence, &pos, &chord, tune, voice_mgr.current_voice)) {
                    try self.createChordFeature(chord, tune, voice_mgr.current_voice);
                    self.current_time += chord.duration.toDouble();
                } else {
                    // parseChord advances position to allow line recovery; continue parsing remainder
                }
                continue;
            }

            // Check for bar line
            if (isBarLine(sequence[pos])) {
                var barline: types.BarLine = undefined;
                if (try self.parseBarLine(sequence, &pos, &barline)) {
                    self.resetVoiceBarAccidentals(voice_mgr.current_voice);
                    try self.createBarFeature(barline, tune, voice_mgr.current_voice);
                    continue;
                }
            }

            // Check for rest
            if (sequence[pos] == 'z' or sequence[pos] == 'Z') {
                var rest: types.Rest = undefined;
                if (try self.parseRest(sequence, &pos, &rest, tune, voice_mgr.current_voice)) {
                    try self.createRestFeature(rest, tune, voice_mgr.current_voice);
                    self.current_time += rest.duration.toDouble();
                    continue;
                }
            }

            // Check for slur start/end
            if (sequence[pos] == '(' or sequence[pos] == ')') {
                if (sequence[pos] == '(' and pos + 1 < sequence.len and std.ascii.isDigit(sequence[pos + 1])) {
                    _ = try self.parseTupletSpecifier(sequence, &pos, tune, voice_mgr.current_voice);
                    continue;
                }
                pos += 1;
                continue;
            }

            // Check for note
            if (isNote(sequence[pos]) or isAccidentalMarker(sequence[pos])) {
                var note: types.Note = undefined;
                const current_voice = voice_mgr.current_voice;

                if (try self.parseNote(sequence, &pos, &note, tune, current_voice)) {
                    // Check for broken rhythm (> or <)
                    var has_broken_rhythm = false;
                    var is_first_longer = false;
                    if (pos < sequence.len) {
                        if (sequence[pos] == '>') {
                            has_broken_rhythm = true;
                            is_first_longer = true;
                            pos += 1;
                        } else if (sequence[pos] == '<') {
                            has_broken_rhythm = true;
                            is_first_longer = false;
                            pos += 1;
                        } else {
                            var lookahead = pos;
                            while (lookahead < sequence.len and skipGraceGroup(sequence, &lookahead)) {
                                lookahead = skipWhitespace(sequence, lookahead);
                            }

                            if (lookahead < sequence.len) {
                                if (sequence[lookahead] == '>') {
                                    has_broken_rhythm = true;
                                    is_first_longer = true;
                                    pos = lookahead + 1;
                                } else if (sequence[lookahead] == '<') {
                                    has_broken_rhythm = true;
                                    is_first_longer = false;
                                    pos = lookahead + 1;
                                }
                            }
                        }
                    }

                    if (has_broken_rhythm) {
                        if (is_first_longer) {
                            note.duration = note.duration.mul(types.Fraction.init(3, 2));
                        } else {
                            note.duration = note.duration.mul(types.Fraction.init(1, 2));
                        }
                    }

                    self.applyTupletToDuration(&note.duration);

                    // Check for tie
                    if (pos < sequence.len and sequence[pos] == '-') {
                        note.is_tied = true;
                        pos += 1;
                    }

                    try self.mergeTiedNotes(sequence, &pos, &note, tune, current_voice);

                    try self.createNoteFeature(note, tune, current_voice);
                    self.current_time += note.duration.toDouble();

                    if (has_broken_rhythm) {
                        pos = skipWhitespace(sequence, pos);
                        while (pos < sequence.len and skipGraceGroup(sequence, &pos)) {
                            pos = skipWhitespace(sequence, pos);
                        }
                        if (pos < sequence.len and isNote(sequence[pos])) {
                            var next_note: types.Note = undefined;
                            if (try self.parseNote(sequence, &pos, &next_note, tune, current_voice)) {
                                if (is_first_longer) {
                                    next_note.duration = next_note.duration.mul(types.Fraction.init(1, 2));
                                } else {
                                    next_note.duration = next_note.duration.mul(types.Fraction.init(3, 2));
                                }

                                self.applyTupletToDuration(&next_note.duration);

                                if (pos < sequence.len and sequence[pos] == '-') {
                                    next_note.is_tied = true;
                                    pos += 1;
                                }

                                try self.mergeTiedNotes(sequence, &pos, &next_note, tune, current_voice);

                                try self.createNoteFeature(next_note, tune, current_voice);
                                self.current_time += next_note.duration.toDouble();
                            }
                        }
                    }
                }
                continue;
            }

            // Unrecognized character
            pos += 1;
        }
    }

    fn parseNote(self: *MusicParser, sequence: []const u8, pos: *usize, note: *types.Note, tune: *types.ABCTune, voice_id: i32) !bool {
        if (pos.* >= sequence.len) return false;

        var probe_pos = pos.*;
        _ = parseAccidental(sequence, &probe_pos);
        if (probe_pos >= sequence.len or !isNote(sequence[probe_pos])) return false;

        const explicit_accidental = parseAccidental(sequence, pos);
        note.pitch = parseNotePitch(sequence, pos);
        if (note.pitch == 0) return false;

        note.octave = parseOctave(sequence, pos);

        const voice = tune.voices.get(voice_id) orelse return error.VoiceNotFound;
        note.duration = parseDuration(sequence, pos, voice.unit_len);

        const note_index = pitchIndex(note.pitch) orelse return false;
        var accidental = keyAccidentalForPitch(voice.key, std.ascii.toUpper(note.pitch));

        if (explicit_accidental) |a| {
            accidental = a;
            try self.setBarAccidental(voice_id, note_index, a);
        } else if (self.getBarAccidental(voice_id, note_index)) |a| {
            accidental = a;
        }

        note.accidental = accidental;
        note.midi_note = calculateMidiNote(note.pitch, accidental, note.octave, voice.transpose);
        note.velocity = voice.velocity;
        note.is_tied = false;

        return true;
    }

    fn parseRest(self: *MusicParser, sequence: []const u8, pos: *usize, rest: *types.Rest, tune: *types.ABCTune, voice_id: i32) !bool {
        _ = self;
        if (pos.* >= sequence.len or (sequence[pos.*] != 'z' and sequence[pos.*] != 'Z')) return false;
        pos.* += 1;

        const voice = tune.voices.get(voice_id) orelse return error.VoiceNotFound;
        rest.duration = parseDuration(sequence, pos, voice.unit_len);

        return true;
    }

    fn parseChord(self: *MusicParser, sequence: []const u8, pos: *usize, chord: *types.Chord, tune: *types.ABCTune, voice_id: i32) !bool {
        if (pos.* >= sequence.len or sequence[pos.*] != '[') return false;
        const start_pos = pos.*;
        pos.* += 1;

        chord.notes = std.array_list.Managed(types.Note).init(self.allocator);

        while (pos.* < sequence.len and sequence[pos.*] != ']') {
            pos.* = skipWhitespace(sequence, pos.*);
            if (pos.* >= sequence.len or sequence[pos.*] == ']') break;

            var note: types.Note = undefined;
            if (try self.parseNote(sequence, pos, &note, tune, voice_id)) {
                try chord.notes.append(note);
            } else {
                if (pos.* < sequence.len and sequence[pos.*] != ']') pos.* += 1;
            }
            pos.* = skipWhitespace(sequence, pos.*);
        }

        if (pos.* < sequence.len and sequence[pos.*] == ']') {
            pos.* += 1;
            const voice = tune.voices.get(voice_id) orelse return error.VoiceNotFound;
            chord.duration = parseDuration(sequence, pos, voice.unit_len);
            return chord.notes.items.len > 0;
        }

        chord.notes.deinit();
        pos.* = @min(start_pos + 1, sequence.len);
        return false;
    }

    fn parseGuitarChord(self: *MusicParser, sequence: []const u8, pos: *usize, gchord: *types.GuitarChord) !bool {
        _ = self;
        if (pos.* >= sequence.len or sequence[pos.*] != '"') return false;
        pos.* += 1;

        const start = pos.*;
        while (pos.* < sequence.len and sequence[pos.*] != '"') {
            pos.* += 1;
        }

        if (pos.* < sequence.len and sequence[pos.*] == '"') {
            const symbol = sequence[start..pos.*];
            pos.* += 1;
            gchord.symbol = symbol;
            gchord.root_note = parseChordRoot(symbol);
            gchord.chord_type = parseChordType(symbol);
            return true;
        }

        return false;
    }

    fn parseBarLine(self: *MusicParser, sequence: []const u8, pos: *usize, barline: *types.BarLine) !bool {
        _ = self;
        if (pos.* >= sequence.len or !isBarLine(sequence[pos.*])) return false;

        const start = pos.*;
        while (pos.* < sequence.len and isBarLine(sequence[pos.*])) {
            pos.* += 1;
        }

        const bar_str = sequence[start..pos.*];
        if (std.mem.eql(u8, bar_str, "|")) {
            barline.bar_type = .bar1;
        } else if (std.mem.eql(u8, bar_str, "||")) {
            barline.bar_type = .double_bar;
        } else if (std.mem.eql(u8, bar_str, "|:")) {
            barline.bar_type = .rep_bar;
        } else if (std.mem.eql(u8, bar_str, ":|")) {
            barline.bar_type = .bar_rep;
        } else if (std.mem.eql(u8, bar_str, ":|:")) {
            barline.bar_type = .double_rep;
        } else {
            barline.bar_type = .bar1;
        }

        return true;
    }

    fn parseInlineVoiceSwitch(self: *MusicParser, sequence: []const u8, pos: *usize, tune: *types.ABCTune, voice_mgr: *VoiceManager) !bool {
        if (pos.* + 2 >= sequence.len or sequence[pos.*] != '[' or sequence[pos.* + 1] != 'V' or sequence[pos.* + 2] != ':') return false;
        pos.* += 3;

        const start = pos.*;
        while (pos.* < sequence.len and sequence[pos.*] != ']' and !std.ascii.isWhitespace(sequence[pos.*])) {
            pos.* += 1;
        }

        const voice_identifier = sequence[start..pos.*];

        while (pos.* < sequence.len and sequence[pos.*] != ']') {
            pos.* += 1;
        }

        if (pos.* < sequence.len and sequence[pos.*] == ']') {
            pos.* += 1;
        } else {
            return false;
        }

        if (voice_identifier.len == 0) return false;

        try voice_mgr.saveCurrentTime(self.current_time);
        const voice_id = try voice_mgr.switchToVoice(voice_identifier, tune);
        self.current_time = voice_mgr.restoreVoiceTime(voice_id);

        const voice_change = types.VoiceChange{
            .voice_number = voice_id,
            .voice_name = voice_identifier,
        };

        try tune.features.append(.{
            .ty = .voice,
            .voice_id = voice_id,
            .ts = self.current_time,
            .line_number = self.current_line,
            .data = .{ .voice = voice_change },
        });

        return true;
    }

    fn parseInlineBracketField(self: *MusicParser, sequence: []const u8, pos: *usize, tune: *types.ABCTune, voice_mgr: *VoiceManager) !bool {
        if (pos.* + 3 >= sequence.len or sequence[pos.*] != '[') return false;
        const field = sequence[pos.* + 1];
        if (!std.ascii.isAlphabetic(field) or sequence[pos.* + 2] != ':') return false;

        if (std.ascii.toUpper(field) == 'V') {
            return self.parseInlineVoiceSwitch(sequence, pos, tune, voice_mgr);
        }

        var p = pos.* + 3;
        const value_start = p;
        while (p < sequence.len and sequence[p] != ']') : (p += 1) {}
        if (p >= sequence.len) return false;

        const value = std.mem.trim(u8, sequence[value_start..p], " \t");
        try self.applyInlineFieldValue(std.ascii.toUpper(field), value, tune, voice_mgr);

        pos.* = p + 1;
        return true;
    }

    fn createNoteFeature(self: *MusicParser, note: types.Note, tune: *types.ABCTune, voice_id: i32) !void {
        try tune.features.append(.{
            .ty = .note,
            .voice_id = voice_id,
            .ts = self.current_time,
            .line_number = self.current_line,
            .data = .{ .note = note },
        });
    }

    fn mergeTiedNotes(self: *MusicParser, sequence: []const u8, pos: *usize, note: *types.Note, tune: *types.ABCTune, voice_id: i32) !void {
        while (note.is_tied) {
            const scan_start = pos.*;
            var scan_pos = skipTieJoinDelimiters(sequence, scan_start);

            if (scan_pos >= sequence.len or !isNote(sequence[scan_pos])) {
                break;
            }

            var next_note: types.Note = undefined;
            if (!(try self.parseNote(sequence, &scan_pos, &next_note, tune, voice_id))) {
                break;
            }

            if (next_note.midi_note != note.midi_note) {
                break;
            }

            note.duration = note.duration.add(next_note.duration);
            pos.* = scan_pos;

            if (pos.* < sequence.len and sequence[pos.*] == '-') {
                note.is_tied = true;
                pos.* += 1;
            } else {
                note.is_tied = false;
            }
        }

        note.is_tied = false;
    }

    fn createRestFeature(self: *MusicParser, rest: types.Rest, tune: *types.ABCTune, voice_id: i32) !void {
        try tune.features.append(.{
            .ty = .rest,
            .voice_id = voice_id,
            .ts = self.current_time,
            .line_number = self.current_line,
            .data = .{ .rest = rest },
        });
    }

    fn createChordFeature(self: *MusicParser, chord: types.Chord, tune: *types.ABCTune, voice_id: i32) !void {
        try tune.features.append(.{
            .ty = .chord,
            .voice_id = voice_id,
            .ts = self.current_time,
            .line_number = self.current_line,
            .data = .{ .chord = chord },
        });
    }

    fn createGChordFeature(self: *MusicParser, gchord: types.GuitarChord, tune: *types.ABCTune, voice_id: i32) !void {
        try tune.features.append(.{
            .ty = .gchord,
            .voice_id = voice_id,
            .ts = self.current_time,
            .line_number = self.current_line,
            .data = .{ .gchord = gchord },
        });
    }

    fn createBarFeature(self: *MusicParser, barline: types.BarLine, tune: *types.ABCTune, voice_id: i32) !void {
        try tune.features.append(.{
            .ty = .bar,
            .voice_id = voice_id,
            .ts = self.current_time,
            .line_number = self.current_line,
            .data = .{ .bar = barline },
        });
    }

    fn ensureVoiceBarAccidentalState(self: *MusicParser, voice_id: i32) !*[7]?i8 {
        const entry = try self.voice_bar_accidentals.getOrPut(voice_id);
        if (!entry.found_existing) {
            entry.value_ptr.* = emptyAccidentals();
        }
        return entry.value_ptr;
    }

    fn setBarAccidental(self: *MusicParser, voice_id: i32, note_index: usize, accidental: i8) !void {
        const state = try self.ensureVoiceBarAccidentalState(voice_id);
        state[note_index] = accidental;
    }

    fn getBarAccidental(self: *MusicParser, voice_id: i32, note_index: usize) ?i8 {
        if (self.voice_bar_accidentals.get(voice_id)) |state| {
            return state[note_index];
        }
        return null;
    }

    fn resetVoiceBarAccidentals(self: *MusicParser, voice_id: i32) void {
        if (self.voice_bar_accidentals.getPtr(voice_id)) |state| {
            state.* = emptyAccidentals();
        }
    }

    fn parseTupletSpecifier(self: *MusicParser, sequence: []const u8, pos: *usize, tune: *types.ABCTune, voice_id: i32) !bool {
        if (pos.* >= sequence.len or sequence[pos.*] != '(') return false;
        if (pos.* + 1 >= sequence.len or !std.ascii.isDigit(sequence[pos.* + 1])) return false;

        pos.* += 1;
        const p = @as(i32, sequence[pos.*] - '0');
        pos.* += 1;

        var q: ?i32 = null;
        var r: ?i32 = null;

        if (pos.* < sequence.len and sequence[pos.*] == ':') {
            pos.* += 1;

            if (pos.* < sequence.len and std.ascii.isDigit(sequence[pos.*])) {
                q = @as(i32, sequence[pos.*] - '0');
                pos.* += 1;
            }

            if (pos.* < sequence.len and sequence[pos.*] == ':') {
                pos.* += 1;
                if (pos.* < sequence.len and std.ascii.isDigit(sequence[pos.*])) {
                    r = @as(i32, sequence[pos.*] - '0');
                    pos.* += 1;
                }
            }
        }

        const voice = tune.voices.get(voice_id) orelse return error.VoiceNotFound;
        const inferred_q = inferTupletQ(p, voice.timesig);
        const final_q = q orelse inferred_q;
        const final_r = r orelse p;

        if (p <= 0 or final_q <= 0 or final_r <= 0) return false;

        self.tuplet_num = final_q;
        self.tuplet_denom = p;
        self.tuplet_notes_remaining = final_r;
        return true;
    }

    fn applyTupletToDuration(self: *MusicParser, duration: *types.Fraction) void {
        if (self.tuplet_notes_remaining <= 0) return;

        duration.* = duration.mul(types.Fraction.init(self.tuplet_num, self.tuplet_denom));
        self.tuplet_notes_remaining -= 1;
        if (self.tuplet_notes_remaining <= 0) {
            self.tuplet_num = 1;
            self.tuplet_denom = 1;
            self.tuplet_notes_remaining = 0;
        }
    }
};

fn skipWhitespace(sequence: []const u8, pos: usize) usize {
    var p = pos;
    while (p < sequence.len and (sequence[p] == ' ' or sequence[p] == '\t')) {
        p += 1;
    }
    return p;
}

fn isNote(c: u8) bool {
    return (c >= 'A' and c <= 'G') or (c >= 'a' and c <= 'g');
}

fn isBarLine(c: u8) bool {
    return c == '|' or c == ':' or c == '[' or c == ']';
}

fn isAccidentalMarker(c: u8) bool {
    return c == '^' or c == '_' or c == '=';
}

fn parseAccidental(sequence: []const u8, pos: *usize) ?i8 {
    if (pos.* >= sequence.len) return null;
    const c = sequence[pos.*];
    if (c == '^') {
        if (pos.* + 1 < sequence.len and sequence[pos.* + 1] == '^') {
            pos.* += 2;
            return 2;
        }
        pos.* += 1;
        return 1;
    } else if (c == '_') {
        if (pos.* + 1 < sequence.len and sequence[pos.* + 1] == '_') {
            pos.* += 2;
            return -2;
        }
        pos.* += 1;
        return -1;
    } else if (c == '=') {
        pos.* += 1;
        return 0;
    }
    return null;
}

fn parseNotePitch(sequence: []const u8, pos: *usize) u8 {
    if (pos.* >= sequence.len or !isNote(sequence[pos.*])) return 0;
    const pitch = sequence[pos.*];
    pos.* += 1;
    return pitch;
}

fn parseOctave(sequence: []const u8, pos: *usize) i8 {
    var octave: i8 = 0;
    while (pos.* < sequence.len and sequence[pos.*] == '\'') {
        octave += 1;
        pos.* += 1;
    }
    while (pos.* < sequence.len and sequence[pos.*] == ',') {
        octave -= 1;
        pos.* += 1;
    }
    return octave;
}

fn parseDuration(sequence: []const u8, pos: *usize, default_duration: types.Fraction) types.Fraction {
    var duration = default_duration;

    if (pos.* < sequence.len and std.ascii.isDigit(sequence[pos.*])) {
        var numerator: i32 = 0;
        while (pos.* < sequence.len and std.ascii.isDigit(sequence[pos.*])) {
            numerator = numerator * 10 + (sequence[pos.*] - '0');
            pos.* += 1;
        }

        if (pos.* < sequence.len and sequence[pos.*] == '/') {
            pos.* += 1;
            var denominator: i32 = 2;
            if (pos.* < sequence.len and std.ascii.isDigit(sequence[pos.*])) {
                denominator = 0;
                while (pos.* < sequence.len and std.ascii.isDigit(sequence[pos.*])) {
                    denominator = denominator * 10 + (sequence[pos.*] - '0');
                    pos.* += 1;
                }
            }
            duration = types.Fraction.init(numerator, denominator).mul(default_duration);
        } else {
            duration = types.Fraction.init(numerator, 1).mul(default_duration);
        }
    } else if (pos.* < sequence.len and sequence[pos.*] == '/') {
        pos.* += 1;
        var denominator: i32 = 2;
        if (pos.* < sequence.len and std.ascii.isDigit(sequence[pos.*])) {
            denominator = 0;
            while (pos.* < sequence.len and std.ascii.isDigit(sequence[pos.*])) {
                denominator = denominator * 10 + (sequence[pos.*] - '0');
                pos.* += 1;
            }
        }
        duration = types.Fraction.init(default_duration.num, default_duration.denom * denominator);
    }

    // Handle dotted notes
    while (pos.* < sequence.len and sequence[pos.*] == '.') {
        duration = duration.mul(types.Fraction.init(3, 2));
        pos.* += 1;
    }

    return duration;
}

fn calculateMidiNote(pitch: u8, accidental: i8, octave: i8, transpose: i8) u8 {
    const normalized_pitch = std.ascii.toUpper(pitch);
    if (normalized_pitch < 'A' or normalized_pitch > 'G') return 60;

    const semitones = [_]u8{ 9, 11, 0, 2, 4, 5, 7 }; // A B C D E F G
    var semitone: i32 = semitones[normalized_pitch - 'A'];

    semitone += accidental;

    var base_octave: i32 = 4;
    if (std.ascii.isLower(pitch)) {
        base_octave += 1;
    }
    base_octave += octave;

    var midi_note = base_octave * 12 + semitone + transpose;
    if (midi_note < 0) midi_note = 0;
    if (midi_note > 127) midi_note = 127;

    return @intCast(midi_note);
}

fn pitchIndex(pitch: u8) ?usize {
    return switch (std.ascii.toUpper(pitch)) {
        'A' => 0,
        'B' => 1,
        'C' => 2,
        'D' => 3,
        'E' => 4,
        'F' => 5,
        'G' => 6,
        else => null,
    };
}

fn emptyAccidentals() [7]?i8 {
    return [_]?i8{ null, null, null, null, null, null, null };
}

fn inferTupletQ(p: i32, timesig: types.TimeSig) i32 {
    return switch (p) {
        2 => 3,
        3 => 2,
        4 => 3,
        6 => 2,
        8 => 3,
        5, 7, 9 => if (isCompoundMeter(timesig)) 3 else 2,
        else => if (isCompoundMeter(timesig)) 3 else 2,
    };
}

fn isCompoundMeter(timesig: types.TimeSig) bool {
    return timesig.denom == 8 and (timesig.num == 6 or timesig.num == 9 or timesig.num == 12);
}

fn parseKeySig(value: []const u8) types.KeySig {
    const key_name = std.mem.trim(u8, value, " \t");
    const is_minor = (std.mem.indexOf(u8, key_name, "m") != null) and !std.mem.eql(u8, key_name, "M");

    var sharps: i8 = 0;
    if (std.mem.startsWith(u8, key_name, "C#")) {
        sharps = 7;
    } else if (std.mem.startsWith(u8, key_name, "F#")) {
        sharps = 6;
    } else if (std.mem.startsWith(u8, key_name, "B")) {
        sharps = 5;
    } else if (std.mem.startsWith(u8, key_name, "E")) {
        sharps = 4;
    } else if (std.mem.startsWith(u8, key_name, "A")) {
        sharps = 3;
    } else if (std.mem.startsWith(u8, key_name, "D")) {
        sharps = 2;
    } else if (std.mem.startsWith(u8, key_name, "G")) {
        sharps = 1;
    } else if (std.mem.startsWith(u8, key_name, "Cb")) {
        sharps = -7;
    } else if (std.mem.startsWith(u8, key_name, "Gb")) {
        sharps = -6;
    } else if (std.mem.startsWith(u8, key_name, "Db")) {
        sharps = -5;
    } else if (std.mem.startsWith(u8, key_name, "Ab")) {
        sharps = -4;
    } else if (std.mem.startsWith(u8, key_name, "Eb")) {
        sharps = -3;
    } else if (std.mem.startsWith(u8, key_name, "Bb")) {
        sharps = -2;
    } else if (std.mem.startsWith(u8, key_name, "F")) {
        sharps = -1;
    }

    return .{ .sharps = sharps, .is_major = !is_minor };
}

fn keyAccidentalForPitch(key: types.KeySig, pitch: u8) i8 {
    const sharp_order = "FCGDAEB";
    const flat_order = "BEADGCF";

    if (key.sharps > 0) {
        var i: usize = 0;
        while (i < @as(usize, @intCast(key.sharps)) and i < sharp_order.len) : (i += 1) {
            if (sharp_order[i] == pitch) return 1;
        }
        return 0;
    }

    if (key.sharps < 0) {
        const count: usize = @intCast(-key.sharps);
        var i: usize = 0;
        while (i < count and i < flat_order.len) : (i += 1) {
            if (flat_order[i] == pitch) return -1;
        }
    }

    return 0;
}

fn skipTieJoinDelimiters(sequence: []const u8, pos: usize) usize {
    var p = pos;
    while (p < sequence.len) {
        const c = sequence[p];
        if (c == ' ' or c == '\t' or c == '\r' or c == '|' or c == ':') {
            p += 1;
            continue;
        }
        break;
    }
    return p;
}

fn skipGraceGroup(sequence: []const u8, pos: *usize) bool {
    if (pos.* >= sequence.len or sequence[pos.*] != '{') return false;

    pos.* += 1;
    if (pos.* < sequence.len and sequence[pos.*] == '/') {
        pos.* += 1;
    }

    while (pos.* < sequence.len and sequence[pos.*] != '}') {
        pos.* += 1;
    }

    if (pos.* < sequence.len and sequence[pos.*] == '}') {
        pos.* += 1;
        return true;
    }

    pos.* = sequence.len;
    return true;
}

fn parseChordRoot(symbol: []const u8) u8 {
    if (symbol.len == 0) return 60;
    const root = std.ascii.toUpper(symbol[0]);
    var midi_note: u8 = 60;
    switch (root) {
        'C' => midi_note = 60,
        'D' => midi_note = 62,
        'E' => midi_note = 64,
        'F' => midi_note = 65,
        'G' => midi_note = 67,
        'A' => midi_note = 69,
        'B' => midi_note = 71,
        else => midi_note = 60,
    }
    if (symbol.len > 1) {
        if (symbol[1] == '#') midi_note += 1;
        if (symbol[1] == 'b') midi_note -= 1;
    }
    return midi_note - 12;
}

fn parseChordType(symbol: []const u8) []const u8 {
    var type_start: usize = 1;
    if (symbol.len > 1 and (symbol[1] == '#' or symbol[1] == 'b')) {
        type_start = 2;
    }
    if (type_start >= symbol.len) return "major";

    const t = symbol[type_start..];
    if (std.mem.eql(u8, t, "m") or std.mem.eql(u8, t, "min")) return "minor";
    if (std.mem.eql(u8, t, "7")) return "dom7";
    if (std.mem.eql(u8, t, "maj7") or std.mem.eql(u8, t, "M7")) return "maj7";
    if (std.mem.eql(u8, t, "m7")) return "m7";
    if (std.mem.eql(u8, t, "dim") or std.mem.eql(u8, t, "o")) return "dim";
    if (std.mem.eql(u8, t, "aug") or std.mem.eql(u8, t, "+")) return "aug";

    return if (t.len == 0) "major" else t;
}
