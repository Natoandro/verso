const std = @import("std");
const tmpl = @import("tmpl");

comptime {
    const template = tmpl.parse("{{> card}}{{#snippet card |post|}}{{ post }}{{/snippet}}", .{});
    var buffer: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    template.render(&writer, .{}) catch unreachable;
}
