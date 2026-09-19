const sqlite = @import("sqlite");

pub fn hasDocumentReadAccess(database: *sqlite.Db, editor_user_id: i64, document_id: i64) !bool {
    return (try database.one(
        i64,
        \\SELECT 1 FROM documents AS document
        \\    WHERE document.id = ? AND (
        \\        document.created_by = ? OR EXISTS (
        \\            SELECT 1 FROM editor_assignments AS assignment
        \\            WHERE assignment.editor_user_id = ?
        \\                AND assignment.document_id = document.id
        \\                AND assignment.revoked_at IS NULL)
        \\        OR EXISTS (
        \\            SELECT 1 FROM editor_assignments AS assignment
        \\            JOIN version_authors AS version_author
        \\                ON version_author.author_id = assignment.author_id
        \\            JOIN document_versions AS version
        \\                ON version.id = version_author.version_id
        \\            WHERE assignment.editor_user_id = ?
        \\                AND assignment.revoked_at IS NULL
        \\                AND version.document_id = document.id
        \\                AND version.state IN ('draft', 'review')))
    ,
        .{},
        .{ document_id, editor_user_id, editor_user_id, editor_user_id },
    )) != null;
}

pub fn hasDocumentUpdateAccess(database: *sqlite.Db, editor_user_id: i64, document_id: i64) !bool {
    return hasDocumentReadAccess(database, editor_user_id, document_id);
}

pub fn hasVersionReadAccess(database: *sqlite.Db, editor_user_id: i64, version_id: i64) !bool {
    return (try database.one(
        i64,
        \\SELECT 1 FROM document_versions AS version
        \\    JOIN documents AS document ON document.id = version.document_id
        \\    WHERE version.id = ? AND (
        \\        version.created_by = ? OR document.created_by = ? OR EXISTS (
        \\            SELECT 1 FROM editor_assignments AS assignment
        \\            WHERE assignment.editor_user_id = ?
        \\                AND assignment.revoked_at IS NULL
        \\                AND (assignment.document_id = version.document_id OR assignment.author_id IN (
        \\                    SELECT version_author.author_id FROM version_authors AS version_author
        \\                    WHERE version_author.version_id = version.id))))
    ,
        .{},
        .{ version_id, editor_user_id, editor_user_id, editor_user_id },
    )) != null;
}

pub fn hasVersionUpdateAccess(database: *sqlite.Db, editor_user_id: i64, version_id: i64) !bool {
    return hasVersionReadAccess(database, editor_user_id, version_id);
}
