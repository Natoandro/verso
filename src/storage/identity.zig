const sqlite = @import("sqlite");
const identity = @import("../auth/identity.zig");

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
            "INSERT INTO web_sessions (token_hash, csrf_secret_hash, user_id, expires_at) " ++
                "VALUES (?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '+8 hours'))",
            .{},
            .{ token_hash, csrf_secret_hash, user_id },
        );
        return self.database.getLastInsertRowID();
    }

    pub fn activeSessionUserId(self: *Store, token_hash: []const u8) !?i64 {
        const user_id = try self.database.one(
            i64,
            "" ++
                "SELECT session.user_id FROM web_sessions AS session " ++
                "JOIN users AS user ON user.id = session.user_id " ++
                "WHERE session.token_hash = ? AND session.revoked_at IS NULL " ++
                "AND session.expires_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now') " ++
                "AND user.state = 'active'",
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
            "" ++
                "SELECT 1 FROM web_sessions AS session " ++
                "JOIN users AS user ON user.id = session.user_id " ++
                "WHERE session.token_hash = ? AND session.csrf_secret_hash = ? " ++
                "AND session.revoked_at IS NULL " ++
                "AND session.expires_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now') " ++
                "AND user.state = 'active'",
            .{},
            .{ token_hash, csrf_secret_hash },
        )) != null;
    }

    pub fn revokeSession(self: *Store, token_hash: []const u8) !void {
        try self.database.exec(
            "UPDATE web_sessions SET revoked_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') " ++
                "WHERE token_hash = ? AND revoked_at IS NULL",
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
};
