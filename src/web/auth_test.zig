const std = @import("std");
const auth = @import("auth.zig");
const route = @import("router.zig");

test "admin authentication routes separate login and logout methods" {
    const routes = auth.Handler.routes();
    try std.testing.expectEqual(@as(?usize, 0), route.resolve(routes, .GET, "/admin/login"));
    try std.testing.expectEqual(@as(?usize, 1), route.resolve(routes, .POST, "/admin/login"));
    try std.testing.expectEqual(@as(?usize, 2), route.resolve(routes, .GET, "/admin/register"));
    try std.testing.expectEqual(@as(?usize, 3), route.resolve(routes, .POST, "/admin/register"));
    try std.testing.expectEqual(@as(?usize, 4), route.resolve(routes, .POST, "/admin/logout"));
    try std.testing.expectEqual(@as(?usize, null), route.resolve(routes, .GET, "/admin/logout"));
    try std.testing.expectEqual(@as(?usize, null), route.resolve(routes, .GET, "/admin/recover"));
    try std.testing.expectEqual(@as(?usize, 7), route.resolve(routes, .GET, "/admin/recover/complete"));
}

test "standalone admin pages expose their shared stylesheet" {
    try std.testing.expectEqual(
        @as(?usize, 11),
        route.resolve(auth.Handler.routes(), .GET, "/admin/admin.css"),
    );
}

test "admin entry points use the setup-aware login handler" {
    const routes = auth.Handler.routes();
    try std.testing.expectEqual(@as(?usize, 12), route.resolve(routes, .GET, "/admin"));
    try std.testing.expectEqual(@as(?usize, 13), route.resolve(routes, .GET, "/admin/"));
}
