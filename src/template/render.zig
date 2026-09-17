const std = @import("std");
const escape = @import("escape.zig");
const expression = @import("expression.zig");

pub fn writePath(writer: *std.Io.Writer, comptime path: anytype, context: anytype, comptime escaped: bool) !void {
    const Value = expression.resolvePathType(@TypeOf(context), path, 0);
    escape.ensureScalar(Value);
    try escape.write(writer, expression.resolvePath(path, context), escaped);
}
