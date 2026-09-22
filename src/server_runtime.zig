const std = @import("std");
const builtin = @import("builtin");
const logging = @import("logging.zig");
const failure_reason = @import("failure_reason.zig");
const web = @import("web.zig");

var shutdown_requested = std.atomic.Value(bool).init(false);

pub const SignalHandlerState = if (builtin.os.tag == .linux) struct {
    previous_int: std.c.Sigaction,
    previous_term: std.c.Sigaction,
} else struct {};

pub const ConnectionFailureLogRecord = struct {
    comptime format: []const u8 = "HTTP connection failed after {duration_ms}: {error_name} ({reason}) — {suggestion}",
    level: []const u8,
    event: []const u8,
    message: []const u8,
    duration_ms: web.logging.DurationMilliseconds,
    error_name: []const u8,
    reason: []const u8,
    suggestion: []const u8,
};

pub fn resetShutdown() void {
    shutdown_requested.store(false, .seq_cst);
}

pub fn isShutdownRequested() bool {
    return shutdown_requested.load(.seq_cst);
}

pub fn handleHttpConnection(
    connection: std.Io.net.Stream,
    server_context: *web.ServerContext,
    pipeline: *const web.Pipeline,
) std.Io.Cancelable!void {
    const io = server_context.io;
    const allocator = server_context.allocator;
    defer connection.close(io);

    const started_at = std.Io.Clock.now(.awake, io);
    const read_buffer = allocator.alloc(u8, 8192) catch |allocation_error| {
        logConnectionFailure(server_context, started_at, allocation_error) catch {};
        return;
    };
    defer allocator.free(read_buffer);
    const write_buffer = allocator.alloc(u8, 8192) catch |allocation_error| {
        logConnectionFailure(server_context, started_at, allocation_error) catch {};
        return;
    };
    defer allocator.free(write_buffer);
    var reader = connection.reader(io, read_buffer);
    var writer = connection.writer(io, write_buffer);
    var http_server = std.http.Server.init(&reader.interface, &writer.interface);
    var request_head = http_server.receiveHead() catch |connection_error| {
        if (connection_error == error.Canceled) return error.Canceled;
        try logConnectionFailure(server_context, started_at, connection_error);
        return;
    };

    var remote_address_buffer: [64]u8 = undefined;
    var remote_address_writer = std.Io.Writer.fixed(&remote_address_buffer);
    connection.socket.address.format(&remote_address_writer) catch |address_error| {
        logConnectionFailure(server_context, started_at, address_error) catch {};
        return;
    };
    const formatted_remote_address = remote_address_writer.buffered();
    const remote_address = formatted_remote_address[0 .. std.mem.lastIndexOfScalar(
        u8,
        formatted_remote_address,
        ':',
    ) orelse formatted_remote_address.len];
    var http_request = web.RequestContext.init(
        server_context,
        &connection,
        &request_head,
        started_at,
        remote_address,
    ) catch |init_error| {
        if (init_error == error.Canceled) return error.Canceled;
        logConnectionFailure(server_context, started_at, init_error) catch {};
        return;
    };
    defer http_request.deinit();
    pipeline.handle(&http_request) catch |request_error| {
        if (request_error == error.Canceled) return error.Canceled;
        return;
    };
}

fn logConnectionFailure(
    server_context: *web.ServerContext,
    started_at: std.Io.Timestamp,
    connection_error: anyerror,
) std.Io.Cancelable!void {
    const io = server_context.io;
    const finished_at = std.Io.Clock.now(.awake, io);
    server_context.logger.log(io, ConnectionFailureLogRecord{
        .level = "warn",
        .event = "http.connection_failed",
        .message = "HTTP connection failed",
        .duration_ms = .{ .milliseconds = web.logging.durationMilliseconds(started_at.durationTo(finished_at)) },
        .error_name = @errorName(connection_error),
        .reason = failure_reason.forError(connection_error),
        .suggestion = failure_reason.suggestion(connection_error),
    }) catch {};
}

pub fn handleShutdownSignal(_: std.c.SIG) callconv(.c) void {
    shutdown_requested.store(true, .seq_cst);
}

pub fn installSignalHandlers() !SignalHandlerState {
    if (builtin.os.tag != .linux) return .{};

    var action: std.c.Sigaction = std.mem.zeroes(std.c.Sigaction);
    action.handler.handler = handleShutdownSignal;
    if (std.c.sigemptyset(&action.mask) != 0) return error.SignalSetupFailed;

    var previous_int: std.c.Sigaction = undefined;
    if (std.c.sigaction(.INT, &action, &previous_int) != 0) return error.SignalSetupFailed;

    var previous_term: std.c.Sigaction = undefined;
    if (std.c.sigaction(.TERM, &action, &previous_term) != 0) {
        _ = std.c.sigaction(.INT, &previous_int, null);
        return error.SignalSetupFailed;
    }

    return .{
        .previous_int = previous_int,
        .previous_term = previous_term,
    };
}

pub fn restoreSignalHandlers(state: *SignalHandlerState) void {
    if (builtin.os.tag != .linux) return;
    _ = std.c.sigaction(.INT, &state.previous_int, null);
    _ = std.c.sigaction(.TERM, &state.previous_term, null);
}

pub fn waitForListener(listener_handle: std.Io.net.Socket.Handle) !bool {
    if (builtin.os.tag != .linux) return true;

    var poll_fds = [_]std.posix.pollfd{.{
        .fd = listener_handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    var timeout = std.posix.timespec{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };

    const poll_result = std.posix.ppoll(&poll_fds, &timeout, null) catch |poll_error| switch (poll_error) {
        error.SignalInterrupt => return false,
        else => return poll_error,
    };
    if (poll_result == 0) return false;

    return poll_fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.ERR | std.posix.POLL.HUP) != 0;
}

pub fn resolveListenAddress(io: std.Io, host: []const u8, port: u16) !std.Io.net.IpAddress {
    if (std.Io.net.IpAddress.parse(host, port)) |address| return address else |_| {}

    var host_name = try std.Io.net.HostName.init(host);
    var lookup_buffer: [32]std.Io.net.HostName.LookupResult = undefined;
    var lookup_queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&lookup_buffer);
    try host_name.lookup(io, &lookup_queue, .{ .port = port });

    while (lookup_queue.getOneUncancelable(io)) |lookup_result| {
        switch (lookup_result) {
            .address => |address| return address,
            .canonical_name => {},
        }
    } else |lookup_error| switch (lookup_error) {
        error.Closed => return error.NoAddressReturned,
    }
}

test "connection failure records contain only connection details" {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try logging.writeRecord(
        &writer,
        std.testing.allocator,
        .json,
        42,
        false,
        false,
        ConnectionFailureLogRecord{
            .level = "warn",
            .event = "http.connection_failed",
            .message = "HTTP connection failed",
            .duration_ms = .{ .milliseconds = 3.25 },
            .error_name = "ConnectionReset",
            .reason = "the operation could not be completed",
            .suggestion = "Inspect the error details and retry after correcting the underlying problem.",
        },
    );
    try std.testing.expectEqualStrings(
        "{\"timestamp\":\"1970-01-01T00:00:00.042Z\",\"level\":\"warn\",\"event\":\"http.connection_failed\",\"message\":\"HTTP connection failed\",\"duration_ms\":3.25,\"error_name\":\"ConnectionReset\",\"reason\":\"the operation could not be completed\",\"suggestion\":\"Inspect the error details and retry after correcting the underlying problem.\"}\n",
        writer.buffered(),
    );
}
