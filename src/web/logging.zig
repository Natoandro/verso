const std = @import("std");
const context = @import("context.zig");
const layer = @import("layer.zig");

pub const RequestLoggingLayer = struct {
    pub fn handle(_: *@This(), request: *context.RequestContext, next: layer.Next) layer.Error!void {
        next.call(request) catch |request_error| {
            if (request_error == error.Canceled) return error.Canceled;
            try logFailedRequest(request, @errorName(request_error));
            return request_error;
        };

        try logCompletedRequest(request);
    }
};

pub fn durationMilliseconds(duration: std.Io.Duration) f32 {
    return @as(f32, @floatFromInt(duration.toNanoseconds())) / 1_000_000.0;
}

pub const DurationMilliseconds = struct {
    milliseconds: f32,

    pub fn jsonStringify(self: @This(), json: anytype) !void {
        try json.write(self.milliseconds);
    }

    pub fn logFormat(self: @This(), writer: *std.Io.Writer) !void {
        const seconds = self.milliseconds >= 1_000.0;
        const display_value = if (seconds) self.milliseconds / 1_000.0 else self.milliseconds;
        const unit: []const u8 = if (seconds) "s" else "ms";

        if (display_value < 9.999995) {
            try writer.print("{d:.5}{s}", .{ display_value, unit });
        } else if (display_value < 99.99995) {
            try writer.print("{d:.4}{s}", .{ display_value, unit });
        } else if (display_value < 999.995) {
            try writer.print("{d:.3}{s}", .{ display_value, unit });
        } else {
            try writer.print("{e:.5}{s}", .{ display_value, unit });
        }
    }
};

const CompletedRequestLogRecord = struct {
    comptime format: []const u8 = "\"{method} {target} {protocol}\" {status} {duration_ms}",
    level: []const u8,
    event: []const u8,
    message: []const u8,
    method: []const u8,
    target: []const u8,
    protocol: []const u8,
    status: ?u16,
    duration_ms: DurationMilliseconds,
};

const FailedRequestLogRecord = struct {
    comptime format: []const u8 = "\"{method} {target} {protocol}\" {status} {duration_ms} failed: {error_name}",
    level: []const u8,
    event: []const u8,
    message: []const u8,
    method: []const u8,
    target: []const u8,
    protocol: []const u8,
    status: ?u16,
    duration_ms: DurationMilliseconds,
    error_name: []const u8,
};

fn logCompletedRequest(request: *context.RequestContext) std.Io.Cancelable!void {
    const io = request.server.io;
    const finished_at = std.Io.Clock.now(.awake, io);
    const duration = request.started_at.durationTo(finished_at);
    request.server.logger.log(io, CompletedRequestLogRecord{
        .level = "info",
        .event = "http.request",
        .message = "HTTP request completed",
        .method = @tagName(request.request.head.method),
        .target = request.request.head.target,
        .protocol = @tagName(request.request.head.version),
        .status = request.response_status,
        .duration_ms = .{ .milliseconds = durationMilliseconds(duration) },
    }) catch {};
}

fn logFailedRequest(request: *context.RequestContext, error_name: []const u8) std.Io.Cancelable!void {
    const io = request.server.io;
    const finished_at = std.Io.Clock.now(.awake, io);
    const duration = request.started_at.durationTo(finished_at);
    request.server.logger.log(io, FailedRequestLogRecord{
        .level = "warn",
        .event = "http.request",
        .message = "HTTP request failed",
        .method = @tagName(request.request.head.method),
        .target = request.request.head.target,
        .protocol = @tagName(request.request.head.version),
        .status = request.response_status,
        .duration_ms = .{ .milliseconds = durationMilliseconds(duration) },
        .error_name = error_name,
    }) catch {};
}
