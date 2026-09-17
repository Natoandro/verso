const std = @import("std");
const tmpl = @import("tmpl");

comptime {
    const page = tmpl.parse("{{> missing}}", .{});
    var buffer: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    page.render(&writer, .{}) catch unreachable;
}
