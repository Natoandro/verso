const std = @import("std");
const identity = @import("identity.zig");
const storage = @import("../storage/identity.zig");
const query_storage = @import("../storage/identity_queries.zig");

pub const Snapshot = struct {
    authors: []query_storage.Store.AuthorRecord,
    editors: []query_storage.Store.EditorRecord,
    assignments: []query_storage.Store.AssignmentRecord,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Snapshot) void {
        query_storage.Store.freeAuthors(self.allocator, self.authors);
        query_storage.Store.freeEditors(self.allocator, self.editors);
        query_storage.Store.freeAssignments(self.allocator, self.assignments);
        self.* = undefined;
    }
};

pub const Service = struct {
    allocator: std.mem.Allocator,
    store: *query_storage.Store,
    identity_service: *identity.Service,

    pub fn init(
        allocator: std.mem.Allocator,
        store: *query_storage.Store,
        identity_service: *identity.Service,
    ) Service {
        return .{
            .allocator = allocator,
            .store = store,
            .identity_service = identity_service,
        };
    }

    pub fn list(self: *Service, token: []const u8) !Snapshot {
        try self.identity_service.requireCapability(token, .author_manage);
        try self.identity_service.requireCapability(token, .document_assign_editor);

        const authors = try self.store.listAuthors(self.allocator);
        errdefer query_storage.Store.freeAuthors(self.allocator, authors);
        const editors = try self.store.listEditors(self.allocator);
        errdefer query_storage.Store.freeEditors(self.allocator, editors);
        const assignments = try self.store.listActiveAssignments(self.allocator);
        errdefer query_storage.Store.freeAssignments(self.allocator, assignments);

        return .{
            .authors = authors,
            .editors = editors,
            .assignments = assignments,
            .allocator = self.allocator,
        };
    }
};

test "manager listings include active assignments and deny non-managers" {
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
    var identity_service = identity.Service.initForInterface(
        std.testing.io,
        std.testing.allocator,
        &store,
        .web,
    );
    _ = try identity_service.bootstrapOwner(.{
        .subject = "owner",
        .display_name = "Owner",
    });
    const owner_session = try identity_service.startSessionForVerifiedSubject("owner");
    try database.exec(
        "INSERT INTO users (subject, display_name) VALUES ('editor', 'Editor')",
        .{},
        .{},
    );
    const editor_id = database.getLastInsertRowID();
    try database.exec(
        "INSERT INTO user_roles (user_id, role) VALUES (?, 'editor')",
        .{},
        .{editor_id},
    );
    const author_id = try identity_service.createAuthor(&owner_session.token, .{
        .display_name = "Ada Lovelace",
        .slug = "ada-lovelace",
    });
    _ = try identity_service.createAssignment(&owner_session.token, .{
        .editor_user_id = editor_id,
        .scope = .{ .author = author_id },
    });
    var query_store = query_storage.Store.init(&database);
    var management_service = Service.init(std.testing.allocator, &query_store, &identity_service);
    var snapshot = try management_service.list(&owner_session.token);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 1), snapshot.authors.len);
    try std.testing.expectEqual(@as(usize, 1), snapshot.editors.len);
    try std.testing.expectEqual(@as(usize, 1), snapshot.assignments.len);
    try std.testing.expectEqualStrings("Ada Lovelace", snapshot.authors[0].display_name.data);
    try std.testing.expectEqualStrings("author", snapshot.assignments[0].scope_kind.data);

    const editor_session = try identity_service.startSessionForVerifiedSubject("editor");
    try std.testing.expectError(error.Forbidden, management_service.list(&editor_session.token));
}
