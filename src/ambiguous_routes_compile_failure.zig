const router = @import("web/router.zig");

const handler = router.Layer{ .state = undefined, .handle_fn = undefined };

comptime {
    _ = router.routes(.{
        .{ "GET /articles/{id}", handler },
        .{ "GET /articles/{slug}", handler },
    });
}
