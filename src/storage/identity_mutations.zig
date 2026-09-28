const sqlite = @import("sqlite");
const domain = @import("../domain/identity.zig");

pub fn createAuthor(
    database: *sqlite.Db,
    request: domain.CreateAuthor,
    actor_user_id: i64,
    audit_interface: domain.AuditInterface,
) !i64 {
    try database.execMulti("BEGIN IMMEDIATE;", .{});
    errdefer database.execMulti("ROLLBACK;", .{}) catch {};
    if (!try actorCanManage(database, actor_user_id)) return error.Forbidden;

    if (request.user_id) |user_id| {
        if (try database.one(
            i64,
            "SELECT 1 FROM users WHERE id = ? AND state = 'active'",
            .{},
            .{user_id},
        ) == null) return error.AuthorUserNotFound;
    }

    if (request.user_id) |user_id| {
        try database.exec(
            "INSERT INTO authors (user_id, display_name, slug, biography) VALUES (?, ?, ?, ?)",
            .{},
            .{ user_id, request.display_name, request.slug, request.biography },
        );
    } else {
        try database.exec(
            "INSERT INTO authors (display_name, slug, biography) VALUES (?, ?, ?)",
            .{},
            .{ request.display_name, request.slug, request.biography },
        );
    }
    const author_id = database.getLastInsertRowID();
    try recordAuthorAudit(database, "author.create", audit_interface, actor_user_id, author_id);
    try database.execMulti("COMMIT;", .{});
    return author_id;
}

pub fn updateAuthor(
    database: *sqlite.Db,
    request: domain.UpdateAuthor,
    actor_user_id: i64,
    audit_interface: domain.AuditInterface,
) !void {
    try database.execMulti("BEGIN IMMEDIATE;", .{});
    errdefer database.execMulti("ROLLBACK;", .{}) catch {};
    if (!try actorCanManage(database, actor_user_id)) return error.Forbidden;

    if (try database.one(
        i64,
        "SELECT 1 FROM authors WHERE id = ?",
        .{},
        .{request.author_id},
    ) == null) return error.AuthorNotFound;
    try database.exec(
        \\UPDATE authors SET display_name = ?, slug = ?, biography = ?,
        \\    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?
    ,
        .{},
        .{ request.display_name, request.slug, request.biography, request.author_id },
    );
    try recordAuthorAudit(database, "author.update", audit_interface, actor_user_id, request.author_id);
    try database.execMulti("COMMIT;", .{});
}

pub fn setVersionAuthors(
    database: *sqlite.Db,
    request: domain.SetVersionAuthors,
    actor_user_id: i64,
    audit_interface: domain.AuditInterface,
) !void {
    try database.execMulti("BEGIN IMMEDIATE;", .{});
    errdefer database.execMulti("ROLLBACK;", .{}) catch {};
    if (!try actorCanManage(database, actor_user_id)) return error.Forbidden;

    if (try database.one(
        i64,
        "SELECT 1 FROM document_versions WHERE id = ?",
        .{},
        .{request.version_id},
    ) == null) return error.VersionNotFound;
    if (try database.one(
        i64,
        "SELECT 1 FROM document_versions WHERE id = ? AND state IN ('draft', 'review') AND revision_number = ?",
        .{},
        .{ request.version_id, request.expected_revision },
    ) == null) {
        if (try database.one(
            i64,
            "SELECT 1 FROM document_versions WHERE id = ? AND state IN ('draft', 'review')",
            .{},
            .{request.version_id},
        ) == null) return error.VersionNotEditable;
        return error.StaleRevision;
    }
    for (request.author_ids) |author_id| {
        if (try database.one(i64, "SELECT 1 FROM authors WHERE id = ?", .{}, .{author_id}) == null) {
            return error.AuthorNotFound;
        }
    }

    try database.exec("DELETE FROM version_authors WHERE version_id = ?", .{}, .{request.version_id});
    for (request.author_ids, 0..) |author_id, position| {
        try database.exec(
            "INSERT INTO version_authors (version_id, author_id, position) VALUES (?, ?, ?)",
            .{},
            .{ request.version_id, author_id, @as(i64, @intCast(position)) },
        );
    }
    try database.exec(
        \\UPDATE document_versions SET revision_number = revision_number + 1,
        \\    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), updated_by = ? WHERE id = ?
    ,
        .{},
        .{ actor_user_id, request.version_id },
    );
    const document_id = try database.one(
        i64,
        "SELECT document_id FROM document_versions WHERE id = ?",
        .{},
        .{request.version_id},
    ) orelse return error.VersionNotFound;
    try recordVersionAudit(database, "document.authors.update", audit_interface, actor_user_id, document_id, request.version_id);
    try database.execMulti("COMMIT;", .{});
}

pub fn createAssignment(
    database: *sqlite.Db,
    request: domain.CreateAssignment,
    actor_user_id: i64,
    audit_interface: domain.AuditInterface,
) !i64 {
    try database.execMulti("BEGIN IMMEDIATE;", .{});
    errdefer database.execMulti("ROLLBACK;", .{}) catch {};
    if (!try actorCanManage(database, actor_user_id)) return error.Forbidden;

    if (try database.one(
        i64,
        \\SELECT 1 FROM users AS editor JOIN user_roles AS role
        \\    ON role.user_id = editor.id AND role.role = 'editor'
        \\    WHERE editor.id = ? AND editor.state = 'active'
    ,
        .{},
        .{request.editor_user_id},
    ) == null) return error.TargetNotEditor;

    const assignment_id = switch (request.scope) {
        .author => |author_id| blk: {
            if (try database.one(i64, "SELECT 1 FROM authors WHERE id = ?", .{}, .{author_id}) == null) {
                return error.AuthorNotFound;
            }
            if (try database.one(
                i64,
                "SELECT 1 FROM editor_assignments WHERE editor_user_id = ? AND author_id = ? AND revoked_at IS NULL",
                .{},
                .{ request.editor_user_id, author_id },
            ) != null) return error.ActiveAssignmentExists;
            try database.exec(
                "INSERT INTO editor_assignments (editor_user_id, author_id, granted_by) VALUES (?, ?, ?)",
                .{},
                .{ request.editor_user_id, author_id, actor_user_id },
            );
            break :blk database.getLastInsertRowID();
        },
        .document => |document_id| blk: {
            if (try database.one(i64, "SELECT 1 FROM documents WHERE id = ?", .{}, .{document_id}) == null) {
                return error.DocumentNotFound;
            }
            if (try database.one(
                i64,
                "SELECT 1 FROM editor_assignments WHERE editor_user_id = ? AND document_id = ? AND revoked_at IS NULL",
                .{},
                .{ request.editor_user_id, document_id },
            ) != null) return error.ActiveAssignmentExists;
            try database.exec(
                "INSERT INTO editor_assignments (editor_user_id, document_id, granted_by) VALUES (?, ?, ?)",
                .{},
                .{ request.editor_user_id, document_id, actor_user_id },
            );
            break :blk database.getLastInsertRowID();
        },
    };

    switch (request.scope) {
        .author => |author_id| try recordAuthorAssignmentAudit(
            database,
            "assignment.create",
            audit_interface,
            actor_user_id,
            author_id,
        ),
        .document => |document_id| try recordDocumentAssignmentAudit(
            database,
            "assignment.create",
            audit_interface,
            actor_user_id,
            document_id,
        ),
    }
    try database.execMulti("COMMIT;", .{});
    return assignment_id;
}

pub fn revokeAssignment(
    database: *sqlite.Db,
    request: domain.RevokeAssignment,
    actor_user_id: i64,
    audit_interface: domain.AuditInterface,
) !i64 {
    try database.execMulti("BEGIN IMMEDIATE;", .{});
    errdefer database.execMulti("ROLLBACK;", .{}) catch {};
    if (!try actorCanManage(database, actor_user_id)) return error.Forbidden;

    const revision = (try database.one(
        i64,
        "SELECT revision_number FROM editor_assignments WHERE id = ?",
        .{},
        .{request.assignment_id},
    )) orelse return error.AssignmentNotFound;
    if (try database.one(
        i64,
        "SELECT 1 FROM editor_assignments WHERE id = ? AND revoked_at IS NOT NULL",
        .{},
        .{request.assignment_id},
    ) != null) return error.AssignmentRevoked;
    if (revision != request.expected_revision) return error.StaleAssignment;

    const author_id = try database.one(
        i64,
        "SELECT author_id FROM editor_assignments WHERE id = ?",
        .{},
        .{request.assignment_id},
    );
    const document_id = try database.one(
        i64,
        "SELECT document_id FROM editor_assignments WHERE id = ?",
        .{},
        .{request.assignment_id},
    );
    try database.exec(
        \\UPDATE editor_assignments
        \\    SET revoked_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
        \\        revoked_by = ?, revision_number = revision_number + 1
        \\    WHERE id = ? AND revision_number = ? AND revoked_at IS NULL
    ,
        .{},
        .{ actor_user_id, request.assignment_id, request.expected_revision },
    );
    if (author_id) |id| {
        try recordAuthorAssignmentAudit(database, "assignment.revoke", audit_interface, actor_user_id, id);
    } else if (document_id) |id| {
        try recordDocumentAssignmentAudit(database, "assignment.revoke", audit_interface, actor_user_id, id);
    }
    try database.execMulti("COMMIT;", .{});
    return revision + 1;
}

fn recordAuthorAudit(
    database: *sqlite.Db,
    action: []const u8,
    audit_interface: domain.AuditInterface,
    actor_user_id: i64,
    author_id: i64,
) !void {
    try database.exec(
        "INSERT INTO audit_log (action, interface, actor_user_id, acted_for_author_id, details) VALUES (?, ?, ?, ?, '{}')",
        .{},
        .{ action, @tagName(audit_interface), actor_user_id, author_id },
    );
}

fn recordAuthorAssignmentAudit(
    database: *sqlite.Db,
    action: []const u8,
    audit_interface: domain.AuditInterface,
    actor_user_id: i64,
    author_id: i64,
) !void {
    return recordAuthorAudit(database, action, audit_interface, actor_user_id, author_id);
}

fn recordDocumentAssignmentAudit(
    database: *sqlite.Db,
    action: []const u8,
    audit_interface: domain.AuditInterface,
    actor_user_id: i64,
    document_id: i64,
) !void {
    try database.exec(
        "INSERT INTO audit_log (action, interface, actor_user_id, document_id, details) VALUES (?, ?, ?, ?, '{}')",
        .{},
        .{ action, @tagName(audit_interface), actor_user_id, document_id },
    );
}

fn recordVersionAudit(
    database: *sqlite.Db,
    action: []const u8,
    audit_interface: domain.AuditInterface,
    actor_user_id: i64,
    document_id: i64,
    version_id: i64,
) !void {
    try database.exec(
        \\INSERT INTO audit_log (action, interface, actor_user_id, document_id, version_id, details)
        \\    VALUES (?, ?, ?, ?, ?, '{}')
    ,
        .{},
        .{ action, @tagName(audit_interface), actor_user_id, document_id, version_id },
    );
}

fn actorCanManage(database: *sqlite.Db, actor_user_id: i64) !bool {
    return (try database.one(
        i64,
        \\SELECT 1 FROM users AS actor JOIN user_roles AS role ON role.user_id = actor.id
        \\    WHERE actor.id = ? AND actor.state = 'active' AND role.role IN ('owner', 'manager')
    ,
        .{},
        .{actor_user_id},
    )) != null;
}
