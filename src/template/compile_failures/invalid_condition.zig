const std = @import("std");
const tmpl = @import("tmpl");

comptime {
    const template = tmpl.parse("{{#if title}}visible{{/if}}");
    var buffer: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    template.render(&writer, .{ .title = "not a condition" }) catch unreachable;
}
