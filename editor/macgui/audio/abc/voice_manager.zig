const std = @import("std");
const types = @import("types.zig");

pub const ClefType = enum {
    treble,
    bass,
    alto,
    tenor,
};

pub const VoiceManager = struct {
    allocator: std.mem.Allocator,
    current_voice: i32,
    next_voice_id: i32,
    voice_times: std.AutoHashMap(i32, f64),
    voice_name_to_id: std.StringHashMap(i32),

    pub fn init(allocator: std.mem.Allocator) VoiceManager {
        return .{
            .allocator = allocator,
            .current_voice = 1,
            .next_voice_id = 1,
            .voice_times = std.AutoHashMap(i32, f64).init(allocator),
            .voice_name_to_id = std.StringHashMap(i32).init(allocator),
        };
    }

    pub fn deinit(self: *VoiceManager) void {
        self.voice_times.deinit();
        var it = self.voice_name_to_id.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.voice_name_to_id.deinit();
    }

    pub fn reset(self: *VoiceManager) void {
        self.current_voice = 1;
        self.next_voice_id = 1;
        self.voice_times.clearRetainingCapacity();

        var it = self.voice_name_to_id.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.voice_name_to_id.clearRetainingCapacity();
    }

    pub fn saveCurrentTime(self: *VoiceManager, time: f64) !void {
        if (self.current_voice != 0) {
            try self.voice_times.put(self.current_voice, time);
        }
    }

    pub fn restoreVoiceTime(self: *VoiceManager, voice_id: i32) f64 {
        if (self.voice_times.get(voice_id)) |time| {
            return time;
        }
        return 0.0;
    }

    pub fn initializeVoiceFromDefaults(self: *VoiceManager, voice: *types.VoiceContext, tune: *const types.ABCTune) void {
        _ = self;
        voice.key = tune.default_key;
        voice.timesig = tune.default_timesig;
        voice.unit_len = tune.default_unit;
        voice.transpose = 0;
        voice.octave_shift = 0;
        voice.instrument = tune.default_instrument;
        voice.channel = tune.default_channel;
        voice.velocity = 80;
        voice.percussion = tune.default_percussion;
    }

    pub fn findVoiceByIdentifier(self: *VoiceManager, identifier: []const u8, tune: *const types.ABCTune) i32 {
        if (std.fmt.parseInt(i32, identifier, 10)) |voice_id| {
            if (tune.voices.contains(voice_id)) {
                return voice_id;
            }
        } else |_| {}

        var it = tune.voices.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.name, identifier)) {
                return entry.key_ptr.*;
            }
        }

        if (self.voice_name_to_id.get(identifier)) |id| {
            return id;
        }

        return 0;
    }

    pub fn getOrCreateVoice(self: *VoiceManager, identifier: []const u8, tune: *types.ABCTune) !i32 {
        const existing_id = self.findVoiceByIdentifier(identifier, tune);
        if (existing_id != 0) {
            return existing_id;
        }

        const voice_id = self.next_voice_id;
        self.next_voice_id += 1;

        var voice = types.VoiceContext{
            .id = voice_id,
            .name = try self.allocator.dupe(u8, identifier),
            .key = tune.default_key,
            .timesig = tune.default_timesig,
            .unit_len = tune.default_unit,
            .transpose = 0,
            .octave_shift = 0,
            .instrument = tune.default_instrument,
            .channel = -1,
            .velocity = 80,
        };
        self.initializeVoiceFromDefaults(&voice, tune);
        try tune.voices.put(voice_id, voice);

        const id_copy = try self.allocator.dupe(u8, identifier);
        try self.voice_name_to_id.put(id_copy, voice_id);

        return voice_id;
    }

    pub fn switchToVoice(self: *VoiceManager, identifier: []const u8, tune: *types.ABCTune) !i32 {
        var voice_id = self.findVoiceByIdentifier(identifier, tune);
        if (voice_id == 0) {
            voice_id = try self.getOrCreateVoice(identifier, tune);
        }
        self.current_voice = voice_id;
        return voice_id;
    }

    pub fn registerExternalVoice(self: *VoiceManager, voice_id: i32, identifier: []const u8) !void {
        var it = self.voice_name_to_id.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, identifier)) {
                entry.value_ptr.* = voice_id;
                if (voice_id >= self.next_voice_id) {
                    self.next_voice_id = voice_id + 1;
                }
                return;
            }
        }

        const id_copy = try self.allocator.dupe(u8, identifier);
        try self.voice_name_to_id.put(id_copy, voice_id);
        if (voice_id >= self.next_voice_id) {
            self.next_voice_id = voice_id + 1;
        }
    }
};
