const std = @import("std");
const logging = @import("../logging.zig");
const application = @import("documents.zig");
const storage = @import("../storage/documents.zig");
const migrations = @import("../storage/migrations.zig");
const sqlite = @import("sqlite");

const Service = application.Service;

fn migrate(database: *sqlite.Db) !void {
    var logger = logging.Logger.init(std.testing.allocator, .text);
    var migration_context = migrations.MigrationContext.init(
        std.testing.io,
        std.testing.allocator,
        "migrations",
        database,
        &logger,
    );
    try std.testing.expectEqual(@as(usize, 1), try migration_context.migrateUp());
}

test "section mutations preserve order and reject stale or immutable edits" {
    var database = try sqlite.Db.init(.{
        .mode = .Memory,
        .open_flags = .{ .write = true, .create = true },
    });
    defer database.deinit();
    try migrate(&database);

    var store = storage.Store.init(&database);
    var service = Service.init(std.testing.allocator, &store);
    const draft = try service.createDraft(.local_operator, .{
        .document_type = .article,
        .title = "Sections",
        .slug = "sections",
        .markdown = "first",
    });

    const image = try service.insertSection(.local_operator, .{
        .version_id = draft.version_id,
        .position = 1,
        .expected_revision = 0,
        .payload = .{ .image = .{ .asset = "diagram.png", .alt = "Diagram" } },
    });
    try std.testing.expectEqual(@as(u64, 1), image.revision_number);

    const second_text = try service.insertSection(.local_operator, .{
        .version_id = draft.version_id,
        .position = 1,
        .expected_revision = 1,
        .payload = .{ .text = .{ .markdown = "second" } },
    });
    try expectSectionPosition(&database, draft.version_id, draft.section_id, 0);
    try expectSectionPosition(&database, draft.version_id, second_text.section_id, 1);
    try expectSectionPosition(&database, draft.version_id, image.section_id, 2);

    _ = try service.moveSection(.local_operator, .{
        .version_id = draft.version_id,
        .section_id = image.section_id,
        .position = 0,
        .expected_revision = 2,
    });
    try expectSectionPosition(&database, draft.version_id, image.section_id, 0);
    try expectSectionPosition(&database, draft.version_id, draft.section_id, 1);
    try expectSectionPosition(&database, draft.version_id, second_text.section_id, 2);

    _ = try service.moveSection(.local_operator, .{
        .version_id = draft.version_id,
        .section_id = image.section_id,
        .position = 2,
        .expected_revision = 3,
    });
    try expectSectionPosition(&database, draft.version_id, draft.section_id, 0);
    try expectSectionPosition(&database, draft.version_id, second_text.section_id, 1);
    try expectSectionPosition(&database, draft.version_id, image.section_id, 2);

    const copy = try service.duplicateSection(.local_operator, .{
        .version_id = draft.version_id,
        .section_id = draft.section_id,
        .position = 2,
        .expected_revision = 4,
    });
    try std.testing.expect(copy.section_id != draft.section_id);
    try expectSectionPosition(&database, draft.version_id, draft.section_id, 0);
    try expectSectionPosition(&database, draft.version_id, second_text.section_id, 1);
    try expectSectionPosition(&database, draft.version_id, copy.section_id, 2);
    try expectSectionPosition(&database, draft.version_id, image.section_id, 3);
    try std.testing.expectEqual(@as(?i64, 1), try database.one(
        i64,
        "SELECT count(*) FROM sections WHERE id = ? AND kind = 'text' AND json_extract(data, '$.markdown') = 'first'",
        .{},
        .{copy.section_id},
    ));

    _ = try service.updateSection(.local_operator, .{
        .version_id = draft.version_id,
        .section_id = second_text.section_id,
        .expected_revision = 5,
        .payload = .{ .text = .{ .markdown = "updated" } },
    });
    _ = try service.deleteSection(.local_operator, .{
        .version_id = draft.version_id,
        .section_id = draft.section_id,
        .expected_revision = 6,
    });
    try expectSectionPosition(&database, draft.version_id, second_text.section_id, 0);
    try expectSectionPosition(&database, draft.version_id, copy.section_id, 1);
    try expectSectionPosition(&database, draft.version_id, image.section_id, 2);

    try std.testing.expectError(
        error.StaleRevision,
        service.insertSection(.local_operator, .{
            .version_id = draft.version_id,
            .position = 0,
            .expected_revision = 5,
            .payload = .{ .text = .{ .markdown = "stale" } },
        }),
    );
    try std.testing.expectEqual(@as(?i64, 7), try database.one(
        i64,
        "SELECT revision_number FROM document_versions WHERE id = ?",
        .{},
        .{draft.version_id},
    ));

    try std.testing.expectError(
        error.InvalidPosition,
        service.insertSection(.local_operator, .{
            .version_id = draft.version_id,
            .position = 4,
            .expected_revision = 7,
            .payload = .{ .text = .{ .markdown = "invalid position" } },
        }),
    );
    try database.exec(
        "UPDATE document_versions SET state = 'published', published_at = '2026-01-01T00:00:00Z' WHERE id = ?",
        .{},
        .{draft.version_id},
    );
    try std.testing.expectError(
        error.VersionNotEditable,
        service.deleteSection(.local_operator, .{
            .version_id = draft.version_id,
            .section_id = image.section_id,
            .expected_revision = 7,
        }),
    );
    try database.exec(
        "UPDATE document_versions SET state = 'archived', archive_accessible = 1 WHERE id = ?",
        .{},
        .{draft.version_id},
    );
    try std.testing.expectError(
        error.VersionNotEditable,
        service.moveSection(.local_operator, .{
            .version_id = draft.version_id,
            .section_id = image.section_id,
            .position = 0,
            .expected_revision = 7,
        }),
    );
}

fn expectSectionPosition(database: *sqlite.Db, version_id: i64, section_id: i64, expected: i64) !void {
    try std.testing.expectEqual(@as(?i64, expected), try database.one(
        i64,
        "SELECT position FROM sections WHERE version_id = ? AND id = ?",
        .{},
        .{ version_id, section_id },
    ));
}
