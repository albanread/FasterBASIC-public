const std = @import("std");

fn expandLineRepeats(allocator: std.mem.Allocator, line: []const u8) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();

    var pos: usize = 0;
    while (pos < line.len) {
        const start_idx = std.mem.indexOfPos(u8, line, pos, "|:");
        if (start_idx) |start| {
            const end_idx = std.mem.indexOfPos(u8, line, start + 2, ":|");
            if (end_idx) |end| {
                // Append everything before the repeat
                try result.appendSlice(line[pos..start]);

                // Extract the content to repeat
                const content = line[start + 2 .. end];
                const trimmed = std.mem.trim(u8, content, " \t");

                // Append the repeated content twice
                try result.appendSlice(trimmed);
                try result.appendSlice(" ");
                try result.appendSlice(trimmed);

                pos = end + 2;
                continue;
            }
        }

        // No more repeats found, append the rest
        try result.appendSlice(line[pos..]);
        break;
    }

    return result.toOwnedSlice();
}

fn expandVoiceSectionRepeats(allocator: std.mem.Allocator, section: []const u8) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    defer output.deinit();

    var repeat_buffer = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (repeat_buffer.items) |item| {
            allocator.free(item);
        }
        repeat_buffer.deinit();
    }

    var in_repeat = false;
    var lines = std.mem.splitScalar(u8, section, '\n');

    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "|:")) |start_pos| {
            in_repeat = true;
            if (std.mem.indexOf(u8, line, ":|")) |_| {
                // Single-line repeat
                const expanded = try expandLineRepeats(allocator, line);
                defer allocator.free(expanded);
                try output.appendSlice(expanded);
                try output.append('\n');
                in_repeat = false;
                continue;
            } else {
                // Multi-line repeat starts
                var cleaned = std.array_list.Managed(u8).init(allocator);
                try cleaned.appendSlice(line[0..start_pos]);
                try cleaned.append('|');
                try cleaned.appendSlice(line[start_pos + 2 ..]);
                try repeat_buffer.append(try cleaned.toOwnedSlice());
                continue;
            }
        }

        if (in_repeat) {
            if (std.mem.indexOf(u8, line, ":|")) |end_pos| {
                // Multi-line repeat ends
                var cleaned = std.array_list.Managed(u8).init(allocator);
                try cleaned.appendSlice(line[0..end_pos]);
                try cleaned.append('|');
                try cleaned.appendSlice(line[end_pos + 2 ..]);
                try repeat_buffer.append(try cleaned.toOwnedSlice());

                // Output the repeat section twice
                for (0..2) |_| {
                    for (repeat_buffer.items) |repeat_line| {
                        try output.appendSlice(repeat_line);
                        try output.append('\n');
                    }
                }

                for (repeat_buffer.items) |item| {
                    allocator.free(item);
                }
                repeat_buffer.clearRetainingCapacity();
                in_repeat = false;
                continue;
            } else {
                // Regular line inside repeat
                try repeat_buffer.append(try allocator.dupe(u8, line));
                continue;
            }
        }

        // Regular line outside repeat
        try output.appendSlice(line);
        try output.append('\n');
    }

    // If malformed (ended while in repeat), output what we have
    if (repeat_buffer.items.len > 0) {
        for (repeat_buffer.items) |repeat_line| {
            try output.appendSlice(repeat_line);
            try output.append('\n');
        }
    }

    return output.toOwnedSlice();
}

pub fn expandABCRepeats(allocator: std.mem.Allocator, abc_content: []const u8) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    defer output.deinit();

    var in_header = true;
    var current_voice_section = std.array_list.Managed(u8).init(allocator);
    defer current_voice_section.deinit();
    var in_voice_section = false;

    var lines = std.mem.splitScalar(u8, abc_content, '\n');

    while (lines.next()) |line| {
        if (in_header) {
            try output.appendSlice(line);
            try output.append('\n');
            if (line.len >= 2 and line[0] == 'K' and line[1] == ':') {
                in_header = false;
            }
            continue;
        }

        if (line.len >= 2 and line[0] == 'V' and line[1] == ':') {
            if (in_voice_section and current_voice_section.items.len > 0) {
                const expanded = try expandVoiceSectionRepeats(allocator, current_voice_section.items);
                defer allocator.free(expanded);
                try output.appendSlice(expanded);
                current_voice_section.clearRetainingCapacity();
            }
            try output.appendSlice(line);
            try output.append('\n');
            continue;
        }

        if (line.len >= 2 and line[0] == '%' and line[1] == '%') {
            if (in_voice_section and current_voice_section.items.len > 0) {
                const expanded = try expandVoiceSectionRepeats(allocator, current_voice_section.items);
                defer allocator.free(expanded);
                try output.appendSlice(expanded);
                current_voice_section.clearRetainingCapacity();
                in_voice_section = false;
            }
            try output.appendSlice(line);
            try output.append('\n');
            continue;
        }

        if (line.len >= 4 and line[0] == '[' and line[1] == 'V' and line[2] == ':') {
            if (in_voice_section and current_voice_section.items.len > 0) {
                const expanded = try expandVoiceSectionRepeats(allocator, current_voice_section.items);
                defer allocator.free(expanded);
                try output.appendSlice(expanded);
                current_voice_section.clearRetainingCapacity();
            }
            try output.appendSlice(line);
            try output.append('\n');
            in_voice_section = true;
            continue;
        }

        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) {
            if (in_voice_section and current_voice_section.items.len > 0) {
                const expanded = try expandVoiceSectionRepeats(allocator, current_voice_section.items);
                defer allocator.free(expanded);
                try output.appendSlice(expanded);
                current_voice_section.clearRetainingCapacity();
                in_voice_section = false;
            }
            try output.appendSlice(line);
            try output.append('\n');
            continue;
        }

        if (in_voice_section) {
            try current_voice_section.appendSlice(line);
            try current_voice_section.append('\n');
        } else {
            in_voice_section = true;
            try current_voice_section.appendSlice(line);
            try current_voice_section.append('\n');
        }
    }

    if (in_voice_section and current_voice_section.items.len > 0) {
        const expanded = try expandVoiceSectionRepeats(allocator, current_voice_section.items);
        defer allocator.free(expanded);
        try output.appendSlice(expanded);
    }

    return output.toOwnedSlice();
}
