const std = @import("std");
const sqlite = @import("sqlite");
const migrations = @import("migrations");

const bootstrap_sql = migrations.bootstrap_sql;
const initial_sql = migrations.initial_sql;

const initial_migration = Migration{
    .version = 1,
    .name = "initial",
    .sql = initial_sql,
};

const Migration = struct {
    version: i64,
    name: []const u8,
    sql: []const u8,
};

pub const Database = struct {
    handle: sqlite.Db,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Database {
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        var database = Database{ .handle = try sqlite.Db.init(.{
            .mode = .{ .File = path_z },
            .open_flags = .{ .write = true, .create = true },
            .threading_mode = .Serialized,
        }) };
        errdefer database.close();

        try database.configureConnection();
        return database;
    }

    pub fn migrateUp(self: *Database, allocator: std.mem.Allocator) !bool {
        try executeScript(&self.handle, allocator, bootstrap_sql);
        return try applyMigration(self, allocator, initial_migration);
    }

    pub fn close(self: *Database) void {
        self.handle.deinit();
        self.* = undefined;
    }

    fn configureConnection(self: *Database) !void {
        const journal_mode = try self.handle.pragma([16:0]u8, .{}, "journal_mode", "WAL") orelse return error.InvalidJournalMode;
        if (!std.ascii.eqlIgnoreCase(journal_mode[0..3], "wal") or journal_mode[3] != 0) return error.InvalidJournalMode;

        try self.handle.exec("PRAGMA synchronous = NORMAL", .{}, .{});
        try self.handle.exec("PRAGMA foreign_keys = ON", .{}, .{});
        const foreign_keys = try self.handle.pragma(i64, .{}, "foreign_keys", null) orelse return error.ForeignKeysDisabled;
        if (foreign_keys != 1) return error.ForeignKeysDisabled;

        const busy_timeout = try self.handle.pragma(i64, .{}, "busy_timeout", "5000") orelse return error.InvalidBusyTimeout;
        if (busy_timeout != 5000) return error.InvalidBusyTimeout;
    }
};

fn applyMigration(database: *Database, allocator: std.mem.Allocator, migration: Migration) !bool {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(migration.sql, &digest, .{});
    const checksum = std.fmt.bytesToHex(digest, .lower);

    const AppliedMigration = struct {
        name: sqlite.Text,
        checksum_sha256: sqlite.Text,
    };

    try database.handle.execMulti("BEGIN IMMEDIATE;", .{});
    errdefer database.handle.execMulti("ROLLBACK;", .{}) catch {};
    const applied = try database.handle.oneAlloc(
        AppliedMigration,
        allocator,
        "SELECT name, checksum_sha256 FROM schema_migrations WHERE version = ?",
        .{},
        .{migration.version},
    );
    if (applied) |value| {
        defer allocator.free(value.name.data);
        defer allocator.free(value.checksum_sha256.data);
        if (!std.mem.eql(u8, value.name.data, migration.name) or
            !std.mem.eql(u8, value.checksum_sha256.data, &checksum)) return error.MigrationDrift;
        try database.handle.execMulti("COMMIT;", .{});
        return false;
    }

    try executeScript(&database.handle, allocator, migration.sql);
    try database.handle.exec(
        "INSERT INTO schema_migrations (version, name, checksum_sha256) VALUES (?, ?, ?)",
        .{},
        .{ migration.version, migration.name, &checksum },
    );
    try database.handle.execMulti("COMMIT;", .{});
    return true;
}

fn executeScript(handle: *sqlite.Db, allocator: std.mem.Allocator, sql: []const u8) !void {
    const source_end = std.mem.indexOfScalar(u8, sql, 0) orelse sql.len;
    const source = sql[0..source_end];
    var without_comments = try std.ArrayList(u8).initCapacity(allocator, source.len);
    defer without_comments.deinit(allocator);

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const normalized_line = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (normalized_line.len == 0 or std.mem.startsWith(u8, normalized_line, "--")) continue;
        try without_comments.appendSlice(allocator, line);
        try without_comments.append(allocator, '\n');
    }

    try without_comments.append(allocator, 0);
    const generated = without_comments.items[0 .. without_comments.items.len - 1];
    const trimmed = std.mem.trim(u8, generated, &std.ascii.whitespace);
    const script = if (trimmed[trimmed.len - 1] == ';') trimmed[0 .. trimmed.len - 1] else trimmed;
    const script_start = @intFromPtr(script.ptr) - @intFromPtr(without_comments.items.ptr);
    without_comments.items[script_start + script.len] = 0;
    try handle.execMulti(script, .{});
}

test "migration is recorded and repeatable" {
    var database = Database{ .handle = try sqlite.Db.init(.{
        .mode = .Memory,
        .open_flags = .{ .write = true, .create = true },
    }) };
    defer database.close();

    try std.testing.expect(try database.migrateUp(std.testing.allocator));
    try std.testing.expect(!(try database.migrateUp(std.testing.allocator)));

    const count = try database.handle.one(i64, "SELECT count(*) FROM schema_migrations", .{}, .{});
    try std.testing.expectEqual(@as(?i64, 1), count);

    const tables = try database.handle.one(
        i64,
        "SELECT count(*) FROM sqlite_schema WHERE type = 'table' AND name IN ('documents', 'document_versions', 'sections', 'working_revisions', 'users', 'user_roles', 'assets', 'cache_invalidation_jobs', 'idempotency_results', 'audit_log', 'version_import_provenance')",
        .{},
        .{},
    );
    try std.testing.expectEqual(@as(?i64, 11), tables);
}

test "migration ledger rejects checksum drift" {
    var database = Database{ .handle = try sqlite.Db.init(.{
        .mode = .Memory,
        .open_flags = .{ .write = true, .create = true },
    }) };
    defer database.close();
    _ = try database.migrateUp(std.testing.allocator);

    try database.handle.exec(
        "UPDATE schema_migrations SET checksum_sha256 = ? WHERE version = 1",
        .{},
        .{"0000000000000000000000000000000000000000000000000000000000000000"},
    );
    try std.testing.expectError(error.MigrationDrift, database.migrateUp(std.testing.allocator));
}
