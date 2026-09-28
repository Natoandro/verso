const std = @import("std");
const logging = @import("../logging.zig");
const storage = @import("../storage/identity.zig");
const migrations = @import("../storage/migrations.zig");
const identity = @import("identity.zig");

test "owner bootstrap, session lifecycle, CSRF, and capability checks share the service" {
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
    var service = identity.Service.initForInterface(std.testing.io, std.testing.allocator, &store, .cli);
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
    var service = identity.Service.initForInterface(std.testing.io, std.testing.allocator, &store, .cli);
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
    var service = identity.Service.initForInterface(std.testing.io, std.testing.allocator, &store, .cli);
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
