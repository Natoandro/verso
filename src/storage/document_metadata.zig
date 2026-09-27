const std = @import("std");
const sqlite = @import("sqlite");

pub fn validateReferences(
    database: *sqlite.Db,
    subject_ids: []const i64,
    series_id: ?i64,
) !void {
    if (series_id) |id| {
        if (try database.one(i64, "SELECT 1 FROM series WHERE id = ?", .{}, .{id}) == null) {
            return error.SeriesNotFound;
        }
    }
    for (subject_ids) |subject_id| {
        if (try database.one(i64, "SELECT 1 FROM subjects WHERE id = ?", .{}, .{subject_id}) == null) {
            return error.SubjectNotFound;
        }
    }
}

pub fn insertSubjectReferences(database: *sqlite.Db, version_id: i64, subject_ids: []const i64) !void {
    for (subject_ids) |subject_id| {
        try database.exec(
            "INSERT INTO version_subjects (version_id, subject_id) VALUES (?, ?)",
            .{},
            .{ version_id, subject_id },
        );
    }
}

pub fn freeVersionRow(allocator: std.mem.Allocator, row: anytype) void {
    allocator.free(row.document_type);
    allocator.free(row.state);
    allocator.free(row.title);
    allocator.free(row.slug);
    if (row.description) |description| allocator.free(description);
    allocator.free(row.language);
}
