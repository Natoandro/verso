const std = @import("std");
const tmpl = @import("tmpl");

comptime {
    const template = tmpl.parse("{{#for title |item|}}{{ item }}{{/for}}");
    var buffer: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    template.render(&writer, .{ .title = "not iterable" }) catch unreachable;
}
