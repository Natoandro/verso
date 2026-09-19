const std = @import("std");
const documents = @import("documents.zig");
const document_access = @import("document_access.zig");

pub const MutationResult = struct {
    section_id: i64,
    revision_number: u64,
};

const VersionSnapshot = struct {
    revision_number: i64,
    section_count: i64,
};

const temporary_position_offset: i64 = 1_000_000_000;

pub fn insertSection(
    store: *documents.Store,
    version_id: i64,
    position: u32,
    expected_revision: u64,
    kind: []const u8,
    data: []const u8,
    actor_user_id: ?i64,
) !MutationResult {
    try store.database.execMulti("BEGIN IMMEDIATE;", .{});
    errdefer store.database.execMulti("ROLLBACK;", .{}) catch {};

    const snapshot = try beginMutation(store, version_id, expected_revision, actor_user_id);
    const target = try toDatabaseInteger(position);
    if (target > snapshot.section_count) return error.InvalidPosition;

    try moveExistingPositionsForInsert(store, version_id, snapshot.section_count, target);
    try store.database.exec(
        "INSERT INTO sections (version_id, position, kind, data) VALUES (?, ?, ?, ?)",
        .{},
        .{ version_id, target, kind, data },
    );
    const section_id = store.database.getLastInsertRowID();
    return try finishMutation(store, version_id, snapshot.revision_number, section_id);
}

pub fn updateSection(
    store: *documents.Store,
    version_id: i64,
    section_id: i64,
    expected_revision: u64,
    kind: []const u8,
    data: []const u8,
    actor_user_id: ?i64,
) !MutationResult {
    try store.database.execMulti("BEGIN IMMEDIATE;", .{});
    errdefer store.database.execMulti("ROLLBACK;", .{}) catch {};

    const snapshot = try beginMutation(store, version_id, expected_revision, actor_user_id);
    try requireSection(store, version_id, section_id);
    try store.database.exec(
        "UPDATE sections SET kind = ?, data = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ? AND version_id = ?",
        .{},
        .{ kind, data, section_id, version_id },
    );
    return try finishMutation(store, version_id, snapshot.revision_number, section_id);
}

pub fn moveSection(
    store: *documents.Store,
    version_id: i64,
    section_id: i64,
    position: u32,
    expected_revision: u64,
    actor_user_id: ?i64,
) !MutationResult {
    try store.database.execMulti("BEGIN IMMEDIATE;", .{});
    errdefer store.database.execMulti("ROLLBACK;", .{}) catch {};

    const snapshot = try beginMutation(store, version_id, expected_revision, actor_user_id);
    const current_position = try sectionPosition(store, version_id, section_id);
    const target = try toDatabaseInteger(position);
    if (target >= snapshot.section_count) return error.InvalidPosition;

    try store.database.exec(
        "UPDATE sections SET position = position + ? WHERE version_id = ?",
        .{},
        .{ temporary_position_offset, version_id },
    );
    try normalizeAfterMove(
        store,
        version_id,
        current_position,
        target,
    );
    return try finishMutation(store, version_id, snapshot.revision_number, section_id);
}

pub fn duplicateSection(
    store: *documents.Store,
    version_id: i64,
    section_id: i64,
    position: u32,
    expected_revision: u64,
    actor_user_id: ?i64,
) !MutationResult {
    try store.database.execMulti("BEGIN IMMEDIATE;", .{});
    errdefer store.database.execMulti("ROLLBACK;", .{}) catch {};

    const snapshot = try beginMutation(store, version_id, expected_revision, actor_user_id);
    try requireSection(store, version_id, section_id);
    const target = try toDatabaseInteger(position);
    if (target > snapshot.section_count) return error.InvalidPosition;

    try moveExistingPositionsForInsert(store, version_id, snapshot.section_count, target);
    try store.database.exec(
        \\INSERT INTO sections (version_id, position, kind, data)
        \\    SELECT version_id, ?, kind, data FROM sections WHERE id = ? AND version_id = ?
    ,
        .{},
        .{ target, section_id, version_id },
    );
    const duplicate_id = store.database.getLastInsertRowID();
    return try finishMutation(store, version_id, snapshot.revision_number, duplicate_id);
}

pub fn deleteSection(
    store: *documents.Store,
    version_id: i64,
    section_id: i64,
    expected_revision: u64,
    actor_user_id: ?i64,
) !MutationResult {
    try store.database.execMulti("BEGIN IMMEDIATE;", .{});
    errdefer store.database.execMulti("ROLLBACK;", .{}) catch {};

    const snapshot = try beginMutation(store, version_id, expected_revision, actor_user_id);
    const current_position = try sectionPosition(store, version_id, section_id);

    try store.database.exec(
        "UPDATE sections SET position = position + ? WHERE version_id = ?",
        .{},
        .{ temporary_position_offset, version_id },
    );
    try store.database.exec(
        "DELETE FROM sections WHERE id = ? AND version_id = ?",
        .{},
        .{ section_id, version_id },
    );
    try normalizeAfterDelete(store, version_id, current_position);
    return try finishMutation(store, version_id, snapshot.revision_number, section_id);
}

fn beginMutation(
    store: *documents.Store,
    version_id: i64,
    expected_revision: u64,
    actor_user_id: ?i64,
) !VersionSnapshot {
    if (try store.database.one(i64, "SELECT 1 FROM document_versions WHERE id = ?", .{}, .{version_id}) == null) {
        return error.VersionNotFound;
    }
    if (try store.database.one(
        i64,
        "SELECT 1 FROM document_versions WHERE id = ? AND state IN ('draft', 'review')",
        .{},
        .{version_id},
    ) == null) return error.VersionNotEditable;
    if (actor_user_id) |user_id| {
        if (!try document_access.hasVersionUpdateAccess(store.database, user_id, version_id)) {
            return error.Forbidden;
        }
    }

    const revision_number = (try store.database.one(
        i64,
        "SELECT revision_number FROM document_versions WHERE id = ?",
        .{},
        .{version_id},
    )).?;
    const expected = std.math.cast(i64, expected_revision) orelse return error.InvalidRevision;
    if (revision_number != expected) return error.StaleRevision;
    const section_count = (try store.database.one(
        i64,
        "SELECT count(*) FROM sections WHERE version_id = ?",
        .{},
        .{version_id},
    )).?;
    return .{ .revision_number = revision_number, .section_count = section_count };
}

fn finishMutation(
    store: *documents.Store,
    version_id: i64,
    previous_revision: i64,
    section_id: i64,
) !MutationResult {
    const next_revision = std.math.add(i64, previous_revision, 1) catch return error.RevisionOverflow;
    try store.database.exec(
        "UPDATE document_versions SET revision_number = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?",
        .{},
        .{ next_revision, version_id },
    );
    try store.database.execMulti("COMMIT;", .{});
    return .{
        .section_id = section_id,
        .revision_number = @intCast(next_revision),
    };
}

fn requireSection(store: *documents.Store, version_id: i64, section_id: i64) !void {
    if (try store.database.one(
        i64,
        "SELECT 1 FROM sections WHERE id = ? AND version_id = ?",
        .{},
        .{ section_id, version_id },
    ) == null) return error.SectionNotFound;
}

fn sectionPosition(store: *documents.Store, version_id: i64, section_id: i64) !i64 {
    return (try store.database.one(
        i64,
        "SELECT position FROM sections WHERE id = ? AND version_id = ?",
        .{},
        .{ section_id, version_id },
    )) orelse error.SectionNotFound;
}

fn moveExistingPositionsForInsert(
    store: *documents.Store,
    version_id: i64,
    section_count: i64,
    target: i64,
) !void {
    const offset = try temporaryOffset(section_count);
    try store.database.exec(
        "UPDATE sections SET position = position + ? WHERE version_id = ?",
        .{},
        .{ offset, version_id },
    );
    try store.database.exec(
        \\UPDATE sections
        \\    SET position = position - ? + CASE WHEN position - ? >= ? THEN 1 ELSE 0 END
        \\    WHERE version_id = ? AND position >= ?
    ,
        .{},
        .{ offset, offset, target, version_id, offset },
    );
}

fn normalizeAfterMove(
    store: *documents.Store,
    version_id: i64,
    current: i64,
    target: i64,
) !void {
    const offset = temporary_position_offset;
    try store.database.exec(
        \\UPDATE sections SET position = CASE
        \\    WHEN position = ? + ? THEN ?
        \\    WHEN ? < ? AND position > ? + ? AND position <= ? + ? THEN position - ? - 1
        \\    WHEN ? < ? AND position >= ? + ? AND position < ? + ? THEN position - ? + 1
        \\    ELSE position - ? END WHERE version_id = ?
    ,
        .{},
        .{
            offset,     current, target,
            current,    target,  offset,
            current,    offset,  target,
            offset,     target,  current,
            offset,     target,  offset,
            current,    offset,  offset,
            version_id,
        },
    );
}

fn normalizeAfterDelete(store: *documents.Store, version_id: i64, current: i64) !void {
    const offset = temporary_position_offset;
    try store.database.exec(
        \\UPDATE sections
        \\    SET position = position - ? - CASE WHEN position - ? > ? THEN 1 ELSE 0 END
        \\    WHERE version_id = ?
    ,
        .{},
        .{ offset, offset, current, version_id },
    );
}

fn temporaryOffset(section_count: i64) !i64 {
    if (section_count >= temporary_position_offset) return error.SectionLimitExceeded;
    return temporary_position_offset;
}

fn toDatabaseInteger(value: u32) !i64 {
    return std.math.cast(i64, value) orelse error.InvalidPosition;
}
