const std = @import("std");
const auth_crypto = @import("../auth/crypto.zig");
const identity = @import("../auth/identity.zig");
const storage = @import("../storage/identity.zig");

pub const SessionCredentials = struct {
    id: i64,
    token: [auth_crypto.encoded_secret_length]u8,
    csrf_token: [auth_crypto.encoded_secret_length]u8,
};

pub const SessionIdentity = struct {
    user_id: i64,
};

pub const Service = struct {
    store: *storage.Store,

    pub fn init(store: *storage.Store) Service {
        return .{ .store = store };
    }

    pub fn bootstrapOwner(self: *Service, owner: identity.BootstrapOwner) !i64 {
        try identity.validateBootstrapOwner(owner);
        return self.store.bootstrapOwner(owner);
    }

    /// The subject must already be authenticated by the interface/provider.
    /// This service only maps that assertion to a local user and session.
    pub fn startSessionForVerifiedSubject(self: *Service, subject: []const u8) !SessionCredentials {
        const user_id = (try self.store.userIdForSubject(subject)) orelse return error.InvalidCredentials;
        const token = auth_crypto.newSecret();
        const csrf_token = auth_crypto.newSecret();
        const token_hash = auth_crypto.hashSecret(&token);
        const csrf_secret_hash = auth_crypto.hashSecret(&csrf_token);
        const session_id = try self.store.createSession(
            user_id,
            &token_hash,
            &csrf_secret_hash,
        );
        return .{
            .id = session_id,
            .token = token,
            .csrf_token = csrf_token,
        };
    }

    pub fn authenticate(self: *Service, token: []const u8) !SessionIdentity {
        const token_hash = auth_crypto.hashSecret(token);
        const user_id = (try self.store.activeSessionUserId(&token_hash)) orelse return error.InvalidSession;
        return .{ .user_id = user_id };
    }

    pub fn validateCsrf(self: *Service, token: []const u8, csrf_token: []const u8) !void {
        const token_hash = auth_crypto.hashSecret(token);
        const csrf_secret_hash = auth_crypto.hashSecret(csrf_token);
        if (!try self.store.csrfMatches(&token_hash, &csrf_secret_hash)) return error.InvalidCsrfToken;
    }

    pub fn logout(self: *Service, token: []const u8) !void {
        const token_hash = auth_crypto.hashSecret(token);
        try self.store.revokeSession(&token_hash);
    }

    pub fn requireCapability(
        self: *Service,
        token: []const u8,
        capability: identity.Capability,
    ) !void {
        const session = try self.authenticate(token);
        inline for (std.meta.tags(identity.Role)) |role| {
            if (try self.store.userHasRole(session.user_id, role) and identity.roleGrants(role, capability)) return;
        }
        return error.Forbidden;
    }
};

test "owner bootstrap, session lifecycle, CSRF, and capability checks share the service" {
    const sqlite = @import("sqlite");
    const logging = @import("../logging.zig");
    const migrations = @import("../storage/migrations.zig");

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
    var service = Service.init(&store);
    const owner_id = try service.bootstrapOwner(.{
        .subject = "provider|owner",
        .display_name = "Initial Owner",
        .email = "owner@example.test",
    });
    try std.testing.expectEqual(@as(i64, 1), owner_id);
    try std.testing.expectError(error.OwnerAlreadyExists, service.bootstrapOwner(.{
        .subject = "provider|second",
        .display_name = "Second Owner",
    }));

    const credentials = try service.startSessionForVerifiedSubject("provider|owner");
    const session = try service.authenticate(&credentials.token);
    try std.testing.expectEqual(owner_id, session.user_id);
    try service.validateCsrf(&credentials.token, &credentials.csrf_token);
    try service.requireCapability(&credentials.token, .user_manage);
    try std.testing.expectError(
        error.InvalidCsrfToken,
        service.validateCsrf(&credentials.token, "wrong-token"),
    );

    try service.logout(&credentials.token);
    try std.testing.expectError(error.InvalidSession, service.authenticate(&credentials.token));
}

test "disabled, unknown, and expired identities cannot create sessions" {
    const sqlite = @import("sqlite");
    const logging = @import("../logging.zig");
    const migrations = @import("../storage/migrations.zig");

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
    var service = Service.init(&store);
    _ = try service.bootstrapOwner(.{ .subject = "owner", .display_name = "Owner" });
    try std.testing.expectError(error.InvalidCredentials, service.startSessionForVerifiedSubject("missing"));
    const expired = try service.startSessionForVerifiedSubject("owner");
    try database.exec(
        "UPDATE web_sessions SET expires_at = '2000-01-01T00:00:00.000Z' WHERE id = ?",
        .{},
        .{expired.id},
    );
    try std.testing.expectError(error.InvalidSession, service.authenticate(&expired.token));
    try database.exec("UPDATE users SET state = 'disabled' WHERE subject = 'owner'", .{}, .{});
    try std.testing.expectError(error.InvalidCredentials, service.startSessionForVerifiedSubject("owner"));
}
