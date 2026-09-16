const std = @import("std");
const sqlite = @import("sqlite");
const embedded = @import("embedded_migrations");

pub const Migration = struct {
    version: i64,
    name: []const u8,
    sql: []const u8,
};

pub fn runtimeDirectoryPath(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    var directory = std.Io.Dir.cwd().openDir(io, "migrations", .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (directory) |*value| {
        value.close(io);
        return allocator.dupe(u8, "migrations");
    }

    const executable_directory = try std.process.executableDirPathAlloc(io, allocator);
    defer allocator.free(executable_directory);
    const install_prefix = std.fs.path.dirname(executable_directory) orelse return error.InvalidExecutablePath;
    return std.fs.path.join(allocator, &.{ install_prefix, "migrations" });
}

const MigrationFiles = struct {
    items: []Migration,
    allocator: std.mem.Allocator,

    fn deinit(self: *MigrationFiles) void {
        for (self.items) |migration| {
            self.allocator.free(migration.name);
            self.allocator.free(migration.sql);
        }
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub fn migrateUp(
    database: *sqlite.Db,
    io: std.Io,
    allocator: std.mem.Allocator,
    directory_path: []const u8,
) !usize {
    try executeScript(database, allocator, embedded.bootstrap_sql);

    var files = try loadMigrationFiles(io, allocator, directory_path);
    defer files.deinit();

    var applied_count: usize = 0;
    for (files.items) |migration| {
        if (try applyMigration(database, allocator, migration)) applied_count += 1;
    }
    return applied_count;
}

fn loadMigrationFiles(
    io: std.Io,
    allocator: std.mem.Allocator,
    directory_path: []const u8,
) !MigrationFiles {
    var directory = try std.Io.Dir.cwd().openDir(io, directory_path, .{ .iterate = true });
    defer directory.close(io);

    var files = try std.ArrayList(Migration).initCapacity(allocator, 4);
    errdefer {
        for (files.items) |migration| {
            allocator.free(migration.name);
            allocator.free(migration.sql);
        }
        files.deinit(allocator);
    }

    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".sql")) continue;

        const parsed = try parseFilename(entry.name);
        const name = try allocator.dupe(u8, parsed.name);
        errdefer allocator.free(name);
        const sql = try directory.readFileAlloc(io, entry.name, allocator, .limited(16 * 1024 * 1024));
        errdefer allocator.free(sql);
        try files.append(allocator, .{
            .version = parsed.version,
            .name = name,
            .sql = sql,
        });
    }

    std.mem.sort(Migration, files.items, {}, lessThan);
    if (files.items.len > 1) {
        for (files.items[1..], files.items[0 .. files.items.len - 1]) |current, previous| {
            if (current.version == previous.version) return error.DuplicateMigrationVersion;
        }
    }

    return .{ .items = try files.toOwnedSlice(allocator), .allocator = allocator };
}

const ParsedFilename = struct {
    version: i64,
    name: []const u8,
};

fn parseFilename(filename: []const u8) !ParsedFilename {
    if (!std.mem.endsWith(u8, filename, ".sql") or filename.len <= ".sql".len) {
        return error.InvalidMigrationFilename;
    }
    const stem = filename[0 .. filename.len - ".sql".len];
    const separator = std.mem.indexOfScalar(u8, stem, '_') orelse return error.InvalidMigrationFilename;
    if (separator == 0 or separator + 1 == stem.len) return error.InvalidMigrationFilename;

    const version = std.fmt.parseInt(i64, stem[0..separator], 10) catch {
        return error.InvalidMigrationFilename;
    };
    if (version <= 0) return error.InvalidMigrationVersion;
    return .{ .version = version, .name = stem[separator + 1 ..] };
}

fn lessThan(_: void, lhs: Migration, rhs: Migration) bool {
    return lhs.version < rhs.version;
}

fn applyMigration(database: *sqlite.Db, allocator: std.mem.Allocator, migration: Migration) !bool {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(migration.sql, &digest, .{});
    const checksum = std.fmt.bytesToHex(digest, .lower);

    const AppliedMigration = struct {
        name: sqlite.Text,
        checksum_sha256: sqlite.Text,
    };

    try database.execMulti("BEGIN IMMEDIATE;", .{});
    errdefer database.execMulti("ROLLBACK;", .{}) catch {};
    const applied = try database.oneAlloc(
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
        try database.execMulti("COMMIT;", .{});
        return false;
    }

    try executeScript(database, allocator, migration.sql);
    try database.exec(
        "INSERT INTO schema_migrations (version, name, checksum_sha256) VALUES (?, ?, ?)",
        .{},
        .{ migration.version, migration.name, &checksum },
    );
    try database.execMulti("COMMIT;", .{});
    return true;
}

fn executeScript(database: *sqlite.Db, allocator: std.mem.Allocator, sql: []const u8) !void {
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
    if (trimmed.len == 0) return;

    const script = if (trimmed[trimmed.len - 1] == ';') trimmed[0 .. trimmed.len - 1] else trimmed;
    const script_start = @intFromPtr(script.ptr) - @intFromPtr(without_comments.items.ptr);
    without_comments.items[script_start + script.len] = 0;
    try database.execMulti(script, .{});
}

test "migration filenames provide version and name" {
    const parsed = try parseFilename("0007_add_authors.sql");
    try std.testing.expectEqual(@as(i64, 7), parsed.version);
    try std.testing.expectEqualStrings("add_authors", parsed.name);
}

test "migration filenames reject version zero and malformed names" {
    try std.testing.expectError(error.InvalidMigrationVersion, parseFilename("0000_bootstrap.sql"));
    try std.testing.expectError(error.InvalidMigrationFilename, parseFilename("initial.sql"));
}

test "migration is recorded and repeatable" {
    var database = try sqlite.Db.init(.{
        .mode = .Memory,
        .open_flags = .{ .write = true, .create = true },
    });
    defer database.deinit();

    try std.testing.expectEqual(@as(usize, 1), try migrateUp(&database, std.testing.io, std.testing.allocator, "migrations"));
    try std.testing.expectEqual(@as(usize, 0), try migrateUp(&database, std.testing.io, std.testing.allocator, "migrations"));

    const count = try database.one(i64, "SELECT count(*) FROM schema_migrations", .{}, .{});
    try std.testing.expectEqual(@as(?i64, 1), count);

    const tables = try database.one(
        i64,
        "SELECT count(*) FROM sqlite_schema WHERE type = 'table' AND name IN ('documents', 'document_versions', 'sections', 'working_revisions', 'users', 'user_roles', 'assets', 'cache_invalidation_jobs', 'idempotency_results', 'audit_log', 'version_import_provenance')",
        .{},
        .{},
    );
    try std.testing.expectEqual(@as(?i64, 11), tables);
}

test "migration ledger rejects checksum drift" {
    var database = try sqlite.Db.init(.{
        .mode = .Memory,
        .open_flags = .{ .write = true, .create = true },
    });
    defer database.deinit();
    _ = try migrateUp(&database, std.testing.io, std.testing.allocator, "migrations");

    try database.exec(
        "UPDATE schema_migrations SET checksum_sha256 = ? WHERE version = 1",
        .{},
        .{"0000000000000000000000000000000000000000000000000000000000000000"},
    );
    try std.testing.expectError(error.MigrationDrift, migrateUp(&database, std.testing.io, std.testing.allocator, "migrations"));
}
