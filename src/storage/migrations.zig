const std = @import("std");
const sqlite = @import("sqlite");
const embedded = @import("embedded_migrations");
const logging = @import("../logging.zig");

pub const Migration = struct {
    version: i64,
    name: []const u8,
    sql: []const u8,
};

const MigrationFailureLogRecord = struct {
    comptime format: []const u8 = "migration run failed in {directory}: {error_name}",
    level: []const u8,
    event: []const u8,
    message: []const u8,
    directory: []const u8,
    error_name: []const u8,
};

const MigrationsLoadedLogRecord = struct {
    comptime format: []const u8 = "loaded {migration_count} migrations from {directory}",
    level: []const u8,
    event: []const u8,
    message: []const u8,
    directory: []const u8,
    migration_count: usize,
};

const MigrationAppliedLogRecord = struct {
    comptime format: []const u8 = "applied migration {version} ({name})",
    level: []const u8,
    event: []const u8,
    message: []const u8,
    version: i64,
    name: []const u8,
};

const MigrationVerifiedLogRecord = struct {
    comptime format: []const u8 = "verified migration {version} ({name})",
    level: []const u8,
    event: []const u8,
    message: []const u8,
    version: i64,
    name: []const u8,
};

const MigrationsCompletedLogRecord = struct {
    comptime format: []const u8 = "migration run completed ({applied_count} applied)",
    level: []const u8,
    event: []const u8,
    message: []const u8,
    applied_count: usize,
};

test "migration records use focused text templates" {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try logging.writeRecord(
        &writer,
        std.testing.allocator,
        .text,
        42,
        false,
        false,
        MigrationAppliedLogRecord{
            .level = "info",
            .event = "migration.applied",
            .message = "applied migration",
            .version = 1,
            .name = "initial",
        },
    );
    try std.testing.expectEqualStrings(
        "timestamp=\"1970-01-01T00:00:00.042Z\" message=\"applied migration 1 (initial)\" level=\"info\" event=\"migration.applied\"\n",
        writer.buffered(),
    );
}

pub const MigrationContext = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    directory_path: []const u8,
    database: *sqlite.Db,
    logger: *logging.Logger,

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        directory_path: []const u8,
        database: *sqlite.Db,
        logger: *logging.Logger,
    ) MigrationContext {
        return .{
            .io = io,
            .allocator = allocator,
            .directory_path = directory_path,
            .database = database,
            .logger = logger,
        };
    }

    pub fn up(self: *MigrationContext) !usize {
        return self.migrateUp();
    }

    pub fn migrateUp(self: *MigrationContext) !usize {
        return self.migrateUpInner() catch |migration_error| {
            self.logger.log(self.io, MigrationFailureLogRecord{
                .level = "error",
                .event = "migrations.failed",
                .message = "migration run failed",
                .directory = self.directory_path,
                .error_name = @errorName(migration_error),
            }) catch {};
            return migration_error;
        };
    }

    fn migrateUpInner(self: *MigrationContext) !usize {
        try executeScript(self.database, self.allocator, embedded.bootstrap_sql);

        var files = try loadMigrationFiles(self.io, self.allocator, self.directory_path);
        defer files.deinit();
        self.logger.log(self.io, MigrationsLoadedLogRecord{
            .level = "debug",
            .event = "migrations.loaded",
            .message = "loaded migrations",
            .directory = self.directory_path,
            .migration_count = files.items.len,
        }) catch {};

        var applied_count: usize = 0;
        for (files.items) |migration| {
            if (try applyMigration(self.database, self.allocator, migration)) {
                applied_count += 1;
                self.logger.log(self.io, MigrationAppliedLogRecord{
                    .level = "info",
                    .event = "migration.applied",
                    .message = "applied migration",
                    .version = migration.version,
                    .name = migration.name,
                }) catch {};
            } else {
                self.logger.log(self.io, MigrationVerifiedLogRecord{
                    .level = "debug",
                    .event = "migration.verified",
                    .message = "migration already applied",
                    .version = migration.version,
                    .name = migration.name,
                }) catch {};
            }
        }

        self.logger.log(self.io, MigrationsCompletedLogRecord{
            .level = "debug",
            .event = "migrations.completed",
            .message = "migration run completed",
            .applied_count = applied_count,
        }) catch {};
        return applied_count;
    }
};

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

        const parsed_filename = try parseFilename(entry.name);
        const migration_name = try allocator.dupe(u8, parsed_filename.name);
        errdefer allocator.free(migration_name);
        const sql = try directory.readFileAlloc(io, entry.name, allocator, .limited(16 * 1024 * 1024));
        errdefer allocator.free(sql);
        try files.append(allocator, .{
            .version = parsed_filename.version,
            .name = migration_name,
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
    if (applied) |applied_migration| {
        defer allocator.free(applied_migration.name.data);
        defer allocator.free(applied_migration.checksum_sha256.data);
        if (!std.mem.eql(u8, applied_migration.name.data, migration.name) or
            !std.mem.eql(u8, applied_migration.checksum_sha256.data, &checksum)) return error.MigrationDrift;
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
    const parsed_filename = try parseFilename("0007_add_authors.sql");
    try std.testing.expectEqual(@as(i64, 7), parsed_filename.version);
    try std.testing.expectEqualStrings("add_authors", parsed_filename.name);
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
    var logger = logging.Logger.init(std.testing.allocator, .text);
    var context = MigrationContext.init(std.testing.io, std.testing.allocator, "migrations", &database, &logger);

    try std.testing.expectEqual(@as(usize, 1), try context.migrateUp());
    try std.testing.expectEqual(@as(usize, 0), try context.up());

    const count = try database.one(i64, "SELECT count(*) FROM schema_migrations", .{}, .{});
    try std.testing.expectEqual(@as(?i64, 1), count);

    const tables = try database.one(
        i64,
        "SELECT count(*) FROM sqlite_schema WHERE type = 'table' AND name IN ('documents', 'document_versions', 'sections', 'working_revisions', 'users', 'local_password_credentials', 'user_roles', 'assets', 'web_sessions', 'local_password_reset_tokens', 'local_login_rate_limits', 'cache_invalidation_jobs', 'idempotency_results', 'audit_log', 'version_import_provenance')",
        .{},
        .{},
    );
    try std.testing.expectEqual(@as(?i64, 15), tables);
}

test "migration ledger rejects checksum drift" {
    var database = try sqlite.Db.init(.{
        .mode = .Memory,
        .open_flags = .{ .write = true, .create = true },
    });
    defer database.deinit();
    var logger = logging.Logger.init(std.testing.allocator, .text);
    var context = MigrationContext.init(std.testing.io, std.testing.allocator, "migrations", &database, &logger);
    _ = try context.migrateUp();

    try database.exec(
        "UPDATE schema_migrations SET checksum_sha256 = ? WHERE version = 1",
        .{},
        .{"0000000000000000000000000000000000000000000000000000000000000000"},
    );
    try std.testing.expectError(error.MigrationDrift, context.migrateUp());
}
