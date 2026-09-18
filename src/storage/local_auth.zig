const std = @import("std");
const sqlite = @import("sqlite");
const password = @import("../auth/password.zig");

pub const Credential = struct {
    user_id: i64,
    password_hash: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Credential) void {
        self.allocator.free(self.password_hash);
        self.* = undefined;
    }
};

pub const Store = struct {
    database: *sqlite.Db,

    pub fn init(database: *sqlite.Db) Store {
        return .{ .database = database };
    }

    pub fn credentialForLogin(
        self: *Store,
        allocator: std.mem.Allocator,
        login: []const u8,
    ) !?Credential {
        const Row = struct {
            user_id: i64,
            password_hash: sqlite.Text,
        };
        const row = try self.database.oneAlloc(
            Row,
            allocator,
            \\SELECT credential.user_id, credential.password_hash
            \\FROM local_password_credentials AS credential
            \\JOIN users AS user ON user.id = credential.user_id
            \\WHERE credential.login = ? AND user.state = 'active'
        ,
            .{},
            .{login},
        ) orelse return null;
        defer allocator.free(row.password_hash.data);
        return .{
            .user_id = row.user_id,
            .password_hash = try allocator.dupe(u8, row.password_hash.data),
            .allocator = allocator,
        };
    }

    pub fn credentialForUser(
        self: *Store,
        allocator: std.mem.Allocator,
        user_id: i64,
    ) !?Credential {
        const Row = struct {
            user_id: i64,
            password_hash: sqlite.Text,
        };
        const row = try self.database.oneAlloc(
            Row,
            allocator,
            "SELECT user_id, password_hash FROM local_password_credentials WHERE user_id = ?",
            .{},
            .{user_id},
        ) orelse return null;
        defer allocator.free(row.password_hash.data);
        return .{
            .user_id = row.user_id,
            .password_hash = try allocator.dupe(u8, row.password_hash.data),
            .allocator = allocator,
        };
    }

    pub fn replacePassword(self: *Store, user_id: i64, password_hash: []const u8) !void {
        try password.validateEncodedHash(password_hash);
        try self.database.execMulti("BEGIN IMMEDIATE;", .{});
        errdefer self.database.execMulti("ROLLBACK;", .{}) catch {};
        try self.database.exec(
            \\UPDATE local_password_credentials
            \\SET password_hash = ?, password_changed_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
            \\    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
            \\WHERE user_id = ?
        ,
            .{},
            .{ password_hash, user_id },
        );
        try self.database.exec(
            "UPDATE local_password_reset_tokens SET consumed_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE user_id = ? AND consumed_at IS NULL",
            .{},
            .{user_id},
        );
        try self.revokeUserSessionsInTransaction(user_id);
        try self.database.execMulti("COMMIT;", .{});
    }

    pub fn issueResetToken(self: *Store, user_id: i64, token_hash: []const u8) !bool {
        try self.database.execMulti("BEGIN IMMEDIATE;", .{});
        errdefer self.database.execMulti("ROLLBACK;", .{}) catch {};
        try self.database.exec(
            "DELETE FROM local_password_reset_tokens WHERE expires_at <= strftime('%Y-%m-%dT%H:%M:%fZ', 'now') OR (consumed_at IS NOT NULL AND consumed_at <= strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-30 days'))",
            .{},
            .{},
        );
        if (try self.database.one(
            i64,
            "SELECT 1 FROM local_password_credentials JOIN users ON users.id = local_password_credentials.user_id WHERE user_id = ? AND users.state = 'active'",
            .{},
            .{user_id},
        ) == null) {
            try self.database.execMulti("COMMIT;", .{});
            return false;
        }
        try self.database.exec(
            "UPDATE local_password_reset_tokens SET consumed_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE user_id = ? AND consumed_at IS NULL",
            .{},
            .{user_id},
        );
        try self.database.exec(
            "INSERT INTO local_password_reset_tokens (user_id, token_hash, expires_at) VALUES (?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '+1 hour'))",
            .{},
            .{ user_id, token_hash },
        );
        try self.database.execMulti("COMMIT;", .{});
        return true;
    }

    pub fn consumeResetAndReplace(self: *Store, token_hash: []const u8, password_hash: []const u8) !?i64 {
        try password.validateEncodedHash(password_hash);
        try self.database.execMulti("BEGIN IMMEDIATE;", .{});
        errdefer self.database.execMulti("ROLLBACK;", .{}) catch {};
        const user_id = try self.database.one(
            i64,
            \\SELECT token.user_id FROM local_password_reset_tokens AS token
            \\JOIN users AS user ON user.id = token.user_id
            \\WHERE token.token_hash = ? AND token.consumed_at IS NULL
            \\  AND token.expires_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
            \\  AND user.state = 'active'
        ,
            .{},
            .{token_hash},
        ) orelse {
            try self.database.execMulti("COMMIT;", .{});
            return null;
        };
        try self.database.exec(
            \\UPDATE local_password_credentials
            \\SET password_hash = ?, password_changed_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
            \\    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
            \\WHERE user_id = ?
        ,
            .{},
            .{ password_hash, user_id },
        );
        try self.database.exec(
            "UPDATE local_password_reset_tokens SET consumed_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE token_hash = ?",
            .{},
            .{token_hash},
        );
        try self.revokeUserSessionsInTransaction(user_id);
        try self.database.execMulti("COMMIT;", .{});
        return user_id;
    }

    pub fn revokeUserSessions(self: *Store, user_id: i64) !void {
        try self.database.execMulti("BEGIN IMMEDIATE;", .{});
        errdefer self.database.execMulti("ROLLBACK;", .{}) catch {};
        try self.revokeUserSessionsInTransaction(user_id);
        try self.database.execMulti("COMMIT;", .{});
    }

    pub fn resetTokenIsValid(self: *Store, token_hash: []const u8) !bool {
        return (try self.database.one(
            i64,
            \\SELECT 1 FROM local_password_reset_tokens AS token
            \\JOIN users AS user ON user.id = token.user_id
            \\WHERE token.token_hash = ? AND token.consumed_at IS NULL
            \\  AND token.expires_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
            \\  AND user.state = 'active'
        ,
            .{},
            .{token_hash},
        )) != null;
    }

    fn revokeUserSessionsInTransaction(self: *Store, user_id: i64) !void {
        try self.database.exec(
            "UPDATE web_sessions SET revoked_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE user_id = ? AND revoked_at IS NULL",
            .{},
            .{user_id},
        );
    }

    pub fn isRateLimited(self: *Store, identifier_hash: []const u8, address_hash: []const u8) !bool {
        return (try self.database.one(
            i64,
            \\SELECT 1 FROM local_login_rate_limits
            \\WHERE locked_until > strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
            \\  AND ((scope = 'identifier' AND key_hash = ?) OR (scope = 'address' AND key_hash = ?))
            \\LIMIT 1
        ,
            .{},
            .{ identifier_hash, address_hash },
        )) != null;
    }

    pub fn allowLoginAttempt(self: *Store, identifier_hash: []const u8, address_hash: []const u8) !bool {
        try self.database.execMulti("BEGIN IMMEDIATE;", .{});
        errdefer self.database.execMulti("ROLLBACK;", .{}) catch {};
        try self.cleanupRateLimitsInTransaction();
        if (try self.database.one(
            i64,
            \\SELECT 1 FROM local_login_rate_limits
            \\WHERE locked_until > strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
            \\  AND ((scope = 'identifier' AND key_hash = ?) OR (scope = 'address' AND key_hash = ?))
            \\LIMIT 1
        ,
            .{},
            .{ identifier_hash, address_hash },
        ) != null) {
            try self.database.execMulti("COMMIT;", .{});
            return false;
        }
        try self.recordFailureInTransaction("identifier", identifier_hash);
        try self.recordFailureInTransaction("address", address_hash);
        try self.database.execMulti("COMMIT;", .{});
        return true;
    }

    pub fn recordFailure(self: *Store, scope: []const u8, key_hash: []const u8) !void {
        try self.database.execMulti("BEGIN IMMEDIATE;", .{});
        errdefer self.database.execMulti("ROLLBACK;", .{}) catch {};
        try self.cleanupRateLimitsInTransaction();
        try self.recordFailureInTransaction(scope, key_hash);
        try self.database.execMulti("COMMIT;", .{});
    }

    fn recordFailureInTransaction(self: *Store, scope: []const u8, key_hash: []const u8) !void {
        const count = try self.database.one(
            i64,
            \\SELECT failure_count FROM local_login_rate_limits
            \\WHERE scope = ? AND key_hash = ?
        ,
            .{},
            .{ scope, key_hash },
        );
        const recent_count = try self.database.one(
            i64,
            \\SELECT failure_count FROM local_login_rate_limits
            \\WHERE scope = ? AND key_hash = ?
            \\  AND window_started_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-15 minutes')
        ,
            .{},
            .{ scope, key_hash },
        );
        if (recent_count) |current| {
            const next = current + 1;
            try self.database.exec(
                "UPDATE local_login_rate_limits SET failure_count = ?, locked_until = CASE WHEN ? >= 5 THEN strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '+15 minutes') ELSE locked_until END, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE scope = ? AND key_hash = ?",
                .{},
                .{ next, next, scope, key_hash },
            );
        } else if (count != null) {
            try self.database.exec(
                "UPDATE local_login_rate_limits SET failure_count = 1, window_started_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), locked_until = NULL, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE scope = ? AND key_hash = ?",
                .{},
                .{ scope, key_hash },
            );
        } else {
            try self.database.exec(
                "INSERT INTO local_login_rate_limits (scope, key_hash, failure_count) VALUES (?, ?, 1)",
                .{},
                .{ scope, key_hash },
            );
        }
    }

    fn cleanupRateLimitsInTransaction(self: *Store) !void {
        try self.database.exec(
            "DELETE FROM local_login_rate_limits WHERE updated_at <= strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-1 day') AND (locked_until IS NULL OR locked_until <= strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))",
            .{},
            .{},
        );
    }

    pub fn clearRateLimit(self: *Store, identifier_hash: []const u8, address_hash: []const u8) !void {
        try self.database.exec(
            "DELETE FROM local_login_rate_limits WHERE (scope = 'identifier' AND key_hash = ?) OR (scope = 'address' AND key_hash = ?)",
            .{},
            .{ identifier_hash, address_hash },
        );
    }
};
