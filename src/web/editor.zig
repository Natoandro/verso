const std = @import("std");
const context = @import("context.zig");
const editor_assets = @import("editor_assets");
const router = @import("router.zig");

const editor_html = @embedFile("editor.html");

pub const Handler = struct {
    pub fn routes() []const router.Route {
        return routes_table[0..];
    }
};

const routes_table = [_]router.Route{
    .{
        .method = .GET,
        .path = "/admin/editor",
        .handler = .initFn(serveEditor),
        .trailing_slash = true,
    },
    .{
        .method = .GET,
        .path = "/admin/editor.css",
        .handler = .initFn(serveStylesheet),
    },
    .{
        .method = .GET,
        .path = "/admin/editor.js",
        .handler = .initFn(serveJavascript),
    },
};

fn serveEditor(request: *context.RequestContext, _: router.Next) router.Error!void {
    return respond(request, editor_html, .ok, "text/html; charset=utf-8");
}

fn serveStylesheet(request: *context.RequestContext, _: router.Next) router.Error!void {
    return respond(request, editor_assets.css, .ok, "text/css; charset=utf-8");
}

fn serveJavascript(request: *context.RequestContext, _: router.Next) router.Error!void {
    return respond(request, editor_assets.javascript, .ok, "text/javascript; charset=utf-8");
}

fn respond(
    request: *context.RequestContext,
    body: []const u8,
    status: std.http.Status,
    content_type: []const u8,
) router.Error!void {
    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = content_type },
        .{ .name = "cache-control", .value = "no-store" },
    };
    request.request.respond(body, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = &headers,
    }) catch |response_error| {
        if (response_error == error.Canceled) return error.Canceled;
        return response_error;
    };
    request.response_status = @intFromEnum(status);
}

test "editor routes cover the admin editor assets" {
    const routes = Handler.routes();

    try std.testing.expectEqual(@as(?usize, 0), router.resolve(routes, .GET, "/admin/editor?draft=one"));
    try std.testing.expectEqual(@as(?usize, 0), router.resolve(routes, .GET, "/admin/editor/"));
    try std.testing.expectEqual(@as(?usize, 1), router.resolve(routes, .GET, "/admin/editor.css"));
    try std.testing.expectEqual(@as(?usize, 2), router.resolve(routes, .GET, "/admin/editor.js"));
    try std.testing.expectEqual(@as(?usize, null), router.resolve(routes, .POST, "/admin/editor"));
}
