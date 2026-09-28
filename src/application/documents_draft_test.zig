const std = @import("std");
const logging = @import("../logging.zig");
const application = @import("documents.zig");
const domain = @import("../domain/document.zig");
const section_domain = @import("../domain/sections.zig");
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

test "draft save and load round-trip atomically with revision checks" {
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
        .title = "Round trip",
        .slug = "round-trip",
        .description = "Before save",
        .markdown = "initial",
    });

    var loaded = try service.loadDraft(.local_operator, draft.version_id);
    errdefer loaded.deinit();
    try std.testing.expectEqual(@as(u64, 0), loaded.document.revision_number);
    try std.testing.expectEqualStrings("initial", loaded.document.sections[0].payload.text.markdown);

    const sections = [_]domain.DraftSection{
        .{ .id = draft.section_id, .payload = .{ .text = .{ .markdown = "saved" } } },
        .{ .payload = .{ .image = .{
            .asset = "diagram.png",
            .alt = "A diagram",
            .caption = "Saved image",
            .display = .wide,
        } } },
    };
    const saved = try service.saveDraft(.local_operator, .{
        .document_id = draft.document_id,
        .version_id = draft.version_id,
        .expected_revision = loaded.document.revision_number,
        .document_type = .article,
        .title = "Saved title",
        .slug = "saved-title",
        .description = "After save",
        .language = "en",
        .sections = &sections,
    });
    try std.testing.expectEqual(@as(u64, 1), saved.revision_number);
    loaded.deinit();

    var saved_document = try service.loadDraft(.local_operator, draft.version_id);
    errdefer saved_document.deinit();
    try std.testing.expectEqualStrings("Saved title", saved_document.document.title);
    try std.testing.expectEqualStrings("After save", saved_document.document.description.?);
    try std.testing.expectEqual(@as(usize, 2), saved_document.document.sections.len);
    try std.testing.expectEqualStrings("saved", saved_document.document.sections[0].payload.text.markdown);
    try std.testing.expectEqualStrings("diagram.png", saved_document.document.sections[1].payload.image.asset);
    try std.testing.expectEqual(section_domain.ImageDisplay.wide, saved_document.document.sections[1].payload.image.display.?);

    const repeated_sections = [_]domain.DraftSection{
        .{ .id = saved_document.document.sections[0].id, .payload = .{ .text = .{ .markdown = "saved twice" } } },
        .{ .id = saved_document.document.sections[1].id, .payload = .{ .image = .{
            .asset = "diagram.png",
            .alt = "A diagram",
            .caption = "Saved image twice",
            .display = .full,
        } } },
    };
    const repeated = try service.saveDraft(.local_operator, .{
        .document_id = draft.document_id,
        .version_id = draft.version_id,
        .expected_revision = saved_document.document.revision_number,
        .document_type = .article,
        .title = "Saved twice",
        .slug = "saved-twice",
        .description = "After the second save",
        .sections = &repeated_sections,
    });
    try std.testing.expectEqual(@as(u64, 2), repeated.revision_number);
    saved_document.deinit();

    var repeated_document = try service.loadDraft(.local_operator, draft.version_id);
    defer repeated_document.deinit();
    try std.testing.expectEqual(@as(u64, 2), repeated_document.document.revision_number);
    try std.testing.expectEqualStrings("saved twice", repeated_document.document.sections[0].payload.text.markdown);
    try std.testing.expectEqual(section_domain.ImageDisplay.full, repeated_document.document.sections[1].payload.image.display.?);

    try std.testing.expectError(
        error.StaleRevision,
        service.saveDraft(.local_operator, .{
            .document_id = draft.document_id,
            .version_id = draft.version_id,
            .expected_revision = 0,
            .document_type = .article,
            .title = "Stale title",
            .slug = "stale-title",
            .sections = &sections,
        }),
    );
    try std.testing.expectEqual(@as(?i64, 2), try database.one(
        i64,
        "SELECT revision_number FROM document_versions WHERE id = ?",
        .{},
        .{draft.version_id},
    ));

    const other_draft = try service.createDraft(.local_operator, .{
        .document_type = .article,
        .title = "Other",
        .slug = "other",
        .markdown = "other",
    });
    const invalid_sections = [_]domain.DraftSection{
        .{ .id = other_draft.section_id, .payload = .{ .text = .{ .markdown = "wrong owner" } } },
    };
    try std.testing.expectError(
        error.SectionBelongsToAnotherVersion,
        service.saveDraft(.local_operator, .{
            .document_id = draft.document_id,
            .version_id = draft.version_id,
            .expected_revision = 2,
            .document_type = .article,
            .title = "Must roll back",
            .slug = "must-roll-back",
            .sections = &invalid_sections,
        }),
    );
    try std.testing.expectEqual(@as(?i64, 1), try database.one(
        i64,
        "SELECT count(*) FROM sections WHERE version_id = ? AND json_extract(data, '$.markdown') = 'saved twice'",
        .{},
        .{draft.version_id},
    ));
}

test "createDraft persists document version and text section atomically" {
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
        .title = "A bootstrap draft",
        .slug = "a-bootstrap-draft",
        .markdown = "# Hello\n\nThis is a draft.",
    });

    try std.testing.expectEqual(@as(i64, 1), draft.document_id);
    try std.testing.expectEqual(@as(i64, 1), draft.version_id);
    try std.testing.expectEqual(@as(i64, 1), draft.section_id);
    try std.testing.expectEqual(@as(?i64, 1), try database.one(
        i64,
        "SELECT count(*) FROM document_versions WHERE document_id = ? AND version_number = 1 AND state = 'draft'",
        .{},
        .{draft.document_id},
    ));
    try std.testing.expectEqual(@as(?i64, 1), try database.one(
        i64,
        "SELECT count(*) FROM sections WHERE version_id = ? AND position = 0 AND kind = 'text' AND json_extract(data, '$.markdown') = ?",
        .{},
        .{ draft.version_id, "# Hello\n\nThis is a draft." },
    ));

    const duplicate = domain.CreateDraft{
        .document_id = draft.document_id,
        .document_type = .article,
        .title = "Another title",
        .slug = "another-title",
        .markdown = "Another body",
    };
    try std.testing.expectError(
        error.MutableDraftExists,
        service.createDraft(.local_operator, duplicate),
    );
    try std.testing.expectEqual(@as(?i64, 1), try database.one(
        i64,
        "SELECT count(*) FROM documents",
        .{},
        .{},
    ));
}

test "draft metadata persists subject and series relationships through save and load" {
    var database = try sqlite.Db.init(.{
        .mode = .Memory,
        .open_flags = .{ .write = true, .create = true },
    });
    defer database.deinit();
    try migrate(&database);

    try database.exec("INSERT INTO series (title, slug) VALUES ('A Series', 'a-series')", .{}, .{});
    const series_id = database.getLastInsertRowID();
    try database.exec("INSERT INTO subjects (name, slug) VALUES ('Zig', 'zig')", .{}, .{});
    const zig_subject_id = database.getLastInsertRowID();
    try database.exec("INSERT INTO subjects (name, slug) VALUES ('SQLite', 'sqlite')", .{}, .{});
    const sqlite_subject_id = database.getLastInsertRowID();

    var store = storage.Store.init(&database);
    var service = Service.init(std.testing.allocator, &store);
    const subject_ids = [_]i64{zig_subject_id};
    try std.testing.expectError(
        error.SubjectNotFound,
        service.createDraft(.local_operator, .{
            .document_type = .article,
            .title = "Invalid metadata",
            .slug = "invalid-metadata",
            .subject_ids = &[_]i64{9999},
            .markdown = "body",
        }),
    );
    try std.testing.expectError(
        error.SeriesNotFound,
        service.createDraft(.local_operator, .{
            .document_type = .article,
            .title = "Invalid series",
            .slug = "invalid-series",
            .series_id = 9999,
            .series_position = 1,
            .markdown = "body",
        }),
    );
    try std.testing.expectEqual(@as(?i64, 0), try database.one(i64, "SELECT count(*) FROM documents", .{}, .{}));

    const draft = try service.createDraft(.local_operator, .{
        .document_type = .article,
        .title = "Metadata",
        .slug = "metadata",
        .subject_ids = &subject_ids,
        .series_id = series_id,
        .series_position = 2,
        .markdown = "body",
    });

    var loaded = try service.loadDraft(.local_operator, draft.version_id);
    try std.testing.expectEqual(series_id, loaded.document.series_id.?);
    try std.testing.expectEqual(@as(?u32, 2), loaded.document.series_position);
    try std.testing.expectEqualSlices(i64, &subject_ids, loaded.document.subject_ids);

    const replacement_subject_ids = [_]i64{sqlite_subject_id};
    _ = try service.saveDraft(.local_operator, .{
        .document_id = draft.document_id,
        .version_id = draft.version_id,
        .expected_revision = loaded.document.revision_number,
        .document_type = .article,
        .title = "Updated metadata",
        .slug = "updated-metadata",
        .subject_ids = &replacement_subject_ids,
        .series_id = series_id,
        .series_position = 3,
        .sections = loaded.document.sections,
    });
    loaded.deinit();

    var updated = try service.loadDraft(.local_operator, draft.version_id);
    defer updated.deinit();
    try std.testing.expectEqualStrings("Updated metadata", updated.document.title);
    try std.testing.expectEqual(@as(?u32, 3), updated.document.series_position);
    try std.testing.expectEqualSlices(i64, &replacement_subject_ids, updated.document.subject_ids);
    try std.testing.expectError(
        error.SubjectNotFound,
        service.saveDraft(.local_operator, .{
            .document_id = draft.document_id,
            .version_id = draft.version_id,
            .expected_revision = updated.document.revision_number,
            .document_type = .article,
            .title = "Must roll back",
            .slug = "must-roll-back",
            .subject_ids = &[_]i64{9999},
            .series_id = series_id,
            .series_position = 4,
            .sections = updated.document.sections,
        }),
    );
    try std.testing.expectEqualSlices(i64, &replacement_subject_ids, updated.document.subject_ids);
    try std.testing.expectEqual(@as(?i64, 1), try database.one(
        i64,
        "SELECT revision_number FROM document_versions WHERE id = ?",
        .{},
        .{draft.version_id},
    ));
    try std.testing.expectEqual(@as(?i64, 1), try database.one(
        i64,
        "SELECT count(*) FROM document_versions WHERE id = ? AND title = ?",
        .{},
        .{ draft.version_id, "Updated metadata" },
    ));
    try std.testing.expectEqual(@as(?i64, series_id), try database.one(
        i64,
        "SELECT series_id FROM document_versions WHERE id = ?",
        .{},
        .{draft.version_id},
    ));
    try std.testing.expectEqual(@as(?i64, 1), try database.one(
        i64,
        "SELECT count(*) FROM version_subjects WHERE version_id = ? AND subject_id = ?",
        .{},
        .{ draft.version_id, sqlite_subject_id },
    ));
}
