const std = @import("std");

pub const Fraction = struct {
    num: i32,
    denom: i32,

    pub fn init(num: i32, denom: i32) Fraction {
        return .{ .num = num, .denom = denom };
    }

    pub fn toDouble(self: Fraction) f64 {
        return @as(f64, @floatFromInt(self.num)) / @as(f64, @floatFromInt(self.denom));
    }

    pub fn mul(self: Fraction, other: Fraction) Fraction {
        return .{
            .num = self.num * other.num,
            .denom = self.denom * other.denom,
        };
    }

    pub fn add(self: Fraction, other: Fraction) Fraction {
        const num = self.num * other.denom + other.num * self.denom;
        const denom = self.denom * other.denom;
        return .{ .num = num, .denom = denom };
    }

    pub fn mulInt(self: Fraction, multiplier: i32) Fraction {
        return .{
            .num = self.num * multiplier,
            .denom = self.denom,
        };
    }

    pub fn divInt(self: Fraction, divisor: i32) Fraction {
        return .{
            .num = self.num,
            .denom = self.denom * divisor,
        };
    }
};

pub const Tempo = struct {
    bpm: i32,
};

pub const TimeSig = struct {
    num: u8,
    denom: u8,
};

pub const KeySig = struct {
    sharps: i8, // positive for sharps, negative for flats
    is_major: bool,
};

pub const VoiceContext = struct {
    id: i32,
    name: []const u8,
    key: KeySig,
    timesig: TimeSig,
    unit_len: Fraction,
    transpose: i8,
    octave_shift: i8,
    instrument: u8,
    channel: i8,
    velocity: u8,
    percussion: bool = false,
};

pub const Note = struct {
    pitch: u8, // 'A'-'G', 'a'-'g'
    accidental: i8, // -1 flat, 0 natural, 1 sharp
    octave: i8,
    duration: Fraction,
    midi_note: u8,
    velocity: u8,
    is_tied: bool = false,
};

pub const Rest = struct {
    duration: Fraction,
};

pub const Chord = struct {
    notes: std.array_list.Managed(Note),
    duration: Fraction,
};

pub const GuitarChord = struct {
    symbol: []const u8,
    root_note: u8,
    chord_type: []const u8,
    duration: Fraction,
};

pub const VoiceChange = struct {
    voice_number: i32,
    voice_name: []const u8,
};

pub const BarLineType = enum {
    bar1,
    double_bar,
    rep_bar,
    bar_rep,
    double_rep,
};

pub const BarLine = struct {
    bar_type: BarLineType,
};

pub const FeatureType = enum {
    note,
    rest,
    chord,
    gchord,
    bar,
    tempo,
    time,
    key,
    voice,
};

pub const FeatureData = union(FeatureType) {
    note: Note,
    rest: Rest,
    chord: Chord,
    gchord: GuitarChord,
    bar: BarLine,
    tempo: Tempo,
    time: TimeSig,
    key: KeySig,
    voice: VoiceChange,
};

pub const Feature = struct {
    ty: FeatureType,
    voice_id: i32,
    ts: f64,
    line_number: usize,
    data: FeatureData,
};

pub const ABCTune = struct {
    allocator: std.mem.Allocator,
    title: []const u8,
    history: []const u8,
    composer: []const u8,
    origin: []const u8,
    rhythm: []const u8,
    notes: []const u8,
    words: []const u8,
    aligned_words: []const u8,
    default_key: KeySig,
    default_timesig: TimeSig,
    default_unit: Fraction,
    default_tempo: Tempo,
    default_instrument: u8,
    default_channel: i8,
    default_percussion: bool,
    voices: std.AutoHashMap(i32, VoiceContext),
    features: std.array_list.Managed(Feature),

    pub fn init(allocator: std.mem.Allocator) ABCTune {
        return .{
            .allocator = allocator,
            .title = "",
            .history = "",
            .composer = "",
            .origin = "",
            .rhythm = "",
            .notes = "",
            .words = "",
            .aligned_words = "",
            .default_key = .{ .sharps = 0, .is_major = true },
            .default_timesig = .{ .num = 4, .denom = 4 },
            .default_instrument = 0,
            .default_channel = -1,
            .default_percussion = false,
            .default_unit = Fraction.init(1, 8),
            .default_tempo = .{ .bpm = 120 },
            .voices = std.AutoHashMap(i32, VoiceContext).init(allocator),
            .features = std.array_list.Managed(Feature).init(allocator),
        };
    }

    pub fn deinit(self: *ABCTune) void {
        if (self.title.len > 0) {
            self.allocator.free(self.title);
        }
        if (self.history.len > 0) {
            self.allocator.free(self.history);
        }
        if (self.composer.len > 0) {
            self.allocator.free(self.composer);
        }
        if (self.origin.len > 0) {
            self.allocator.free(self.origin);
        }
        if (self.rhythm.len > 0) {
            self.allocator.free(self.rhythm);
        }
        if (self.notes.len > 0) {
            self.allocator.free(self.notes);
        }
        if (self.words.len > 0) {
            self.allocator.free(self.words);
        }
        if (self.aligned_words.len > 0) {
            self.allocator.free(self.aligned_words);
        }

        var vit = self.voices.iterator();
        while (vit.next()) |entry| {
            const voice = entry.value_ptr;
            if (voice.name.len > 0) {
                self.allocator.free(voice.name);
            }
        }
        self.voices.deinit();

        for (self.features.items) |*feature| {
            switch (feature.data) {
                .chord => |*c| c.notes.deinit(),
                else => {},
            }
        }
        self.features.deinit();
    }
};
