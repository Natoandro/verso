const std = @import("std");
const identity = @import("identity.zig");
const logging = @import("../logging.zig");
const storage = @import("../storage/identity.zig");
const migrations = @import("../storage/migrations.zig");

test "local password authentication rotates sessions and supports recovery" {
    const sqlite = @import("sqlite");

    var database = try sqlite.Db.init(.{
        .mode = .Memory,
        .open_flags = .{ .write = true, .create = true },
    });
    defer database.deinit();
    var logger = logging.Logger.init(std.testing.allocator, .text);
    var migration_context = migrations.MigrationContext.init(
        std.testing.io,
        std.testing.allocator,
        "migrations",
        &database,
        &logger,
    );
    _ = try migration_context.migrateUp();

    var store = storage.Store.init(&database);
    var service = identity.Service.initForInterface(std.testing.io, std.testing.allocator, &store, .web);
    const owner_id = try service.bootstrapLocalOwner(
        .{ .subject = "local-owner", .display_name = "Local Owner" },
        "Owner@Example.test",
        "correct horse battery staple",
    );
    try std.testing.expectError(
        error.InvalidCredentials,
        service.startLocalSession("owner@example.test", "wrong password", "192.0.2.1"),
    );

    const first_session = try service.startLocalSession(
        "owner@example.test",
        "correct horse battery staple",
        "192.0.2.1",
    );
    const second_session = try service.startLocalSession(
        "OWNER@EXAMPLE.TEST",
        "correct horse battery staple",
        "192.0.2.1",
    );
    try std.testing.expectError(error.InvalidSession, service.authenticate(&first_session.token));
    try std.testing.expectEqual(owner_id, (try service.authenticate(&second_session.token)).user_id);

    const changed_session = try service.changePassword(
        &second_session.token,
        "correct horse battery staple",
        "another correct horse battery staple",
    );
    try std.testing.expectError(error.InvalidSession, service.authenticate(&second_session.token));
    try std.testing.expectEqual(owner_id, (try service.authenticate(&changed_session.token)).user_id);

    const reset = (try service.requestPasswordReset("owner@example.test", "192.0.2.1")).?;
    const recovered_session = try service.completePasswordReset(
        &reset.value,
        "recovered correct horse battery staple",
    );
    try std.testing.expectError(error.InvalidSession, service.authenticate(&changed_session.token));
    try std.testing.expectEqual(owner_id, (try service.authenticate(&recovered_session.token)).user_id);
    try std.testing.expectError(
        error.InvalidCredentials,
        service.startLocalSession("owner@example.test", "another correct horse battery staple", "192.0.2.1"),
    );
    var failure_index: usize = 1;
    while (failure_index < 5) : (failure_index += 1) {
        try std.testing.expectError(
            error.InvalidCredentials,
            service.startLocalSession("owner@example.test", "another correct horse battery staple", "192.0.2.1"),
        );
    }
    try std.testing.expectError(
        error.InvalidCredentials,
        service.startLocalSession("owner@example.test", "recovered correct horse battery staple", "192.0.2.1"),
    );
    try database.exec(
        "UPDATE local_login_rate_limits SET window_started_at = '2000-01-01T00:00:00.000Z', locked_until = NULL",
        .{},
        .{},
    );
    try std.testing.expectError(
        error.InvalidCredentials,
        service.startLocalSession("owner@example.test", "another correct horse battery staple", "192.0.2.1"),
    );
}
