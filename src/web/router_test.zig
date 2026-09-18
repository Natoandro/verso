const std = @import("std");
const layer = @import("layer.zig");
const router = @import("router.zig");

const RequestContext = router.RequestContext;
const Next = router.Next;
const Layer = router.Layer;
const Error = router.Error;

test "comptime routes compile parameters and select the most specific match" {
    const handler = struct {
        fn handle(_: *RequestContext, _: Next) Error!void {}
    }.handle;
    const table = router.routes(.{
        .{ "GET /articles/{id}", Layer.initFn(handler) },
        .{ "GET /articles/latest", Layer.initFn(handler) },
    });

    try std.testing.expectEqual(@as(?usize, 1), router.resolve(table.asSlice(), .GET, "/articles/latest?draft=true"));
    try std.testing.expectEqual(@as(?usize, 0), router.resolve(table.asSlice(), .GET, "/articles/42"));
    try std.testing.expectEqual(@as(?usize, null), router.resolve(table.asSlice(), .POST, "/articles/42"));
}

test "route matching decodes captures but rejects encoded separators and malformed targets" {
    const handler = struct {
        fn handle(_: *RequestContext, _: Next) Error!void {}
    }.handle;
    const table = router.routes(.{.{ "GET /articles/{id}", Layer.initFn(handler) }});
    const route = table.asSlice();

    try std.testing.expectEqual(@as(?usize, 0), router.resolve(route, .GET, "/articles/a%20b"));
    try std.testing.expectEqual(@as(?usize, 0), router.resolve(route, .GET, "/articles/a%23b"));
    try std.testing.expectEqual(@as(?usize, null), router.resolve(route, .GET, "/articles/a%2Fb"));
    try std.testing.expectEqual(@as(?usize, null), router.resolve(route, .GET, "/articles/%zz"));
    try std.testing.expectEqual(@as(?usize, null), router.resolve(route, .GET, "/articles/../"));
    try std.testing.expectEqual(@as(?usize, null), router.resolve(route, .GET, "/articles/a/"));
}

test "literal routes preserve explicit trailing slash compatibility" {
    const handler = struct {
        fn handle(_: *RequestContext, _: Next) Error!void {}
    }.handle;
    const route = router.Route{
        .method = .GET,
        .path = "/admin/editor",
        .handler = Layer.initFn(handler),
        .trailing_slash = true,
    };
    const routes_table = [_]router.Route{route};

    try std.testing.expectEqual(@as(?usize, 0), router.resolve(&routes_table, .GET, "/admin/editor/"));
    try std.testing.expectEqual(@as(?usize, null), router.resolve(&routes_table, .GET, "/admin/editor//"));
}

test "a compiled route table is a layer and preserves composed handler delegation" {
    const authorize = struct {
        fn handle(request: *RequestContext, next: Next) Error!void {
            request.response_status = 1;
            return next.call(request);
        }
    }.handle;
    const final = struct {
        fn handle(request: *RequestContext, next: Next) Error!void {
            if (request.response_status != 1) return error.AuthorizationWasSkipped;
            if (!std.mem.eql(u8, request.routeParam("id") orelse "", "42")) {
                return error.CaptureWasNotAvailable;
            }
            request.response_status = 2;
            return next.call(request);
        }
    }.handle;
    const fallback = struct {
        fn handle(request: *RequestContext, _: Next) Error!void {
            if (request.response_status == null) request.response_status = 404;
        }
    }.handle;

    const table = router.routes(.{
        .{ "GET /admin/drafts/{id}", layer.compose(.{ authorize, final }) },
    });
    try std.testing.expectEqual(@as(?usize, 0), router.resolve(table.asSlice(), .GET, "/admin/drafts/42?preview=true"));
    var mutable_table = table;
    const route_layer = mutable_table.layer();
    const fallback_layers = [_]Layer{Layer.initFn(fallback)};
    var http_request: std.http.Server.Request = undefined;
    http_request.head.method = .GET;
    http_request.head.target = "/admin/drafts/42?preview=true";
    var request: RequestContext = undefined;
    request.request = &http_request;
    request.response_status = null;

    try mutable_table.handle(&request, .{ .layers = &fallback_layers, .index = 0 });
    try std.testing.expectEqual(@as(?u16, 2), request.response_status);
    request.response_status = null;
    try route_layer.handle(&request, .{ .layers = &fallback_layers, .index = 0 });
    try std.testing.expectEqual(@as(?u16, 2), request.response_status);

    http_request.head.method = .POST;
    request.response_status = null;
    try route_layer.handle(&request, .{ .layers = &fallback_layers, .index = 0 });
    try std.testing.expectEqual(@as(?u16, 404), request.response_status);
}

test "a mounted route layer isolates protected fallthrough from public routes" {
    const protected_handler = struct {
        fn handle(request: *RequestContext, _: Next) Error!void {
            request.response_status = 200;
        }
    }.handle;
    const public_handler = struct {
        fn handle(request: *RequestContext, _: Next) Error!void {
            request.response_status = 418;
        }
    }.handle;

    const protected_table = router.routes(.{.{ "GET /admin/editor", protected_handler }});
    var mutable_protected_table = protected_table;
    var mount = layer.Mount.init("/admin", mutable_protected_table.layer());
    const public_layers = [_]Layer{Layer.initFn(public_handler)};

    var http_request: std.http.Server.Request = undefined;
    var request: RequestContext = undefined;
    request.request = &http_request;

    http_request.head.method = .GET;
    http_request.head.target = "/admin/unknown";
    request.response_status = null;
    try mount.handle(&request, .{ .layers = &public_layers, .index = 0 });
    try std.testing.expectEqual(@as(?u16, null), request.response_status);

    http_request.head.target = "/public";
    request.response_status = null;
    try mount.handle(&request, .{ .layers = &public_layers, .index = 0 });
    try std.testing.expectEqual(@as(?u16, 418), request.response_status);
}
