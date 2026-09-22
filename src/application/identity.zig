const std = @import("std");
const auth_crypto = @import("../auth/crypto.zig");
const identity = @import("../auth/identity.zig");
const password = @import("../auth/password.zig");
const domain = @import("../domain/identity.zig");
const storage = @import("../storage/identity.zig");
const local_storage = @import("../storage/local_auth.zig");
const initial_owner = @import("initial_owner.zig");

pub const SessionCredentials = struct {
    id: i64,
    token: [auth_crypto.encoded_secret_length]u8,
    csrf_token: [auth_crypto.encoded_secret_length]u8,
};

pub const SessionIdentity = struct {
    user_id: i64,
};

pub const PasswordResetToken = struct {
    value: [auth_crypto.encoded_secret_length]u8,
};

pub const Service = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    store: *storage.Store,
    local_store: local_storage.Store,
    audit_interface: domain.AuditInterface,

    pub fn initForInterface(
        io: std.Io,
        allocator: std.mem.Allocator,
        store: *storage.Store,
        audit_interface: domain.AuditInterface,
    ) Service {
        return .{
            .io = io,
            .allocator = allocator,
            .store = store,
            .local_store = .init(store.database),
            .audit_interface = audit_interface,
        };
    }

    pub fn bootstrapOwner(self: *Service, owner: identity.BootstrapOwner) !i64 {
        try identity.validateBootstrapOwner(owner);
        return self.store.bootstrapOwner(owner);
    }

    pub fn bootstrapLocalOwner(
        self: *Service,
        owner: identity.BootstrapOwner,
        login: []const u8,
        password_text: []const u8,
    ) !i64 {
        return self.bootstrapLocalOwnerPassword(.{
            .subject = owner.subject,
            .display_name = owner.display_name,
            .email = owner.email,
        }, login, password_text);
    }

    pub fn bootstrapLocalOwnerPassword(
        self: *Service,
        profile: initial_owner.Profile,
        login: []const u8,
        password_text: []const u8,
    ) !i64 {
        var initial_service = self.initialOwnerService();
        return initial_service.hashAndProvisionLocal(profile, login, password_text);
    }

    pub fn bootstrapLocalOwnerHash(
        self: *Service,
        profile: initial_owner.Profile,
        login: []const u8,
        password_hash: []const u8,
    ) !i64 {
        var initial_service = self.initialOwnerService();
        return initial_service.provisionLocal(profile, .{
            .login = login,
            .password_hash = password_hash,
        });
    }

    pub fn registerInitialLocalOwner(
        self: *Service,
        profile: initial_owner.Profile,
        login: []const u8,
        password_text: []const u8,
        remote_address: []const u8,
    ) !SessionCredentials {
        var login_buffer: [320]u8 = undefined;
        const normalized_login = password.normalizeLogin(&login_buffer, login) catch |failure| {
            return failure;
        };
        const identifier_hash = rateKey("registration-identifier:", normalized_login);
        const address_hash = rateKey("registration-address:", remote_address);
        if (!try self.local_store.allowLoginAttempt(&identifier_hash, &address_hash)) {
            return error.InvalidRegistration;
        }

        var initial_service = self.initialOwnerService();
        const user_id = initial_service.hashAndProvisionLocal(
            profile,
            normalized_login,
            password_text,
        ) catch |registration_error| switch (registration_error) {
            error.OwnerAlreadyExists => return error.OwnerAlreadyExists,
            error.InvalidDisplayName,
            error.InvalidEmail,
            error.InvalidLogin,
            error.InvalidPassword,
            error.InvalidPasswordHash,
            => return registration_error,
            else => return registration_error,
        };
        try self.local_store.clearRateLimit(&identifier_hash, &address_hash);
        return self.createSession(user_id);
    }

    pub fn initialSetupAvailable(self: *Service) !bool {
        return self.store.hasNoUsers();
    }

    fn initialOwnerService(self: *Service) initial_owner.Service {
        return initial_owner.Service.init(self.io, self.allocator, self.store);
    }

    /// The subject must already be authenticated by the interface/provider.
    /// This service only maps that assertion to a local user and session.
    pub fn startSessionForVerifiedSubject(self: *Service, subject: []const u8) !SessionCredentials {
        const user_id = (try self.store.userIdForSubject(subject)) orelse return error.InvalidCredentials;
        const token = try auth_crypto.newSecret(self.io);
        const csrf_token = try auth_crypto.newSecret(self.io);
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

    pub fn startLocalSession(
        self: *Service,
        login: []const u8,
        password_text: []const u8,
        remote_address: []const u8,
    ) !SessionCredentials {
        var login_buffer: [320]u8 = undefined;
        const normalized_login = password.normalizeLogin(&login_buffer, login) catch return error.InvalidCredentials;
        const identifier_hash = rateKey("identifier:", normalized_login);
        const address_hash = rateKey("address:", remote_address);
        if (!try self.local_store.allowLoginAttempt(&identifier_hash, &address_hash)) return error.InvalidCredentials;

        var credential = try self.local_store.credentialForLogin(self.allocator, normalized_login);
        defer if (credential) |*value| value.deinit();
        const valid = if (credential) |*value|
            try password.verify(self.allocator, self.io, value.password_hash, password_text)
        else blk: {
            var ignored_hash: [password.encoded_hash_capacity]u8 = undefined;
            _ = try password.hash(self.allocator, self.io, "Verso invalid credential padding", &ignored_hash);
            break :blk false;
        };
        if (!valid) {
            return error.InvalidCredentials;
        }

        const user_id = credential.?.user_id;
        try self.local_store.clearRateLimit(&identifier_hash, &address_hash);
        return self.createRotatedSession(user_id);
    }

    pub fn changePassword(
        self: *Service,
        token: []const u8,
        current_password: []const u8,
        new_password: []const u8,
    ) !SessionCredentials {
        const session = try self.authenticate(token);
        try password.validatePassword(new_password);
        var credential = (try self.local_store.credentialForUser(self.allocator, session.user_id)) orelse {
            return error.InvalidCredentials;
        };
        defer credential.deinit();
        if (!try password.verify(self.allocator, self.io, credential.password_hash, current_password)) {
            return error.InvalidCredentials;
        }
        var password_hash: [password.encoded_hash_capacity]u8 = undefined;
        const encoded_hash = try password.hash(self.allocator, self.io, new_password, &password_hash);
        try self.local_store.replacePassword(session.user_id, encoded_hash);
        return self.createSession(session.user_id);
    }

    pub fn requestPasswordReset(
        self: *Service,
        login: []const u8,
        remote_address: []const u8,
    ) !?PasswordResetToken {
        var login_buffer: [320]u8 = undefined;
        const normalized_login = password.normalizeLogin(&login_buffer, login) catch return null;
        const identifier_hash = rateKey("recovery-identifier:", normalized_login);
        const address_hash = rateKey("recovery-address:", remote_address);
        if (!try self.local_store.allowLoginAttempt(&identifier_hash, &address_hash)) return null;
        var credential = (try self.local_store.credentialForLogin(self.allocator, normalized_login)) orelse return null;
        defer credential.deinit();

        const token = try auth_crypto.newSecret(self.io);
        const token_hash = auth_crypto.hashSecret(&token);
        if (!try self.local_store.issueResetToken(credential.user_id, &token_hash)) return null;
        return .{ .value = token };
    }

    /// Issues a reset token for an operator who already controls the database.
    /// The caller is responsible for protecting the returned URL.
    pub fn issueAdminPasswordReset(self: *Service, identifier: []const u8) !PasswordResetToken {
        var identifier_buffer: [320]u8 = undefined;
        const normalized_identifier = password.normalizeLogin(&identifier_buffer, identifier) catch {
            return error.ResetUserNotFound;
        };
        var credential = (try self.local_store.credentialForLoginOrEmail(
            self.allocator,
            normalized_identifier,
        )) orelse return error.ResetUserNotFound;
        defer credential.deinit();

        const token = try auth_crypto.newSecret(self.io);
        const token_hash = auth_crypto.hashSecret(&token);
        if (!try self.local_store.issueResetToken(credential.user_id, &token_hash)) {
            return error.ResetUserNotFound;
        }
        return .{ .value = token };
    }

    pub fn completePasswordReset(
        self: *Service,
        token: []const u8,
        new_password: []const u8,
    ) !SessionCredentials {
        try password.validatePassword(new_password);
        if (token.len != auth_crypto.encoded_secret_length) return error.InvalidCredentials;
        const token_hash = auth_crypto.hashSecret(token);
        if (!try self.local_store.resetTokenIsValid(&token_hash)) return error.InvalidCredentials;
        var password_hash: [password.encoded_hash_capacity]u8 = undefined;
        const encoded_hash = try password.hash(self.allocator, self.io, new_password, &password_hash);
        const user_id = (try self.local_store.consumeResetAndReplace(&token_hash, encoded_hash)) orelse {
            return error.InvalidCredentials;
        };
        return self.createSession(user_id);
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

    pub fn createAuthor(self: *Service, token: []const u8, request: domain.CreateAuthor) !i64 {
        try domain.validateCreateAuthor(request);
        const actor_user_id = try self.authorize(token, .author_manage);
        return self.store.createAuthor(request, actor_user_id, self.audit_interface);
    }

    pub fn updateAuthor(self: *Service, token: []const u8, request: domain.UpdateAuthor) !void {
        try domain.validateUpdateAuthor(request);
        const actor_user_id = try self.authorize(token, .author_manage);
        try self.store.updateAuthor(request, actor_user_id, self.audit_interface);
    }

    pub fn setVersionAuthors(self: *Service, token: []const u8, request: domain.SetVersionAuthors) !void {
        try domain.validateSetVersionAuthors(request);
        const actor_user_id = try self.authorize(token, .author_manage);
        try self.store.setVersionAuthors(request, actor_user_id, self.audit_interface);
    }

    pub fn createAssignment(self: *Service, token: []const u8, request: domain.CreateAssignment) !i64 {
        try domain.validateCreateAssignment(request);
        const actor_user_id = try self.authorize(token, .document_assign_editor);
        return self.store.createAssignment(request, actor_user_id, self.audit_interface);
    }

    pub fn revokeAssignment(self: *Service, token: []const u8, request: domain.RevokeAssignment) !i64 {
        try domain.validateRevokeAssignment(request);
        const actor_user_id = try self.authorize(token, .document_assign_editor);
        return self.store.revokeAssignment(request, actor_user_id, self.audit_interface);
    }

    pub fn requireAuthorAccess(self: *Service, token: []const u8, author_id: i64) !void {
        const session = try self.authenticate(token);
        if (try self.store.userHasRole(session.user_id, .owner)) return;
        if (try self.store.userHasRole(session.user_id, .manager)) return;
        try self.requireCapability(token, .document_read_assigned);
        if (!try self.store.hasAuthorAssignment(session.user_id, author_id)) return error.Forbidden;
    }

    pub fn requireDocumentAccess(self: *Service, token: []const u8, document_id: i64) !void {
        const session = try self.authenticate(token);
        if (try self.store.userHasRole(session.user_id, .owner)) return;
        if (try self.store.userHasRole(session.user_id, .manager)) return;
        try self.requireCapability(token, .document_read_assigned);
        if (!try self.store.hasDocumentAssignment(session.user_id, document_id)) return error.Forbidden;
    }

    pub fn requireVersionAccess(self: *Service, token: []const u8, version_id: i64) !void {
        const session = try self.authenticate(token);
        if (try self.store.userHasRole(session.user_id, .owner)) return;
        if (try self.store.userHasRole(session.user_id, .manager)) return;
        try self.requireCapability(token, .document_read_assigned);
        if (!try self.store.hasVersionAssignment(session.user_id, version_id)) return error.Forbidden;
    }

    fn authorize(self: *Service, token: []const u8, capability: identity.Capability) !i64 {
        const session = try self.authenticate(token);
        try self.requireCapability(token, capability);
        return session.user_id;
    }

    fn createSession(self: *Service, user_id: i64) !SessionCredentials {
        const token = try auth_crypto.newSecret(self.io);
        const csrf_token = try auth_crypto.newSecret(self.io);
        const token_hash = auth_crypto.hashSecret(&token);
        const csrf_secret_hash = auth_crypto.hashSecret(&csrf_token);
        const session_id = try self.store.createSession(user_id, &token_hash, &csrf_secret_hash);
        return .{ .id = session_id, .token = token, .csrf_token = csrf_token };
    }

    fn createRotatedSession(self: *Service, user_id: i64) !SessionCredentials {
        const token = try auth_crypto.newSecret(self.io);
        const csrf_token = try auth_crypto.newSecret(self.io);
        const token_hash = auth_crypto.hashSecret(&token);
        const csrf_secret_hash = auth_crypto.hashSecret(&csrf_token);
        const session_id = try self.store.rotateUserSession(user_id, &token_hash, &csrf_secret_hash);
        return .{ .id = session_id, .token = token, .csrf_token = csrf_token };
    }

    fn rateKey(prefix: []const u8, value: []const u8) [auth_crypto.encoded_secret_length]u8 {
        return auth_crypto.hashSecretParts(prefix, value);
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
    var service = Service.initForInterface(std.testing.io, std.testing.allocator, &store, .cli);
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
    var service = Service.initForInterface(std.testing.io, std.testing.allocator, &store, .cli);
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

test "manager author and assignment operations enforce scope and audit actors" {
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
    var service = Service.initForInterface(std.testing.io, std.testing.allocator, &store, .cli);
    const owner_id = try service.bootstrapOwner(.{ .subject = "owner", .display_name = "Owner" });
    const owner_session = try service.startSessionForVerifiedSubject("owner");
    try database.exec(
        "INSERT INTO users (subject, display_name) VALUES ('editor', 'Editor')",
        .{},
        .{},
    );
    const editor_id = database.getLastInsertRowID();
    try database.exec("INSERT INTO user_roles (user_id, role) VALUES (?, 'editor')", .{}, .{editor_id});
    try database.exec("INSERT INTO documents (type, created_by) VALUES ('article', ?)", .{}, .{owner_id});
    const document_id = database.getLastInsertRowID();

    const author_id = try service.createAuthor(&owner_session.token, .{
        .display_name = "Ada Lovelace",
        .slug = "ada-lovelace",
        .biography = "Mathematician",
    });
    try service.updateAuthor(&owner_session.token, .{
        .author_id = author_id,
        .display_name = "Ada Byron Lovelace",
        .slug = "ada-lovelace",
        .biography = "Mathematician and writer",
    });
    try database.exec(
        \\INSERT INTO document_versions
        \\    (document_id, version_number, state, slug, title, language, created_by)
        \\    VALUES (?, 1, 'draft', 'draft', 'Draft', 'en', ?)
    ,
        .{},
        .{ document_id, owner_id },
    );
    const version_id = database.getLastInsertRowID();
    const author_ids = [_]i64{author_id};
    try service.setVersionAuthors(&owner_session.token, .{
        .version_id = version_id,
        .author_ids = &author_ids,
        .expected_revision = 0,
    });
    const author_assignment = try service.createAssignment(&owner_session.token, .{
        .editor_user_id = editor_id,
        .scope = .{ .author = author_id },
    });
    try std.testing.expectError(
        error.ActiveAssignmentExists,
        service.createAssignment(&owner_session.token, .{
            .editor_user_id = editor_id,
            .scope = .{ .author = author_id },
        }),
    );
    try service.requireAuthorAccess(&owner_session.token, author_id);
    const editor_session = try service.startSessionForVerifiedSubject("editor");
    try std.testing.expectError(
        error.Forbidden,
        service.createAuthor(&editor_session.token, .{
            .display_name = "Unauthorized",
            .slug = "unauthorized",
        }),
    );
    try std.testing.expectError(
        error.Forbidden,
        service.createAssignment(&editor_session.token, .{
            .editor_user_id = editor_id,
            .scope = .{ .author = author_id },
        }),
    );
    try service.requireAuthorAccess(&editor_session.token, author_id);
    try service.requireVersionAccess(&editor_session.token, version_id);

    const document_assignment = try service.createAssignment(&owner_session.token, .{
        .editor_user_id = editor_id,
        .scope = .{ .document = document_id },
    });
    try service.requireVersionAccess(&editor_session.token, version_id);
    try std.testing.expectError(
        error.StaleAssignment,
        service.revokeAssignment(&owner_session.token, .{
            .assignment_id = author_assignment,
            .expected_revision = 1,
        }),
    );
    try std.testing.expectEqual(@as(i64, 1), try service.revokeAssignment(&owner_session.token, .{
        .assignment_id = author_assignment,
        .expected_revision = 0,
    }));
    try std.testing.expectError(
        error.Forbidden,
        service.requireAuthorAccess(&editor_session.token, author_id),
    );
    try service.requireDocumentAccess(&editor_session.token, document_id);
    _ = try service.revokeAssignment(&owner_session.token, .{
        .assignment_id = document_assignment,
        .expected_revision = 0,
    });
    try std.testing.expectError(
        error.Forbidden,
        service.requireVersionAccess(&editor_session.token, version_id),
    );

    try std.testing.expectEqual(@as(?i64, 7), try database.one(
        i64,
        "SELECT count(*) FROM audit_log WHERE actor_user_id = ?",
        .{},
        .{owner_id},
    ));
    try std.testing.expectEqual(@as(?i64, 4), try database.one(
        i64,
        "SELECT count(*) FROM audit_log WHERE acted_for_author_id = ?",
        .{},
        .{author_id},
    ));
}
