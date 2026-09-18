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

const max_logged_target_length = 4096;

pub fn sanitizedTarget(target: []const u8, buffer: []u8) []const u8 {
    const suffix = "...";
    if (buffer.len < suffix.len) return buffer[0..0];

    const limit = buffer.len - suffix.len;
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const path_start = absoluteTargetPathStart(target, query_start);
    var output_length: usize = 0;
    var truncated = !appendTargetBytes(buffer, &output_length, limit, target[path_start..query_start]);

    if (!truncated and query_start < target.len) {
        var first_key = true;
        var query = std.mem.splitScalar(u8, target[query_start + 1 ..], '&');
        while (query.next()) |component| {
            const key_end = std.mem.indexOfScalar(u8, component, '=') orelse component.len;
            const key = component[0..key_end];
            if (key.len == 0) continue;

            const separator: u8 = if (first_key) '?' else '&';
            const key_start = output_length;
            if (output_length == limit) {
                truncated = true;
                break;
            }
            buffer[output_length] = separator;
            output_length += 1;
            if (!appendTargetBytes(buffer, &output_length, limit, key)) {
                output_length = key_start;
                truncated = true;
                break;
            }
            first_key = false;
        }
    }

    if (truncated) {
        @memcpy(buffer[output_length .. output_length + suffix.len], suffix);
        output_length += suffix.len;
    }
    return buffer[0..output_length];
}

fn absoluteTargetPathStart(target: []const u8, query_start: usize) usize {
    const scheme_end = std.mem.indexOf(u8, target[0..query_start], "://") orelse return 0;
    if (scheme_end == 0 or !std.ascii.isAlphabetic(target[0])) return 0;
    for (target[1..scheme_end]) |byte| {
        if (!std.ascii.isAlphabetic(byte) and !std.ascii.isDigit(byte) and byte != '+' and byte != '-' and byte != '.') {
            return 0;
        }
    }

    const authority_start = scheme_end + 3;
    return std.mem.indexOfScalarPos(u8, target, authority_start, '/') orelse query_start;
}

fn appendTargetBytes(buffer: []u8, output_length: *usize, limit: usize, value: []const u8) bool {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (isSafeTargetByte(byte)) {
            if (output_length.* == limit) return false;
            buffer[output_length.*] = byte;
            output_length.* += 1;
            continue;
        }

        if (output_length.* + 3 > limit) return false;
        buffer[output_length.*] = '%';
        buffer[output_length.* + 1] = hex[byte >> 4];
        buffer[output_length.* + 2] = hex[byte & 0x0f];
        output_length.* += 3;
    }
    return true;
}

fn isSafeTargetByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or switch (byte) {
        '!', '$', '&', '\'', '(', ')', '*', '+', ',', '-', '.', '/', ':', ';', '=', '?', '@', '[', ']', '_', '~', '%' => true,
        else => false,
    };
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
    var target_buffer: [max_logged_target_length]u8 = undefined;
    request.server.logger.log(io, CompletedRequestLogRecord{
        .level = "info",
        .event = "http.request",
        .message = "HTTP request completed",
        .method = @tagName(request.request.head.method),
        .target = sanitizedTarget(request.request.head.target, &target_buffer),
        .protocol = @tagName(request.request.head.version),
        .status = request.response_status,
        .duration_ms = .{ .milliseconds = durationMilliseconds(duration) },
    }) catch {};
}

fn logFailedRequest(request: *context.RequestContext, error_name: []const u8) std.Io.Cancelable!void {
    const io = request.server.io;
    const finished_at = std.Io.Clock.now(.awake, io);
    const duration = request.started_at.durationTo(finished_at);
    var target_buffer: [max_logged_target_length]u8 = undefined;
    request.server.logger.log(io, FailedRequestLogRecord{
        .level = "warn",
        .event = "http.request",
        .message = "HTTP request failed",
        .method = @tagName(request.request.head.method),
        .target = sanitizedTarget(request.request.head.target, &target_buffer),
        .protocol = @tagName(request.request.head.version),
        .status = request.response_status,
        .duration_ms = .{ .milliseconds = durationMilliseconds(duration) },
        .error_name = error_name,
    }) catch {};
}

test "request targets retain query keys but redact values" {
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/notes/hello?draft&token&flag",
        sanitizedTarget("/notes/hello?draft=true&token=secret&=ignored&flag", &buffer),
    );
}

test "request target logging escapes unsafe bytes" {
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/notes/%22hello?quo%22te&line%0A",
        sanitizedTarget("/notes/\"hello?quo\"te=secret&line\n=value", &buffer),
    );
}

test "request target logging omits absolute-form authority" {
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/private?token",
        sanitizedTarget("http://alice:secret@example.test/private?token=secret", &buffer),
    );
}

test "request target logging is bounded" {
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/notes/123456...",
        sanitizedTarget("/notes/123456789?token=secret", &buffer),
    );
}

test "request target logging truncates before an expanded key" {
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/...",
        sanitizedTarget("/?abcdefghij\"=secret", &buffer),
    );
}
