const std = @import("std");

pub const Error = error{InvalidValue};

pub fn get(map: ?*const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const environ_map = map orelse return null;
    return environ_map.get(name);
}

pub fn parseBool(boolean_text: []const u8) Error!bool {
    if (std.mem.eql(u8, boolean_text, "true")) return true;
    if (std.mem.eql(u8, boolean_text, "false")) return false;
    return error.InvalidValue;
}

pub fn parseUnsigned(comptime T: type, integer_text: []const u8) Error!T {
    return std.fmt.parseUnsigned(T, integer_text, 10) catch error.InvalidValue;
}

pub fn parseEnum(comptime T: type, enum_text: []const u8) Error!T {
    return std.meta.stringToEnum(T, enum_text) orelse error.InvalidValue;
}

test "environment parsers require canonical values" {
    try std.testing.expectEqual(true, try parseBool("true"));
    try std.testing.expectEqual(false, try parseBool("false"));
    try std.testing.expectError(error.InvalidValue, parseBool("TRUE"));
    try std.testing.expectEqual(@as(u16, 8080), try parseUnsigned(u16, "8080"));
    try std.testing.expectError(error.InvalidValue, parseUnsigned(u16, "8_080"));
}
