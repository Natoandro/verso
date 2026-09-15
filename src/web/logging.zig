const std = @import("std");
const context = @import("context.zig");
const layer = @import("layer.zig");

pub const RequestLoggingLayer = struct {
    pub fn handle(_: *@This(), request: *context.RequestContext, next: layer.Next) layer.Error!void {
        next.call(request) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            try logFailedRequest(request, @errorName(err));
            return err;
        };

        try logCompletedRequest(request);
    }
};

const CompletedRequestLogRecord = struct {
    comptime format: []const u8 = "\"{method} {target} {protocol}\" {status} {duration_us}µs",
    level: []const u8,
    event: []const u8,
    message: []const u8,
    method: []const u8,
    target: []const u8,
    protocol: []const u8,
    status: ?u16,
    duration_ms: i64,
    duration_us: i64,
};

const FailedRequestLogRecord = struct {
    comptime format: []const u8 = "\"{method} {target} {protocol}\" {status} {duration_us}µs failed: {error_name}",
    level: []const u8,
    event: []const u8,
    message: []const u8,
    method: []const u8,
    target: []const u8,
    protocol: []const u8,
    status: ?u16,
    duration_ms: i64,
    duration_us: i64,
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
        .duration_ms = duration.toMilliseconds(),
        .duration_us = duration.toMicroseconds(),
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
        .duration_ms = duration.toMilliseconds(),
        .duration_us = duration.toMicroseconds(),
        .error_name = error_name,
    }) catch {};
}
