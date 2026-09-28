const std = @import("std");

pub const max_target_segments = 64;
pub const max_decoded_segment = 4096;

pub const TargetSegment = struct { raw: []const u8 };

pub const Target = struct {
    path: []const u8,
    segments: [max_target_segments]TargetSegment = undefined,
    segment_count: usize = 0,
    trailing_slash: bool = false,
};

pub fn parseTarget(target: []const u8) ?Target {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const path = target[0..query_start];
    if (path.len == 0 or path[0] != '/' or std.mem.indexOfScalar(u8, path, '#') != null) return null;

    var parsed = Target{ .path = path };
    if (path.len == 1) {
        parsed.trailing_slash = true;
        return parsed;
    }

    var path_end = path.len;
    if (path[path_end - 1] == '/') {
        parsed.trailing_slash = true;
        path_end -= 1;
        if (path_end == 0 or path[path_end - 1] == '/') return null;
    }

    var cursor: usize = 1;
    while (cursor < path_end) {
        if (parsed.segment_count == max_target_segments) return null;
        const segment_start = cursor;
        while (cursor < path_end and path[cursor] != '/') : (cursor += 1) {}
        if (cursor == segment_start) return null;
        const raw = path[segment_start..cursor];
        var decoded: [max_decoded_segment]u8 = undefined;
        const value = decodeSegment(raw, &decoded) catch return null;
        if (std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..")) return null;
        parsed.segments[parsed.segment_count] = .{ .raw = raw };
        parsed.segment_count += 1;
        if (cursor < path_end) cursor += 1;
    }
    return parsed;
}

pub fn decodeSegment(raw: []const u8, output: []u8) ![]const u8 {
    var output_len: usize = 0;
    var cursor: usize = 0;
    while (cursor < raw.len) {
        if (output_len == output.len) return error.TargetTooLong;
        var value = raw[cursor];
        if (value == '%') {
            if (cursor + 2 >= raw.len) return error.MalformedTarget;
            const high = hexValue(raw[cursor + 1]) orelse return error.MalformedTarget;
            const low = hexValue(raw[cursor + 2]) orelse return error.MalformedTarget;
            value = (high << 4) | low;
            cursor += 3;
        } else {
            cursor += 1;
        }
        if (value == '/' or value == '\\' or value < 0x20 or value == 0x7f) {
            return error.UnsafeTarget;
        }
        output[output_len] = value;
        output_len += 1;
    }
    return output[0..output_len];
}

fn hexValue(value: u8) ?u8 {
    return switch (value) {
        '0'...'9' => value - '0',
        'a'...'f' => value - 'a' + 10,
        'A'...'F' => value - 'A' + 10,
        else => null,
    };
}

pub fn countPathSegments(path: []const u8) usize {
    if (std.mem.eql(u8, path, "/")) return 0;
    var count: usize = 1;
    for (path) |character| {
        if (character == '/') count += 1;
    }
    if (path[path.len - 1] == '/') count -= 1;
    return count;
}
