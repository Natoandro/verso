const std = @import("std");
const logging = @import("../logging.zig");
const domain = @import("../domain/document.zig");
const storage = @import("../storage/documents.zig");
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
};

fn authorizeCreateDraft(actor: Actor) !void {
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

test "text section data is escaped as JSON" {
    const data = try buildTextSection(std.testing.allocator, "say \"hello\"");
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("{\"markdown\":\"say \\\"hello\\\"\"}", data);
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
