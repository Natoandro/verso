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

test "distinct literal routes with equal specificity are not ambiguous" {
    const handler = struct {
        fn handle(_: *RequestContext, _: Next) Error!void {}
    }.handle;
    const table = router.routes(.{
        .{ "GET /admin/editor", Layer.initFn(handler) },
    });

    try std.testing.expectEqual(@as(?usize, 0), router.resolve(table.asSlice(), .GET, "/admin/editor"));
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

test "route capture frames expose parents and reject name conflicts" {
    var request_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer request_arena.deinit();

    var request: RequestContext = undefined;
    request.route_captures = .{
        .allocator = request_arena.allocator(),
        .frames = .empty,
    };

    const parent_names = [_][]const u8{"author_id"};
    try request.pushRouteCaptureFrame(parent_names[0..]);

    const conflicting_names = [_][]const u8{"author_id"};
    try std.testing.expectError(
        error.RouteCaptureNameConflict,
        request.pushRouteCaptureFrame(conflicting_names[0..]),
    );

    try request.addRouteCapture("author_id", "42");

    const child_names = [_][]const u8{"document_id"};
    try request.pushRouteCaptureFrame(child_names[0..]);
    try request.addRouteCapture("document_id", "7");
    try std.testing.expectEqualStrings("7", request.routeParam("document_id").?);
    try std.testing.expectEqualStrings("42", request.routeParam("author_id").?);

    request.popRouteCaptureFrame();
    try std.testing.expectEqualStrings("42", request.routeParam("author_id").?);
    try std.testing.expect(request.routeParam("document_id") == null);

    request.popRouteCaptureFrame();
    try std.testing.expect(request.routeParam("author_id") == null);
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
    var request_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer request_arena.deinit();
    var request: RequestContext = undefined;
    request.request = &http_request;
    request.response_status = null;
    request.route_captures = .{
        .allocator = request_arena.allocator(),
        .frames = .empty,
    };

    try mutable_table.handle(&request, .{ .layers = &fallback_layers, .index = 0 });
    try std.testing.expectEqual(@as(?u16, 2), request.response_status);
    try std.testing.expect(request.routeParam("id") == null);
    request.response_status = null;
    try route_layer.handle(&request, .{ .layers = &fallback_layers, .index = 0 });
    try std.testing.expectEqual(@as(?u16, 2), request.response_status);
    try std.testing.expect(request.routeParam("id") == null);

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
