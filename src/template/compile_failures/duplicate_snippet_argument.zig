const std = @import("std");
const tmpl = @import("tmpl");

comptime {
    const template = tmpl.parse("{{> card value=title value=title}}{{#snippet card |value|}}{{ value }}{{/snippet}}", .{});
    var buffer: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    template.render(&writer, .{ .title = "title" }) catch unreachable;
}
