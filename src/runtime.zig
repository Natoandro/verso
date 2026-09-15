const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const logging = @import("logging.zig");
const database = @import("storage/sqlite.zig");
const web = @import("web.zig");

var shutdown_requested = std.atomic.Value(bool).init(false);

const SignalState = if (builtin.os.tag == .linux) struct {
    previous_int: std.c.Sigaction,
    previous_term: std.c.Sigaction,
} else struct {};

pub fn prepareDirectories(io: std.Io, root: std.Io.Dir, value: config.Config) !void {
    try prepareDatabaseDirectory(io, root, value);

    switch (value.storage) {
        .filesystem => |filesystem| try root.createDirPath(io, filesystem.path),
    }
    try root.createDirPath(io, value.cache.path);
}

pub fn prepareDatabaseDirectory(io: std.Io, root: std.Io.Dir, value: config.Config) !void {
    var database_path_buffer: [1024]u8 = undefined;
    const database_path = try databasePath(value, &database_path_buffer);
    try createParentPath(io, root, database_path);
}

pub fn serve(io: std.Io, allocator: std.mem.Allocator, value: config.Config) !void {
    shutdown_requested.store(false, .seq_cst);

    const stderr_is_tty = std.Io.File.stderr().isTty(io) catch false;
    var logger = logging.Logger.initWithOptions(
        allocator,
        value.effectiveLoggingFormat(stderr_is_tty),
        .{
            .use_color = stderr_is_tty,
            .omit_null_fields = value.logging.omit_null_fields,
        },
    );
    logBestEffort(&logger, io, .{
        .level = "info",
        .event = "server.starting",
        .message = "starting server",
        .environment = @tagName(value.runtime.environment),
        .host = value.server.host,
        .port = value.server.port,
    });

    var signal_state = installSignalHandlers() catch |err| {
        logStartupFailure(&logger, io, "signals", err);
        return err;
    };
    defer restoreSignalHandlers(&signal_state);

    prepareDirectories(io, std.Io.Dir.cwd(), value) catch |err| {
        logStartupFailure(&logger, io, "directories", err);
        return err;
    };

    var database_path_buffer: [1024]u8 = undefined;
    const database_path = databasePath(value, &database_path_buffer) catch |err| {
        logStartupFailure(&logger, io, "database", err);
        return err;
    };
    var db = database.Database.open(allocator, database_path) catch |err| {
        logStartupFailure(&logger, io, "database", err);
        return err;
    };
    defer db.close();

    var address = resolveAddress(io, value.server.host, value.server.port) catch |err| {
        logStartupFailure(&logger, io, "address", err);
        return err;
    };
    var server = address.listen(io, .{ .reuse_address = true }) catch |err| {
        logStartupFailure(&logger, io, "listener", err);
        return err;
    };
    defer server.deinit(io);

    logBestEffort(&logger, io, .{
        .level = "info",
        .event = "server.listening",
        .message = "server listening",
        .host = value.server.host,
        .port = server.socket.address.getPort(),
    });
    var server_started = true;
    var shutdown_reason: []const u8 = "signal";
    defer if (server_started) logBestEffort(&logger, io, .{
        .level = "info",
        .event = "server.shutdown",
        .message = "server shutting down",
        .reason = shutdown_reason,
    });

    var server_context = web.ServerContext{
        .io = io,
        .allocator = allocator,
        .config = &value,
        .logger = &logger,
    };
    var bootstrap_handler = BootstrapHandler{};
    var request_logging = web.RequestLoggingLayer{};
    const layers = [_]web.Layer{ .init(&request_logging), .init(&bootstrap_handler) };
    const pipeline = web.Pipeline.init(&layers);
    var handlers: std.Io.Group = .init;
    errdefer handlers.cancel(io);

    while (!shutdown_requested.load(.seq_cst)) {
        const ready = waitForConnection(server.socket.handle) catch |err| {
            shutdown_reason = "failure";
            logRuntimeFailure(&logger, io, "wait_for_connection", err);
            return err;
        };
        if (!ready) continue;

        var stream = server.accept(io) catch |err| switch (err) {
            error.ConnectionAborted => continue,
            else => {
                shutdown_reason = "failure";
                logRuntimeFailure(&logger, io, "accept", err);
                return err;
            },
        };

        handlers.concurrent(io, handleConnection, .{ stream, &server_context, &pipeline }) catch |err| {
            stream.close(io);
            shutdown_reason = "failure";
            logRuntimeFailure(&logger, io, "handler_dispatch", err);
            return err;
        };
    }

    handlers.cancel(io);
    server_started = false;
    logBestEffort(&logger, io, .{
        .level = "info",
        .event = "server.shutdown",
        .message = "server shut down",
        .reason = shutdown_reason,
    });
}

fn handleConnection(
    stream: std.Io.net.Stream,
    server_context: *web.ServerContext,
    pipeline: *const web.Pipeline,
) std.Io.Cancelable!void {
    const io = server_context.io;
    defer stream.close(io);

    const started_at = std.Io.Clock.now(.awake, io);
    var read_buffer: [8192]u8 = undefined;
    var write_buffer: [8192]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);
    var http_server = std.http.Server.init(&reader.interface, &writer.interface);
    var request = http_server.receiveHead() catch |err| {
        if (err == error.Canceled) return error.Canceled;
        try logConnectionFailure(server_context, started_at, err);
        return;
    };

    var context = web.RequestContext.init(server_context, &stream, &request, started_at);
    pipeline.handle(&context) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        return;
    };
}

const BootstrapHandler = struct {
    pub fn handle(_: *@This(), request: *web.RequestContext, _: web.Next) anyerror!void {
        request.request.respond("Verso is running\n", .{
            .keep_alive = false,
            .extra_headers = &.{.{
                .name = "content-type",
                .value = "text/plain; charset=utf-8",
            }},
        }) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            return err;
        };

        request.response_status = 200;
    }
};

fn logConnectionFailure(
    server_context: *web.ServerContext,
    started_at: std.Io.Timestamp,
    err: anyerror,
) std.Io.Cancelable!void {
    const io = server_context.io;
    const finished_at = std.Io.Clock.now(.awake, io);
    server_context.logger.log(io, .{
        .level = "warn",
        .event = "http.request",
        .message = "HTTP request failed",
        .method = null,
        .target = null,
        .status = null,
        .duration_ms = .{
            .value = web.logging.durationMilliseconds(started_at.durationTo(finished_at)),
        },
        .error_name = @errorName(err),
    }) catch {};
}

fn logBestEffort(logger: *logging.Logger, io: std.Io, record: anytype) void {
    logger.log(io, record) catch {};
}

fn logStartupFailure(logger: *logging.Logger, io: std.Io, stage: []const u8, err: anyerror) void {
    logBestEffort(logger, io, .{
        .level = "error",
        .event = "server.startup_failed",
        .message = "server startup failed",
        .stage = stage,
        .error_name = @errorName(err),
    });
}

fn logRuntimeFailure(logger: *logging.Logger, io: std.Io, stage: []const u8, err: anyerror) void {
    logBestEffort(logger, io, .{
        .level = "error",
        .event = "server.runtime_failed",
        .message = "server runtime failed",
        .stage = stage,
        .error_name = @errorName(err),
    });
}

fn requestShutdown(_: std.c.SIG) callconv(.c) void {
    shutdown_requested.store(true, .seq_cst);
}

fn installSignalHandlers() !SignalState {
    if (builtin.os.tag != .linux) return .{};

    var action: std.c.Sigaction = std.mem.zeroes(std.c.Sigaction);
    action.handler.handler = requestShutdown;
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

fn restoreSignalHandlers(state: *SignalState) void {
    if (builtin.os.tag != .linux) return;
    _ = std.c.sigaction(.INT, &state.previous_int, null);
    _ = std.c.sigaction(.TERM, &state.previous_term, null);
}

fn waitForConnection(handle: std.Io.net.Socket.Handle) !bool {
    if (builtin.os.tag != .linux) return true;

    var poll_fds = [_]std.posix.pollfd{.{
        .fd = handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    var timeout = std.posix.timespec{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };

    const result = std.posix.ppoll(&poll_fds, &timeout, null) catch |err| switch (err) {
        error.SignalInterrupt => return false,
        else => return err,
    };
    if (result == 0) return false;

    return poll_fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.ERR | std.posix.POLL.HUP) != 0;
}

fn resolveAddress(io: std.Io, host: []const u8, port: u16) !std.Io.net.IpAddress {
    if (std.Io.net.IpAddress.parse(host, port)) |address| return address else |_| {}

    var host_name = try std.Io.net.HostName.init(host);
    var lookup_buffer: [32]std.Io.net.HostName.LookupResult = undefined;
    var lookup_queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&lookup_buffer);
    try host_name.lookup(io, &lookup_queue, .{ .port = port });

    while (lookup_queue.getOneUncancelable(io)) |result| {
        switch (result) {
            .address => |address| return address,
            .canonical_name => {},
        }
    } else |err| switch (err) {
        error.Closed => return error.NoAddressReturned,
    }
}

pub fn databasePath(value: config.Config, buffer: []u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, value.database.url, ':') == null) {
        return value.database.url;
    }

    const uri = try std.Uri.parse(value.database.url);
    if (!uri.path.isEmpty()) {
        const path = try uri.path.toRaw(buffer);
        if (std.mem.startsWith(u8, path, "/./")) return path[1..];
        return path;
    }
    if (uri.host) |host| return host.toRaw(buffer);
    return error.InvalidDatabaseUrl;
}

fn createParentPath(io: std.Io, root: std.Io.Dir, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0) return;
    try root.createDirPath(io, parent);
}

test "prepareDirectories creates database, asset, and cache parents" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var value = config.Config{};
    value.database.url = "nested/db/verso.db";
    value.storage = .{ .filesystem = .{ .path = "nested/assets" } };
    value.cache.path = "nested/cache";

    try prepareDirectories(std.testing.io, tmp.dir, value);

    var database_parent = try tmp.dir.openDir(std.testing.io, "nested/db", .{});
    database_parent.close(std.testing.io);
    var assets = try tmp.dir.openDir(std.testing.io, "nested/assets", .{});
    assets.close(std.testing.io);
    var cache = try tmp.dir.openDir(std.testing.io, "nested/cache", .{});
    cache.close(std.testing.io);
}

test "prepareDirectories is repeatable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const value = config.Config{};
    try prepareDirectories(std.testing.io, tmp.dir, value);
    try prepareDirectories(std.testing.io, tmp.dir, value);
}

test "prepareDirectories rejects a file in a configured parent path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var blocker = try tmp.dir.createFile(std.testing.io, "blocked", .{});
    blocker.close(std.testing.io);

    var value = config.Config{};
    value.database.url = "blocked/verso.db";
    try std.testing.expectError(error.NotDir, prepareDirectories(std.testing.io, tmp.dir, value));
}

test "databasePath keeps relative SQLite URLs relative" {
    var value = config.Config{};
    value.database.url = "sqlite:///./data/verso.db";

    var buffer: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("./data/verso.db", try databasePath(value, &buffer));
}

test "databasePath keeps absolute SQLite URLs absolute" {
    var value = config.Config{};
    value.database.url = "sqlite:///var/lib/verso.db";

    var buffer: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("/var/lib/verso.db", try databasePath(value, &buffer));
}
