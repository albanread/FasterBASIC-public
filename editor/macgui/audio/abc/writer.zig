const std = @import("std");
const midi = @import("midi.zig");

pub const MIDIWriter = struct {
    allocator: std.mem.Allocator,
    ticks_per_quarter: i32,

    pub fn init(allocator: std.mem.Allocator, ticks_per_quarter: i32) MIDIWriter {
        return .{
            .allocator = allocator,
            .ticks_per_quarter = ticks_per_quarter,
        };
    }

    pub fn write(self: *MIDIWriter, tracks: *std.array_list.Managed(midi.MIDITrack), writer: anytype) !void {
        try self.writeHeader(tracks.items.len, writer);

        for (tracks.items) |*track| {
            try self.writeTrack(track, writer);
        }
    }

    fn writeHeader(self: *MIDIWriter, num_tracks: usize, writer: anytype) !void {
        try writer.writeAll("MThd");
        try writer.writeInt(u32, 6, .big);
        try writer.writeInt(u16, 1, .big); // Format 1 (multi-track)
        try writer.writeInt(u16, @intCast(num_tracks), .big);
        try writer.writeInt(u16, @intCast(self.ticks_per_quarter), .big);
    }

    fn writeTrack(self: *MIDIWriter, track: *midi.MIDITrack, writer: anytype) !void {
        var track_data = std.array_list.Managed(u8).init(self.allocator);
        defer track_data.deinit();

        var track_writer = track_data.writer();
        var last_time: f64 = 0.0;

        // Sort events by timestamp
        std.mem.sort(midi.MIDIEvent, track.events.items, {}, struct {
            fn lessThan(_: void, a: midi.MIDIEvent, b: midi.MIDIEvent) bool {
                return a.timestamp < b.timestamp;
            }
        }.lessThan);

        for (track.events.items) |event| {
            const delta_time = @max(0, @as(i32, @intFromFloat((event.timestamp - last_time) * @as(f64, @floatFromInt(self.ticks_per_quarter)))));
            try writeVarLen(track_writer, @intCast(delta_time));

            switch (event.ty) {
                .note_on => {
                    try track_writer.writeByte(0x90 | @as(u8, @intCast(event.channel)));
                    try track_writer.writeByte(event.data1);
                    try track_writer.writeByte(event.data2);
                },
                .note_off => {
                    try track_writer.writeByte(0x80 | @as(u8, @intCast(event.channel)));
                    try track_writer.writeByte(event.data1);
                    try track_writer.writeByte(event.data2);
                },
                .program_change => {
                    try track_writer.writeByte(0xC0 | @as(u8, @intCast(event.channel)));
                    try track_writer.writeByte(event.data1);
                },
                .control_change => {
                    try track_writer.writeByte(0xB0 | @as(u8, @intCast(event.channel)));
                    try track_writer.writeByte(event.data1);
                    try track_writer.writeByte(event.data2);
                },
                .meta_tempo => {
                    try track_writer.writeByte(0xFF);
                    try track_writer.writeByte(0x51);
                    try writeVarLen(track_writer, @intCast(event.meta_data.items.len));
                    try track_writer.writeAll(event.meta_data.items);
                },
                .meta_time_signature => {
                    try track_writer.writeByte(0xFF);
                    try track_writer.writeByte(0x58);
                    try writeVarLen(track_writer, @intCast(event.meta_data.items.len));
                    try track_writer.writeAll(event.meta_data.items);
                },
                .meta_key_signature => {
                    try track_writer.writeByte(0xFF);
                    try track_writer.writeByte(0x59);
                    try writeVarLen(track_writer, @intCast(event.meta_data.items.len));
                    try track_writer.writeAll(event.meta_data.items);
                },
                .meta_text => {
                    try track_writer.writeByte(0xFF);
                    try track_writer.writeByte(0x01);
                    try writeVarLen(track_writer, @intCast(event.meta_data.items.len));
                    try track_writer.writeAll(event.meta_data.items);
                },
                .meta_end_of_track => {
                    try track_writer.writeByte(0xFF);
                    try track_writer.writeByte(0x2F);
                    try track_writer.writeByte(0x00);
                },
            }

            last_time = event.timestamp;
        }

        try writer.writeAll("MTrk");
        try writer.writeInt(u32, @intCast(track_data.items.len), .big);
        try writer.writeAll(track_data.items);
    }

    fn writeVarLen(writer: anytype, value: u32) !void {
        var buffer: [4]u8 = undefined;
        var i: usize = 0;
        var v = value;

        buffer[i] = @intCast(v & 0x7F);
        v >>= 7;
        while (v > 0) {
            i += 1;
            buffer[i] = @intCast((v & 0x7F) | 0x80);
            v >>= 7;
        }

        while (true) {
            try writer.writeByte(buffer[i]);
            if (i == 0) break;
            i -= 1;
        }
    }
};
