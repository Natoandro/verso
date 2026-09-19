const std = @import("std");
const domain = @import("../domain/document.zig");
const documents = @import("documents.zig");

pub fn createNextVersion(
    store: *documents.Store,
    allocator: std.mem.Allocator,
    request: domain.CreateNextVersion,
    created_by: ?i64,
) !domain.NextVersion {
    const SourceVersion = struct {
        document_id: i64,
        version_number: i64,
        state: []const u8,
        slug: []const u8,
        title: []const u8,
        description: ?[]const u8,
        language: []const u8,
        series_id: ?i64,
        series_position: ?i64,
        current_published_version_id: ?i64,
        finalized_at: ?[]const u8,
    };

    try store.database.execMulti("BEGIN IMMEDIATE;", .{});
    errdefer store.database.execMulti("ROLLBACK;", .{}) catch {};

    const source = (try store.database.oneAlloc(
        SourceVersion,
        allocator,
        \\SELECT version.document_id, version.version_number, version.state,
        \\       version.slug, version.title, version.description, version.language,
        \\       version.series_id, version.series_position,
        \\       document.current_published_version_id, document.finalized_at
        \\FROM document_versions AS version
        \\JOIN documents AS document ON document.id = version.document_id
        \\WHERE version.id = ?
    ,
        .{},
        .{request.source_version_id},
    )) orelse return error.VersionNotFound;
    defer freeSource(allocator, source);

    if (!std.mem.eql(u8, source.state, "published")) return error.VersionNotPublished;
    if (source.current_published_version_id != request.source_version_id) {
        return error.NotCurrentPublishedVersion;
    }
    if (source.finalized_at != null) return error.DocumentFinalized;
    if (try store.database.one(
        i64,
        "SELECT 1 FROM document_versions WHERE document_id = ? AND state IN ('draft', 'review') LIMIT 1",
        .{},
        .{source.document_id},
    ) != null) return error.MutableDraftExists;

    const next_version_number = std.math.add(i64, source.version_number, 1) catch {
        return error.VersionNumberOverflow;
    };
    const next_version_number_u32 = std.math.cast(u32, next_version_number) orelse {
        return error.VersionNumberOverflow;
    };
    try store.database.exec(
        \\INSERT INTO document_versions
        \\    (document_id, version_number, based_on_version_id, state, slug, title,
        \\     description, language, series_id, series_position, created_by)
        \\    VALUES (?, ?, ?, 'draft', ?, ?, ?, ?, ?, ?, ?)
    ,
        .{},
        .{
            source.document_id,
            next_version_number,
            request.source_version_id,
            source.slug,
            source.title,
            source.description,
            source.language,
            source.series_id,
            source.series_position,
            created_by,
        },
    );
    const version_id = store.database.getLastInsertRowID();

    try store.database.exec(
        \\INSERT INTO sections (version_id, position, kind, data)
        \\    SELECT ?, position, kind, data
        \\    FROM sections WHERE version_id = ? ORDER BY position
    ,
        .{},
        .{ version_id, request.source_version_id },
    );
    try store.database.exec(
        \\INSERT INTO version_references (version_id, short_name, data)
        \\    SELECT ?, short_name, data
        \\    FROM version_references WHERE version_id = ?
    ,
        .{},
        .{ version_id, request.source_version_id },
    );
    try store.database.exec(
        \\INSERT INTO version_authors (version_id, author_id, position)
        \\    SELECT ?, author_id, position
        \\    FROM version_authors WHERE version_id = ? ORDER BY position
    ,
        .{},
        .{ version_id, request.source_version_id },
    );
    try store.database.exec(
        \\INSERT INTO version_subjects (version_id, subject_id)
        \\    SELECT ?, subject_id
        \\    FROM version_subjects WHERE version_id = ?
    ,
        .{},
        .{ version_id, request.source_version_id },
    );
    try store.database.exec(
        \\INSERT INTO version_assets (version_id, asset_id, name)
        \\    SELECT ?, asset_id, name
        \\    FROM version_assets WHERE version_id = ?
    ,
        .{},
        .{ version_id, request.source_version_id },
    );

    try store.database.execMulti("COMMIT;", .{});
    return .{
        .document_id = source.document_id,
        .version_id = version_id,
        .version_number = next_version_number_u32,
        .based_on_version_id = request.source_version_id,
        .state = .draft,
    };
}

fn freeSource(allocator: std.mem.Allocator, source: anytype) void {
    allocator.free(source.state);
    allocator.free(source.slug);
    allocator.free(source.title);
    allocator.free(source.language);
    if (source.description) |description| allocator.free(description);
    if (source.finalized_at) |finalized_at| allocator.free(finalized_at);
}
