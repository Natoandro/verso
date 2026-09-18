const tmpl = @import("tmpl");

comptime {
    const layout = tmpl.layout("{{> header}}{{> content}}{{> footer}}");
    const header = tmpl.parse("<header />", .{});
    const content = tmpl.parse("<main />", .{});
    _ = layout.with(.{ .header = header, .content = content });
}
