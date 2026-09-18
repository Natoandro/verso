const std = @import("std");
const context = @import("context.zig");
const layer = @import("layer.zig");

pub const RequestContext = context.RequestContext;
pub const Next = layer.Next;
pub const Layer = layer.Layer;
pub const Error = anyerror;

pub const Route = struct {
    method: std.http.Method,
    path: []const u8,
    handler: Layer,
    trailing_slash: bool = false,
};

pub const Router = struct {
    routes: []const Route,

    pub fn init(routes: []const Route) Router {
        return .{ .routes = routes };
    }

    pub fn handle(self: *Router, request: *RequestContext, next: Next) Error!void {
        const index = resolve(self.routes, request.request.head.method, request.request.head.target) orelse
            return next.call(request);
        return self.routes[index].handler.handle(request, next);
    }
};

pub fn resolve(routes: []const Route, method: std.http.Method, target: []const u8) ?usize {
    const path = pathFromTarget(target);

    for (routes, 0..) |route, index| {
        if (!pathMatches(route, path)) continue;
        if (route.method == method) return index;
    }

    return null;
}

fn pathMatches(route: Route, path: []const u8) bool {
    if (std.mem.eql(u8, path, route.path)) return true;
    return route.trailing_slash and
        path.len == route.path.len + 1 and
        std.mem.startsWith(u8, path, route.path) and
        path[path.len - 1] == '/';
}

fn pathFromTarget(target: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, target, '?')) |query_start| target[0..query_start] else target;
}

test "resolves paths without query strings and with configured trailing slashes" {
    const handler = struct {
        fn handle(_: *RequestContext, _: Next) Error!void {}
    }.handle;
    const routes = [_]Route{
        .{ .method = .GET, .path = "/admin/editor", .handler = .initFn(handler), .trailing_slash = true },
        .{ .method = .GET, .path = "/admin/editor.css", .handler = .initFn(handler) },
    };

    try std.testing.expectEqual(@as(?usize, 0), resolve(&routes, .GET, "/admin/editor/?draft=one"));
    try std.testing.expectEqual(@as(?usize, 1), resolve(&routes, .GET, "/admin/editor.css?version=one"));
    try std.testing.expectEqual(@as(?usize, null), resolve(&routes, .POST, "/admin/editor"));
    try std.testing.expectEqual(@as(?usize, null), resolve(&routes, .GET, "/public/article"));
}

test "routes only match their declared method" {
    const handler = struct {
        fn handle(_: *RequestContext, _: Next) Error!void {}
    }.handle;
    const routes = [_]Route{
        .{ .method = .GET, .path = "/admin/editor", .handler = .initFn(handler) },
        .{ .method = .POST, .path = "/admin/editor", .handler = .initFn(handler) },
    };

    try std.testing.expectEqual(@as(?usize, 1), resolve(&routes, .POST, "/admin/editor"));
}
