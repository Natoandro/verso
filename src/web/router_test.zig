const std = @import("std");
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
