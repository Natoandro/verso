const std = @import("std");
const tmpl = @import("tmpl");

comptime {
    const template = tmpl.parse("{{> card one}}{{#snippet card |first, second|}}{{ first }}{{ second }}{{/snippet}}", .{});
    var buffer: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    template.render(&writer, .{ .one = "one" }) catch unreachable;
}
