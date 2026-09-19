const builtin = @import("builtin");
const std = @import("std");

/// Template diagnostics are enabled for Debug builds while the renderer's
/// runtime lifetime and stack behavior are being verified. Release builds
/// compile these calls away. This intentionally writes directly to stderr:
/// the template renderer has no application logger or request context.
pub fn log(comptime format: []const u8, args: anytype) void {
    // Template.render is also instantiated while compile-failure tests are
    // evaluated. Never inspect runtime-only values such as writer pointers
    // during that comptime evaluation.
    if (@inComptime()) return;
    if (comptime builtin.mode == .Debug) {
        std.debug.print("[template] " ++ format ++ "\n", args);
    }
}
