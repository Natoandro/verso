const std = @import("std");
const context = @import("context.zig");
const layer = @import("layer.zig");
const route = @import("router.zig");
const tmpl = @import("tmpl");

const editor_template = tmpl.parse(@embedFile("editor.html"), .{});

const EditorPage = struct {
    fn handle(request: *context.RequestContext, _: layer.Next) anyerror!void {
        const content = try editor_template.renderAlloc(request.server.allocator, .{});
        defer request.server.allocator.free(content);
        request.request.respond(content, .{
            .status = .ok,
            .keep_alive = true,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/html; charset=utf-8" },
                .{ .name = "cache-control", .value = "no-store" },
            },
        }) catch |response_error| {
            if (response_error == error.Canceled) return error.Canceled;
            return response_error;
        };
        request.response_status = 200;
    }
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
    .{ "GET /admin/editor", EditorPage.handle },
});

test "editor route table serves the server-rendered shell" {
    const routes = Handler.routes();

    try std.testing.expectEqual(@as(?usize, 0), route.resolve(routes, .GET, "/admin/editor?draft=one"));
    try std.testing.expectEqual(@as(?usize, 0), route.resolve(routes, .GET, "/admin/editor/"));
    try std.testing.expectEqual(@as(?usize, null), route.resolve(routes, .POST, "/admin/editor"));
}

test "editor mount isolates admin misses from outer routes" {
    const public_handler = struct {
        fn handle(request: *context.RequestContext, _: layer.Next) layer.Error!void {
            request.response_status = 418;
        }
    }.handle;

    var editor_router = Handler.router();
    var editor_mount = layer.Mount.init("/admin", layer.Layer.init(&editor_router));
    const outer_layers = [_]layer.Layer{layer.Layer.initFn(public_handler)};
    var http_request: std.http.Server.Request = undefined;
    var request: context.RequestContext = undefined;
    request.request = &http_request;
    http_request.head.method = .GET;
    http_request.head.target = "/admin/unknown";

    try editor_mount.handle(&request, .{ .layers = &outer_layers, .index = 0 });
    try std.testing.expectEqual(@as(?u16, null), request.response_status);

    http_request.head.target = "/public";
    try editor_mount.handle(&request, .{ .layers = &outer_layers, .index = 0 });
    try std.testing.expectEqual(@as(?u16, 418), request.response_status);
}
