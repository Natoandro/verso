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
