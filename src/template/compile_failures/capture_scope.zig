const std = @import("std");
const tmpl = @import("tmpl");

const Item = struct {
    name: []const u8,
};

const Context = struct {
    items: [1]Item,
};

comptime {
    const template = tmpl.parse("{{#for items |item|}}{{ item.name }}{{/for}}{{ item.name }}", .{});
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    template.render(&writer, Context{ .items = .{.{ .name = "item" }} }) catch unreachable;
}
