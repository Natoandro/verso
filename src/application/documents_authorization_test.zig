const std = @import("std");
const sqlite = @import("sqlite");
const logging = @import("../logging.zig");
const migrations = @import("../storage/migrations.zig");
const document_storage = @import("../storage/documents.zig");
const identity_storage = @import("../storage/identity.zig");
const identity_application = @import("identity.zig");
const documents = @import("documents.zig");

fn migrate(database: *sqlite.Db) !void {
    var logger = logging.Logger.init(std.testing.allocator, .text);
    var migration_context = migrations.MigrationContext.init(
        std.testing.io,
        std.testing.allocator,
        "migrations",
        database,
        &logger,
    );
    _ = try migration_context.migrateUp();
}

test "assigned editors can list, open, and save only assigned drafts" {
    var database = try sqlite.Db.init(.{
        .mode = .Memory,
        .open_flags = .{ .write = true, .create = true },
    });
    defer database.deinit();
    try migrate(&database);

    var identity_store = identity_storage.Store.init(&database);
    var identity_service = identity_application.Service.initForInterface(
        std.testing.io,
        std.testing.allocator,
        &identity_store,
        .web,
    );
    const owner_id = try identity_service.bootstrapOwner(.{
        .subject = "owner",
        .display_name = "Owner",
    });
    try database.exec(
        "INSERT INTO users (subject, display_name) VALUES ('editor', 'Assigned editor'), ('outsider', 'Other editor')",
        .{},
        .{},
    );
    const outsider_id = database.getLastInsertRowID();
    const editor_id = outsider_id - 1;
    try database.exec(
        "INSERT INTO user_roles (user_id, role) VALUES (?, 'editor'), (?, 'editor')",
        .{},
        .{ editor_id, outsider_id },
    );

    var document_store = document_storage.Store.init(&database);
    var document_service = documents.Service.initProtected(
        std.testing.allocator,
        &document_store,
        &identity_service,
    );
    const first = try document_service.createDraft(.{ .user = owner_id }, .{
        .document_type = .article,
        .title = "Assigned draft",
        .slug = "assigned-draft",
        .markdown = "Initial text",
    });
    _ = try document_service.createDraft(.{ .user = owner_id }, .{
        .document_type = .article,
        .title = "Private draft",
        .slug = "private-draft",
        .markdown = "Not assigned",
    });

    const owner_session = try identity_service.startSessionForVerifiedSubject("owner");
    const author_id = try identity_service.createAuthor(&owner_session.token, .{
        .display_name = "Assigned author",
        .slug = "assigned-author",
    });
    const author_ids = [_]i64{author_id};
    try identity_service.setVersionAuthors(&owner_session.token, .{
        .version_id = first.version_id,
        .author_ids = &author_ids,
        .expected_revision = 0,
    });
    _ = try identity_service.createAssignment(&owner_session.token, .{
        .editor_user_id = editor_id,
        .scope = .{ .author = author_id },
    });
    const assigned_drafts = try document_service.listDrafts(.{ .user = editor_id }, std.testing.allocator);
    defer {
        for (assigned_drafts) |*draft| draft.deinit(std.testing.allocator);
        std.testing.allocator.free(assigned_drafts);
    }
    try std.testing.expectEqual(@as(usize, 1), assigned_drafts.len);
    try std.testing.expectEqual(first.document_id, assigned_drafts[0].document_id);

    var loaded = try document_service.loadDraft(.{ .user = editor_id }, first.version_id);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("Initial text", loaded.document.sections[0].payload.text.markdown);

    const stale_sections = loaded.document.sections;
    _ = try document_service.saveDraft(.{ .user = editor_id }, .{
        .document_id = first.document_id,
        .version_id = first.version_id,
        .expected_revision = loaded.document.revision_number,
        .document_type = .article,
        .title = "Updated by editor",
        .slug = "updated-by-editor",
        .language = "en",
        .sections = stale_sections,
    });
    try std.testing.expectError(
        error.StaleRevision,
        document_service.saveDraft(.{ .user = editor_id }, .{
            .document_id = first.document_id,
            .version_id = first.version_id,
            .expected_revision = 0,
            .document_type = .article,
            .title = "Stale update",
            .slug = "stale-update",
            .language = "en",
            .sections = stale_sections,
        }),
    );
    try std.testing.expectError(
        error.Forbidden,
        document_service.loadDraft(.{ .user = outsider_id }, first.version_id),
    );
}

test "assigned draft services refuse immutable published and archived versions" {
    var database = try sqlite.Db.init(.{
        .mode = .Memory,
        .open_flags = .{ .write = true, .create = true },
    });
    defer database.deinit();
    try migrate(&database);

    var identity_store = identity_storage.Store.init(&database);
    var identity_service = identity_application.Service.initForInterface(
        std.testing.io,
        std.testing.allocator,
        &identity_store,
        .web,
    );
    const owner_id = try identity_service.bootstrapOwner(.{ .subject = "owner", .display_name = "Owner" });
    try database.exec("INSERT INTO users (subject, display_name) VALUES ('editor', 'Editor')", .{}, .{});
    const editor_id = database.getLastInsertRowID();
    try database.exec("INSERT INTO user_roles (user_id, role) VALUES (?, 'editor')", .{}, .{editor_id});

    var document_store = document_storage.Store.init(&database);
    var service = documents.Service.initProtected(std.testing.allocator, &document_store, &identity_service);
    const draft = try service.createDraft(.{ .user = owner_id }, .{
        .document_type = .article,
        .title = "Immutable source",
        .slug = "immutable-source",
        .markdown = "Published text",
    });
    const owner_session = try identity_service.startSessionForVerifiedSubject("owner");
    _ = try identity_service.createAssignment(&owner_session.token, .{
        .editor_user_id = editor_id,
        .scope = .{ .document = draft.document_id },
    });

    try database.exec(
        "UPDATE document_versions SET state = 'published', published_at = '2026-01-01T00:00:00Z' WHERE id = ?",
        .{},
        .{draft.version_id},
    );
    try database.exec(
        "UPDATE documents SET current_published_version_id = ? WHERE id = ?",
        .{},
        .{ draft.version_id, draft.document_id },
    );
    try std.testing.expectError(
        error.VersionNotEditable,
        service.loadDraft(.{ .user = editor_id }, draft.version_id),
    );

    try database.exec(
        "UPDATE document_versions SET state = 'archived', archive_accessible = 1 WHERE id = ?",
        .{},
        .{draft.version_id},
    );
    try std.testing.expectError(
        error.VersionNotEditable,
        service.loadDraft(.{ .user = editor_id }, draft.version_id),
    );
}

test "protected document services require an identity service for user actors" {
    var database = try sqlite.Db.init(.{
        .mode = .Memory,
        .open_flags = .{ .write = true, .create = true },
    });
    defer database.deinit();
    try migrate(&database);
    var store = document_storage.Store.init(&database);
    var service = documents.Service.init(std.testing.allocator, &store);
    try std.testing.expectError(
        error.AuthorizationUnavailable,
        service.createDraft(.{ .user = 1 }, .{
            .document_type = .article,
            .title = "No identity",
            .slug = "no-identity",
            .markdown = "",
        }),
    );
}
