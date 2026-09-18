const sqlite = @import("sqlite");
const domain = @import("../domain/document.zig");
const std = @import("std");

pub const EncodedSection = struct {
    id: ?i64,
    kind: []const u8,
    data: []const u8,
};

pub const SectionRecord = struct {
    id: i64,
    position: i64,
    kind: []const u8,
    data: []const u8,
};

pub const DraftRecord = struct {
    document_id: i64,
    version_id: i64,
    version_number: i64,
    revision_number: i64,
    document_type: []const u8,
    title: []const u8,
    slug: []const u8,
    description: ?[]const u8,
    language: []const u8,
    sections: []SectionRecord,

    pub fn deinit(self: *DraftRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.document_type);
        allocator.free(self.title);
        allocator.free(self.slug);
        if (self.description) |description| allocator.free(description);
        allocator.free(self.language);
        for (self.sections) |section| {
            allocator.free(section.kind);
            allocator.free(section.data);
        }
        allocator.free(self.sections);
        self.* = undefined;
    }
};

pub const Store = struct {
    database: *sqlite.Db,

    pub fn init(database: *sqlite.Db) Store {
        return .{ .database = database };
    }

    pub fn createDraft(
        self: *Store,
        request: domain.CreateDraft,
        section_data: []const u8,
    ) !domain.Draft {
        try self.database.execMulti("BEGIN IMMEDIATE;", .{});
        errdefer self.database.execMulti("ROLLBACK;", .{}) catch {};

        const document_id = request.document_id orelse blk: {
            try self.database.exec(
                "INSERT INTO documents (type) VALUES (?)",
                .{},
                .{request.document_type.text()},
            );
            break :blk self.database.getLastInsertRowID();
        };

        if (request.document_id != null) {
            if (try self.database.one(
                i64,
                "SELECT 1 FROM documents WHERE id = ?",
                .{},
                .{document_id},
            ) == null) return error.DocumentNotFound;
            if (try self.database.one(
                i64,
                "SELECT 1 FROM documents WHERE id = ? AND type = ?",
                .{},
                .{ document_id, request.document_type.text() },
            ) == null) return error.DocumentTypeMismatch;
            if (try self.database.one(
                i64,
                "SELECT 1 FROM document_versions WHERE document_id = ? AND state IN ('draft', 'review') LIMIT 1",
                .{},
                .{document_id},
            ) != null) return error.MutableDraftExists;
            if (try self.database.one(
                i64,
                "SELECT 1 FROM document_versions WHERE document_id = ? LIMIT 1",
                .{},
                .{document_id},
            ) != null) return error.DocumentAlreadyStarted;
        }

        try self.database.exec(
            \\INSERT INTO document_versions
            \\    (document_id, version_number, state, slug, title, description, language)
            \\    VALUES (?, 1, 'draft', ?, ?, ?, ?)
        ,
            .{},
            .{ document_id, request.slug, request.title, request.description, request.language },
        );
        const version_id = self.database.getLastInsertRowID();

        try self.database.exec(
            "INSERT INTO sections (version_id, position, kind, data) VALUES (?, 0, 'text', ?)",
            .{},
            .{ version_id, section_data },
        );
        const section_id = self.database.getLastInsertRowID();

        try self.database.execMulti("COMMIT;", .{});
        return .{
            .document_id = document_id,
            .version_id = version_id,
            .section_id = section_id,
            .version_number = 1,
            .state = .draft,
        };
    }

    pub fn saveDraft(
        self: *Store,
        request: domain.SaveDraft,
        encoded_sections: []const EncodedSection,
    ) !domain.SaveResult {
        if (request.sections.len != encoded_sections.len) return error.InvalidSectionData;

        try self.database.execMulti("BEGIN IMMEDIATE;", .{});
        errdefer self.database.execMulti("ROLLBACK;", .{}) catch {};

        if (try self.database.one(
            i64,
            "SELECT 1 FROM document_versions WHERE id = ? AND document_id = ?",
            .{},
            .{ request.version_id, request.document_id },
        ) == null) return error.VersionNotFound;
        if (try self.database.one(
            i64,
            "SELECT 1 FROM document_versions WHERE id = ? AND state IN ('draft', 'review')",
            .{},
            .{request.version_id},
        ) == null) return error.VersionNotEditable;
        if (try self.database.one(
            i64,
            "SELECT 1 FROM documents WHERE id = ? AND type = ?",
            .{},
            .{ request.document_id, request.document_type.text() },
        ) == null) return error.DocumentTypeMismatch;

        const current_revision = (try self.database.one(
            i64,
            "SELECT revision_number FROM document_versions WHERE id = ?",
            .{},
            .{request.version_id},
        )) orelse return error.VersionNotFound;
        const expected_revision = std.math.cast(i64, request.expected_revision) orelse return error.InvalidRevision;
        if (current_revision != expected_revision) return error.StaleRevision;

        for (request.sections, encoded_sections) |section, encoded| {
            if (section.id) |section_id| {
                const owner = try self.database.one(
                    i64,
                    "SELECT version_id FROM sections WHERE id = ?",
                    .{},
                    .{section_id},
                );
                if (owner == null) return error.SectionNotFound;
                if (owner.? != request.version_id) return error.SectionBelongsToAnotherVersion;
            }
            if (!std.mem.eql(u8, encoded.kind, section.payload.kind().name())) {
                return error.InvalidSectionData;
            }
        }

        try self.database.exec(
            "DELETE FROM sections WHERE version_id = ?",
            .{},
            .{request.version_id},
        );
        for (encoded_sections, 0..) |section, position| {
            const database_position = std.math.cast(i64, position) orelse return error.SectionLimitExceeded;
            if (section.id) |section_id| {
                try self.database.exec(
                    "INSERT INTO sections (id, version_id, position, kind, data) VALUES (?, ?, ?, ?, ?)",
                    .{},
                    .{ section_id, request.version_id, database_position, section.kind, section.data },
                );
            } else {
                try self.database.exec(
                    "INSERT INTO sections (version_id, position, kind, data) VALUES (?, ?, ?, ?)",
                    .{},
                    .{ request.version_id, database_position, section.kind, section.data },
                );
            }
        }

        const next_revision = std.math.add(i64, current_revision, 1) catch return error.RevisionOverflow;
        try self.database.exec(
            "UPDATE document_versions SET slug = ?, title = ?, description = ?, language = ?, " ++
                "revision_number = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?",
            .{},
            .{
                request.slug,
                request.title,
                request.description,
                request.language,
                next_revision,
                request.version_id,
            },
        );
        try self.database.execMulti("COMMIT;", .{});
        return .{
            .version_id = request.version_id,
            .revision_number = @intCast(next_revision),
        };
    }

    pub fn loadDraft(self: *Store, allocator: std.mem.Allocator, version_id: i64) !DraftRecord {
        const VersionRow = struct {
            document_id: i64,
            version_number: i64,
            revision_number: i64,
            document_type: []const u8,
            state: []const u8,
            title: []const u8,
            slug: []const u8,
            description: ?[]const u8,
            language: []const u8,
        };
        const version = (try self.database.oneAlloc(
            VersionRow,
            allocator,
            "SELECT v.document_id, v.version_number, v.revision_number, d.type, v.state, " ++
                "v.title, v.slug, v.description, v.language " ++
                "FROM document_versions v JOIN documents d ON d.id = v.document_id WHERE v.id = ?",
            .{},
            .{version_id},
        )) orelse return error.VersionNotFound;
        var version_owned = true;
        defer if (version_owned) freeVersionRow(allocator, version);
        if (!std.mem.eql(u8, version.state, "draft") and !std.mem.eql(u8, version.state, "review")) {
            return error.VersionNotEditable;
        }

        var record = DraftRecord{
            .document_id = version.document_id,
            .version_id = version_id,
            .version_number = version.version_number,
            .revision_number = version.revision_number,
            .document_type = version.document_type,
            .title = version.title,
            .slug = version.slug,
            .description = version.description,
            .language = version.language,
            .sections = &.{},
        };
        errdefer record.deinit(allocator);
        allocator.free(version.state);
        version_owned = false;

        var statement = try self.database.prepareWithDiags(
            "SELECT id, position, kind, data FROM sections WHERE version_id = ? ORDER BY position",
            .{},
        );
        defer statement.deinit();
        record.sections = try statement.all(SectionRecord, allocator, .{}, .{version_id});
        return record;
    }
};

fn freeVersionRow(allocator: std.mem.Allocator, row: anytype) void {
    allocator.free(row.document_type);
    allocator.free(row.state);
    allocator.free(row.title);
    allocator.free(row.slug);
    if (row.description) |description| allocator.free(description);
    allocator.free(row.language);
}
