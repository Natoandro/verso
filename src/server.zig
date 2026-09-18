const std = @import("std");
const builtin = @import("builtin");
const config_types = @import("config.zig");
const application_identity = @import("application/identity.zig");
const bootstrap = @import("application/bootstrap.zig");
const logging = @import("logging.zig");
const migration_directory = @import("storage/migration_directory.zig");
const migrations = @import("storage/migrations.zig");
const database = @import("storage/sqlite.zig");
const web = @import("web.zig");

var shutdown_requested = std.atomic.Value(bool).init(false);

const SignalHandlerState = if (builtin.os.tag == .linux) struct {
    previous_int: std.c.Sigaction,
    previous_term: std.c.Sigaction,
} else struct {};

const ServerListeningLogRecord = struct {
    comptime format: []const u8 = "server listening on {host}:{port}",
    level: []const u8,
    event: []const u8,
    message: []const u8,
    host: []const u8,
    port: u16,
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, app_config: config_types.Config) !void {
    shutdown_requested.store(false, .seq_cst);

    const stderr_is_tty = std.Io.File.stderr().isTty(io) catch false;
    var logger = logging.Logger.initWithOptions(
        allocator,
        app_config.effectiveLoggingFormat(stderr_is_tty),
        .{
            .use_color = stderr_is_tty,
            .omit_null_fields = app_config.logging.omit_null_fields,
        },
    );
    logBestEffort(&logger, io, .{
        .level = "info",
        .event = "server.starting",
        .message = "starting server",
        .environment = @tagName(app_config.runtime.environment),
        .host = app_config.server.host,
        .port = app_config.server.port,
    });

    var signal_handlers = installSignalHandlers() catch |startup_error| {
        logStartupFailure(&logger, io, "signals", startup_error);
        return startup_error;
    };
    defer restoreSignalHandlers(&signal_handlers);

    bootstrap.prepareConfiguredDirectories(io, std.Io.Dir.cwd(), app_config) catch |startup_error| {
        logStartupFailure(&logger, io, "directories", startup_error);
        return startup_error;
    };

    var database_path_buffer: [1024]u8 = undefined;
    const database_path = bootstrap.resolveDatabasePath(app_config, &database_path_buffer) catch |startup_error| {
        logStartupFailure(&logger, io, "database", startup_error);
        return startup_error;
    };
    var database_connection = database.Database.open(allocator, database_path) catch |startup_error| {
        logStartupFailure(&logger, io, "database", startup_error);
        return startup_error;
    };
    defer database_connection.close();

    if (app_config.migrations.run_on_startup) {
        const migration_directory_path = migration_directory.resolveMigrationDirectory(
            io,
            allocator,
            app_config.migrations.path,
        ) catch |directory_error| {
            logStartupFailure(&logger, io, "migrations", directory_error);
            return directory_error;
        };
        defer allocator.free(migration_directory_path);
        var migration_context = database_connection.migrationContext(
            io,
            allocator,
            migration_directory_path,
            &logger,
        );
        _ = migration_context.migrateUp() catch |migration_error| {
            logStartupFailure(&logger, io, "migrations", migration_error);
            return migration_error;
        };
    }

    var identity_store = @import("storage/identity.zig").Store.init(database_connection.sqliteHandle());
    var identity_service = application_identity.Service.initForInterface(
        io,
        allocator,
        &identity_store,
        .web,
    );

    var base_url_buffer: [1024]u8 = undefined;
    const base_url = app_config.effectiveBaseUrl(&base_url_buffer) catch |startup_error| {
        logStartupFailure(&logger, io, "base_url", startup_error);
        return startup_error;
    };
    const public_origin = web.originFromBaseUrl(base_url) catch |startup_error| {
        logStartupFailure(&logger, io, "base_url", startup_error);
        return startup_error;
    };
    var trusted_proxy_storage: [16][]const u8 = undefined;
    const trusted_proxy_addresses = web.parseTrustedProxyAddresses(
        app_config.security.trusted_proxy_addresses,
        &trusted_proxy_storage,
    ) catch |startup_error| {
        logStartupFailure(&logger, io, "security", startup_error);
        return startup_error;
    };

    var listen_address = resolveListenAddress(io, app_config.server.host, app_config.server.port) catch |startup_error| {
        logStartupFailure(&logger, io, "address", startup_error);
        return startup_error;
    };
    var listener = listen_address.listen(io, .{ .reuse_address = true }) catch |startup_error| {
        logStartupFailure(&logger, io, "listener", startup_error);
        return startup_error;
    };
    defer listener.deinit(io);

    logBestEffort(&logger, io, ServerListeningLogRecord{
        .level = "info",
        .event = "server.listening",
        .message = "server listening",
        .host = app_config.server.host,
        .port = listener.socket.address.getPort(),
    });
    var listener_started = true;
    var shutdown_reason: []const u8 = "signal";
    defer if (listener_started) logBestEffort(&logger, io, .{
        .level = "info",
        .event = "server.shutdown",
        .message = "server shutting down",
        .reason = shutdown_reason,
    });

    var server_context = web.ServerContext{
        .io = io,
        .allocator = allocator,
        .config = &app_config,
        .logger = &logger,
        .identity_service = &identity_service,
        .origin_policy = .{
            .public_origin = public_origin,
            .trusted_proxy_addresses = trusted_proxy_addresses,
        },
    };
    var editor_router = web.EditorHandler.router();
    var auth_router = web.AuthHandler.router();
    var session_guard = web.SessionGuard{};
    var protected_editor = web.ProtectedEditorHandler{
        .guard = &session_guard,
        .router = &editor_router,
        .fallback = web.Layer.initFn(NotFoundHandler.handle),
    };
    var admin_mount = web.Mount.initWithFallback(
        "/admin",
        .init(&auth_router),
        .init(&protected_editor),
    );
    var status_router = web.routes(.{.{ "GET /", StatusHandler.handle }}).router();
    var request_logging = web.RequestLoggingLayer{};
    const layers = [_]web.Layer{
        .init(&request_logging),
        .init(&admin_mount),
        .init(&status_router),
        web.Layer.initFn(NotFoundHandler.handle),
    };
    const pipeline = web.Pipeline.init(&layers);
    var handlers: std.Io.Group = .init;
    errdefer handlers.cancel(io);

    while (!shutdown_requested.load(.seq_cst)) {
        const listener_ready = waitForListener(listener.socket.handle) catch |runtime_error| {
            shutdown_reason = "failure";
            logRuntimeFailure(&logger, io, "wait_for_connection", runtime_error);
            return runtime_error;
        };
        if (!listener_ready) continue;

        var connection = listener.accept(io) catch |connection_error| switch (connection_error) {
            error.ConnectionAborted => continue,
            else => {
                shutdown_reason = "failure";
                logRuntimeFailure(&logger, io, "accept", connection_error);
                return connection_error;
            },
        };

        handlers.concurrent(io, handleHttpConnection, .{ connection, &server_context, &pipeline }) catch |dispatch_error| {
            connection.close(io);
            shutdown_reason = "failure";
            logRuntimeFailure(&logger, io, "handler_dispatch", dispatch_error);
            return dispatch_error;
        };
    }

    handlers.cancel(io);
    listener_started = false;
    logBestEffort(&logger, io, .{
        .level = "info",
        .event = "server.shutdown",
        .message = "server shut down",
        .reason = shutdown_reason,
    });
}

fn handleHttpConnection(
    connection: std.Io.net.Stream,
    server_context: *web.ServerContext,
    pipeline: *const web.Pipeline,
) std.Io.Cancelable!void {
    const io = server_context.io;
    defer connection.close(io);

    const started_at = std.Io.Clock.now(.awake, io);
    var read_buffer: [8192]u8 = undefined;
    var write_buffer: [8192]u8 = undefined;
    var reader = connection.reader(io, &read_buffer);
    var writer = connection.writer(io, &write_buffer);
    var http_server = std.http.Server.init(&reader.interface, &writer.interface);
    var request_head = http_server.receiveHead() catch |connection_error| {
        if (connection_error == error.Canceled) return error.Canceled;
        try logConnectionFailure(server_context, started_at, connection_error);
        return;
    };

    var remote_address_buffer: [64]u8 = undefined;
    var remote_address_writer = std.Io.Writer.fixed(&remote_address_buffer);
    connection.socket.address.format(&remote_address_writer) catch return;
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
    );
    pipeline.handle(&http_request) catch |request_error| {
        if (request_error == error.Canceled) return error.Canceled;
        return;
    };
}

const StatusHandler = struct {
    pub fn handle(http_request: *web.RequestContext, _: web.Next) anyerror!void {
        http_request.request.respond("Verso is running\n", .{
            .keep_alive = false,
            .extra_headers = &.{.{
                .name = "content-type",
                .value = "text/plain; charset=utf-8",
            }},
        }) catch |response_error| {
            if (response_error == error.Canceled) return error.Canceled;
            return response_error;
        };

        http_request.response_status = 200;
    }
};

const NotFoundHandler = struct {
    pub fn handle(http_request: *web.RequestContext, _: web.Next) anyerror!void {
        http_request.request.respond("Not Found\n", .{
            .status = .not_found,
            .keep_alive = false,
            .extra_headers = &.{.{
                .name = "content-type",
                .value = "text/plain; charset=utf-8",
            }},
        }) catch |response_error| {
            if (response_error == error.Canceled) return error.Canceled;
            return response_error;
        };

        http_request.response_status = @intFromEnum(std.http.Status.not_found);
    }
};

fn logConnectionFailure(
    server_context: *web.ServerContext,
    started_at: std.Io.Timestamp,
    connection_error: anyerror,
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
            .milliseconds = web.logging.durationMilliseconds(started_at.durationTo(finished_at)),
        },
        .error_name = @errorName(connection_error),
    }) catch {};
}

fn logBestEffort(logger: *logging.Logger, io: std.Io, record: anytype) void {
    logger.log(io, record) catch {};
}

fn logStartupFailure(logger: *logging.Logger, io: std.Io, stage: []const u8, startup_error: anyerror) void {
    logBestEffort(logger, io, .{
        .level = "error",
        .event = "server.startup_failed",
        .message = "server startup failed",
        .stage = stage,
        .error_name = @errorName(startup_error),
    });
}

fn logRuntimeFailure(logger: *logging.Logger, io: std.Io, stage: []const u8, runtime_error: anyerror) void {
    logBestEffort(logger, io, .{
        .level = "error",
        .event = "server.runtime_failed",
        .message = "server runtime failed",
        .stage = stage,
        .error_name = @errorName(runtime_error),
    });
}

fn handleShutdownSignal(_: std.c.SIG) callconv(.c) void {
    shutdown_requested.store(true, .seq_cst);
}

fn installSignalHandlers() !SignalHandlerState {
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

fn restoreSignalHandlers(state: *SignalHandlerState) void {
    if (builtin.os.tag != .linux) return;
    _ = std.c.sigaction(.INT, &state.previous_int, null);
    _ = std.c.sigaction(.TERM, &state.previous_term, null);
}

fn waitForListener(listener_handle: std.Io.net.Socket.Handle) !bool {
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

fn resolveListenAddress(io: std.Io, host: []const u8, port: u16) !std.Io.net.IpAddress {
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
