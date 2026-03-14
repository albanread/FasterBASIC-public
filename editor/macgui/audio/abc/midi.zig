const std = @import("std");
const types = @import("types.zig");

fn playChordsEnabled() bool {
    return std.c.getenv("ED_PLAY_CHORDS") != null;
}

fn chordIntervals(chord_type: []const u8) []const i8 {
    const major = [_]i8{ 0, 4, 7 };
    const minor = [_]i8{ 0, 3, 7 };
    const dom7 = [_]i8{ 0, 4, 7, 10 };
    const maj7 = [_]i8{ 0, 4, 7, 11 };
    const min7 = [_]i8{ 0, 3, 7, 10 };
    const dim = [_]i8{ 0, 3, 6 };
    const aug = [_]i8{ 0, 4, 8 };

    if (std.mem.eql(u8, chord_type, "minor")) return &minor;
    if (std.mem.eql(u8, chord_type, "dom7")) return &dom7;
    if (std.mem.eql(u8, chord_type, "maj7")) return &maj7;
    if (std.mem.eql(u8, chord_type, "m7")) return &min7;
    if (std.mem.eql(u8, chord_type, "dim")) return &dim;
    if (std.mem.eql(u8, chord_type, "aug")) return &aug;
    return &major;
}

fn durationToBeats(dur: types.Fraction, voice: types.VoiceContext) f64 {
    // Fractions are stored in whole-note units; convert to beats where the beat
    // is the time-signature denominator note (e.g., quarter note in 4/4). A
    // whole note therefore spans `denom` beats.
    return dur.toDouble() * @as(f64, @floatFromInt(voice.timesig.denom));
}

fn timestampToBeats(ts: f64, voice: types.VoiceContext) f64 {
    // Feature timestamps are also stored in whole-note units; scale into beat
    // units so they line up with durationToBeats() results.
    return ts * @as(f64, @floatFromInt(voice.timesig.denom));
}

pub const TrackType = enum {
    notes,
    tempo,
};

pub const MIDIEventType = enum {
    note_on,
    note_off,
    program_change,
    control_change,
    meta_tempo,
    meta_time_signature,
    meta_key_signature,
    meta_text,
    meta_end_of_track,
};

pub const MIDIEvent = struct {
    ty: MIDIEventType,
    timestamp: f64,
    channel: i8,
    data1: u8,
    data2: u8,
    meta_data: std.array_list.Managed(u8),

    pub fn init(allocator: std.mem.Allocator, ty: MIDIEventType, timestamp: f64, channel: i8, data1: u8, data2: u8) MIDIEvent {
        return .{
            .ty = ty,
            .timestamp = timestamp,
            .channel = channel,
            .data1 = data1,
            .data2 = data2,
            .meta_data = std.array_list.Managed(u8).init(allocator),
        };
    }

    pub fn deinit(self: *MIDIEvent) void {
        self.meta_data.deinit();
    }
};

pub const MIDITrack = struct {
    allocator: std.mem.Allocator,
    track_number: i32,
    ty: TrackType,
    voice_number: i32,
    name: []const u8,
    channel: i8,
    events: std.array_list.Managed(MIDIEvent),

    pub fn init(allocator: std.mem.Allocator, track_number: i32, ty: TrackType) MIDITrack {
        return .{
            .allocator = allocator,
            .track_number = track_number,
            .ty = ty,
            .voice_number = 0,
            .name = "",
            .channel = -1,
            .events = std.array_list.Managed(MIDIEvent).init(allocator),
        };
    }

    pub fn deinit(self: *MIDITrack) void {
        for (self.events.items) |*event| {
            event.deinit();
        }
        self.events.deinit();
    }
};

pub const ActiveNote = struct {
    midi_note: u8,
    channel: i8,
    velocity: u8,
    end_time: f64,
};

pub const ChannelManager = struct {
    channels_in_use: [16]bool,
    voice_to_channel: std.AutoHashMap(i32, i8),
    next_available_channel: i8,

    pub fn init(allocator: std.mem.Allocator) ChannelManager {
        return .{
            .channels_in_use = [_]bool{false} ** 16,
            .voice_to_channel = std.AutoHashMap(i32, i8).init(allocator),
            .next_available_channel = 0,
        };
    }

    pub fn deinit(self: *ChannelManager) void {
        self.voice_to_channel.deinit();
    }

    pub fn reset(self: *ChannelManager) void {
        self.channels_in_use = [_]bool{false} ** 16;
        self.voice_to_channel.clearRetainingCapacity();
        self.next_available_channel = 0;
    }

    pub fn assignChannel(self: *ChannelManager, voice_id: i32, track_type: TrackType) i8 {
        _ = track_type;
        if (self.voice_to_channel.get(voice_id)) |channel| {
            return channel;
        }

        while (self.next_available_channel < 16) {
            if (self.next_available_channel != 9 and !self.channels_in_use[@intCast(self.next_available_channel)]) {
                const channel = self.next_available_channel;
                self.channels_in_use[@intCast(channel)] = true;
                self.voice_to_channel.put(voice_id, channel) catch unreachable;
                self.next_available_channel += 1;
                return channel;
            }
            self.next_available_channel += 1;
        }

        return 0; // Fallback
    }

    /// Assign a specific channel to a voice (used for explicit %%MIDI channel
    /// directives and percussion voices that must be on channel 9).
    pub fn assignExplicitChannel(self: *ChannelManager, voice_id: i32, channel: i8) void {
        const ch: usize = @intCast(channel);
        self.channels_in_use[ch] = true;
        self.voice_to_channel.put(voice_id, channel) catch unreachable;
    }
};

pub const MIDIGenerator = struct {
    allocator: std.mem.Allocator,
    ticks_per_quarter: i32,
    default_tempo: i32,
    default_velocity: u8,
    current_time: f64,
    current_tempo: i32,
    channel_manager: ChannelManager,
    active_notes: std.array_list.Managed(ActiveNote),
    errors: std.array_list.Managed([]const u8),

    pub fn init(allocator: std.mem.Allocator) MIDIGenerator {
        return .{
            .allocator = allocator,
            .ticks_per_quarter = 480,
            .default_tempo = 120,
            .default_velocity = 80,
            .current_time = 0.0,
            .current_tempo = 120,
            .channel_manager = ChannelManager.init(allocator),
            .active_notes = std.array_list.Managed(ActiveNote).init(allocator),
            .errors = std.array_list.Managed([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *MIDIGenerator) void {
        self.channel_manager.deinit();
        self.active_notes.deinit();
        for (self.errors.items) |err| {
            self.allocator.free(err);
        }
        self.errors.deinit();
    }

    pub fn generateMIDI(self: *MIDIGenerator, tune: *const types.ABCTune, tracks: *std.array_list.Managed(MIDITrack)) !bool {
        self.channel_manager.reset();
        self.current_time = 0.0;
        self.current_tempo = tune.default_tempo.bpm;
        self.active_notes.clearRetainingCapacity();

        try self.createTracks(tune, tracks);
        try self.assignChannels(tune, tracks);

        for (tracks.items) |*track| {
            try self.generateTrackEvents(tune, track);
        }

        if (tracks.items.len > 0) {
            try self.processTempoTrack(tune, &tracks.items[0]);
        }

        return true;
    }

    fn createTracks(self: *MIDIGenerator, tune: *const types.ABCTune, tracks: *std.array_list.Managed(MIDITrack)) !void {
        var tempo_track = MIDITrack.init(self.allocator, 0, .tempo);
        tempo_track.name = "Tempo Track";
        tempo_track.channel = -1;
        try tracks.append(tempo_track);

        var track_num: i32 = 1;
        var it = tune.voices.iterator();
        while (it.next()) |entry| {
            const voice = entry.value_ptr;
            var voice_track = MIDITrack.init(self.allocator, track_num, .notes);
            track_num += 1;
            voice_track.voice_number = voice.id;
            voice_track.name = if (voice.name.len > 0) voice.name else "Voice";
            try tracks.append(voice_track);
        }
    }

    fn assignChannels(self: *MIDIGenerator, tune: *const types.ABCTune, tracks: *std.array_list.Managed(MIDITrack)) !void {
        // First pass: assign explicit channels (%%MIDI channel / percussion)
        for (tracks.items) |*track| {
            if (track.track_number == 0) continue;
            if (tune.voices.get(track.voice_number)) |voice| {
                if (voice.channel >= 0) {
                    track.channel = voice.channel;
                    self.channel_manager.assignExplicitChannel(track.voice_number, voice.channel);
                }
            }
        }

        // Second pass: auto-assign remaining voices
        for (tracks.items) |*track| {
            if (track.track_number == 0) continue;
            if (track.channel < 0) {
                track.channel = self.channel_manager.assignChannel(track.voice_number, track.ty);
            }
        }

        // Third pass: emit program changes
        for (tracks.items) |*track| {
            if (track.track_number == 0) continue;
            if (tune.voices.get(track.voice_number)) |voice| {
                // Percussion voices on channel 9: program change selects
                // the drum kit (0 = Standard, etc.) which the DLS synth
                // honours, so we emit it for all voices.
                try self.addProgramChange(voice.instrument, track.channel, 0.0, track);
            }
        }
    }

    fn generateTrackEvents(self: *MIDIGenerator, tune: *const types.ABCTune, track: *MIDITrack) !void {
        if (track.track_number == 0) return;

        self.current_time = 0.0;
        var max_end_time: f64 = 0.0;

        for (tune.features.items) |feature| {
            if (feature.voice_id != track.voice_number) continue;

            try self.processFeature(tune, feature, track, &max_end_time);
        }

        try self.flushActiveNotes(track);

        // Fix EOT: use max_end_time instead of current_time
        try self.addEndOfTrack(@max(self.current_time, max_end_time), track);
    }

    fn processTempoTrack(self: *MIDIGenerator, tune: *const types.ABCTune, track: *MIDITrack) !void {
        try self.addTempo(tune.default_tempo.bpm, 0.0, track);
        try self.addTimeSignature(tune.default_timesig.num, tune.default_timesig.denom, 0.0, track);
        try self.addKeySignature(tune.default_key.sharps, tune.default_key.is_major, 0.0, track);

        if (tune.title.len > 0) {
            try self.addText(tune.title, 0.0, track);
        }

        var max_end_time: f64 = 0.0;
        for (tune.features.items) |feature| {
            const voice = tune.voices.get(feature.voice_id);
            const ts_beats = if (voice) |v|
                timestampToBeats(feature.ts, v)
            else
                feature.ts * @as(f64, @floatFromInt(tune.default_timesig.denom));

            switch (feature.data) {
                .tempo => |t| try self.addTempo(t.bpm, ts_beats, track),
                .time => |t| try self.addTimeSignature(t.num, t.denom, ts_beats, track),
                .key => |k| try self.addKeySignature(k.sharps, k.is_major, ts_beats, track),
                else => {},
            }

            const feature_end = switch (feature.data) {
                .note => |n| ts_beats + durationToBeats(n.duration, tune.voices.get(feature.voice_id).?),
                .rest => |r| ts_beats + durationToBeats(r.duration, tune.voices.get(feature.voice_id).?),
                .chord => |c| ts_beats + durationToBeats(c.duration, tune.voices.get(feature.voice_id).?),
                .gchord => |g| ts_beats + durationToBeats(g.duration, tune.voices.get(feature.voice_id).?),
                else => ts_beats,
            };
            max_end_time = @max(max_end_time, feature_end);
        }

        try self.addEndOfTrack(max_end_time, track);
    }

    fn processFeature(self: *MIDIGenerator, tune: *const types.ABCTune, feature: types.Feature, track: *MIDITrack, max_end_time: *f64) !void {
        const voice = tune.voices.get(track.voice_number) orelse return;
        const timestamp = timestampToBeats(feature.ts, voice);

        switch (feature.data) {
            .note => |note| {
                try self.processActiveNotes(timestamp, track);
                try self.scheduleNoteOn(note.midi_note, note.velocity, track.channel, timestamp, track);
                const note_off_time = timestamp + durationToBeats(note.duration, voice);
                try self.scheduleNoteOff(note.midi_note, track.channel, note_off_time);
                max_end_time.* = @max(max_end_time.*, note_off_time);
            },
            .rest => |rest| {
                const rest_end = timestamp + durationToBeats(rest.duration, voice);
                try self.processActiveNotes(rest_end, track);
                max_end_time.* = @max(max_end_time.*, rest_end);
            },
            .chord => |chord| {
                try self.processActiveNotes(timestamp, track);
                for (chord.notes.items) |note| {
                    try self.scheduleNoteOn(note.midi_note, note.velocity, track.channel, timestamp, track);
                    const note_off_time = timestamp + durationToBeats(chord.duration, voice);
                    try self.scheduleNoteOff(note.midi_note, track.channel, note_off_time);
                    max_end_time.* = @max(max_end_time.*, note_off_time);
                }
            },
            .gchord => |gchord| {
                const note_off_time = timestamp + durationToBeats(gchord.duration, voice);
                if (!playChordsEnabled()) {
                    max_end_time.* = @max(max_end_time.*, note_off_time);
                    return;
                }

                try self.processActiveNotes(timestamp, track);
                const intervals = chordIntervals(gchord.chord_type);

                for (intervals) |interval| {
                    const midi_val: i32 = @as(i32, gchord.root_note) + @as(i32, interval) + @as(i32, voice.transpose);
                    const midi_note: u8 = @intCast(std.math.clamp(midi_val, 0, 127));
                    try self.scheduleNoteOn(midi_note, voice.velocity, track.channel, timestamp, track);
                    try self.scheduleNoteOff(midi_note, track.channel, note_off_time);
                }

                max_end_time.* = @max(max_end_time.*, note_off_time);
            },
            else => {},
        }

        self.current_time = @max(self.current_time, timestamp);
    }

    fn scheduleNoteOn(self: *MIDIGenerator, midi_note: u8, velocity: u8, channel: i8, timestamp: f64, track: *MIDITrack) !void {
        try self.addNoteOn(midi_note, velocity, channel, timestamp, track);
    }

    fn scheduleNoteOff(self: *MIDIGenerator, midi_note: u8, channel: i8, timestamp: f64) !void {
        try self.active_notes.append(.{
            .midi_note = midi_note,
            .channel = channel,
            .velocity = 0,
            .end_time = timestamp,
        });
    }

    fn processActiveNotes(self: *MIDIGenerator, current_time: f64, track: *MIDITrack) !void {
        var i: usize = 0;
        while (i < self.active_notes.items.len) {
            const active = self.active_notes.items[i];
            if (active.end_time <= current_time) {
                try self.addNoteOff(active.midi_note, active.channel, active.end_time, track);
                _ = self.active_notes.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    fn flushActiveNotes(self: *MIDIGenerator, track: *MIDITrack) !void {
        for (self.active_notes.items) |active| {
            try self.addNoteOff(active.midi_note, active.channel, active.end_time, track);
        }
        self.active_notes.clearRetainingCapacity();
    }

    fn addNoteOn(self: *MIDIGenerator, midi_note: u8, velocity: u8, channel: i8, timestamp: f64, track: *MIDITrack) !void {
        try track.events.append(MIDIEvent.init(self.allocator, .note_on, timestamp, channel, midi_note, velocity));
    }

    fn addNoteOff(self: *MIDIGenerator, midi_note: u8, channel: i8, timestamp: f64, track: *MIDITrack) !void {
        try track.events.append(MIDIEvent.init(self.allocator, .note_off, timestamp, channel, midi_note, 0));
    }

    fn addProgramChange(self: *MIDIGenerator, program: u8, channel: i8, timestamp: f64, track: *MIDITrack) !void {
        try track.events.append(MIDIEvent.init(self.allocator, .program_change, timestamp, channel, program, 0));
    }

    fn addTempo(self: *MIDIGenerator, bpm: i32, timestamp: f64, track: *MIDITrack) !void {
        var event = MIDIEvent.init(self.allocator, .meta_tempo, timestamp, 0, 0, 0);
        const mpq: u32 = @intCast(@divTrunc(60000000, bpm));
        try event.meta_data.append(@intCast((mpq >> 16) & 0xFF));
        try event.meta_data.append(@intCast((mpq >> 8) & 0xFF));
        try event.meta_data.append(@intCast(mpq & 0xFF));
        try track.events.append(event);
    }

    fn addTimeSignature(self: *MIDIGenerator, num: u8, denom: u8, timestamp: f64, track: *MIDITrack) !void {
        var event = MIDIEvent.init(self.allocator, .meta_time_signature, timestamp, 0, 0, 0);
        var denom_power: u8 = 0;
        var temp_denom = denom;
        while (temp_denom > 1) {
            temp_denom /= 2;
            denom_power += 1;
        }
        try event.meta_data.append(num);
        try event.meta_data.append(denom_power);
        try event.meta_data.append(24);
        try event.meta_data.append(8);
        try track.events.append(event);
    }

    fn addKeySignature(self: *MIDIGenerator, sharps: i8, is_major: bool, timestamp: f64, track: *MIDITrack) !void {
        var event = MIDIEvent.init(self.allocator, .meta_key_signature, timestamp, 0, 0, 0);
        try event.meta_data.append(@bitCast(sharps));
        try event.meta_data.append(if (is_major) 0 else 1);
        try track.events.append(event);
    }

    fn addText(self: *MIDIGenerator, text: []const u8, timestamp: f64, track: *MIDITrack) !void {
        var event = MIDIEvent.init(self.allocator, .meta_text, timestamp, 0, 0, 0);
        try event.meta_data.appendSlice(text);
        try track.events.append(event);
    }

    fn addEndOfTrack(self: *MIDIGenerator, timestamp: f64, track: *MIDITrack) !void {
        try track.events.append(MIDIEvent.init(self.allocator, .meta_end_of_track, timestamp, 0, 0, 0));
    }
};
