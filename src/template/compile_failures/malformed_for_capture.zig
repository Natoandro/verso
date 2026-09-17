const tmpl = @import("tmpl");

comptime {
    _ = tmpl.parse("{{#for items |item| trailing}}{{ item }}{{/for}}", .{});
}
