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

pub fn durationMilliseconds(duration: std.Io.Duration) f32 {
    return @as(f32, @floatFromInt(duration.toNanoseconds())) / 1_000_000.0;
}

pub const DurationMilliseconds = struct {
    value: f32,

    pub fn jsonStringify(self: @This(), json: anytype) !void {
        var buffer: [64]u8 = undefined;
        const rendered = render(self.value, &buffer);
        try json.print("{s}", .{rendered});
    }
};

fn render(value: f32, buffer: []u8) []const u8 {
    if (value == 0.0) return "0";

    const exponent: i32 = @intFromFloat(@floor(std.math.log10(@abs(value))));
    const scientific = exponent >= 6;
    const precision: usize = if (scientific) 5 else if (exponent >= 5) 0 else @intCast(5 - exponent);
    var rendered = std.fmt.float.render(buffer, value, .{
        .mode = if (scientific) .scientific else .decimal,
        .precision = precision,
    }) catch unreachable;

    if (std.mem.indexOfScalar(u8, rendered, '.')) |dot| {
        var end = rendered.len;
        while (end > dot + 1 and rendered[end - 1] == '0') end -= 1;
        if (end == dot + 1) end = dot;
        rendered = rendered[0..end];
    }

    return rendered;
}

const CompletedRequestLogRecord = struct {
    comptime format: []const u8 = "\"{method} {target} {protocol}\" {status} {duration_ms}ms",
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
    comptime format: []const u8 = "\"{method} {target} {protocol}\" {status} {duration_ms}ms failed: {error_name}",
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
        .duration_ms = .{ .value = durationMilliseconds(duration) },
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
        .duration_ms = .{ .value = durationMilliseconds(duration) },
        .error_name = error_name,
    }) catch {};
}
