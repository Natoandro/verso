const std = @import("std");

const tmpl = @import("tmpl");

comptime {
    const template = tmpl.parse("{{#snippet outer |value|}}{{#snippet inner |text|}}{{ text }}{{/snippet}}{{> inner value}}{{/snippet}}{{> inner value}}", .{});
    var buffer: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    template.render(&writer, .{ .value = "value" }) catch unreachable;
}
