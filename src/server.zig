const std = @import("std");
const config_types = @import("config.zig");
const application_identity = @import("application/identity.zig");
const application_documents = @import("application/documents.zig");
const identity_management = @import("application/identity_management.zig");
const identity_queries = @import("storage/identity_queries.zig");
const bootstrap = @import("application/bootstrap.zig");
const logging = @import("logging.zig");
const migration_directory = @import("storage/migration_directory.zig");
const migrations = @import("storage/migrations.zig");
const database = @import("storage/sqlite.zig");
const web = @import("web.zig");
const runtime = @import("server_runtime.zig");

const ServerListeningLogRecord = struct {
    comptime format: []const u8 = "server listening on {host}:{port}",
    level: []const u8,
    event: []const u8,
    message: []const u8,
    host: []const u8,
    port: u16,
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, app_config: config_types.Config) !void {
    runtime.resetShutdown();

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

    var signal_handlers = runtime.installSignalHandlers() catch |startup_error| {
        logStartupFailure(&logger, io, "signals", startup_error);
        return startup_error;
    };
    defer runtime.restoreSignalHandlers(&signal_handlers);

    bootstrap.prepareConfiguredDirectories(io, std.Io.Dir.cwd(), allocator, app_config) catch |startup_error| {
        logStartupFailure(&logger, io, "directories", startup_error);
        return startup_error;
    };

    const database_path = bootstrap.resolveDatabasePath(allocator, app_config) catch |startup_error| {
        logStartupFailure(&logger, io, "database", startup_error);
        return startup_error;
    };
    defer allocator.free(database_path);
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
    var document_store = @import("storage/documents.zig").Store.init(database_connection.sqliteHandle());
    var identity_query_store = identity_queries.Store.init(database_connection.sqliteHandle());
    var identity_service = application_identity.Service.initForInterface(
        io,
        allocator,
        &identity_store,
        .web,
    );
    const bootstrap_config = app_config.auth.bootstrap;
    if (bootstrap_config.isConfigured()) {
        _ = identity_service.bootstrapLocalOwnerHash(.{
            .subject = bootstrap_config.subject,
            .display_name = bootstrap_config.display_name.?,
            .email = bootstrap_config.email,
        }, bootstrap_config.login.?, bootstrap_config.password_hash.?) catch |bootstrap_error| switch (bootstrap_error) {
            error.OwnerAlreadyExists => {},
            else => {
                logStartupFailure(&logger, io, "initial_owner", bootstrap_error);
                return bootstrap_error;
            },
        };
    }
    var identity_management_service = identity_management.Service.init(
        allocator,
        &identity_query_store,
        &identity_service,
    );
    var document_service = application_documents.Service.initProtected(
        allocator,
        &document_store,
        &identity_service,
    );

    const base_url = app_config.effectiveBaseUrl(allocator) catch |startup_error| {
        logStartupFailure(&logger, io, "base_url", startup_error);
        return startup_error;
    };
    defer allocator.free(base_url);
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

    var listen_address = runtime.resolveListenAddress(io, app_config.server.host, app_config.server.port) catch |startup_error| {
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
        .document_service = &document_service,
        .identity_management_service = &identity_management_service,
        .origin_policy = .{
            .public_origin = public_origin,
            .trusted_proxy_addresses = trusted_proxy_addresses,
        },
    };
    var editor_router = web.EditorHandler.router();
    var auth_router = web.AuthHandler.router();
    var management_router = web.ManagementHandler.router();
    var session_guard = web.SessionGuard{};
    var protected_editor = web.ProtectedEditorHandler{
        .guard = &session_guard,
        .router = &editor_router,
        .fallback = web.Layer.initFn(NotFoundHandler.handle),
    };
    var protected_admin_layers = [_]web.Layer{
        .init(&management_router),
        .init(&protected_editor),
    };
    var protected_admin = ProtectedAdmin{
        .layers = &protected_admin_layers,
    };
    var admin_mount = web.Mount.initWithFallback(
        "/admin",
        .init(&auth_router),
        .init(&protected_admin),
    );
    var status_router = web.routes(.{.{ "GET /", StatusHandler.handle }}).router();
    var request_logging = web.RequestLoggingLayer{};
    var header_cache = web.HeaderCacheLayer{
        .names = &.{
            "host",
            "origin",
            "cookie",
            "x-csrf-token",
            "hx-request",
            "x-forwarded-proto",
            "x-forwarded-host",
        },
    };
    const layers = [_]web.Layer{
        .init(&request_logging),
        .init(&header_cache),
        .init(&admin_mount),
        .init(&status_router),
        web.Layer.initFn(NotFoundHandler.handle),
    };
    const pipeline = web.Pipeline.init(&layers);
    var handlers: std.Io.Group = .init;
    errdefer handlers.cancel(io);

    while (!runtime.isShutdownRequested()) {
        const listener_ready = runtime.waitForListener(listener.socket.handle) catch |runtime_error| {
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

        handlers.concurrent(io, runtime.handleHttpConnection, .{ connection, &server_context, &pipeline }) catch |dispatch_error| {
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
            web.logging.logDiagnostic(http_request, "error", "http.response_failed", "failed to write status response", .ok, response_error, null);
            return response_error;
        };

        http_request.response_status = 200;
    }
};

const NotFoundHandler = struct {
    pub fn handle(http_request: *web.RequestContext, _: web.Next) anyerror!void {
        web.logging.logDiagnostic(http_request, "info", "http.request_rejected", "no route matched request", .not_found, error.NotFound, "route not found");
        return web.respondError(http_request, .not_found);
    }
};

const ProtectedAdmin = struct {
    layers: []const web.Layer,

    pub fn handle(self: *@This(), request: *web.RequestContext, _: web.Next) anyerror!void {
        return (web.Next{ .layers = self.layers, .index = 0 }).call(request);
    }
};

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
