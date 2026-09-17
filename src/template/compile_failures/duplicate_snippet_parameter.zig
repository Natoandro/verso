const tmpl = @import("tmpl");

comptime {
    _ = tmpl.parse("{{#snippet card |value, value|}}{{ value }}{{/snippet}}", .{});
}
