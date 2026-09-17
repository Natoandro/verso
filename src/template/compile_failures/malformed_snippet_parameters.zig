const tmpl = @import("tmpl");

comptime {
    _ = tmpl.parse("{{#snippet card |post,|}}{{ post }}{{/snippet}}", .{});
}
