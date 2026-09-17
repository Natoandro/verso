const tmpl = @import("tmpl");

comptime {
    _ = tmpl.parse("<p>{{ title</p>", .{});
}
