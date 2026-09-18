const std = @import("std");
const sqlite = @import("sqlite");

pub const Store = struct {
    database: *sqlite.Db,

    pub const AuthorRecord = struct {
        id: i64,
        display_name: sqlite.Text,
        slug: sqlite.Text,
        biography: sqlite.Text,
    };

    pub const EditorRecord = struct {
        id: i64,
        display_name: sqlite.Text,
    };

    pub const AssignmentRecord = struct {
        id: i64,
        editor_user_id: i64,
        editor_display_name: sqlite.Text,
        scope_kind: sqlite.Text,
        scope_id: i64,
        scope_name: sqlite.Text,
        revision_number: i64,
    };

    pub fn init(database: *sqlite.Db) Store {
        return .{ .database = database };
    }

    pub fn listAuthors(self: *Store, allocator: std.mem.Allocator) ![]AuthorRecord {
        var statement = try self.database.prepare(
            \\SELECT id, display_name, slug, COALESCE(biography, '')
            \\FROM authors ORDER BY display_name COLLATE NOCASE, id
        );
        defer statement.deinit();
        return statement.all(AuthorRecord, allocator, .{}, .{});
    }

    pub fn freeAuthors(allocator: std.mem.Allocator, rows: []AuthorRecord) void {
        for (rows) |row| {
            allocator.free(row.display_name.data);
            allocator.free(row.slug.data);
            allocator.free(row.biography.data);
        }
        allocator.free(rows);
    }

    pub fn listEditors(self: *Store, allocator: std.mem.Allocator) ![]EditorRecord {
        var statement = try self.database.prepare(
            \\SELECT user.id, user.display_name
            \\FROM users AS user JOIN user_roles AS role
            \\    ON role.user_id = user.id AND role.role = 'editor'
            \\WHERE user.state = 'active'
            \\ORDER BY user.display_name COLLATE NOCASE, user.id
        );
        defer statement.deinit();
        return statement.all(EditorRecord, allocator, .{}, .{});
    }

    pub fn freeEditors(allocator: std.mem.Allocator, rows: []EditorRecord) void {
        for (rows) |row| allocator.free(row.display_name.data);
        allocator.free(rows);
    }

    pub fn listActiveAssignments(self: *Store, allocator: std.mem.Allocator) ![]AssignmentRecord {
        var statement = try self.database.prepare(
            \\SELECT assignment.id, assignment.editor_user_id, editor.display_name,
            \\    CASE WHEN assignment.author_id IS NOT NULL THEN 'author' ELSE 'document' END,
            \\    COALESCE(assignment.author_id, assignment.document_id),
            \\    COALESCE(author.display_name, printf('Document #%lld', assignment.document_id)),
            \\    assignment.revision_number
            \\FROM editor_assignments AS assignment
            \\JOIN users AS editor ON editor.id = assignment.editor_user_id
            \\LEFT JOIN authors AS author ON author.id = assignment.author_id
            \\WHERE assignment.revoked_at IS NULL
            \\ORDER BY editor.display_name COLLATE NOCASE, assignment.id
        );
        defer statement.deinit();
        return statement.all(AssignmentRecord, allocator, .{}, .{});
    }

    pub fn freeAssignments(allocator: std.mem.Allocator, rows: []AssignmentRecord) void {
        for (rows) |row| {
            allocator.free(row.editor_display_name.data);
            allocator.free(row.scope_kind.data);
            allocator.free(row.scope_name.data);
        }
        allocator.free(rows);
    }
};
