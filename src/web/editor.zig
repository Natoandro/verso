const std = @import("std");
const editor_assets = @import("editor_assets");
const route = @import("router.zig");
const static_content = @import("static.zig");

const editor_html = @embedFile("editor.html");
const editor_policy = static_content.ResponsePolicy{
    .status = .ok,
    .cache_control = "no-store",
};

pub const Handler = struct {
    pub fn routes() []const route.Route {
        return routes_table.asSlice();
    }

    pub fn router() route.Router {
        return routes_table.router();
    }
};

const routes_table = route.routes(.{
    .{ "GET /admin/editor", static_content.EmbeddedStatic.handler(
        editor_html,
        "text/html; charset=utf-8",
        editor_policy,
    ) },
    .{ "GET /admin/editor.css", static_content.EmbeddedStatic.handler(
        editor_assets.css,
        "text/css; charset=utf-8",
        editor_policy,
    ) },
    .{ "GET /admin/editor.js", static_content.EmbeddedStatic.handler(
        editor_assets.javascript,
        "text/javascript; charset=utf-8",
        editor_policy,
    ) },
});

test "editor routes use comptime embedded static handlers" {
    const routes = Handler.routes();

    try std.testing.expectEqual(@as(?usize, 0), route.resolve(routes, .GET, "/admin/editor?draft=one"));
    try std.testing.expectEqual(@as(?usize, 0), route.resolve(routes, .GET, "/admin/editor/"));
    try std.testing.expectEqual(@as(?usize, 1), route.resolve(routes, .GET, "/admin/editor.css"));
    try std.testing.expectEqual(@as(?usize, 2), route.resolve(routes, .GET, "/admin/editor.js"));
    try std.testing.expectEqual(@as(?usize, null), route.resolve(routes, .POST, "/admin/editor"));
}
