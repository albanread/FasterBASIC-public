const std = @import("std");
const types = @import("types.zig");
const VoiceManager = @import("voice_manager.zig").VoiceManager;
const MusicParser = @import("music_parser.zig").MusicParser;
const repeat = @import("repeat.zig");

pub const ParseState = enum {
    header,
    body,
    complete,
};

pub const ABCParser = struct {
    allocator: std.mem.Allocator,
    state: ParseState,
    current_line: usize,
    voice_manager: VoiceManager,
    music_parser: MusicParser,
    errors: std.array_list.Managed([]const u8),
    warnings: std.array_list.Managed([]const u8),

    pub fn init(allocator: std.mem.Allocator) ABCParser {
        return .{
            .allocator = allocator,
            .state = .header,
            .current_line = 0,
            .voice_manager = VoiceManager.init(allocator),
            .music_parser = MusicParser.init(allocator),
            .errors = std.array_list.Managed([]const u8).init(allocator),
            .warnings = std.array_list.Managed([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *ABCParser) void {
        self.voice_manager.deinit();
        self.music_parser.deinit();
        for (self.errors.items) |err| {
            self.allocator.free(err);
        }
        self.errors.deinit();
        for (self.warnings.items) |warn| {
            self.allocator.free(warn);
        }
        self.warnings.deinit();
    }

    pub fn reset(self: *ABCParser) void {
        self.state = .header;
        self.current_line = 0;
        self.voice_manager.reset();
        self.music_parser.reset();

        for (self.errors.items) |err| {
            self.allocator.free(err);
        }
        self.errors.clearRetainingCapacity();

        for (self.warnings.items) |warn| {
            self.allocator.free(warn);
        }
        self.warnings.clearRetainingCapacity();
    }

    pub fn parseABC(self: *ABCParser, abc_content: []const u8, tune: *types.ABCTune) !bool {
        self.reset();
        var last_field: ?u8 = null;

        // Expand repeats
        const expanded_content = try repeat.expandABCRepeats(self.allocator, abc_content);
        defer self.allocator.free(expanded_content);

        var lines = std.mem.splitScalar(u8, expanded_content, '\n');
        while (lines.next()) |line| {
            self.current_line += 1;

            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;

            // ── %%MIDI directives ──────────────────────────────────
            if (trimmed.len >= 7 and std.mem.startsWith(u8, trimmed, "%%MIDI")) {
                try self.parseMidiDirective(trimmed[6..], tune);
                continue;
            }

            // Skip plain comments (single %)
            if (trimmed[0] == '%') {
                continue;
            }

            // Strip comments
            var clean_line = trimmed;
            if (std.mem.indexOf(u8, trimmed, "%")) |comment_pos| {
                clean_line = std.mem.trim(u8, trimmed[0..comment_pos], " \t");
            }

            if (clean_line.len == 0) continue;

            if (clean_line.len >= 2 and clean_line[0] == '+' and clean_line[1] == ':') {
                if (last_field) |field| {
                    if (isStringField(field)) {
                        const continuation_value = std.mem.trim(u8, clean_line[2..], " \t");
                        var continued = std.array_list.Managed(u8).init(self.allocator);
                        defer continued.deinit();
                        try continued.append(field);
                        try continued.append(':');
                        try continued.appendSlice(continuation_value);
                        const continued_line = try continued.toOwnedSlice();
                        defer self.allocator.free(continued_line);
                        try self.parseLine(continued_line, tune);
                    } else {
                        try self.addWarning("Ignoring +: continuation for non-string field");
                    }
                } else {
                    try self.addWarning("Ignoring +: continuation with no previous field");
                }
                continue;
            }

            if (isHeaderField(clean_line)) {
                last_field = clean_line[0];
            }

            try self.parseLine(clean_line, tune);
        }

        if (self.errors.items.len == 0) {
            if (tune.voices.count() == 0) {
                const default_voice = types.VoiceContext{
                    .id = 1,
                    .name = try self.allocator.dupe(u8, "1"),
                    .key = tune.default_key,
                    .timesig = tune.default_timesig,
                    .unit_len = tune.default_unit,
                    .transpose = 0,
                    .octave_shift = 0,
                    .instrument = tune.default_instrument,
                    .channel = tune.default_channel,
                    .velocity = 80,
                    .percussion = tune.default_percussion,
                };
                try tune.voices.put(1, default_voice);
            }
            self.state = .complete;
        }

        return self.errors.items.len == 0;
    }

    pub fn parse(self: *ABCParser, abc_content: []const u8) !types.ABCTune {
        var tune = types.ABCTune.init(self.allocator);
        errdefer tune.deinit();

        const ok = try self.parseABC(abc_content, &tune);
        if (!ok) return error.ParseFailed;
        return tune;
    }

    fn parseLine(self: *ABCParser, line: []const u8, tune: *types.ABCTune) !void {
        // Check for standalone [V:...]
        if (line.len >= 4 and line[0] == '[' and line[1] == 'V' and line[2] == ':') {
            if (std.mem.indexOf(u8, line, "]")) |end_bracket| {
                var has_content_after = false;
                for (line[end_bracket + 1 ..]) |c| {
                    if (!std.ascii.isWhitespace(c)) {
                        has_content_after = true;
                        break;
                    }
                }

                if (!has_content_after) {
                    const voice_id_str = std.mem.trim(u8, line[3..end_bracket], " \t");
                    if (voice_id_str.len > 0) {
                        try self.voice_manager.saveCurrentTime(self.music_parser.current_time);
                        const new_voice = try self.voice_manager.switchToVoice(voice_id_str, tune);
                        self.music_parser.current_time = self.voice_manager.restoreVoiceTime(new_voice);
                    }
                    return;
                }
            }
        }

        // Check for V: field
        if (line.len >= 2 and line[0] == 'V' and line[1] == ':') {
            const voice_spec = std.mem.trim(u8, line[2..], " \t");
            var it = std.mem.splitScalar(u8, voice_spec, ' ');
            if (it.next()) |voice_id_str| {
                if (voice_id_str.len > 0) {
                    const has_attributes = std.mem.indexOf(u8, voice_spec, "=") != null;
                    if (has_attributes) {
                        // Voice definition
                        try self.parseHeaderLine(line, tune);
                        const found_voice_id = self.voice_manager.findVoiceByIdentifier(voice_id_str, tune);
                        if (found_voice_id != 0) {
                            try self.voice_manager.registerExternalVoice(found_voice_id, voice_id_str);
                            self.voice_manager.current_voice = found_voice_id;
                        }
                    } else {
                        // Voice switch
                        try self.voice_manager.saveCurrentTime(self.music_parser.current_time);
                        const new_voice = try self.voice_manager.switchToVoice(voice_id_str, tune);
                        self.music_parser.current_time = self.voice_manager.restoreVoiceTime(new_voice);
                    }
                }
            }
            return;
        }

        if (self.state == .header and isHeaderField(line)) {
            try self.parseHeaderLine(line, tune);
            if (line[0] == 'K') {
                self.state = .body;
            }
            return;
        }

        if (self.state == .header) {
            self.state = .body;
        }

        if (self.state == .body) {
            if (tune.voices.count() == 0) {
                _ = try self.voice_manager.switchToVoice("1", tune);
            }
            self.music_parser.current_line = self.current_line;
            try self.music_parser.parseMusicLine(line, tune, &self.voice_manager);
        }
    }

    fn isHeaderField(line: []const u8) bool {
        return line.len >= 2 and std.ascii.isAlphabetic(line[0]) and line[1] == ':';
    }

    fn isStringField(field: u8) bool {
        return switch (field) {
            'A', 'B', 'C', 'D', 'F', 'G', 'H', 'N', 'O', 'R', 'S', 'T', 'W', 'Z', 'w' => true,
            else => false,
        };
    }

    fn addWarning(self: *ABCParser, msg: []const u8) !void {
        try self.warnings.append(try self.allocator.dupe(u8, msg));
    }

    fn parseHeaderLine(self: *ABCParser, line: []const u8, tune: *types.ABCTune) !void {
        const field = line[0];
        const value = std.mem.trim(u8, line[2..], " \t");

        switch (field) {
            'T' => {
                try self.appendStringField(&tune.title, value);
            },
            'H' => {
                try self.appendStringField(&tune.history, value);
            },
            'C' => {
                try self.appendStringField(&tune.composer, value);
            },
            'O' => {
                try self.appendStringField(&tune.origin, value);
            },
            'R' => {
                try self.appendStringField(&tune.rhythm, value);
            },
            'N' => {
                try self.appendStringField(&tune.notes, value);
            },
            'W' => {
                try self.appendStringField(&tune.words, value);
            },
            'w' => {
                try self.appendStringField(&tune.aligned_words, value);
            },
            'M' => {
                // Parse meter
                if (std.mem.eql(u8, value, "C") or std.mem.eql(u8, value, "c")) {
                    tune.default_timesig = .{ .num = 4, .denom = 4 };
                } else if (std.mem.eql(u8, value, "C|") or std.mem.eql(u8, value, "c|")) {
                    tune.default_timesig = .{ .num = 2, .denom = 2 };
                } else if (std.mem.indexOf(u8, value, "/")) |slash_pos| {
                    const num_str = value[0..slash_pos];
                    const denom_str = value[slash_pos + 1 ..];
                    if (std.fmt.parseInt(u8, num_str, 10)) |num| {
                        if (std.fmt.parseInt(u8, denom_str, 10)) |denom| {
                            tune.default_timesig = .{ .num = num, .denom = denom };
                        } else |_| {}
                    } else |_| {}
                }
            },
            'L' => {
                // Parse default length
                if (std.mem.indexOf(u8, value, "/")) |slash_pos| {
                    const num_str = value[0..slash_pos];
                    const denom_str = value[slash_pos + 1 ..];
                    if (std.fmt.parseInt(i32, num_str, 10)) |num| {
                        if (std.fmt.parseInt(i32, denom_str, 10)) |denom| {
                            tune.default_unit = types.Fraction.init(num, denom);
                        } else |_| {}
                    } else |_| {}
                }
            },
            'Q' => {
                // Parse tempo
                var tempo_str = value;
                if (std.mem.indexOf(u8, value, "=")) |eq_pos| {
                    tempo_str = value[eq_pos + 1 ..];
                }
                tempo_str = std.mem.trim(u8, tempo_str, " \t");
                if (std.fmt.parseInt(i32, tempo_str, 10)) |bpm| {
                    tune.default_tempo = .{ .bpm = bpm };
                } else |_| {}
            },
            'K' => {
                // Parse key signature
                tune.default_key = parseKeySig(value);
            },
            'V' => {
                // Voice definition
                var it = std.mem.splitScalar(u8, value, ' ');
                if (it.next()) |voice_id_str| {
                    const voice_id = try self.voice_manager.getOrCreateVoice(voice_id_str, tune);
                    if (tune.voices.getPtr(voice_id)) |voice| {
                        const attr_offset = @min(voice_id_str.len, value.len);
                        const attrs = std.mem.trimLeft(u8, value[attr_offset..], " \t");
                        try self.applyVoiceAttributes(attrs, voice);
                    }
                }
            },
            else => {},
        }
    }

    fn appendStringField(self: *ABCParser, field: *[]const u8, value: []const u8) !void {
        if (value.len == 0) return;
        if (field.*.len == 0) {
            field.* = try self.allocator.dupe(u8, value);
            return;
        }
        const combined = try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ field.*, value });
        self.allocator.free(field.*);
        field.* = combined;
    }

    fn applyVoiceAttributes(self: *ABCParser, attrs: []const u8, voice: *types.VoiceContext) !void {
        var pos: usize = 0;
        while (pos < attrs.len) {
            while (pos < attrs.len and std.ascii.isWhitespace(attrs[pos])) : (pos += 1) {}
            if (pos >= attrs.len) break;

            const key_start = pos;
            while (pos < attrs.len and attrs[pos] != '=' and !std.ascii.isWhitespace(attrs[pos])) : (pos += 1) {}
            if (pos >= attrs.len or attrs[pos] != '=') {
                while (pos < attrs.len and !std.ascii.isWhitespace(attrs[pos])) : (pos += 1) {}
                continue;
            }

            const key = attrs[key_start..pos];
            pos += 1;

            var val_start = pos;
            var val_end = pos;
            var quoted = false;

            if (pos < attrs.len and attrs[pos] == '"') {
                quoted = true;
                pos += 1;
                val_start = pos;
                while (pos < attrs.len and attrs[pos] != '"') : (pos += 1) {}
                val_end = pos;
                if (pos < attrs.len and attrs[pos] == '"') pos += 1;
            } else {
                while (pos < attrs.len and !std.ascii.isWhitespace(attrs[pos])) : (pos += 1) {}
                val_end = pos;
            }

            const raw_val = attrs[val_start..val_end];
            const val = if (quoted) raw_val else std.mem.trim(u8, raw_val, " \t");

            if (std.ascii.eqlIgnoreCase(key, "name")) {
                if (voice.name.len > 0) {
                    self.allocator.free(voice.name);
                }
                voice.name = try self.allocator.dupe(u8, val);
            } else if (std.ascii.eqlIgnoreCase(key, "instrument") or
                std.ascii.eqlIgnoreCase(key, "program") or
                std.ascii.eqlIgnoreCase(key, "prog"))
            {
                if (std.fmt.parseInt(i32, val, 10)) |program| {
                    if (program >= 0 and program <= 127) {
                        voice.instrument = @intCast(program);
                    }
                } else |_| {}
            }
        }
    }

    // ── %%MIDI directive handler ────────────────────────────────
    fn parseMidiDirective(self: *ABCParser, rest: []const u8, tune: *types.ABCTune) !void {
        const args = std.mem.trim(u8, rest, " \t");
        if (args.len == 0) return;

        // Tokenise: first word is the sub-command, remainder is the value
        var it = std.mem.tokenizeAny(u8, args, " \t");
        const subcmd = it.next() orelse return;
        const val_str = std.mem.trim(u8, it.rest(), " \t");

        // Resolve the voice we should modify.  If we're already in
        // the body and voices exist, use the current voice; otherwise
        // apply to the default voice (created lazily) or stash as a
        // "pending" default that will be picked up when the first
        // voice is created.
        var voice_ptr: ?*types.VoiceContext = null;
        if (tune.voices.count() > 0) {
            voice_ptr = tune.voices.getPtr(self.voice_manager.current_voice);
        }

        if (std.ascii.eqlIgnoreCase(subcmd, "program")) {
            // %%MIDI program <0-127>
            if (std.fmt.parseInt(i32, val_str, 10)) |program| {
                if (program >= 0 and program <= 127) {
                    if (voice_ptr) |v| {
                        v.instrument = @intCast(program);
                    } else {
                        // No voice yet — will be picked up via default_instrument
                        tune.default_instrument = @intCast(program);
                    }
                }
            } else |_| {}
        } else if (std.ascii.eqlIgnoreCase(subcmd, "channel")) {
            // %%MIDI channel <1-16>  (ABC convention: 1-based)
            if (std.fmt.parseInt(i32, val_str, 10)) |ch| {
                if (ch >= 1 and ch <= 16) {
                    if (voice_ptr) |v| {
                        v.channel = @intCast(ch - 1); // store 0-based
                    } else {
                        // No voice yet — remember as default for later-created voices
                        tune.default_channel = @intCast(ch - 1);
                    }
                }
            } else |_| {}
        } else if (std.ascii.eqlIgnoreCase(subcmd, "transpose")) {
            // %%MIDI transpose <-127..127>
            if (std.fmt.parseInt(i8, val_str, 10)) |t| {
                if (voice_ptr) |v| {
                    v.transpose = t;
                }
            } else |_| {}
        } else if (std.ascii.eqlIgnoreCase(subcmd, "velocity") or
            std.ascii.eqlIgnoreCase(subcmd, "volume"))
        {
            // %%MIDI velocity <0-127>  /  %%MIDI volume <0-127>
            if (std.fmt.parseInt(i32, val_str, 10)) |vel| {
                if (vel >= 0 and vel <= 127) {
                    if (voice_ptr) |v| {
                        v.velocity = @intCast(vel);
                    }
                }
            } else |_| {}
        } else if (std.ascii.eqlIgnoreCase(subcmd, "drum") or
            std.ascii.eqlIgnoreCase(subcmd, "percussion"))
        {
            // %%MIDI drum on / %%MIDI percussion
            // Force the current voice to MIDI channel 10 (index 9)
            const on = val_str.len == 0 or
                std.ascii.eqlIgnoreCase(val_str, "on") or
                std.ascii.eqlIgnoreCase(val_str, "1");
            if (voice_ptr) |v| {
                v.percussion = on;
                if (on) v.channel = 9; // 0-based channel 10
            } else {
                // No voice yet — store defaults for when a voice is created
                tune.default_percussion = on;
                if (on) tune.default_channel = 9;
            }
        } else {
            // Unknown %%MIDI sub-command — silently ignore
        }
    }
};

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
