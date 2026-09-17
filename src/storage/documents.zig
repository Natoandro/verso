const sqlite = @import("sqlite");
const domain = @import("../domain/document.zig");

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
            "INSERT INTO document_versions " ++
                "(document_id, version_number, state, slug, title, description, language) " ++
                "VALUES (?, 1, 'draft', ?, ?, ?, ?)",
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
};
