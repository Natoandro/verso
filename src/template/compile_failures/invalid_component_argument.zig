const std = @import("std");
const tmpl = @import("tmpl");

comptime {
    const card = tmpl.parse("<strong>{{ user.name }}</strong>", .{ .parameters = .{ .user = {} } });
    const page = tmpl.parse("{{> card user=1}}", .{ .components = .{ .card = card } });
    var buffer: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    page.render(&writer, .{}) catch unreachable;
}
