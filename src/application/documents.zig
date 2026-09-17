const std = @import("std");
const logging = @import("../logging.zig");
const domain = @import("../domain/document.zig");
const section_domain = @import("../domain/sections.zig");
const storage = @import("../storage/documents.zig");
const section_storage = @import("../storage/sections.zig");
const migrations = @import("../storage/migrations.zig");
const sqlite = @import("sqlite");

pub const Actor = enum {
    local_operator,
};

pub const Service = struct {
    allocator: std.mem.Allocator,
    store: *storage.Store,

    pub fn init(allocator: std.mem.Allocator, store: *storage.Store) Service {
        return .{ .allocator = allocator, .store = store };
    }

    pub fn createDraft(
        self: *Service,
        actor: Actor,
        request: domain.CreateDraft,
    ) !domain.Draft {
        try authorizeCreateDraft(actor);
        try domain.validateCreateDraft(request);

        const section_data = try buildTextSection(self.allocator, request.markdown);
        defer self.allocator.free(section_data);
        return self.store.createDraft(request, section_data);
    }

    pub fn insertSection(
        self: *Service,
        actor: Actor,
        request: section_domain.Insert,
    ) !section_storage.MutationResult {
        try authorizeSectionMutation(actor);
        try section_domain.validateInsert(request);
        const data = try encodeSection(self.allocator, request.payload);
        defer self.allocator.free(data);
        return section_storage.insertSection(
            self.store,
            request.version_id,
            request.position,
            request.expected_revision,
            request.payload.kind().name(),
            data,
        );
    }

    pub fn updateSection(
        self: *Service,
        actor: Actor,
        request: section_domain.Update,
    ) !section_storage.MutationResult {
        try authorizeSectionMutation(actor);
        try section_domain.validateUpdate(request);
        const data = try encodeSection(self.allocator, request.payload);
        defer self.allocator.free(data);
        return section_storage.updateSection(
            self.store,
            request.version_id,
            request.section_id,
            request.expected_revision,
            request.payload.kind().name(),
            data,
        );
    }

    pub fn moveSection(
        self: *Service,
        actor: Actor,
        request: section_domain.Move,
    ) !section_storage.MutationResult {
        try authorizeSectionMutation(actor);
        try section_domain.validateMove(request);
        return section_storage.moveSection(
            self.store,
            request.version_id,
            request.section_id,
            request.position,
            request.expected_revision,
        );
    }

    pub fn duplicateSection(
        self: *Service,
        actor: Actor,
        request: section_domain.Duplicate,
    ) !section_storage.MutationResult {
        try authorizeSectionMutation(actor);
        try section_domain.validateDuplicate(request);
        return section_storage.duplicateSection(
            self.store,
            request.version_id,
            request.section_id,
            request.position,
            request.expected_revision,
        );
    }

    pub fn deleteSection(
        self: *Service,
        actor: Actor,
        request: section_domain.Delete,
    ) !section_storage.MutationResult {
        try authorizeSectionMutation(actor);
        try section_domain.validateDelete(request);
        return section_storage.deleteSection(
            self.store,
            request.version_id,
            request.section_id,
            request.expected_revision,
        );
    }
};

fn authorizeCreateDraft(actor: Actor) !void {
    return switch (actor) {
        .local_operator => {},
    };
}

fn authorizeSectionMutation(actor: Actor) !void {
    return switch (actor) {
        .local_operator => {},
    };
}

fn buildTextSection(allocator: std.mem.Allocator, markdown: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try output.writer.print("{f}", .{std.json.fmt(.{ .markdown = markdown }, .{})});
    return output.toOwnedSlice();
}

fn encodeSection(allocator: std.mem.Allocator, payload: section_domain.Payload) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    switch (payload) {
        .text => |text| try output.writer.print("{f}", .{std.json.fmt(text, .{})}),
        .image => |image| {
            const json = struct {
                asset: []const u8,
                alt: []const u8,
                caption: ?[]const u8,
                display: ?[]const u8,
            }{
                .asset = image.asset,
                .alt = image.alt,
                .caption = image.caption,
                .display = if (image.display) |display| display.text() else null,
            };
            try output.writer.print("{f}", .{std.json.fmt(json, .{})});
        },
    }
    return output.toOwnedSlice();
}

test "text section data is escaped as JSON" {
    const data = try buildTextSection(std.testing.allocator, "say \"hello\"");
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("{\"markdown\":\"say \\\"hello\\\"\"}", data);
}

test "image section data is encoded as JSON" {
    const data = try encodeSection(std.testing.allocator, .{ .image = .{
        .asset = "diagram.png",
        .alt = "A diagram",
        .display = .wide,
    } });
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings(
        "{\"asset\":\"diagram.png\",\"alt\":\"A diagram\",\"caption\":null,\"display\":\"wide\"}",
        data,
    );
}

test "createDraft persists document version and text section atomically" {
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
    try std.testing.expectEqual(@as(usize, 1), try migration_context.migrateUp());

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

    var logger = logging.Logger.init(std.testing.allocator, .text);
    var migration_context = migrations.MigrationContext.init(
        std.testing.io,
        std.testing.allocator,
        "migrations",
        &database,
        &logger,
    );
    try std.testing.expectEqual(@as(usize, 1), try migration_context.migrateUp());

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
