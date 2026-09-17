const std = @import("std");

pub fn write(writer: *std.Io.Writer, value: anytype, comptime escaped: bool) !void {
    const Value = @TypeOf(value);
    ensureScalar(Value);

    if (comptime isString(Value)) {
        switch (@typeInfo(Value)) {
            .pointer => |pointer| {
                if (pointer.size == .slice) {
                    if (escaped) try writeEscaped(writer, value) else try writer.writeAll(value);
                } else {
                    const array = @typeInfo(pointer.child).array;
                    const bytes = value.*[0..array.len];
                    if (escaped) try writeEscaped(writer, bytes) else try writer.writeAll(bytes);
                }
            },
            else => unreachable,
        }
        return;
    }

    switch (@typeInfo(Value)) {
        .@"enum" => try writer.print("{t}", .{value}),
        else => try writer.print("{}", .{value}),
    }
}

pub fn ensureScalar(comptime Value: type) void {
    if (comptime isString(Value)) return;
    switch (@typeInfo(Value)) {
        .int, .comptime_int, .float, .comptime_float, .bool, .@"enum" => {},
        else => @compileError(std.fmt.comptimePrint(
            "template interpolation does not support value type {s}",
            .{@typeName(Value)},
        )),
    }
}

fn isString(comptime Value: type) bool {
    if (Value == []const u8 or Value == []u8) return true;
    return switch (@typeInfo(Value)) {
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .array => |array| isByte(array.child),
            else => pointer.size == .slice and isByte(pointer.child),
        },
        else => false,
    };
}

fn isByte(comptime Value: type) bool {
    return switch (@typeInfo(Value)) {
        .int => |integer| integer.bits == 8 and integer.signedness == .unsigned,
        else => false,
    };
}

fn writeEscaped(writer: *std.Io.Writer, value: []const u8) !void {
    var start: usize = 0;
    for (value, 0..) |character, index| {
        const replacement: []const u8 = switch (character) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&#39;",
            else => continue,
        };
        if (index > start) try writer.writeAll(value[start..index]);
        try writer.writeAll(replacement);
        start = index + 1;
    }
    if (start < value.len) try writer.writeAll(value[start..]);
}
