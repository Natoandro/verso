const sqlite = @import("sqlite");
const identity = @import("../auth/identity.zig");
const domain = @import("../domain/identity.zig");
const mutations = @import("identity_mutations.zig");

pub const Store = struct {
    database: *sqlite.Db,

    pub const InitialLocalOwner = struct {
        subject: []const u8,
        display_name: []const u8,
        email: ?[]const u8,
        login: []const u8,
        password_hash: []const u8,
    };

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

    pub fn createInitialLocalOwner(self: *Store, owner: InitialLocalOwner) !i64 {
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
            "INSERT INTO local_password_credentials (user_id, login, password_hash) VALUES (?, ?, ?)",
            .{},
            .{ user_id, owner.login, owner.password_hash },
        );
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

    pub fn hasNoUsers(self: *Store) !bool {
        return (try self.database.one(i64, "SELECT 1 FROM users LIMIT 1", .{}, .{})) == null;
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

    pub fn rotateUserSession(
        self: *Store,
        user_id: i64,
        token_hash: []const u8,
        csrf_secret_hash: []const u8,
    ) !i64 {
        try self.database.execMulti("BEGIN IMMEDIATE;", .{});
        errdefer self.database.execMulti("ROLLBACK;", .{}) catch {};
        try self.database.exec(
            "UPDATE web_sessions SET revoked_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE user_id = ? AND revoked_at IS NULL",
            .{},
            .{user_id},
        );
        try self.database.exec(
            \\INSERT INTO web_sessions (token_hash, csrf_secret_hash, user_id, expires_at)
            \\    VALUES (?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '+8 hours'))
        ,
            .{},
            .{ token_hash, csrf_secret_hash, user_id },
        );
        const session_id = self.database.getLastInsertRowID();
        try self.database.execMulti("COMMIT;", .{});
        return session_id;
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
            \\SELECT 1 FROM user_roles AS role_grant
            \\    JOIN users AS user ON user.id = role_grant.user_id
            \\    WHERE role_grant.user_id = ? AND role_grant.role = ? AND user.state = 'active'
        ,
            .{},
            .{ user_id, @tagName(role) },
        )) != null;
    }

    pub fn createAuthor(self: *Store, request: domain.CreateAuthor, actor_user_id: i64, audit_interface: domain.AuditInterface) !i64 {
        return mutations.createAuthor(self.database, request, actor_user_id, audit_interface);
    }

    pub fn updateAuthor(self: *Store, request: domain.UpdateAuthor, actor_user_id: i64, audit_interface: domain.AuditInterface) !void {
        return mutations.updateAuthor(self.database, request, actor_user_id, audit_interface);
    }

    pub fn setVersionAuthors(self: *Store, request: domain.SetVersionAuthors, actor_user_id: i64, audit_interface: domain.AuditInterface) !void {
        return mutations.setVersionAuthors(self.database, request, actor_user_id, audit_interface);
    }

    pub fn createAssignment(self: *Store, request: domain.CreateAssignment, actor_user_id: i64, audit_interface: domain.AuditInterface) !i64 {
        return mutations.createAssignment(self.database, request, actor_user_id, audit_interface);
    }

    pub fn revokeAssignment(self: *Store, request: domain.RevokeAssignment, actor_user_id: i64, audit_interface: domain.AuditInterface) !i64 {
        return mutations.revokeAssignment(self.database, request, actor_user_id, audit_interface);
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
};
