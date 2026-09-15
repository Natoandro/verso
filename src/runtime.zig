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
    var database_path_buffer: [1024]u8 = undefined;
    const database_path = try databasePath(value, &database_path_buffer);
    try createParentPath(io, root, database_path);

    switch (value.storage) {
        .filesystem => |filesystem| try root.createDirPath(io, filesystem.path),
    }
    try root.createDirPath(io, value.cache.path);
}

pub fn serve(io: std.Io, allocator: std.mem.Allocator, value: config.Config) !void {
    shutdown_requested.store(false, .seq_cst);
    var signal_state = try installSignalHandlers();
    defer restoreSignalHandlers(&signal_state);

    try prepareDirectories(io, std.Io.Dir.cwd(), value);

    var database_path_buffer: [1024]u8 = undefined;
    const database_path = try databasePath(value, &database_path_buffer);
    var db = try database.Database.open(allocator, database_path);
    defer db.close();

    var address = try resolveAddress(io, value.server.host, value.server.port);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    var logger = logging.Logger.init(allocator);
    var server_context = web.ServerContext{
        .io = io,
        .allocator = allocator,
        .config = &value,
        .logger = &logger,
    };
    var bootstrap_handler = BootstrapHandler{};
    const layers = [_]web.Layer{.init(&bootstrap_handler)};
    const pipeline = web.Pipeline.init(&layers);
    var handlers: std.Io.Group = .init;
    errdefer handlers.cancel(io);

    while (!shutdown_requested.load(.seq_cst)) {
        if (!try waitForConnection(server.socket.handle)) continue;

        var stream = server.accept(io) catch |err| switch (err) {
            error.ConnectionAborted => continue,
            else => return err,
        };

        handlers.concurrent(io, handleConnection, .{ stream, &server_context, &pipeline }) catch |err| {
            stream.close(io);
            return err;
        };
    }

    handlers.cancel(io);
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
        try logRequest(&context, .{
            .level = "warn",
            .status = context.response_status,
            .error_name = @errorName(err),
        });
    };
}

const BootstrapHandler = struct {
    pub fn handle(_: *@This(), request: *web.RequestContext, _: web.Next) std.Io.Cancelable!void {
        request.request.respond("Verso is running\n", .{
            .keep_alive = false,
            .extra_headers = &.{.{
                .name = "content-type",
                .value = "text/plain; charset=utf-8",
            }},
        }) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            try logRequest(request, .{
                .level = "warn",
                .status = null,
                .error_name = @errorName(err),
            });
            return;
        };

        request.response_status = 200;
        try logRequest(request, .{
            .level = "info",
            .status = request.response_status,
            .error_name = null,
        });
    }
};

const RequestLogFields = struct {
    level: []const u8,
    status: ?u16,
    error_name: ?[]const u8,
};

fn logRequest(request: *web.RequestContext, fields: RequestLogFields) std.Io.Cancelable!void {
    const io = request.server.io;
    const finished_at = std.Io.Clock.now(.awake, io);
    try request.server.logger.request(io, .{
        .timestamp_ms = std.Io.Clock.now(.real, io).toMilliseconds(),
        .level = fields.level,
        .event = "http.request",
        .method = @tagName(request.request.head.method),
        .target = request.request.head.target,
        .status = fields.status,
        .duration_ms = request.started_at.durationTo(finished_at).toMilliseconds(),
        .error_name = fields.error_name,
    });
}

fn logConnectionFailure(
    server_context: *web.ServerContext,
    started_at: std.Io.Timestamp,
    err: anyerror,
) std.Io.Cancelable!void {
    const io = server_context.io;
    const finished_at = std.Io.Clock.now(.awake, io);
    try server_context.logger.request(io, .{
        .timestamp_ms = std.Io.Clock.now(.real, io).toMilliseconds(),
        .level = "warn",
        .event = "http.request",
        .method = null,
        .target = null,
        .status = null,
        .duration_ms = started_at.durationTo(finished_at).toMilliseconds(),
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

fn databasePath(value: config.Config, buffer: []u8) ![]const u8 {
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
