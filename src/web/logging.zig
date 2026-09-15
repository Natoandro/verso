const std = @import("std");
const context = @import("context.zig");
const layer = @import("layer.zig");

pub const RequestLoggingLayer = struct {
    pub fn handle(_: *@This(), request: *context.RequestContext, next: layer.Next) layer.Error!void {
        next.call(request) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            try logRequest(request, "warn", @errorName(err));
            return err;
        };

        try logRequest(request, "info", null);
    }
};

fn logRequest(
    request: *context.RequestContext,
    level: []const u8,
    error_name: ?[]const u8,
) std.Io.Cancelable!void {
    const io = request.server.io;
    const finished_at = std.Io.Clock.now(.awake, io);
    try request.server.logger.request(io, .{
        .timestamp_ms = std.Io.Clock.now(.real, io).toMilliseconds(),
        .level = level,
        .event = "http.request",
        .method = @tagName(request.request.head.method),
        .target = request.request.head.target,
        .status = request.response_status,
        .duration_ms = request.started_at.durationTo(finished_at).toMilliseconds(),
        .error_name = error_name,
    });
}
