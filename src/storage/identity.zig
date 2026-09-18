const sqlite = @import("sqlite");
const identity = @import("../auth/identity.zig");
const domain = @import("../domain/identity.zig");

pub const Store = struct {
    database: *sqlite.Db,

    pub fn init(database: *sqlite.Db) Store {
        return .{ .database = database };
    }

    pub fn bootstrapOwner(self: *Store, owner: identity.BootstrapOwner) !i64 {
        try self.database.execMulti("BEGIN IMMEDIATE;", .{});
        errdefer self.database.execMulti("ROLLBACK;", .{}) catch {};

        if (try self.database.one(i64, "SELECT 1 FROM users LIMIT 1", .{}, .{}) != null) {
            return error.OwnerAlreadyExists;
        }

        if (owner.email) |email| {
            try self.database.exec(
                "INSERT INTO users (subject, display_name, email) VALUES (?, ?, ?)",
                .{},
                .{ owner.subject, owner.display_name, email },
            );
        } else {
            try self.database.exec(
                "INSERT INTO users (subject, display_name) VALUES (?, ?)",
                .{},
                .{ owner.subject, owner.display_name },
            );
        }
        const user_id = self.database.getLastInsertRowID();
        try self.database.exec(
            "INSERT INTO user_roles (user_id, role) VALUES (?, 'owner')",
            .{},
            .{user_id},
        );
        try self.database.exec(
            "INSERT INTO audit_log (action, interface, details) VALUES ('owner.bootstrap', 'system', '{}')",
            .{},
            .{},
        );
        try self.database.execMulti("COMMIT;", .{});
        return user_id;
    }

    pub fn userIdForSubject(self: *Store, subject: []const u8) !?i64 {
        return self.database.one(
            i64,
            "SELECT id FROM users WHERE subject = ? AND state = 'active'",
            .{},
            .{subject},
        );
    }

    pub fn createSession(
        self: *Store,
        user_id: i64,
        token_hash: []const u8,
        csrf_secret_hash: []const u8,
    ) !i64 {
        try self.database.exec(
            \\INSERT INTO web_sessions (token_hash, csrf_secret_hash, user_id, expires_at)
            \\    VALUES (?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '+8 hours'))
        ,
            .{},
            .{ token_hash, csrf_secret_hash, user_id },
        );
        return self.database.getLastInsertRowID();
    }

    pub fn activeSessionUserId(self: *Store, token_hash: []const u8) !?i64 {
        const user_id = try self.database.one(
            i64,
            \\SELECT session.user_id FROM web_sessions AS session
            \\    JOIN users AS user ON user.id = session.user_id
            \\    WHERE session.token_hash = ? AND session.revoked_at IS NULL
            \\    AND session.expires_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
            \\    AND user.state = 'active'
        ,
            .{},
            .{token_hash},
        );
        if (user_id) |id| {
            try self.database.exec(
                "UPDATE web_sessions SET last_seen_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE token_hash = ?",
                .{},
                .{token_hash},
            );
            return id;
        }
        return null;
    }

    pub fn csrfMatches(
        self: *Store,
        token_hash: []const u8,
        csrf_secret_hash: []const u8,
    ) !bool {
        return (try self.database.one(
            i64,
            \\SELECT 1 FROM web_sessions AS session
            \\    JOIN users AS user ON user.id = session.user_id
            \\    WHERE session.token_hash = ? AND session.csrf_secret_hash = ?
            \\    AND session.revoked_at IS NULL
            \\    AND session.expires_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
            \\    AND user.state = 'active'
        ,
            .{},
            .{ token_hash, csrf_secret_hash },
        )) != null;
    }

    pub fn revokeSession(self: *Store, token_hash: []const u8) !void {
        try self.database.exec(
            \\UPDATE web_sessions SET revoked_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
            \\    WHERE token_hash = ? AND revoked_at IS NULL
        ,
            .{},
            .{token_hash},
        );
    }

    pub fn userHasRole(self: *Store, user_id: i64, role: identity.Role) !bool {
        return (try self.database.one(
            i64,
            "SELECT 1 FROM user_roles WHERE user_id = ? AND role = ?",
            .{},
            .{ user_id, @tagName(role) },
        )) != null;
    }

    pub fn createAuthor(
        self: *Store,
        request: domain.CreateAuthor,
        actor_user_id: i64,
        audit_interface: domain.AuditInterface,
    ) !i64 {
        try self.database.execMulti("BEGIN IMMEDIATE;", .{});
        errdefer self.database.execMulti("ROLLBACK;", .{}) catch {};
        if (!try self.actorCanManage(actor_user_id)) return error.Forbidden;

        if (request.user_id) |user_id| {
            if (try self.database.one(
                i64,
                "SELECT 1 FROM users WHERE id = ? AND state = 'active'",
                .{},
                .{user_id},
            ) == null) return error.AuthorUserNotFound;
        }

        if (request.user_id) |user_id| {
            try self.database.exec(
                "INSERT INTO authors (user_id, display_name, slug, biography) VALUES (?, ?, ?, ?)",
                .{},
                .{ user_id, request.display_name, request.slug, request.biography },
            );
        } else {
            try self.database.exec(
                "INSERT INTO authors (display_name, slug, biography) VALUES (?, ?, ?)",
                .{},
                .{ request.display_name, request.slug, request.biography },
            );
        }
        const author_id = self.database.getLastInsertRowID();
        try self.recordAuthorAudit("author.create", audit_interface, actor_user_id, author_id);
        try self.database.execMulti("COMMIT;", .{});
        return author_id;
    }

    pub fn updateAuthor(
        self: *Store,
        request: domain.UpdateAuthor,
        actor_user_id: i64,
        audit_interface: domain.AuditInterface,
    ) !void {
        try self.database.execMulti("BEGIN IMMEDIATE;", .{});
        errdefer self.database.execMulti("ROLLBACK;", .{}) catch {};
        if (!try self.actorCanManage(actor_user_id)) return error.Forbidden;

        if (try self.database.one(
            i64,
            "SELECT 1 FROM authors WHERE id = ?",
            .{},
            .{request.author_id},
        ) == null) return error.AuthorNotFound;
        try self.database.exec(
            \\UPDATE authors SET display_name = ?, slug = ?, biography = ?,
            \\    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?
        ,
            .{},
            .{ request.display_name, request.slug, request.biography, request.author_id },
        );
        try self.recordAuthorAudit("author.update", audit_interface, actor_user_id, request.author_id);
        try self.database.execMulti("COMMIT;", .{});
    }

    pub fn setVersionAuthors(
        self: *Store,
        request: domain.SetVersionAuthors,
        actor_user_id: i64,
        audit_interface: domain.AuditInterface,
    ) !void {
        try self.database.execMulti("BEGIN IMMEDIATE;", .{});
        errdefer self.database.execMulti("ROLLBACK;", .{}) catch {};
        if (!try self.actorCanManage(actor_user_id)) return error.Forbidden;

        if (try self.database.one(
            i64,
            "SELECT 1 FROM document_versions WHERE id = ?",
            .{},
            .{request.version_id},
        ) == null) return error.VersionNotFound;
        if (try self.database.one(
            i64,
            "SELECT 1 FROM document_versions WHERE id = ? AND state IN ('draft', 'review') AND revision_number = ?",
            .{},
            .{ request.version_id, request.expected_revision },
        ) == null) {
            if (try self.database.one(
                i64,
                "SELECT 1 FROM document_versions WHERE id = ? AND state IN ('draft', 'review')",
                .{},
                .{request.version_id},
            ) == null) return error.VersionNotEditable;
            return error.StaleRevision;
        }
        for (request.author_ids) |author_id| {
            if (try self.database.one(i64, "SELECT 1 FROM authors WHERE id = ?", .{}, .{author_id}) == null) {
                return error.AuthorNotFound;
            }
        }

        try self.database.exec("DELETE FROM version_authors WHERE version_id = ?", .{}, .{request.version_id});
        for (request.author_ids, 0..) |author_id, position| {
            try self.database.exec(
                "INSERT INTO version_authors (version_id, author_id, position) VALUES (?, ?, ?)",
                .{},
                .{ request.version_id, author_id, @as(i64, @intCast(position)) },
            );
        }
        try self.database.exec(
            \\UPDATE document_versions SET revision_number = revision_number + 1,
            \\    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), updated_by = ? WHERE id = ?
        ,
            .{},
            .{ actor_user_id, request.version_id },
        );
        const document_id = try self.database.one(
            i64,
            "SELECT document_id FROM document_versions WHERE id = ?",
            .{},
            .{request.version_id},
        ) orelse return error.VersionNotFound;
        try self.recordVersionAudit("document.authors.update", audit_interface, actor_user_id, document_id, request.version_id);
        try self.database.execMulti("COMMIT;", .{});
    }

    pub fn createAssignment(
        self: *Store,
        request: domain.CreateAssignment,
        actor_user_id: i64,
        audit_interface: domain.AuditInterface,
    ) !i64 {
        try self.database.execMulti("BEGIN IMMEDIATE;", .{});
        errdefer self.database.execMulti("ROLLBACK;", .{}) catch {};
        if (!try self.actorCanManage(actor_user_id)) return error.Forbidden;

        if (try self.database.one(
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
                if (try self.database.one(i64, "SELECT 1 FROM authors WHERE id = ?", .{}, .{author_id}) == null) {
                    return error.AuthorNotFound;
                }
                if (try self.database.one(
                    i64,
                    "SELECT 1 FROM editor_assignments WHERE editor_user_id = ? AND author_id = ? AND revoked_at IS NULL",
                    .{},
                    .{ request.editor_user_id, author_id },
                ) != null) return error.ActiveAssignmentExists;
                try self.database.exec(
                    "INSERT INTO editor_assignments (editor_user_id, author_id, granted_by) VALUES (?, ?, ?)",
                    .{},
                    .{ request.editor_user_id, author_id, actor_user_id },
                );
                break :blk self.database.getLastInsertRowID();
            },
            .document => |document_id| blk: {
                if (try self.database.one(i64, "SELECT 1 FROM documents WHERE id = ?", .{}, .{document_id}) == null) {
                    return error.DocumentNotFound;
                }
                if (try self.database.one(
                    i64,
                    "SELECT 1 FROM editor_assignments WHERE editor_user_id = ? AND document_id = ? AND revoked_at IS NULL",
                    .{},
                    .{ request.editor_user_id, document_id },
                ) != null) return error.ActiveAssignmentExists;
                try self.database.exec(
                    "INSERT INTO editor_assignments (editor_user_id, document_id, granted_by) VALUES (?, ?, ?)",
                    .{},
                    .{ request.editor_user_id, document_id, actor_user_id },
                );
                break :blk self.database.getLastInsertRowID();
            },
        };

        switch (request.scope) {
            .author => |author_id| try self.recordAuthorAssignmentAudit(
                "assignment.create",
                audit_interface,
                actor_user_id,
                author_id,
            ),
            .document => |document_id| try self.recordDocumentAssignmentAudit(
                "assignment.create",
                audit_interface,
                actor_user_id,
                document_id,
            ),
        }
        try self.database.execMulti("COMMIT;", .{});
        return assignment_id;
    }

    pub fn revokeAssignment(
        self: *Store,
        request: domain.RevokeAssignment,
        actor_user_id: i64,
        audit_interface: domain.AuditInterface,
    ) !i64 {
        try self.database.execMulti("BEGIN IMMEDIATE;", .{});
        errdefer self.database.execMulti("ROLLBACK;", .{}) catch {};
        if (!try self.actorCanManage(actor_user_id)) return error.Forbidden;

        const revision = (try self.database.one(
            i64,
            "SELECT revision_number FROM editor_assignments WHERE id = ?",
            .{},
            .{request.assignment_id},
        )) orelse return error.AssignmentNotFound;
        if (try self.database.one(
            i64,
            "SELECT 1 FROM editor_assignments WHERE id = ? AND revoked_at IS NOT NULL",
            .{},
            .{request.assignment_id},
        ) != null) return error.AssignmentRevoked;
        if (revision != request.expected_revision) return error.StaleAssignment;

        const author_id = try self.database.one(
            i64,
            "SELECT author_id FROM editor_assignments WHERE id = ?",
            .{},
            .{request.assignment_id},
        );
        const document_id = try self.database.one(
            i64,
            "SELECT document_id FROM editor_assignments WHERE id = ?",
            .{},
            .{request.assignment_id},
        );
        try self.database.exec(
            \\UPDATE editor_assignments
            \\    SET revoked_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
            \\        revoked_by = ?, revision_number = revision_number + 1
            \\    WHERE id = ? AND revision_number = ? AND revoked_at IS NULL
        ,
            .{},
            .{ actor_user_id, request.assignment_id, request.expected_revision },
        );
        if (author_id) |id| {
            try self.recordAuthorAssignmentAudit("assignment.revoke", audit_interface, actor_user_id, id);
        } else if (document_id) |id| {
            try self.recordDocumentAssignmentAudit("assignment.revoke", audit_interface, actor_user_id, id);
        }
        try self.database.execMulti("COMMIT;", .{});
        return revision + 1;
    }

    pub fn hasAuthorAssignment(self: *Store, editor_user_id: i64, author_id: i64) !bool {
        return (try self.database.one(
            i64,
            "SELECT 1 FROM editor_assignments WHERE editor_user_id = ? AND author_id = ? AND revoked_at IS NULL",
            .{},
            .{ editor_user_id, author_id },
        )) != null;
    }

    pub fn hasDocumentAssignment(self: *Store, editor_user_id: i64, document_id: i64) !bool {
        return (try self.database.one(
            i64,
            "SELECT 1 FROM editor_assignments WHERE editor_user_id = ? AND document_id = ? AND revoked_at IS NULL",
            .{},
            .{ editor_user_id, document_id },
        )) != null;
    }

    pub fn hasVersionAssignment(self: *Store, editor_user_id: i64, version_id: i64) !bool {
        return (try self.database.one(
            i64,
            \\SELECT 1 FROM editor_assignments AS assignment
            \\    JOIN document_versions AS version ON version.id = ?
            \\    WHERE assignment.editor_user_id = ? AND assignment.revoked_at IS NULL
            \\    AND (assignment.document_id = version.document_id OR assignment.author_id IN (
            \\        SELECT version_author.author_id FROM version_authors AS version_author
            \\        WHERE version_author.version_id = version.id))
        ,
            .{},
            .{ version_id, editor_user_id },
        )) != null;
    }

    fn recordAuthorAudit(
        self: *Store,
        action: []const u8,
        audit_interface: domain.AuditInterface,
        actor_user_id: i64,
        author_id: i64,
    ) !void {
        try self.database.exec(
            "INSERT INTO audit_log (action, interface, actor_user_id, acted_for_author_id, details) VALUES (?, ?, ?, ?, '{}')",
            .{},
            .{ action, @tagName(audit_interface), actor_user_id, author_id },
        );
    }

    fn recordAuthorAssignmentAudit(
        self: *Store,
        action: []const u8,
        audit_interface: domain.AuditInterface,
        actor_user_id: i64,
        author_id: i64,
    ) !void {
        return self.recordAuthorAudit(action, audit_interface, actor_user_id, author_id);
    }

    fn recordDocumentAssignmentAudit(
        self: *Store,
        action: []const u8,
        audit_interface: domain.AuditInterface,
        actor_user_id: i64,
        document_id: i64,
    ) !void {
        try self.database.exec(
            "INSERT INTO audit_log (action, interface, actor_user_id, document_id, details) VALUES (?, ?, ?, ?, '{}')",
            .{},
            .{ action, @tagName(audit_interface), actor_user_id, document_id },
        );
    }

    fn recordVersionAudit(
        self: *Store,
        action: []const u8,
        audit_interface: domain.AuditInterface,
        actor_user_id: i64,
        document_id: i64,
        version_id: i64,
    ) !void {
        try self.database.exec(
            \\INSERT INTO audit_log (action, interface, actor_user_id, document_id, version_id, details)
            \\    VALUES (?, ?, ?, ?, ?, '{}')
        ,
            .{},
            .{ action, @tagName(audit_interface), actor_user_id, document_id, version_id },
        );
    }

    fn actorCanManage(self: *Store, actor_user_id: i64) !bool {
        return (try self.database.one(
            i64,
            \\SELECT 1 FROM users AS actor JOIN user_roles AS role ON role.user_id = actor.id
            \\    WHERE actor.id = ? AND actor.state = 'active' AND role.role IN ('owner', 'manager')
        ,
            .{},
            .{actor_user_id},
        )) != null;
    }
};
