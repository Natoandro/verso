const tmpl = @import("tmpl");

comptime {
    _ = tmpl.parse("{{#if enabled}}body{{/for}}", .{});
}
