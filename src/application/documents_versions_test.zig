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

test "createNextVersion deep copies the published version and preserves source immutability" {
    var database = try sqlite.Db.init(.{
        .mode = .Memory,
        .open_flags = .{ .write = true, .create = true },
    });
    defer database.deinit();
    try migrate(&database);

    var store = storage.Store.init(&database);
    var service = Service.init(std.testing.allocator, &store);
    const source = try service.createDraft(.local_operator, .{
        .document_type = .article,
        .title = "Published source",
        .slug = "published-source",
        .description = "Source description",
        .markdown = "Source text",
    });
    const image = try service.insertSection(.local_operator, .{
        .version_id = source.version_id,
        .position = 1,
        .expected_revision = 0,
        .payload = .{ .image = .{
            .asset = "diagram.png",
            .alt = "A diagram",
            .caption = "Source caption",
            .display = .wide,
        } },
    });

    try database.exec("INSERT INTO series (title, slug) VALUES ('Series', 'series')", .{}, .{});
    const series_id = database.getLastInsertRowID();
    try database.exec("UPDATE document_versions SET series_id = ?, series_position = 2 WHERE id = ?", .{}, .{ series_id, source.version_id });
    try database.exec("INSERT INTO authors (display_name, slug) VALUES ('Ada', 'ada')", .{}, .{});
    const author_id = database.getLastInsertRowID();
    try database.exec("INSERT INTO subjects (name, slug) VALUES ('Zig', 'zig')", .{}, .{});
    const subject_id = database.getLastInsertRowID();
    try database.exec(
        "INSERT INTO assets (object_key, content_type, byte_size, checksum_sha256, extension) VALUES ('sha/diagram.png', 'image/png', 3, ?, 'png')",
        .{},
        .{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
    );
    const asset_id = database.getLastInsertRowID();
    try database.exec("INSERT INTO version_references (version_id, short_name, data) VALUES (?, 'ref', '{\"title\":\"Reference\"}')", .{}, .{source.version_id});
    try database.exec("INSERT INTO version_authors (version_id, author_id, position) VALUES (?, ?, 0)", .{}, .{ source.version_id, author_id });
    try database.exec("INSERT INTO version_subjects (version_id, subject_id) VALUES (?, ?)", .{}, .{ source.version_id, subject_id });
    try database.exec("INSERT INTO version_assets (version_id, asset_id, name) VALUES (?, ?, 'diagram.png')", .{}, .{ source.version_id, asset_id });
    try database.exec(
        "UPDATE document_versions SET state = 'published', published_at = '2026-01-01T00:00:00Z' WHERE id = ?",
        .{},
        .{source.version_id},
    );
    try database.exec(
        "UPDATE documents SET current_published_version_id = ? WHERE id = ?",
        .{},
        .{ source.version_id, source.document_id },
    );

    const next = try service.createNextVersion(.local_operator, .{ .source_version_id = source.version_id });
    try std.testing.expectEqual(source.document_id, next.document_id);
    try std.testing.expectEqual(@as(i64, 2), next.version_number);
    try std.testing.expectEqual(source.version_id, next.based_on_version_id);
    try std.testing.expectEqual(@as(?i64, 1), try database.one(
        i64,
        "SELECT count(*) FROM document_versions WHERE id = ? AND state = 'draft' AND based_on_version_id = ? AND slug = 'published-source' AND series_id = ? AND series_position = 2",
        .{},
        .{ next.version_id, source.version_id, series_id },
    ));
    try std.testing.expectEqual(@as(?i64, 2), try database.one(
        i64,
        "SELECT count(*) FROM sections WHERE version_id = ?",
        .{},
        .{next.version_id},
    ));
    try std.testing.expectEqual(@as(?i64, 1), try database.one(
        i64,
        "SELECT count(*) FROM sections WHERE version_id = ? AND kind = 'image' AND json_extract(data, '$.asset') = 'diagram.png'",
        .{},
        .{next.version_id},
    ));
    const copied_image_id = (try database.one(
        i64,
        "SELECT id FROM sections WHERE version_id = ? AND kind = 'image'",
        .{},
        .{next.version_id},
    )).?;
    try std.testing.expect(copied_image_id != image.section_id);
    try std.testing.expectEqual(@as(?i64, 1), try database.one(i64, "SELECT count(*) FROM version_references WHERE version_id = ?", .{}, .{next.version_id}));
    try std.testing.expectEqual(@as(?i64, 1), try database.one(i64, "SELECT count(*) FROM version_authors WHERE version_id = ? AND author_id = ?", .{}, .{ next.version_id, author_id }));
    try std.testing.expectEqual(@as(?i64, 1), try database.one(i64, "SELECT count(*) FROM version_subjects WHERE version_id = ? AND subject_id = ?", .{}, .{ next.version_id, subject_id }));
    try std.testing.expectEqual(@as(?i64, 1), try database.one(i64, "SELECT count(*) FROM version_assets WHERE version_id = ? AND asset_id = ?", .{}, .{ next.version_id, asset_id }));

    _ = try service.updateSection(.local_operator, .{
        .version_id = next.version_id,
        .section_id = copied_image_id,
        .expected_revision = 0,
        .payload = .{ .image = .{ .asset = "changed.png", .alt = "Changed" } },
    });
    try std.testing.expectEqual(@as(?i64, 1), try database.one(
        i64,
        "SELECT count(*) FROM sections WHERE version_id = ? AND json_extract(data, '$.asset') = 'diagram.png'",
        .{},
        .{source.version_id},
    ));
    try std.testing.expectError(
        error.MutableDraftExists,
        service.createNextVersion(.local_operator, .{ .source_version_id = source.version_id }),
    );
    try std.testing.expectEqual(@as(?i64, 2), try database.one(
        i64,
        "SELECT count(*) FROM document_versions WHERE document_id = ?",
        .{},
        .{source.document_id},
    ));
}

test "createNextVersion rejects unpublished and non-current parents" {
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
        .title = "Draft",
        .slug = "draft",
        .markdown = "Draft",
    });
    try std.testing.expectError(
        error.VersionNotPublished,
        service.createNextVersion(.local_operator, .{ .source_version_id = draft.version_id }),
    );

    const published_without_pointer = try service.createDraft(.local_operator, .{
        .document_type = .article,
        .title = "Published without pointer",
        .slug = "published-without-pointer",
        .markdown = "Published",
    });
    try database.exec(
        "UPDATE document_versions SET state = 'published', published_at = '2026-01-01T00:00:00Z' WHERE id = ?",
        .{},
        .{published_without_pointer.version_id},
    );
    try std.testing.expectError(
        error.NotCurrentPublishedVersion,
        service.createNextVersion(.local_operator, .{ .source_version_id = published_without_pointer.version_id }),
    );
}
